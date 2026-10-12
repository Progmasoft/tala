// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <deque>
#include <string>
#include <string_view>

#include "Progmasoft/Tala/Interactive/History.hpp"

namespace Progmasoft::Tala::Interactive::Runtime
{
    void
    History::Append(std::string_view expression)
    {
        if (expression.empty())
            return;
        if (entries_.size() == kMaximumEntries)
            entries_.pop_front();
        entries_.emplace_back(expression);
    }

    void
    History::Clear() noexcept
    {
        entries_.clear();
    }

    auto
    History::Entries() const noexcept -> const std::deque<std::string> &
    {
        return entries_;
    }
} // namespace Progmasoft::Tala::Interactive::Runtime
