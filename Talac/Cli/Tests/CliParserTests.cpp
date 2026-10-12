// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <string>
#include <utility>
#include <vector>

#include "Talac/Cli/Arguments/Options.hpp"

namespace
{
    class ParsedInvocation final
    {
    public:
        ParsedInvocation(std::initializer_list<std::string> arguments)
            : storage_(arguments)
        {
            argv_.reserve(storage_.size());
            for (auto &argument : storage_)
                argv_.push_back(argument.data());
            outcome_ = ParseCommandLine(static_cast<int>(argv_.size()),
                                        argv_.data());
        }

        ParsedInvocation(const ParsedInvocation &) = delete;
        ParsedInvocation &
        operator=(const ParsedInvocation &) = delete;
        [[nodiscard]] CliParseResult
        Result() const noexcept
        {
            return outcome_.result;
        }

        [[nodiscard]] const CliOptions &
        Options() const noexcept
        {
            return outcome_.options;
        }

        [[nodiscard]] const std::string &
        Diagnostic() const noexcept
        {
            return outcome_.diagnostic;
        }

        [[nodiscard]] std::optional<CliCommand>
        HelpCommand() const noexcept
        {
            return outcome_.helpCommand;
        }

    private:
        std::vector<std::string> storage_;
        std::vector<char *> argv_;
        CliParseOutcome outcome_{};
    };
} // namespace

TEST_CASE("CLI defaults become typed compiler settings", "[cli][parser]")
{
    const ParsedInvocation parsed{ "talac", "check" };

    REQUIRE(parsed.Result() == CliParseResult::kReady);
    const auto &options = parsed.Options();
    REQUIRE(options.command == CliCommand::kCheck);
    REQUIRE_FALSE(options.filePath);
    REQUIRE(std::string(options.standard) == "latest");
    REQUIRE(options.compilerVersion == "latest");
    REQUIRE_FALSE(options.target);
    REQUIRE(options.input == BuildInput::kTala);
    REQUIRE(options.output == BuildOutput::kBinary);
    REQUIRE(options.compiler.warningLevel == WarningLevel::kMedium);
    REQUIRE_FALSE(options.compiler.warningsAsErrors);
    REQUIRE_FALSE(options.compiler.experimentalWarnings);
    REQUIRE_FALSE(options.compiler.shadowWarnings);
    REQUIRE(options.compiler.undefinedWarnings);
    REQUIRE(options.compiler.typeSafeFormat);
    REQUIRE(options.compiler.xppOptimizationPasses);
    REQUIRE(options.compiler.xmmOptimizationPasses);
    REQUIRE(options.compiler.llvmOptLevel == LlvmOptLevel::kO2);
    REQUIRE(options.compiler.llvmCompiler == LlvmCompiler::kAot);
    REQUIRE(options.compiler.llvmLto == LlvmLto::kNone);
    REQUIRE_FALSE(options.compilerVersionOverride);
    REQUIRE_FALSE(options.standardOverride);
    REQUIRE_FALSE(options.targetOverride);
}

TEST_CASE(
    "help and version are parser outcomes rather than parser side effects",
    "[cli][parser]")
{
    const ParsedInvocation globalHelp{ "talac", "-Help" };
    REQUIRE(globalHelp.Result() == CliParseResult::kHelp);
    REQUIRE_FALSE(globalHelp.Options().filePath);
    REQUIRE_FALSE(globalHelp.HelpCommand());

    const ParsedInvocation buildHelp{ "talac", "build", "-Help" };
    REQUIRE(buildHelp.Result() == CliParseResult::kHelp);
    REQUIRE(buildHelp.HelpCommand() == CliCommand::kBuild);

    const ParsedInvocation version{ "talac", "version" };
    REQUIRE(version.Result() == CliParseResult::kVersion);

    const ParsedInvocation legacyVersion{ "talac", "--version" };
    REQUIRE(legacyVersion.Result() == CliParseResult::kError);
    REQUIRE(legacyVersion.Diagnostic() == "unknown command '--version'");

    const ParsedInvocation versionHelp{ "talac", "version", "-Help" };
    REQUIRE(versionHelp.Result() == CliParseResult::kHelp);
    REQUIRE(versionHelp.HelpCommand() == CliCommand::kVersion);

    const ParsedInvocation legacyHelp{ "talac", "build", "--help" };
    REQUIRE(legacyHelp.Result() == CliParseResult::kError);
    REQUIRE(legacyHelp.Diagnostic() == "unknown option '--help'");
}

TEST_CASE(
    "interactive hands every child argument to tali without compiler parsing",
    "[cli][parser][interactive]")
{
    const ParsedInvocation repl{ "talac", "interactive" };
    REQUIRE(repl.Result() == CliParseResult::kReady);
    REQUIRE(repl.Options().command == CliCommand::kInteractive);
    REQUIRE(repl.Options().interactiveArguments.empty());

    const ParsedInvocation oneShot{ "talac", "interactive", "--eval", "5 + 5" };
    REQUIRE(oneShot.Result() == CliParseResult::kReady);
    REQUIRE(oneShot.Options().interactiveArguments
            == std::vector<std::string>{ "--eval", "5 + 5" });

    const ParsedInvocation help{ "talac", "interactive", "-Help" };
    REQUIRE(help.Result() == CliParseResult::kReady);
    REQUIRE(help.Options().interactiveArguments
            == std::vector<std::string>{ "-Help" });

    const ParsedInvocation optionLookingExpression{ "talac",
                                                    "interactive",
                                                    "--eval",
                                                    "-1 + 2" };
    REQUIRE(optionLookingExpression.Result() == CliParseResult::kReady);
    REQUIRE(optionLookingExpression.Options().interactiveArguments
            == std::vector<std::string>{ "--eval", "-1 + 2" });

    const ParsedInvocation extra{ "talac",
                                  "interactive",
                                  "--",
                                  "--eval",
                                  "5 + 5" };
    REQUIRE(extra.Result() == CliParseResult::kReady);
    REQUIRE(extra.Options().interactiveArguments
            == std::vector<std::string>{ "--", "--eval", "5 + 5" });
}

TEST_CASE("compiler arguments are converted to typed values", "[cli][parser]")
{
    const ParsedInvocation parsed{
        "talac",
        "build",
        "-File",
        "Program.tala",
        "-Standard",
        "26",
        "-Compiler-Version",
        "0.3.1",
        "-Target",
        "x86_64-pc-windows-msvc",
        "-Emit",
        "llvmbc",
        "-Build",
        "talac",
        "-Warnings",
        "all",
        "-Werror",
        "true",
        "-Wexperimental",
        "true",
        "-Wshadow",
        "true",
        "-Wundef",
        "false",
        "-Type-Safe-Format",
        "false",
        "-Backend",
        "llvm",
        "-Llvm-OptLevel",
        "g",
        "-Llvm-Compiler",
        "orc",
        "-Llvm-Lto",
        "thin",
        "-Xpp-Optimization-Passes",
        "false",
        "-Xmm-Optimization-Passes",
        "false",
    };

    REQUIRE(parsed.Result() == CliParseResult::kReady);
    const auto &options = parsed.Options();
    REQUIRE(options.command == CliCommand::kBuild);
    REQUIRE(options.filePath == std::filesystem::path("Program.tala"));
    REQUIRE(std::string(options.standard) == "26");
    REQUIRE(options.compilerVersion == "0.3.1");
    REQUIRE(options.target == "x86_64-pc-windows-msvc");
    REQUIRE(options.input == BuildInput::kTala);
    REQUIRE(options.output == BuildOutput::kLlvmBitcode);
    REQUIRE(options.compiler.warningLevel == WarningLevel::kAll);
    REQUIRE(options.compiler.warningsAsErrors);
    REQUIRE(options.compiler.experimentalWarnings);
    REQUIRE(options.compiler.shadowWarnings);
    REQUIRE_FALSE(options.compiler.undefinedWarnings);
    REQUIRE_FALSE(options.compiler.typeSafeFormat);
    REQUIRE_FALSE(options.compiler.xppOptimizationPasses);
    REQUIRE_FALSE(options.compiler.xmmOptimizationPasses);
    REQUIRE(options.compiler.llvmOptLevel == LlvmOptLevel::kOg);
    REQUIRE(options.compiler.llvmCompiler == LlvmCompiler::kOrc);
    REQUIRE(options.compiler.llvmLto == LlvmLto::kThin);
    REQUIRE(options.outputOverride);
    REQUIRE(options.compilerVersionOverride);
    REQUIRE(options.standardOverride);
    REQUIRE(options.targetOverride);
    REQUIRE(options.warningOverride);
    REQUIRE(options.werrorOverride);
    REQUIRE(options.llvmOptOverride);
}

TEST_CASE("double dash forwards exact program arguments only for run",
          "[cli][parser]")
{
    const ParsedInvocation run{
        "talac",
        "run",
        "-File",
        "Program.tala",
        "--",
        "--server-option",
        "value with spaces",
        "-1",
    };
    REQUIRE(run.Result() == CliParseResult::kReady);
    REQUIRE(run.Options().programArguments
            == std::vector<std::string>{ "--server-option",
                                         "value with spaces",
                                         "-1" });

    const ParsedInvocation emptyTail{ "talac", "run", "--" };
    REQUIRE(emptyTail.Result() == CliParseResult::kReady);
    REQUIRE(emptyTail.Options().programArguments.empty());

    const ParsedInvocation build{ "talac", "build", "--", "unexpected" };
    REQUIRE(build.Result() == CliParseResult::kError);
    REQUIRE(build.Diagnostic() == "-- is only valid for run program arguments");
}

TEST_CASE("command and option spellings are case-sensitive", "[cli][parser]")
{
    REQUIRE(ParsedInvocation{ "talac", "Build" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-warnings", "all" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Warnings", "ALL" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "--module", "Sources" }.Result()
            == CliParseResult::kError);
}

TEST_CASE("format and lint are project-wide tool commands",
          "[cli][parser][tools]")
{
    const ParsedInvocation format{ "talac", "format" };
    REQUIRE(format.Result() == CliParseResult::kReady);
    REQUIRE(format.Options().command == CliCommand::kFormat);
    REQUIRE_FALSE(format.Options().formatterDryRun);

    const ParsedInvocation dryRun{ "talac", "format", "-Dry-Run" };
    REQUIRE(dryRun.Result() == CliParseResult::kReady);
    REQUIRE(dryRun.Options().formatterDryRun);

    const ParsedInvocation inPlace{ "talac", "format", "-In-Place" };
    REQUIRE(inPlace.Result() == CliParseResult::kError);
    REQUIRE_FALSE(format.Options().filePath);

    const ParsedInvocation lint{ "talac", "lint" };
    REQUIRE(lint.Result() == CliParseResult::kReady);
    REQUIRE(lint.Options().command == CliCommand::kLint);
    REQUIRE_FALSE(lint.Options().filePath);

    REQUIRE(
        ParsedInvocation{ "talac", "format", "-File", "Program.tala" }.Result()
        == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "lint", "Program.tala" }.Result()
            == CliParseResult::kError);
}

TEST_CASE("schema enforces arity command scope and duplicate policy",
          "[cli][parser]")
{
    REQUIRE(ParsedInvocation{ "talac", "build", "-File" }.Result()
            == CliParseResult::kError);
    // A path that is not well-formed UTF-8 is a diagnostic. Converting it
    // to a native path would throw in a program built without exceptions.
    for (const char *malformed : { "Program\xff.tala",
                                   "\x80.tala",
                                   "Stray\xbf",
                                   "Truncated\xe2\x82",
                                   "Overlong\xc0\xaf.tala",
                                   "Overlong\xe0\x80\xaf.tala",
                                   "Surrogate\xed\xa0\x80.tala",
                                   "Beyond\xf4\x90\x80\x80.tala",
                                   "Beyond\xf5\x80\x80\x80.tala" })
    {
        const ParsedInvocation rejected{ "talac", "build", "-File", malformed };
        REQUIRE(rejected.Result() == CliParseResult::kError);
        REQUIRE_FALSE(rejected.Diagnostic().empty());
    }
    for (const char *wellFormed : { "Pro\xc3\xa7gram.tala",
                                    "\xe0\xa0\x80.tala",
                                    "\xed\x9f\xbf.tala",
                                    "\xf0\x90\x80\x80.tala",
                                    "\xf4\x8f\xbf\xbf.tala" })
        REQUIRE(
            ParsedInvocation{ "talac", "build", "-File", wellFormed }.Result()
            == CliParseResult::kReady);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Emit", "core" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac",
                              "check",
                              "-File",
                              "A.tala",
                              "-File",
                              "B.tala" }
                .Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "resolve", "-Warnings", "all" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "version", "extra" }.Result()
            == CliParseResult::kError);
}

TEST_CASE("every typed value domain rejects unknown values", "[cli][parser]")
{
    REQUIRE(ParsedInvocation{ "talac", "build", "-Emit", "hir" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Build", "source" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Standard", "23" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Werror", "yes" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Backend", "vpi" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Llvm-OptLevel", "0" }.Result()
            == CliParseResult::kError);
    REQUIRE(
        ParsedInvocation{ "talac", "check", "-Llvm-Compiler", "jit" }.Result()
        == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Llvm-Lto", "full" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Target", "windows" }.Result()
            == CliParseResult::kError);
    REQUIRE(
        ParsedInvocation{ "talac", "check", "-Target", "x86_64/windows/msvc" }
            .Result()
        == CliParseResult::kError);

    const ParsedInvocation warning{ "talac", "check", "-Warnings", "urgent" };
    REQUIRE(warning.Diagnostic()
            == "invalid value 'urgent' for -Warnings; expected "
               "all|medium|low|none");
}

TEST_CASE("explicit artifact input cannot silently become project mode",
          "[cli][parser]")
{
    REQUIRE(ParsedInvocation{ "talac", "check", "-Build", "core" }.Result()
            == CliParseResult::kError);

    const ParsedInvocation direct{ "talac", "check", "-Build",
                                   "core",  "-File", "Module.core" };
    REQUIRE(direct.Result() == CliParseResult::kReady);
    REQUIRE(direct.Options().input == BuildInput::kCore);
    REQUIRE(direct.Options().filePath == std::filesystem::path("Module.core"));
}

TEST_CASE("install and ViGet have distinct typed positional contracts",
          "[cli][parser]")
{
    const ParsedInvocation localInstall{ "talac", "install", "Publisher.Name" };
    REQUIRE(localInstall.Result() == CliParseResult::kReady);
    REQUIRE(localInstall.Options().command == CliCommand::kInstall);
    REQUIRE(localInstall.Options().packageCoordinate == "Publisher.Name");
    REQUIRE_FALSE(localInstall.Options().globalInstall);

    const ParsedInvocation globalInstall{ "talac",
                                          "install",
                                          "-Global",
                                          "Publisher.Name" };
    REQUIRE(globalInstall.Result() == CliParseResult::kReady);
    REQUIRE(globalInstall.Options().globalInstall);

    const ParsedInvocation push{ "talac", "viget", "push" };
    REQUIRE(push.Result() == CliParseResult::kReady);
    REQUIRE(push.Options().command == CliCommand::kViGet);
    REQUIRE(push.Options().vigetAction == ViGetAction::kPush);
    REQUIRE_FALSE(push.Options().packageCoordinate);

    const ParsedInvocation update{ "talac", "viget", "update" };
    REQUIRE(update.Result() == CliParseResult::kReady);
    REQUIRE(update.Options().vigetAction == ViGetAction::kUpdate);

    REQUIRE(ParsedInvocation{ "talac", "install" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "viget" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "viget", "publish" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "install", "Publisher" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "install", ".Name" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "install", "Publisher..Name" }.Result()
            == CliParseResult::kError);
    REQUIRE(
        ParsedInvocation{ "talac", "install", "Publisher.Name.More" }.Result()
        == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "install", "Publisher.Na/me" }.Result()
            == CliParseResult::kError);
    REQUIRE(
        ParsedInvocation{ "talac", "install", "Publisher.Name?version=latest" }
            .Result()
        == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "install", "Publisher.Na me" }.Result()
            == CliParseResult::kError);
    REQUIRE(
        ParsedInvocation{ "talac", "install", "Publisher.Nam\xC3\xA9" }.Result()
        == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "install", "Publisher.Name", "extra" }
                .Result()
            == CliParseResult::kError);
}

TEST_CASE("ViPkg creation and TCI build options are typed", "[cli][parser]")
{
    const ParsedInvocation create{ "talac", "vipkg", "create" };
    REQUIRE(create.Result() == CliParseResult::kReady);
    REQUIRE(create.Options().command == CliCommand::kViPkg);
    REQUIRE(create.Options().viPkgAction == ViPkgAction::kCreate);

    const ParsedInvocation library{ "talac",     "build",   "-File",
                                    "Math.tala", "-Header", "-ViPkgType",
                                    "staticlib" };
    REQUIRE(library.Result() == CliParseResult::kReady);
    REQUIRE(library.Options().emitHeader);
    REQUIRE(library.Options().viPkgType == ViPkgType::kStaticLibrary);

    REQUIRE(ParsedInvocation{ "talac", "vipkg" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "vipkg", "push" }.Result()
            == CliParseResult::kError);
    REQUIRE(ParsedInvocation{ "talac", "check", "-Header" }.Result()
            == CliParseResult::kError);
    REQUIRE(
        ParsedInvocation{ "talac", "build", "-ViPkgType", "shared" }.Result()
        == CliParseResult::kError);
}

TEST_CASE("build and run select multiple named project targets",
          "[cli][parser]")
{
    const ParsedInvocation selected{
        "talac",       "build",  "-ViPkg", "PackageOne", "PackageTwo",
        "-Executable", "Server", "Client", "-Library",   "Shared",
    };
    REQUIRE(selected.Result() == CliParseResult::kReady);
    REQUIRE(selected.Options().selectedViPkgs
            == std::vector<std::string>{ "PackageOne", "PackageTwo" });
    REQUIRE(selected.Options().selectedExecutables
            == std::vector<std::string>{ "Server", "Client" });
    REQUIRE(selected.Options().selectedLibraries
            == std::vector<std::string>{ "Shared" });

    const ParsedInvocation run{ "talac",  "run", "-Executable",
                                "Server", "--",  "-user-option" };
    REQUIRE(run.Result() == CliParseResult::kReady);
    REQUIRE(run.Options().selectedExecutables
            == std::vector<std::string>{ "Server" });
    REQUIRE(run.Options().programArguments
            == std::vector<std::string>{ "-user-option" });

    REQUIRE(ParsedInvocation{ "talac", "build", "-Executable" }.Result()
            == CliParseResult::kError);
    REQUIRE(
        ParsedInvocation{ "talac", "build", "-Library", "bad/name" }.Result()
        == CliParseResult::kError);
    REQUIRE(
        ParsedInvocation{ "talac", "build", "-ViPkg", "Same", "Same" }.Result()
        == CliParseResult::kError);
    REQUIRE(
        ParsedInvocation{ "talac", "check", "-Executable", "Program" }.Result()
        == CliParseResult::kError);
}

TEST_CASE(
    "project settings are overridden only by explicitly present CLI values",
    "[cli][parser]")
{
    const ParsedInvocation parsed{ "talac", "check",          "-Wundef",
                                   "false", "-Llvm-Compiler", "orc" };
    REQUIRE(parsed.Result() == CliParseResult::kReady);

    CompilerSettings project{
        .warningLevel = WarningLevel::kLow,
        .warningsAsErrors = true,
        .experimentalWarnings = true,
        .shadowWarnings = true,
        .undefinedWarnings = true,
        .typeSafeFormat = false,
        .xppOptimizationPasses = false,
        .xmmOptimizationPasses = false,
        .llvmOptLevel = LlvmOptLevel::kO3,
        .llvmCompiler = LlvmCompiler::kAot,
        .llvmLto = LlvmLto::kFat,
    };
    ApplyCompilerOverrides(parsed.Options(), project);

    REQUIRE(project.warningLevel == WarningLevel::kLow);
    REQUIRE(project.warningsAsErrors);
    REQUIRE(project.experimentalWarnings);
    REQUIRE(project.shadowWarnings);
    REQUIRE_FALSE(project.undefinedWarnings);
    REQUIRE_FALSE(project.typeSafeFormat);
    REQUIRE_FALSE(project.xppOptimizationPasses);
    REQUIRE_FALSE(project.xmmOptimizationPasses);
    REQUIRE(project.llvmOptLevel == LlvmOptLevel::kO3);
    REQUIRE(project.llvmCompiler == LlvmCompiler::kOrc);
    REQUIRE(project.llvmLto == LlvmLto::kFat);
}

TEST_CASE(
    "effective compiler options follow CLI project and fallback precedence",
    "[cli][parser]")
{
    const ParsedInvocation fallbackInvocation{ "talac", "build" };
    REQUIRE(fallbackInvocation.Result() == CliParseResult::kReady);
    const auto fallback = ResolveCompilerOptions(fallbackInvocation.Options());
    REQUIRE(fallback.compilerVersion == "latest");
    REQUIRE(fallback.standard == "latest");
    REQUIRE_FALSE(fallback.target);
    REQUIRE(fallback.output == BuildOutput::kBinary);
    REQUIRE(fallback.compiler.llvmOptLevel == LlvmOptLevel::kO2);

    EffectiveCompilerOptions project{
        .compilerVersion = "0.3.1",
        .standard = "26",
        .target = std::nullopt,
        .output = BuildOutput::kObject,
        .compiler = DefaultCompilerSettings(),
    };
    // Kotlin materializes explicit project settings and DSL defaults alike.
    // Both outrank CLI fallbacks; only argv presence bits can replace this
    // layer.
    project.compiler.llvmOptLevel = LlvmOptLevel::kO0;
    const auto fromProject
        = ResolveCompilerOptions(fallbackInvocation.Options(), &project);
    REQUIRE(fromProject.compilerVersion == "0.3.1");
    REQUIRE(fromProject.standard == "26");
    REQUIRE(fromProject.output == BuildOutput::kObject);
    REQUIRE(fromProject.compiler.llvmOptLevel == LlvmOptLevel::kO0);

    const ParsedInvocation explicitInvocation{
        "talac",     "build",  "-Compiler-Version", "latest",
        "-Standard", "latest", "-Target",           "aarch64-unknown-linux-gnu",
        "-Emit",     "llvmll", "-Llvm-OptLevel",    "3",
    };
    REQUIRE(explicitInvocation.Result() == CliParseResult::kReady);
    const auto explicitResult
        = ResolveCompilerOptions(explicitInvocation.Options(), &project);
    REQUIRE(explicitResult.compilerVersion == "latest");
    REQUIRE(explicitResult.standard == "latest");
    REQUIRE(explicitResult.target == "aarch64-unknown-linux-gnu");
    REQUIRE(explicitResult.output == BuildOutput::kLlvmIr);
    REQUIRE(explicitResult.compiler.llvmOptLevel == LlvmOptLevel::kO3);
}

TEST_CASE("parser rejects malformed process argument vectors safely",
          "[cli][parser]")
{
    REQUIRE(ParseCommandLine(-1, nullptr).result == CliParseResult::kError);
    REQUIRE(ParseCommandLine(1, nullptr).result == CliParseResult::kError);

    char program[] = "talac";
    char *arguments[]{ program, nullptr };
    REQUIRE(ParseCommandLine(2, arguments).result == CliParseResult::kError);
}
