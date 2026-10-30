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
    struct NativeLinkRequest final
    {
        std::filesystem::path outputPath;
        std::vector<std::filesystem::path> objectPaths;
        Backend::LLVM::ObjectFormat objectFormat{
            Backend::LLVM::ObjectFormat::Unknown
        };
        /// The system root the linker driver links against, or none for
        /// the driver's own. A Windows executable links no system library
        /// and refuses one.
        std::optional<std::filesystem::path> sysroot;
        /// The LLVM target triple of the objects; empty for the host. The
        /// target, not the host, decides how the executable is linked.
        std::string targetTriple;
    };

    struct NativeLinkResult final
    {
        int exitCode{ -1 };
        std::string diagnostic;

        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return exitCode == 0 && diagnostic.empty();
        }
    };

    // LinkNativeExecutable links the objects for their target: lld-link for
    // Windows from any host, the host's C compiler for a target of the host,
    // and clang with LLD for another Linux, macOS or BSD target. It runs the
    // linker with a typed argv; no command shell, response-file parser, or
    // user-controlled command string sits between the compiler model and the
    // linker.
    [[nodiscard]] auto
    LinkNativeExecutable(const NativeLinkRequest &request) -> NativeLinkResult;
} // namespace Progmasoft::Tala::Driver
