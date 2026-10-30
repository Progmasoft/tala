// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fmt/format.h>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "Progmasoft/Tala/Pipeline.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"
#include "Talac/Driver/CorePipeline.hpp"
#include "Talac/Driver/ProjectArtifacts.hpp"
#include "Talac/Linker/NativeLinker.hpp"

#ifdef _WIN32
#    include <process.h>
#else
#    include <unistd.h>
#endif

namespace
{
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Driver = Progmasoft::Tala::Driver;

    class TemporaryObject final
    {
    public:
        explicit TemporaryObject(const std::filesystem::path &artifactBase)
        {
            static std::atomic_uint64_t sequence{};
#ifdef _WIN32
            const auto process = static_cast<std::uint64_t>(_getpid());
#else
            const auto process = static_cast<std::uint64_t>(getpid());
#endif
            path_ = artifactBase.parent_path()
                    / (artifactBase.filename().string() + ".tala-link-"
                       + std::to_string(process) + "-"
                       + std::to_string(
                           sequence.fetch_add(1U, std::memory_order_relaxed))
                       + ".o");
        }

        TemporaryObject(const TemporaryObject &) = delete;
        auto
        operator=(const TemporaryObject &) -> TemporaryObject & = delete;

        ~TemporaryObject()
        {
            // Cleanup is best-effort and covers every return path, including a
            // failed link or a later output-validation diagnostic.
            std::error_code ignored;
            std::filesystem::remove(path_, ignored);
        }

        [[nodiscard]] auto
        Path() const -> const std::filesystem::path &
        {
            return path_;
        }

    private:
        std::filesystem::path path_;
    };

    [[nodiscard]] auto
    ReadFile(const std::filesystem::path &path)
        -> std::optional<std::vector<std::uint8_t>>
    {
        std::ifstream stream(path, std::ios::binary);
        if (!stream)
            return std::nullopt;
        return std::vector<std::uint8_t>(std::istreambuf_iterator<char>(stream),
                                         {});
    }

    [[nodiscard]] auto
    PathText(const std::filesystem::path &path) -> std::string
    {
        const auto text = path.u8string();
        return { reinterpret_cast<const char *>(text.data()), text.size() };
    }

    [[nodiscard]] auto
    Optimization(const CompilerSettings &settings) -> Llvm::OptimizationLevel
    {
        switch (settings.llvmOptLevel)
        {
            case LlvmOptLevel::kO0:
            case LlvmOptLevel::kOg:
                return Llvm::OptimizationLevel::Debug;
            case LlvmOptLevel::kO1:
                return Llvm::OptimizationLevel::Less;
            case LlvmOptLevel::kO2:
                return Llvm::OptimizationLevel::Default;
            case LlvmOptLevel::kO3:
                return Llvm::OptimizationLevel::Aggressive;
        }
        return Llvm::OptimizationLevel::Default;
    }

    void
    PrintFailure(const tala::PipelineResult &result)
    {
        if (result.coreWireError)
        {
            fmt::print(stderr,
                       "talac: Core artifact error at byte {} ({}): {}\n",
                       result.coreWireError->offset,
                       result.coreWireError->context,
                       result.coreWireError->message);
            return;
        }
        if (result.xppWireError)
        {
            fmt::print(stderr,
                       "talac: Xpp artifact error at byte {} ({}): {}\n",
                       result.xppWireError->offset,
                       result.xppWireError->context,
                       result.xppWireError->message);
            return;
        }
        if (result.xmmWireError)
        {
            fmt::print(stderr,
                       "talac: Xmm artifact error at byte {} ({}): {}\n",
                       result.xmmWireError->offset,
                       result.xmmWireError->context,
                       result.xmmWireError->message);
            return;
        }
        for (const auto &issue : result.coreVerificationIssues)
            fmt::print(stderr,
                       "talac: {}: {} [function={}, symbol={}]\n",
                       issue.code,
                       issue.message,
                       issue.function,
                       issue.symbol);
        for (const auto &issue : result.verification_issues)
            fmt::print(stderr,
                       "talac: {}: {} [function={}, block={}]\n",
                       issue.code,
                       issue.message,
                       issue.function,
                       issue.block);
        for (const auto &issue : result.xppVerificationIssues)
            fmt::print(
                stderr,
                "talac: {}: {} [Xpp function={}, block={}, instruction={}]\n",
                issue.code,
                issue.message,
                issue.function,
                issue.block,
                issue.instruction);
        for (const auto &issue : result.xmmVerificationIssues)
            fmt::print(
                stderr,
                "talac: {}: {} [Xmm function={}, block={}, instruction={}]\n",
                issue.code,
                issue.message,
                issue.function,
                issue.block,
                issue.instruction);
        if (result.llvm_error)
            fmt::print(stderr,
                       "talac: {}: {}\n",
                       result.llvm_error->code,
                       result.llvm_error->message);
    }

    [[nodiscard]] auto
    ArtifactPath(const char *inputPath, std::string_view extension)
        -> std::filesystem::path
    {
        // Project mode deliberately supplies an artifact base unrelated to the
        // temporary Core path, keeping generated files in the configured build
        // root.
        auto path = std::filesystem::path(inputPath);
        path.replace_extension(extension);
        return path;
    }

    [[nodiscard]] auto
    ReportWrite(const std::filesystem::path &path,
                const std::optional<Llvm::Error> &error) -> bool
    {
        if (error)
        {
            fmt::print(stderr, "talac: {}: {}\n", error->code, error->message);
            return false;
        }
        fmt::print(
            stderr,
            "talac: wrote '{}' from verified Core through CorePrep, Xpp, "
            "Xmm and LLVM\n",
            path.string());
        return true;
    }

    [[nodiscard]] auto
    WriteArtifact(const char *inputPath,
                  BuildOutput output,
                  const Llvm::Artifact &artifact) -> bool
    {
        if (output == BuildOutput::kLlvmIr)
        {
            const auto path = ArtifactPath(inputPath, ".ll");
            return ReportWrite(path, Llvm::WriteLlvmIr(path, artifact.llvm_ir));
        }
        if (output == BuildOutput::kLlvmBitcode)
        {
            const auto path = ArtifactPath(inputPath, ".bc");
            return ReportWrite(path,
                               Llvm::WriteBitcode(path, artifact.bitcode));
        }
        if (output == BuildOutput::kObject)
        {
            const auto path = ArtifactPath(inputPath, ".o");
            return ReportWrite(path, Llvm::WriteObject(path, artifact.object));
        }
        if (output == BuildOutput::kAssembly)
        {
            const auto path = ArtifactPath(inputPath, ".asm");
            return ReportWrite(path,
                               Llvm::WriteAssembly(path, artifact.assembly));
        }
        return false;
    }

    [[nodiscard]] auto
    WriteBytes(const std::filesystem::path &path,
               std::span<const std::uint8_t> bytes,
               std::string_view stage) -> bool
    {
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        if (!stream)
        {
            fmt::print(stderr,
                       "talac: could not open {} artifact '{}' for writing\n",
                       stage,
                       path.string());
            return false;
        }
        stream.write(reinterpret_cast<const char *>(bytes.data()),
                     static_cast<std::streamsize>(bytes.size()));
        if (!stream)
        {
            fmt::print(stderr,
                       "talac: could not finish writing {} artifact '{}'\n",
                       stage,
                       path.string());
            return false;
        }
        fmt::print(stderr,
                   "talac: wrote verified {} artifact '{}'\n",
                   stage,
                   path.string());
        return true;
    }

    [[nodiscard]] auto
    WriteIntermediate(const char *artifactBasePath,
                      BuildOutput output,
                      const tala::PipelineResult &result) -> bool
    {
        if (output == BuildOutput::kXpp && result.xpp)
        {
            auto encoded = Progmasoft::Tala::Xpp::Wire::Encode(*result.xpp);
            if (encoded.error)
            {
                fmt::print(stderr,
                           "talac: Xpp encode error at byte {} ({}): {}\n",
                           encoded.error->offset,
                           encoded.error->context,
                           encoded.error->message);
                return false;
            }
            return WriteBytes(ArtifactPath(artifactBasePath, ".xpp"),
                              encoded.bytes,
                              "Xpp");
        }
        if (output == BuildOutput::kXmm && result.xmm)
        {
            auto encoded = Progmasoft::Tala::Xmm::Wire::Encode(*result.xmm);
            if (encoded.error)
            {
                fmt::print(stderr,
                           "talac: Xmm encode error at byte {} ({}): {}\n",
                           encoded.error->offset,
                           encoded.error->context,
                           encoded.error->message);
                return false;
            }
            return WriteBytes(ArtifactPath(artifactBasePath, ".xmm"),
                              encoded.bytes,
                              "Xmm");
        }
        return false;
    }

    [[nodiscard]] auto
    WriteExecutable(const char *inputPath,
                    const Llvm::Artifact &artifact,
                    const char *sysroot) -> bool
    {
        const auto output
            = ArtifactPath(inputPath,
                           OutputExtension(BuildOutput::kExecutable));
        TemporaryObject temporary(inputPath);
        // Binary is one user-visible artifact. The object exists only long
        // enough for LLD and is never confused with an explicit `-Emit object`
        // request.
        if (const auto error
            = Llvm::WriteObject(temporary.Path(), artifact.object))
        {
            fmt::print(stderr, "talac: {}: {}\n", error->code, error->message);
            return false;
        }
        const Driver::NativeLinkRequest request{
            output,
            { temporary.Path() },
            artifact.objectFormat,
            sysroot != nullptr ? std::optional{ std::filesystem::path(sysroot) }
                               : std::nullopt
        };
        const auto linked = Driver::LinkNativeExecutable(request);
        if (!linked)
        {
            fmt::print(stderr,
                       "talac: native link failed: {}\n",
                       linked.diagnostic);
            return false;
        }
        fmt::print(stderr,
                   "talac: linked native executable '{}'\n",
                   output.string());
        return true;
    }
} // namespace

namespace
{
    enum class InputStage : std::uint8_t
    {
        Core,
        Xpp,
        Xmm
    };

    [[nodiscard]] auto
    ProcessArtifact(InputStage inputStage,
                    std::span<const std::uint8_t> bytes,
                    const char *sourceName,
                    const char *artifactBasePath,
                    PipelineAction action,
                    BuildOutput output,
                    const CompilerSettings *settings,
                    const char *targetTriple) -> bool
    {
        if (sourceName == nullptr || artifactBasePath == nullptr
            || settings == nullptr)
            return false;
        constexpr auto kMaximumArtifactBytes
            = std::uintmax_t{ 64U } * 1024U * 1024U;
        if (bytes.size() > kMaximumArtifactBytes)
        {
            fmt::print(stderr,
                       "talac: compiler artifact '{}' exceeds the 64 MiB input "
                       "limit\n",
                       sourceName);
            return false;
        }

        tala::PipelineOptions options;
        options.optimize_xpp = settings->xppOptimizationPasses;
        options.optimize_xmm = settings->xmmOptimizationPasses;
        options.llvm.optimization = Optimization(*settings);
        options.llvm.target_triple
            = targetTriple == nullptr ? "" : targetTriple;
        if (output == BuildOutput::kXpp)
            options.stop_after = tala::PipelineStop::Xpp;
        else if (output == BuildOutput::kXmm)
            options.stop_after = tala::PipelineStop::Xmm;
        if (action != PipelineAction::kCheck)
        {
            if (output == BuildOutput::kExecutable
                || output == BuildOutput::kObject)
                options.llvm.machineCode = Llvm::MachineCodeEmission::Object;
            else if (output == BuildOutput::kAssembly)
                options.llvm.machineCode = Llvm::MachineCodeEmission::Assembly;
            // An object written for its own sake is the object of a program
            // too: `--build=object` links it, and a program without the
            // entry of its process cannot be linked.
            options.llvm.executableEntry = output == BuildOutput::kExecutable
                                           || output == BuildOutput::kObject;
        }

        auto result
            = inputStage == InputStage::Core
                  ? Progmasoft::Tala::Pipeline::ConsumeCore(bytes, options)
              : inputStage == InputStage::Xpp
                  ? Progmasoft::Tala::Pipeline::ConsumeXpp(bytes, options)
                  : Progmasoft::Tala::Pipeline::ConsumeXmm(bytes, options);
        if (!result)
        {
            PrintFailure(result);
            return false;
        }
        if (action == PipelineAction::kCheck)
        {
            fmt::print(stderr,
                       "talac: compiler artifact '{}' is valid through its "
                       "requested pipeline boundary\n",
                       sourceName);
            return true;
        }
        if (output == BuildOutput::kXpp || output == BuildOutput::kXmm)
            return WriteIntermediate(artifactBasePath, output, result);
        const auto needsLlvm = output == BuildOutput::kExecutable
                               || output == BuildOutput::kObject
                               || output == BuildOutput::kAssembly
                               || output == BuildOutput::kLlvmIr
                               || output == BuildOutput::kLlvmBitcode;
        if (needsLlvm)
        {
            // A successful pipeline that ran to the backend carries its
            // artifact; report the contradiction instead of reading through
            // an empty optional.
            if (!result.llvm)
            {
                fmt::print(stderr,
                           "talac: compiler artifact '{}' produced no LLVM "
                           "artifact for the requested output\n",
                           sourceName);
                return false;
            }
            if (output == BuildOutput::kExecutable)
                return WriteExecutable(artifactBasePath,
                                       *result.llvm,
                                       settings->sysroot);
            return WriteArtifact(artifactBasePath, output, *result.llvm);
        }
        fmt::print(stderr,
                   "talac: requested artifact conversion is not supported from "
                   "this input stage\n");
        return false;
    }
} // namespace

bool
ProcessCoreArtifactAs(const char *path,
                      const char *artifactBasePath,
                      PipelineAction action,
                      BuildOutput output,
                      const CompilerSettings *settings,
                      const char *targetTriple)
{
    if (path == nullptr)
        return false;
    constexpr std::uintmax_t kMaximumArtifactBytes
        = std::uintmax_t{ 64U } * 1024U * 1024U;
    std::error_code sizeError;
    const auto size = std::filesystem::file_size(path, sizeError);
    if (!sizeError && size > kMaximumArtifactBytes)
    {
        fmt::print(
            stderr,
            "talac: compiler artifact '{}' exceeds the 64 MiB input limit\n",
            path);
        return false;
    }
    const auto bytes = ReadFile(path);
    if (!bytes)
    {
        fmt::print(stderr,
                   "talac: could not read compiler artifact '{}'\n",
                   path);
        return false;
    }
    return ProcessCoreBytesAs(*bytes,
                              path,
                              artifactBasePath,
                              action,
                              output,
                              settings,
                              targetTriple);
}

bool
ProcessCoreBytesAs(std::span<const std::uint8_t> bytes,
                   const char *sourceName,
                   const char *artifactBasePath,
                   PipelineAction action,
                   BuildOutput output,
                   const CompilerSettings *settings,
                   const char *targetTriple)
{
    return ProcessArtifact(InputStage::Core,
                           bytes,
                           sourceName,
                           artifactBasePath,
                           action,
                           output,
                           settings,
                           targetTriple);
}

bool
ProcessCoreArtifact(const char *path,
                    PipelineAction action,
                    BuildOutput output,
                    const CompilerSettings *settings,
                    const char *targetTriple)
{
    return ProcessCoreArtifactAs(path,
                                 path,
                                 action,
                                 output,
                                 settings,
                                 targetTriple);
}

bool
ProcessProjectCoreArtifacts(const std::filesystem::path &corePath,
                            const std::filesystem::path &outputDirectory,
                            const BuildOutput output,
                            const CompilerSettings *settings,
                            const char *targetTriple)
{
    constexpr std::uintmax_t kMaximumArtifactBytes
        = std::uintmax_t{ 64U } * 1024U * 1024U;
    std::error_code sizeError;
    const auto artifactSize = std::filesystem::file_size(corePath, sizeError);
    if (!sizeError && artifactSize > kMaximumArtifactBytes)
    {
        fmt::print(stderr,
                   "talac: Core artifact '{}' exceeds the 64 MiB input limit\n",
                   corePath.string());
        return false;
    }
    const auto bytes = ReadFile(corePath);
    if (!bytes)
    {
        fmt::print(stderr,
                   "talac: could not read project Core artifact '{}'\n",
                   corePath.string());
        return false;
    }

    return ProcessProjectCoreBytes(*bytes,
                                   corePath.string().c_str(),
                                   outputDirectory,
                                   output,
                                   settings,
                                   targetTriple);
}

bool
ProcessProjectCoreBytes(std::span<const std::uint8_t> bytes,
                        const char *sourceName,
                        const std::filesystem::path &outputDirectory,
                        const BuildOutput output,
                        const CompilerSettings *settings,
                        const char *targetTriple)
{
    if (settings == nullptr || sourceName == nullptr
        || (output != BuildOutput::kObject && output != BuildOutput::kAssembly))
        return false;
    constexpr std::size_t kMaximumArtifactBytes
        = std::size_t{ 64U } * 1024U * 1024U;
    if (bytes.size() > kMaximumArtifactBytes)
    {
        fmt::print(stderr,
                   "talac: Core artifact '{}' exceeds the 64 MiB input limit\n",
                   sourceName);
        return false;
    }

    tala::PipelineOptions pipelineOptions;
    pipelineOptions.optimize_xpp = settings->xppOptimizationPasses;
    pipelineOptions.optimize_xmm = settings->xmmOptimizationPasses;
    pipelineOptions.stop_after = tala::PipelineStop::Xmm;
    auto pipeline
        = Progmasoft::Tala::Pipeline::ConsumeCore(bytes, pipelineOptions);
    if (!pipeline || !pipeline.xmm)
    {
        PrintFailure(pipeline);
        return false;
    }

    namespace Project = Progmasoft::Tala::Driver::ProjectArtifacts;
    const auto extension = output == BuildOutput::kObject ? ".o" : ".asm";
    const auto plan
        = Project::PlanSourceOutputs(pipeline.xmm->source_files, extension);
    if (!plan)
    {
        fmt::print(stderr,
                   "talac: cannot plan per-source output: {}\n",
                   plan.diagnostic);
        return false;
    }

    const auto emission = output == BuildOutput::kObject
                              ? Llvm::MachineCodeEmission::Object
                              : Llvm::MachineCodeEmission::Assembly;
    std::vector<Project::ArtifactFile> files;
    files.reserve(plan.outputs.size());
    for (const auto &sourceOutput : plan.outputs)
    {
        auto llvmOptions = pipelineOptions.llvm;
        llvmOptions.optimization = Optimization(*settings);
        llvmOptions.target_triple = targetTriple == nullptr ? "" : targetTriple;
        llvmOptions.machineCode = emission;
        llvmOptions.executableEntry = false;
        llvmOptions.definition_source_file = sourceOutput.source_file;
        const auto lowered = Llvm::Lower(*pipeline.xmm, llvmOptions);
        if (!lowered.artifact)
        {
            // A result without an artifact carries the error that explains
            // it; the fallback keeps this report total if one ever does not.
            fmt::print(stderr,
                       "talac: source '{}' could not be lowered: {}: {}\n",
                       sourceOutput.file_name,
                       lowered.error ? lowered.error->code : "internal",
                       lowered.error ? lowered.error->message
                                     : "the backend returned neither an "
                                       "artifact nor an error");
            return false;
        }

        Project::ArtifactFile file;
        file.file_name = sourceOutput.file_name;
        if (emission == Llvm::MachineCodeEmission::Object)
            file.bytes = lowered.artifact->object;
        else
        {
            file.bytes.reserve(lowered.artifact->assembly.size());
            for (const auto byte : lowered.artifact->assembly)
                file.bytes.push_back(static_cast<std::uint8_t>(byte));
        }
        files.push_back(std::move(file));
    }

    if (const auto error = Project::CommitArtifactFiles(outputDirectory, files))
    {
        fmt::print(stderr,
                   "talac: project artifacts were not committed: {}\n",
                   *error);
        return false;
    }
    for (const auto &file : files)
        fmt::print(stderr,
                   "talac: wrote verified {} artifact '{}'\n",
                   output == BuildOutput::kObject ? "object" : "assembly",
                   PathText(outputDirectory
                            / std::filesystem::path(
                                std::u8string(file.file_name.begin(),
                                              file.file_name.end()))));
    return true;
}

bool
ProcessXppArtifactAs(const char *path,
                     const char *artifactBasePath,
                     PipelineAction action,
                     BuildOutput output,
                     const CompilerSettings *settings,
                     const char *targetTriple)
{
    if (path == nullptr)
        return false;
    const auto bytes = ReadFile(path);
    if (!bytes)
    {
        fmt::print(stderr,
                   "talac: could not read compiler artifact '{}'\n",
                   path);
        return false;
    }
    return ProcessArtifact(InputStage::Xpp,
                           *bytes,
                           path,
                           artifactBasePath,
                           action,
                           output,
                           settings,
                           targetTriple);
}

bool
ProcessXmmArtifactAs(const char *path,
                     const char *artifactBasePath,
                     PipelineAction action,
                     BuildOutput output,
                     const CompilerSettings *settings,
                     const char *targetTriple)
{
    if (path == nullptr)
        return false;
    const auto bytes = ReadFile(path);
    if (!bytes)
    {
        fmt::print(stderr,
                   "talac: could not read compiler artifact '{}'\n",
                   path);
        return false;
    }
    return ProcessArtifact(InputStage::Xmm,
                           *bytes,
                           path,
                           artifactBasePath,
                           action,
                           output,
                           settings,
                           targetTriple);
}
