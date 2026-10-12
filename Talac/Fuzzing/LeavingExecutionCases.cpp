// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <array>
#include <string_view>

#include "ExecutionCases.hpp"
#include "LeavingExecutionCases.hpp"

// Executable regressions for expressions that leave instead of yielding a
// value: `return`, `break` and `continue` out of blocks used as values, in
// loop bodies, in the condition and the update clause of a loop, and in
// loops used as expressions. Each case is a method body, the arguments it
// runs on and the value it must return. The expected values are written by
// hand from the language rules: what precedes the transfer is evaluated
// once and in order, what follows it is not evaluated, `break` and
// `continue` target the nearest loop, a `break` in the condition or the
// update clause of a loop leaves that loop, a `continue` in the condition
// evaluates the condition again, and a `continue` in an update clause ends
// the update. The cases are written in `Cases/Leaving.cases`; the rows here
// and the list `leavingCases` that the frontend test suite runs in a
// reference evaluator are generated from that file by
// `go -C helpers run ./cmd/execution-cases generate`. Here every case runs
// through CorePrep, Xpp, Xmm, LLVM and the ORC JIT, unoptimized and
// optimized.

namespace Progmasoft::Tala::Fuzzing
{
    namespace
    {
        constexpr auto kCases = std::to_array<ExecutionCase>({
#include "Generated/LeavingCases.inc"
        });

        // The methods a body may call besides `Run` itself.
        constexpr std::string_view kHelpers
            = "    public static int Twice(_ int value) { return value + "
              "value; }\n";
    } // namespace

    void
    ExerciseLeavingCases()
    {
        ExerciseExecutionCases("Leaving execution", kCases, kHelpers);
    }
} // namespace Progmasoft::Tala::Fuzzing
