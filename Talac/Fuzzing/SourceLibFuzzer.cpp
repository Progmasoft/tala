// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstddef>
#include <cstdint>
#include <span>

#include "Progmasoft/Tala/Support/CompilerStack.hpp"
#include "SourceFuzz.hpp"

#ifndef TALA_SOURCE_FUZZ_STAGE
#    error TALA_SOURCE_FUZZ_STAGE must select one dedicated fuzz target
#endif

extern "C" int
LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size)
{
    const std::span<const std::uint8_t> input(data, size);
    // The compiler runs on its own stack, as it does in `talac`: an input
    // nested up to the frontend's limits must compile here as well, and the
    // stack libFuzzer calls this function on is the platform's default.
    Progmasoft::Tala::Support::RunOnCompilerStack([input] {
#if TALA_SOURCE_FUZZ_STAGE == 0
        Progmasoft::Tala::Fuzzing::ExerciseLexer(input);
#elif TALA_SOURCE_FUZZ_STAGE == 1
        Progmasoft::Tala::Fuzzing::ExerciseParser(input);
#elif TALA_SOURCE_FUZZ_STAGE == 2
        // Arbitrary source and generated arithmetic have independent corpora
        // and time budgets. An invalid source mutation should not pay for
        // two JITs.
        Progmasoft::Tala::Fuzzing::ExerciseSourceToLlvm(input);
#elif TALA_SOURCE_FUZZ_STAGE == 3
        Progmasoft::Tala::Fuzzing::ExerciseDifferentialOracle(input);
#else
#    error Unsupported TALA_SOURCE_FUZZ_STAGE
#endif
    });
    // Oracle invariant failures terminate directly. No exception can unwind
    // through the C ABI, and libFuzzer retains the reproducing input.
    return 0;
}
