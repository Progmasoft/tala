// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>

#include "Talac/Artifact/SourcePath.hpp"

namespace Progmasoft::Tala::Artifact
{
    namespace
    {
        [[nodiscard]] auto
        IsUnicodeScalar(const char32_t value) -> bool
        {
            return value <= 0x10ffffU && (value < 0xd800U || value > 0xdfffU);
        }
    } // namespace

    auto
    IsNormalizedSourcePath(const std::u32string_view path) -> bool
    {
        if (path.empty() || path.front() == U'/' || path.front() == U'\\'
            || path.find(U'\\') != std::u32string_view::npos
            || path.find(U':') != std::u32string_view::npos
            || path.find(U'\0') != std::u32string_view::npos
            || !path.ends_with(U".tala")
            || !std::ranges::all_of(path, IsUnicodeScalar))
            return false;

        // `.tala` has no source basename. Keep the extension itself from being
        // mistaken for a valid filename by the generic segment checks below.
        const auto lastSeparator = path.find_last_of(U'/');
        const auto basenameStart = lastSeparator == std::u32string_view::npos
                                       ? 0U
                                       : lastSeparator + 1U;
        if (path.substr(basenameStart) == U".tala")
            return false;

        // Reject aliases and traversal before any consumer turns this identity
        // into a filesystem output name.
        std::size_t segmentStart{};
        while (segmentStart <= path.size())
        {
            const auto separator = path.find(U'/', segmentStart);
            const auto segment
                = path.substr(segmentStart,
                              separator == std::u32string_view::npos
                                  ? path.size() - segmentStart
                                  : separator - segmentStart);
            if (segment.empty() || segment == U"." || segment == U"..")
                return false;
            if (separator == std::u32string_view::npos)
                break;
            segmentStart = separator + 1U;
        }
        return true;
    }
} // namespace Progmasoft::Tala::Artifact
