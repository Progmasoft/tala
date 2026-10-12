// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <array>
#include <filesystem>
#include <limits>
#include <mutex>
#include <optional>
#include <string>
#include <system_error>
#include <utility>

#include "Progmasoft/Tala/Frontend.h"
#include "Talac/Cli/Commands/Frontend.hpp"

#ifdef _WIN32
#    include <windows.h>
#elif defined(__APPLE__)
#    include <dlfcn.h>
#    include <mach-o/dyld.h>
#else
#    include <dlfcn.h>
#    include <unistd.h>
#endif

namespace Progmasoft::Tala::Cli::Frontend
{
    namespace
    {
        constexpr std::size_t kMaximumArgumentBytes
            = std::size_t{ 1024U } * 1024U;
        constexpr std::size_t kMaximumCoreBytes
            = std::size_t{ 64U } * 1024U * 1024U;
        constexpr std::size_t kMaximumDiagnosticBytes
            = std::size_t{ 16U } * 1024U * 1024U;
        constexpr std::size_t kMaximumSourceListBytes
            = std::size_t{ 64U } * 1024U * 1024U;

        using AbiVersionFunction = std::uint32_t (*)();
        using InitializeFunction = std::int32_t (*)();
        using ShutdownFunction = void (*)();
        using ExecuteFunction = std::int32_t (*)(const std::uint8_t *,
                                                 std::size_t,
                                                 tala_frontend_output_callback,
                                                 void *);
        using FuzzSyntaxFunction = std::int32_t (*)(std::uint32_t,
                                                    const std::uint8_t *,
                                                    std::size_t);
        using CompileSourceFunction
            = std::int32_t (*)(const std::uint8_t *,
                               std::size_t,
                               tala_frontend_output_callback,
                               void *);
        using FuzzCompileFunction
            = std::int32_t (*)(const std::uint8_t *,
                               std::size_t,
                               tala_frontend_output_callback,
                               void *);

        struct CapturedOutput final
        {
            std::optional<OutputKind> kind;
            std::vector<std::uint8_t> bytes;
            std::string error;
            // Only the testing route sets this. It lets one CorePrep payload
            // follow a Core payload; every other route keeps the
            // single-payload contract.
            bool acceptCorePrep{};
            std::optional<std::vector<std::uint8_t>> corePrep;
            // Warning text of a successful request. It arrives before the
            // payload and at most once.
            std::optional<std::string> warnings;
        };

        auto
        CaptureOutput(void *context,
                      std::uint32_t rawKind,
                      const std::uint8_t *bytes,
                      std::size_t size) noexcept -> std::int32_t;

        [[nodiscard]] auto
        ExecutableDirectory() -> std::optional<std::filesystem::path>
        {
#ifdef _WIN32
            std::wstring buffer(32768U, L'\0');
            const DWORD length
                = GetModuleFileNameW(nullptr,
                                     buffer.data(),
                                     static_cast<DWORD>(buffer.size()));
            if (length == 0U || length >= buffer.size())
                return std::nullopt;
            buffer.resize(length);
            return std::filesystem::path(buffer).parent_path();
#elif defined(__APPLE__)
            std::uint32_t size{};
            (void)_NSGetExecutablePath(nullptr, &size);
            if (size == 0U || size > 32768U)
                return std::nullopt;
            std::string buffer(size, '\0');
            if (_NSGetExecutablePath(buffer.data(), &size) != 0)
                return std::nullopt;
            std::error_code error;
            const auto absolute
                = std::filesystem::canonical(buffer.c_str(), error);
            return error ? std::nullopt : std::optional(absolute.parent_path());
#else
            std::error_code error;
            const auto executable
                = std::filesystem::read_symlink("/proc/self/exe", error);
            return error ? std::nullopt
                         : std::optional(executable.parent_path());
#endif
        }

        [[nodiscard]] auto
        LibraryName() -> std::filesystem::path
        {
#ifdef _WIN32
            return L"tala-frontend.dll";
#elif defined(__APPLE__)
            return "libtala-frontend.dylib";
#else
            return "libtala-frontend.so";
#endif
        }

        class SharedFrontend final
        {
        public:
            SharedFrontend()
            {
                const auto directory = ExecutableDirectory();
                if (!directory)
                {
                    error_ = "could not determine the running executable "
                             "directory";
                    return;
                }
                const auto libraryPath = *directory / LibraryName();
#ifdef _WIN32
                // Restrict dependency lookup to the loaded DLL's directory and
                // standard Windows locations; never search cwd or a project.
                handle_
                    = LoadLibraryExW(libraryPath.c_str(),
                                     nullptr,
                                     LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR
                                         | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
                if (handle_ == nullptr)
                {
                    error_ = "could not load adjacent tala-frontend.dll "
                             "(Windows error "
                             + std::to_string(GetLastError()) + ")";
                    return;
                }
                const auto resolve = [this](const char *name) {
                    return reinterpret_cast<void *>(
                        GetProcAddress(static_cast<HMODULE>(handle_), name));
                };
#else
                handle_ = dlopen(libraryPath.c_str(), RTLD_NOW | RTLD_LOCAL);
                if (handle_ == nullptr)
                {
                    // The loader is used on this thread only, before any
                    // other thread exists.
                    // NOLINTNEXTLINE(concurrency-mt-unsafe)
                    const char *const message = dlerror();
                    error_ = "could not load adjacent frontend library: ";
                    error_ += message == nullptr ? "unknown loader error"
                                                 : message;
                    return;
                }
                const auto resolve = [this](const char *name) {
                    return dlsym(handle_, name);
                };
#endif
                abiVersion_ = reinterpret_cast<AbiVersionFunction>(
                    resolve("tala_frontend_abi_version"));
                initialize_ = reinterpret_cast<InitializeFunction>(
                    resolve("tala_frontend_initialize"));
                shutdown_ = reinterpret_cast<ShutdownFunction>(
                    resolve("tala_frontend_shutdown"));
                execute_ = reinterpret_cast<ExecuteFunction>(
                    resolve("tala_frontend_execute"));
                fuzzSyntax_ = reinterpret_cast<FuzzSyntaxFunction>(
                    resolve("tala_frontend_fuzz_syntax"));
                compileSource_ = reinterpret_cast<CompileSourceFunction>(
                    resolve("tala_frontend_compile_source"));
                fuzzCompile_ = reinterpret_cast<FuzzCompileFunction>(
                    resolve("tala_frontend_fuzz_compile"));
                if (abiVersion_ == nullptr || initialize_ == nullptr
                    || shutdown_ == nullptr || execute_ == nullptr
                    || fuzzSyntax_ == nullptr || compileSource_ == nullptr
                    || fuzzCompile_ == nullptr)
                {
                    error_ = "frontend library is missing a required ABI v2 "
                             "symbol";
                    Close();
                    return;
                }
                if (initialize_() != 0)
                {
                    error_ = "Haskell frontend RTS initialization failed";
                    Close();
                    return;
                }
                initialized_ = true;
                // Even the version function is a Haskell `foreign export` and
                // enters the RTS. Initialize before calling any exported
                // function, then shut down cleanly if the ABI is incompatible.
                if (abiVersion_() != 2U)
                {
                    error_ = "frontend library ABI version is incompatible";
                    shutdown_();
                    initialized_ = false;
                    Close();
                    return;
                }
            }

            SharedFrontend(const SharedFrontend &) = delete;
            auto
            operator=(const SharedFrontend &) -> SharedFrontend & = delete;

            ~SharedFrontend()
            {
                if (initialized_ && shutdown_ != nullptr)
                {
                    shutdown_();
                    // This is a process-owned runtime, not a reloadable plugin.
                    // Keep its DSO and dependencies mapped until process exit:
                    // GHC/base retain process-lifetime allocator caches after
                    // hs_exit. Unmapping their roots turns those bounded caches
                    // into unreachable allocations at LeakSanitizer teardown.
                    // The normal leak check stays enabled and can still inspect
                    // the mapped allocator and any genuinely lost allocations.
                    return;
                }
                Close();
            }

            [[nodiscard]] auto
            IsReady() const noexcept -> bool
            {
                return initialized_;
            }

            [[nodiscard]] auto
            Error() const noexcept -> const std::string &
            {
                return error_;
            }

            [[nodiscard]] auto
            Execute(const std::uint8_t *arguments,
                    std::size_t argumentSize,
                    CapturedOutput &output) const -> std::int32_t
            {
                return execute_(arguments,
                                argumentSize,
                                CaptureOutput,
                                &output);
            }

            [[nodiscard]] auto
            FuzzSyntax(std::uint32_t stage,
                       const std::uint8_t *source,
                       std::size_t sourceSize) const -> std::int32_t
            {
                return fuzzSyntax_(stage, source, sourceSize);
            }

            [[nodiscard]] auto
            FuzzCompile(const std::uint8_t *source,
                        std::size_t sourceSize,
                        CapturedOutput &output) const -> std::int32_t
            {
                return fuzzCompile_(source, sourceSize, CaptureOutput, &output);
            }

            [[nodiscard]] auto
            CompileSource(const std::uint8_t *source,
                          std::size_t sourceSize,
                          CapturedOutput &output) const -> std::int32_t
            {
                return compileSource_(source,
                                      sourceSize,
                                      CaptureOutput,
                                      &output);
            }

        private:
            void
            Close() noexcept
            {
                if (handle_ == nullptr)
                    return;
#ifdef _WIN32
                FreeLibrary(static_cast<HMODULE>(handle_));
#else
                dlclose(handle_);
#endif
                handle_ = nullptr;
            }

            void *handle_{};
            std::string error_;
            AbiVersionFunction abiVersion_{};
            InitializeFunction initialize_{};
            ShutdownFunction shutdown_{};
            ExecuteFunction execute_{};
            FuzzSyntaxFunction fuzzSyntax_{};
            CompileSourceFunction compileSource_{};
            FuzzCompileFunction fuzzCompile_{};
            bool initialized_{};
        };

        [[nodiscard]] auto
        GetFrontend() -> SharedFrontend &
        {
            static SharedFrontend frontend;
            return frontend;
        }

        auto
        CaptureOutput(void *context,
                      std::uint32_t rawKind,
                      const std::uint8_t *bytes,
                      std::size_t size) noexcept -> std::int32_t
        {
            if (context == nullptr || rawKind > 5U
                || (size != 0U && bytes == nullptr))
                return 1;
            auto &captured = *static_cast<CapturedOutput *>(context);
            if (static_cast<OutputKind>(rawKind) == OutputKind::WarningText)
            {
                // Warnings never stand for a result: they are accepted once
                // and only while no payload has been delivered.
                if (captured.kind.has_value() || captured.warnings.has_value()
                    || size > kMaximumDiagnosticBytes)
                {
                    captured.error = "frontend emitted an unexpected warning "
                                     "payload";
                    return 1;
                }
                captured.warnings.emplace(reinterpret_cast<const char *>(bytes),
                                          size);
                return 0;
            }
            if (static_cast<OutputKind>(rawKind) == OutputKind::CorePrepWire)
            {
                // CorePrep is accepted once, only after Core, and only on
                // the route that asked for it.
                if (!captured.acceptCorePrep
                    || captured.kind != OutputKind::CoreWire
                    || captured.corePrep.has_value()
                    || size > kMaximumCoreBytes)
                {
                    captured.error = "frontend emitted an unexpected CorePrep "
                                     "payload";
                    return 1;
                }
                captured.corePrep.emplace(bytes, bytes + size);
                return 0;
            }
            if (captured.kind.has_value())
            {
                captured.error
                    = "frontend emitted more than one output payload";
                return 1;
            }
            const auto kind = static_cast<OutputKind>(rawKind);
            const std::size_t maximum
                = kind == OutputKind::CoreWire         ? kMaximumCoreBytes
                  : kind == OutputKind::DiagnosticWire ? kMaximumDiagnosticBytes
                  : kind == OutputKind::ProjectSourceList
                      ? kMaximumSourceListBytes
                      : kMaximumDiagnosticBytes;
            if (size > maximum)
            {
                captured.error
                    = "frontend output exceeded its per-kind byte limit";
                return 1;
            }
            captured.kind = kind;
            if (size != 0U)
                captured.bytes.assign(bytes, bytes + size);
            return 0;
        }

        [[nodiscard]] auto
        MakeResult(std::int32_t rawStatus, CapturedOutput output) -> Result
        {
            Result result;
            result.status = static_cast<Status>(rawStatus);
            result.kind = output.kind.value_or(OutputKind::ErrorText);
            result.bytes = std::move(output.bytes);
            result.error = std::move(output.error);
            if (output.warnings)
                result.warnings = std::move(*output.warnings);
            if (rawStatus < 0 || rawStatus > 4)
            {
                result.status = Status::InternalError;
                result.error = "frontend returned an unknown status value";
            }
            if (result.error.empty() && result.kind == OutputKind::ErrorText)
                result.error.assign(result.bytes.begin(), result.bytes.end());
            if (!output.kind.has_value() && result.error.empty())
                result.error = "frontend returned without an output payload";
            return result;
        }

        [[nodiscard]] auto
        BuildArgumentBlob(std::span<const std::string> arguments,
                          std::vector<std::uint8_t> &blob) -> bool
        {
            if (arguments.empty() || arguments.size() > 1024U)
                return false;
            std::size_t required{};
            for (const auto &argument : arguments)
            {
                if (argument.empty() || argument.find('\0') != std::string::npos
                    || argument.size() >= kMaximumArgumentBytes - required)
                    return false;
                required += argument.size() + 1U;
            }
            blob.reserve(required);
            for (const auto &argument : arguments)
            {
                blob.insert(blob.end(), argument.begin(), argument.end());
                blob.push_back(0U);
            }
            return true;
        }
    } // namespace

    auto
    Execute(std::span<const std::string> arguments) -> Result
    {
        auto &frontend = GetFrontend();
        if (!frontend.IsReady())
            return { Status::InternalError,
                     OutputKind::ErrorText,
                     {},
                     frontend.Error(),
                     {} };
        std::vector<std::uint8_t> blob;
        if (!BuildArgumentBlob(arguments, blob))
            return {
                Status::InvalidRequest,
                OutputKind::ErrorText,
                {},
                "private frontend arguments are empty, malformed, or too large",
                {}
            };
        CapturedOutput output;
        const auto status = frontend.Execute(blob.data(), blob.size(), output);
        return MakeResult(status, std::move(output));
    }

    auto
    CompileSource(std::span<const std::uint8_t> source) -> Result
    {
        auto &frontend = GetFrontend();
        if (!frontend.IsReady())
            return { Status::InternalError,
                     OutputKind::ErrorText,
                     {},
                     frontend.Error(),
                     {} };
        if (source.size() > kMaximumArgumentBytes)
            return { Status::InvalidRequest,
                     OutputKind::ErrorText,
                     {},
                     "source exceeds the 1 MiB in-memory compile limit",
                     {} };
        CapturedOutput output;
        const auto status
            = frontend.CompileSource(source.data(), source.size(), output);
        return MakeResult(status, std::move(output));
    }

    auto
    FuzzSyntax(std::uint32_t stage, std::span<const std::uint8_t> source)
        -> bool
    {
        auto &frontend = GetFrontend();
        if (!frontend.IsReady())
            return false;
        if (stage > 1U)
            return false;
        return frontend.FuzzSyntax(stage, source.data(), source.size()) <= 1;
    }

    auto
    FuzzCompile(std::span<const std::uint8_t> source) -> Result
    {
        auto &frontend = GetFrontend();
        if (!frontend.IsReady())
            return { Status::InternalError,
                     OutputKind::ErrorText,
                     {},
                     frontend.Error(),
                     {} };
        CapturedOutput output;
        output.acceptCorePrep = true;
        const auto status
            = frontend.FuzzCompile(source.data(), source.size(), output);
        return MakeResult(status, std::move(output));
    }

    auto
    FuzzCompileStages(std::span<const std::uint8_t> source) -> StageResult
    {
        auto &frontend = GetFrontend();
        if (!frontend.IsReady())
            return { { Status::InternalError,
                       OutputKind::ErrorText,
                       {},
                       frontend.Error(),
                       {} },
                     {} };
        CapturedOutput output;
        output.acceptCorePrep = true;
        const auto status
            = frontend.FuzzCompile(source.data(), source.size(), output);
        auto corePrep = std::move(output.corePrep);
        StageResult result{ MakeResult(status, std::move(output)), {} };
        if (result.core.succeeded() && result.core.kind == OutputKind::CoreWire)
        {
            if (!corePrep)
            {
                result.core.status = Status::InternalError;
                result.core.error
                    = "frontend delivered Core without its CorePrep lowering";
                return result;
            }
            result.corePrep = std::move(*corePrep);
        }
        return result;
    }
} // namespace Progmasoft::Tala::Cli::Frontend
