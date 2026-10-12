// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include "Progmasoft/Tala/Analysis/Dominance.hpp"
#include "Progmasoft/Tala/Xpp/IR.hpp"

namespace tala::xpp
{
    // Build the canonical native structural analysis for one verified Xpp
    // function. Optimizers consume this adapter instead of duplicating the
    // terminator-to-edge mapping and accidentally drifting from verifiers.
    [[nodiscard]] auto
    AnalyzeControlStructure(const Function &function)
        -> Progmasoft::Tala::Analysis::DominanceResult;
} // namespace tala::xpp
