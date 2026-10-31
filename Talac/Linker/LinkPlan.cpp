// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <llvm/TargetParser/Triple.h>

#include "Talac/Linker/LinkPlan.hpp"

namespace Progmasoft::Tala::Driver
{
    namespace
    {
        // The programs and runtime libraries of each kind of target, which
        // Documents/abi-manifest.json states and verify-abi compares.
        constexpr std::string_view kWindowsLinker = "lld-link";
        constexpr std::string_view kWindowsRuntimeLibrary = "talart.lib";
        constexpr std::string_view kWindowsSharedRuntime = "talart.dll";
        constexpr std::string_view kLinkerDriver = "cc";
        constexpr std::string_view kCrossDriver = "clang";
        constexpr std::string_view kRuntimeLibraryName = "libtalart.a";
        constexpr std::string_view kElfSharedRuntime = "libtalart.so";
        constexpr std::string_view kMachOSharedRuntime = "libtalart.dylib";

        [[nodiscard]] auto
        TripleOf(std::string_view text) -> llvm::Triple
        {
            return llvm::Triple(llvm::Triple::normalize(text));
        }

        /// A path as UTF-8, the encoding every argument of a plan is in.
        [[nodiscard]] auto
        Utf8(const std::filesystem::path &path) -> std::string
        {
            const auto text = path.u8string();
            return { reinterpret_cast<const char *>(text.data()), text.size() };
        }

        /// The machine `lld-link` is told for a Windows target, or empty
        /// for an architecture the runtime is not built for.
        [[nodiscard]] auto
        WindowsMachine(const llvm::Triple &triple) -> std::string
        {
            switch (triple.getArch())
            {
                case llvm::Triple::x86_64:
                    return "x64";
                case llvm::Triple::aarch64:
                    return "arm64";
                default:
                    return {};
            }
        }

        /// The operating system, with every Darwin spelling as one.
        [[nodiscard]] auto
        SystemOf(const llvm::Triple &triple) -> llvm::Triple::OSType
        {
            return triple.isOSDarwin() ? llvm::Triple::Darwin : triple.getOS();
        }
    } // namespace

    auto
    TargetObjectFormat(const std::string_view triple)
        -> Backend::LLVM::ObjectFormat
    {
        switch (TripleOf(triple).getObjectFormat())
        {
            case llvm::Triple::COFF:
                return Backend::LLVM::ObjectFormat::Coff;
            case llvm::Triple::ELF:
                return Backend::LLVM::ObjectFormat::Elf;
            case llvm::Triple::MachO:
                return Backend::LLVM::ObjectFormat::MachO;
            case llvm::Triple::Wasm:
                return Backend::LLVM::ObjectFormat::Wasm;
            default:
                return Backend::LLVM::ObjectFormat::Unknown;
        }
    }

    auto
    IsCrossTarget(const std::string_view target, const std::string_view host)
        -> bool
    {
        const auto targetTriple = TripleOf(target);
        const auto hostTriple = TripleOf(host);
        // Another C library is another target as well: musl on a glibc
        // host needs the system root of musl.
        return targetTriple.getArch() != hostTriple.getArch()
               || SystemOf(targetTriple) != SystemOf(hostTriple)
               || (!targetTriple.isOSDarwin()
                   && targetTriple.getEnvironment()
                          != hostTriple.getEnvironment());
    }

    auto
    RuntimeLibraryName(const std::string_view triple, const bool shared)
        -> std::string_view
    {
        switch (TargetObjectFormat(triple))
        {
            case Backend::LLVM::ObjectFormat::Coff:
                return shared ? kWindowsSharedRuntime : kWindowsRuntimeLibrary;
            case Backend::LLVM::ObjectFormat::MachO:
                return shared ? kMachOSharedRuntime : kRuntimeLibraryName;
            default:
                return shared ? kElfSharedRuntime : kRuntimeLibraryName;
        }
    }

    auto
    CrossRuntimeDirectory(const std::string_view triple)
        -> std::filesystem::path
    {
        return std::filesystem::path("runtimes")
               / std::string(llvm::Triple::normalize(triple));
    }

    auto
    LinkerCommandOf(const std::string_view driverOutput)
        -> std::optional<std::vector<std::string>>
    {
        std::optional<std::vector<std::string>> found;
        std::size_t start = 0U;
        while (start < driverOutput.size())
        {
            auto end = driverOutput.find('\n', start);
            if (end == std::string_view::npos)
                end = driverOutput.size();
            auto line = driverOutput.substr(start, end - start);
            start = end + 1U;
            // Each command is one line of words in double quotes, with `\`
            // escaping a quote or a backslash inside one.
            std::vector<std::string> words;
            std::size_t index = 0U;
            bool wellFormed = true;
            while (index < line.size())
            {
                const auto character = line[index];
                if (character == ' ' || character == '\t' || character == '\r')
                {
                    ++index;
                    continue;
                }
                if (character != '"')
                {
                    wellFormed = false;
                    break;
                }
                std::string word;
                ++index;
                while (index < line.size() && line[index] != '"')
                {
                    if (line[index] == '\\' && index + 1U < line.size())
                        ++index;
                    word.push_back(line[index]);
                    ++index;
                }
                if (index >= line.size())
                {
                    wellFormed = false;
                    break;
                }
                ++index;
                words.push_back(std::move(word));
            }
            if (!wellFormed || words.empty())
                continue;
            // The name of the program, on whichever host wrote the path.
            std::string_view program = words.front();
            if (const auto slash = program.find_last_of("/\\");
                slash != std::string_view::npos)
                program.remove_prefix(slash + 1U);
            if (program.ends_with(".exe"))
                program.remove_suffix(4U);
            if (program == "ld" || program == "ld.lld" || program == "ld64.lld"
                || program == "ld64" || program == "ld.bfd"
                || program == "ld.gold")
                found = std::move(words);
        }
        return found;
    }

    auto
    PlanLink(const LinkPlanRequest &request) -> LinkPlanResult
    {
        const auto target = TripleOf(request.targetTriple);
        const auto format = TargetObjectFormat(request.targetTriple);
        LinkPlan plan;

        if (format == Backend::LLVM::ObjectFormat::Coff)
        {
            if (!target.isOSWindows())
                return { std::nullopt,
                         "the target " + target.str()
                             + " writes COFF objects but is not Windows; "
                               "talac links Windows executables only" };
            if (request.sysroot)
                return { std::nullopt,
                         "--sysroot has nothing to name for a Windows "
                         "executable, which links no system library" };
            plan.machine = WindowsMachine(target);
            if (plan.machine.empty())
                return { std::nullopt,
                         "a Windows executable for "
                             + target.getArchName().str()
                             + " is not linked yet; the targets are x86_64 and "
                               "aarch64" };
            // The generated bridge is a freestanding PE entry and needs no
            // C runtime. Avoiding implicit default libraries keeps the
            // executable small, deterministic and independent from Visual
            // Studio's compiler and linker binaries. What a program needs
            // beyond its own code is the Tala runtime library, linked the
            // same way, and through it a few functions of kernel32. Nothing
            // here depends on the host, so a Windows executable is linked
            // the same way from any of them.
            plan.linker = Linker::LldLink;
            plan.program = kWindowsLinker;
            plan.arguments = { "/nologo",
                               "/entry:mainCRTStartup",
                               "/subsystem:console",
                               "/nodefaultlib",
                               "/machine:" + plan.machine,
                               "/out:" + Utf8(request.outputPath) };
            for (const auto &object : request.objectPaths)
                plan.arguments.push_back(Utf8(object));
            // With the archive, the executable carries TalaRT and imports
            // kernel32 through the import library. With `talart.dll`, it
            // imports TalaRT through the import library of the DLL, and the
            // DLL imports kernel32 itself.
            if (request.runtimeLibrary)
            {
                if (!request.sharedRuntime)
                    plan.arguments.push_back(Utf8(*request.runtimeLibrary));
                else
                    plan.besideExecutable = request.runtimeLibrary;
                if (request.systemImports)
                    plan.arguments.push_back(Utf8(*request.systemImports));
            }
            return { std::move(plan), {} };
        }

        if (format != Backend::LLVM::ObjectFormat::Elf
            && format != Backend::LLVM::ObjectFormat::MachO)
            return { std::nullopt,
                     "talac does not link executables for " + target.str() };

        // The entry of a program is `main`, which the start-up code of the
        // C library calls. A target of the host is linked by the C compiler
        // of the host, which knows where that library is. Another target
        // is linked by clang, told the target and to link with LLD, which
        // can write every format; the system root says where the target's
        // C library and start-up objects are, and for macOS its SDK.
        if (IsCrossTarget(request.targetTriple, request.hostTriple))
        {
            plan.linker = Linker::CrossDriver;
            plan.program = kCrossDriver;
            plan.arguments = { "--target=" + target.str(), "-fuse-ld=lld" };
        }
        else
        {
            plan.linker = Linker::HostDriver;
            plan.program = kLinkerDriver;
        }
        // clang and GCC spell the system root the same way.
        if (request.sysroot)
            plan.arguments.push_back("--sysroot=" + Utf8(*request.sysroot));
        plan.arguments.push_back("-o");
        plan.arguments.push_back(Utf8(request.outputPath));
        for (const auto &object : request.objectPaths)
            plan.arguments.push_back(Utf8(object));
        if (request.runtimeLibrary)
        {
            plan.arguments.push_back(Utf8(*request.runtimeLibrary));
            // The shared library stands beside the executable, and the
            // executable looks for it there wherever it is moved with it.
            if (request.sharedRuntime)
            {
                plan.arguments.push_back(
                    format == Backend::LLVM::ObjectFormat::MachO
                        ? "-Wl,-rpath,@executable_path"
                        : "-Wl,-rpath,$ORIGIN");
                plan.besideExecutable = request.runtimeLibrary;
            }
        }
        return { std::move(plan), {} };
    }
} // namespace Progmasoft::Tala::Driver
