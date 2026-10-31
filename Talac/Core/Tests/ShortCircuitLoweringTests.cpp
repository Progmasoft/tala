// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstdint>
#include <optional>
#include <ranges>
#include <string>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"

// `&&` and `||` are control flow in CorePrep: the right operand is reached
// only through the branch that needs it. These tests pin that shape on the
// native Core-to-CorePrep adapter. An eager two-operand instruction computes
// the same Boolean for pure operands but evaluates a guarded division, call
// or recursion that the source never executes.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Prepared = tala::core;

    constexpr std::uint64_t kLeft = 2U;
    constexpr std::uint64_t kRight = 3U;
    constexpr std::uint64_t kThird = 4U;

    [[nodiscard]] auto
    Spelling(std::uint64_t id) -> std::u32string
    {
        return id == kLeft ? U"left" : id == kRight ? U"right" : U"third";
    }

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Variable(std::uint64_t id) -> Core::Expression
    {
        return Core::Expression::Variable({ id, Spelling(id) },
                                          Core::Type::int64());
    }

    /// `id < 10`; the distinct symbol identifies which operand a block owns.
    [[nodiscard]] auto
    Below(std::uint64_t id) -> Core::Expression
    {
        return Core::Expression::InvokePrimitive(Core::Primitive::LessThan,
                                                 { Variable(id), Integer(10) },
                                                 Core::Type::boolean());
    }

    [[nodiscard]] auto
    Logical(Core::Primitive operation,
            Core::Expression left,
            Core::Expression right) -> Core::Expression
    {
        return Core::Expression::InvokePrimitive(
            operation,
            { std::move(left), std::move(right) },
            Core::Type::boolean());
    }

    [[nodiscard]] auto
    Declare(std::uint64_t id) -> Core::Statement
    {
        return Core::Statement::Bind(
            { { id, Spelling(id) }, Core::Type::int64(), true, Integer(0) });
    }

    [[nodiscard]] auto
    Module(Core::Type returnType, std::vector<Core::Statement> tail)
        -> Core::Module
    {
        std::vector<Core::Statement> body{ Declare(kLeft),
                                           Declare(kRight),
                                           Declare(kThird) };
        body.insert(body.end(),
                    std::make_move_iterator(tail.begin()),
                    std::make_move_iterator(tail.end()));
        return { { U"ShortCircuit" },
                 { Core::Function{ { 1U, U"Evaluate" },
                                   {},
                                   std::move(returnType),
                                   std::move(body) } } };
    }

    [[nodiscard]] auto
    PrepareVerified(const Core::Module &module) -> Prepared::Function
    {
        for (const auto &issue : Core::Verify(module))
            FAIL_CHECK("Core " << issue.code << ": " << issue.message);
        REQUIRE(Core::Verify(module).empty());
        auto prepared = Core::CorePrep::Prepare(module);
        for (const auto &issue : Prepared::verify(prepared))
            FAIL_CHECK("CorePrep " << issue.code << ": " << issue.message
                                   << " (block " << issue.block << ")");
        REQUIRE(Prepared::verify(prepared).empty());
        REQUIRE(prepared.functions.size() == 1U);
        return std::move(prepared.functions.front());
    }

    [[nodiscard]] auto
    Find(const Prepared::Function &function, Prepared::BlockId id)
        -> const Prepared::Block &
    {
        const auto found
            = std::ranges::find(function.blocks, id, &Prepared::Block::id);
        REQUIRE(found != function.blocks.end());
        return *found;
    }

    /// The block whose instructions read the given source variable.
    [[nodiscard]] auto
    BlockReading(const Prepared::Function &function, std::uint64_t symbol)
        -> std::optional<Prepared::BlockId>
    {
        for (const auto &block : function.blocks)
            for (const auto &instruction : block.instructions)
                if (instruction.operation == Prepared::Operation::LessThan
                    && std::ranges::any_of(
                        instruction.operands,
                        [symbol](const auto &operand) {
                            return operand.kind
                                       == Prepared::Atom::Kind::Variable
                                   && operand.symbol.id == symbol;
                        }))
                    return block.id;
        return std::nullopt;
    }

    [[nodiscard]] auto
    HasEagerLogicalOperation(const Prepared::Function &function) -> bool
    {
        return std::ranges::any_of(function.blocks, [](const auto &block) {
            return std::ranges::any_of(
                block.instructions,
                [](const auto &instruction) {
                    return instruction.operation
                               == Prepared::Operation::LogicalAnd
                           || instruction.operation
                                  == Prepared::Operation::LogicalOr;
                });
        });
    }

    [[nodiscard]] auto
    IsJumpTo(const Prepared::Block &block, Prepared::BlockId target) -> bool
    {
        return block.terminator.kind == Prepared::Terminator::Kind::Jump
               && block.terminator.true_target == target;
    }
} // namespace

TEST_CASE("logical and evaluates its right operand only on the true edge",
          "[coreprep][shortcircuit]")
{
    const auto function = PrepareVerified(
        Module(Core::Type::boolean(),
               { Core::Statement::Return(Logical(Core::Primitive::LogicalAnd,
                                                 Below(kLeft),
                                                 Below(kRight))) }));
    CHECK_FALSE(HasEagerLogicalOperation(function));

    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
    const auto leftBlock = BlockReading(function, kLeft);
    const auto rightBlock = BlockReading(function, kRight);
    REQUIRE(leftBlock);
    REQUIRE(rightBlock);
    CHECK(*leftBlock == function.entry);
    CHECK(*rightBlock != function.entry);
    // True continues into the right operand; false skips it to the join.
    CHECK(entry.terminator.true_target == *rightBlock);
    const auto joinId = entry.terminator.false_target;
    CHECK(joinId != *rightBlock);
    const auto &right = Find(function, *rightBlock);
    CHECK(IsJumpTo(right, joinId));

    // The join returns one slot: initialized false before the branch and
    // overwritten only by the right operand's block.
    const auto &join = Find(function, joinId);
    REQUIRE(join.terminator.kind == Prepared::Terminator::Kind::Return);
    REQUIRE(join.terminator.value.kind == Prepared::Atom::Kind::Variable);
    const auto result = join.terminator.value.symbol.id;
    const auto initializer
        = std::ranges::find_if(entry.instructions,
                               [result](const auto &instruction) {
                                   return instruction.destination.id == result;
                               });
    REQUIRE(initializer != entry.instructions.end());
    CHECK(initializer->kind == Prepared::Instruction::Kind::Bind);
    CHECK(initializer->mutable_binding);
    REQUIRE(initializer->operands.size() == 1U);
    CHECK(initializer->operands.front().literal == Prepared::Literal{ false });
    REQUIRE_FALSE(right.instructions.empty());
    CHECK(right.instructions.back().kind
          == Prepared::Instruction::Kind::Assign);
    CHECK(right.instructions.back().destination.id == result);
}

TEST_CASE("logical or evaluates its right operand only on the false edge",
          "[coreprep][shortcircuit]")
{
    const auto function = PrepareVerified(
        Module(Core::Type::boolean(),
               { Core::Statement::Return(Logical(Core::Primitive::LogicalOr,
                                                 Below(kLeft),
                                                 Below(kRight))) }));
    CHECK_FALSE(HasEagerLogicalOperation(function));

    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
    const auto rightBlock = BlockReading(function, kRight);
    REQUIRE(rightBlock);
    CHECK(entry.terminator.false_target == *rightBlock);
    const auto joinId = entry.terminator.true_target;
    CHECK(IsJumpTo(Find(function, *rightBlock), joinId));
    const auto &join = Find(function, joinId);
    REQUIRE(join.terminator.kind == Prepared::Terminator::Kind::Return);
    const auto result = join.terminator.value.symbol.id;
    const auto initializer
        = std::ranges::find_if(entry.instructions,
                               [result](const auto &instruction) {
                                   return instruction.destination.id == result;
                               });
    REQUIRE(initializer != entry.instructions.end());
    REQUIRE(initializer->operands.size() == 1U);
    CHECK(initializer->operands.front().literal == Prepared::Literal{ true });
}

TEST_CASE("nested short-circuit operands stay behind their own guards",
          "[coreprep][shortcircuit]")
{
    // (left && right) || third: `right` needs left, `third` needs the
    // conjunction to be false, and neither is evaluated in the entry block.
    const auto function = PrepareVerified(Module(
        Core::Type::boolean(),
        { Core::Statement::Return(Logical(
            Core::Primitive::LogicalOr,
            Logical(Core::Primitive::LogicalAnd, Below(kLeft), Below(kRight)),
            Below(kThird))) }));
    CHECK_FALSE(HasEagerLogicalOperation(function));
    const auto leftBlock = BlockReading(function, kLeft);
    const auto rightBlock = BlockReading(function, kRight);
    const auto thirdBlock = BlockReading(function, kThird);
    REQUIRE(leftBlock);
    REQUIRE(rightBlock);
    REQUIRE(thirdBlock);
    CHECK(*leftBlock == function.entry);
    CHECK(*rightBlock != function.entry);
    CHECK(*thirdBlock != function.entry);
    CHECK(*thirdBlock != *rightBlock);

    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(entry.terminator.true_target == *rightBlock);
    // The conjunction's join decides whether `third` runs at all.
    const auto &innerJoin = Find(function, entry.terminator.false_target);
    REQUIRE(innerJoin.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(innerJoin.terminator.false_target == *thirdBlock);
    CHECK(IsJumpTo(Find(function, *thirdBlock),
                   innerJoin.terminator.true_target));
}

TEST_CASE("short-circuit loop condition is re-evaluated from the loop header",
          "[coreprep][shortcircuit][loop]")
{
    const auto function = PrepareVerified(Module(
        Core::Type::int64(),
        { Core::Statement::While(
              Logical(Core::Primitive::LogicalAnd, Below(kLeft), Below(kRight)),
              { Core::Statement::Assign({ kLeft, Spelling(kLeft) },
                                        Core::Expression::InvokePrimitive(
                                            Core::Primitive::Add,
                                            { Variable(kLeft), Integer(1) },
                                            Core::Type::int64())) }),
          Core::Statement::Return(Variable(kLeft)) }));
    CHECK_FALSE(HasEagerLogicalOperation(function));

    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Jump);
    const auto headerId = entry.terminator.true_target;
    const auto leftBlock = BlockReading(function, kLeft);
    const auto rightBlock = BlockReading(function, kRight);
    REQUIRE(leftBlock);
    REQUIRE(rightBlock);
    CHECK(*leftBlock == headerId);
    CHECK(*rightBlock != headerId);

    // The header only decides whether the right operand runs; the loop's
    // own body/exit branch lives in the short-circuit join.
    const auto &header = Find(function, headerId);
    REQUIRE(header.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(header.terminator.true_target == *rightBlock);
    const auto &join = Find(function, header.terminator.false_target);
    REQUIRE(join.terminator.kind == Prepared::Terminator::Kind::Branch);
    const auto &body = Find(function, join.terminator.true_target);
    // The back-edge re-enters the header so `left` is tested again.
    CHECK(IsJumpTo(body, headerId));
    CHECK(Find(function, join.terminator.false_target).terminator.kind
          == Prepared::Terminator::Kind::Return);
}

TEST_CASE("logical not remains an ordinary single-block operation",
          "[coreprep][shortcircuit]")
{
    const auto function = PrepareVerified(
        Module(Core::Type::boolean(),
               { Core::Statement::Return(Core::Expression::InvokePrimitive(
                   Core::Primitive::LogicalNot,
                   { Below(kLeft) },
                   Core::Type::boolean())) }));
    REQUIRE(function.blocks.size() == 1U);
    CHECK(std::ranges::any_of(function.blocks.front().instructions,
                              [](const auto &instruction) {
                                  return instruction.operation
                                         == Prepared::Operation::LogicalNot;
                              }));
}
