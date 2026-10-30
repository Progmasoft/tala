// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "Progmasoft/Tala/Backend/LLVM.hpp"

namespace Progmasoft::Tala::Driver
{
    /// The program that links an executable.
    enum class Linker : std::uint8_t
    {
        /// `lld-link`, for every Windows target on every host.
        LldLink,
        /// `cc`, the C compiler of the host, for a target of the host. It
        /// knows where the C library and its start-up objects are.
        HostDriver,
        /// `clang` with the target triple and LLD, for a Linux, macOS or
        /// BSD target that is not the host. The system root tells it where
        /// the target's C library is.
        CrossDriver,
    };

    /// What a link is planned from. Triples are LLVM target triples as the
    /// backend resolved them; the host triple is the one talac runs on.
    struct LinkPlanRequest final
    {
        std::filesystem::path outputPath;
        std::vector<std::filesystem::path> objectPaths;
        std::string targetTriple;
        std::string hostTriple;
        std::optional<std::filesystem::path> sysroot;
        /// Whether the program takes TalaRT from its shared library, which
        /// stands beside the executable, rather than from the archive.
        bool sharedRuntime{ true };
        /// TalaRT of the target, when it was found: the archive, or the
        /// shared library.
        std::optional<std::filesystem::path> runtimeLibrary;
        /// For a Windows target: the import library of what the program
        /// takes from the system. With the archive these are the kernel32
        /// functions TalaRT calls; with `talart.dll`, the functions of
        /// TalaRT itself. The link writes it first.
        std::optional<std::filesystem::path> systemImports;
    };

    /// The program, its arguments and, for a Windows target, the machine
    /// the import library of the system functions is written for.
    struct LinkPlan final
    {
        Linker linker{ Linker::HostDriver };
        std::string program;
        std::vector<std::string> arguments;
        std::string machine;
        /// The shared library of TalaRT, which is copied beside the
        /// executable after a link that uses it.
        std::optional<std::filesystem::path> besideExecutable;
    };

    /// A plan, or why the target cannot be linked.
    struct LinkPlanResult final
    {
        std::optional<LinkPlan> plan;
        std::string diagnostic;
    };

    /// The object format a target's objects are written in.
    [[nodiscard]] auto
    TargetObjectFormat(std::string_view triple) -> Backend::LLVM::ObjectFormat;

    /// Whether the target is not the host: another architecture or another
    /// operating system.
    [[nodiscard]] auto
    IsCrossTarget(std::string_view target, std::string_view host) -> bool;

    /// The file name of TalaRT for a target: the archive, or the shared
    /// library.
    [[nodiscard]] auto
    RuntimeLibraryName(std::string_view triple, bool shared)
        -> std::string_view;

    /// Where the runtime of a target that is not the host is installed,
    /// relative to the directory of the compiler: `runtimes/<triple>`.
    [[nodiscard]] auto
    CrossRuntimeDirectory(std::string_view triple) -> std::filesystem::path;

    /// Choose the linker and its arguments. Nothing is run and no file is
    /// touched, so every target can be planned on every host.
    [[nodiscard]] auto
    PlanLink(const LinkPlanRequest &request) -> LinkPlanResult;
} // namespace Progmasoft::Tala::Driver
