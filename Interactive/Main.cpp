// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstddef>
#include <fmt/format.h>
#include <iostream>
#include <string>

#include "Progmasoft/Tala/Interactive/Arguments.hpp"
#include "Progmasoft/Tala/Interactive/ReplInput.hpp"
#include "Progmasoft/Tala/Interactive/Session.hpp"
#include "Progmasoft/Tala/Support/CompilerStack.hpp"

namespace
{
    constexpr std::size_t kMaximumInputLineBytes = std::size_t{ 1024U } * 1024U;

    [[nodiscard]] auto
    Repl() -> int
    {
        using namespace Progmasoft::Tala::Interactive;
        Session session;
        fmt::print("Tala Interactive (tali)\nType :help for commands; "
                   "Ctrl+D/Ctrl+Z exits.\n");
        std::string line;
        while (true)
        {
            fmt::print("tali> ");
            std::cout.flush();
            const auto inputStatus
                = ReadInputLine(std::cin, line, kMaximumInputLineBytes);
            if (inputStatus == InputLineStatus::End)
            {
                fmt::print("\n");
                return 0;
            }
            if (inputStatus == InputLineStatus::Failure)
            {
                fmt::print(stderr,
                           "tali: could not read the next input line\n");
                return 1;
            }
            if (inputStatus == InputLineStatus::TooLong)
            {
                fmt::print(stderr,
                           "tali: one Tala input line cannot exceed 1 MiB\n");
                continue;
            }
            if (!line.empty() && line.back() == '\r')
                line.pop_back();
            const auto command = ParseReplCommand(line);
            switch (command.kind)
            {
                case ReplCommandKind::Expression:
                    if (command.expression.empty())
                        continue;
                    break;
                case ReplCommandKind::Help:
                    PrintHelp();
                    continue;
                case ReplCommandKind::Type:
                {
                    const auto result = session.TypeOf(command.expression);
                    if (result.status == CellStatus::Type)
                        fmt::print("{}\n", result.text);
                    else
                        fmt::print(stderr, "tali: {}\n", result.text);
                    continue;
                }
                case ReplCommandKind::History:
                {
                    std::size_t number = 1U;
                    for (const auto &entry : session.History())
                        fmt::print("{:>4}  {}\n", number++, entry);
                    continue;
                }
                case ReplCommandKind::Reset:
                    if (const auto issue = session.Reset())
                        fmt::print(stderr, "tali: {}\n", *issue);
                    else
                        fmt::print("session values, JIT modules, and history "
                                   "cleared\n");
                    continue;
                case ReplCommandKind::Quit:
                    return 0;
                case ReplCommandKind::TypeMissingExpression:
                    fmt::print(stderr,
                               "tali: :type expects a Tala expression\n");
                    continue;
                case ReplCommandKind::Unknown:
                    fmt::print(stderr,
                               "tali: unknown REPL command '{}'; use :help\n",
                               line);
                    continue;
            }

            const auto result = session.Evaluate(command.expression);
            if (result.status == CellStatus::Value
                || result.status == CellStatus::Void)
                fmt::print("{}\n", result.text);
            else
                fmt::print(stderr, "tali: {}\n", result.text);
        }
    }
} // namespace

namespace
{
    auto
    RunMain(int argc, char **argv) -> int;
} // namespace

auto
main(int argc, char **argv) -> int
{
    // Cells are compiled on the compiler stack, as sources are in `talac`.
    return Progmasoft::Tala::Support::RunOnCompilerStack([argc, argv] {
        return RunMain(argc, argv);
    });
}

namespace
{
    auto
    RunMain(int argc, char **argv) -> int
    {
        using namespace Progmasoft::Tala::Interactive;
        const auto request = ParseArguments(argc, argv);
        switch (request.kind)
        {
            case RequestKind::Repl:
                return Repl();
            case RequestKind::Help:
                PrintHelp();
                return 0;
            case RequestKind::Error:
                fmt::print(stderr, "tali: {}\n", request.diagnostic);
                return 2;
            case RequestKind::Evaluate:
            {
                Session session;
                const auto result = session.Evaluate(request.expression);
                if (result.status != CellStatus::Value
                    && result.status != CellStatus::Void)
                {
                    fmt::print(stderr, "tali: {}\n", result.text);
                    return 1;
                }
                fmt::print("{}\n", result.text);
                return 0;
            }
        }
        return 2;
    }
} // namespace
