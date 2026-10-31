// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <fmt/format.h>

#include "Progmasoft/Tala/Interactive/Arguments.hpp"

namespace Progmasoft::Tala::Interactive
{
    auto
    ParseArguments(int argc, char **argv) -> Request
    {
        if (argc == 1)
            return {};
        if (argc == 2
            && (std::string_view(argv[1]) == "--help"
                || std::string_view(argv[1]) == "-h"))
            return Request{ RequestKind::Help, {}, {} };
        if (argc == 3 && std::string_view(argv[1]) == "--eval")
        {
            if (argv[2][0] == '\0')
                return Request{ RequestKind::Error,
                                {},
                                "--eval requires a non-empty Tala expression" };
            return Request{ RequestKind::Evaluate, argv[2], {} };
        }
        if (argc >= 2 && std::string_view(argv[1]) == "--eval")
            return Request{ RequestKind::Error,
                            {},
                            "--eval accepts exactly one expression argument" };
        return Request{
            RequestKind::Error,
            {},
            fmt::format(
                "unknown or misplaced argument '{}'; use --help for usage",
                argc > 1 ? argv[1] : "")
        };
    }

    void
    PrintHelp()
    {
        fmt::print("Tala Interactive\n\n"
                   "Usage:\n"
                   "  tali\n"
                   "  tali --eval <expression>\n"
                   "  tali -Help\n\n"
                   "With no arguments, tali opens a persistent ORC LLJIT "
                   "session. Each complete input line is\n"
                   "compiled by the Tala Haskell frontend and lowered "
                   "through Core, CorePrep, Xpp, Xmm,\n"
                   "and LLVM before execution. The most recent supported "
                   "scalar result is available as `taliPrevious`.\n\n"
                   "REPL commands:\n"
                   "  :help                 show this help\n"
                   "  :type <expression>   compile and report the expression "
                   "type without running it\n"
                   "  :history              list successful input expressions\n"
                   "  :reset                clear results, history, and loaded "
                   "JIT modules\n"
                   "  :quit                 leave the REPL (EOF also exits)\n\n"
                   "The current host invocation ABI prints void, booleans, "
                   "characters, integers up to 64 bits,\n"
                   "and 32/64-bit floating values. Other Tala values are "
                   "type-checked but not yet callable\n"
                   "through the scalar REPL ABI.\n");
    }
} // namespace Progmasoft::Tala::Interactive
