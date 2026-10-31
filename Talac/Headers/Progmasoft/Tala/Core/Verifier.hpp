// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <string>
#include <vector>

#include "Progmasoft/Tala/Core/IR.hpp"

namespace Progmasoft::Tala::Core
{
    /// Core verifier finding attached to a function or symbol.
    struct VerificationIssue final
    {
        /// Stable identifier for the violated Core invariant.
        std::string code;
        /// Human-readable explanation for diagnostics and tests.
        std::string message;
        /// Function whose body or signature violates an invariant.
        SymbolId function{};
        /// Symbol involved in the issue, when it is symbol-specific.
        SymbolId symbol{};
    };

    /// Validate Core semantics before CorePrep or backend lowering.
    /// Structural wire decoding alone is not a semantic trust boundary.
    /// @param module Core module to verify.
    /// @return Ordered semantic issues; empty means the module is verified.
    [[nodiscard]] auto
    Verify(const Module &module) -> std::vector<VerificationIssue>;
} // namespace Progmasoft::Tala::Core
