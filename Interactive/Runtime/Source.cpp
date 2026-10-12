// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Source.hpp"
#include "Value.hpp"

namespace Progmasoft::Tala::Interactive::Runtime
{
    namespace
    {
        constexpr std::size_t kMaximumExpressionBytes
            = std::size_t{ 1024U } * 1024U;

        [[nodiscard]] auto
        AppendPreviousBinding(
            std::string &source,
            const std::optional<Backend::LLVM::JitValue> &previous) -> bool
        {
            if (!previous)
                return true;
            const auto binding = SourceBinding(*previous);
            if (!binding)
                return false;
            source.append("        ").append(*binding).push_back('\n');
            return true;
        }
    } // namespace

    auto
    BuildCellSource(std::uint64_t cellNumber,
                    std::string_view expression,
                    const std::optional<Backend::LLVM::JitValue> &previous)
        -> std::optional<std::string>
    {
        if (expression.empty())
            return std::nullopt;
        if (expression.size() > kMaximumExpressionBytes)
            return std::nullopt;

        // Construct each cell in memory. A unique namespace separates JIT
        // symbols; source and Core scratch files are not part of the REPL ABI.
        std::string source;
        source.reserve(expression.size() + 160U);
        source.append("namespace Tala.Interactive.Cell")
            .append(std::to_string(cellNumber))
            .append(
                ";\nclass Session {\n    public static auto Evaluate() {\n");
        if (!AppendPreviousBinding(source, previous))
            return std::nullopt;
        source.append("        ").append(expression).append("\n    }\n}\n");
        return source;
    }

    auto
    EvaluationSymbol(const tala::xmm::Module &module, std::uint64_t cellNumber)
        -> std::optional<std::string>
    {
        auto expectedCell = std::u32string(U"Cell");
        for (const auto digit : std::to_string(cellNumber))
            expectedCell.push_back(static_cast<char32_t>(digit));
        const std::vector<std::u32string> expectedName{ U"Tala",
                                                        U"Interactive",
                                                        std::move(
                                                            expectedCell) };
        if (module.name != expectedName)
            return std::nullopt;
        const tala::xmm::Function *evaluation{};
        for (const auto &function : module.functions)
        {
            if (function.symbol.spelling != U"Evaluate")
                continue;
            if (evaluation != nullptr)
                return std::nullopt;
            evaluation = &function;
        }
        if (evaluation == nullptr || !evaluation->parameter_types.empty())
            return std::nullopt;

        // Use the verifier-approved Xmm symbol identity, not a guessed source
        // name or a compiler-local counter replicated by the REPL.
        std::string symbol;
        for (const auto &part : module.name)
        {
            if (!symbol.empty())
                symbol.push_back('.');
            for (const auto scalar : part)
            {
                if (scalar > 0x7fU)
                    return std::nullopt;
                symbol.push_back(static_cast<char>(scalar));
            }
        }
        symbol.append(".Evaluate.");
        symbol.append(std::to_string(evaluation->symbol.id));
        return symbol;
    }
} // namespace Progmasoft::Tala::Interactive::Runtime
