// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstdio>
#include <filesystem>
#include <fmt/format.h>
#include <fstream>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "Talac/Cli/Arguments/Options.hpp"
#include "Talac/Cli/Commands/Commands.hpp"
#include "Talac/Cli/Commands/Frontend.hpp"
#include "Talac/Cli/Presentation/Activity.hpp"
#include "Talac/Driver/CorePipeline.hpp"
#include "Talac/Linker/NativeLinker.hpp"

namespace
{
    using Progmasoft::Tala::Cli::Activity;
    namespace Frontend = Progmasoft::Tala::Cli::Frontend;

    /// Exit status of a command line that asks for what talac cannot do.
    constexpr int kUsageError = 2;

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

    /// Compile the Tala sources of one invocation to verified Core. Several
    /// sources are one program: they are resolved together and the entry
    /// selects the namespace that is lowered.
    [[nodiscard]] auto
    RunFrontend(std::span<const std::filesystem::path> sources,
                const std::optional<std::string> &entry) -> Frontend::Result
    {
        std::vector<std::string> arguments;
        arguments.reserve(sources.size() * 2U + 2U);
        for (const auto &source : sources)
        {
            arguments.emplace_back("--source-file");
            arguments.push_back(PathText(source));
        }
        if (entry)
        {
            arguments.emplace_back("--entry");
            arguments.push_back(*entry);
        }
        return Frontend::Execute(arguments);
    }

    [[nodiscard]] auto
    FrontendSucceeded(const Frontend::Result &result) -> bool
    {
        if (result.succeeded())
            return result.kind != Frontend::OutputKind::ErrorText;
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
    /// policy. `--warnings=none` hides them; `--warnings-as-errors=true`
    /// fails the compilation after printing them, without changing what they
    /// say.
    [[nodiscard]] auto
    FrontendWarningsAllowed(const Frontend::Result &result,
                            const CompilerSettings &settings) -> bool
    {
        if (result.warnings.empty()
            || settings.warningLevel == WarningLevel::kNone)
            return true;
        fmt::print(stderr, "{}", result.warnings);
        if (!settings.warningsAsErrors)
            return true;
        fmt::print(stderr,
                   "talac: warnings are treated as errors "
                   "(--warnings-as-errors=true)\n");
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

    /// The output stands beside the first input and takes its name.
    [[nodiscard]] std::filesystem::path
    OutputPath(const std::filesystem::path &input, std::string_view extension)
    {
        auto output = input;
        output.replace_extension(extension);
        return output;
    }

    [[nodiscard]] std::string_view
    BuildName(BuildInput input)
    {
        constexpr std::string_view names[]
            = { "tala", "object",  "core",        "xpp",
                "xmm",  "llvm-ir", "llvm-bitcode" };
        const auto index = static_cast<unsigned>(input);
        return index < 7U ? names[index] : std::string_view{};
    }

    /// Position of a kind in the pipeline. An output cannot stand earlier in
    /// the pipeline than the input it is made from.
    [[nodiscard]] int
    Stage(BuildInput input)
    {
        switch (input)
        {
            case BuildInput::kTala:
                return 0;
            case BuildInput::kCore:
                return 1;
            case BuildInput::kXpp:
                return 2;
            case BuildInput::kXmm:
                return 3;
            case BuildInput::kLlvmIr:
            case BuildInput::kLlvmBitcode:
                return 4;
            case BuildInput::kObject:
                return 5;
        }
        return 0;
    }

    [[nodiscard]] int
    Stage(BuildOutput output)
    {
        switch (output)
        {
            case BuildOutput::kCore:
                return 1;
            case BuildOutput::kXpp:
                return 2;
            case BuildOutput::kXmm:
                return 3;
            case BuildOutput::kLlvmIr:
            case BuildOutput::kLlvmBitcode:
                return 4;
            case BuildOutput::kAssembly:
            case BuildOutput::kObject:
                return 5;
            case BuildOutput::kExecutable:
                return 6;
        }
        return 6;
    }

    /// What the command line asks for that this compiler does not do yet.
    /// Saying so is better than accepting the option and ignoring it.
    [[nodiscard]] std::optional<std::string_view>
    Unimplemented(const CliOptions &options)
    {
        if (options.viPkgType != ViPkgType::kExecutable)
            return "--vipkg-type other than executable";
        if (options.emitHeader)
            return "--header";
        if (options.compiler.llvmCompiler != LlvmCompiler::kAot)
            return "--llvm-compiler=orc";
        if (options.compiler.llvmLto != LlvmLto::kNone)
            return "--llvm-lto other than none";
        if (!options.llvmArguments.empty())
            return "--llvm-args";
        if (options.input == BuildInput::kLlvmIr
            || options.input == BuildInput::kLlvmBitcode)
            return "--build=llvm-ir and --build=llvm-bitcode";
        return std::nullopt;
    }

    [[nodiscard]] int
    LinkObjects(const CliOptions &options)
    {
        if (options.output != BuildOutput::kExecutable)
        {
            fmt::print(stderr,
                       "talac: --build=object can only be linked into an "
                       "executable\n");
            return kUsageError;
        }
        const auto executable
            = OutputPath(options.inputs.front(),
                         OutputExtension(BuildOutput::kExecutable));
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
        const Progmasoft::Tala::Driver::NativeLinkRequest request{
            executable,
            options.inputs,
            hostFormat
        };
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
        return 0;
    }

    [[nodiscard]] int
    CompileSources(const CliOptions &options)
    {
        const auto core = RunFrontend(options.inputs, options.entry);
        if (!FrontendSucceeded(core)
            || core.kind != Frontend::OutputKind::CoreWire
            || !FrontendWarningsAllowed(core, options.compiler))
            return 1;
        const auto &first = options.inputs.front();
        if (options.output == BuildOutput::kCore)
            return WriteCore(OutputPath(first, ".core"), core.bytes) ? 0 : 1;
        const auto sourceText = PathText(first);
        // Every source crosses the same verified Core consumer as a `.core`
        // input does, so the two cannot drift into separate validation paths.
        return ProcessCoreBytesAs(core.bytes,
                                  sourceText.c_str(),
                                  sourceText.c_str(),
                                  PipelineAction::kBuild,
                                  options.output,
                                  &options.compiler,
                                  options.target ? options.target->c_str()
                                                 : nullptr)
                   ? 0
                   : 1;
    }

    [[nodiscard]] int
    CompileArtifact(const CliOptions &options)
    {
        if (options.inputs.size() != 1U)
        {
            fmt::print(stderr,
                       "talac: --build={} takes exactly one input\n",
                       BuildName(options.input));
            return kUsageError;
        }
        const auto fileText = PathText(options.inputs.front());
        const char *target = options.target ? options.target->c_str() : nullptr;
        bool built{};
        if (options.input == BuildInput::kCore)
            built = ProcessCoreArtifact(fileText.c_str(),
                                        PipelineAction::kBuild,
                                        options.output,
                                        &options.compiler,
                                        target);
        else if (options.input == BuildInput::kXpp)
            built = ProcessXppArtifactAs(fileText.c_str(),
                                         fileText.c_str(),
                                         PipelineAction::kBuild,
                                         options.output,
                                         &options.compiler,
                                         target);
        else
            built = ProcessXmmArtifactAs(fileText.c_str(),
                                         fileText.c_str(),
                                         PipelineAction::kBuild,
                                         options.output,
                                         &options.compiler,
                                         target);
        return built ? 0 : 1;
    }

    [[nodiscard]] int
    Compile(const CliOptions &options)
    {
        if (const auto missing = Unimplemented(options))
        {
            fmt::print(stderr, "talac: {} is not implemented yet\n", *missing);
            return kUsageError;
        }
        const auto extension = InputExtension(options.input);
        for (const auto &input : options.inputs)
        {
            if (PathText(input.extension()) != extension)
            {
                fmt::print(stderr,
                           "talac: --build={} takes {} inputs, and '{}' is "
                           "not one\n",
                           BuildName(options.input),
                           extension,
                           PathText(input));
                return kUsageError;
            }
        }
        if (Stage(options.output) < Stage(options.input)
            || (Stage(options.output) == Stage(options.input)
                && options.input != BuildInput::kTala))
        {
            fmt::print(stderr,
                       "talac: a {} input cannot be turned into the requested "
                       "output; --emit names an earlier stage of the "
                       "pipeline or the stage of the input itself\n",
                       BuildName(options.input));
            return kUsageError;
        }
        if (options.input == BuildInput::kObject)
            return LinkObjects(options);
        if (options.input == BuildInput::kTala)
            return CompileSources(options);
        return CompileArtifact(options);
    }
} // namespace

auto
Progmasoft::Tala::Cli::Run(int argc, char **argv) -> int
{
    const auto parsed = ParseCommandLine(argc, argv);
    if (parsed.result == CliParseResult::kHelp)
    {
        PrintCliHelp();
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
        return kUsageError;
    }
    Activity activity("compiling");
    const int result = Compile(parsed.options);
    if (result == 0)
        activity.Complete("compiled");
    else
        activity.Fail("compilation failed");
    return result;
}
