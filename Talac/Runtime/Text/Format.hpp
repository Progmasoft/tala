// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>

#include "Scalars.hpp"

// The conversions of the output format grammar, as functions from a value
// and the parts of its conversion to scalars appended to a sequence. They
// do no I/O and allocate nothing but the sequence they append to.

namespace Progmasoft::Tala::Runtime::Text
{
    /** The parts of one conversion: the flags written between `%` and the
     * conversion letter, and its width and precision when it has them. */
    struct Conversion final
    {
        std::int64_t flags{};
        /// Negative when the conversion has no width.
        std::int64_t width{ -1 };
        /// Negative when the conversion has no precision.
        std::int64_t precision{ -1 };

        [[nodiscard]] auto
        Has(const std::int64_t flag) const noexcept -> bool
        {
            return (flags & flag) != 0;
        }
    };

    /** An integer given as whether it is negative and its magnitude, so
     * that the least signed value needs no case of its own. */
    void
    AppendInteger(Scalars &output,
                  bool negative,
                  std::uint64_t magnitude,
                  const Conversion &conversion) noexcept;

    void
    AppendFloating(Scalars &output,
                   double value,
                   const Conversion &conversion) noexcept;

    /** A run of scalars as the body of a `%s` or `%c` field. */
    void
    AppendText(Scalars &output,
               const char32_t *scalars,
               std::size_t count,
               const Conversion &conversion) noexcept;
} // namespace Progmasoft::Tala::Runtime::Text
