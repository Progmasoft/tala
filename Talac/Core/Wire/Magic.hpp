// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>

namespace Progmasoft::Tala::Core::Wire
{
    /// The four bytes every Core wire document starts with. The reader and
    /// the writer are separate translation units and share this one
    /// definition.
    inline constexpr std::uint8_t kMagic[] = { 'T', 'A', 'C', 'R' };
} // namespace Progmasoft::Tala::Core::Wire
