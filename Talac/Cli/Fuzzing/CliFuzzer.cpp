// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstddef>
#include <cstdint>
#include <llvm/Support/ErrorHandling.h>
#include <span>
#include <string>
#include <vector>

#include "Talac/Cli/Arguments/Options.hpp"

extern "C" int
LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size)
{
    if (size > 16384U)
        return 0;
    std::vector<std::string> arguments{ "talac" };
    std::string word;
    for (const auto byte : std::span(data, size))
    {
        if (byte == 0U)
        {
            arguments.push_back(word);
            word.clear();
            if (arguments.size() == 128U)
                break;
        }
        else
            word.push_back(static_cast<char>(byte));
    }
    if (!word.empty())
        arguments.push_back(word);
    const auto original = arguments;
    std::vector<char *> argv;
    for (auto &argument : arguments)
        argv.push_back(argument.data());
    const auto first
        = ParseCommandLine(static_cast<int>(argv.size()), argv.data());
    const auto second
        = ParseCommandLine(static_cast<int>(argv.size()), argv.data());
    // Full typed-model equality checks defaults and override bits as well as
    // diagnostics. Parsing must never mutate borrowed argv storage.
    if (first != second || arguments != original)
        llvm::report_fatal_error(
            "CLI parsing is nondeterministic or mutated argv");
    if (first.result == CliParseResult::kError && first.diagnostic.empty())
        llvm::report_fatal_error("CLI rejected input without a diagnostic");
    if (first.result == CliParseResult::kReady && first.options.inputs.empty())
        llvm::report_fatal_error("CLI accepted a command line without input");
    // An executable made from Tala sources needs an entry and nothing else
    // may carry one; the parser is the only place that rule is enforced.
    if (first.result == CliParseResult::kReady)
    {
        const bool needsEntry
            = first.options.viPkgType == ViPkgType::kExecutable
              && first.options.input == BuildInput::kTala;
        if (needsEntry != first.options.entry.has_value())
            llvm::report_fatal_error(
                "CLI accepted an entry that does not fit the inputs");
    }
    return 0;
}
