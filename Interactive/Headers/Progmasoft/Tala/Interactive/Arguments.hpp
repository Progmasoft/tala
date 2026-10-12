// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>
#include <string>

namespace Progmasoft::Tala::Interactive
{
    enum class RequestKind : std::uint8_t
    {
        Repl,
        Evaluate,
        Help,
        Error
    };

    struct Request final
    {
        RequestKind kind{ RequestKind::Repl };
        std::string expression;
        std::string diagnostic;
    };

    /** Parse the deliberately small public tali command line. */
    [[nodiscard]] auto
    ParseArguments(int argc, char **argv) -> Request;

    void
    PrintHelp();
} // namespace Progmasoft::Tala::Interactive
