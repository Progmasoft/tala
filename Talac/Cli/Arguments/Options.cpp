// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <array>
#include <cstdint>
#include <fmt/format.h>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>

#include "TableLibrary.hpp"
#include "Talac/Cli/Arguments/Options.hpp"

#ifndef TALA_PROJECT_VERSION
#    define TALA_PROJECT_VERSION "0.5.1"
#endif

namespace
{
    using std::literals::operator""sv;

    constexpr std::string_view kHelpOption = "-Help";

    enum class Option : std::uint8_t
    {
        File,
        Standard,
        CompilerVersion,
        Target,
        Emit,
        Build,
        Warnings,
        Werror,
        Wexperimental,
        Wshadow,
        Wundef,
        TypeSafeFormat,
        Backend,
        LlvmOptLevel,
        LlvmCompiler,
        LlvmLto,
        XppOptimization,
        XmmOptimization,
        Global,
        DryRun,
        ViPkg,
        Executable,
        Library,
        Header,
        ViPkgType,
        Count,
    };

    enum class ValueDomain : std::uint8_t
    {
        None,
        Path,
        Standard,
        Version,
        TargetTriple,
        Output,
        Input,
        WarningLevel,
        Boolean,
        Backend,
        LlvmOptLevel,
        LlvmCompiler,
        LlvmLto,
        TargetNameList,
        ViPkgType,
    };

    enum class PositionalKind : std::uint8_t
    {
        None,
        PackageCoordinate,
        ViGetAction,
        ViPkgAction,
    };

    enum class ApplyResult : std::uint8_t
    {
        Applied,
        Invalid,
    };

    using CommandMask = unsigned;

    constexpr CommandMask
    Bit(CliCommand command)
    {
        return 1U << static_cast<unsigned>(command);
    }

    constexpr CommandMask kCompilerCommands
        = Bit(CliCommand::kBuild) | Bit(CliCommand::kCheck)
          | Bit(CliCommand::kRun) | Bit(CliCommand::kTest);

    struct CommandSpec
    {
        std::string_view name;
        CliCommand command;
        PositionalKind positional;
        std::string_view description;
    };

    // The field order mirrors the columns of the declarative option table
    // below; the table has a few dozen static rows, so its padding is not
    // worth reordering every row.
    // NOLINTNEXTLINE(clang-analyzer-optin.performance.Padding)
    struct OptionSpec
    {
        std::string_view spelling;
        Option option;
        CommandMask commands;
        ValueDomain domain;
        std::string_view description;
    };

    template<typename Value>
    using Choice = std::pair<std::string_view, Value>;

    // All accepted spellings live in these typed domains. Both conversion and
    // help rendering consume the same tables, preventing documentation from
    // accepting a value that the parser rejects (or silently omitting a value
    // it supports).
    constexpr std::array kStandardValues = { "26"sv, "latest"sv };
    constexpr std::array kBooleanValues
        = { Choice{ "true"sv, true }, Choice{ "false"sv, false } };
    constexpr std::array kOutputValues = {
        Choice{ "binary"sv, BuildOutput::kBinary },
        Choice{ "object"sv, BuildOutput::kObject },
        Choice{ "core"sv, BuildOutput::kCore },
        Choice{ "xpp"sv, BuildOutput::kXpp },
        Choice{ "xmm"sv, BuildOutput::kXmm },
        Choice{ "assembly"sv, BuildOutput::kAssembly },
        Choice{ "llvmll"sv, BuildOutput::kLlvmIr },
        Choice{ "llvmbc"sv, BuildOutput::kLlvmBitcode },
    };
    constexpr std::array kInputValues = {
        Choice{ "object"sv, BuildInput::kObject },
        Choice{ "talac"sv, BuildInput::kTala },
        Choice{ "core"sv, BuildInput::kCore },
        Choice{ "xpp"sv, BuildInput::kXpp },
        Choice{ "xmm"sv, BuildInput::kXmm },
        Choice{ "llvmll"sv, BuildInput::kLlvmIr },
        Choice{ "llvmbc"sv, BuildInput::kLlvmBitcode },
    };
    constexpr std::array kWarningValues = {
        Choice{ "all"sv, WarningLevel::kAll },
        Choice{ "medium"sv, WarningLevel::kMedium },
        Choice{ "low"sv, WarningLevel::kLow },
        Choice{ "none"sv, WarningLevel::kNone },
    };
    constexpr std::array kBackendValues = { "llvm"sv };
    constexpr std::array kLlvmOptValues = {
        Choice{ "1"sv, LlvmOptLevel::kO1 },
        Choice{ "2"sv, LlvmOptLevel::kO2 },
        Choice{ "3"sv, LlvmOptLevel::kO3 },
        Choice{ "g"sv, LlvmOptLevel::kOg },
    };
    constexpr std::array kLlvmCompilerValues = {
        Choice{ "aot"sv, LlvmCompiler::kAot },
        Choice{ "orc"sv, LlvmCompiler::kOrc },
    };
    constexpr std::array kLlvmLtoValues = {
        Choice{ "fat"sv, LlvmLto::kFat },
        Choice{ "thin"sv, LlvmLto::kThin },
        Choice{ "none"sv, LlvmLto::kNone },
    };
    constexpr std::array kViGetActions = {
        Choice{ "push"sv, ViGetAction::kPush },
        Choice{ "update"sv, ViGetAction::kUpdate },
    };
    constexpr std::array kViPkgActions = {
        Choice{ "create"sv, ViPkgAction::kCreate },
    };
    constexpr std::array kViPkgTypes = {
        Choice{ "exe"sv, ViPkgType::kExecutable },
        Choice{ "talalib"sv, ViPkgType::kTalaLibrary },
        Choice{ "staticlib"sv, ViPkgType::kStaticLibrary },
        Choice{ "cdylib"sv, ViPkgType::kDynamicLibrary },
    };

    constexpr CommandSpec kCommands[] = {
        { "check",
          CliCommand::kCheck,
          PositionalKind::None,
          "validate a project or source artifact" },
        { "build",
          CliCommand::kBuild,
          PositionalKind::None,
          "build a project or source artifact" },
        { "format",
          CliCommand::kFormat,
          PositionalKind::None,
          "format every source in the project with talafmt" },
        { "lint",
          CliCommand::kLint,
          PositionalKind::None,
          "lint every source in the project with talalint" },
        { "run",
          CliCommand::kRun,
          PositionalKind::None,
          "build and run a project or source file" },
        { "test",
          CliCommand::kTest,
          PositionalKind::None,
          "run the project's named test suites" },
        { "resolve",
          CliCommand::kResolve,
          PositionalKind::None,
          "resolve project dependencies" },
        { "update",
          CliCommand::kUpdate,
          PositionalKind::None,
          "update system and project dependencies" },
        { "install",
          CliCommand::kInstall,
          PositionalKind::PackageCoordinate,
          "install a ViGet package" },
        { "viget",
          CliCommand::kViGet,
          PositionalKind::ViGetAction,
          "publish or update a ViGet package" },
        { "vipkg",
          CliCommand::kViPkg,
          PositionalKind::ViPkgAction,
          "create a local ViPkg without publishing it" },
        { "version",
          CliCommand::kVersion,
          PositionalKind::None,
          "print the compiler version" },
        { "interactive",
          CliCommand::kInteractive,
          PositionalKind::None,
          "launch the Tala Interactive REPL" },
    };

    // Option spelling, arity (through domain), command scope, and help
    // description are deliberately one record. New options must not grow ad-hoc
    // argv branches.
    constexpr OptionSpec kOptions[] = {
        { "-File",
          Option::File,
          kCompilerCommands,
          ValueDomain::Path,
          "compile one explicit file instead of the project" },
        { "-Standard",
          Option::Standard,
          kCompilerCommands,
          ValueDomain::Standard,
          "select the language standard" },
        { "-Compiler-Version",
          Option::CompilerVersion,
          kCompilerCommands,
          ValueDomain::Version,
          "select the compiler version" },
        { "-Target",
          Option::Target,
          kCompilerCommands,
          ValueDomain::TargetTriple,
          "select the LLVM target triple" },
        { "-Emit",
          Option::Emit,
          Bit(CliCommand::kBuild),
          ValueDomain::Output,
          "select the emitted artifact" },
        { "-Build",
          Option::Build,
          Bit(CliCommand::kBuild) | Bit(CliCommand::kCheck),
          ValueDomain::Input,
          "select the explicit input artifact kind" },
        { "-Warnings",
          Option::Warnings,
          kCompilerCommands,
          ValueDomain::WarningLevel,
          "select the warning level" },
        { "-Werror",
          Option::Werror,
          kCompilerCommands,
          ValueDomain::Boolean,
          "treat warnings as errors" },
        { "-Wexperimental",
          Option::Wexperimental,
          kCompilerCommands,
          ValueDomain::Boolean,
          "enable experimental warnings" },
        { "-Wshadow",
          Option::Wshadow,
          kCompilerCommands,
          ValueDomain::Boolean,
          "enable shadowing warnings" },
        { "-Wundef",
          Option::Wundef,
          kCompilerCommands,
          ValueDomain::Boolean,
          "enable undefined-name warnings" },
        { "-Type-Safe-Format",
          Option::TypeSafeFormat,
          kCompilerCommands,
          ValueDomain::Boolean,
          "require strict format-argument type matching; false enables C-like "
          "compatibility" },
        { "-Backend",
          Option::Backend,
          kCompilerCommands,
          ValueDomain::Backend,
          "select the compiler backend" },
        { "-Llvm-OptLevel",
          Option::LlvmOptLevel,
          kCompilerCommands,
          ValueDomain::LlvmOptLevel,
          "select LLVM optimization" },
        { "-Llvm-Compiler",
          Option::LlvmCompiler,
          kCompilerCommands,
          ValueDomain::LlvmCompiler,
          "select LLVM execution mode" },
        { "-Llvm-Lto",
          Option::LlvmLto,
          kCompilerCommands,
          ValueDomain::LlvmLto,
          "select LLVM link-time optimization" },
        { "-Xpp-Optimization-Passes",
          Option::XppOptimization,
          kCompilerCommands,
          ValueDomain::Boolean,
          "enable Xpp optimization passes" },
        { "-Xmm-Optimization-Passes",
          Option::XmmOptimization,
          kCompilerCommands,
          ValueDomain::Boolean,
          "enable Xmm optimization passes" },
        { "-Global",
          Option::Global,
          Bit(CliCommand::kInstall),
          ValueDomain::None,
          "install into the system package store" },
        { "-Dry-Run",
          Option::DryRun,
          Bit(CliCommand::kFormat),
          ValueDomain::None,
          "report formatting differences without writing files" },
        { "-ViPkg",
          Option::ViPkg,
          Bit(CliCommand::kBuild) | Bit(CliCommand::kRun),
          ValueDomain::TargetNameList,
          "select one or more ViPkg targets" },
        { "-Executable",
          Option::Executable,
          Bit(CliCommand::kBuild) | Bit(CliCommand::kRun),
          ValueDomain::TargetNameList,
          "select one or more executable targets" },
        { "-Library",
          Option::Library,
          Bit(CliCommand::kBuild) | Bit(CliCommand::kRun),
          ValueDomain::TargetNameList,
          "select one or more library targets" },
        { "-Header",
          Option::Header,
          Bit(CliCommand::kBuild),
          ValueDomain::None,
          "reserved; TCI export ABI and header generation are not "
          "implemented" },
        { "-ViPkgType",
          Option::ViPkgType,
          Bit(CliCommand::kBuild),
          ValueDomain::ViPkgType,
          "select the executable or library package shape" },
    };

    constexpr CompilerSettings kCompilerDefaults{
        .warningLevel = WarningLevel::kMedium,
        .warningsAsErrors = false,
        .experimentalWarnings = false,
        .shadowWarnings = false,
        .undefinedWarnings = true,
        .typeSafeFormat = true,
        .xppOptimizationPasses = true,
        .xmmOptimizationPasses = true,
        .llvmOptLevel = LlvmOptLevel::kO2,
        .llvmCompiler = LlvmCompiler::kAot,
        .llvmLto = LlvmLto::kNone,
    };

    [[nodiscard]] std::optional<CommandSpec>
    FindCommand(std::string_view spelling)
    {
        for (const auto &spec : kCommands)
            if (spec.name == spelling)
                return spec;
        return std::nullopt;
    }

    [[nodiscard]] const OptionSpec *
    FindOption(std::string_view spelling)
    {
        for (const auto &spec : kOptions)
            if (spec.spelling == spelling)
                return &spec;
        return nullptr;
    }

    template<typename Value, std::size_t Size>
    [[nodiscard]] bool
    ParseChoice(std::string_view value,
                Value &output,
                const std::array<Choice<Value>, Size> &choices)
    {
        for (const auto &[spelling, parsed] : choices)
        {
            if (value == spelling)
            {
                output = parsed;
                return true;
            }
        }
        return false;
    }

    template<std::size_t Size>
    [[nodiscard]] bool
    Contains(std::string_view value,
             const std::array<std::string_view, Size> &choices)
    {
        for (const auto choice : choices)
            if (value == choice)
                return true;
        return false;
    }

    template<typename Value, std::size_t Size>
    void
    AppendChoices(std::string &output,
                  const std::array<Choice<Value>, Size> &choices)
    {
        for (std::size_t index = 0; index < choices.size(); ++index)
        {
            if (index != 0U)
                output.push_back('|');
            output.append(choices[index].first);
        }
    }

    template<std::size_t Size>
    void
    AppendChoices(std::string &output,
                  const std::array<std::string_view, Size> &choices)
    {
        for (std::size_t index = 0; index < choices.size(); ++index)
        {
            if (index != 0U)
                output.push_back('|');
            output.append(choices[index]);
        }
    }

    [[nodiscard]] std::string
    DomainText(ValueDomain domain)
    {
        std::string result;
        switch (domain)
        {
            case ValueDomain::None:
                break;
            case ValueDomain::Path:
                result = "PATH";
                break;
            case ValueDomain::Version:
                result = "VERSION|latest";
                break;
            case ValueDomain::TargetTriple:
                result = "TARGET-TRIPLE";
                break;
            case ValueDomain::Standard:
                AppendChoices(result, kStandardValues);
                break;
            case ValueDomain::Output:
                AppendChoices(result, kOutputValues);
                break;
            case ValueDomain::Input:
                AppendChoices(result, kInputValues);
                break;
            case ValueDomain::WarningLevel:
                AppendChoices(result, kWarningValues);
                break;
            case ValueDomain::Boolean:
                AppendChoices(result, kBooleanValues);
                break;
            case ValueDomain::Backend:
                AppendChoices(result, kBackendValues);
                break;
            case ValueDomain::LlvmOptLevel:
                AppendChoices(result, kLlvmOptValues);
                break;
            case ValueDomain::LlvmCompiler:
                AppendChoices(result, kLlvmCompilerValues);
                break;
            case ValueDomain::LlvmLto:
                AppendChoices(result, kLlvmLtoValues);
                break;
            case ValueDomain::TargetNameList:
                result = "NAME [NAME ...]";
                break;
            case ValueDomain::ViPkgType:
                AppendChoices(result, kViPkgTypes);
                break;
        }
        return result;
    }

    [[nodiscard]] std::string_view
    BoolText(bool value)
    {
        return value ? "true"sv : "false"sv;
    }

    template<typename Value, std::size_t Size>
    [[nodiscard]] std::string_view
    ChoiceText(Value value, const std::array<Choice<Value>, Size> &choices)
    {
        for (const auto &[spelling, candidate] : choices)
            if (candidate == value)
                return spelling;
        return {};
    }

    // Help defaults are rendered from the same typed state used by parsing.
    // This avoids a second prose-only default table that can drift from
    // execution.
    [[nodiscard]] std::string_view
    DefaultText(Option option)
    {
        switch (option)
        {
            case Option::Standard:
            case Option::CompilerVersion:
                return "latest"sv;
            case Option::Target:
                return "host"sv;
            case Option::Emit:
                return ChoiceText(BuildOutput::kBinary, kOutputValues);
            case Option::Build:
                return ChoiceText(BuildInput::kTala, kInputValues);
            case Option::Warnings:
                return ChoiceText(kCompilerDefaults.warningLevel,
                                  kWarningValues);
            case Option::Werror:
                return BoolText(kCompilerDefaults.warningsAsErrors);
            case Option::Wexperimental:
                return BoolText(kCompilerDefaults.experimentalWarnings);
            case Option::Wshadow:
                return BoolText(kCompilerDefaults.shadowWarnings);
            case Option::Wundef:
                return BoolText(kCompilerDefaults.undefinedWarnings);
            case Option::TypeSafeFormat:
                return BoolText(kCompilerDefaults.typeSafeFormat);
            case Option::Backend:
                return "llvm"sv;
            case Option::LlvmOptLevel:
                return ChoiceText(kCompilerDefaults.llvmOptLevel,
                                  kLlvmOptValues);
            case Option::LlvmCompiler:
                return ChoiceText(kCompilerDefaults.llvmCompiler,
                                  kLlvmCompilerValues);
            case Option::LlvmLto:
                return ChoiceText(kCompilerDefaults.llvmLto, kLlvmLtoValues);
            case Option::XppOptimization:
                return BoolText(kCompilerDefaults.xppOptimizationPasses);
            case Option::XmmOptimization:
                return BoolText(kCompilerDefaults.xmmOptimizationPasses);
            case Option::ViPkgType:
                return ChoiceText(ViPkgType::kExecutable, kViPkgTypes);
            case Option::File:
            case Option::Global:
            case Option::DryRun:
            case Option::ViPkg:
            case Option::Executable:
            case Option::Library:
            case Option::Header:
            case Option::Count:
                return {};
        }
        return {};
    }

    [[nodiscard]] CliParseOutcome
    Failure(CliOptions options, std::string message)
    {
        return { CliParseResult::kError,
                 std::move(options),
                 std::nullopt,
                 std::move(message) };
    }

    [[nodiscard]] CliParseOutcome
    FailOption(CliOptions options,
               const OptionSpec &spec,
               std::string_view value)
    {
        std::string message = "invalid value '";
        message.append(value);
        message.append("' for ");
        message.append(spec.spelling);
        message.append("; expected ");
        message.append(DomainText(spec.domain));
        return Failure(std::move(options), std::move(message));
    }

    // Whether the bytes are well-formed UTF-8: no stray or missing
    // continuation byte, no overlong form, no surrogate and nothing above
    // U+10FFFF. The ranges are those of the Unicode standard's table of
    // well-formed byte sequences.
    [[nodiscard]] bool
    IsWellFormedUtf8(std::string_view value)
    {
        const auto byteAt = [value](std::size_t index) {
            return static_cast<unsigned char>(value[index]);
        };
        for (std::size_t index = 0U; index < value.size();)
        {
            const auto first = byteAt(index);
            if (first <= 0x7fU)
            {
                ++index;
                continue;
            }
            std::size_t width{};
            unsigned char lowest = 0x80U;
            unsigned char highest = 0xbfU;
            if (first >= 0xc2U && first <= 0xdfU)
                width = 2U;
            else if (first >= 0xe0U && first <= 0xefU)
            {
                width = 3U;
                if (first == 0xe0U)
                    lowest = 0xa0U;
                else if (first == 0xedU)
                    highest = 0x9fU;
            }
            else if (first >= 0xf0U && first <= 0xf4U)
            {
                width = 4U;
                if (first == 0xf0U)
                    lowest = 0x90U;
                else if (first == 0xf4U)
                    highest = 0x8fU;
            }
            else
                return false;
            if (width > value.size() - index)
                return false;
            const auto second = byteAt(index + 1U);
            if (second < lowest || second > highest)
                return false;
            for (std::size_t offset = 2U; offset < width; ++offset)
            {
                const auto continuation = byteAt(index + offset);
                if (continuation < 0x80U || continuation > 0xbfU)
                    return false;
            }
            index += width;
        }
        return true;
    }

    // The caller has checked that the bytes are well-formed UTF-8. The
    // standard library converts them to the native encoding of the host and
    // reports bytes it cannot convert by throwing, which this code, built
    // without exceptions, cannot answer.
    [[nodiscard]] std::filesystem::path
    Utf8Path(std::string_view value)
    {
        const auto *begin = reinterpret_cast<const char8_t *>(value.data());
        return std::filesystem::path(std::u8string_view(begin, value.size()));
    }

    [[nodiscard]] bool
    IsTargetTriple(std::string_view value)
    {
        std::size_t segmentCount{};
        std::size_t segmentLength{};
        for (const char character : value)
        {
            if (character == '-')
            {
                if (segmentLength == 0U)
                    return false;
                ++segmentCount;
                segmentLength = 0U;
                continue;
            }
            const bool accepted = (character >= 'A' && character <= 'Z')
                                  || (character >= 'a' && character <= 'z')
                                  || (character >= '0' && character <= '9')
                                  || character == '_' || character == '+'
                                  || character == '.';
            if (!accepted)
                return false;
            ++segmentLength;
        }
        return segmentLength != 0U && segmentCount >= 2U;
    }

    [[nodiscard]] std::string
    PositionalText(PositionalKind positional)
    {
        switch (positional)
        {
            case PositionalKind::None:
                return {};
            case PositionalKind::PackageCoordinate:
                return " Publisher.Name";
            case PositionalKind::ViGetAction:
                return " push|update";
            case PositionalKind::ViPkgAction:
                return " create";
        }
        return {};
    }

    void
    PrintHelp(const CommandSpec *command)
    {
        if (command == nullptr)
        {
            fmt::print("Tala compiler, project, and ViGet command-line "
                       "interface.\n\n"
                       "Usage: talac <command> [options]\n\n");
            tabulate::Table commands;
            commands.add_row({ "Command", "Description" });
            for (const auto &spec : kCommands)
                commands.add_row(
                    { std::string(spec.name), std::string(spec.description) });
            commands[0].format().font_style({ tabulate::FontStyle::bold });
            commands.column(0).format().font_align(tabulate::FontAlign::left);
            commands.column(1).format().font_align(tabulate::FontAlign::left);
            std::ostringstream rendered;
            rendered << commands;
            fmt::print("{}\n\n", rendered.str());
            fmt::print("\nRun 'talac <command> -Help' for command-specific "
                       "options.\n");
            return;
        }

        const auto positional = PositionalText(command->positional);
        const auto programArguments = command->command == CliCommand::kRun
                                          ? " [-- program-arguments...]"
                                          : "";
        if (command->command == CliCommand::kInteractive)
        {
            fmt::print(
                "Usage: talac interactive [tali arguments...]\n\n"
                "Starts `tali` by searching PATH and forwards all "
                "following arguments unchanged.\n"
                "Use `talac interactive --eval <expression>` for one-shot "
                "evaluation or pass no\n"
                "arguments to open the interactive REPL. Use `talac "
                "interactive -Help` for details.\n");
            return;
        }
        fmt::print("Usage: talac {} [options]{}{}\n",
                   command->name,
                   positional,
                   programArguments);
        tabulate::Table options;
        options.add_row({ "Option", "Description", "Default" });
        for (const auto &spec : kOptions)
        {
            if ((spec.commands & Bit(command->command)) == 0U)
                continue;
            std::string signature(spec.spelling);
            const auto domain = DomainText(spec.domain);
            if (!domain.empty())
            {
                signature.push_back(' ');
                signature.append(domain);
            }
            const auto defaultValue = DefaultText(spec.option);
            options.add_row({ std::move(signature),
                              std::string(spec.description),
                              std::string(defaultValue) });
        }
        options.add_row({ "-Help", "show this command help", "" });
        options[0].format().font_style({ tabulate::FontStyle::bold });
        options.column(0).format().font_align(tabulate::FontAlign::left);
        options.column(1).format().font_align(tabulate::FontAlign::left);
        options.column(2).format().font_align(tabulate::FontAlign::left);
        std::ostringstream rendered;
        rendered << options;
        fmt::print("\n{}\n", rendered.str());
    }

    [[nodiscard]] ApplyResult
    ApplyBoolean(Option option, std::string_view value, CliOptions &options)
    {
        bool parsed{};
        if (!ParseChoice(value, parsed, kBooleanValues))
            return ApplyResult::Invalid;
        bool *destination{};
        bool *overrideFlag{};
        switch (option)
        {
            case Option::Werror:
                destination = &options.compiler.warningsAsErrors;
                overrideFlag = &options.werrorOverride;
                break;
            case Option::Wexperimental:
                destination = &options.compiler.experimentalWarnings;
                overrideFlag = &options.experimentalOverride;
                break;
            case Option::Wshadow:
                destination = &options.compiler.shadowWarnings;
                overrideFlag = &options.shadowOverride;
                break;
            case Option::Wundef:
                destination = &options.compiler.undefinedWarnings;
                overrideFlag = &options.undefOverride;
                break;
            case Option::TypeSafeFormat:
                destination = &options.compiler.typeSafeFormat;
                overrideFlag = &options.typeSafeFormatOverride;
                break;
            case Option::XppOptimization:
                destination = &options.compiler.xppOptimizationPasses;
                overrideFlag = &options.xppOptimizationOverride;
                break;
            case Option::XmmOptimization:
                destination = &options.compiler.xmmOptimizationPasses;
                overrideFlag = &options.xmmOptimizationOverride;
                break;
            default:
                return ApplyResult::Invalid;
        }
        *destination = parsed;
        *overrideFlag = true;
        return ApplyResult::Applied;
    }

    // Values become typed at this boundary. The rest of the driver never
    // interprets raw argv text or carries compatibility aliases into project
    // configuration.
    [[nodiscard]] bool
    IsPackageSegment(std::string_view value);

    [[nodiscard]] ApplyResult
    ApplyOption(const OptionSpec &spec,
                std::string_view value,
                CliOptions &options)
    {
        switch (spec.option)
        {
            case Option::File:
                if (value.empty() || !IsWellFormedUtf8(value))
                    return ApplyResult::Invalid;
                options.filePath = Utf8Path(value);
                return ApplyResult::Applied;
            case Option::Standard:
                if (!Contains(value, kStandardValues))
                    return ApplyResult::Invalid;
                options.standard = value;
                options.standardOverride = true;
                return ApplyResult::Applied;
            case Option::CompilerVersion:
                if (value.empty())
                    return ApplyResult::Invalid;
                options.compilerVersion = value;
                options.compilerVersionOverride = true;
                return ApplyResult::Applied;
            case Option::Target:
                if (!IsTargetTriple(value))
                    return ApplyResult::Invalid;
                options.target = value;
                options.targetOverride = true;
                return ApplyResult::Applied;
            case Option::Emit:
                if (!ParseChoice(value, options.output, kOutputValues))
                    return ApplyResult::Invalid;
                options.outputOverride = true;
                return ApplyResult::Applied;
            case Option::Build:
                return ParseChoice(value, options.input, kInputValues)
                           ? ApplyResult::Applied
                           : ApplyResult::Invalid;
            case Option::Warnings:
                if (!ParseChoice(value,
                                 options.compiler.warningLevel,
                                 kWarningValues))
                    return ApplyResult::Invalid;
                options.warningOverride = true;
                return ApplyResult::Applied;
            case Option::Backend:
                return Contains(value, kBackendValues) ? ApplyResult::Applied
                                                       : ApplyResult::Invalid;
            case Option::LlvmOptLevel:
                if (!ParseChoice(value,
                                 options.compiler.llvmOptLevel,
                                 kLlvmOptValues))
                    return ApplyResult::Invalid;
                options.llvmOptOverride = true;
                return ApplyResult::Applied;
            case Option::LlvmCompiler:
                if (!ParseChoice(value,
                                 options.compiler.llvmCompiler,
                                 kLlvmCompilerValues))
                    return ApplyResult::Invalid;
                options.llvmCompilerOverride = true;
                return ApplyResult::Applied;
            case Option::LlvmLto:
                if (!ParseChoice(value,
                                 options.compiler.llvmLto,
                                 kLlvmLtoValues))
                    return ApplyResult::Invalid;
                options.llvmLtoOverride = true;
                return ApplyResult::Applied;
            case Option::Global:
                options.globalInstall = true;
                return ApplyResult::Applied;
            case Option::DryRun:
                options.formatterDryRun = true;
                return ApplyResult::Applied;
            case Option::Header:
                options.emitHeader = true;
                return ApplyResult::Applied;
            case Option::ViPkgType:
                return ParseChoice(value, options.viPkgType, kViPkgTypes)
                           ? ApplyResult::Applied
                           : ApplyResult::Invalid;
            case Option::ViPkg:
            case Option::Executable:
            case Option::Library:
            {
                if (!IsPackageSegment(value))
                    return ApplyResult::Invalid;
                auto *selected = &options.selectedViPkgs;
                if (spec.option == Option::Executable)
                    selected = &options.selectedExecutables;
                else if (spec.option == Option::Library)
                    selected = &options.selectedLibraries;
                if (std::find(selected->begin(), selected->end(), value)
                    != selected->end())
                    return ApplyResult::Invalid;
                selected->emplace_back(value);
                return ApplyResult::Applied;
            }
            default:
                return ApplyBoolean(spec.option, value, options);
        }
    }

    void
    ApplyInitialDefaults(CliOptions &options)
    {
        options.compiler = kCompilerDefaults;
        options.input = BuildInput::kTala;
        options.output = BuildOutput::kBinary;
        options.viPkgType = ViPkgType::kExecutable;
        options.standard = DefaultText(Option::Standard);
        options.compilerVersion = DefaultText(Option::CompilerVersion);
    }

    [[nodiscard]] bool
    IsPackageSegment(std::string_view value)
    {
        if (value.empty())
            return false;
        const auto isAsciiLetter = [](char character) {
            return (character >= 'A' && character <= 'Z')
                   || (character >= 'a' && character <= 'z');
        };
        if (!isAsciiLetter(value.front()))
            return false;
        return std::all_of(value.begin() + 1,
                           value.end(),
                           [isAsciiLetter](char character) {
                               return isAsciiLetter(character)
                                      || (character >= '0' && character <= '9')
                                      || character == '_';
                           });
    }

    [[nodiscard]] bool
    IsPackageCoordinate(std::string_view value)
    {
        // This is the same two-identifier contract enforced by the Kotlin
        // project model. Merely finding one dot accepted slashes, query
        // strings, whitespace, additional path segments, and non-ASCII bytes
        // into the future ViGet path.
        const auto separator = value.find('.');
        if (separator == std::string_view::npos
            || value.find('.', separator + 1U) != std::string_view::npos)
            return false;
        return IsPackageSegment(value.substr(0U, separator))
               && IsPackageSegment(value.substr(separator + 1U));
    }

    [[nodiscard]] bool
    ApplyPositional(const CommandSpec &command,
                    std::string_view value,
                    CliOptions &options)
    {
        if (command.positional == PositionalKind::None || value.empty())
            return false;
        if (command.positional == PositionalKind::ViGetAction)
            return ParseChoice(value, options.vigetAction, kViGetActions);
        if (command.positional == PositionalKind::ViPkgAction)
            return ParseChoice(value, options.viPkgAction, kViPkgActions);
        if (!IsPackageCoordinate(value))
            return false;
        options.packageCoordinate = value;
        return true;
    }

    [[nodiscard]] std::optional<std::string>
    ValidateCombination(const CommandSpec &command, const CliOptions &options)
    {
        if (command.positional != PositionalKind::None
            && !options.packageCoordinate)
        {
            if (command.positional == PositionalKind::ViGetAction
                && options.vigetAction != ViGetAction::kNone)
                return std::nullopt;
            if (command.positional == PositionalKind::ViPkgAction
                && options.viPkgAction != ViPkgAction::kNone)
                return std::nullopt;
            const auto expected
                = command.positional == PositionalKind::PackageCoordinate
                      ? "Publisher.Name"
                  : command.positional == PositionalKind::ViGetAction
                      ? "push|update"
                      : "create";
            return std::string(command.name) + " requires " + expected;
        }
        if (options.input != BuildInput::kTala && !options.filePath)
            return "-Build with an artifact input requires -File";
        return std::nullopt;
    }
} // namespace

CompilerSettings
DefaultCompilerSettings() noexcept
{
    return kCompilerDefaults;
}

void
ApplyCompilerOverrides(const CliOptions &options,
                       CompilerSettings &settings) noexcept
{
    // Project settings are the base layer. Only command-line fields explicitly
    // present in the schema override them, so defaults never erase DSL choices.
    if (options.warningOverride)
        settings.warningLevel = options.compiler.warningLevel;
    if (options.werrorOverride)
        settings.warningsAsErrors = options.compiler.warningsAsErrors;
    if (options.experimentalOverride)
        settings.experimentalWarnings = options.compiler.experimentalWarnings;
    if (options.shadowOverride)
        settings.shadowWarnings = options.compiler.shadowWarnings;
    if (options.undefOverride)
        settings.undefinedWarnings = options.compiler.undefinedWarnings;
    if (options.typeSafeFormatOverride)
        settings.typeSafeFormat = options.compiler.typeSafeFormat;
    if (options.xppOptimizationOverride)
        settings.xppOptimizationPasses = options.compiler.xppOptimizationPasses;
    if (options.xmmOptimizationOverride)
        settings.xmmOptimizationPasses = options.compiler.xmmOptimizationPasses;
    if (options.llvmOptOverride)
        settings.llvmOptLevel = options.compiler.llvmOptLevel;
    if (options.llvmCompilerOverride)
        settings.llvmCompiler = options.compiler.llvmCompiler;
    if (options.llvmLtoOverride)
        settings.llvmLto = options.compiler.llvmLto;
}

EffectiveCompilerOptions
ResolveCompilerOptions(const CliOptions &options,
                       const EffectiveCompilerOptions *projectDefaults)
{
    // Kotlin materializes both explicit DSL values and DSL defaults. Therefore
    // any project layer outranks CLI fallbacks, while the parser's presence
    // bits ensure only argv values explicitly supplied by the user can replace
    // it.
    EffectiveCompilerOptions result;
    if (projectDefaults != nullptr)
        result = *projectDefaults;
    else
    {
        result.compilerVersion = options.compilerVersion;
        result.standard = options.standard;
        result.target = std::nullopt;
        result.output = options.output;
        result.compiler = kCompilerDefaults;
    }

    if (options.compilerVersionOverride)
        result.compilerVersion = options.compilerVersion;
    if (options.standardOverride)
        result.standard = options.standard;
    if (options.targetOverride)
        result.target = options.target;
    if (options.outputOverride)
        result.output = options.output;
    ApplyCompilerOverrides(options, result.compiler);
    return result;
}

const char *
WarningLevelName(WarningLevel level) noexcept
{
    const auto spelling = ChoiceText(level, kWarningValues);
    return spelling.empty() ? "medium" : spelling.data();
}

const char *
OutputExtension(BuildOutput output) noexcept
{
    constexpr const char *extensions[]
        = { ".vxse", ".o", ".core", ".xpp", ".xmm", ".asm", ".ll", ".bc" };
    const auto index = static_cast<unsigned>(output);
    return index < 8U ? extensions[index] : "";
}

CliParseOutcome
ParseCommandLine(int argc, char **argv)
{
    CliOptions options{};
    ApplyInitialDefaults(options);
    if (argc < 0 || (argc > 0 && argv == nullptr))
        return Failure(std::move(options), "invalid process argument vector");

    if (argc < 2 || argv[1] == nullptr)
        return Failure(std::move(options),
                       "a command is required; use -Help to list commands");
    if (std::string_view(argv[1]) == kHelpOption)
        return { CliParseResult::kHelp, std::move(options), std::nullopt, {} };

    const auto command = FindCommand(argv[1]);
    if (!command)
        return Failure(std::move(options),
                       std::string("unknown command '") + argv[1] + "'");
    if (command->command == CliCommand::kVersion)
    {
        if (argc == 3 && argv[2] != nullptr
            && std::string_view(argv[2]) == kHelpOption)
            return { CliParseResult::kHelp,
                     std::move(options),
                     command->command,
                     {} };
        if (argc != 2)
            return Failure(std::move(options),
                           "version does not accept arguments");
        return { CliParseResult::kVersion,
                 std::move(options),
                 std::nullopt,
                 {} };
    }
    options.command = command->command;

    // `interactive` is a process boundary, not a compiler option group. Keep
    // the child parser authoritative and forward its argv spellings verbatim;
    // in particular, the child's --eval and -Help must not be consumed here.
    if (command->command == CliCommand::kInteractive)
    {
        for (int index = 2; index < argc; ++index)
        {
            if (argv[index] == nullptr)
                return Failure(std::move(options),
                               "process argument vector contains null");
            options.interactiveArguments.emplace_back(argv[index]);
        }
        return { CliParseResult::kReady, std::move(options), std::nullopt, {} };
    }

    std::array<bool, static_cast<unsigned>(Option::Count)> seen{};
    bool positionalSeen = false;
    for (int index = 2; index < argc; ++index)
    {
        if (argv[index] == nullptr)
            return Failure(std::move(options),
                           "process argument vector contains null");
        const std::string_view argument(argv[index]);
        if (argument == "--")
        {
            if (command->command != CliCommand::kRun)
                return Failure(std::move(options),
                               "-- is only valid for run program arguments");
            for (++index; index < argc; ++index)
            {
                if (argv[index] == nullptr)
                    return Failure(std::move(options),
                                   "process argument vector contains null");
                options.programArguments.emplace_back(argv[index]);
            }
            break;
        }
        if (argument == kHelpOption)
        {
            return { CliParseResult::kHelp,
                     std::move(options),
                     command->command,
                     {} };
        }
        if (!argument.starts_with('-'))
        {
            if (positionalSeen)
                return Failure(std::move(options),
                               std::string("unexpected positional argument '")
                                   + std::string(argument) + "'");
            if (!ApplyPositional(*command, argument, options))
            {
                if (command->positional == PositionalKind::ViGetAction)
                    return Failure(std::move(options),
                                   std::string("invalid viget action '")
                                       + std::string(argument)
                                       + "'; expected push|update");
                if (command->positional == PositionalKind::ViPkgAction)
                    return Failure(std::move(options),
                                   std::string("invalid vipkg action '")
                                       + std::string(argument)
                                       + "'; expected create");
                if (command->positional == PositionalKind::PackageCoordinate)
                    return Failure(std::move(options),
                                   std::string("invalid package coordinate '")
                                       + std::string(argument)
                                       + "'; expected Publisher.Name");
                return Failure(std::move(options),
                               std::string("unexpected positional argument '")
                                   + std::string(argument) + "'");
            }
            positionalSeen = true;
            continue;
        }

        const OptionSpec *spec = FindOption(argument);
        if (spec == nullptr)
            return Failure(std::move(options),
                           std::string("unknown option '")
                               + std::string(argument) + "'");
        if ((spec->commands & Bit(command->command)) == 0U)
            return Failure(std::move(options),
                           std::string(spec->spelling) + " is not valid for "
                               + std::string(command->name));
        const auto optionIndex = static_cast<unsigned>(spec->option);
        if (seen[optionIndex])
            return Failure(std::move(options),
                           std::string(spec->spelling)
                               + " was specified more than once");
        seen[optionIndex] = true;

        std::string_view value;
        if (spec->domain != ValueDomain::None)
        {
            if (index + 1 >= argc || argv[index + 1] == nullptr
                || std::string_view(argv[index + 1]).starts_with('-'))
                return Failure(std::move(options),
                               std::string(spec->spelling) + " requires "
                                   + DomainText(spec->domain));
            value = argv[++index];
        }
        const auto applied = ApplyOption(*spec, value, options);
        if (applied == ApplyResult::Invalid)
            return FailOption(std::move(options), *spec, value);
        if (spec->domain == ValueDomain::TargetNameList)
        {
            while (index + 1 < argc && argv[index + 1] != nullptr
                   && !std::string_view(argv[index + 1]).starts_with('-'))
            {
                value = argv[++index];
                if (ApplyOption(*spec, value, options) == ApplyResult::Invalid)
                    return FailOption(std::move(options), *spec, value);
            }
        }
    }

    if (auto diagnostic = ValidateCombination(*command, options))
        return Failure(std::move(options), std::move(*diagnostic));
    return { CliParseResult::kReady, std::move(options), std::nullopt, {} };
}

void
PrintCliHelp(std::optional<CliCommand> command)
{
    if (!command)
    {
        PrintHelp(nullptr);
        return;
    }
    for (const auto &spec : kCommands)
    {
        if (spec.command == *command)
        {
            PrintHelp(&spec);
            return;
        }
    }
}

void
PrintCliVersion()
{
    fmt::print("talac {}\n", TALA_PROJECT_VERSION);
}
