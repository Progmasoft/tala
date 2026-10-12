// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <llvm/Support/raw_ostream.h>

#include "BranchingExecutionCases.hpp"
#include "Progmasoft/Tala/Support/CompilerStack.hpp"

// The executable regressions of the branching table: every program of it
// runs through CorePrep, Xpp, Xmm, LLVM and the ORC JIT, unoptimized and
// optimized, and must return its expected value from both. The expression
// and leaving tables are `source_expression_smoke`. They are programs of
// their own, beside `source_fuzz_smoke` and `source_feature_smoke`, because
// each is a deterministic check under one process watchdog, and a watchdog
// is meant to end a run that never finishes, not to bound the size of a
// test table.

namespace
{
    int
    Smoke()
    {
        // Hand-written results for match, if expressions and guard, and
        // the programs at the nesting limits of the frontend.
        Progmasoft::Tala::Fuzzing::ExerciseBranchingCases();
        return 0;
    }
} // namespace

int
main()
{
    // The programs include ones nested up to the frontend's limits, which
    // only compile on the stack the compiler runs on in `talac`.
    return Progmasoft::Tala::Support::RunOnCompilerStack([] {
        const auto result = Smoke();
        // What the compiler stack held for all of the above, the programs
        // at the nesting limits among them. The line is how the figure is
        // read on platforms where nobody measures by hand; zero means the
        // platform does not report it.
        llvm::errs() << "compiler stack committed: "
                     << Progmasoft::Tala::Support::CommittedStackBytes() / 1024U
                     << " KiB\n";
        return result;
    });
}
