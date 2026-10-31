/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 *
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

 */

#include "Progmasoft/Tala/Support/CompilerStack.hpp"
#include "Talac/Cli/Commands/Commands.hpp"

int
main(int argc, char **argv)
{
    // Every command runs on the compiler stack: the nesting limits of the
    // frontend are stated against its size, not against the stack the
    // operating system gives the process.
    return Progmasoft::Tala::Support::RunOnCompilerStack([argc, argv] {
        return Progmasoft::Tala::Cli::Run(argc, argv);
    });
}
