// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

// Raw argv spellings are consumed by the C++20 parser and become this typed
// driver model. Strings remain only for values that are intrinsically textual.
enum class CliCommand : std::uint8_t
{
    kNone,
    kBuild,
    kCheck,
    kFormat,
    kInstall,
    kLint,
    kResolve,
    kRun,
    kTest,
    kUpdate,
    kVersion,
    kViGet,
    kViPkg,
    kInteractive,
};

enum class ViPkgAction : std::uint8_t
{
    kNone,
    kCreate,
};

enum class ViPkgType : std::uint8_t
{
    kExecutable,
    kTalaLibrary,
    kStaticLibrary,
    kDynamicLibrary,
};

enum class ViGetAction : std::uint8_t
{
    kNone,
    kPush,
    kUpdate,
};

enum class WarningLevel : std::uint8_t
{
    kAll,
    kMedium,
    kLow,
    kNone,
};

enum class BuildOutput : std::uint8_t
{
    kBinary,
    kObject,
    kCore,
    kXpp,
    kXmm,
    kAssembly,
    kLlvmIr,
    kLlvmBitcode,
};

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
    bool experimentalWarnings;
    bool shadowWarnings;
    bool undefinedWarnings;
    bool typeSafeFormat;
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
    CliCommand command;
    ViGetAction vigetAction;
    ViPkgAction viPkgAction;
    ViPkgType viPkgType;
    std::optional<std::filesystem::path> filePath;
    std::optional<std::string> packageCoordinate;
    std::optional<std::string> target;
    std::vector<std::string> programArguments;
    std::vector<std::string> interactiveArguments;
    std::vector<std::string> selectedViPkgs;
    std::vector<std::string> selectedExecutables;
    std::vector<std::string> selectedLibraries;
    std::string compilerVersion;
    std::string standard;
    BuildOutput output;
    BuildInput input;
    CompilerSettings compiler;
    bool globalInstall;
    bool formatterDryRun;
    bool emitHeader;
    bool compilerVersionOverride;
    bool standardOverride;
    bool targetOverride;
    bool outputOverride;
    bool warningOverride;
    bool werrorOverride;
    bool experimentalOverride;
    bool shadowOverride;
    bool undefOverride;
    bool typeSafeFormatOverride;
    bool xppOptimizationOverride;
    bool xmmOptimizationOverride;
    bool llvmOptOverride;
    bool llvmCompilerOverride;
    bool llvmLtoOverride;

    bool
    operator==(const CliOptions &) const = default;
};

// Fully resolved values for one compiler invocation. A project evaluation can
// provide the base layer; only CLI fields that were actually present replace
// it.
struct EffectiveCompilerOptions
{
    std::string compilerVersion;
    std::string standard;
    std::optional<std::string> target;
    BuildOutput output;
    CompilerSettings compiler;
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
    std::optional<CliCommand> helpCommand;
    std::string diagnostic;

    bool
    operator==(const CliParseOutcome &) const = default;
};

[[nodiscard]] CompilerSettings
DefaultCompilerSettings() noexcept;
void
ApplyCompilerOverrides(const CliOptions &options,
                       CompilerSettings &settings) noexcept;
[[nodiscard]] const char *
WarningLevelName(WarningLevel level) noexcept;
[[nodiscard]] const char *
OutputExtension(BuildOutput output) noexcept;

[[nodiscard]] CliParseOutcome
ParseCommandLine(int argc, char **argv);
[[nodiscard]] EffectiveCompilerOptions
ResolveCompilerOptions(const CliOptions &options,
                       const EffectiveCompilerOptions *projectDefaults
                       = nullptr);
void
PrintCliHelp(std::optional<CliCommand> command);
void
PrintCliVersion();
