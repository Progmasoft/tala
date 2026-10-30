// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cerrno>
#include <fstream>
#include <llvm/ADT/SmallString.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/FileUtilities.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Program.h>
#include <llvm/TargetParser/Host.h>
#include <llvm/TargetParser/Triple.h>
#include <system_error>
#include <utility>

#include "Talac/Linker/LinkPlan.hpp"
#include "Talac/Linker/Lld.hpp"
#include "Talac/Linker/NativeLinker.hpp"

#ifdef _WIN32
#    ifndef WIN32_LEAN_AND_MEAN
#        define WIN32_LEAN_AND_MEAN
#    endif
#    ifndef NOMINMAX
#        define NOMINMAX
#    endif
#    include <process.h>
#    include <windows.h>
#else
#    include <spawn.h>
#    include <sys/wait.h>
#    ifdef __APPLE__
#        include <cstdint>
#        include <mach-o/dyld.h>
#    endif

// The environment of the process, which the linker inherits. macOS does
// not declare it in a header; glibc does.
// NOLINTNEXTLINE(readability-redundant-declaration)
extern char **environ;
#endif

// The link of an executable. What is linked, and with which program, is
// decided by the target in `LinkPlan.cpp`; this file runs the plan on the
// host: it finds the Tala runtime of the target beside the compiler, writes
// the import library of the system functions a Windows executable calls,
// and starts the linker.

namespace Progmasoft::Tala::Driver
{
    namespace
    {
        [[nodiscard]] auto
        ObjectFormatName(const Backend::LLVM::ObjectFormat format)
            -> std::string_view
        {
            switch (format)
            {
                case Backend::LLVM::ObjectFormat::Coff:
                    return "COFF";
                case Backend::LLVM::ObjectFormat::Elf:
                    return "ELF";
                case Backend::LLVM::ObjectFormat::MachO:
                    return "Mach-O";
                case Backend::LLVM::ObjectFormat::Wasm:
                    return "WebAssembly";
                case Backend::LLVM::ObjectFormat::Unknown:
                    break;
            }
            return "an unknown format";
        }

        [[nodiscard]] auto
        ValidateRequest(const NativeLinkRequest &request,
                        const std::string &target) -> std::string
        {
            // Validate the complete typed request before touching an older
            // output. A bad invocation must never destroy the last successfully
            // linked executable.
            if (request.outputPath.empty())
                return "native executable link requires an output path";
            if (request.objectPaths.empty())
                return "native executable link requires at least one object "
                       "file";
            // The executable of a host without an extension for programs
            // takes the bare name of its input. An object with that name
            // would be overwritten by its own link.
            for (const auto &object : request.objectPaths)
            {
                if (object == request.outputPath)
                    return "native executable output would overwrite one of "
                           "its object files";
            }
            // The objects are the target's: their format is the one its
            // triple names, whichever host links them.
            const auto expected = TargetObjectFormat(target);
            if (request.objectFormat != Backend::LLVM::ObjectFormat::Unknown
                && request.objectFormat != expected)
                return "the objects are "
                       + std::string(ObjectFormatName(request.objectFormat))
                       + ", but an executable for " + target
                       + " is linked from "
                       + std::string(ObjectFormatName(expected)) + " objects";
            if (request.sysroot)
            {
                std::error_code error;
                if (!std::filesystem::is_directory(*request.sysroot, error))
                    return "the system root '" + request.sysroot->string()
                           + "' is not a directory";
            }
            for (const auto &object : request.objectPaths)
            {
                std::error_code error;
                if (object.extension() != ".o"
                    || !std::filesystem::is_regular_file(object, error)
                    || error)
                    return "native executable link input is not a readable .o "
                           "object file";
            }
            return {};
        }

        /// The directory of the running compiler.
        [[nodiscard]] auto
        ProgramDirectory() -> std::optional<std::filesystem::path>
        {
#if defined(_WIN32)
            std::wstring buffer(32768U, L'\0');
            const auto length
                = GetModuleFileNameW(nullptr,
                                     buffer.data(),
                                     static_cast<DWORD>(buffer.size()));
            if (length == 0U || length >= buffer.size())
                return std::nullopt;
            buffer.resize(length);
            return std::filesystem::path(buffer).parent_path();
#elif defined(__APPLE__)
            std::uint32_t size = 0U;
            _NSGetExecutablePath(nullptr, &size);
            std::string buffer(size, '\0');
            if (_NSGetExecutablePath(buffer.data(), &size) != 0)
                return std::nullopt;
            buffer.resize(std::char_traits<char>::length(buffer.c_str()));
            std::error_code error;
            auto resolved = std::filesystem::canonical(buffer, error);
            if (error)
                return std::nullopt;
            return resolved.parent_path();
#else
            std::error_code error;
            auto resolved
                = std::filesystem::read_symlink("/proc/self/exe", error);
            if (error)
                return std::nullopt;
            return resolved.parent_path();
#endif
        }

        /// Where the runtime of a target is installed: beside the compiler
        /// for the host, in `runtimes/<triple>` beside it for another one.
        [[nodiscard]] auto
        RuntimeLocation(const std::string &target,
                        const std::string &host,
                        const bool shared) -> std::filesystem::path
        {
            const std::filesystem::path name{ std::string(
                RuntimeLibraryName(target, shared)) };
            const auto relative = IsCrossTarget(target, host)
                                      ? CrossRuntimeDirectory(target) / name
                                      : name;
            const auto directory = ProgramDirectory();
            return directory ? *directory / relative : relative;
        }

        [[nodiscard]] auto
        IsFile(const std::filesystem::path &path) -> bool
        {
            std::error_code error;
            return std::filesystem::is_regular_file(path, error) && !error;
        }

        /// Runs a program with UTF-8 arguments and waits for it. Gives its
        /// exit status, or -1 with `errno` set when it could not be started
        /// or did not exit by itself.
        [[nodiscard]] auto
        Run(const std::string &program, const std::vector<std::string> &options)
            -> int
        {
#ifdef _WIN32
            // Owning strings stay separate from the argv pointers, so that
            // growth of one vector cannot invalidate memory passed to
            // `_wspawnvp`.
            const auto wide = [](const std::string &text) {
                return std::filesystem::path(
                           std::u8string(text.begin(), text.end()))
                    .wstring();
            };
            const std::wstring executable = wide(program) + L".exe";
            std::vector<std::wstring> owned;
            owned.reserve(options.size());
            for (const auto &option : options)
                owned.push_back(wide(option));
            std::vector<const wchar_t *> arguments;
            arguments.reserve(owned.size() + 2U);
            arguments.push_back(executable.c_str());
            for (const auto &option : owned)
                arguments.push_back(option.c_str());
            arguments.push_back(nullptr);
            return static_cast<int>(
                _wspawnvp(_P_WAIT, executable.c_str(), arguments.data()));
#else
            std::string name = program;
            std::vector<std::string> owned = options;
            std::vector<char *> arguments;
            arguments.reserve(owned.size() + 2U);
            arguments.push_back(name.data());
            for (auto &option : owned)
                arguments.push_back(option.data());
            arguments.push_back(nullptr);
            pid_t process{};
            const int spawned = posix_spawnp(&process,
                                             name.c_str(),
                                             nullptr,
                                             nullptr,
                                             arguments.data(),
                                             environ);
            if (spawned != 0)
            {
                errno = spawned;
                return -1;
            }
            int status{};
            while (waitpid(process, &status, 0) < 0)
                if (errno != EINTR)
                    return -1;
            if (!WIFEXITED(status))
            {
                errno = ECHILD;
                return -1;
            }
            return WEXITSTATUS(status);
#endif
        }

        /// The arguments of a host link with the host's triple in front, so
        /// that clang asked for the command line answers for the target
        /// the objects were written for.
        [[nodiscard]] auto
        WithTarget(const std::string &target,
                   const std::vector<std::string> &arguments)
            -> std::vector<std::string>
        {
            std::vector<std::string> result{ "--target=" + target };
            result.insert(result.end(), arguments.begin(), arguments.end());
            return result;
        }

        [[nodiscard]] auto
        StartFailure(const std::string &program) -> std::string
        {
            return "could not run '" + program + "': "
                   + std::error_code(errno, std::generic_category()).message();
        }

        /// What the runtime library of a Windows executable takes from the
        /// system: these functions of kernel32 and nothing else. The list is
        /// the one the runtime declares in
        /// `Talac/Runtime/Text/Platform.cpp` and
        /// `Talac/Runtime/Freestanding/Freestanding.cpp`.
        constexpr std::string_view kSystemImports = "LIBRARY KERNEL32.dll\n"
                                                    "EXPORTS\n"
                                                    "    GetConsoleMode\n"
                                                    "    GetProcessHeap\n"
                                                    "    GetStdHandle\n"
                                                    "    HeapAlloc\n"
                                                    "    HeapFree\n"
                                                    "    WriteConsoleW\n"
                                                    "    WriteFile\n";

        /// What a Windows executable takes from `talart.dll`: the C ABI of
        /// TalaRT, which Documents/abi-manifest.json lists and verify-abi
        /// compares, and the memory functions generated code calls, which
        /// the executable does not carry when TalaRT is not in it.
        constexpr std::string_view kRuntimeImports
            = "LIBRARY talart.dll\n"
              "EXPORTS\n"
              "    tala_aarc_abi_version\n"
              "    tala_aarc_allocate\n"
              "    tala_aarc_copy_unowned\n"
              "    tala_aarc_copy_weak\n"
              "    tala_aarc_is_exact_type\n"
              "    tala_aarc_load_unowned\n"
              "    tala_aarc_lock_weak\n"
              "    tala_aarc_make_unowned\n"
              "    tala_aarc_make_weak\n"
              "    tala_aarc_release_strong\n"
              "    tala_aarc_release_unowned\n"
              "    tala_aarc_release_weak\n"
              "    tala_aarc_retain_strong\n"
              "    tala_aarc_string_literal\n"
              "    tala_console_write\n"
              "    tala_test_end\n"
              "    tala_test_fail\n"
              "    tala_test_finish\n"
              "    tala_test_status\n"
              "    tala_text_concat\n"
              "    tala_text_equals\n"
              "    tala_text_format_char\n"
              "    tala_text_format_floating\n"
              "    tala_text_format_signed\n"
              "    tala_text_format_string\n"
              "    tala_text_format_unsigned\n"
              "    tala_text_from_bool\n"
              "    tala_text_from_char\n"
              "    tala_text_from_signed\n"
              "    tala_text_from_unsigned\n"
              "    tala_text_newline\n"
              "    memcpy\n"
              "    memmove\n"
              "    memset\n";

        /// Removes the files of one link when it goes out of scope.
        struct Scratch final
        {
            std::vector<std::filesystem::path> paths;

            Scratch() = default;
            Scratch(const Scratch &) = delete;
            Scratch(Scratch &&) = delete;
            auto
            operator=(const Scratch &) -> Scratch & = delete;
            auto
            operator=(Scratch &&) -> Scratch & = delete;

            ~Scratch()
            {
                for (const auto &path : paths)
                {
                    std::error_code ignored;
                    std::filesystem::remove(path, ignored);
                }
            }
        };

        /// Writes the import library a list of imports describes, for the
        /// given machine, beside the output.
        ///
        /// A Windows executable is linked without the libraries of a C
        /// runtime or of a Windows SDK, so there is no `kernel32.lib` to
        /// name, and talart.dll comes with no import library. LLVM writes
        /// one from a list of names, which is all that is needed to call a
        /// function of a DLL, on any host.
        [[nodiscard]] auto
        WriteImports(const std::filesystem::path &output,
                     const std::string_view imports,
                     const std::string &machine,
                     Scratch &scratch,
                     std::string &diagnostic)
            -> std::optional<std::filesystem::path>
        {
            // The list is `LIBRARY <dll>`, `EXPORTS` and one name a line.
            std::string dll;
            std::vector<std::string> functions;
            std::size_t start = 0U;
            while (start < imports.size())
            {
                auto end = imports.find('\n', start);
                if (end == std::string_view::npos)
                    end = imports.size();
                auto line = imports.substr(start, end - start);
                start = end + 1U;
                while (!line.empty() && line.front() == ' ')
                    line.remove_prefix(1U);
                if (line.starts_with("LIBRARY "))
                    dll = std::string(line.substr(8U));
                else if (!line.empty() && line != "EXPORTS")
                    functions.emplace_back(line);
            }
            auto library = output;
            library += ".imports.lib";
            scratch.paths.push_back(library);
            diagnostic = WriteImportLibrary(library, dll, functions, machine);
            if (!diagnostic.empty())
                return std::nullopt;
            return library;
        }

        /// The linker's command line a C compiler driver would run for the
        /// given arguments, which it prints for `-###` without running
        /// anything. Nothing when the driver cannot be started or prints no
        /// linker.
        [[nodiscard]] auto
        DriverLinkerCommand(const std::string &driver,
                            const std::vector<std::string> &arguments)
            -> std::optional<std::vector<std::string>>
        {
            auto program = llvm::sys::findProgramByName(driver);
            if (!program)
                return std::nullopt;
            llvm::SmallString<128> output;
            if (llvm::sys::fs::createTemporaryFile("talac-driver",
                                                   "txt",
                                                   output))
                return std::nullopt;
            llvm::FileRemover remover(output);
            std::vector<llvm::StringRef> argv{ *program, "-###" };
            for (const auto &argument : arguments)
                argv.emplace_back(argument);
            const std::optional<llvm::StringRef> redirects[]
                = { llvm::StringRef(""), llvm::StringRef(""), output.str() };
            if (llvm::sys::ExecuteAndWait(*program,
                                          argv,
                                          std::nullopt,
                                          redirects)
                != 0)
                return std::nullopt;
            auto text = llvm::MemoryBuffer::getFile(output);
            if (!text)
                return std::nullopt;
            return LinkerCommandOf((*text)->getBuffer());
        }
    } // namespace

    auto
    LinkNativeExecutable(const NativeLinkRequest &request) -> NativeLinkResult
    {
        const auto host = llvm::sys::getDefaultTargetTriple();
        const auto target = request.targetTriple.empty()
                                ? host
                                : llvm::Triple::normalize(request.targetTriple);
        if (auto diagnostic = ValidateRequest(request, target);
            !diagnostic.empty())
            return { -1, std::move(diagnostic) };

        LinkPlanRequest planRequest{ request.outputPath,
                                     request.objectPaths,
                                     target,
                                     host,
                                     request.sysroot,
                                     request.sharedRuntime,
                                     std::nullopt,
                                     std::nullopt };
        // A program that creates no closure, uses no string and writes
        // nothing calls nothing of the runtime, and the linker takes nothing
        // from a library that is not called. When the library is not
        // installed, such a program still links; any other fails at an
        // unresolved runtime symbol, which the diagnostic below explains.
        const auto runtime
            = RuntimeLocation(target, host, request.sharedRuntime);
        if (IsFile(runtime))
            planRequest.runtimeLibrary = runtime;
        // The plan is made once without the import library to learn the
        // machine, which the import library is written for.
        auto planned = PlanLink(planRequest);
        if (!planned.plan)
            return { -1, std::move(planned.diagnostic) };

        std::error_code removeError;
        // Replacement starts only after all inputs pass validation. If the
        // link fails, no stale executable remains that could be mistaken for
        // the current build.
        std::filesystem::remove(request.outputPath, removeError);
        if (removeError)
            return { -1,
                     "could not replace the existing native executable: "
                         + removeError.message() };

        Scratch scratch;
        if (planned.plan->linker == Linker::LldLink
            && planRequest.runtimeLibrary)
        {
            std::string importDiagnostic;
            const auto imports = WriteImports(
                request.outputPath,
                request.sharedRuntime ? kRuntimeImports : kSystemImports,
                planned.plan->machine,
                scratch,
                importDiagnostic);
            if (!imports)
                return { -1, std::move(importDiagnostic) };
            planRequest.systemImports = imports;
            planned = PlanLink(planRequest);
            if (!planned.plan)
                return { -1, std::move(planned.diagnostic) };
        }

        const auto &plan = *planned.plan;
        // LLD inside talac links. A Windows executable needs nothing more
        // than the plan. Another target needs the start-up objects and the
        // C library a driver knows the places of: clang prints the command
        // line of its linker for `-###`, and LLD runs it. Only when no
        // clang is there to ask is a target of the host linked by its own
        // C compiler, which runs its own linker.
        std::optional<LldOutcome> linked;
        if (plan.linker == Linker::LldLink)
            linked = RunLld(LldFlavor::Coff, plan.arguments);
        else
        {
            const auto command = DriverLinkerCommand(
                plan.linker == Linker::CrossDriver ? plan.program
                                                   : std::string("clang"),
                plan.linker == Linker::CrossDriver
                    ? plan.arguments
                    : WithTarget(target, plan.arguments));
            if (command)
                linked = RunLld(TargetObjectFormat(target)
                                        == Backend::LLVM::ObjectFormat::MachO
                                    ? LldFlavor::MachO
                                    : LldFlavor::Elf,
                                std::vector<std::string>(command->begin() + 1,
                                                         command->end()));
            else if (plan.linker == Linker::CrossDriver)
                return { -1,
                         "could not ask '" + plan.program + "' how to link for "
                             + target
                             + "; an executable for another target needs "
                               "clang to know where the target's C library "
                               "is" };
        }
        if (linked)
        {
            if (linked->exitCode != 0)
                return { linked->exitCode,
                         "LLD could not link the executable:\n"
                             + linked->messages
                             + (planRequest.runtimeLibrary
                                    ? std::string()
                                    : "the Tala runtime library was not found "
                                      "at "
                                          + runtime.string()
                                          + ", and a program that uses "
                                            "strings, closures, the console or "
                                            "tests needs it") };
        }
        const auto status = linked ? 0 : Run(plan.program, plan.arguments);
        // Waiting is deliberate: success cannot be reported, and `run` cannot
        // begin, until the linker has closed and finalized the image.
        if (status == -1)
            return { -1,
                     StartFailure(plan.program)
                         + (plan.linker == Linker::CrossDriver
                                ? "; an executable for another target is "
                                  "linked by clang with LLD"
                            : plan.linker == Linker::HostDriver
                                ? "; a native executable is linked by "
                                  "the C compiler of the system"
                                : "") };
        if (status != 0)
            return { status,
                     "'" + plan.program + "' failed with exit code "
                         + std::to_string(status)
                         + (planRequest.runtimeLibrary
                                ? std::string()
                                : "; the Tala runtime library was not found at "
                                      + runtime.string()
                                      + ", and a program that uses strings, "
                                        "closures, the console or tests "
                                        "needs it") };

        std::error_code sizeError;
        const auto size
            = std::filesystem::file_size(request.outputPath, sizeError);
        if (sizeError || size == 0U)
            return { -1,
                     "'" + plan.program
                         + "' did not produce a non-empty executable" };

        // The executable finds the shared library of TalaRT beside itself.
        if (plan.besideExecutable)
        {
            const auto beside = request.outputPath.parent_path()
                                / plan.besideExecutable->filename();
            std::error_code same;
            if (!std::filesystem::equivalent(*plan.besideExecutable,
                                             beside,
                                             same))
            {
                std::error_code copyError;
                std::filesystem::copy_file(
                    *plan.besideExecutable,
                    beside,
                    std::filesystem::copy_options::overwrite_existing,
                    copyError);
                if (copyError)
                    return { -1,
                             "could not put " + beside.filename().string()
                                 + " beside the executable: "
                                 + copyError.message() };
            }
        }
        return { 0, {} };
    }
} // namespace Progmasoft::Tala::Driver
