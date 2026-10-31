// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"

namespace tala::core
{
    [[nodiscard]] auto
    verify_semantics(const CorePrepModule &module)
        -> std::vector<VerificationIssue>;
} // namespace tala::core
