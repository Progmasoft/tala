// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <vector>

#include "Progmasoft/Tala/Xmm/Verifier.hpp"

namespace Progmasoft::Tala::Xmm
{
    // Ownership verification is deliberately separate from structural Xmm
    // verification. The pass consumes already explicit AARC operations and
    // reasons about their control-flow lifetime without changing the IR.
    [[nodiscard]] auto
    VerifyOwnership(const ::tala::xmm::Function &function)
        -> std::vector<VerificationIssue>;
} // namespace Progmasoft::Tala::Xmm
