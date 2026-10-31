// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <string_view>

namespace Progmasoft::Tala::Artifact
{
    /**
     * Validate the canonical source identity shared by all compiler IRs.
     *
     * Source ownership crosses the Haskell/native boundary and is also stored
     * in public Xpp/Xmm artifacts. Requiring one portable relative spelling at
     * each verifier prevents a later output planner from interpreting a path
     * differently on Windows, macOS, or Linux.
     */
    [[nodiscard]] auto
    IsNormalizedSourcePath(std::u32string_view path) -> bool;
} // namespace Progmasoft::Tala::Artifact
