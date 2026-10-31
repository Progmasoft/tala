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
#include "Progmasoft/Tala/Xmm/Verifier.hpp"

namespace
{
    namespace Core = tala::core;
    namespace IR = tala::xmm;
    namespace Xmm = Progmasoft::Tala::Xmm;

    [[nodiscard]] auto
    Integer(const std::int64_t value) -> IR::Value
    {
        return { IR::Value::Kind::Immediate,
                 Core::Type::int64(),
                 0U,
                 0U,
                 Core::integer_from_signed(value) };
    }

    [[nodiscard]] auto
    Boolean(const bool value) -> IR::Value
    {
        return { IR::Value::Kind::Immediate,
                 Core::Type::boolean(),
                 0U,
                 0U,
                 value };
    }

    [[nodiscard]] auto
    Floating(const std::string_view spelling) -> IR::Value
    {
        return { IR::Value::Kind::Immediate,
                 Core::Type::float64(),
                 0U,
                 0U,
                 Core::FloatingLiteral{ std::string(spelling) } };
    }

    [[nodiscard]] auto
    TypeIdentity(const std::uint64_t value) -> IR::Value
    {
        return { IR::Value::Kind::Immediate,
                 Core::Type::uint64(),
                 0U,
                 0U,
                 Core::integer_from_unsigned(value) };
    }

    [[nodiscard]] auto
    Unit() -> IR::Value
    {
        return { IR::Value::Kind::Immediate,
                 Core::Type::unit(),
                 0U,
                 0U,
                 std::monostate{} };
    }

    [[nodiscard]] auto
    Register(const IR::VirtualRegister reg,
             Core::Type type = Core::Type::int64()) -> IR::Value
    {
        return { IR::Value::Kind::Register,
                 std::move(type),
                 reg,
                 0U,
                 std::monostate{} };
    }

    [[nodiscard]] auto
    Define(const IR::VirtualRegister destination, const std::int64_t value = 0)
        -> IR::Instruction
    {
        return {
            IR::Opcode::LoadImmediate,
            destination,
            Core::Type::int64(),
            { Integer(value) },
            true,
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    DefineFrom(const IR::VirtualRegister destination,
               const IR::VirtualRegister source) -> IR::Instruction
    {
        return {
            IR::Opcode::Move,
            destination,
            Core::Type::int64(),
            { Register(source) },
            true,
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
    Return(const IR::VirtualRegister reg) -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Return;
        terminator.value = Register(reg);
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
        return { { U"Verifier", U"Xmm" }, { std::move(function) } };
    }

    [[nodiscard]] auto
    InitializationIssues(const IR::Module &module)
        -> std::vector<Xmm::VerificationIssue>
    {
        auto issues = Xmm::Verify(module);
        std::erase_if(issues, [](const auto &issue) {
            return issue.kind != Xmm::IssueKind::UninitializedRegister;
        });
        return issues;
    }
} // namespace

TEST_CASE("Xmm accepts a register defined before it is read")
{
    const auto module = Module(
        { Block(0U, { Define(10U), DefineFrom(11U, 10U) }, ReturnUnit()) });
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE(
    "Xmm rejects weak value captures and bounds malformed capture metadata")
{
    const auto callable = Core::Type::function({}, Core::Type::unit());
    IR::Instruction closure;
    closure.opcode = IR::Opcode::MakeClosure;
    closure.destination = 10U;
    closure.result_type = callable;
    closure.operands = { Integer(42) };
    closure.has_result = true;
    closure.closure_function = 2U;
    closure.capture_modes
        = { Core::CaptureMode::Weak, Core::CaptureMode::Strong };

    auto module = Module({ Block(0U, { closure }, ReturnUnit()) });
    IR::Function target;
    target.symbol = { 2U, U"Lifted" };
    target.parameter_registers = { 20U };
    target.parameter_types = { Core::Type::int64() };
    target.return_type = Core::Type::unit();
    target.entry = 0U;
    target.blocks = { Block(0U, {}, ReturnUnit()) };
    module.functions.push_back(std::move(target));

    const auto issues = Xmm::Verify(module);
    CHECK(std::ranges::any_of(issues, [](const auto &issue) {
        return issue.code == "TAL1034";
    }));
    CHECK(std::ranges::any_of(issues, [](const auto &issue) {
        return issue.code == "TAL1051";
    }));
}

TEST_CASE("Xmm rejects a read that precedes its definition")
{
    const auto module = Module(
        { Block(0U, { DefineFrom(11U, 10U), Define(10U) }, ReturnUnit()) });
    const auto issues = InitializationIssues(module);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAL1045");
    CHECK(issues.front().function == 1U);
    CHECK(issues.front().block == 0U);
    CHECK(issues.front().instruction == 0U);
}

TEST_CASE("Xmm requires rounded floating division to return int")
{
    IR::Instruction instruction;
    instruction.opcode = IR::Opcode::FloorDivide;
    instruction.destination = 10U;
    instruction.result_type = Core::Type::float64();
    instruction.operands = { Floating("7.8"), Floating("2.0") };
    instruction.has_result = true;

    const auto issues
        = Xmm::Verify(Module({ Block(0U, { instruction }, ReturnUnit()) }));
    CHECK(std::ranges::any_of(issues, [](const auto &issue) {
        return issue.code == "TAL1052";
    }));
}

TEST_CASE("Xmm accepts the complete type-test ABI tuple")
{
    IR::Instruction typeTest;
    typeTest.opcode = IR::Opcode::TypeIs;
    typeTest.destination = 10U;
    typeTest.result_type = Core::Type::boolean();
    typeTest.operands
        = { Register(5U, Core::Type::string()), TypeIdentity(0x51a2U) };
    typeTest.has_result = true;

    auto module = Module({ Block(0U, { typeTest }, ReturnUnit()) });
    module.functions.front().parameter_registers = { 5U };
    module.functions.front().parameter_types = { Core::Type::string() };
    const auto issues = Xmm::Verify(module);
    CHECK(std::ranges::none_of(issues, [](const auto &issue) {
        return issue.code == "TAL1049";
    }));
}

TEST_CASE("Xmm rejects malformed type-test operands and result")
{
    IR::Instruction typeTest;
    typeTest.opcode = IR::Opcode::TypeIs;
    typeTest.destination = 10U;
    typeTest.result_type = Core::Type::int64();
    typeTest.operands = { Register(5U), Integer(1) };
    typeTest.has_result = true;

    auto module = Module({ Block(0U, { typeTest }, ReturnUnit()) });
    module.functions.front().parameter_registers = { 5U };
    module.functions.front().parameter_types = { Core::Type::int64() };
    CHECK(std::ranges::any_of(Xmm::Verify(module), [](const auto &issue) {
        return issue.code == "TAL1049";
    }));
}

TEST_CASE(
    "Xmm rejects bitwise operations whose operands are not one integer type")
{
    IR::Instruction bitwiseNot;
    bitwiseNot.opcode = IR::Opcode::BitwiseNot;
    bitwiseNot.destination = 10U;
    bitwiseNot.result_type = Core::Type::boolean();
    bitwiseNot.operands = { Boolean(true) };
    bitwiseNot.has_result = true;

    const auto module = Module({ Block(0U, { bitwiseNot }, ReturnUnit()) });
    CHECK(std::ranges::any_of(Xmm::Verify(module), [](const auto &issue) {
        return issue.code == "TAL1050";
    }));
}

TEST_CASE("Xmm parameters are initialized at function entry")
{
    auto module = Module({ Block(0U, { DefineFrom(11U, 10U) }, ReturnUnit()) });
    auto &function = module.functions.front();
    function.parameter_registers = { 10U };
    function.parameter_types = { Core::Type::int64() };
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE("Xmm return registers require definite initialization")
{
    const auto module = Module(
        {
            Block(0U, {}, Return(10U)),
            Block(9U, { Define(10U) }, Return(10U)),
        },
        Core::Type::int64());
    const auto issues = InitializationIssues(module);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().instruction == 0U);
    CHECK(issues.front().message.find("terminator") != std::string::npos);
}

TEST_CASE("Xmm uses predecessor intersection at a join")
{
    const auto module = Module({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Define(10U) }, Jump(3U)),
        Block(2U, {}, Jump(3U)),
        Block(3U, { DefineFrom(11U, 10U) }, ReturnUnit()),
    });
    CHECK(InitializationIssues(module).size() == 1U);
}

TEST_CASE("Xmm accepts a joined register written on every path")
{
    const auto module = Module({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Define(10U, 1) }, Jump(3U)),
        Block(2U, { Define(10U, 2) }, Jump(3U)),
        Block(3U, { DefineFrom(11U, 10U) }, ReturnUnit()),
    });
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE("Xmm storage discovery is independent of block order")
{
    auto module = Module({
        Block(0U, { Define(10U) }, Jump(1U)),
        Block(1U, { DefineFrom(11U, 10U) }, ReturnUnit()),
    });
    const auto forward = Xmm::Verify(module);
    std::ranges::reverse(module.functions.front().blocks);
    const auto reverse = Xmm::Verify(module);
    CHECK(forward == reverse);
}

TEST_CASE("Xmm skips unreachable register reads")
{
    const auto module = Module({
        Block(0U, { Define(10U) }, ReturnUnit()),
        Block(7U, { DefineFrom(11U, 10U) }, ReturnUnit()),
    });
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE("Xmm preserves instruction location for multiple bad reads")
{
    IR::Instruction sum;
    sum.opcode = IR::Opcode::Add;
    sum.destination = 12U;
    sum.result_type = Core::Type::int64();
    sum.operands = { Register(10U), Register(11U) };
    sum.has_result = true;
    const auto module = Module(
        { Block(0U, { sum, Define(10U), Define(11U) }, ReturnUnit()) });
    const auto issues = InitializationIssues(module);
    REQUIRE(issues.size() == 2U);
    CHECK(std::ranges::all_of(issues, [](const auto &issue) {
        return issue.instruction == 0U;
    }));
}

TEST_CASE("Xmm initialization crosses a loop preheader")
{
    const auto module = Module({
        Block(0U, { Define(10U) }, Jump(1U)),
        Block(1U, { DefineFrom(11U, 10U) }, Branch(1U, 2U)),
        Block(2U, { DefineFrom(12U, 10U) }, ReturnUnit()),
    });
    CHECK(InitializationIssues(module).empty());
}

TEST_CASE("Xmm loop-carried writes cannot satisfy the first iteration")
{
    const auto module = Module({
        Block(0U, {}, Jump(1U)),
        Block(1U, { DefineFrom(11U, 10U), Define(10U) }, Branch(1U, 2U)),
        Block(2U, {}, ReturnUnit()),
    });
    CHECK(InitializationIssues(module).size() == 1U);
}

TEST_CASE("Xmm entry backedges do not manufacture register values")
{
    const auto module = Module({
        Block(0U, { DefineFrom(11U, 10U) }, Jump(1U)),
        Block(1U, { Define(10U) }, Jump(0U)),
    });
    CHECK(InitializationIssues(module).size() == 1U);
}

TEST_CASE("Xmm type conflicts remain distinct from initialization errors")
{
    auto module = Module({ Block(0U, { Define(10U) }, ReturnUnit()) });
    auto conflicting = Define(10U);
    conflicting.result_type = Core::Type::boolean();
    conflicting.operands = { Boolean(true) };
    module.functions.front().blocks.front().instructions.push_back(conflicting);
    const auto issues = Xmm::Verify(module);
    CHECK(std::ranges::any_of(issues, [](const auto &issue) {
        return issue.kind == Xmm::IssueKind::RegisterRedefinition;
    }));
    CHECK(InitializationIssues(module).empty());
}
