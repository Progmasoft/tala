// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <catch2/catch_test_macros.hpp>
#include <filesystem>
#include <initializer_list>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Talac/Cli/Arguments/Options.hpp"

namespace
{
    /// The outcome of parsing `talac` followed by the given arguments.
    [[nodiscard]] auto
    Parse(std::initializer_list<const char *> written) -> CliParseOutcome
    {
        std::vector<std::string> storage{ "talac" };
        for (const auto *argument : written)
            storage.emplace_back(argument);
        std::vector<char *> arguments;
        arguments.reserve(storage.size() + 1U);
        for (auto &argument : storage)
            arguments.push_back(argument.data());
        arguments.push_back(nullptr);
        return ParseCommandLine(static_cast<int>(storage.size()),
                                arguments.data());
    }

    [[nodiscard]] auto
    Ready(std::initializer_list<const char *> written) -> CliOptions
    {
        const auto outcome = Parse(written);
        INFO(outcome.diagnostic);
        REQUIRE(outcome.result == CliParseResult::kReady);
        return outcome.options;
    }

    [[nodiscard]] auto
    Rejected(std::initializer_list<const char *> written) -> std::string
    {
        const auto outcome = Parse(written);
        REQUIRE(outcome.result == CliParseResult::kError);
        REQUIRE_FALSE(outcome.diagnostic.empty());
        return outcome.diagnostic;
    }

    [[nodiscard]] auto
    Mentions(const std::string &text, std::string_view part) -> bool
    {
        return text.find(part) != std::string::npos;
    }
} // namespace

TEST_CASE("the example of the documentation parses to the defaults")
{
    const auto options = Ready({ "Program.tala", "--entry=Namespace.Program" });
    REQUIRE(options.inputs.size() == 1U);
    CHECK(options.inputs.front() == std::filesystem::path("Program.tala"));
    CHECK(options.entry == "Namespace.Program");
    CHECK(options.standard == "26");
    CHECK_FALSE(options.target.has_value());
    CHECK(options.output == BuildOutput::kExecutable);
    CHECK(options.input == BuildInput::kTala);
    CHECK(options.viPkgType == ViPkgType::kExecutable);
    CHECK(options.compiler == DefaultCompilerSettings());
    CHECK(options.llvmArguments.empty());
    CHECK_FALSE(options.emitHeader);
}

TEST_CASE("the defaults are the documented ones")
{
    const auto defaults = DefaultCompilerSettings();
    CHECK(defaults.warningLevel == WarningLevel::kMedium);
    CHECK_FALSE(defaults.warningsAsErrors);
    CHECK_FALSE(defaults.shadowWarnings);
    CHECK(defaults.xppOptimizationPasses);
    CHECK(defaults.xmmOptimizationPasses);
    CHECK(defaults.llvmOptLevel == LlvmOptLevel::kO2);
    CHECK(defaults.llvmCompiler == LlvmCompiler::kAot);
    CHECK(defaults.llvmLto == LlvmLto::kNone);
}

TEST_CASE("help and version are recognized in both forms and need no input")
{
    CHECK(Parse({ "--help" }).result == CliParseResult::kHelp);
    CHECK(Parse({ "-h" }).result == CliParseResult::kHelp);
    CHECK(Parse({ "--version" }).result == CliParseResult::kVersion);
    CHECK(Parse({ "-v" }).result == CliParseResult::kVersion);
    // Asking for help wins over whatever else the line says after it.
    CHECK(Parse({ "--help", "--no-such-option" }).result
          == CliParseResult::kHelp);
    CHECK(Mentions(Rejected({ "--help=yes" }), "does not take a value"));
    CHECK(Mentions(Rejected({ "-v=1" }), "does not take a value"));
}

TEST_CASE("a long option takes its value after an equals sign")
{
    const auto options = Ready({ "Program.tala",
                                 "--entry=Demo.Program",
                                 "--standard=26",
                                 "--target=x86_64-unknown-linux-gnu",
                                 "--warnings-as-errors=true",
                                 "--warnings=all",
                                 "--codegen-backend=llvm",
                                 "--opt-level=3",
                                 "--llvm-compiler=orc",
                                 "--llvm-lto=thin",
                                 "--llvm-args=-time-passes,-print-after-all",
                                 "--xpp-optimization-passes=false",
                                 "--xmm-optimization-passes=false",
                                 "--emit=llvm-ir",
                                 "--build=tala",
                                 "--vipkg-type=executable" });
    CHECK(options.target == "x86_64-unknown-linux-gnu");
    CHECK(options.compiler.warningsAsErrors);
    CHECK(options.compiler.warningLevel == WarningLevel::kAll);
    CHECK(options.compiler.llvmOptLevel == LlvmOptLevel::kO3);
    CHECK(options.compiler.llvmCompiler == LlvmCompiler::kOrc);
    CHECK(options.compiler.llvmLto == LlvmLto::kThin);
    CHECK(options.llvmArguments
          == std::vector<std::string>{ "-time-passes", "-print-after-all" });
    CHECK_FALSE(options.compiler.xppOptimizationPasses);
    CHECK_FALSE(options.compiler.xmmOptimizationPasses);
    CHECK(options.output == BuildOutput::kLlvmIr);

    // A value in the next argument is an input file, not a value.
    CHECK(Mentions(Rejected({ "Program.tala", "--entry", "Demo.Program" }),
                   "requires a value"));
    CHECK(Mentions(Rejected({ "Program.tala", "--emit" }), "requires a value"));
}

TEST_CASE("a short option takes its value joined or after an equals sign")
{
    CHECK(Ready({ "P.tala", "--entry=A.B", "-O3" }).compiler.llvmOptLevel
          == LlvmOptLevel::kO3);
    CHECK(Ready({ "P.tala", "--entry=A.B", "-O=1" }).compiler.llvmOptLevel
          == LlvmOptLevel::kO1);
    CHECK(Ready({ "P.tala", "--entry=A.B", "-Og" }).compiler.llvmOptLevel
          == LlvmOptLevel::kOg);
    CHECK(Ready({ "P.tala", "--entry=A.B", "-O0" }).compiler.llvmOptLevel
          == LlvmOptLevel::kO0);
    CHECK(Ready({ "P.tala", "--entry=A.B", "-taarch64-apple-darwin" }).target
          == "aarch64-apple-darwin");
    CHECK(Ready({ "P.tala", "--entry=A.B", "-t=aarch64-apple-darwin" }).target
          == "aarch64-apple-darwin");
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "-O" }),
                   "requires a value"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "-O", "2" }),
                   "requires a value"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "-O4" }),
                   "invalid value '4'"));
    // An option that has no short form is not guessed from its first letter.
    CHECK(Mentions(Rejected({ "P.tala", "-eA.B" }), "unknown option"));
}

TEST_CASE("every choice of every option is spelled as documented")
{
    const auto emits
        = { std::pair{ "--emit=executable", BuildOutput::kExecutable },
            std::pair{ "--emit=object", BuildOutput::kObject },
            std::pair{ "--emit=core", BuildOutput::kCore },
            std::pair{ "--emit=xpp", BuildOutput::kXpp },
            std::pair{ "--emit=xmm", BuildOutput::kXmm },
            std::pair{ "--emit=assembly", BuildOutput::kAssembly },
            std::pair{ "--emit=llvm-ir", BuildOutput::kLlvmIr },
            std::pair{ "--emit=llvm-bitcode", BuildOutput::kLlvmBitcode },
            std::pair{ "--emit=metadata", BuildOutput::kMetadata } };
    for (const auto &[spelling, expected] : emits)
        CHECK(Ready({ "P.tala", "--entry=A.B", spelling }).output == expected);

    const auto builds
        = { std::pair{ "--build=object", BuildInput::kObject },
            std::pair{ "--build=core", BuildInput::kCore },
            std::pair{ "--build=xpp", BuildInput::kXpp },
            std::pair{ "--build=xmm", BuildInput::kXmm },
            std::pair{ "--build=llvm-ir", BuildInput::kLlvmIr },
            std::pair{ "--build=llvm-bitcode", BuildInput::kLlvmBitcode } };
    for (const auto &[spelling, expected] : builds)
        CHECK(Ready({ "P.input", spelling }).input == expected);

    const auto warnings
        = { std::pair{ "--warnings=none", WarningLevel::kNone },
            std::pair{ "--warnings=low", WarningLevel::kLow },
            std::pair{ "--warnings=medium", WarningLevel::kMedium },
            std::pair{ "--warnings=all", WarningLevel::kAll } };
    for (const auto &[spelling, expected] : warnings)
        CHECK(Ready({ "P.tala", "--entry=A.B", spelling }).compiler.warningLevel
              == expected);

    CHECK(Ready({ "P.tala", "--entry=A.B", "--llvm-lto=fat" }).compiler.llvmLto
          == LlvmLto::kFat);
    CHECK(Ready({ "P.tala", "--entry=A.B", "--llvm-lto=none" }).compiler.llvmLto
          == LlvmLto::kNone);
    CHECK(Ready({ "P.tala", "--entry=A.B", "--llvm-compiler=aot" })
              .compiler.llvmCompiler
          == LlvmCompiler::kAot);
    CHECK(Ready({ "P.tala", "--vipkg-type=staticlib" }).viPkgType
          == ViPkgType::kStaticLibrary);
    CHECK(Ready({ "P.tala", "--vipkg-type=cdylib" }).viPkgType
          == ViPkgType::kDynamicLibrary);
    CHECK(Ready({ "P.tala", "--vipkg-type=talalib" }).viPkgType
          == ViPkgType::kTalaLibrary);
}

TEST_CASE("values outside the documented choices are rejected by name")
{
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--emit=exe" }),
                   "invalid value 'exe' for --emit"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--standard=latest" }),
                   "--standard"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--warnings=high" }),
                   "--warnings"));
    CHECK(Mentions(
        Rejected({ "P.tala", "--entry=A.B", "--warnings-as-errors=yes" }),
        "--warnings-as-errors"));
    CHECK(Mentions(
        Rejected({ "P.tala", "--entry=A.B", "--codegen-backend=cranelift" }),
        "--codegen-backend"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--target=" }),
                   "--target"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--llvm-args=" }),
                   "--llvm-args"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--llvm-args=-a,,-b" }),
                   "--llvm-args"));
    // Spellings are case-sensitive, values included.
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--Emit=core" }),
                   "unknown option"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--emit=Core" }),
                   "--emit"));
    // The form the compiler had before is no longer an option.
    CHECK(Mentions(Rejected({ "build", "-File", "P.tala" }), "unknown option"));
}

TEST_CASE("shadow warnings are asked for by name, beside any level")
{
    // No level turns them on, the highest included.
    CHECK_FALSE(Ready({ "P.tala", "--entry=A.B", "--warnings=all" })
                    .compiler.shadowWarnings);

    const auto listed
        = Ready({ "P.tala", "--entry=A.B", "--warnings=all,shadow" });
    CHECK(listed.compiler.shadowWarnings);
    CHECK(listed.compiler.warningLevel == WarningLevel::kAll);

    const auto repeated = Ready(
        { "P.tala", "--entry=A.B", "--warnings=all", "--warnings=shadow" });
    CHECK(repeated.compiler == listed.compiler);
    const auto reversed = Ready(
        { "P.tala", "--entry=A.B", "--warnings=shadow", "--warnings=low" });
    CHECK(reversed.compiler.shadowWarnings);
    CHECK(reversed.compiler.warningLevel == WarningLevel::kLow);
    CHECK(Ready({ "P.tala", "--entry=A.B", "--warnings=shadow,low" }).compiler
          == reversed.compiler);

    // Alone, shadow keeps the default level.
    const auto alone = Ready({ "P.tala", "--entry=A.B", "--warnings=shadow" });
    CHECK(alone.compiler.shadowWarnings);
    CHECK(alone.compiler.warningLevel == WarningLevel::kMedium);

    CHECK(
        Mentions(Rejected({ "P.tala", "--entry=A.B", "--warnings=all,medium" }),
                 "second level, 'medium'"));
    CHECK(Mentions(
        Rejected(
            { "P.tala", "--entry=A.B", "--warnings=all", "--warnings=low" }),
        "second level, 'low'"));
    CHECK(Mentions(
        Rejected({ "P.tala", "--entry=A.B", "--warnings=shadow,shadow" }),
        "shadow twice"));
    CHECK(Mentions(Rejected({ "P.tala",
                              "--entry=A.B",
                              "--warnings=shadow",
                              "--warnings=all,shadow" }),
                   "shadow twice"));
    CHECK(Mentions(
        Rejected({ "P.tala", "--entry=A.B", "--warnings=none,shadow" }),
        "cannot be combined"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--warnings=all," }),
                   "invalid value ''"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--warnings=Shadow" }),
                   "invalid value 'Shadow'"));
}

TEST_CASE("an option may be written only once")
{
    CHECK(Mentions(
        Rejected({ "P.tala", "--entry=A.B", "--emit=core", "--emit=xpp" }),
        "--emit may be written only once"));
    // The two forms of one option are one option.
    CHECK(
        Mentions(Rejected({ "P.tala", "--entry=A.B", "-O2", "--opt-level=3" }),
                 "--opt-level may be written only once"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--entry=A.C" }),
                   "--entry may be written only once"));
}

TEST_CASE("an entry is a namespace-qualified class")
{
    CHECK(Ready({ "P.tala", "--entry=Company.Product.Program" }).entry
          == "Company.Product.Program");
    CHECK(Ready({ "P.tala", "--entry=_a._b" }).entry == "_a._b");
    for (const auto *entry : { "--entry=Program",
                               "--entry=",
                               "--entry=.Program",
                               "--entry=A.",
                               "--entry=A..B",
                               "--entry=A.1B",
                               "--entry=A.B-C",
                               "--entry=A B.C" })
    {
        INFO(entry);
        CHECK(Mentions(Rejected({ "P.tala", entry }), "--entry"));
    }
}

TEST_CASE("the entry belongs to an executable made from Tala sources")
{
    CHECK(Mentions(Rejected({ "P.tala" }), "--entry is required"));
    CHECK(
        Mentions(Rejected({ "P.tala", "--emit=core" }), "--entry is required"));
    CHECK(
        Mentions(Rejected({ "P.tala", "--entry=A.B", "--vipkg-type=talalib" }),
                 "--entry cannot be written"));
    CHECK(Mentions(
        Rejected({ "P.tala", "--entry=A.B", "--vipkg-type=staticlib" }),
        "--entry cannot be written"));
    CHECK(Mentions(Rejected({ "P.core", "--build=core", "--entry=A.B" }),
                   "already carries its entry"));
    CHECK_FALSE(Ready({ "P.core", "--build=core" }).entry.has_value());
    CHECK_FALSE(Ready({ "P.tala", "--vipkg-type=cdylib" }).entry.has_value());
}

TEST_CASE("a check of one source needs no entry")
{
    const auto check = Ready({ "P.tala", "--emit=metadata" });
    CHECK(check.output == BuildOutput::kMetadata);
    CHECK_FALSE(check.entry.has_value());
    CHECK(Ready({ "P.tala", "--emit=metadata", "--entry=A.B" }).entry
          == std::optional<std::string>("A.B"));
    // Several sources are one program, and a program is lowered from its
    // entry even when nothing is built.
    CHECK(Mentions(Rejected({ "P.tala", "Q.tala", "--emit=metadata" }),
                   "--entry is required to check several sources"));
    CHECK(Ready({ "P.tala", "Q.tala", "--emit=metadata", "--entry=A.B" })
              .inputs.size()
          == 2U);
    // An artifact still carries its own entry.
    CHECK(Mentions(
        Rejected(
            { "P.core", "--build=core", "--emit=metadata", "--entry=A.B" }),
        "already carries its entry"));
}

TEST_CASE("a header is written only for a C library")
{
    CHECK(Ready({ "P.tala", "--vipkg-type=staticlib", "--header" }).emitHeader);
    CHECK(Ready({ "P.tala", "--vipkg-type=cdylib", "--header" }).emitHeader);
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "--header" }),
                   "--header requires"));
    CHECK(Mentions(Rejected({ "P.tala", "--vipkg-type=talalib", "--header" }),
                   "--header requires"));
    CHECK(Mentions(Rejected({ "P.tala", "--header=true" }),
                   "does not take a value"));
}

TEST_CASE("inputs are every argument that is not an option, in order")
{
    const auto options = Ready({ "One.tala",
                                 "--entry=A.B",
                                 "Two.tala",
                                 "--emit=object",
                                 "Three.tala" });
    REQUIRE(options.inputs.size() == 3U);
    CHECK(options.inputs[0] == std::filesystem::path("One.tala"));
    CHECK(options.inputs[1] == std::filesystem::path("Two.tala"));
    CHECK(options.inputs[2] == std::filesystem::path("Three.tala"));

    CHECK(Mentions(Rejected({ "--entry=A.B" }), "an input file is required"));
    CHECK(Mentions(Rejected({}), "an input file is required"));
    CHECK(Mentions(Rejected({ "P.tala", "--entry=A.B", "" }), "input file"));
}

TEST_CASE("a double dash ends the options")
{
    const auto options
        = Ready({ "--entry=A.B", "--", "-Odd.tala", "--emit=core" });
    REQUIRE(options.inputs.size() == 2U);
    CHECK(options.inputs[0] == std::filesystem::path("-Odd.tala"));
    CHECK(options.inputs[1] == std::filesystem::path("--emit=core"));
    CHECK(options.output == BuildOutput::kExecutable);
    // A lone dash is a name, not an option.
    CHECK(Ready({ "-", "--entry=A.B" }).inputs.front()
          == std::filesystem::path("-"));
}

TEST_CASE("an input name that is not UTF-8 is refused before it is a path")
{
    // On Windows the conversion to a native path would throw, and the
    // compiler is built without exceptions.
    CHECK(Mentions(Rejected({ "\xff\xfe.tala", "--entry=A.B" }), "UTF-8"));
    CHECK(Mentions(Rejected({ "\xc3.tala", "--entry=A.B" }), "UTF-8"));
    CHECK(Mentions(Rejected({ "\xed\xa0\x80.tala", "--entry=A.B" }), "UTF-8"));
    CHECK(Ready({ "\xc3\xa7\xc4\x9f.tala", "--entry=A.B" }).inputs.size()
          == 1U);
}

TEST_CASE("a null in the argument vector is a failure, not a crash")
{
    std::string program = "talac";
    std::string input = "P.tala";
    std::vector<char *> arguments{ program.data(), nullptr, input.data() };
    const auto outcome = ParseCommandLine(3, arguments.data());
    CHECK(outcome.result == CliParseResult::kError);
    CHECK_FALSE(outcome.diagnostic.empty());
}

TEST_CASE("extensions follow the kind and the host")
{
    CHECK(std::string_view(OutputExtension(BuildOutput::kObject)) == ".o");
    CHECK(std::string_view(OutputExtension(BuildOutput::kCore)) == ".core");
    CHECK(std::string_view(OutputExtension(BuildOutput::kXpp)) == ".xpp");
    CHECK(std::string_view(OutputExtension(BuildOutput::kXmm)) == ".xmm");
    CHECK(std::string_view(OutputExtension(BuildOutput::kAssembly)) == ".asm");
    CHECK(std::string_view(OutputExtension(BuildOutput::kLlvmIr)) == ".ll");
    CHECK(std::string_view(OutputExtension(BuildOutput::kLlvmBitcode))
          == ".bc");
#if defined(_WIN32)
    CHECK(std::string_view(OutputExtension(BuildOutput::kExecutable))
          == ".exe");
#else
    CHECK(std::string_view(OutputExtension(BuildOutput::kExecutable)).empty());
#endif
    CHECK(std::string_view(OutputExtension(BuildOutput::kMetadata))
          == ".talameta");
    CHECK(InputExtension(BuildInput::kTala) == ".tala");
    CHECK(InputExtension(BuildInput::kObject) == ".o");
    CHECK(InputExtension(BuildInput::kCore) == ".core");
    CHECK(InputExtension(BuildInput::kXpp) == ".xpp");
    CHECK(InputExtension(BuildInput::kXmm) == ".xmm");
    CHECK(InputExtension(BuildInput::kLlvmIr) == ".ll");
    CHECK(InputExtension(BuildInput::kLlvmBitcode) == ".bc");
    CHECK(std::string_view(WarningLevelName(WarningLevel::kLow)) == "low");
}
