// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <ranges>
#include <sstream>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"
#include "Talac/Driver/CorePipeline.hpp"

#ifdef _WIN32
#    include <process.h>
#endif

namespace
{
    namespace Core = Progmasoft::Tala::Core;

    class TemporaryDirectory final
    {
    public:
        TemporaryDirectory()
        {
            static std::atomic_uint64_t sequence{};
            const auto clock
                = std::chrono::steady_clock::now().time_since_epoch().count();
            const auto serial
                = sequence.fetch_add(1U, std::memory_order_relaxed);
            path_ = std::filesystem::temp_directory_path()
                    / ("tala-project-pipeline-" + std::to_string(clock) + "-"
                       + std::to_string(serial));
            created_ = std::filesystem::create_directory(path_);
        }

        TemporaryDirectory(const TemporaryDirectory &) = delete;
        auto
        operator=(const TemporaryDirectory &) -> TemporaryDirectory & = delete;

        ~TemporaryDirectory()
        {
            if (created_)
            {
                std::error_code ignored;
                std::filesystem::remove_all(path_, ignored);
            }
        }

        [[nodiscard]] auto
        Path() const -> const std::filesystem::path &
        {
            return path_;
        }

        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return created_;
        }

    private:
        std::filesystem::path path_;
        bool created_{};
    };

    [[nodiscard]] auto
    GoldenModule() -> Core::Module
    {
        return { { U"Demo" },
                 { { { 1U, U"Main" },
                     {},
                     Core::Type::unit(),
                     { Core::Statement::Return(Core::Expression::Constant(
                         std::monostate{},
                         Core::Type::unit())) } } } };
    }

    [[nodiscard]] auto
    PipelineModule() -> Core::Module
    {
        const auto integer = [](std::int64_t value) {
            return Core::Expression::Constant(value, Core::Type::int64());
        };
        const auto variable
            = [](std::uint64_t id, std::u32string spelling, Core::Type type) {
                  return Core::Expression::Variable({ id, std::move(spelling) },
                                                    std::move(type));
              };
        const auto sumType
            = Core::Type::function({ Core::Type::int64(), Core::Type::int64() },
                                   Core::Type::int64());
        Core::Function sum{
            { 10U, U"Sum" },
            { { { 11U, U"left" }, Core::Type::int64() },
              { { 12U, U"right" }, Core::Type::int64() } },
            Core::Type::int64(),
            { Core::Statement::Return(Core::Expression::InvokePrimitive(
                Core::Primitive::Add,
                { variable(11U, U"left", Core::Type::int64()),
                  variable(12U, U"right", Core::Type::int64()) },
                Core::Type::int64())) }
        };

        auto call = Core::Expression::Apply(variable(10U, U"Sum", sumType),
                                            { integer(20), integer(22) },
                                            Core::Type::int64());
        auto condition = Core::Expression::InvokePrimitive(
            Core::Primitive::GreaterEqual,
            { variable(21U, U"value", Core::Type::int64()), integer(40) },
            Core::Type::boolean());
        Core::Function main{
            { 20U, U"Main" },
            {},
            Core::Type::unit(),
            { Core::Statement::Bind({ { 21U, U"value" },
                                      Core::Type::int64(),
                                      true,
                                      std::move(call) }),
              Core::Statement::If(
                  std::move(condition),
                  { Core::Statement::Assign(
                      { 21U, U"value" },
                      Core::Expression::InvokePrimitive(
                          Core::Primitive::Add,
                          { variable(21U, U"value", Core::Type::int64()),
                            integer(1) },
                          Core::Type::int64())) },
                  { Core::Statement::Assign({ 21U, U"value" }, integer(0)) }),
              Core::Statement::Return(
                  Core::Expression::Constant(std::monostate{},
                                             Core::Type::unit())) }
        };
        return { { U"Name" }, { std::move(sum), std::move(main) } };
    }

    [[nodiscard]] auto
    ProjectPartitionModule() -> Core::Module
    {
        auto module = PipelineModule();
        module.sourceFiles = { U"Sources/Main.tala",
                               U"Sources/Math.tala",
                               U"Sources/Empty.tala" };
        module.functions[0].sourceFile = U"Sources/Math.tala";
        module.functions[1].sourceFile = U"Sources/Main.tala";
        return module;
    }

    [[nodiscard]] auto
    ClosureModule() -> Core::Module
    {
        const auto integer = [](std::int64_t value) {
            return Core::Expression::Constant(value, Core::Type::int64());
        };
        const auto variable
            = [](std::uint64_t id, std::u32string spelling, Core::Type type) {
                  return Core::Expression::Variable({ id, std::move(spelling) },
                                                    std::move(type));
              };
        const auto callableType = Core::Type::function({}, Core::Type::int64());
        Core::Capture capture{
            Core::CaptureMode::Strong,
            { 4U, U"captured" },
            Core::Type::int64(),
            std::make_shared<Core::Expression>(
                variable(2U, U"seed", Core::Type::int64())),
        };
        auto closure = Core::Expression::Closure(
            { std::move(capture) },
            {},
            Core::Type::int64(),
            { Core::Statement::Return(
                variable(4U, U"captured", Core::Type::int64())) },
            callableType);
        Core::Function main{
            { 1U, U"Main" },
            {},
            Core::Type::unit(),
            {
                Core::Statement::Bind({ { 2U, U"seed" },
                                        Core::Type::int64(),
                                        false,
                                        integer(42) }),
                Core::Statement::Bind({ { 3U, U"answer" },
                                        callableType,
                                        false,
                                        std::move(closure) }),
                Core::Statement::Return(
                    Core::Expression::Constant(std::monostate{},
                                               Core::Type::unit())),
            },
        };
        return { { U"ClosureBoundary" }, { std::move(main) } };
    }

    [[nodiscard]] auto
    ReadGoldenHex(std::string_view filename = "wire-v10.hex")
        -> std::vector<std::uint8_t>
    {
        const auto path = std::filesystem::path(__FILE__).parent_path()
                          / "Fixtures" / "Core"
                          / std::filesystem::path(filename);
        std::ifstream stream(path);
        REQUIRE(stream);
        std::vector<std::uint8_t> bytes;
        std::string line;
        while (std::getline(stream, line))
        {
            if (const auto comment = line.find('#');
                comment != std::string::npos)
                line.erase(comment);
            std::istringstream tokens(line);
            std::string token;
            while (tokens >> token)
                bytes.push_back(
                    static_cast<std::uint8_t>(std::stoul(token, nullptr, 16)));
        }
        return bytes;
    }

    [[nodiscard]] auto
    HasIssue(const std::vector<Core::VerificationIssue> &issues,
             std::string_view code) -> bool
    {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    }
} // namespace

TEST_CASE("native TACR v10 codec matches the Haskell golden contract")
{
    const auto expected = ReadGoldenHex();
    const auto encoded = Core::Wire::Encode(GoldenModule());
    REQUIRE(encoded);
    REQUIRE(encoded.bytes == expected);
    const auto decoded = Core::Wire::Decode(expected);
    REQUIRE(decoded);
    REQUIRE(decoded.module == GoldenModule());
}

TEST_CASE("TACR reader rejects malformed boundaries and configured limits")
{
    const auto encoded = Core::Wire::Encode(PipelineModule());
    REQUIRE(encoded);

    SECTION("wrong transport")
    {
        auto bytes = encoded.bytes;
        bytes[3] = 'P';
        const auto decoded = Core::Wire::Decode(bytes);
        REQUIRE_FALSE(decoded);
        REQUIRE(decoded.error->kind == Core::Wire::ErrorKind::InvalidMagic);
    }
    SECTION("truncation")
    {
        auto bytes = encoded.bytes;
        bytes.pop_back();
        const auto decoded = Core::Wire::Decode(bytes);
        REQUIRE_FALSE(decoded);
        REQUIRE(decoded.error->kind == Core::Wire::ErrorKind::TruncatedInput);
    }
    SECTION("trailing input")
    {
        auto bytes = encoded.bytes;
        bytes.push_back(0U);
        const auto decoded = Core::Wire::Decode(bytes);
        REQUIRE_FALSE(decoded);
        REQUIRE(decoded.error->kind == Core::Wire::ErrorKind::TrailingInput);
    }
    SECTION("byte limit")
    {
        Core::Wire::Limits limits;
        limits.maximumWireBytes = encoded.bytes.size() - 1U;
        const auto decoded = Core::Wire::Decode(encoded.bytes, limits);
        REQUIRE_FALSE(decoded);
        REQUIRE(decoded.error->kind == Core::Wire::ErrorKind::LimitExceeded);
    }
}

TEST_CASE("TACR v10 carries Haskell Core closure and source-owner fields")
{
    const auto source = ClosureModule();
    REQUIRE(Core::Verify(source).empty());
    const auto encoded = Core::Wire::Encode(source);
    REQUIRE(encoded);

    const auto decoded = Core::Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    CHECK(decoded.module == source);
    const auto &closure
        = decoded.module->functions.front().body.at(1).binding.value;
    REQUIRE(closure.kind == Core::Expression::Kind::Closure);
    REQUIRE(closure.captures.size() == 1U);
    CHECK(closure.captures.front().mode == Core::CaptureMode::Strong);
    CHECK(closure.captures.front().symbol.id == 4U);
    REQUIRE(closure.closureBody);
    CHECK(closure.closureBody->size() == 1U);
}

TEST_CASE("native pipeline consumes a closure artifact emitted by Haskell")
{
    // This golden file is emitted from closure-boundary.tala by tala-frontend,
    // rather than re-encoded by the C++ model. It therefore locks the actual
    // cross-language expression tag and field order that production uses.
    const auto bytes = ReadGoldenHex("wire-v10-closure.hex");
    const auto decoded = Core::Wire::Decode(bytes);
    REQUIRE(decoded);
    REQUIRE(Core::Verify(*decoded.module).empty());
    const auto &body = decoded.module->functions.front().body;
    REQUIRE(body.size() == 3U);
    REQUIRE(body.at(1).kind == Core::Statement::Kind::Evaluate);
    CHECK(body.at(1).expression.kind == Core::Expression::Kind::Closure);
    CHECK(body.at(1).expression.type.kind == Core::Type::Kind::Function);
    INFO("closure type kind="
         << static_cast<int>(body.at(1).expression.type.kind)
         << " components=" << body.at(1).expression.type.components.size());

    const auto result = Progmasoft::Tala::Pipeline::ConsumeCore(bytes);
    INFO("core verification issues=" << result.coreVerificationIssues.size());
    INFO("CorePrep verification issues=" << result.verification_issues.size());
    INFO("Xpp verification issues=" << result.xppVerificationIssues.size());
    INFO("Xmm verification issues=" << result.xmmVerificationIssues.size());
    std::string corePrepDiagnostics;
    for (const auto &issue : result.verification_issues)
        corePrepDiagnostics += issue.code + ": " + issue.message + "\n";
    INFO(corePrepDiagnostics);
    std::string xmmDiagnostics;
    for (const auto &issue : result.xmmVerificationIssues)
        xmmDiagnostics += issue.code + ": " + issue.message + "\n";
    INFO(xmmDiagnostics);
    for (const auto &issue : result.coreVerificationIssues)
        INFO(issue.code << ": " << issue.message);
    for (const auto &issue : result.verification_issues)
        INFO(issue.code << ": " << issue.message);
    for (const auto &issue : result.xppVerificationIssues)
        INFO(issue.code << ": " << issue.message);
    for (const auto &issue : result.xmmVerificationIssues)
        INFO(issue.code << ": " << issue.message);
    if (result.llvm_error)
        INFO(result.llvm_error->code << ": " << result.llvm_error->message);
    INFO("core=" << result.core.has_value()
                 << " coreprep=" << result.core_prep.has_value() << " xpp="
                 << result.xpp.has_value() << " xmm=" << result.xmm.has_value()
                 << " llvm=" << result.llvm.has_value());
    REQUIRE(result);
    REQUIRE(result.core_prep);
    CHECK(result.core_prep->functions.size() == 2U);
    CHECK(result.xmmVerificationIssues.empty());
}

TEST_CASE("native pipeline preserves non-empty Haskell source ownership bytes")
{
    // Both owner fields are non-empty in this golden so field order cannot be
    // accidentally hidden by interchangeable zero-length encodings.
    const auto bytes = ReadGoldenHex("wire-v10-project-source.hex");
    const auto decoded = Core::Wire::Decode(bytes);
    REQUIRE(decoded);
    REQUIRE(Core::Verify(*decoded.module).empty());
    REQUIRE(decoded.module->sourceFiles
            == std::vector<std::u32string>{ U"Sources/Main.tala" });
    REQUIRE(decoded.module->functions.size() == 1U);
    CHECK(decoded.module->functions.front().sourceFile == U"Sources/Main.tala");

    const auto reencoded = Core::Wire::Encode(*decoded.module);
    REQUIRE(reencoded);
    CHECK(reencoded.bytes == bytes);

    Progmasoft::Tala::Pipeline::Options options;
    options.stop_after = Progmasoft::Tala::Pipeline::Stop::Xmm;
    const auto pipeline
        = Progmasoft::Tala::Pipeline::ConsumeCore(bytes, options);
    REQUIRE(pipeline);
    REQUIRE(pipeline.xpp);
    REQUIRE(pipeline.xmm);
    CHECK(pipeline.xpp->source_files == decoded.module->sourceFiles);
    CHECK(pipeline.xmm->source_files == decoded.module->sourceFiles);
    CHECK(pipeline.xpp->functions.front().source_file
          == decoded.module->functions.front().sourceFile);
    CHECK(pipeline.xmm->functions.front().source_file
          == decoded.module->functions.front().sourceFile);
}

TEST_CASE(
    "Core closure conversion lifts a target and preserves capture metadata")
{
    const auto prepared = Core::CorePrep::Prepare(ClosureModule());
    REQUIRE(prepared.functions.size() == 2U);
    const auto &main = prepared.functions.front();
    const auto &lifted = prepared.functions.back();
    REQUIRE(main.blocks.size() == 1U);
    const auto closure = std::ranges::find_if(
        main.blocks.front().instructions,
        [](const auto &instruction) {
            return instruction.operation == tala::core::Operation::MakeClosure;
        });
    REQUIRE(closure != main.blocks.front().instructions.end());
    CHECK(closure->closure_function.id == lifted.symbol.id);
    REQUIRE(closure->captures.size() == 1U);
    CHECK(closure->captures.front().symbol.id
          == lifted.parameters.front().symbol.id);
    CHECK(closure->captures.front().value.symbol.id == 2U);
    CHECK(tala::core::verify(prepared).empty());
}

TEST_CASE("TACR closure survives the complete RAM compiler pipeline")
{
    const auto encoded = Core::Wire::Encode(ClosureModule());
    REQUIRE(encoded);
    const auto result = Progmasoft::Tala::Pipeline::ConsumeCore(encoded.bytes);
    REQUIRE(result);
    REQUIRE(result.core_prep);
    REQUIRE(result.xpp);
    REQUIRE(result.xmm);
    REQUIRE(result.llvm);
    CHECK(result.core_prep->functions.size() == 2U);
    CHECK(result.verification_issues.empty());
    CHECK(result.xppVerificationIssues.empty());
    CHECK(result.xmmVerificationIssues.empty());
}

TEST_CASE(
    "Core verifier rejects incomplete closure payloads before wire lowering")
{
    SECTION("missing capture initializer")
    {
        auto module = ClosureModule();
        module.functions.front()
            .body.at(1)
            .binding.value.captures.front()
            .value.reset();
        CHECK(HasIssue(Core::Verify(module), "TAC1035"));
    }
    SECTION("callable arity mismatch")
    {
        auto module = ClosureModule();
        auto &closure = module.functions.front().body.at(1).binding.value;
        closure.type = Core::Type::function({ Core::Type::int64() },
                                            Core::Type::int64());
        CHECK(HasIssue(Core::Verify(module), "TAC1041"));
    }
    SECTION("closure result mismatch")
    {
        auto module = ClosureModule();
        auto &closure = module.functions.front().body.at(1).binding.value;
        closure.closureReturnType = Core::Type::boolean();
        CHECK(HasIssue(Core::Verify(module), "TAC1041"));
    }
    SECTION("invalid capture ownership mode")
    {
        auto module = ClosureModule();
        // The out-of-catalog value is the input under test.
        module.functions.front().body.at(1).binding.value.captures.front().mode
            // NOLINTNEXTLINE(clang-analyzer-optin.core.EnumCastOutOfRange)
            = static_cast<Core::CaptureMode>(255U);
        CHECK(HasIssue(Core::Verify(module), "TAC1043"));
        CHECK_FALSE(Core::Wire::Encode(module));
    }
    SECTION("non-owning scalar capture")
    {
        auto module = ClosureModule();
        module.functions.front().body.at(1).binding.value.captures.front().mode
            = Core::CaptureMode::Weak;
        CHECK(HasIssue(Core::Verify(module), "TAC1044"));
    }
}

TEST_CASE("native Core accepts mutation of captured closure storage")
{
    auto module = ClosureModule();
    auto &closure = module.functions.front().body.at(1).binding.value;
    closure.closureBody = std::make_shared<std::vector<Core::Statement>>(
        std::vector<Core::Statement>{
            Core::Statement::Assign(
                { 4U, U"captured" },
                Core::Expression::Constant(std::int64_t{ 43 },
                                           Core::Type::int64())),
            Core::Statement::Return(
                Core::Expression::Variable({ 4U, U"captured" },
                                           Core::Type::int64())),
        });
    CHECK(Core::Verify(module).empty());
    const auto encoded = Core::Wire::Encode(module);
    REQUIRE(encoded);
    CHECK(Progmasoft::Tala::Pipeline::ConsumeCore(encoded.bytes));
}

TEST_CASE("native Core verifier blocks invalid references mutation and returns")
{
    SECTION("undefined symbol")
    {
        auto module = GoldenModule();
        module.functions.front().returnType = Core::Type::int64();
        module.functions.front().body.front() = Core::Statement::Return(
            Core::Expression::Variable({ 90U, U"missing" },
                                       Core::Type::int64()));
        REQUIRE(HasIssue(Core::Verify(module), "TAC1020"));
    }
    SECTION("immutable assignment")
    {
        auto module = GoldenModule();
        auto &body = module.functions.front().body;
        body.insert(body.begin(),
                    Core::Statement::Bind(
                        { { 2U, U"value" },
                          Core::Type::int64(),
                          false,
                          Core::Expression::Constant(std::int64_t{ 1 },
                                                     Core::Type::int64()) }));
        body.insert(body.begin() + 1,
                    Core::Statement::Assign(
                        { 2U, U"value" },
                        Core::Expression::Constant(std::int64_t{ 2 },
                                                   Core::Type::int64())));
        REQUIRE(HasIssue(Core::Verify(module), "TAC1013"));
    }
    SECTION("missing return path")
    {
        auto module = GoldenModule();
        module.functions.front().returnType = Core::Type::int64();
        module.functions.front().body = { Core::Statement::If(
            Core::Expression::Constant(true, Core::Type::boolean()),
            { Core::Statement::Return(
                Core::Expression::Constant(std::int64_t{ 1 },
                                           Core::Type::int64())) },
            {}) };
        REQUIRE(HasIssue(Core::Verify(module), "TAC1005"));
    }
}

TEST_CASE("Core adapter creates explicit CorePrep CFG and temporaries")
{
    const auto module = PipelineModule();
    REQUIRE(Core::Verify(module).empty());
    const auto prepared = Core::CorePrep::Prepare(module);
    REQUIRE(prepared.functions.size() == 2U);
    REQUIRE(prepared.functions.at(1).blocks.size() == 4U);
    REQUIRE(prepared.functions.at(1).blocks.front().terminator.kind
            == tala::core::Terminator::Kind::Branch);
    REQUIRE(prepared.functions.at(1).blocks.at(1).instructions.size() == 2U);
    REQUIRE(tala::core::verify(prepared).empty());
}

TEST_CASE("Core v10 loops round-trip and lower to explicit back-edges")
{
    const auto integer = [](std::int64_t value) {
        return Core::Expression::Constant(value, Core::Type::int64());
    };
    const auto variable = [](std::uint64_t id, std::u32string spelling) {
        return Core::Expression::Variable({ id, std::move(spelling) },
                                          Core::Type::int64());
    };
    const auto comparison = [&](Core::Primitive operation,
                                std::uint64_t symbol,
                                std::u32string spelling) {
        return Core::Expression::InvokePrimitive(
            operation,
            { variable(symbol, std::move(spelling)), integer(4) },
            Core::Type::boolean());
    };
    const auto increment
        = [&](std::uint64_t symbol, const std::u32string &spelling) {
              return Core::Statement::Assign(
                  { symbol, spelling },
                  Core::Expression::InvokePrimitive(
                      Core::Primitive::Add,
                      { variable(symbol, spelling), integer(1) },
                      Core::Type::int64()));
          };

    Core::Function function{
        { 1U, U"Main" },
        {},
        Core::Type::unit(),
        { Core::Statement::Bind(
              { { 2U, U"index" }, Core::Type::int64(), true, integer(0) }),
          Core::Statement::While(
              comparison(Core::Primitive::LessThan, 2U, U"index"),
              { increment(2U, U"index"), Core::Statement::Continue() }),
          Core::Statement::DoWhile(
              { Core::Statement::Break() },
              Core::Expression::Constant(false, Core::Type::boolean())),
          Core::Statement::For(
              comparison(Core::Primitive::LessThan, 2U, U"index"),
              { Core::Statement::If(
                  Core::Expression::Constant(true, Core::Type::boolean()),
                  { Core::Statement::Continue() },
                  { increment(2U, U"index") }) },
              { increment(2U, U"index") }),
          Core::Statement::Return(
              Core::Expression::Constant(std::monostate{},
                                         Core::Type::unit())) }
    };
    const Core::Module module{ { U"Iteration" }, { std::move(function) } };

    CHECK(Core::Wire::kCurrentVersion == 10U);
    REQUIRE(Core::Verify(module).empty());
    const auto encoded = Core::Wire::Encode(module);
    REQUIRE(encoded);
    const auto decoded = Core::Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    REQUIRE(decoded.module == module);

    const auto prepared = Core::CorePrep::Prepare(*decoded.module);
    REQUIRE(tala::core::verify(prepared).empty());
    const auto &blocks = prepared.functions.front().blocks;
    REQUIRE(blocks.size() >= 10U);
    CHECK(std::ranges::any_of(blocks, [](const auto &block) {
        return block.terminator.kind == tala::core::Terminator::Kind::Jump
               && block.terminator.true_target < block.id;
    }));
}

TEST_CASE("Core verifier rejects break and continue outside loop regions")
{
    auto module = GoldenModule();
    auto &body = module.functions.front().body;
    body.insert(body.begin(), Core::Statement::Break());
    CHECK(HasIssue(Core::Verify(module), "TAC1064"));

    body.front() = Core::Statement::Continue();
    CHECK(HasIssue(Core::Verify(module), "TAC1065"));
}

TEST_CASE("CorePrep canonicalizes numeric branch conditions before Xpp")
{
    Core::Module module{
        { U"NumericBranch" },
        { Core::Function{
            { 1U, U"Main" },
            {},
            Core::Type::unit(),
            { Core::Statement::If(
                Core::Expression::Constant(std::int64_t{ 7 },
                                           Core::Type::int64()),
                { Core::Statement::Return(
                    Core::Expression::Constant(std::monostate{},
                                               Core::Type::unit())) },
                { Core::Statement::Return(
                    Core::Expression::Constant(std::monostate{},
                                               Core::Type::unit())) }) },
        } },
    };
    REQUIRE(Core::Verify(module).empty());
    const auto prepared = Core::CorePrep::Prepare(module);
    REQUIRE(tala::core::verify(prepared).empty());
    const auto &entry = prepared.functions.front().blocks.front();
    REQUIRE(entry.terminator.kind == tala::core::Terminator::Kind::Branch);
    CHECK(entry.terminator.value.type == Core::Type::boolean());
    REQUIRE(entry.instructions.size() == 1U);
    CHECK(entry.instructions.front().operation
          == tala::core::Operation::NotEqual);
}

TEST_CASE(
    "logical operands with distinct numeric types become canonical booleans")
{
    auto logical = Core::Expression::InvokePrimitive(
        Core::Primitive::LogicalAnd,
        {
            Core::Expression::Constant(std::int64_t{ 1 }, Core::Type::int64()),
            Core::Expression::Constant(tala::core::FloatingLiteral{ "2" },
                                       Core::Type::float32()),
        },
        Core::Type::boolean());
    Core::Module module{
        { U"NumericLogical" },
        { Core::Function{
            { 1U, U"Evaluate" },
            {},
            Core::Type::boolean(),
            { Core::Statement::Return(std::move(logical)) },
        } },
    };
    REQUIRE(Core::Verify(module).empty());
    const auto prepared = Core::CorePrep::Prepare(module);
    REQUIRE(tala::core::verify(prepared).empty());
    // Each operand is canonicalized with its own typed `!= 0` comparison.
    // The conjunction itself is control flow: the left comparison and the
    // result slot live in the entry block, and the right comparison runs
    // only in the block the true edge reaches.
    const auto &blocks = prepared.functions.front().blocks;
    REQUIRE(blocks.size() == 3U);
    const auto &entry = blocks.front();
    REQUIRE(entry.instructions.size() == 2U);
    CHECK(entry.instructions.at(0).operation
          == tala::core::Operation::NotEqual);
    CHECK(entry.instructions.at(0).operands.front().type
          == Core::Type::int64());
    CHECK(entry.instructions.at(1).operation == tala::core::Operation::Copy);
    REQUIRE(entry.terminator.kind == tala::core::Terminator::Kind::Branch);
    const auto right = std::ranges::find(blocks,
                                         entry.terminator.true_target,
                                         &tala::core::Block::id);
    REQUIRE(right != blocks.end());
    REQUIRE(right->instructions.size() == 2U);
    CHECK(right->instructions.at(0).operation
          == tala::core::Operation::NotEqual);
    CHECK(right->instructions.at(0).operands.front().type
          == Core::Type::float32());
    CHECK(right->instructions.at(1).kind
          == tala::core::Instruction::Kind::Assign);
    for (const auto &block : blocks)
        for (const auto &instruction : block.instructions)
            CHECK(instruction.operation != tala::core::Operation::LogicalAnd);
    const auto result = Progmasoft::Tala::Pipeline::ConsumeCore(
        Core::Wire::Encode(module).bytes);
    REQUIRE(result);
    CHECK(result.xmmVerificationIssues.empty());
}

TEST_CASE("TACR RAM pipeline reaches optimized Xpp Xmm and LLVM")
{
    const auto encoded = Core::Wire::Encode(PipelineModule());
    REQUIRE(encoded);
    const auto result = Progmasoft::Tala::Pipeline::ConsumeCore(encoded.bytes);
    REQUIRE(result);
    REQUIRE(result.core);
    REQUIRE(result.core_prep);
    REQUIRE(result.xpp);
    REQUIRE(result.xmm);
    REQUIRE(result.llvm);
    REQUIRE(result.coreVerificationIssues.empty());
    REQUIRE(result.verification_issues.empty());
    REQUIRE(result.xppVerificationIssues.empty());
    REQUIRE(result.xmmVerificationIssues.empty());
    REQUIRE(result.xpp->functions.at(1).blocks.size() == 4U);
}

TEST_CASE("TACR RAM pipeline never lowers semantically invalid Core")
{
    auto module = PipelineModule();
    module.functions.at(1).body.front().binding.value.type
        = Core::Type::boolean();
    const auto encoded = Core::Wire::Encode(module);
    REQUIRE(encoded);
    const auto result = Progmasoft::Tala::Pipeline::ConsumeCore(encoded.bytes);
    REQUIRE_FALSE(result);
    REQUIRE(result.core);
    REQUIRE(HasIssue(result.coreVerificationIssues, "TAC1011"));
    REQUIRE_FALSE(result.core_prep);
    REQUIRE_FALSE(result.xpp);
    REQUIRE_FALSE(result.xmm);
    REQUIRE_FALSE(result.llvm);
}

TEST_CASE("Core artifact driver validates and emits LLVM and native artifacts")
{
    const auto encoded = Core::Wire::Encode(GoldenModule());
    REQUIRE(encoded);
    const auto directory
        = std::filesystem::temp_directory_path() / "tala-core-driver";
    std::filesystem::create_directories(directory);
    const auto corePath = directory / "Golden.core";
    const auto llvmPath = directory / "Golden.ll";
    // Keep every explicit format beside one verified Core input, then exercise
    // the binary as a process to cover TargetMachine, LLD, and PE loading
    // together.
    {
        std::ofstream stream(corePath, std::ios::binary | std::ios::trunc);
        stream.write(reinterpret_cast<const char *>(encoded.bytes.data()),
                     static_cast<std::streamsize>(encoded.bytes.size()));
    }
    const auto settings = DefaultCompilerSettings();
    REQUIRE(ProcessCoreArtifact(corePath.string().c_str(),
                                PipelineAction::kCheck,
                                BuildOutput::kExecutable,
                                &settings,
                                nullptr));
    REQUIRE(ProcessCoreArtifact(corePath.string().c_str(),
                                PipelineAction::kBuild,
                                BuildOutput::kLlvmIr,
                                &settings,
                                nullptr));
    REQUIRE(std::filesystem::file_size(llvmPath) > 0U);
#ifdef _WIN32
    const auto objectPath = directory / "Golden.o";
    const auto assemblyPath = directory / "Golden.asm";
    const auto executablePath
        = directory
          / (std::string("Golden") + OutputExtension(BuildOutput::kExecutable));
    REQUIRE(ProcessCoreArtifact(corePath.string().c_str(),
                                PipelineAction::kBuild,
                                BuildOutput::kObject,
                                &settings,
                                nullptr));
    REQUIRE(ProcessCoreArtifact(corePath.string().c_str(),
                                PipelineAction::kBuild,
                                BuildOutput::kAssembly,
                                &settings,
                                nullptr));
    REQUIRE(ProcessCoreArtifact(corePath.string().c_str(),
                                PipelineAction::kBuild,
                                BuildOutput::kExecutable,
                                &settings,
                                nullptr));
    REQUIRE(std::filesystem::file_size(objectPath) > 0U);
    REQUIRE(std::filesystem::file_size(assemblyPath) > 0U);
    REQUIRE(std::filesystem::file_size(executablePath) > 0U);
    const std::vector<const wchar_t *> arguments{ executablePath.c_str(),
                                                  nullptr };
    REQUIRE(_wspawnv(_P_WAIT, executablePath.c_str(), arguments.data()) == 0);
#endif
    std::filesystem::remove_all(directory);
}

TEST_CASE("project artifact driver emits one object and assembly per source")
{
    TemporaryDirectory temporary;
    REQUIRE(temporary);

    auto source = ProjectPartitionModule();
    REQUIRE(Core::Verify(source).empty());
    const auto encoded = Core::Wire::Encode(source);
    REQUIRE(encoded);
    const auto corePath = temporary.Path() / "Project.core";
    {
        std::ofstream stream(corePath, std::ios::binary | std::ios::trunc);
        REQUIRE(stream);
        stream.write(reinterpret_cast<const char *>(encoded.bytes.data()),
                     static_cast<std::streamsize>(encoded.bytes.size()));
        REQUIRE(stream.good());
    }

    // This is the actual Core-to-LLVM project driver boundary, not a test of
    // the filename planner alone. The Math definition is called from Main,
    // while Empty has no declarations but remains a requested compilation
    // unit and therefore still receives an output artifact.
    const auto settings = DefaultCompilerSettings();
    const auto objectDirectory = temporary.Path() / "build" / "debug";
    REQUIRE(ProcessProjectCoreArtifacts(corePath,
                                        objectDirectory,
                                        BuildOutput::kObject,
                                        &settings,
                                        nullptr));
    for (const auto *name : { "Main.o", "Math.o", "Empty.o" })
    {
        const auto artifact = objectDirectory / name;
        REQUIRE(std::filesystem::is_regular_file(artifact));
        CHECK(std::filesystem::file_size(artifact) > 0U);
    }

    const auto assemblyDirectory = temporary.Path() / "build" / "assembly";
    REQUIRE(ProcessProjectCoreArtifacts(corePath,
                                        assemblyDirectory,
                                        BuildOutput::kAssembly,
                                        &settings,
                                        nullptr));
    for (const auto *name : { "Main.asm", "Math.asm", "Empty.asm" })
    {
        const auto artifact = assemblyDirectory / name;
        REQUIRE(std::filesystem::is_regular_file(artifact));
        CHECK(std::filesystem::file_size(artifact) > 0U);
    }
    for (const auto &entry :
         std::filesystem::recursive_directory_iterator(temporary.Path()))
        CHECK(entry.path().filename().string().find(".tala-artifacts-")
              == std::string::npos);
}

TEST_CASE("source catalog paths are revalidated at each native IR boundary")
{
    const auto hasCode = [](const auto &issues, const std::string_view code) {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    };

    auto core = ProjectPartitionModule();
    core.sourceFiles.front() = U"Sources/../Main.tala";
    CHECK(hasCode(Core::Verify(core), "TAC1060"));

    auto prepared = Core::CorePrep::Prepare(ProjectPartitionModule());
    prepared.sourceFiles.front() = U"Sources\\Main.tala";
    CHECK(hasCode(tala::core::verify(prepared), "TAC1064"));

    auto xpp
        = tala::xpp::lower(Core::CorePrep::Prepare(ProjectPartitionModule()));
    xpp.source_files.front() = U"C:/outside/Main.tala";
    CHECK(hasCode(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1020"));

    auto xmm = tala::xmm::lower(
        tala::xpp::lower(Core::CorePrep::Prepare(ProjectPartitionModule())));
    xmm.source_files.front() = U"Sources//Main.tala";
    CHECK(hasCode(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1020"));
}

TEST_CASE("function source owners cannot bypass the module path contract")
{
    const auto hasCode = [](const auto &issues, const std::string_view code) {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    };

    auto core = ProjectPartitionModule();
    core.functions.front().sourceFile = U"Sources/./Math.tala";
    CHECK(hasCode(Core::Verify(core), "TAC1062"));

    auto prepared = Core::CorePrep::Prepare(ProjectPartitionModule());
    prepared.functions.front().sourceFile = U"../Math.tala";
    CHECK(hasCode(tala::core::verify(prepared), "TAC1065"));

    auto xpp
        = tala::xpp::lower(Core::CorePrep::Prepare(ProjectPartitionModule()));
    xpp.functions.front().source_file = U"Math.cpp";
    CHECK(hasCode(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1021"));

    auto xmm = tala::xmm::lower(
        tala::xpp::lower(Core::CorePrep::Prepare(ProjectPartitionModule())));
    xmm.functions.front().source_file = U"\\absolute\\Main.tala";
    CHECK(hasCode(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1021"));
}

TEST_CASE("project partition collision leaves previously built files intact")
{
    TemporaryDirectory temporary;
    REQUIRE(temporary);

    auto source = ProjectPartitionModule();
    source.sourceFiles
        = { U"Sources/First/Main.tala", U"Sources/Second/Main.tala" };
    source.functions[0].sourceFile = source.sourceFiles[0];
    source.functions[1].sourceFile = source.sourceFiles[1];
    const auto encoded = Core::Wire::Encode(source);
    REQUIRE(encoded);

    const auto corePath = temporary.Path() / "Collision.core";
    {
        std::ofstream stream(corePath, std::ios::binary | std::ios::trunc);
        REQUIRE(stream);
        stream.write(reinterpret_cast<const char *>(encoded.bytes.data()),
                     static_cast<std::streamsize>(encoded.bytes.size()));
        REQUIRE(stream.good());
    }
    const auto outputDirectory = temporary.Path() / "build" / "debug";
    std::filesystem::create_directories(outputDirectory);
    {
        std::ofstream stable(outputDirectory / "Main.o",
                             std::ios::binary | std::ios::trunc);
        stable << "previous successful build";
        REQUIRE(stable.good());
    }
    const auto settings = DefaultCompilerSettings();

    // Two distinct source paths flatten to one basename. Planning must reject
    // the whole set before replacing Main.o or publishing a partial Math.o.
    REQUIRE_FALSE(ProcessProjectCoreArtifacts(corePath,
                                              outputDirectory,
                                              BuildOutput::kObject,
                                              &settings,
                                              nullptr));
    std::ifstream stable(outputDirectory / "Main.o", std::ios::binary);
    const std::string contents{ std::istreambuf_iterator<char>(stable),
                                std::istreambuf_iterator<char>() };
    CHECK(contents == "previous successful build");
    CHECK_FALSE(std::filesystem::exists(outputDirectory / "Math.o"));
}
