// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <cstddef>
#include <cstdint>

#include "WireFuzz.hpp"

// An instrumented libFuzzer driver supplies main and calls this entry point.
// It is deliberately not linked into the ordinary CI smoke executable.
extern "C" int
LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size)
{
    Progmasoft::Tala::Fuzzing::ExerciseWire({ data, size });
    return 0;
}
