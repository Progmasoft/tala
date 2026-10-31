// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <fmt/format.h>
#include <optional>
#include <span>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>

#include "TableLibrary.hpp"
#include "Talac/Cli/Arguments/Options.hpp"

#ifndef TALA_PROJECT_VERSION
#    define TALA_PROJECT_VERSION "0.2.0"
#endif

namespace
{
    using std::literals::operator""sv;

    enum class Option : std::uint8_t
    {
        Version,
        Help,
        Entry,
        Standard,
        Target,
        WarningsAsErrors,
        Warnings,
        CodegenBackend,
        OptLevel,
        LlvmCompiler,
        LlvmLto,
        LlvmArgs,
        XppOptimizationPasses,
        XmmOptimizationPasses,
        Emit,
        Build,
        ViPkgType,
        Header,
        Test,
        Sysroot,
        Incremental,
        StaticTalartLibrary,
        Count,
    };

    constexpr auto kOptionCount = static_cast<std::size_t>(Option::Count);

    /// One row of the command-line schema. Parsing, the duplicate check and
    /// the help text are all read from this table, so an option cannot be
    /// accepted without being described.
    struct OptionSpec
    {
        Option option;
        std::string_view longName;
        char shortName;         ///< NUL when the option has no short form.
        std::string_view value; ///< Empty for an option without a value.
        std::string_view description;
        std::string_view defaultValue;
    };

    constexpr std::array<OptionSpec, kOptionCount> kOptions{ {
        { Option::Version,
          "version",
          'v',
          "",
          "print the version of talac",
          "" },
        { Option::Help, "help", 'h', "", "print this help", "" },
        { Option::Entry,
          "entry",
          '\0',
          "Namespace.Class",
          "class whose Main starts the program; required for an "
          "executable built from Tala sources",
          "" },
        { Option::Standard, "standard", '\0', "26", "language standard", "26" },
        { Option::Target,
          "target",
          't',
          "<llvm-target-triple>",
          "target of the generated code",
          "host" },
        { Option::WarningsAsErrors,
          "warnings-as-errors",
          '\0',
          "true|false",
          "fail when a warning is reported",
          "false" },
        { Option::Warnings,
          "warnings",
          '\0',
          "none|low|medium|all[,shadow]",
          "which warnings are reported; shadow is asked for by name and "
          "may be given in a list or by writing the option again",
          "medium" },
        { Option::CodegenBackend,
          "codegen-backend",
          '\0',
          "llvm",
          "code generator",
          "llvm" },
        { Option::OptLevel,
          "opt-level",
          'O',
          "0|1|2|3|g|s|z",
          "optimization level",
          "2" },
        { Option::LlvmCompiler,
          "llvm-compiler",
          '\0',
          "aot|orc",
          "ahead-of-time compilation or the ORC JIT",
          "aot" },
        { Option::LlvmLto,
          "llvm-lto",
          '\0',
          "fat|thin|none",
          "link-time optimization",
          "none" },
        { Option::LlvmArgs,
          "llvm-args",
          '\0',
          "<argument>[,<argument>...]",
          "arguments handed to LLVM as written",
          "" },
        { Option::XppOptimizationPasses,
          "xpp-optimization-passes",
          '\0',
          "true|false",
          "run the Xpp optimizations",
          "true" },
        { Option::XmmOptimizationPasses,
          "xmm-optimization-passes",
          '\0',
          "true|false",
          "run the Xmm optimizations",
          "true" },
        { Option::Emit,
          "emit",
          '\0',
          "executable|object|core|xpp|xmm|assembly|llvm-ir|llvm-bitcode|"
          "metadata",
          "what is written; metadata checks the program and writes a "
          ".talameta file and no executable",
          "executable" },
        { Option::Build,
          "build",
          '\0',
          "tala|object|core|xpp|xmm|llvm-ir|llvm-bitcode",
          "kind of the inputs",
          "tala" },
        { Option::ViPkgType,
          "vipkg-type",
          '\0',
          "executable|staticlib|cdylib|talalib",
          "kind of the package being built",
          "executable" },
        { Option::Header,
          "header",
          '\0',
          "",
          "write a C header; with --vipkg-type=staticlib or cdylib",
          "" },
        { Option::Test,
          "test",
          '\0',
          "",
          "build the runner of the [Fact] methods; Fact holds in #if",
          "" },
        { Option::Sysroot,
          "sysroot",
          '\0',
          "<path>",
          "system root of the target, for what the build links",
          "the linker's" },
        { Option::Incremental,
          "incremental",
          '\0',
          "<path>",
          "keep an object per source here and lower only what changed",
          "off" },
        { Option::StaticTalartLibrary,
          "static-talart-library",
          '\0',
          "true|false",
          "link TalaRT into the output instead of beside it",
          "false" },
    } };

    template<typename Value>
    struct Choice
    {
        std::string_view spelling;
        Value value;
    };

    constexpr std::array kWarningValues{
        Choice{ "all"sv, WarningLevel::kAll },
        Choice{ "medium"sv, WarningLevel::kMedium },
        Choice{ "low"sv, WarningLevel::kLow },
        Choice{ "none"sv, WarningLevel::kNone },
    };
    constexpr std::array kOptLevelValues{
        Choice{ "0"sv, LlvmOptLevel::kO0 }, Choice{ "1"sv, LlvmOptLevel::kO1 },
        Choice{ "2"sv, LlvmOptLevel::kO2 }, Choice{ "3"sv, LlvmOptLevel::kO3 },
        Choice{ "g"sv, LlvmOptLevel::kOg }, Choice{ "s"sv, LlvmOptLevel::kOs },
        Choice{ "z"sv, LlvmOptLevel::kOz },
    };
    constexpr std::array kLlvmCompilerValues{
        Choice{ "aot"sv, LlvmCompiler::kAot },
        Choice{ "orc"sv, LlvmCompiler::kOrc },
    };
    constexpr std::array kLlvmLtoValues{
        Choice{ "fat"sv, LlvmLto::kFat },
        Choice{ "thin"sv, LlvmLto::kThin },
        Choice{ "none"sv, LlvmLto::kNone },
    };
    constexpr std::array kEmitValues{
        Choice{ "executable"sv, BuildOutput::kExecutable },
        Choice{ "object"sv, BuildOutput::kObject },
        Choice{ "core"sv, BuildOutput::kCore },
        Choice{ "xpp"sv, BuildOutput::kXpp },
        Choice{ "xmm"sv, BuildOutput::kXmm },
        Choice{ "assembly"sv, BuildOutput::kAssembly },
        Choice{ "llvm-ir"sv, BuildOutput::kLlvmIr },
        Choice{ "llvm-bitcode"sv, BuildOutput::kLlvmBitcode },
        Choice{ "metadata"sv, BuildOutput::kMetadata },
    };
    constexpr std::array kBuildValues{
        Choice{ "tala"sv, BuildInput::kTala },
        Choice{ "object"sv, BuildInput::kObject },
        Choice{ "core"sv, BuildInput::kCore },
        Choice{ "xpp"sv, BuildInput::kXpp },
        Choice{ "xmm"sv, BuildInput::kXmm },
        Choice{ "llvm-ir"sv, BuildInput::kLlvmIr },
        Choice{ "llvm-bitcode"sv, BuildInput::kLlvmBitcode },
    };
    constexpr std::array kViPkgTypeValues{
        Choice{ "executable"sv, ViPkgType::kExecutable },
        Choice{ "staticlib"sv, ViPkgType::kStaticLibrary },
        Choice{ "cdylib"sv, ViPkgType::kDynamicLibrary },
        Choice{ "talalib"sv, ViPkgType::kTalaLibrary },
    };

    constexpr CompilerSettings kCompilerDefaults{
        .warningLevel = WarningLevel::kMedium,
        .warningsAsErrors = false,
        .shadowWarnings = false,
        .xppOptimizationPasses = true,
        .xmmOptimizationPasses = true,
        .llvmOptLevel = LlvmOptLevel::kO2,
        .llvmCompiler = LlvmCompiler::kAot,
        .llvmLto = LlvmLto::kNone,
        .sysroot = nullptr,
        .incrementalDirectory = nullptr,
        .staticTalartLibrary = false,
    };

    template<typename Value, std::size_t Size>
    [[nodiscard]] std::optional<Value>
    Find(std::string_view spelling,
         const std::array<Choice<Value>, Size> &choices)
    {
        for (const auto &choice : choices)
        {
            if (choice.spelling == spelling)
                return choice.value;
        }
        return std::nullopt;
    }

    [[nodiscard]] std::optional<bool>
    Boolean(std::string_view spelling)
    {
        if (spelling == "true")
            return true;
        if (spelling == "false")
            return false;
        return std::nullopt;
    }

    [[nodiscard]] const OptionSpec *
    FindLong(std::string_view name)
    {
        for (const auto &spec : kOptions)
        {
            if (spec.longName == name)
                return &spec;
        }
        return nullptr;
    }

    [[nodiscard]] const OptionSpec *
    FindShort(char name)
    {
        for (const auto &spec : kOptions)
        {
            if (spec.shortName != '\0' && spec.shortName == name)
                return &spec;
        }
        return nullptr;
    }

    /// A path from the command line is UTF-8. A sequence that is not would
    /// make the conversion to a native path throw on Windows, and this
    /// compiler is built without exceptions.
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

    [[nodiscard]] std::filesystem::path
    Utf8Path(std::string_view value)
    {
        return { std::u8string(value.begin(), value.end()) };
    }

    [[nodiscard]] bool
    IsIdentifier(std::string_view text)
    {
        if (text.empty())
            return false;
        const auto first = static_cast<unsigned char>(text.front());
        if (std::isalpha(first) == 0 && first != '_')
            return false;
        return std::ranges::all_of(text.substr(1U), [](char value) {
            const auto byte = static_cast<unsigned char>(value);
            return std::isalnum(byte) != 0 || byte == '_';
        });
    }

    /// An entry names a class inside a namespace, so it has at least two
    /// identifiers joined by dots.
    [[nodiscard]] bool
    IsEntryName(std::string_view text)
    {
        std::size_t parts{};
        while (true)
        {
            const auto dot = text.find('.');
            if (!IsIdentifier(text.substr(0U, dot)))
                return false;
            ++parts;
            if (dot == std::string_view::npos)
                break;
            text.remove_prefix(dot + 1U);
        }
        return parts >= 2U;
    }

    [[nodiscard]] std::string
    Spelling(const OptionSpec &spec)
    {
        return fmt::format("--{}", spec.longName);
    }

    [[nodiscard]] CliParseOutcome
    Failure(CliOptions options, std::string diagnostic)
    {
        return { CliParseResult::kError,
                 std::move(options),
                 std::move(diagnostic) };
    }

    /// Store the value of one option. False means the value is not one the
    /// option accepts.
    [[nodiscard]] bool
    Apply(const OptionSpec &spec, std::string_view value, CliOptions &options)
    {
        switch (spec.option)
        {
            case Option::Entry:
                if (!IsEntryName(value))
                    return false;
                options.entry = std::string(value);
                return true;
            case Option::Standard:
                if (value != "26")
                    return false;
                options.standard = value;
                return true;
            case Option::Target:
                if (value.empty())
                    return false;
                options.target = std::string(value);
                return true;
            case Option::WarningsAsErrors:
                if (const auto parsed = Boolean(value))
                {
                    options.compiler.warningsAsErrors = *parsed;
                    return true;
                }
                return false;
            case Option::Warnings:
                // Read by ApplyWarnings, which keeps what earlier
                // occurrences of the option said.
                return false;
            case Option::CodegenBackend:
                return value == "llvm";
            case Option::OptLevel:
                if (const auto parsed = Find(value, kOptLevelValues))
                {
                    options.compiler.llvmOptLevel = *parsed;
                    return true;
                }
                return false;
            case Option::LlvmCompiler:
                if (const auto parsed = Find(value, kLlvmCompilerValues))
                {
                    options.compiler.llvmCompiler = *parsed;
                    return true;
                }
                return false;
            case Option::LlvmLto:
                if (const auto parsed = Find(value, kLlvmLtoValues))
                {
                    options.compiler.llvmLto = *parsed;
                    return true;
                }
                return false;
            case Option::LlvmArgs:
                while (true)
                {
                    const auto comma = value.find(',');
                    const auto argument = value.substr(0U, comma);
                    if (argument.empty())
                        return false;
                    options.llvmArguments.emplace_back(argument);
                    if (comma == std::string_view::npos)
                        return true;
                    value.remove_prefix(comma + 1U);
                }
            case Option::XppOptimizationPasses:
                if (const auto parsed = Boolean(value))
                {
                    options.compiler.xppOptimizationPasses = *parsed;
                    return true;
                }
                return false;
            case Option::XmmOptimizationPasses:
                if (const auto parsed = Boolean(value))
                {
                    options.compiler.xmmOptimizationPasses = *parsed;
                    return true;
                }
                return false;
            case Option::Emit:
                if (const auto parsed = Find(value, kEmitValues))
                {
                    options.output = *parsed;
                    return true;
                }
                return false;
            case Option::Build:
                if (const auto parsed = Find(value, kBuildValues))
                {
                    options.input = *parsed;
                    return true;
                }
                return false;
            case Option::ViPkgType:
                if (const auto parsed = Find(value, kViPkgTypeValues))
                {
                    options.viPkgType = *parsed;
                    return true;
                }
                return false;
            case Option::Header:
                options.emitHeader = true;
                return true;
            case Option::Test:
                options.test = true;
                return true;
            case Option::StaticTalartLibrary:
                if (const auto parsed = Boolean(value))
                {
                    options.compiler.staticTalartLibrary = *parsed;
                    return true;
                }
                return false;
            case Option::Sysroot:
                if (value.empty())
                    return false;
                options.sysroot = std::string(value);
                return true;
            case Option::Incremental:
                if (value.empty())
                    return false;
                options.incremental = std::string(value);
                return true;
            case Option::Version:
            case Option::Help:
            case Option::Count:
                return true;
        }
        return false;
    }

    /// What the occurrences of `--warnings` said so far. The option is the
    /// one that may be written again, because a level and `shadow` are two
    /// separate things to ask for.
    struct WarningsSeen
    {
        bool level{};
        bool shadow{};
    };

    /// Read one `--warnings` value: a list of a level and `shadow`, each at
    /// most once over the whole command line. The result is the reason the
    /// value is refused, or nothing.
    [[nodiscard]] std::optional<std::string>
    ApplyWarnings(std::string_view value,
                  CliOptions &options,
                  WarningsSeen &seen)
    {
        while (true)
        {
            const auto comma = value.find(',');
            const auto word = value.substr(0U, comma);
            if (word == "shadow")
            {
                if (seen.shadow)
                    return "--warnings names shadow twice";
                seen.shadow = true;
                options.compiler.shadowWarnings = true;
            }
            else if (const auto level = Find(word, kWarningValues))
            {
                if (seen.level)
                    return fmt::format("--warnings names a second level, "
                                       "'{}'; a level is one of "
                                       "none|low|medium|all",
                                       word);
                seen.level = true;
                options.compiler.warningLevel = *level;
            }
            else
                return fmt::format("invalid value '{}' for --warnings; "
                                   "expected none|low|medium|all and, beside "
                                   "a level or alone, shadow",
                                   word);
            if (comma == std::string_view::npos)
                return std::nullopt;
            value.remove_prefix(comma + 1U);
        }
    }

    /// What the options say together, after each of them was accepted alone.
    [[nodiscard]] std::optional<std::string>
    ValidateCombination(const CliOptions &options)
    {
        if (options.inputs.empty())
            return "an input file is required; use --help for usage";
        if (options.compiler.shadowWarnings
            && options.compiler.warningLevel == WarningLevel::kNone)
            return "--warnings=none reports nothing; it cannot be combined "
                   "with shadow";
        if (options.incremental
            && (options.output != BuildOutput::kExecutable
                || options.viPkgType != ViPkgType::kExecutable
                || options.input != BuildInput::kTala))
            return "--incremental keeps the objects of an executable built "
                   "from Tala sources; this build writes none";
        if (options.test)
        {
            if (options.entry)
                return "--test builds the runner of the [Fact] methods, "
                       "which is the entry; it takes no --entry";
            if (options.input != BuildInput::kTala)
                return "--test compiles Tala sources; write --build=tala";
            if (options.viPkgType != ViPkgType::kExecutable)
                return "--test builds an executable; it cannot be combined "
                       "with another --vipkg-type";
            return std::nullopt;
        }
        if (options.viPkgType == ViPkgType::kExecutable)
        {
            if (options.emitHeader)
                return "--header requires --vipkg-type=staticlib or "
                       "--vipkg-type=cdylib";
            // A check builds nothing, so it needs no place to start from:
            // one source is checked as it stands. Several sources are one
            // program, and the entry selects the namespace that is lowered.
            const bool check = options.output == BuildOutput::kMetadata;
            if (options.input == BuildInput::kTala && !options.entry)
            {
                if (!check)
                    return "--entry is required for an executable; write "
                           "--entry=Namespace.Class";
                if (options.inputs.size() > 1U)
                    return "--entry is required to check several sources "
                           "as one program; write --entry=Namespace.Class";
            }
            if (options.input != BuildInput::kTala && options.entry)
                return "--entry belongs to Tala sources; this input already "
                       "carries its entry";
        }
        else
        {
            if (options.entry)
                return "--entry cannot be written unless "
                       "--vipkg-type=executable";
            if (options.emitHeader
                && options.viPkgType == ViPkgType::kTalaLibrary)
                return "--header requires --vipkg-type=staticlib or "
                       "--vipkg-type=cdylib";
        }
        return std::nullopt;
    }

    struct Argument
    {
        const OptionSpec *spec;
        std::optional<std::string_view> value;
        std::string spelling; ///< As the user wrote the option name.
    };

    /// Split one option argument into its schema row and its value. A long
    /// option carries its value after `=`; a short option carries it joined
    /// or after `=`.
    [[nodiscard]] std::optional<Argument>
    Recognize(std::string_view text)
    {
        if (text.starts_with("--"))
        {
            const auto body = text.substr(2U);
            const auto equals = body.find('=');
            const auto *spec = FindLong(body.substr(0U, equals));
            if (spec == nullptr)
                return std::nullopt;
            return Argument{ spec,
                             equals == std::string_view::npos
                                 ? std::nullopt
                                 : std::optional{ body.substr(equals + 1U) },
                             fmt::format("--{}", spec->longName) };
        }
        if (text.size() < 2U)
            return std::nullopt;
        const auto *spec = FindShort(text[1]);
        if (spec == nullptr)
            return std::nullopt;
        auto rest = text.substr(2U);
        if (rest.starts_with('='))
            rest.remove_prefix(1U);
        else if (rest.empty())
            return Argument{ spec,
                             std::nullopt,
                             fmt::format("-{}", spec->shortName) };
        return Argument{ spec, rest, fmt::format("-{}", spec->shortName) };
    }
} // namespace

CompilerSettings
DefaultCompilerSettings() noexcept
{
    return kCompilerDefaults;
}

const char *
WarningLevelName(WarningLevel level) noexcept
{
    for (const auto &choice : kWarningValues)
    {
        if (choice.value == level)
            return choice.spelling.data();
    }
    return "medium";
}

const char *
OutputExtension(BuildOutput output) noexcept
{
#if defined(_WIN32)
    constexpr const char *kExecutable = ".exe";
#else
    constexpr const char *kExecutable = "";
#endif
    constexpr const char *extensions[]
        = { kExecutable, ".o",  ".core", ".xpp",     ".xmm",
            ".asm",      ".ll", ".bc",   ".talameta" };
    const auto index = static_cast<unsigned>(output);
    return index < 9U ? extensions[index] : "";
}

std::string_view
InputExtension(BuildInput input) noexcept
{
    constexpr std::string_view extensions[]
        = { ".tala", ".o", ".core", ".xpp", ".xmm", ".ll", ".bc" };
    const auto index = static_cast<unsigned>(input);
    return index < 7U ? extensions[index] : std::string_view{};
}

CliParseOutcome
ParseCommandLine(int argc, char **argv)
{
    CliOptions options{};
    options.standard = "26";
    options.output = BuildOutput::kExecutable;
    options.input = BuildInput::kTala;
    options.viPkgType = ViPkgType::kExecutable;
    options.compiler = kCompilerDefaults;

    std::array<bool, kOptionCount> seen{};
    WarningsSeen warnings;
    bool onlyInputs = false;
    for (int index = 1; index < argc; ++index)
    {
        if (argv[index] == nullptr)
            return Failure(std::move(options),
                           "process argument vector contains null");
        const std::string_view text(argv[index]);
        if (onlyInputs || text.empty() || text.front() != '-' || text == "-")
        {
            if (text.empty() || !IsWellFormedUtf8(text))
                return Failure(std::move(options),
                               "an input file name is empty or is not valid "
                               "UTF-8");
            options.inputs.push_back(Utf8Path(text));
            continue;
        }
        if (text == "--")
        {
            onlyInputs = true;
            continue;
        }
        const auto argument = Recognize(text);
        if (!argument)
            return Failure(
                std::move(options),
                fmt::format("unknown option '{}'; use --help for usage", text));
        const auto &spec = *argument->spec;
        const bool takesValue = !spec.value.empty();
        if (takesValue && !argument->value)
            return Failure(std::move(options),
                           fmt::format("{} requires a value: {}={}",
                                       argument->spelling,
                                       Spelling(spec),
                                       spec.value));
        if (!takesValue && argument->value)
            return Failure(
                std::move(options),
                fmt::format("{} does not take a value", argument->spelling));
        if (spec.option == Option::Help)
            return { CliParseResult::kHelp, std::move(options), {} };
        if (spec.option == Option::Version)
            return { CliParseResult::kVersion, std::move(options), {} };
        if (spec.option == Option::Warnings)
        {
            if (auto problem = ApplyWarnings(argument->value.value_or(""sv),
                                             options,
                                             warnings))
                return Failure(std::move(options), std::move(*problem));
            continue;
        }
        auto &alreadySeen = seen[static_cast<std::size_t>(spec.option)];
        if (alreadySeen)
            return Failure(
                std::move(options),
                fmt::format("{} may be written only once", Spelling(spec)));
        alreadySeen = true;
        if (!Apply(spec, argument->value.value_or(""sv), options))
            return Failure(std::move(options),
                           fmt::format("invalid value '{}' for {}; expected {}",
                                       argument->value.value_or(""sv),
                                       Spelling(spec),
                                       spec.value));
    }

    if (auto diagnostic = ValidateCombination(options))
        return Failure(std::move(options), std::move(*diagnostic));
    return { CliParseResult::kReady, std::move(options), {} };
}

void
PrintCliHelp()
{
    fmt::print("Usage: talac <input>... [options]\n\n"
               "talac compiles the inputs it is given and writes one output "
               "beside the first of them.\n"
               "A long option takes its value after '='. A short option takes "
               "it joined or after '='.\n");
    tabulate::Table table;
    table.add_row({ "Option", "Description", "Default" });
    for (const auto &spec : kOptions)
    {
        auto signature = fmt::format("--{}", spec.longName);
        if (!spec.value.empty())
            signature += fmt::format("={}", spec.value);
        if (spec.shortName != '\0')
            signature += spec.value.empty()
                             ? fmt::format(", -{}", spec.shortName)
                             : fmt::format(", -{}<value>", spec.shortName);
        table.add_row({ std::move(signature),
                        std::string(spec.description),
                        std::string(spec.defaultValue) });
    }
    table[0].format().font_style({ tabulate::FontStyle::bold });
    table.column(0).format().font_align(tabulate::FontAlign::left).width(44);
    table.column(1).format().font_align(tabulate::FontAlign::left).width(48);
    table.column(2).format().font_align(tabulate::FontAlign::left);
    std::ostringstream rendered;
    rendered << table;
    fmt::print("\n{}\n\n"
               "Example: talac Program.tala --entry=Namespace.Program\n",
               rendered.str());
}

const char *
CliVersion() noexcept
{
    return TALA_PROJECT_VERSION;
}

void
PrintCliVersion()
{
    fmt::print("talac {}\n", CliVersion());
}
