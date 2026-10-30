// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// talac is a compiler and nothing else: it reads the inputs named on its
// command line and writes one kind of output. Projects, dependencies and
// packages belong to the program that starts it.
//
// Raw argv spellings are consumed by the parser and become this typed model.
// Strings remain only for values that are intrinsically textual.

/// What the pipeline does with a verified program.
enum class PipelineAction : std::uint8_t
{
    kBuild, ///< Lower the program and write the requested output.
    kCheck, ///< Run every verifier and write nothing.
};

enum class ViPkgType : std::uint8_t
{
    kExecutable,
    kStaticLibrary,
    kDynamicLibrary,
    kTalaLibrary,
};

enum class WarningLevel : std::uint8_t
{
    kAll,
    kMedium,
    kLow,
    kNone,
};

/// The output named by `--emit`.
enum class BuildOutput : std::uint8_t
{
    kExecutable,
    kObject,
    kCore,
    kXpp,
    kXmm,
    kAssembly,
    kLlvmIr,
    kLlvmBitcode,
    /// Check the program and write no executable: every verifier runs,
    /// code generation does not, and a `.talameta` file records what was
    /// checked.
    kMetadata,
};

/// The kind of the inputs, named by `--build`.
enum class BuildInput : std::uint8_t
{
    kTala,
    kObject,
    kCore,
    kXpp,
    kXmm,
    kLlvmIr,
    kLlvmBitcode,
};

enum class LlvmOptLevel : std::uint8_t
{
    kO0,
    kO1,
    kO2,
    kO3,
    kOg,
};

enum class LlvmCompiler : std::uint8_t
{
    kAot,
    kOrc,
};

enum class LlvmLto : std::uint8_t
{
    kNone,
    kFat,
    kThin,
};

struct CompilerSettings
{
    WarningLevel warningLevel;
    bool warningsAsErrors;
    /// Report a local that hides an outer one. No level turns this on:
    /// it is asked for by name, `--warnings=shadow`.
    bool shadowWarnings;
    bool xppOptimizationPasses;
    bool xmmOptimizationPasses;
    LlvmOptLevel llvmOptLevel;
    LlvmCompiler llvmCompiler;
    LlvmLto llvmLto;

    bool
    operator==(const CompilerSettings &) const = default;
};

struct CliOptions
{
    /// The inputs in the order they were written; all of one kind.
    std::vector<std::filesystem::path> inputs;
    /// Namespace-qualified class whose `Main` starts the program.
    std::optional<std::string> entry;
    /// LLVM target triple; the host when absent.
    std::optional<std::string> target;
    /// Arguments handed to LLVM as they were written.
    std::vector<std::string> llvmArguments;
    std::string standard;
    BuildOutput output;
    BuildInput input;
    ViPkgType viPkgType;
    CompilerSettings compiler;
    bool emitHeader;
    /// Whether the program is the runner of the sources' [Fact] methods.
    bool test;

    bool
    operator==(const CliOptions &) const = default;
};

enum class CliParseResult : std::uint8_t
{
    kError,
    kReady,
    kHelp,
    kVersion,
};

struct CliParseOutcome
{
    CliParseResult result;
    CliOptions options;
    std::string diagnostic;

    bool
    operator==(const CliParseOutcome &) const = default;
};

[[nodiscard]] CompilerSettings
DefaultCompilerSettings() noexcept;
[[nodiscard]] const char *
WarningLevelName(WarningLevel level) noexcept;
/// @brief File extension of an output kind.
/// @return The usual extension of the kind; for an executable, the one the
/// host gives its programs, which is empty where programs have none.
[[nodiscard]] const char *
OutputExtension(BuildOutput output) noexcept;
/// @brief File extension a compiler input of this kind must have.
[[nodiscard]] std::string_view
InputExtension(BuildInput input) noexcept;

[[nodiscard]] CliParseOutcome
ParseCommandLine(int argc, char **argv);
void
PrintCliHelp();
/// @brief Version of this compiler, as `--version` prints it.
[[nodiscard]] const char *
CliVersion() noexcept;
void
PrintCliVersion();
