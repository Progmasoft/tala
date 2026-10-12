// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <string>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"

namespace tala::core
{
    /// CorePrep verifier finding with a stable stage-specific code.
    struct VerificationIssue final
    {
        /// Stable issue identifier for tooling and diagnostics.
        std::string code;
        /// Human-readable explanation of the rejected CorePrep construct.
        std::string message;
        /// Function containing the invalid construct, when applicable.
        SymbolId function{};
        /// Block containing the invalid construct, when applicable.
        BlockId block{};
    };

    /// Validate CorePrep invariants before adaptation to Xpp.
    /// @param module CorePrep module to verify.
    /// @return Ordered issues; an empty vector denotes valid CorePrep.
    [[nodiscard]] auto
    verify(const CorePrepModule &module) -> std::vector<VerificationIssue>;
} // namespace tala::core
