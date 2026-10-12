// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <optional>

namespace Progmasoft::Tala::Cli::ExecutionStatus
{
    struct Outcome final
    {
        bool built{};
        std::optional<int> nativeExitStatus;
    };

    // Compilation and execution are separate outcomes. In particular, a native
    // program's nonzero exit status is not a compiler failure code and must
    // reach the caller unchanged after a successful build.
    [[nodiscard]] auto
    Resolve(const Outcome &outcome) noexcept -> int;
} // namespace Progmasoft::Tala::Cli::ExecutionStatus
