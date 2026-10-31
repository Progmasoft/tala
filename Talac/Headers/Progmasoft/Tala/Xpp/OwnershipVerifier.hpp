// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <vector>

#include "Progmasoft/Tala/Xpp/Verifier.hpp"

namespace Progmasoft::Tala::Xpp
{
    // The module-level entry point lets the adapter distinguish direct function
    // symbols from register-backed closure values before running generic
    // ownership dataflow for each function body.
    [[nodiscard]] auto
    VerifyOwnership(const ::tala::xpp::Module &module)
        -> std::vector<VerificationIssue>;
} // namespace Progmasoft::Tala::Xpp
