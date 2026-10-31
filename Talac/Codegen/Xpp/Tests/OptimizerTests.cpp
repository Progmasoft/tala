// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstdint>
#include <ranges>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Xpp/IR.hpp"
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
    Symbol(const IR::SymbolId symbol) -> IR::Operand
    {
        return { IR::Operand::Kind::Symbol,
                 Core::Type::int64(),
                 symbol,
                 std::monostate{} };
    }

    [[nodiscard]] auto
    Copy(const IR::SymbolId destination, const IR::Operand &source)
        -> IR::Instruction
    {
        return {
            IR::Instruction::Effect::Define,
            IR::Opcode::Copy,
            destination,
            source.type,
            { source },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    Store(const IR::SymbolId destination, const IR::Operand &source)
        -> IR::Instruction
    {
        auto instruction = Copy(destination, source);
        instruction.effect = IR::Instruction::Effect::Store;
        return instruction;
    }

    [[nodiscard]] auto
    Discard(const IR::Operand &source) -> IR::Instruction
    {
        return {
            IR::Instruction::Effect::Discard,
            IR::Opcode::Copy,
            0U,
            source.type,
            { source },
            0U,
            {},
        };
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
        terminator.value = { IR::Operand::Kind::Literal,
                             Core::Type::unit(),
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
        return { { U"Optimizer", U"Xpp" }, { std::move(function) } };
    }

    [[nodiscard]] auto
    ModuleWithIntegerParameter(std::vector<IR::Block> blocks) -> IR::Module
    {
        auto module = Module(std::move(blocks));
        module.functions.front().parameters.push_back(
            Core::Parameter{ { 10U, U"value" }, Core::Type::int64() });
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
        {
            result.push_back(block.id);
        }
        return result;
    }
} // namespace

TEST_CASE("Xpp optimization removes an unreachable region")
{
    const auto optimized = IR::optimize(Module({
        Block(0U, {}, Jump(1U)),
        Block(1U, {}, Return()),
        Block(90U, { Copy(10U, Integer(1)) }, Return()),
    }));

    CHECK(BlockOrder(optimized) == std::vector<IR::BlockId>{ 0U, 1U });
    CHECK(Xpp::Verify(optimized).empty());
}

TEST_CASE("Xpp optimization collapses identical branch destinations")
{
    const auto optimized = IR::optimize(
        Module({ Block(0U, {}, Branch(1U, 1U)), Block(1U, {}, Return()) }));
    const auto &terminator = FindBlock(optimized, 0U).terminator;
    CHECK(terminator.kind == IR::Terminator::Kind::Jump);
    CHECK(terminator.true_target == 1U);
}

TEST_CASE("Xpp optimization bypasses an empty jump trampoline")
{
    const auto optimized = IR::optimize(Module({
        Block(0U, {}, Branch(1U, 3U)),
        Block(1U, {}, Jump(2U)),
        Block(2U, {}, Return()),
        Block(3U, {}, Return()),
    }));

    const auto &entry = FindBlock(optimized, 0U);
    CHECK(entry.terminator.true_target == 2U);
    CHECK(entry.terminator.false_target == 3U);
    CHECK(BlockOrder(optimized) == std::vector<IR::BlockId>{ 0U, 3U, 2U });
}

TEST_CASE("Xpp optimization resolves a chain of empty trampolines")
{
    const auto optimized = IR::optimize(Module({
        Block(0U, {}, Jump(1U)),
        Block(1U, {}, Jump(2U)),
        Block(2U, {}, Jump(3U)),
        Block(3U, {}, Return()),
    }));

    CHECK(BlockOrder(optimized) == std::vector<IR::BlockId>{ 0U, 3U });
    CHECK(FindBlock(optimized, 0U).terminator.true_target == 3U);
}

TEST_CASE("Xpp optimization retains a jump block with an observable store")
{
    const auto optimized = IR::optimize(Module({
        Block(0U, {}, Jump(1U)),
        Block(1U, { Copy(10U, Integer(0)), Store(10U, Integer(4)) }, Jump(2U)),
        Block(2U, {}, Return()),
    }));

    CHECK(BlockOrder(optimized) == std::vector<IR::BlockId>{ 0U, 1U, 2U });
    REQUIRE(FindBlock(optimized, 1U).instructions.size() == 2U);
    CHECK(Xpp::Verify(optimized).empty());
}

TEST_CASE("Xpp optimization removes only true self copies")
{
    const auto optimized = IR::optimize(ModuleWithIntegerParameter({
        Block(0U,
              { Copy(12U, Integer(0)),
                Store(10U, Symbol(10U)),
                Copy(11U, Symbol(10U)),
                Store(12U, Symbol(11U)) },
              Return()),
    }));

    const auto &instructions = FindBlock(optimized, 0U).instructions;
    REQUIRE(instructions.size() == 3U);
    CHECK(instructions.front().destination == 12U);
    CHECK(instructions[1].destination == 11U);
    CHECK(instructions.back().effect == IR::Instruction::Effect::Store);
    CHECK(Xpp::Verify(optimized).empty());
}

TEST_CASE("Xpp optimization removes a transitive dead copy chain")
{
    const auto optimized
        = IR::optimize(Module({ Block(0U,
                                      { Copy(10U, Integer(1)),
                                        Copy(11U, Symbol(10U)),
                                        Copy(12U, Symbol(11U)) },
                                      Return()) }));

    CHECK(FindBlock(optimized, 0U).instructions.empty());
    CHECK(Xpp::Verify(optimized).empty());
}

TEST_CASE(
    "Xpp optimization retains the complete chain feeding an observable store")
{
    const auto optimized
        = IR::optimize(Module({ Block(0U,
                                      { Copy(12U, Integer(0)),
                                        Copy(10U, Integer(1)),
                                        Copy(11U, Symbol(10U)),
                                        Store(12U, Symbol(11U)) },
                                      Return()) }));

    const auto &instructions = FindBlock(optimized, 0U).instructions;
    REQUIRE(instructions.size() == 4U);
    CHECK(instructions[0].destination == 12U);
    CHECK(instructions[1].destination == 10U);
    CHECK(instructions[2].destination == 11U);
    CHECK(instructions[3].effect == IR::Instruction::Effect::Store);
    CHECK(Xpp::Verify(optimized).empty());
}

TEST_CASE("Xpp optimization retains explicit discard evaluation")
{
    const auto optimized = IR::optimize(
        Module({ Block(0U,
                       { Copy(10U, Integer(1)), Discard(Symbol(10U)) },
                       Return()) }));

    REQUIRE(FindBlock(optimized, 0U).instructions.size() == 2U);
    CHECK(Xpp::Verify(optimized).empty());
}

TEST_CASE("Xpp optimization is insensitive to source block presentation")
{
    auto ordered = Module({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Copy(10U, Integer(1)) }, Jump(3U)),
        Block(2U, { Copy(11U, Integer(2)) }, Jump(3U)),
        Block(3U, {}, Return()),
    });
    auto shuffled = Module({
        Block(3U, {}, Return()),
        Block(2U, { Copy(11U, Integer(2)) }, Jump(3U)),
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Copy(10U, Integer(1)) }, Jump(3U)),
    });

    const auto optimizedOrdered = IR::optimize(std::move(ordered));
    const auto optimizedShuffled = IR::optimize(std::move(shuffled));
    CHECK(optimizedOrdered == optimizedShuffled);
}

TEST_CASE("Xpp optimization preserves semantic branch successor order")
{
    const auto optimized = IR::optimize(Module({
        Block(0U, {}, Branch(8U, 4U)),
        Block(4U, { Copy(4U, Integer(4)) }, Return()),
        Block(8U, { Copy(8U, Integer(8)) }, Return()),
    }));

    const auto &entry = FindBlock(optimized, 0U).terminator;
    CHECK(entry.true_target == 8U);
    CHECK(entry.false_target == 4U);
    CHECK(BlockOrder(optimized) == std::vector<IR::BlockId>{ 0U, 4U, 8U });
}

TEST_CASE("Xpp optimization is idempotent")
{
    const auto once = IR::optimize(Module({
        Block(0U, { Copy(1U, Symbol(1U)) }, Jump(1U)),
        Block(1U, {}, Jump(2U)),
        Block(2U, {}, Return()),
        Block(99U, {}, Return()),
    }));
    CHECK(IR::optimize(once) == once);
}

TEST_CASE("Xpp optimization terminates on an empty jump cycle")
{
    const auto optimized = IR::optimize(
        Module({ Block(0U, {}, Jump(1U)), Block(1U, {}, Jump(0U)) }));
    CHECK(optimized.functions.front().blocks.size() == 2U);
}
