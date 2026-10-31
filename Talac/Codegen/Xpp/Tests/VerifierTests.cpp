// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstdint>
#include <ranges>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Xpp/Verifier.hpp"

namespace
{
    namespace Core = tala::core;
    namespace IR = tala::xpp;
    namespace Xpp = Progmasoft::Tala::Xpp;

    [[nodiscard]] auto
    Integer(const std::int64_t value) -> IR::Operand
    {
        return { IR::Operand::Kind::Literal,
                 Core::Type::int64(),
                 0U,
                 Core::integer_from_signed(value) };
    }

    [[nodiscard]] auto
    Boolean(const bool value) -> IR::Operand
    {
        return { IR::Operand::Kind::Literal, Core::Type::boolean(), 0U, value };
    }

    [[nodiscard]] auto
    Floating(const std::string_view spelling) -> IR::Operand
    {
        return { IR::Operand::Kind::Literal,
                 Core::Type::float64(),
                 0U,
                 Core::FloatingLiteral{ std::string(spelling) } };
    }

    [[nodiscard]] auto
    TypeIdentity(const std::uint64_t value) -> IR::Operand
    {
        return { IR::Operand::Kind::Literal,
                 Core::Type::uint64(),
                 0U,
                 Core::integer_from_unsigned(value) };
    }

    [[nodiscard]] auto
    Unit() -> IR::Operand
    {
        return { IR::Operand::Kind::Literal,
                 Core::Type::unit(),
                 0U,
                 std::monostate{} };
    }

    [[nodiscard]] auto
    Symbol(const IR::SymbolId symbol, Core::Type type = Core::Type::int64())
        -> IR::Operand
    {
        return { IR::Operand::Kind::Symbol,
                 std::move(type),
                 symbol,
                 std::monostate{} };
    }

    [[nodiscard]] auto
    Define(const IR::SymbolId destination, const std::int64_t value = 0)
        -> IR::Instruction
    {
        return {
            IR::Instruction::Effect::Define,
            IR::Opcode::Copy,
            destination,
            Core::Type::int64(),
            { Integer(value) },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    DefineFrom(const IR::SymbolId destination, const IR::SymbolId source)
        -> IR::Instruction
    {
        return {
            IR::Instruction::Effect::Define,
            IR::Opcode::Copy,
            destination,
            Core::Type::int64(),
            { Symbol(source) },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    Store(const IR::SymbolId destination, const std::int64_t value)
        -> IR::Instruction
    {
        return {
            IR::Instruction::Effect::Store,
            IR::Opcode::Copy,
            destination,
            Core::Type::int64(),
            { Integer(value) },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    Evaluate(const IR::SymbolId source) -> IR::Instruction
    {
        return {
            IR::Instruction::Effect::Discard,
            IR::Opcode::Copy,
            0U,
            Core::Type::unit(),
            { Symbol(source) },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    ReturnUnit() -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Return;
        terminator.value = Unit();
        return terminator;
    }

    [[nodiscard]] auto
    Return(const IR::SymbolId storage) -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Return;
        terminator.value = Symbol(storage);
        return terminator;
    }

    [[nodiscard]] auto
    Jump(const IR::BlockId target) -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Jump;
        terminator.true_target = target;
        return terminator;
    }

    [[nodiscard]] auto
    Branch(const IR::BlockId trueTarget, const IR::BlockId falseTarget)
        -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Branch;
        terminator.value = Boolean(true);
        terminator.true_target = trueTarget;
        terminator.false_target = falseTarget;
        return terminator;
    }

    [[nodiscard]] auto
    Block(const IR::BlockId id,
          std::vector<IR::Instruction> instructions,
          IR::Terminator terminator) -> IR::Block
    {
        return { id, std::move(instructions), std::move(terminator) };
    }

    [[nodiscard]] auto
    Module(std::vector<IR::Block> blocks,
           Core::Type result = Core::Type::unit()) -> IR::Module
    {
        IR::Function function;
        function.symbol = { 1U, U"Evaluate" };
        function.return_type = std::move(result);
        function.entry = 0U;
        function.blocks = std::move(blocks);
        return { { U"Verifier", U"Xpp" }, { std::move(function) } };
    }

    [[nodiscard]] auto
    HasCode(const std::vector<Xpp::VerificationIssue> &issues,
            const std::string_view code) -> bool
    {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    }

    [[nodiscard]] auto
    InitializationIssues(const IR::Module &module)
        -> std::vector<Xpp::VerificationIssue>
    {
        auto issues = Xpp::Verify(module);
        std::erase_if(issues, [](const auto &issue) {
            return issue.code != "TAP1041";
        });
        return issues;
    }
} // namespace

TEST_CASE("Xpp accepts a definition followed by a read")
{
    const auto module
        = Module({ Block(0U, { Define(10U), Evaluate(10U) }, ReturnUnit()) });
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE("Xpp reports a read before a later definition")
{
    const auto module
        = Module({ Block(0U, { Evaluate(10U), Define(10U) }, ReturnUnit()) });
    const auto issues = InitializationIssues(module);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().function == 1U);
    CHECK(issues.front().block == 0U);
    CHECK(issues.front().instruction == 0U);
}

TEST_CASE("Xpp requires rounded floating division to return int")
{
    IR::Instruction instruction{
        IR::Instruction::Effect::Define,
        IR::Opcode::FloorDivide,
        10U,
        Core::Type::float64(),
        { Floating("7.8"), Floating("2.0") },
        0U,
        {},
    };
    const auto issues
        = Xpp::Verify(Module({ Block(0U, { instruction }, ReturnUnit()) }));
    CHECK(HasCode(issues, "TAP1046"));
}

TEST_CASE("Xpp reads instruction operands before writing their destination")
{
    const auto module
        = Module({ Block(0U, { DefineFrom(10U, 10U) }, ReturnUnit()) });
    CHECK(InitializationIssues(module).size() == 1U);
}

TEST_CASE("Xpp parameters seed definite initialization")
{
    auto module = Module({ Block(0U, { Evaluate(5U) }, ReturnUnit()) });
    module.functions.front().parameters.push_back(
        { { 5U, U"value" }, Core::Type::int64() });
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE("Xpp detects an uninitialized return operand")
{
    const auto module = Module({ Block(0U, { Define(10U) }, Return(11U)),
                                 Block(1U, { Define(11U) }, Return(11U)) },
                               Core::Type::int64());
    const auto issues = InitializationIssues(module);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().instruction == 1U);
    CHECK(issues.front().message.find("terminator") != std::string::npos);
}

TEST_CASE("Xpp requires a definition on both paths of a diamond")
{
    const auto partial = Module({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Define(10U) }, Jump(3U)),
        Block(2U, {}, Jump(3U)),
        Block(3U, { Evaluate(10U) }, ReturnUnit()),
    });
    CHECK(InitializationIssues(partial).size() == 1U);

    auto complete = partial;
    complete.functions.front().blocks[2].instructions.push_back(Store(10U, 2));
    CHECK(InitializationIssues(complete).empty());
}

TEST_CASE("Xpp block vector order is not execution order")
{
    auto module = Module({
        Block(0U, { Define(10U) }, Jump(1U)),
        Block(1U, { Evaluate(10U) }, ReturnUnit()),
    });
    const auto ordered = InitializationIssues(module);
    std::ranges::reverse(module.functions.front().blocks);
    const auto reversed = InitializationIssues(module);
    CHECK(ordered.empty());
    CHECK(reversed.empty());
}

TEST_CASE("Xpp does not validate unreachable storage reads as executions")
{
    const auto module = Module({
        Block(0U, { Define(10U) }, ReturnUnit()),
        Block(4U, { Evaluate(10U) }, ReturnUnit()),
    });
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE("Xpp direct function symbols are not local storage reads")
{
    auto module = Module({ Block(0U, {}, ReturnUnit()) });
    IR::Function target;
    target.symbol = { 2U, U"Target" };
    target.return_type = Core::Type::unit();
    target.entry = 0U;
    target.blocks = { Block(0U, {}, ReturnUnit()) };
    module.functions.push_back(target);

    IR::Instruction call;
    call.effect = IR::Instruction::Effect::Discard;
    call.opcode = IR::Opcode::Call;
    call.result_type = Core::Type::unit();
    call.operands
        = { Symbol(2U, Core::Type::function({}, Core::Type::unit())) };
    module.functions.front().blocks.front().instructions.push_back(call);
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE(
    "Xpp closure storage is a local read even though its type is callable")
{
    const auto callable = Core::Type::function({}, Core::Type::unit());
    auto module
        = Module({ Block(0U, {}, ReturnUnit()), Block(1U, {}, ReturnUnit()) });
    IR::Instruction declaration;
    declaration.effect = IR::Instruction::Effect::Define;
    declaration.opcode = IR::Opcode::Copy;
    declaration.destination = 20U;
    declaration.result_type = callable;
    declaration.operands = { Symbol(20U, callable) };
    module.functions.front().blocks[1].instructions.push_back(declaration);

    IR::Instruction call;
    call.effect = IR::Instruction::Effect::Discard;
    call.opcode = IR::Opcode::Call;
    call.result_type = Core::Type::unit();
    call.operands = { Symbol(20U, callable) };
    module.functions.front().blocks.front().instructions.push_back(call);
    CHECK(InitializationIssues(module).size() == 1U);
}

TEST_CASE("Xpp safely rejects malformed weak closure capture metadata")
{
    const auto callable = Core::Type::function({}, Core::Type::unit());
    IR::Instruction closure;
    closure.effect = IR::Instruction::Effect::Define;
    closure.opcode = IR::Opcode::MakeClosure;
    closure.destination = 10U;
    closure.result_type = callable;
    closure.operands = { Integer(42) };
    closure.closure_function = 2U;
    closure.capture_modes
        = { Core::CaptureMode::Weak, Core::CaptureMode::Strong };

    auto module = Module({ Block(0U, { closure }, ReturnUnit()) });
    IR::Function target;
    target.symbol = { 2U, U"Lifted" };
    target.parameters = { { { 20U, U"captured" }, Core::Type::int64() } };
    target.return_type = Core::Type::unit();
    target.entry = 0U;
    target.blocks = { Block(0U, {}, ReturnUnit()) };
    module.functions.push_back(std::move(target));

    const auto issues = Xpp::Verify(module);
    CHECK(HasCode(issues, "TAP1030"));
    CHECK(HasCode(issues, "TAP1033"));
}

TEST_CASE("Xpp initialization diagnostic code is stable")
{
    const auto module
        = Module({ Block(0U, { Evaluate(10U), Define(10U) }, ReturnUnit()) });
    const auto issues = Xpp::Verify(module);
    CHECK(HasCode(issues, "TAP1041"));
}

TEST_CASE("Xpp accepts the complete type-test ABI tuple")
{
    IR::Instruction typeTest;
    typeTest.effect = IR::Instruction::Effect::Define;
    typeTest.opcode = IR::Opcode::TypeIs;
    typeTest.destination = 10U;
    typeTest.result_type = Core::Type::boolean();
    typeTest.operands
        = { Symbol(5U, Core::Type::string()), TypeIdentity(0x51a2U) };

    auto module = Module({ Block(0U, { typeTest }, ReturnUnit()) });
    module.functions.front().parameters.push_back(
        { { 5U, U"value" }, Core::Type::string() });
    CHECK_FALSE(HasCode(Xpp::Verify(module), "TAP1045"));
}

TEST_CASE("Xpp rejects every malformed type-test ABI dimension")
{
    IR::Instruction typeTest;
    typeTest.effect = IR::Instruction::Effect::Define;
    typeTest.opcode = IR::Opcode::TypeIs;
    typeTest.destination = 10U;
    typeTest.result_type = Core::Type::int64();
    typeTest.operands = { Symbol(5U), Integer(1) };

    auto module = Module({ Block(0U, { typeTest }, ReturnUnit()) });
    module.functions.front().parameters.push_back(
        { { 5U, U"value" }, Core::Type::int64() });
    CHECK(HasCode(Xpp::Verify(module), "TAP1045"));

    module.functions.front()
        .blocks.front()
        .instructions.front()
        .operands.pop_back();
    CHECK(HasCode(Xpp::Verify(module), "TAP1045"));
}

TEST_CASE("Xpp reports every uninitialized operand at its instruction")
{
    IR::Instruction sum;
    sum.effect = IR::Instruction::Effect::Define;
    sum.opcode = IR::Opcode::Add;
    sum.destination = 12U;
    sum.result_type = Core::Type::int64();
    sum.operands = { Symbol(10U), Symbol(11U) };
    const auto module = Module(
        { Block(0U, { sum, Define(10U), Define(11U) }, ReturnUnit()) });
    const auto issues = InitializationIssues(module);
    REQUIRE(issues.size() == 2U);
    CHECK(std::ranges::all_of(issues, [](const auto &issue) {
        return issue.instruction == 0U;
    }));
}

TEST_CASE("Xpp initialization survives a loop with a preheader")
{
    const auto module = Module({
        Block(0U, { Define(10U) }, Jump(1U)),
        Block(1U, { Evaluate(10U) }, Branch(1U, 2U)),
        Block(2U, { Evaluate(10U) }, ReturnUnit()),
    });
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE("Xpp loop-only writes cannot initialize first iteration reads")
{
    const auto module = Module({
        Block(0U, {}, Jump(1U)),
        Block(1U, { Evaluate(10U), Define(10U) }, Branch(1U, 2U)),
        Block(2U, {}, ReturnUnit()),
    });
    CHECK(InitializationIssues(module).size() == 1U);
}
