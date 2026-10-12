// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstdint>
#include <fmt/format.h>
#include <iterator>
#include <span>
#include <string>
#include <string_view>
#include <utility>

#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Interactive/Session.hpp"
#include "Source.hpp"
#include "Talac/Cli/Commands/Frontend.hpp"
#include "Value.hpp"

namespace Progmasoft::Tala::Interactive
{
    namespace
    {
        [[nodiscard]] auto
        Error(std::string message) -> CellResult
        {
            return { CellStatus::Error, std::move(message), std::nullopt };
        }

        [[nodiscard]] auto
        EvaluationFunction(const tala::xmm::Module &module)
            -> const tala::xmm::Function *
        {
            const tala::xmm::Function *found{};
            for (const auto &function : module.functions)
            {
                if (function.symbol.spelling != U"Evaluate")
                    continue;
                if (found != nullptr)
                    return nullptr;
                found = &function;
            }
            return found;
        }

        [[nodiscard]] auto
        BackendError(const Backend::LLVM::JitError &error) -> std::string
        {
            return fmt::format("{}: {}", error.code, error.message);
        }
    } // namespace

    auto
    Session::Evaluate(std::string_view expression) -> CellResult
    {
        auto result = Compile(expression, true);
        if (result.status == CellStatus::Value
            || result.status == CellStatus::Void)
            history_.Append(expression);
        return result;
    }

    auto
    Session::TypeOf(std::string_view expression) -> CellResult
    {
        return Compile(expression, false);
    }

    auto
    Session::Reset() -> std::optional<std::string>
    {
        if (const auto issue = jit_.Reset())
            return BackendError(*issue);
        nextCell_ = 0U;
        previous_.reset();
        history_.Clear();
        return std::nullopt;
    }

    auto
    Session::History() const noexcept -> const std::deque<std::string> &
    {
        return history_.Entries();
    }

    auto
    Session::Compile(std::string_view expression, bool execute) -> CellResult
    {
        if (expression.empty())
            return Error(
                "enter a Tala expression, or use :help for REPL commands");
        if (expression.size() > std::size_t{ 1024U } * 1024U)
            return Error("one Tala expression cannot exceed 1 MiB");

        const auto source
            = Runtime::BuildCellSource(nextCell_, expression, previous_);
        if (!source)
            return Error("could not construct the bounded in-memory REPL cell");
        const auto *sourceBegin
            = reinterpret_cast<const std::uint8_t *>(source->data());
        const auto sourceBytes
            = std::span<const std::uint8_t>(sourceBegin, source->size());
        const auto compiled
            = Progmasoft::Tala::Cli::Frontend::CompileSource(sourceBytes);
        if (!compiled.succeeded())
            return Error(
                compiled.error.empty()
                    ? "frontend rejected this input without a diagnostic"
                    : compiled.error);
        if (compiled.kind
            != Progmasoft::Tala::Cli::Frontend::OutputKind::CoreWire)
            return Error("frontend returned a non-Core result for a REPL cell");

        tala::PipelineOptions options;
        if (!execute)
            options.stop_after = tala::PipelineStop::Xmm;
        auto pipeline
            = Progmasoft::Tala::Pipeline::ConsumeCore(compiled.bytes, options);
        if (!pipeline)
        {
            if (pipeline.coreWireError)
                return Error(fmt::format("Core artifact error at byte {}: {}",
                                         pipeline.coreWireError->offset,
                                         pipeline.coreWireError->message));
            if (pipeline.llvm_error)
                return Error(fmt::format("{}: {}",
                                         pipeline.llvm_error->code,
                                         pipeline.llvm_error->message));
            if (!pipeline.coreVerificationIssues.empty())
                return Error(fmt::format(
                    "Core verifier rejected the expression: {} issue(s)",
                    pipeline.coreVerificationIssues.size()));
            if (!pipeline.verification_issues.empty())
                return Error(fmt::format(
                    "CorePrep verifier rejected the expression: {} issue(s)",
                    pipeline.verification_issues.size()));
            if (!pipeline.xppVerificationIssues.empty())
                return Error(fmt::format(
                    "Xpp verifier rejected the expression: {} issue(s)",
                    pipeline.xppVerificationIssues.size()));
            if (!pipeline.xmmVerificationIssues.empty())
                return Error(fmt::format(
                    "Xmm verifier rejected the expression: {} issue(s)",
                    pipeline.xmmVerificationIssues.size()));
            return Error("compiler pipeline stopped before producing an "
                         "executable expression");
        }
        if (!pipeline.xmm)
            return Error(
                "compiler pipeline did not retain its verified Xmm module");

        const auto symbol = Runtime::EvaluationSymbol(*pipeline.xmm, nextCell_);
        if (!symbol)
            return Error("compiler did not emit the unique zero-argument "
                         "Evaluate function for this cell");
        const auto *function = EvaluationFunction(*pipeline.xmm);
        if (function == nullptr)
            return Error("compiler emitted an ambiguous Evaluate function for "
                         "this cell");

        if (!execute)
        {
            const auto typeName = FormatType(function->return_type);
            return { CellStatus::Type, typeName, std::nullopt };
        }
        if (!pipeline.llvm)
            return Error("LLVM lowering did not produce bitcode for this cell");
        // A module is never re-used after insertion, even if lookup or native
        // invocation fails. Advancing before insertion prevents a later input
        // from colliding with residual JIT symbols from a partially failed
        // cell.
        ++nextCell_;
        if (const auto issue = jit_.AddModule(pipeline.llvm->bitcode,
                                              *symbol,
                                              *symbol,
                                              function->return_type))
            return Error(BackendError(*issue));

        auto invocation = jit_.InvokeScalar(*symbol, function->return_type);
        if (!invocation.value)
            return Error(invocation.error
                             ? BackendError(*invocation.error)
                             : std::string("the JIT returned neither a value "
                                           "nor an error"));

        if (std::holds_alternative<std::monostate>(invocation.value->payload))
        {
            previous_.reset();
            return { CellStatus::Void, "void", std::move(invocation.value) };
        }
        // Keep the result only when it has a lossless source spelling. Wider
        // values remain executable and printable by the backend, but never
        // silently narrow to host int64 merely to implement the `_` binding.
        if (Runtime::SourceBinding(*invocation.value))
            previous_ = *invocation.value;
        else
            previous_.reset();
        return { CellStatus::Value,
                 fmt::format("{} : {}",
                             Runtime::DisplayValue(*invocation.value),
                             FormatType(function->return_type)),
                 std::move(invocation.value) };
    }

    auto
    FormatValue(const Backend::LLVM::JitValue &value) -> std::string
    {
        return Runtime::DisplayValue(value);
    }

    auto
    FormatType(const tala::core::Type &type) -> std::string
    {
        return Runtime::DisplayType(type);
    }
} // namespace Progmasoft::Tala::Interactive
