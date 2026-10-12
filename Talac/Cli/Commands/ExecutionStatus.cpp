// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include "Talac/Cli/Commands/ExecutionStatus.hpp"

namespace Progmasoft::Tala::Cli::ExecutionStatus
{
    auto
    Resolve(const Outcome &outcome) noexcept -> int
    {
        if (!outcome.built)
            return 1;
        return outcome.nativeExitStatus.value_or(0);
    }
} // namespace Progmasoft::Tala::Cli::ExecutionStatus
