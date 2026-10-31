// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include "ExpressionExecutionCases.hpp"
#include "LeavingExecutionCases.hpp"
#include "Progmasoft/Tala/Support/CompilerStack.hpp"

// The executable regressions of two of the three large tables: every program
// of the expression and leaving tables runs through CorePrep, Xpp, Xmm, LLVM
// and the ORC JIT, unoptimized and optimized, and must return its expected
// value from both. The branching table is `source_execution_smoke`.
//
// The three tables were one program. Every run of a body passes its inputs
// as calls, so that no stage can fold them, and since arguments are passed by
// need each such argument is a suspended computation with code of its own.
// The programs grew with that, and under the sanitizers the one program ran
// past its process watchdog with every case passing. A watchdog is meant to
// end a run that never finishes, not to bound the size of a test table, so
// the tables are two programs and the watchdog is what it was.

namespace
{
    int
    Smoke()
    {
        // Hand-written results for assignments and increments used as values
        // and for loops used as expressions.
        Progmasoft::Tala::Fuzzing::ExerciseExpressionCases();
        // Hand-written results for expressions that leave instead of
        // yielding a value.
        Progmasoft::Tala::Fuzzing::ExerciseLeavingCases();
        return 0;
    }
} // namespace

int
main()
{
    // The compiler runs on the stack it runs on in `talac`.
    return Progmasoft::Tala::Support::RunOnCompilerStack([] {
        return Smoke();
    });
}
