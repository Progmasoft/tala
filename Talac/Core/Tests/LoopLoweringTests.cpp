// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstdint>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"

// These tests pin the control-flow graph the native Core-to-CorePrep adapter
// builds for structured loops. They assert exact edges instead of "some
// back-edge exists": a for-loop whose update region branched to itself used
// to satisfy every weaker shape check while never terminating.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Prepared = tala::core;

    constexpr std::uint64_t kTotal = 2U;
    constexpr std::uint64_t kIndex = 3U;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Spelling(std::uint64_t id) -> std::u32string
    {
        return id == kTotal ? U"total" : id == kIndex ? U"index" : U"inner";
    }

    [[nodiscard]] auto
    Variable(std::uint64_t id, std::u32string spelling) -> Core::Expression
    {
        return Core::Expression::Variable({ id, std::move(spelling) },
                                          Core::Type::int64());
    }

    [[nodiscard]] auto
    Compare(Core::Primitive operation, std::uint64_t id, std::int64_t value)
        -> Core::Expression
    {
        return Core::Expression::InvokePrimitive(
            operation,
            { Variable(id, Spelling(id)), Integer(value) },
            Core::Type::boolean());
    }

    [[nodiscard]] auto
    Increment(std::uint64_t id, const std::u32string &spelling)
        -> Core::Statement
    {
        return Core::Statement::Assign(
            { id, spelling },
            Core::Expression::InvokePrimitive(
                Core::Primitive::Add,
                { Variable(id, spelling), Integer(1) },
                Core::Type::int64()));
    }

    [[nodiscard]] auto
    Accumulate() -> Core::Statement
    {
        return Core::Statement::Assign(
            { kTotal, U"total" },
            Core::Expression::InvokePrimitive(
                Core::Primitive::Add,
                { Variable(kTotal, U"total"), Variable(kIndex, U"index") },
                Core::Type::int64()));
    }

    /// `int total = 0; int index = 0; <loop>; return total;`
    [[nodiscard]] auto
    LoopModule(Core::Statement loop) -> Core::Module
    {
        Core::Function function{
            { 1U, U"Evaluate" },
            {},
            Core::Type::int64(),
            { Core::Statement::Bind({ { kTotal, U"total" },
                                      Core::Type::int64(),
                                      true,
                                      Integer(0) }),
              Core::Statement::Bind({ { kIndex, U"index" },
                                      Core::Type::int64(),
                                      true,
                                      Integer(0) }),
              std::move(loop),
              Core::Statement::Return(Variable(kTotal, U"total")) },
        };
        return { { U"Loops" }, { std::move(function) } };
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

    [[nodiscard]] auto
    Successors(const Prepared::Block &block) -> std::vector<Prepared::BlockId>
    {
        switch (block.terminator.kind)
        {
            case Prepared::Terminator::Kind::Jump:
                return { block.terminator.true_target };
            case Prepared::Terminator::Kind::Branch:
                return { block.terminator.true_target,
                         block.terminator.false_target };
            default:
                return {};
        }
    }

    /// Blocks reachable from the entry that end in a function return.
    [[nodiscard]] auto
    ReachesReturn(const Prepared::Function &function, Prepared::BlockId from)
        -> bool
    {
        std::vector<Prepared::BlockId> pending{ from };
        std::vector<Prepared::BlockId> seen;
        while (!pending.empty())
        {
            const auto id = pending.back();
            pending.pop_back();
            if (std::ranges::find(seen, id) != seen.end())
                continue;
            seen.push_back(id);
            const auto &block = Find(function, id);
            if (block.terminator.kind == Prepared::Terminator::Kind::Return)
                return true;
            for (const auto successor : Successors(block))
                pending.push_back(successor);
        }
        return false;
    }

    [[nodiscard]] auto
    IsJumpTo(const Prepared::Block &block, Prepared::BlockId target) -> bool
    {
        return block.terminator.kind == Prepared::Terminator::Kind::Jump
               && block.terminator.true_target == target;
    }

    struct ForShape final
    {
        Prepared::BlockId condition;
        Prepared::BlockId body;
        Prepared::BlockId update;
        Prepared::BlockId exit;
    };

    /// Recover the for-loop block roles from edges alone, then check each.
    [[nodiscard]] auto
    ForShapeOf(const Prepared::Function &function) -> ForShape
    {
        const auto &entry = Find(function, function.entry);
        REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Jump);
        const auto conditionId = entry.terminator.true_target;
        const auto &condition = Find(function, conditionId);
        REQUIRE(condition.terminator.kind
                == Prepared::Terminator::Kind::Branch);
        const auto bodyId = condition.terminator.true_target;
        const auto exitId = condition.terminator.false_target;
        // The adapter numbers the update region directly after the body
        // entry; the edge checks below confirm that role independently.
        return { conditionId, bodyId, bodyId + 1U, exitId };
    }
} // namespace

TEST_CASE("for-loop update region returns to the condition block",
          "[coreprep][loop]")
{
    const auto function = PrepareVerified(LoopModule(
        Core::Statement::For(Compare(Core::Primitive::LessThan, kIndex, 1),
                             { Accumulate() },
                             { Increment(kIndex, U"index") })));
    const auto shape = ForShapeOf(function);

    const auto &body = Find(function, shape.body);
    const auto &update = Find(function, shape.update);
    CHECK(IsJumpTo(body, shape.update));
    // The update region's only successor is the condition. A jump back to
    // the update block itself is an infinite loop that skips the condition.
    CHECK(IsJumpTo(update, shape.condition));
    CHECK_FALSE(IsJumpTo(update, shape.update));
    CHECK(update.instructions.size() >= 1U);
    CHECK(Find(function, shape.exit).terminator.kind
          == Prepared::Terminator::Kind::Return);
    for (const auto &block : function.blocks)
        CHECK(ReachesReturn(function, block.id));
}

TEST_CASE("for-loop continue runs the update and break leaves the loop",
          "[coreprep][loop]")
{
    const auto function = PrepareVerified(LoopModule(Core::Statement::For(
        Compare(Core::Primitive::LessThan, kIndex, 12),
        { Core::Statement::If(Compare(Core::Primitive::Equal, kIndex, 2),
                              { Core::Statement::Continue() },
                              {}),
          Core::Statement::If(Compare(Core::Primitive::Equal, kIndex, 9),
                              { Core::Statement::Break() },
                              {}),
          Accumulate() },
        { Increment(kIndex, U"index") })));
    const auto shape = ForShapeOf(function);

    // Body entry tests `index == 2`; its true arm is the continue.
    const auto &body = Find(function, shape.body);
    REQUIRE(body.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(IsJumpTo(Find(function, body.terminator.true_target), shape.update));

    // The join of the first `if` tests `index == 9`; its true arm breaks.
    const auto &firstElse = Find(function, body.terminator.false_target);
    REQUIRE(firstElse.terminator.kind == Prepared::Terminator::Kind::Jump);
    const auto &second = Find(function, firstElse.terminator.true_target);
    REQUIRE(second.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(IsJumpTo(Find(function, second.terminator.true_target), shape.exit));

    const auto &update = Find(function, shape.update);
    CHECK(IsJumpTo(update, shape.condition));

    // Exactly the body tail and the continue arm enter the update region,
    // and only the update region re-enters the condition from inside.
    std::size_t intoUpdate{};
    std::size_t intoCondition{};
    for (const auto &block : function.blocks)
    {
        const auto successors = Successors(block);
        intoUpdate += static_cast<std::size_t>(
            std::ranges::count(successors, shape.update));
        intoCondition += static_cast<std::size_t>(
            std::ranges::count(successors, shape.condition));
        CHECK(ReachesReturn(function, block.id));
    }
    CHECK(intoUpdate == 2U);
    CHECK(intoCondition == 2U); // function entry and the update region
}

TEST_CASE("for-loop with an empty update still returns to the condition",
          "[coreprep][loop]")
{
    const auto function = PrepareVerified(LoopModule(
        Core::Statement::For(Compare(Core::Primitive::LessThan, kIndex, 3),
                             { Accumulate(), Increment(kIndex, U"index") },
                             {})));
    const auto shape = ForShapeOf(function);
    const auto &update = Find(function, shape.update);
    CHECK(update.instructions.empty());
    CHECK(IsJumpTo(update, shape.condition));
}

TEST_CASE("for-loop update containing a branch closes every open tail",
          "[coreprep][loop]")
{
    // Structured updates may lower to several blocks; each open tail must
    // reach the condition, not only the first update block.
    const auto function = PrepareVerified(LoopModule(Core::Statement::For(
        Compare(Core::Primitive::LessThan, kIndex, 4),
        { Accumulate() },
        { Core::Statement::If(
            Compare(Core::Primitive::LessThan, kTotal, 2),
            { Increment(kIndex, U"index") },
            { Increment(kIndex, U"index"), Increment(kTotal, U"total") }) })));
    const auto shape = ForShapeOf(function);
    const auto &update = Find(function, shape.update);
    REQUIRE(update.terminator.kind == Prepared::Terminator::Kind::Branch);
    const auto &join = Find(
        function,
        Find(function, update.terminator.true_target).terminator.true_target);
    CHECK(IsJumpTo(join, shape.condition));
    for (const auto &block : function.blocks)
    {
        CHECK_FALSE(IsJumpTo(block, block.id));
        CHECK(ReachesReturn(function, block.id));
    }
}

TEST_CASE("for-loop numeric condition keeps its comparison in the header",
          "[coreprep][loop]")
{
    // A non-Boolean condition is canonicalized to `value != 0`. That
    // comparison belongs to the condition block so every iteration
    // re-evaluates it and the branch operand is defined on all paths.
    const auto function = PrepareVerified(LoopModule(
        Core::Statement::For(Core::Expression::InvokePrimitive(
                                 Core::Primitive::Subtract,
                                 { Integer(3), Variable(kIndex, U"index") },
                                 Core::Type::int64()),
                             { Accumulate() },
                             { Increment(kIndex, U"index") })));
    const auto shape = ForShapeOf(function);
    const auto &condition = Find(function, shape.condition);
    REQUIRE(condition.terminator.value.kind == Prepared::Atom::Kind::Variable);
    const auto branchSymbol = condition.terminator.value.symbol.id;
    CHECK(condition.terminator.value.type == Core::Type::boolean());
    CHECK(std::ranges::any_of(
        condition.instructions,
        [branchSymbol](const auto &instruction) {
            return instruction.destination.id == branchSymbol
                   && instruction.operation == Prepared::Operation::NotEqual;
        }));
}

TEST_CASE("nested for-loops keep independent continue and break targets",
          "[coreprep][loop]")
{
    constexpr std::uint64_t kInner = 4U;
    auto inner = Core::Statement::For(
        Compare(Core::Primitive::LessThan, kInner, 3),
        { Core::Statement::If(Compare(Core::Primitive::Equal, kInner, 1),
                              { Core::Statement::Continue() },
                              {}),
          Accumulate() },
        { Increment(kInner, U"inner") });
    const auto function = PrepareVerified(LoopModule(Core::Statement::For(
        Compare(Core::Primitive::LessThan, kIndex, 3),
        { Core::Statement::Bind(
              { { kInner, U"inner" }, Core::Type::int64(), true, Integer(0) }),
          std::move(inner) },
        { Increment(kIndex, U"index") })));
    const auto outer = ForShapeOf(function);

    const auto &outerBody = Find(function, outer.body);
    REQUIRE(outerBody.terminator.kind == Prepared::Terminator::Kind::Jump);
    const auto innerConditionId = outerBody.terminator.true_target;
    const auto &innerCondition = Find(function, innerConditionId);
    REQUIRE(innerCondition.terminator.kind
            == Prepared::Terminator::Kind::Branch);
    const auto innerBodyId = innerCondition.terminator.true_target;
    const auto innerUpdateId = innerBodyId + 1U;
    const auto innerExitId = innerCondition.terminator.false_target;

    CHECK(IsJumpTo(Find(function, innerUpdateId), innerConditionId));
    // The inner continue targets the inner update, never the outer one.
    const auto &innerBody = Find(function, innerBodyId);
    REQUIRE(innerBody.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(IsJumpTo(Find(function, innerBody.terminator.true_target),
                   innerUpdateId));
    // Leaving the inner loop falls through to the outer update region.
    CHECK(IsJumpTo(Find(function, innerExitId), outer.update));
    CHECK(IsJumpTo(Find(function, outer.update), outer.condition));
    for (const auto &block : function.blocks)
        CHECK(ReachesReturn(function, block.id));
}

TEST_CASE("while-loop condition owns a header separate from prior statements",
          "[coreprep][loop]")
{
    const auto function = PrepareVerified(LoopModule(Core::Statement::While(
        Compare(Core::Primitive::LessThan, kIndex, 3),
        { Core::Statement::If(
              Compare(Core::Primitive::Equal, kIndex, 1),
              { Increment(kIndex, U"index"), Core::Statement::Continue() },
              {}),
          Accumulate(),
          Increment(kIndex, U"index") })));

    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Jump);
    const auto headerId = entry.terminator.true_target;
    REQUIRE(headerId != function.entry);
    const auto &header = Find(function, headerId);
    REQUIRE(header.terminator.kind == Prepared::Terminator::Kind::Branch);

    // The initializers stay in the entry block and are never re-executed:
    // nothing in the header may define or assign a source variable.
    CHECK(entry.instructions.size() == 2U);
    CHECK(
        std::ranges::none_of(header.instructions, [](const auto &instruction) {
            return instruction.destination.id == kTotal
                   || instruction.destination.id == kIndex;
        }));

    std::size_t backEdges{};
    for (const auto &block : function.blocks)
    {
        if (block.id != function.entry)
            backEdges += static_cast<std::size_t>(
                std::ranges::count(Successors(block), headerId));
        CHECK(std::ranges::count(Successors(block), function.entry) == 0);
        CHECK(ReachesReturn(function, block.id));
    }
    CHECK(backEdges == 2U); // the continue arm and the body tail

    const auto &body = Find(function, header.terminator.true_target);
    REQUIRE(body.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(IsJumpTo(Find(function, body.terminator.true_target), headerId));
}

TEST_CASE("do-while continue targets the trailing condition block",
          "[coreprep][loop]")
{
    const auto function = PrepareVerified(LoopModule(Core::Statement::DoWhile(
        { Increment(kIndex, U"index"),
          Core::Statement::If(Compare(Core::Primitive::Equal, kIndex, 2),
                              { Core::Statement::Continue() },
                              {}),
          Core::Statement::If(Compare(Core::Primitive::Equal, kIndex, 5),
                              { Core::Statement::Break() },
                              {}),
          Accumulate() },
        Compare(Core::Primitive::LessThan, kIndex, 8))));

    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Jump);
    const auto bodyId = entry.terminator.true_target;
    const auto conditionId = bodyId + 1U;
    const auto &condition = Find(function, conditionId);
    REQUIRE(condition.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(condition.terminator.true_target == bodyId);
    const auto exitId = condition.terminator.false_target;

    const auto &body = Find(function, bodyId);
    REQUIRE(body.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(IsJumpTo(Find(function, body.terminator.true_target), conditionId));
    const auto &second = Find(
        function,
        Find(function, body.terminator.false_target).terminator.true_target);
    REQUIRE(second.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(IsJumpTo(Find(function, second.terminator.true_target), exitId));
    for (const auto &block : function.blocks)
        CHECK(ReachesReturn(function, block.id));
}

TEST_CASE("Core verifier rejects continue in a for update region",
          "[core][verifier][loop]")
{
    const auto codes = [](std::vector<Core::Statement> body,
                          std::vector<Core::Statement> update) {
        std::vector<std::string> result;
        for (const auto &issue : Core::Verify(LoopModule(Core::Statement::For(
                 Compare(Core::Primitive::LessThan, kIndex, 3),
                 std::move(body),
                 std::move(update)))))
            result.push_back(issue.code);
        return result;
    };
    const auto has
        = [](const std::vector<std::string> &found, std::string_view code) {
              return std::ranges::find(found, code) != found.end();
          };

    // The update region is the loop's continuation point: a `continue`
    // there would re-enter the update and never test the condition again.
    CHECK(has(codes({}, { Core::Statement::Continue() }), "TAC1066"));
    CHECK(has(
        codes({},
              { Core::Statement::If(Compare(Core::Primitive::Equal, kIndex, 1),
                                    { Core::Statement::Continue() },
                                    {}) }),
        "TAC1066"));

    // `continue` in the body, `break` in the update, and `continue` in a
    // loop nested inside the update all keep a defined target.
    CHECK(
        codes({ Core::Statement::Continue() }, { Increment(kIndex, U"index") })
            .empty());
    CHECK(codes({ Accumulate() },
                { Increment(kIndex, U"index"), Core::Statement::Break() })
              .empty());
    CHECK(codes({ Accumulate() },
                { Increment(kIndex, U"index"),
                  Core::Statement::While(
                      Compare(Core::Primitive::LessThan, kTotal, 0),
                      { Core::Statement::Continue() }) })
              .empty());

    // Outside any loop the existing diagnostic applies, not the new one.
    auto module = LoopModule(Core::Statement::Continue());
    std::vector<std::string> outside;
    for (const auto &issue : Core::Verify(module))
        outside.push_back(issue.code);
    CHECK(has(outside, "TAC1065"));
    CHECK_FALSE(has(outside, "TAC1066"));
}
