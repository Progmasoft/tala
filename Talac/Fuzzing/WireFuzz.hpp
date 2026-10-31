// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace Progmasoft::Tala::Fuzzing
{
    // The first byte selects a wire format; the remaining bytes are untrusted.
    // This entry point is shared by the deterministic CI runner and libFuzzer.
    void
    ExerciseWire(std::span<const std::uint8_t> input);

    [[nodiscard]] auto
    WireSeeds() -> std::vector<std::vector<std::uint8_t>>;
} // namespace Progmasoft::Tala::Fuzzing
