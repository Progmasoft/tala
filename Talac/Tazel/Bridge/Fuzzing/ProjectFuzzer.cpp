// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstddef>
#include <cstdint>
#include <llvm/Support/ErrorHandling.h>
#include <span>
#include <string>
#include <vector>

#include "Talac/Tazel/Bridge/ProjectDriver.hpp"

namespace
{
    void
    Check(std::span<const char> bytes)
    {
        namespace Driver = Progmasoft::Tala::Driver;
        const auto first = Driver::ParseProjectRegistry(bytes, false);
        if (first != Driver::ParseProjectRegistry(bytes, false))
            llvm::report_fatal_error(
                "project record decoding is nondeterministic");
        const auto required = Driver::ParseProjectRegistry(bytes, true);
        if (required
            && (!first
                || (required->executables.empty()
                    && required->libraries.empty())))
            llvm::report_fatal_error(
                "source-required project decoding lost its source contract");
    }
} // namespace

extern "C" int
LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size)
{
    if (size > 65536U)
        return 0;
    Check(std::span(reinterpret_cast<const char *>(data), size));
    // Reach past the version/header prefix on every input, including seeds
    // that mutate one count to SIZE_MAX. No evaluator or filesystem runs here.
    std::vector<std::string> records{ "tala-sources-v6",
                                      "0.4.0",
                                      "default",
                                      "llvm",
                                      "debug",
                                      "all",
                                      "true",
                                      "false",
                                      "false",
                                      "false",
                                      "true",
                                      "true",
                                      "true",
                                      "0",
                                      "aot",
                                      "none",
                                      "build/debug",
                                      "0",
                                      "1",
                                      "0",
                                      "0",
                                      "Application",
                                      "Example.Program",
                                      "Sources",
                                      "0" };
    if (size != 0U)
    {
        const auto selected
            = static_cast<std::size_t>(data[0]) % records.size();
        records[selected].assign(reinterpret_cast<const char *>(data + 1U),
                                 size - 1U);
    }
    std::string framed;
    for (const auto &record : records)
    {
        framed.append(record);
        framed.push_back('\0');
    }
    Check(framed);
    return 0;
}
