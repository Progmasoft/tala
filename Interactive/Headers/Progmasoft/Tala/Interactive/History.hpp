// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <deque>
#include <string>
#include <string_view>

namespace Progmasoft::Tala::Interactive::Runtime
{
    /** Bounded, insertion-ordered history of successfully evaluated source
     * cells. */
    class History final
    {
    public:
        static constexpr std::size_t kMaximumEntries = 256U;

        /** Append one non-empty cell and discard the oldest cell if the cap is
         * exceeded. */
        void
        Append(std::string_view expression);

        /** Remove every retained entry. */
        void
        Clear() noexcept;

        /** Return an immutable view of entries from oldest to newest. */
        [[nodiscard]] auto
        Entries() const noexcept -> const std::deque<std::string> &;

    private:
        std::deque<std::string> entries_;
    };
} // namespace Progmasoft::Tala::Interactive::Runtime
