// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cerrno>
#include <fstream>
#include <system_error>
#include <utility>

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

// The environment of the process, which the linker driver inherits. macOS
// does not declare it in a header; glibc does.
// NOLINTNEXTLINE(readability-redundant-declaration)
extern char **environ;
#endif

namespace Progmasoft::Tala::Driver
{
    namespace
    {
        [[nodiscard]] auto
        ValidateRequest(const NativeLinkRequest &request) -> std::string
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
            if (request.sysroot)
            {
#if defined(_WIN32)
                return "--sysroot has nothing to name for a Windows "
                       "executable, which links no system library";
#else
                std::error_code error;
                if (!std::filesystem::is_directory(*request.sysroot, error))
                    return "the system root '" + request.sysroot->string()
                           + "' is not a directory";
#endif
            }
#if defined(_WIN32)
            if (request.objectFormat != Backend::LLVM::ObjectFormat::Coff)
                return "the Windows native linker requires COFF object input";
#elif defined(__APPLE__)
            if (request.objectFormat != Backend::LLVM::ObjectFormat::MachO)
                return "the macOS native linker requires Mach-O object input";
#else
            if (request.objectFormat != Backend::LLVM::ObjectFormat::Elf)
                return "the Linux native linker requires ELF object input";
#endif
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

#ifdef _WIN32
        /// Runs `lld-link` with the given arguments and waits for it.
        ///
        /// Owning strings remain separate from argv pointers, so that growth
        /// of one vector cannot invalidate memory passed to `_wspawnvp`.
        [[nodiscard]] auto
        RunLinker(const std::vector<std::wstring> &options) -> std::intptr_t
        {
            const std::wstring program = L"lld-link.exe";
            std::vector<const wchar_t *> arguments;
            arguments.reserve(options.size() + 2U);
            arguments.push_back(program.c_str());
            for (const auto &option : options)
                arguments.push_back(option.c_str());
            arguments.push_back(nullptr);
            return _wspawnvp(_P_WAIT, program.c_str(), arguments.data());
        }

        /// The runtime library, when it stands beside the running program.
        ///
        /// `tala-runtime.lib` is installed with the compiler, in the directory
        /// of its executable, as the frontend library is.
        [[nodiscard]] auto
        RuntimeLibrary() -> std::optional<std::filesystem::path>
        {
            std::wstring buffer(32768U, L'\0');
            const auto length
                = GetModuleFileNameW(nullptr,
                                     buffer.data(),
                                     static_cast<DWORD>(buffer.size()));
            if (length == 0U || length >= buffer.size())
                return std::nullopt;
            buffer.resize(length);
            auto candidate = std::filesystem::path(buffer).parent_path()
                             / L"tala-runtime.lib";
            std::error_code error;
            if (!std::filesystem::is_regular_file(candidate, error) || error)
                return std::nullopt;
            return candidate;
        }

        /// What the runtime library takes from the system: these functions of
        /// kernel32 and nothing else. The list is the one the runtime
        /// declares in `Talac/Runtime/Text/Platform.cpp` and
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

        /// Writes an import library for the functions of kernel32 the
        /// runtime uses, beside the output, and returns its path.
        ///
        /// An executable is linked without the libraries of a C runtime or
        /// of a Windows SDK, so there is no `kernel32.lib` to name. The
        /// linker makes an import library from a list of names, which is all
        /// that is needed to call a function of a system library.
        [[nodiscard]] auto
        WriteSystemImports(const std::filesystem::path &output,
                           Scratch &scratch,
                           std::string &diagnostic)
            -> std::optional<std::filesystem::path>
        {
            auto definition = output;
            definition += L".imports.def";
            auto library = output;
            library += L".imports.lib";
            scratch.paths.push_back(definition);
            scratch.paths.push_back(library);
            {
                std::ofstream stream(definition,
                                     std::ios::binary | std::ios::trunc);
                stream.write(
                    kSystemImports.data(),
                    static_cast<std::streamsize>(kSystemImports.size()));
                if (!stream)
                {
                    diagnostic = "could not write the list of system imports "
                                 "for the native link";
                    return std::nullopt;
                }
            }
#    if defined(_M_ARM64)
            const std::wstring machine = L"/machine:arm64";
#    else
            const std::wstring machine = L"/machine:x64";
#    endif
            const auto status = RunLinker({ L"/lib",
                                            L"/nologo",
                                            machine,
                                            L"/def:" + definition.wstring(),
                                            L"/out:" + library.wstring() });
            if (status != 0)
            {
                diagnostic
                    = status == -1
                          ? "could not start lld-link: "
                                + std::error_code(errno,
                                                  std::generic_category())
                                      .message()
                          : "lld-link could not make the import library of "
                            "the system functions; exit code "
                                + std::to_string(status);
                return std::nullopt;
            }
            return library;
        }
#else
        /// The name the runtime library is installed by, beside the compiler.
        constexpr const char *kRuntimeLibraryName = "libtala-runtime.a";

        /// The driver that links: the C compiler of the system. It knows
        /// where the C library, its start-up objects and, on macOS, the
        /// system libraries are, which a linker started directly would have
        /// to be told for every distribution.
        constexpr const char *kLinkerDriver = "cc";

        /// The directory of the running program.
        [[nodiscard]] auto
        ProgramDirectory() -> std::optional<std::filesystem::path>
        {
#    ifdef __APPLE__
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
#    else
            std::error_code error;
            auto resolved
                = std::filesystem::read_symlink("/proc/self/exe", error);
            if (error)
                return std::nullopt;
            return resolved.parent_path();
#    endif
        }

        /// The runtime library, when it stands beside the running program.
        [[nodiscard]] auto
        RuntimeLibrary() -> std::optional<std::filesystem::path>
        {
            const auto directory = ProgramDirectory();
            if (!directory)
                return std::nullopt;
            auto candidate = *directory / kRuntimeLibraryName;
            std::error_code error;
            if (!std::filesystem::is_regular_file(candidate, error) || error)
                return std::nullopt;
            return candidate;
        }

        /// Runs the linker driver with the given arguments and waits for it.
        /// Gives its exit status, or -1 with `errno` set when it could not
        /// be started or did not exit by itself.
        [[nodiscard]] auto
        RunLinker(std::vector<std::string> options) -> int
        {
            std::string program = kLinkerDriver;
            std::vector<char *> arguments;
            arguments.reserve(options.size() + 2U);
            arguments.push_back(program.data());
            for (auto &option : options)
                arguments.push_back(option.data());
            arguments.push_back(nullptr);
            pid_t process{};
            const int spawned = posix_spawnp(&process,
                                             program.c_str(),
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
        }
#endif
    } // namespace

    auto
    LinkNativeExecutable(const NativeLinkRequest &request) -> NativeLinkResult
    {
        if (auto diagnostic = ValidateRequest(request); !diagnostic.empty())
            return { -1, std::move(diagnostic) };

#ifdef _WIN32
        std::error_code removeError;
        // Replacement starts only after all inputs pass validation. If LLD
        // fails, no stale executable remains that could be mistaken for the
        // current build.
        std::filesystem::remove(request.outputPath, removeError);
        if (removeError)
            return { -1,
                     "could not replace the existing native executable: "
                         + removeError.message() };

        // The generated bridge is a freestanding PE entry and needs no C
        // runtime. Avoiding implicit default libraries keeps the executable
        // small, deterministic, and independent from Visual Studio's
        // compiler and linker binaries. What a program needs beyond its own
        // code is the Tala runtime library, which is linked the same
        // way, and through it a few functions of kernel32.
        std::vector<std::wstring> options{ L"/nologo",
                                           L"/entry:mainCRTStartup",
                                           L"/subsystem:console",
                                           L"/nodefaultlib",
                                           L"/out:"
                                               + request.outputPath.wstring() };
        options.reserve(options.size() + request.objectPaths.size() + 2U);
        for (const auto &object : request.objectPaths)
            options.push_back(object.wstring());

        // A program that creates no closure, uses no string and writes
        // nothing calls nothing of the runtime, and the linker takes
        // nothing from a library that is not called. When the library is
        // not installed, such a program still links; any other fails at an
        // unresolved runtime symbol, which the diagnostic below explains.
        Scratch scratch;
        const auto runtime = RuntimeLibrary();
        if (runtime)
        {
            std::string importDiagnostic;
            const auto imports = WriteSystemImports(request.outputPath,
                                                    scratch,
                                                    importDiagnostic);
            if (!imports)
                return { -1, std::move(importDiagnostic) };
            options.push_back(runtime->wstring());
            options.push_back(imports->wstring());
        }

        const auto status = RunLinker(options);
        // Waiting is deliberate: success cannot be reported, and `run` cannot
        // begin, until LLD has closed and finalized the PE image.
        if (status == -1)
            return {
                -1,
                "could not start lld-link: "
                    + std::error_code(errno, std::generic_category()).message()
            };
        if (status != 0)
            return { static_cast<int>(status),
                     "lld-link failed with exit code " + std::to_string(status)
                         + (runtime
                                ? std::string()
                                : std::string(
                                      "; the Tala runtime library "
                                      "tala-runtime.lib was not found beside "
                                      "the compiler, and a program that uses "
                                      "strings, closures or the console "
                                      "needs it")) };

        std::error_code sizeError;
        const auto size
            = std::filesystem::file_size(request.outputPath, sizeError);
        if (sizeError || size == 0U)
            return { -1, "lld-link did not produce a non-empty executable" };
        return { 0, {} };
#else
        std::error_code removeError;
        // Replacement starts only after all inputs pass validation. If the
        // link fails, no stale executable remains that could be mistaken for
        // the current build.
        std::filesystem::remove(request.outputPath, removeError);
        if (removeError)
            return { -1,
                     "could not replace the existing native executable: "
                         + removeError.message() };

        // The entry of a program is `main`, which the start-up code of the
        // C library calls. What a program needs beyond its own code is the
        // Tala runtime library and, through it, the C library.
        std::vector<std::string> options{ "-o", request.outputPath.string() };
        options.reserve(options.size() + request.objectPaths.size() + 2U);
        // The driver finds the C library and its start-up objects under the
        // system root; clang and GCC spell it the same way, and on macOS it
        // names the SDK.
        if (request.sysroot)
            options.push_back("--sysroot=" + request.sysroot->string());
        for (const auto &object : request.objectPaths)
            options.push_back(object.string());

        // A program that creates no closure, uses no string and writes
        // nothing calls nothing of the runtime. When the library is not
        // installed, such a program still links; any other fails at an
        // unresolved runtime symbol, which the diagnostic below explains.
        const auto runtime = RuntimeLibrary();
        if (runtime)
            options.push_back(runtime->string());

        const auto status = RunLinker(std::move(options));
        if (status == -1)
            return {
                -1,
                std::string("could not run the linker driver '") + kLinkerDriver
                    + "': "
                    + std::error_code(errno, std::generic_category()).message()
                    + "; a native executable is linked by the C compiler of "
                      "the system"
            };
        if (status != 0)
            return { status,
                     std::string("the linker driver '") + kLinkerDriver
                         + "' failed with exit code " + std::to_string(status)
                         + (runtime
                                ? std::string()
                                : std::string("; the Tala runtime library ")
                                      + kRuntimeLibraryName
                                      + " was not found beside the compiler, "
                                        "and a program that uses strings, "
                                        "closures or the console needs it") };

        std::error_code sizeError;
        const auto size
            = std::filesystem::file_size(request.outputPath, sizeError);
        if (sizeError || size == 0U)
            return { -1,
                     "the linker driver did not produce a non-empty "
                     "executable" };
        return { 0, {} };
#endif
    }
} // namespace Progmasoft::Tala::Driver
