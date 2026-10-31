// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <istream>
#include <string>
#include <string_view>

#include "Progmasoft/Tala/Interactive/ReplInput.hpp"

namespace Progmasoft::Tala::Interactive
{
    auto
    ReadInputLine(std::istream &input,
                  std::string &line,
                  std::size_t maximumBytes) -> InputLineStatus
    {
        line.clear();
        bool tooLong{};
        while (true)
        {
            const auto next = input.get();
            if (next == std::char_traits<char>::eof())
            {
                if (input.bad())
                    return InputLineStatus::Failure;
                if (line.empty() && !tooLong)
                    return InputLineStatus::End;
                return tooLong ? InputLineStatus::TooLong
                               : InputLineStatus::Complete;
            }
            if (next == '\n')
                return tooLong ? InputLineStatus::TooLong
                               : InputLineStatus::Complete;
            if (tooLong)
                continue;
            if (line.size() == maximumBytes)
            {
                line.clear();
                tooLong = true;
                continue;
            }
            line.push_back(static_cast<char>(next));
        }
    }

    auto
    ParseReplCommand(std::string_view line) noexcept -> ReplCommand
    {
        if (line == ":help")
            return { ReplCommandKind::Help, {} };
        if (line == ":history")
            return { ReplCommandKind::History, {} };
        if (line == ":reset")
            return { ReplCommandKind::Reset, {} };
        if (line == ":quit")
            return { ReplCommandKind::Quit, {} };
        if (line == ":type")
            return { ReplCommandKind::TypeMissingExpression, {} };
        if (line.starts_with(":type ") || line.starts_with(":type\t"))
        {
            std::size_t start = 5U;
            while (start < line.size()
                   && (line[start] == ' ' || line[start] == '\t'))
                ++start;
            if (start == line.size())
                return { ReplCommandKind::TypeMissingExpression, {} };
            return { ReplCommandKind::Type, line.substr(start) };
        }
        if (!line.empty() && line.front() == ':')
            return { ReplCommandKind::Unknown, {} };
        return { ReplCommandKind::Expression, line };
    }
} // namespace Progmasoft::Tala::Interactive
