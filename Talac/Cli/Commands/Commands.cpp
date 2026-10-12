// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fmt/format.h>
#include <fstream>
#include <iterator>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

#include "Talac/Cli/Arguments/Options.hpp"
#include "Talac/Cli/Commands/Commands.hpp"
#include "Talac/Cli/Commands/ExecutionStatus.hpp"
#include "Talac/Cli/Commands/Frontend.hpp"
#include "Talac/Cli/Presentation/Activity.hpp"
#include "Talac/Driver/CorePipeline.hpp"
#include "Talac/Linker/NativeLinker.hpp"
#include "Talac/Tazel/Bridge/ProjectDriver.hpp"

#ifdef _WIN32
#    include <process.h>
#    include <windows.h>
#else
#    include <spawn.h>
#    include <sys/wait.h>
#    include <unistd.h>
// macOS does not declare environ in a header; glibc does.
// NOLINTNEXTLINE(readability-redundant-declaration)
extern char **environ;
#endif

namespace
{
    [[nodiscard]] std::string
    PathText(const std::filesystem::path &path)
    {
#ifdef _WIN32
        const auto text = path.u8string();
        return std::string(reinterpret_cast<const char *>(text.data()),
                           text.size());
#else
        return path.string();
#endif
    }

#ifdef _WIN32
    [[nodiscard]] std::optional<std::wstring>
    Utf8ToWide(std::string_view text)
    {
        if (text.empty())
            return std::wstring{};
        const int length = MultiByteToWideChar(CP_UTF8,
                                               MB_ERR_INVALID_CHARS,
                                               text.data(),
                                               static_cast<int>(text.size()),
                                               nullptr,
                                               0);
        if (length <= 0)
            return std::nullopt;
        std::wstring result(static_cast<std::size_t>(length), L'\0');
        if (MultiByteToWideChar(CP_UTF8,
                                MB_ERR_INVALID_CHARS,
                                text.data(),
                                static_cast<int>(text.size()),
                                result.data(),
                                length)
            != length)
            return std::nullopt;
        return result;
    }

    /** Resolve an executable strictly from PATH, without an implicit
     * current-directory fallback. */
    [[nodiscard]] auto
    FindExecutableOnPath(std::wstring_view executable)
        -> std::optional<std::filesystem::path>
    {
        std::wstring pathValue;
        DWORD capacity = 256U;
        while (capacity < 32768U)
        {
            std::vector<wchar_t> buffer(capacity);
            const DWORD length
                = GetEnvironmentVariableW(L"PATH", buffer.data(), capacity);
            if (length == 0U)
                return std::nullopt;
            if (length < capacity)
            {
                pathValue.assign(buffer.data(), length);
                break;
            }
            capacity = length + 1U;
        }
        if (pathValue.empty())
            return std::nullopt;

        std::size_t start{};
        while (start <= pathValue.size())
        {
            const auto end = pathValue.find(L';', start);
            auto directory = std::wstring_view(pathValue).substr(
                start,
                end == std::wstring::npos ? std::wstring::npos : end - start);
            if (directory.size() >= 2U && directory.front() == L'"'
                && directory.back() == L'"')
                directory = directory.substr(1U, directory.size() - 2U);
            if (!directory.empty())
            {
                std::error_code error;
                auto candidate = std::filesystem::path(std::wstring(directory))
                                 / std::wstring(executable);
                if (std::filesystem::is_regular_file(candidate, error)
                    && !error)
                    return candidate;
            }
            if (end == std::wstring::npos)
                break;
            start = end + 1U;
        }
        return std::nullopt;
    }

    /** Quote one argv value for the Windows CRT parser used by the spawned
     * image. */
    [[nodiscard]] auto
    QuoteWindowsArgument(std::wstring_view argument) -> std::wstring
    {
        std::wstring quoted;
        quoted.push_back(L'"');
        std::size_t backslashes{};
        for (const auto character : argument)
        {
            if (character == L'\\')
            {
                ++backslashes;
                continue;
            }
            if (character == L'"')
            {
                quoted.append(backslashes * 2U + 1U, L'\\');
                quoted.push_back(L'"');
            }
            else
            {
                quoted.append(backslashes, L'\\');
                quoted.push_back(character);
            }
            backslashes = 0U;
        }
        quoted.append(backslashes * 2U, L'\\');
        quoted.push_back(L'"');
        return quoted;
    }
#else
    /** Resolve an executable strictly from non-empty PATH entries on POSIX
     * hosts. */
    [[nodiscard]] auto
    FindExecutableOnPath(std::string_view executable)
        -> std::optional<std::filesystem::path>
    {
        // Read on the calling thread; this process never modifies its
        // environment.
        // NOLINTNEXTLINE(concurrency-mt-unsafe)
        const auto *const environmentPath = std::getenv("PATH");
        if (environmentPath == nullptr)
            return std::nullopt;
        const std::string_view pathValue(environmentPath);
        std::size_t start{};
        while (start <= pathValue.size())
        {
            const auto end = pathValue.find(':', start);
            const auto directory = pathValue.substr(
                start,
                end == std::string_view::npos ? std::string_view::npos
                                              : end - start);
            if (!directory.empty())
            {
                auto candidate = std::filesystem::path(std::string(directory))
                                 / std::string(executable);
                std::error_code error;
                if (std::filesystem::is_regular_file(candidate, error) && !error
                    && ::access(candidate.c_str(), X_OK) == 0)
                    return candidate;
            }
            if (end == std::string_view::npos)
                break;
            start = end + 1U;
        }
        return std::nullopt;
    }
#endif

    [[nodiscard]] auto
    RunFileFrontend(const std::filesystem::path &source)
        -> Progmasoft::Tala::Cli::Frontend::Result
    {
        const std::vector<std::string> arguments{ "--source-file",
                                                  PathText(source) };
        return Progmasoft::Tala::Cli::Frontend::Execute(arguments);
    }

    [[nodiscard]] auto
    RunProjectFrontend(const Progmasoft::Tala::Driver::ResolvedProject &project)
        -> Progmasoft::Tala::Cli::Frontend::Result
    {
        std::error_code error;
        const auto projectRoot = std::filesystem::current_path(error);
        if (error)
        {
            fmt::print(
                stderr,
                "talac: could not resolve the project working directory: {}\n",
                error.message());
            return { Progmasoft::Tala::Cli::Frontend::Status::InternalError,
                     Progmasoft::Tala::Cli::Frontend::OutputKind::ErrorText,
                     {},
                     error.message(),
                     {} };
        }
        std::vector<std::string> arguments{ "--project-root",
                                            PathText(projectRoot),
                                            "--entry",
                                            project.entry };
        arguments.reserve(arguments.size() + project.sourceRoots.size() * 2
                          + project.sourceExcludes.size() * 2);
        for (const auto &root : project.sourceRoots)
        {
            arguments.push_back("--source-root");
            arguments.push_back(PathText(root));
        }
        for (const auto &pattern : project.sourceExcludes)
        {
            arguments.push_back("--exclude");
            arguments.push_back(pattern);
        }
        return Progmasoft::Tala::Cli::Frontend::Execute(arguments);
    }

    [[nodiscard]] auto
    ReadProjectSourceList(std::span<const std::uint8_t> bytes)
        -> std::optional<std::vector<std::filesystem::path>>
    {
        std::vector<std::filesystem::path> sources;
        std::size_t offset{};
        while (offset < bytes.size())
        {
            const auto begin
                = bytes.begin() + static_cast<std::ptrdiff_t>(offset);
            const auto end = std::find(begin, bytes.end(), 0U);
            if (end == bytes.end())
                return std::nullopt;
            const auto length = static_cast<std::size_t>(end - begin);
            if (length == 0U)
                return std::nullopt;
            const std::string_view encoded(
                reinterpret_cast<const char *>(bytes.data() + offset),
                length);
#ifdef _WIN32
            auto wide = Utf8ToWide(encoded);
            if (!wide)
                return std::nullopt;
            sources.emplace_back(std::move(*wide));
#else
            sources.emplace_back(encoded);
#endif
            offset += length + 1U;
        }
        return sources;
    }

    [[nodiscard]] auto
    ProjectSourceList(const Progmasoft::Tala::Driver::ResolvedProject &project)
        -> Progmasoft::Tala::Cli::Frontend::Result
    {
        std::error_code error;
        const auto projectRoot = std::filesystem::current_path(error);
        if (error)
            return { Progmasoft::Tala::Cli::Frontend::Status::InternalError,
                     Progmasoft::Tala::Cli::Frontend::OutputKind::ErrorText,
                     {},
                     error.message(),
                     {} };
        std::vector<std::string> arguments{ "--project-root",
                                            PathText(projectRoot),
                                            "--list-sources" };
        for (const auto &root : project.sourceRoots)
        {
            arguments.push_back("--source-root");
            arguments.push_back(PathText(root));
        }
        for (const auto &pattern : project.sourceExcludes)
        {
            arguments.push_back("--exclude");
            arguments.push_back(pattern);
        }
        return Progmasoft::Tala::Cli::Frontend::Execute(arguments);
    }

    auto
    FrontendSucceeded(const Progmasoft::Tala::Cli::Frontend::Result &result)
        -> bool
    {
        if (result.succeeded())
            return result.kind
                   != Progmasoft::Tala::Cli::Frontend::OutputKind::ErrorText;
        if (!result.bytes.empty())
            fmt::print(stderr,
                       "{}",
                       fmt::string_view(
                           reinterpret_cast<const char *>(result.bytes.data()),
                           result.bytes.size()));
        if (!result.error.empty())
            fmt::print(stderr, "talac: frontend: {}\n", result.error);
        return false;
    }

    /// Print the warnings of an accepted compilation and apply the warning
    /// policy. `-Warnings none` hides them; `-Werror true` fails the command
    /// after printing them, without changing what they say.
    [[nodiscard]] auto
    FrontendWarningsAllowed(
        const Progmasoft::Tala::Cli::Frontend::Result &result,
        const CompilerSettings &settings) -> bool
    {
        if (result.warnings.empty()
            || settings.warningLevel == WarningLevel::kNone)
            return true;
        fmt::print(stderr, "{}", result.warnings);
        if (!settings.warningsAsErrors)
            return true;
        fmt::print(stderr, "talac: warnings are treated as errors (-Werror)\n");
        return false;
    }

    [[nodiscard]] auto
    WriteCore(const std::filesystem::path &output,
              std::span<const std::uint8_t> bytes) -> bool
    {
        std::ofstream stream(output, std::ios::binary | std::ios::trunc);
        if (!stream)
        {
            fmt::print(stderr,
                       "talac: could not open Core artifact '{}' for writing\n",
                       PathText(output));
            return false;
        }
        stream.write(reinterpret_cast<const char *>(bytes.data()),
                     static_cast<std::streamsize>(bytes.size()));
        if (!stream)
        {
            fmt::print(stderr,
                       "talac: could not finish writing Core artifact '{}'\n",
                       PathText(output));
            return false;
        }
        fmt::print(stderr, "talac: wrote '{}'\n", PathText(output));
        return true;
    }

    [[nodiscard]] int
    RunInstalledTool(std::string_view executable,
                     std::span<const std::string> commandArguments)
    {
#ifdef _WIN32
        auto executableWide = Utf8ToWide(executable);
        if (!executableWide)
            return -1;
        const auto executablePath = FindExecutableOnPath(*executableWide);
        if (!executablePath)
        {
            fmt::print(stderr,
                       "talac: '{}' was not found on PATH\n",
                       executable);
            return -1;
        }
        std::vector<std::wstring> storage;
        storage.reserve(commandArguments.size() + 1);
        storage.push_back(executablePath->native());
        for (const auto &argument : commandArguments)
        {
            auto wide = Utf8ToWide(argument);
            if (!wide)
                return -1;
            storage.push_back(std::move(*wide));
        }
        std::wstring commandLine;
        for (const auto &argument : storage)
        {
            if (!commandLine.empty())
                commandLine.push_back(L' ');
            commandLine.append(QuoteWindowsArgument(argument));
        }
        if (commandLine.size() >= 32767U)
        {
            fmt::print(
                stderr,
                "talac: command line for '{}' exceeds the Windows process "
                "limit\n",
                executable);
            return -1;
        }
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process{};
        if (CreateProcessW(executablePath->c_str(),
                           commandLine.data(),
                           nullptr,
                           nullptr,
                           FALSE,
                           0,
                           nullptr,
                           nullptr,
                           &startup,
                           &process)
            == 0)
        {
            const auto error = GetLastError();
            fmt::print(
                stderr,
                "talac: could not start '{}': {}\n",
                executable,
                std::error_code(static_cast<int>(error), std::system_category())
                    .message());
            return -1;
        }
        CloseHandle(process.hThread);
        const auto waitStatus = WaitForSingleObject(process.hProcess, INFINITE);
        DWORD exitStatus{};
        const bool hasExitStatus
            = waitStatus == WAIT_OBJECT_0
              && GetExitCodeProcess(process.hProcess, &exitStatus) != 0;
        const DWORD waitError
            = waitStatus == WAIT_FAILED ? GetLastError() : ERROR_SUCCESS;
        CloseHandle(process.hProcess);
        if (!hasExitStatus)
        {
            if (waitError != ERROR_SUCCESS)
                fmt::print(stderr,
                           "talac: waiting for '{}' failed: {}\n",
                           executable,
                           std::error_code(static_cast<int>(waitError),
                                           std::system_category())
                               .message());
            else
                fmt::print(stderr,
                           "talac: could not read the exit status from '{}'\n",
                           executable);
            return -1;
        }
        return static_cast<int>(exitStatus);
#else
        const auto executablePath = FindExecutableOnPath(executable);
        if (!executablePath)
        {
            fmt::print(stderr,
                       "talac: '{}' was not found on PATH\n",
                       executable);
            return -1;
        }
        std::vector<std::string> storage;
        storage.reserve(commandArguments.size() + 1);
        storage.push_back(executablePath->string());
        storage.insert(storage.end(),
                       commandArguments.begin(),
                       commandArguments.end());
        std::vector<char *> arguments;
        arguments.reserve(storage.size() + 1);
        for (auto &argument : storage)
            arguments.push_back(argument.data());
        arguments.push_back(nullptr);
        pid_t process{};
        const int spawnStatus = posix_spawn(&process,
                                            storage.front().c_str(),
                                            nullptr,
                                            nullptr,
                                            arguments.data(),
                                            environ);
        if (spawnStatus != 0)
        {
            fmt::print(stderr,
                       "talac: could not start '{}': {}\n",
                       executable,
                       std::error_code(spawnStatus, std::generic_category())
                           .message());
            return -1;
        }
        int status{};
        if (waitpid(process, &status, 0) < 0)
            return -1;
        if (WIFEXITED(status))
            return WEXITSTATUS(status);
        // A program a signal ended has no exit status of its own. It is
        // reported the way a shell reports it, 128 and the signal, so that a
        // program that stopped is told apart from one that did not start.
        if (WIFSIGNALED(status))
            return 128 + WTERMSIG(status);
        return -1;
#endif
    }

    [[nodiscard]] int
    RunProjectTool(CliCommand command, bool formatterDryRun)
    {
        auto project = Progmasoft::Tala::Driver::ResolveProject(true);
        if (!project)
            return 1;
        const auto sourceList = ProjectSourceList(*project);
        if (!FrontendSucceeded(sourceList)
            || sourceList.kind
                   != Progmasoft::Tala::Cli::Frontend::OutputKind::
                       ProjectSourceList)
            return 1;
        auto sources = ReadProjectSourceList(sourceList.bytes);
        if (!sources)
        {
            fmt::print(stderr,
                       "talac: compiler frontend returned an invalid project "
                       "source list\n");
            return 1;
        }

        const bool formatting = command == CliCommand::kFormat;
#ifdef _WIN32
        const std::string executable
            = formatting ? "talafmt.exe" : "talalint.exe";
#else
        const std::string executable = formatting ? "talafmt" : "talalint";
#endif
        if (formatting)
        {
            // Project formatting is one tool invocation. Besides avoiding
            // repeated Kotlin startup, this gives talafmt one
            // authoritative DSL snapshot for the complete source set.
            std::vector<std::string> arguments;
            arguments.emplace_back(formatterDryRun ? "-Dry-Run" : "-In-Place");
            arguments.reserve(sources->size() + 1);
            for (const auto &source : *sources)
                arguments.push_back(PathText(source));
            const int status = RunInstalledTool(executable, arguments);
            if (status == -1)
            {
                fmt::print(stderr,
                           "talac: {} is not installed or is not available on "
                           "PATH; install Progmasoft.Talafmt\n",
                           executable);
                return 1;
            }
            return status == 0 ? 0 : 1;
        }

        bool succeeded = true;
        for (const auto &source : *sources)
        {
            // Child tools inherit the project-root working directory. Their
            // canonical talafmt.kts or talalint.kts lookup
            // therefore has one project-wide owner; when the corresponding file
            // is absent, the installed tool applies its own defaults.
            std::vector<std::string> arguments;
            arguments.push_back(PathText(source));
            const int status = RunInstalledTool(executable, arguments);
            if (status == -1)
            {
                fmt::print(stderr,
                           "talac: {} is not installed or is not available on "
                           "PATH; install Progmasoft.Talalint\n",
                           executable);
                return 1;
            }
            succeeded = status == 0 && succeeded;
        }
        return succeeded ? 0 : 1;
    }

    [[nodiscard]] std::filesystem::path
    OutputPath(const std::filesystem::path &input, std::string_view extension)
    {
        // Artifact naming is a filesystem operation, not a C string
        // manipulation concern. replace_extension handles dotted directories
        // and both separators.
        auto output = input;
        output.replace_extension(extension);
        return output;
    }

    [[nodiscard]] int
    ExecuteNative(const std::filesystem::path &executable,
                  std::span<const std::string> arguments)
    {
        // Check the exact artifact produced by this invocation. This prevents
        // `run` from starting an older executable after a failed build.
        std::error_code error;
        if (!std::filesystem::is_regular_file(executable, error) || error)
        {
            fmt::print(stderr,
                       "talac: native executable '{}' was not produced\n",
                       PathText(executable));
            return 1;
        }
        // The artifact is named relative to the working directory, and a
        // name without a directory would be looked for on PATH, where the
        // program just built is not. Start it by its absolute path.
        const auto absolute = std::filesystem::absolute(executable, error);
        if (error)
        {
            fmt::print(stderr,
                       "talac: could not resolve native executable '{}': {}\n",
                       PathText(executable),
                       error.message());
            return 1;
        }
        const int status = RunInstalledTool(PathText(absolute), arguments);
        if (status == -1)
        {
            fmt::print(
                stderr,
                "talac: could not start native executable '{}': {}\n",
                PathText(executable),
                std::error_code(errno, std::generic_category()).message());
            return 1;
        }
        if (status != 0)
            fmt::print(stderr,
                       "talac: native executable exited with status {}\n",
                       status);
        return status;
    }

    [[nodiscard]] int
    LinkObjectInput(const std::filesystem::path &object, bool execute)
    {
        // Direct object input is an advanced link route and accepts the
        // canonical Tala `.o` spelling rather than a host-specific `.obj`
        // alias.
        if (object.extension() != ".o")
        {
            fmt::print(stderr, "talac: -Build object requires a .o -File\n");
            return 2;
        }
        const auto executable = OutputPath(object, ".vxse");
        // An object given on the command line is taken to be one of this
        // host: nothing else can be linked here.
#if defined(_WIN32)
        const auto hostFormat
            = Progmasoft::Tala::Backend::LLVM::ObjectFormat::Coff;
#elif defined(__APPLE__)
        const auto hostFormat
            = Progmasoft::Tala::Backend::LLVM::ObjectFormat::MachO;
#else
        const auto hostFormat
            = Progmasoft::Tala::Backend::LLVM::ObjectFormat::Elf;
#endif
        const Progmasoft::Tala::Driver::NativeLinkRequest request{ executable,
                                                                   { object },
                                                                   hostFormat };
        const auto linked
            = Progmasoft::Tala::Driver::LinkNativeExecutable(request);
        if (!linked)
        {
            fmt::print(stderr,
                       "talac: native link failed: {}\n",
                       linked.diagnostic);
            return 1;
        }
        fmt::print(stderr,
                   "talac: linked native executable '{}'\n",
                   PathText(executable));
        return execute ? ExecuteNative(executable, {}) : 0;
    }

    [[nodiscard]] int
    ProcessSource(const std::filesystem::path &source,
                  const CliOptions &options,
                  const EffectiveCompilerOptions &effective)
    {
        if (source.extension() != ".tala")
        {
            fmt::print(stderr,
                       "talac: Haskell frontend input must be a .tala file\n");
            return 1;
        }
        const auto core = RunFileFrontend(source);
        if (!FrontendSucceeded(core)
            || core.kind
                   != Progmasoft::Tala::Cli::Frontend::OutputKind::CoreWire
            || !FrontendWarningsAllowed(core, effective.compiler))
            return 1;
        const auto sourceText = PathText(source);
        // Every source command crosses the same verified Core consumer. `check`
        // and artifact emission therefore cannot drift into separate validation
        // paths.
        if (options.command == CliCommand::kCheck)
            return Progmasoft::Tala::Cli::ExecutionStatus::Resolve({
                ProcessCoreBytesAs(core.bytes,
                                   sourceText.c_str(),
                                   sourceText.c_str(),
                                   options.command,
                                   effective.output,
                                   &effective.compiler,
                                   effective.target ? effective.target->c_str()
                                                    : nullptr),
                std::nullopt,
            });
        if (options.command != CliCommand::kBuild
            && options.command != CliCommand::kRun)
        {
            fmt::print(stderr,
                       "talac: this source command is not connected to the "
                       "compiler pipeline\n");
            return 1;
        }
        const auto output = options.command == CliCommand::kRun
                                ? BuildOutput::kBinary
                                : effective.output;
        if (output == BuildOutput::kCore)
            return Progmasoft::Tala::Cli::ExecutionStatus::Resolve(
                { WriteCore(OutputPath(source, ".core"), core.bytes),
                  std::nullopt });
        const bool built = ProcessCoreBytesAs(
            core.bytes,
            sourceText.c_str(),
            sourceText.c_str(),
            options.command,
            output,
            &effective.compiler,
            effective.target ? effective.target->c_str() : nullptr);
        if (!built)
            return Progmasoft::Tala::Cli::ExecutionStatus::Resolve(
                { false, std::nullopt });
        const auto nativeStatus = options.command == CliCommand::kRun
                                      ? std::optional<int>{ ExecuteNative(
                                            OutputPath(source, ".vxse"),
                                            options.programArguments) }
                                      : std::nullopt;
        return Progmasoft::Tala::Cli::ExecutionStatus::Resolve(
            { true, nativeStatus });
    }

    [[nodiscard]] int
    RunFile(const CliOptions &options)
    {
        const auto effective = ResolveCompilerOptions(options);
        if (options.input == BuildInput::kObject)
        {
            // Checking machine code would bypass all language and IR verifiers;
            // object input therefore belongs only to explicit build operations.
            if (options.command != CliCommand::kBuild)
            {
                fmt::print(
                    stderr,
                    "talac: check does not accept native object input\n");
                return 2;
            }
            return options.filePath ? LinkObjectInput(*options.filePath, false)
                                    : 2;
        }
        if (options.input == BuildInput::kCore)
        {
            if (!options.filePath || options.filePath->extension() != ".core")
            {
                fmt::print(stderr,
                           "talac: -Build core requires a .core -File\n");
                return 2;
            }
            const auto fileText = PathText(*options.filePath);
            const auto output = options.command == CliCommand::kRun
                                    ? BuildOutput::kBinary
                                    : effective.output;
            if (!ProcessCoreArtifact(
                    fileText.c_str(),
                    options.command,
                    output,
                    &effective.compiler,
                    effective.target ? effective.target->c_str() : nullptr))
                return 1;
            return options.command == CliCommand::kRun
                       ? ExecuteNative(OutputPath(*options.filePath, ".vxse"),
                                       options.programArguments)
                       : 0;
        }
        if (options.input == BuildInput::kXpp
            || options.input == BuildInput::kXmm)
        {
            const bool isXpp = options.input == BuildInput::kXpp;
            const std::string_view expectedExtension = isXpp ? ".xpp" : ".xmm";
            if (!options.filePath
                || options.filePath->extension() != expectedExtension)
            {
                fmt::print(stderr,
                           "talac: -Build {} requires a {} -File\n",
                           isXpp ? "xpp" : "xmm",
                           expectedExtension);
                return 2;
            }
            const auto output = options.command == CliCommand::kRun
                                    ? BuildOutput::kBinary
                                    : effective.output;
            if (output == BuildOutput::kCore
                || (!isXpp && output == BuildOutput::kXpp))
            {
                fmt::print(stderr,
                           "talac: compiler artifacts cannot be raised back to "
                           "an earlier pipeline stage\n");
                return 2;
            }
            const auto fileText = PathText(*options.filePath);
            const bool built
                = isXpp ? ProcessXppArtifactAs(fileText.c_str(),
                                               fileText.c_str(),
                                               options.command,
                                               output,
                                               &effective.compiler,
                                               effective.target
                                                   ? effective.target->c_str()
                                                   : nullptr)
                        : ProcessXmmArtifactAs(fileText.c_str(),
                                               fileText.c_str(),
                                               options.command,
                                               output,
                                               &effective.compiler,
                                               effective.target
                                                   ? effective.target->c_str()
                                                   : nullptr);
            if (!built)
                return 1;
            return options.command == CliCommand::kRun
                       ? ExecuteNative(OutputPath(*options.filePath, ".vxse"),
                                       options.programArguments)
                       : 0;
        }
        if (options.input != BuildInput::kTala)
        {
            fmt::print(
                stderr,
                "talac: only talac, core, xpp, and xmm inputs belong to the "
                "renewed pipeline\n");
            return 2;
        }
        return options.filePath
                   ? ProcessSource(*options.filePath, options, effective)
                   : 1;
    }

    [[nodiscard]] int
    RunExecutableTarget(
        const CliOptions &options,
        Progmasoft::Tala::Driver::ResolvedProject project,
        const Progmasoft::Tala::Driver::ResolvedSourceTarget &target,
        const EffectiveCompilerOptions &effective)
    {
        if (!target.entry)
        {
            fmt::print(stderr,
                       "talac: the selected executable target has no entry "
                       "class\n");
            return 1;
        }
        project.entry = *target.entry;
        project.sourceRoots = { target.root };
        project.sourceExcludes = target.excludes;

        const auto core = RunProjectFrontend(project);
        if (!FrontendSucceeded(core)
            || core.kind
                   != Progmasoft::Tala::Cli::Frontend::OutputKind::CoreWire
            || !FrontendWarningsAllowed(core, effective.compiler))
            return 1;

        std::error_code pathError;
        const auto workingDirectory = std::filesystem::current_path(pathError);
        if (pathError)
        {
            fmt::print(
                stderr,
                "talac: could not resolve the project artifact directory: {}\n",
                pathError.message());
            return 1;
        }
        const auto artifactBase
            = workingDirectory / project.outputDirectory / target.name;
        const auto coreSourceText = PathText(workingDirectory);
        const auto artifactBaseText = artifactBase.string();
        if (options.command == CliCommand::kCheck)
            return ProcessCoreBytesAs(
                       core.bytes,
                       coreSourceText.c_str(),
                       artifactBaseText.c_str(),
                       options.command,
                       effective.output,
                       &effective.compiler,
                       effective.target ? effective.target->c_str() : nullptr)
                       ? 0
                       : 1;
        std::filesystem::create_directories(artifactBase.parent_path(),
                                            pathError);
        if (pathError)
        {
            fmt::print(
                stderr,
                "talac: could not create project artifact directory '{}': {}\n",
                PathText(artifactBase.parent_path()),
                pathError.message());
            return 1;
        }
        const auto output = options.command == CliCommand::kRun
                                ? BuildOutput::kBinary
                                : effective.output;
        if (output == BuildOutput::kCore)
            return WriteCore(OutputPath(artifactBase, ".core"), core.bytes) ? 0
                                                                            : 1;
        if (output == BuildOutput::kObject || output == BuildOutput::kAssembly)
            return ProcessProjectCoreBytes(
                       core.bytes,
                       coreSourceText.c_str(),
                       artifactBase.parent_path(),
                       output,
                       &effective.compiler,
                       effective.target ? effective.target->c_str() : nullptr)
                       ? 0
                       : 1;
        if (!ProcessCoreBytesAs(core.bytes,
                                coreSourceText.c_str(),
                                artifactBaseText.c_str(),
                                options.command,
                                output,
                                &effective.compiler,
                                effective.target ? effective.target->c_str()
                                                 : nullptr))
            return 1;
        return options.command == CliCommand::kRun
                   ? ExecuteNative(OutputPath(artifactBase, ".vxse"),
                                   options.programArguments)
                   : 0;
    }

    [[nodiscard]] int
    RunProject(const CliOptions &options)
    {
        const bool testing = options.command == CliCommand::kTest;
        auto project = Progmasoft::Tala::Driver::ResolveProject(!testing);
        if (!project)
            return 1;
        if (testing)
        {
            fmt::print(stderr,
                       "talac: named test-suite execution requires the test "
                       "framework runner, which is not linked yet\n");
            return 1;
        }
        if (!options.selectedViPkgs.empty())
        {
            fmt::print(stderr,
                       "talac: -ViPkg selection requires the ViPkg assembly "
                       "stage, which is not linked yet\n");
            return 1;
        }
        if (!options.selectedLibraries.empty())
        {
            fmt::print(stderr,
                       "talac: library target selection requires the library "
                       "frontend route, which is not linked yet\n");
            return 1;
        }

        const EffectiveCompilerOptions projectDefaults{
            .compilerVersion = project->compilerVersion,
            .standard = project->standard,
            .target = std::nullopt,
            .output = project->output,
            .compiler = project->settings,
        };
        const auto effective
            = ResolveCompilerOptions(options, &projectDefaults);
        if (effective.target && !project->targets.empty()
            && std::find(project->targets.begin(),
                         project->targets.end(),
                         *effective.target)
                   == project->targets.end())
        {
            fmt::print(stderr,
                       "talac: target '{}' is not declared by BUILD.kts\n",
                       *effective.target);
            return 2;
        }
        if (options.command != CliCommand::kBuild
            && options.command != CliCommand::kRun
            && options.command != CliCommand::kCheck)
        {
            fmt::print(stderr,
                       "talac: this project command is not connected to the "
                       "compiler pipeline\n");
            return 1;
        }
        std::vector<const Progmasoft::Tala::Driver::ResolvedSourceTarget *>
            selected;
        if (options.selectedExecutables.empty())
        {
            for (const auto &target : project->executables)
                selected.push_back(&target);
        }
        else
        {
            for (const auto &name : options.selectedExecutables)
            {
                const auto found = std::find_if(project->executables.begin(),
                                                project->executables.end(),
                                                [&](const auto &target) {
                                                    return target.name == name;
                                                });
                if (found == project->executables.end())
                {
                    fmt::print(
                        stderr,
                        "talac: executable target '{}' is not declared by "
                        "BUILD.kts\n",
                        name);
                    return 2;
                }
                selected.push_back(&*found);
            }
        }
        if (selected.empty())
        {
            fmt::print(
                stderr,
                "talac: project does not declare an executable target\n");
            return 1;
        }
        for (const auto *target : selected)
            if (RunExecutableTarget(options, *project, *target, effective) != 0)
                return 1;
        return 0;
    }
} // namespace

auto
Progmasoft::Tala::Cli::Run(int argc, char **argv) -> int
{
    auto parsed = ParseCommandLine(argc, argv);
    if (parsed.result == CliParseResult::kHelp)
    {
        PrintCliHelp(parsed.helpCommand);
        return 0;
    }
    if (parsed.result == CliParseResult::kVersion)
    {
        PrintCliVersion();
        return 0;
    }
    if (parsed.result == CliParseResult::kError)
    {
        fmt::print(stderr, "talac: {}\n", parsed.diagnostic);
        return 2;
    }
    const auto &options = parsed.options;
    if (options.command == CliCommand::kInteractive)
        return RunInstalledTool(
#ifdef _WIN32
            "tali.exe",
#else
            "tali",
#endif
            options.interactiveArguments);
    if (options.emitHeader)
    {
        fmt::print(stderr,
                   "talac: -Header is reserved until the TCI export and ABI "
                   "contract is defined\n");
        return 2;
    }
    std::optional<Activity> activity;
    if (options.command == CliCommand::kBuild)
        activity.emplace("building compiler pipeline");
    else if (options.command == CliCommand::kCheck)
        activity.emplace("checking compiler pipeline");
    int result{};
    if (options.command == CliCommand::kResolve
        || options.command == CliCommand::kUpdate)
        result = Progmasoft::Tala::Driver::RefreshProjectLock() ? 0 : 1;
    else if (options.command == CliCommand::kFormat
             || options.command == CliCommand::kLint)
        result = RunProjectTool(options.command, options.formatterDryRun);
    else if (options.command == CliCommand::kInstall
             || options.command == CliCommand::kViGet
             || options.command == CliCommand::kViPkg)
    {
        const char *commandName
            = options.command == CliCommand::kInstall ? "install"
              : options.command == CliCommand::kViGet ? "viget"
                                                      : "vipkg";
        fmt::print(stderr,
                   "talac: {} requires the ViGet client, which is not linked "
                   "into this build yet\n",
                   commandName);
        result = 1;
    }
    else
        result = options.filePath ? RunFile(options) : RunProject(options);
    if (activity)
    {
        if (result == 0)
            activity->Complete(options.command == CliCommand::kBuild
                                   ? "build completed"
                                   : "check completed");
        else
            activity->Fail(options.command == CliCommand::kBuild
                               ? "build failed"
                               : "check failed");
    }
    return result;
}
