// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <llvm/Support/raw_ostream.h>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"
#include "Progmasoft/Tala/Support/CompilerStack.hpp"

// Measures how much stack a native stage needs for a given nesting depth.
//
//     stack_probe <shape> <depth> <stage> <stack-kibibytes>
//
// The shapes are `statements`, an `if` nested in an `if`; `expressions`, a
// chain of additions that nests in the first operand; `operands`, additions
// that nest in the second operand; and `chain`, an `else if` chain.
//
// builds a Core module of the given shape and depth on the compiler stack,
// then runs one stage on a thread whose stack has the given size. The
// process exits with 0 when the stage completes and is terminated by the
// operating system when the stack is too small. Searching for the smallest
// size that completes gives the stack the stage uses at that depth, in the
// build that is measured, which is how the nesting limits are justified for
// ordinary and for sanitizer builds. The program is a measuring instrument,
// not a test: a run that overflows is an expected outcome.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Wire = Progmasoft::Tala::Core::Wire;

    constexpr std::uint64_t kValue = 2U;
    constexpr std::uint64_t kTotal = 3U;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Value() -> Core::Expression
    {
        return Core::Expression::Variable({ kValue, U"value" },
                                          Core::Type::int64());
    }

    [[nodiscard]] auto
    Total() -> Core::Expression
    {
        return Core::Expression::Variable({ kTotal, U"total" },
                                          Core::Type::int64());
    }

    [[nodiscard]] auto
    Module(std::vector<Core::Statement> statements) -> Core::Module
    {
        std::vector<Core::Statement> body;
        body.push_back(
            Core::Statement::Bind(Core::Binding{ { kTotal, U"total" },
                                                 Core::Type::int64(),
                                                 true,
                                                 Integer(0) }));
        for (auto &statement : statements)
            body.push_back(std::move(statement));
        body.push_back(Core::Statement::Return(Total()));
        return { { U"Probe" },
                 { Core::Function{
                     { 1U, U"Pick" },
                     { { { kValue, U"value" }, Core::Type::int64() } },
                     Core::Type::int64(),
                     std::move(body) } } };
    }

    /// `if (value > 0) { if (value > 1) { ... total = value; } }`
    [[nodiscard]] auto
    Statements(std::size_t depth) -> Core::Module
    {
        auto statement = Core::Statement::Assign({ kTotal, U"total" }, Value());
        for (std::size_t index = depth; index-- > 0U;)
        {
            std::vector<Core::Statement> body;
            body.push_back(std::move(statement));
            statement = Core::Statement::If(
                Core::Expression::InvokePrimitive(
                    Core::Primitive::GreaterThan,
                    { Value(), Integer(static_cast<std::int64_t>(index)) },
                    Core::Type::boolean()),
                std::move(body),
                {});
        }
        std::vector<Core::Statement> statements;
        statements.push_back(std::move(statement));
        return Module(std::move(statements));
    }

    /// `total = (((value + 1) + 1) + ...)`: the first operand nests.
    [[nodiscard]] auto
    Expressions(std::size_t depth) -> Core::Module
    {
        auto expression = Value();
        for (std::size_t index = 0U; index < depth; ++index)
        {
            std::vector<Core::Expression> operands;
            operands.push_back(std::move(expression));
            operands.push_back(Integer(1));
            expression = Core::Expression::InvokePrimitive(Core::Primitive::Add,
                                                           std::move(operands),
                                                           Core::Type::int64());
        }
        std::vector<Core::Statement> statements;
        statements.push_back(Core::Statement::Assign({ kTotal, U"total" },
                                                     std::move(expression)));
        return Module(std::move(statements));
    }

    /// `total = (value + (value + (...)))`: the second operand nests,
    /// which is nesting that no stage walks in a loop.
    [[nodiscard]] auto
    Operands(std::size_t depth) -> Core::Module
    {
        auto expression = Value();
        for (std::size_t index = 0U; index < depth; ++index)
        {
            std::vector<Core::Expression> operands;
            operands.push_back(Value());
            operands.push_back(std::move(expression));
            expression = Core::Expression::InvokePrimitive(Core::Primitive::Add,
                                                           std::move(operands),
                                                           Core::Type::int64());
        }
        std::vector<Core::Statement> statements;
        statements.push_back(Core::Statement::Assign({ kTotal, U"total" },
                                                     std::move(expression)));
        return Module(std::move(statements));
    }

    /// `if (value == 0) { total = value; } else if (value == 1) { ... }`
    [[nodiscard]] auto
    Chain(std::size_t links) -> Core::Module
    {
        std::vector<Core::Statement> rest;
        for (std::size_t index = links; index-- > 0U;)
        {
            std::vector<Core::Statement> body;
            body.push_back(
                Core::Statement::Assign({ kTotal, U"total" }, Value()));
            auto link = Core::Statement::If(
                Core::Expression::InvokePrimitive(
                    Core::Primitive::Equal,
                    { Value(), Integer(static_cast<std::int64_t>(index)) },
                    Core::Type::boolean()),
                std::move(body),
                std::move(rest));
            rest.clear();
            rest.push_back(std::move(link));
        }
        return Module(std::move(rest));
    }

    [[nodiscard]] auto
    Usage() -> int
    {
        llvm::errs()
            << "usage: stack_probe <statements|expressions|operands|chain> "
               "<depth> <encode|decode|verify|prepare|pipeline> "
               "<stack-kibibytes>\n";
        return 2;
    }

    [[nodiscard]] auto
    Number(const char *text) -> std::size_t
    {
        return static_cast<std::size_t>(std::strtoull(text, nullptr, 10));
    }
} // namespace

int
main(int argc, char **argv)
{
    if (argc != 5)
        return Usage();
    // The arguments of a measuring tool, read once at the start.
    // NOLINTBEGIN(cppcoreguidelines-pro-bounds-pointer-arithmetic)
    const std::string_view shape = argv[1];
    const auto depth = Number(argv[2]);
    const std::string_view stage = argv[3];
    const auto stack = Number(argv[4]) * 1024U;
    // NOLINTEND(cppcoreguidelines-pro-bounds-pointer-arithmetic)
    if (depth == 0U || stack == 0U)
        return Usage();

    // Everything that recurses along the nesting, including building and
    // destroying the module, happens on the compiler stack; only the stage
    // under measurement runs on the probed one.
    return Progmasoft::Tala::Support::RunOnCompilerStack([&]() -> int {
        Wire::Limits limits;
        limits.maximumStatementDepth = depth + 16U;
        limits.maximumExpressionDepth = depth + 16U;
        const auto module = shape == "statements"    ? Statements(depth)
                            : shape == "expressions" ? Expressions(depth)
                            : shape == "chain"       ? Chain(depth)
                            : shape == "operands"    ? Operands(depth)
                                                     : Core::Module{};
        if (module.functions.empty())
            return Usage();
        const auto encoded = Wire::Encode(module, limits);
        if (!encoded)
        {
            llvm::errs() << "stack_probe: the module could not be encoded\n";
            return 3;
        }
        int outcome = 0;
        std::size_t committed = 0U;
        Progmasoft::Tala::Support::RunOnStack(stack, [&] {
            if (stage == "encode")
                outcome = Wire::Encode(module, limits) ? 0 : 4;
            else if (stage == "decode")
                outcome = Wire::Decode(encoded.bytes, limits) ? 0 : 4;
            else if (stage == "verify")
                outcome = Core::Verify(module).empty() ? 0 : 4;
            else if (stage == "prepare")
                outcome
                    = Core::CorePrep::Prepare(module).functions.empty() ? 4 : 0;
            else if (stage == "pipeline")
                // The whole native route from Core bytes to LLVM, as the
                // driver runs it, under the default wire limits.
                outcome = Progmasoft::Tala::Pipeline::ConsumeCore(encoded.bytes)
                                  .succeeded
                              ? 0
                              : 4;
            else
                outcome = 2;
            committed = Progmasoft::Tala::Support::CommittedStackBytes();
        });
        // The size on the command line is only reserved. What the stage
        // touched is committed: an upper bound on what it used, to the page.
        if (outcome == 0)
            llvm::outs() << "ok committed-kib " << committed / 1024U << '\n';
        return outcome;
    });
}
