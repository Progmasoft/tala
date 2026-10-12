// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include "Progmasoft/Tala/Analysis/Dominance.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"

namespace tala::xmm
{
    // Xmm preserves Xpp block identity, but it owns its terminator enum. This
    // adapter makes that boundary explicit and keeps structural facts shared.
    [[nodiscard]] auto
    AnalyzeControlStructure(const Function &function)
        -> Progmasoft::Tala::Analysis::DominanceResult;
} // namespace tala::xmm
