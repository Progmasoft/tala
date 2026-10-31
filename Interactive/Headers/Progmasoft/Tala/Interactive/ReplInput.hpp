// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <iosfwd>
#include <string>
#include <string_view>

namespace Progmasoft::Tala::Interactive
{
    enum class InputLineStatus : std::uint8_t
    {
        Complete,
        End,
        TooLong,
        Failure
    };

    enum class ReplCommandKind : std::uint8_t
    {
        Expression,
        Help,
        Type,
        History,
        Reset,
        Quit,
        TypeMissingExpression,
        Unknown
    };

    struct ReplCommand final
    {
        ReplCommandKind kind{ ReplCommandKind::Expression };
        std::string_view expression;
    };

    /** Read at most the requested byte count and drain any overlong line. */
    [[nodiscard]] auto
    ReadInputLine(std::istream &input,
                  std::string &line,
                  std::size_t maximumBytes) -> InputLineStatus;

    /** Separate REPL meta-commands from unchanged Tala source expressions.
     */
    [[nodiscard]] auto
    ParseReplCommand(std::string_view line) noexcept -> ReplCommand;
} // namespace Progmasoft::Tala::Interactive
