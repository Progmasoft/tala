// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace Progmasoft::Tala::Driver
{
    /// Which of LLD's linkers runs: each writes one object format.
    enum class LldFlavor : std::uint8_t
    {
        Coff,  ///< `lld-link`, for Windows.
        Elf,   ///< `ld.lld`, for Linux and the BSDs.
        MachO, ///< `ld64.lld`, for macOS.
    };

    /// The exit code of a link and what LLD wrote while it ran.
    struct LldOutcome final
    {
        int exitCode{ 1 };
        std::string messages;
    };

    /// Run one of LLD's linkers inside talac, with the arguments that the
    /// linker of that name takes on its command line.
    [[nodiscard]] auto
    RunLld(LldFlavor flavor, const std::vector<std::string> &arguments)
        -> LldOutcome;

    /// Write a COFF import library for functions of a DLL, for the machine
    /// `lld-link` is told (`x64` or `arm64`). Gives an empty string on
    /// success and the reason otherwise.
    [[nodiscard]] auto
    WriteImportLibrary(const std::filesystem::path &library,
                       std::string_view dll,
                       const std::vector<std::string> &functions,
                       std::string_view machine) -> std::string;
} // namespace Progmasoft::Tala::Driver
