// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstdint>
#include <ranges>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"
#include "Progmasoft/Tala/Xmm/Verifier.hpp"

namespace
{
    namespace Core = tala::core;
    namespace IR = tala::xmm;
    namespace Xmm = Progmasoft::Tala::Xmm;
    namespace Xpp = tala::xpp;

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
    Register(const IR::VirtualRegister reg) -> IR::Value
    {
        return { IR::Value::Kind::Register,
                 Core::Type::int64(),
                 reg,
                 0U,
                 std::monostate{} };
    }

    [[nodiscard]] auto
    Move(const IR::VirtualRegister destination,
         const IR::VirtualRegister source) -> IR::Instruction
    {
        return { IR::Opcode::Move,
                 destination,
                 Core::Type::int64(),
                 { Register(source) },
                 true,
                 0U,
                 {} };
    }

    [[nodiscard]] auto
    Define(const IR::VirtualRegister destination, const std::int64_t value)
        -> IR::Instruction
    {
        return { IR::Opcode::LoadImmediate,
                 destination,
                 Core::Type::int64(),
                 { Integer(value) },
                 true,
                 0U,
                 {} };
    }

    [[nodiscard]] auto
    Add(const IR::VirtualRegister destination,
        const IR::Value &left,
        const IR::Value &right) -> IR::Instruction
    {
        return { IR::Opcode::Add,
                 destination,
                 Core::Type::int64(),
                 { left, right },
                 true,
                 0U,
                 {} };
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
    Return() -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Return;
        terminator.value = { IR::Value::Kind::Immediate,
                             Core::Type::unit(),
                             0U,
                             0U,
                             std::monostate{} };
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
    Module(std::vector<IR::Block> blocks) -> IR::Module
    {
        IR::Function function;
        function.symbol = { 1U, U"Optimize" };
        function.return_type = Core::Type::unit();
        function.entry = 0U;
        function.blocks = std::move(blocks);
        return { { U"Optimizer", U"Xmm" }, { std::move(function) } };
    }

    [[nodiscard]] auto
    ModuleWithIntegerParameter(std::vector<IR::Block> blocks) -> IR::Module
    {
        auto module = Module(std::move(blocks));
        module.functions.front().parameter_registers.push_back(10U);
        module.functions.front().parameter_types.push_back(Core::Type::int64());
        return module;
    }

    [[nodiscard]] auto
    FindBlock(const IR::Module &module, const IR::BlockId id)
        -> const IR::Block &
    {
        const auto &blocks = module.functions.front().blocks;
        const auto found = std::ranges::find(blocks, id, &IR::Block::id);
        REQUIRE(found != blocks.end());
        return *found;
    }

    [[nodiscard]] auto
    BlockOrder(const IR::Module &module) -> std::vector<IR::BlockId>
    {
        std::vector<IR::BlockId> result;
        for (const auto &block : module.functions.front().blocks)
            result.push_back(block.id);
        return result;
    }

    [[nodiscard]] auto
    XppInteger(const std::int64_t value) -> Xpp::Operand
    {
        return { Xpp::Operand::Kind::Literal,
                 Core::Type::int64(),
                 0U,
                 Core::integer_from_signed(value) };
    }

    [[nodiscard]] auto
    XppCopy(const Xpp::SymbolId destination, const std::int64_t value)
        -> Xpp::Instruction
    {
        return {
            Xpp::Instruction::Effect::Define,
            Xpp::Opcode::Copy,
            destination,
            Core::Type::int64(),
            { XppInteger(value) },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    XppReturn() -> Xpp::Terminator
    {
        Xpp::Terminator terminator;
        terminator.kind = Xpp::Terminator::Kind::Return;
        terminator.value = { Xpp::Operand::Kind::Literal,
                             Core::Type::unit(),
                             0U,
                             std::monostate{} };
        return terminator;
    }

    [[nodiscard]] auto
    LoweringInput(std::vector<Xpp::Block> blocks) -> Xpp::Module
    {
        Xpp::Function function;
        function.symbol = { 40U, U"Registers" };
        // Parameter order is the externally observable calling convention and
        // therefore intentionally differs from numeric SymbolId order.
        function.parameters = {
            Core::Parameter{ { 90U, U"first" }, Core::Type::int64() },
            Core::Parameter{ { 20U, U"second" }, Core::Type::int64() },
        };
        function.return_type = Core::Type::unit();
        function.entry = 0U;
        function.blocks = std::move(blocks);
        return { { U"Lowering", U"Order" }, { std::move(function) } };
    }
} // namespace

TEST_CASE("Xmm optimization removes unreachable machine blocks")
{
    const auto optimized = IR::optimize(Module({
        Block(0U, {}, Jump(1U)),
        Block(1U, {}, Return()),
        Block(99U, { Define(9U, 9) }, Return()),
    }));

    CHECK(BlockOrder(optimized) == std::vector<IR::BlockId>{ 0U, 1U });
    CHECK(Xmm::Verify(optimized).empty());
}

TEST_CASE("Xmm optimization changes an identical branch into a jump")
{
    const auto optimized = IR::optimize(
        Module({ Block(0U, {}, Branch(2U, 2U)), Block(2U, {}, Return()) }));
    const auto &terminator = FindBlock(optimized, 0U).terminator;
    CHECK(terminator.kind == IR::Terminator::Kind::Jump);
    CHECK(terminator.true_target == 2U);
    CHECK(terminator.false_target == 0U);
}

TEST_CASE("Xmm optimization bypasses and removes empty trampolines")
{
    const auto optimized = IR::optimize(Module({
        Block(0U, {}, Branch(1U, 4U)),
        Block(1U, {}, Jump(2U)),
        Block(2U, {}, Jump(3U)),
        Block(3U, {}, Return()),
        Block(4U, {}, Return()),
    }));

    const auto &entry = FindBlock(optimized, 0U).terminator;
    CHECK(entry.true_target == 3U);
    CHECK(entry.false_target == 4U);
    CHECK(BlockOrder(optimized) == std::vector<IR::BlockId>{ 0U, 4U, 3U });
}

TEST_CASE(
    "Xmm optimization conservatively retains arithmetic with a dead result")
{
    const auto optimized = IR::optimize(Module({
        Block(0U, {}, Jump(1U)),
        Block(1U, { Add(10U, Integer(7), Integer(8)) }, Jump(2U)),
        Block(2U, {}, Return()),
    }));

    CHECK(FindBlock(optimized, 0U).terminator.true_target == 1U);
    CHECK(FindBlock(optimized, 1U).instructions.size() == 1U);
}

TEST_CASE("Xmm optimization removes a register self move")
{
    const auto optimized = IR::optimize(ModuleWithIntegerParameter({ Block(
        0U,
        { Move(10U, 10U), Move(11U, 10U), Add(12U, Register(11U), Integer(1)) },
        Return()) }));
    const auto &instructions = FindBlock(optimized, 0U).instructions;
    REQUIRE(instructions.size() == 2U);
    CHECK(instructions.front().destination == 11U);
    CHECK(Xmm::Verify(optimized).empty());
}

TEST_CASE("Xmm optimization removes a transitive dead materialization chain")
{
    const auto optimized = IR::optimize(
        Module({ Block(0U,
                       { Define(10U, 1), Move(11U, 10U), Move(12U, 11U) },
                       Return()) }));

    CHECK(FindBlock(optimized, 0U).instructions.empty());
    CHECK(Xmm::Verify(optimized).empty());
}

TEST_CASE(
    "Xmm optimization retains producers consumed by conservative arithmetic")
{
    const auto optimized = IR::optimize(Module({ Block(
        0U,
        { Define(10U, 1), Move(11U, 10U), Add(12U, Register(11U), Integer(1)) },
        Return()) }));

    const auto &instructions = FindBlock(optimized, 0U).instructions;
    REQUIRE(instructions.size() == 3U);
    CHECK(instructions[0].destination == 10U);
    CHECK(instructions[1].destination == 11U);
    CHECK(instructions[2].opcode == IR::Opcode::Add);
    CHECK(Xmm::Verify(optimized).empty());
}

TEST_CASE("Xmm dead materialization removal crosses block boundaries")
{
    const auto optimized = IR::optimize(Module({
        Block(0U, { Define(10U, 1) }, Jump(1U)),
        Block(1U, { Move(11U, 10U) }, Return()),
    }));

    CHECK(FindBlock(optimized, 0U).instructions.empty());
    CHECK(FindBlock(optimized, 1U).instructions.empty());
    CHECK(Xmm::Verify(optimized).empty());
}

TEST_CASE("Xmm optimization canonicalizes shuffled block presentation")
{
    auto ordered = Module({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Define(10U, 1) }, Jump(3U)),
        Block(2U, { Define(11U, 2) }, Jump(3U)),
        Block(3U, {}, Return()),
    });
    auto shuffled = Module({
        Block(3U, {}, Return()),
        Block(1U, { Define(10U, 1) }, Jump(3U)),
        Block(0U, {}, Branch(1U, 2U)),
        Block(2U, { Define(11U, 2) }, Jump(3U)),
    });
    const auto optimizedOrdered = IR::optimize(std::move(ordered));
    const auto optimizedShuffled = IR::optimize(std::move(shuffled));
    CHECK(optimizedOrdered == optimizedShuffled);
}

TEST_CASE("Xmm optimization is idempotent")
{
    const auto once = IR::optimize(Module({
        Block(0U, { Move(1U, 1U) }, Jump(1U)),
        Block(1U, {}, Jump(2U)),
        Block(2U, {}, Return()),
        Block(8U, {}, Return()),
    }));
    CHECK(IR::optimize(once) == once);
}

TEST_CASE("Xmm optimization terminates when trampolines form a cycle")
{
    const auto optimized = IR::optimize(
        Module({ Block(0U, {}, Jump(1U)), Block(1U, {}, Jump(0U)) }));
    CHECK(optimized.functions.front().blocks.size() == 2U);
}

TEST_CASE("Xmm lowering preserves ABI order and sorts local SymbolIds")
{
    const auto lowered = IR::lower(LoweringInput({
        Xpp::Block{ 0U, { XppCopy(70U, 7) }, XppReturn() },
        Xpp::Block{ 1U, { XppCopy(30U, 3) }, XppReturn() },
    }));
    const auto &function = lowered.functions.front();
    CHECK(function.parameter_registers
          == std::vector<IR::VirtualRegister>{ 1U, 2U });
    CHECK(FindBlock(lowered, 1U).instructions.front().destination == 3U);
    CHECK(FindBlock(lowered, 0U).instructions.front().destination == 4U);
}

TEST_CASE("Xmm register assignment ignores source block order")
{
    const auto blockZero = Xpp::Block{ 0U, { XppCopy(70U, 7) }, XppReturn() };
    const auto blockOne = Xpp::Block{ 1U, { XppCopy(30U, 3) }, XppReturn() };
    const auto ordered = IR::lower(LoweringInput({ blockZero, blockOne }));
    const auto shuffled = IR::lower(LoweringInput({ blockOne, blockZero }));

    CHECK(FindBlock(ordered, 0U) == FindBlock(shuffled, 0U));
    CHECK(FindBlock(ordered, 1U) == FindBlock(shuffled, 1U));
    CHECK(ordered.functions.front().parameter_registers
          == shuffled.functions.front().parameter_registers);
}
