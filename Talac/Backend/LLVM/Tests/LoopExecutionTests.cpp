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

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/IR.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"

// Executable loop regressions. Every case is lowered from structured Core
// through CorePrep, Xpp, Xmm and LLVM, run in ORC, and compared with a value
// computed by an ordinary host loop written in this file. Comparing the
// optimized and unoptimized pipelines with each other is not sufficient: a
// defect in the shared Core-to-CorePrep adapter makes both agree on the same
// wrong answer, or on the same non-terminating program.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Pipeline = Progmasoft::Tala::Pipeline;
    namespace Prepared = tala::core;

    constexpr std::uint64_t kTotal = 2U;
    constexpr std::uint64_t kIndex = 3U;
    constexpr std::uint64_t kInner = 4U;
    constexpr std::int64_t kLimits = 13;

    [[nodiscard]] auto
    Spelling(std::uint64_t id) -> std::u32string
    {
        return id == kTotal ? U"total" : id == kIndex ? U"index" : U"inner";
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

    [[nodiscard]] auto
    Compare(Core::Primitive operation, std::uint64_t id, std::int64_t value)
        -> Core::Expression
    {
        return Core::Expression::InvokePrimitive(
            operation,
            { Variable(id), Integer(value) },
            Core::Type::boolean());
    }

    [[nodiscard]] auto
    Add(std::uint64_t destination, Core::Expression value) -> Core::Statement
    {
        return Core::Statement::Assign(
            { destination, Spelling(destination) },
            Core::Expression::InvokePrimitive(
                Core::Primitive::Add,
                { Variable(destination), std::move(value) },
                Core::Type::int64()));
    }

    [[nodiscard]] auto
    Increment(std::uint64_t id) -> Core::Statement
    {
        return Add(id, Integer(1));
    }

    [[nodiscard]] auto
    When(std::uint64_t id, std::int64_t value, Core::Statement then)
        -> Core::Statement
    {
        return Core::Statement::If(Compare(Core::Primitive::Equal, id, value),
                                   { std::move(then) },
                                   {});
    }

    [[nodiscard]] auto
    Declare(std::uint64_t id) -> Core::Statement
    {
        return Core::Statement::Bind(
            { { id, Spelling(id) }, Core::Type::int64(), true, Integer(0) });
    }

    /// `int total = 0; int index = 0; <loop>; return total;`
    [[nodiscard]] auto
    LoopModule(Core::Statement loop) -> Core::Module
    {
        Core::Function function{
            { 1U, U"Evaluate" },
            {},
            Core::Type::int64(),
            { Declare(kTotal),
              Declare(kIndex),
              std::move(loop),
              Core::Statement::Return(Variable(kTotal)) },
        };
        return { { U"Loops" }, { std::move(function) } };
    }

    /// True when every CorePrep block can still reach a function return.
    /// A loop region that cannot leave is rejected before it is executed, so
    /// a control-flow regression fails this suite instead of hanging it.
    [[nodiscard]] auto
    EveryBlockReachesReturn(const Prepared::Function &function) -> bool
    {
        const auto successors = [](const Prepared::Block &block) {
            std::vector<Prepared::BlockId> targets;
            if (block.terminator.kind == Prepared::Terminator::Kind::Jump)
                targets = { block.terminator.true_target };
            if (block.terminator.kind == Prepared::Terminator::Kind::Branch)
                targets = { block.terminator.true_target,
                            block.terminator.false_target };
            return targets;
        };
        // Backward fixed point from the return blocks.
        std::vector<Prepared::BlockId> returning;
        for (const auto &block : function.blocks)
            if (block.terminator.kind == Prepared::Terminator::Kind::Return)
                returning.push_back(block.id);
        for (bool changed = true; changed;)
        {
            changed = false;
            for (const auto &block : function.blocks)
            {
                if (std::ranges::find(returning, block.id) != returning.end())
                    continue;
                const auto targets = successors(block);
                if (std::ranges::any_of(targets, [&](const auto target) {
                        return std::ranges::find(returning, target)
                               != returning.end();
                    }))
                {
                    returning.push_back(block.id);
                    changed = true;
                }
            }
        }
        return returning.size() == function.blocks.size();
    }

    [[nodiscard]] auto
    Run(const Core::Module &module, bool optimize)
        -> std::optional<std::int64_t>
    {
        const auto encoded = Core::Wire::Encode(module);
        REQUIRE(encoded);
        Pipeline::Options options;
        options.optimize_xpp = optimize;
        options.optimize_xmm = optimize;
        options.llvm.optimization = optimize ? Llvm::OptimizationLevel::Default
                                             : Llvm::OptimizationLevel::Debug;
        const auto pipeline = Pipeline::ConsumeCore(encoded.bytes, options);
        REQUIRE(pipeline);
        REQUIRE(pipeline.llvm);
        REQUIRE(pipeline.core_prep);
        REQUIRE(pipeline.core_prep->functions.size() == 1U);
        REQUIRE(EveryBlockReachesReturn(pipeline.core_prep->functions.front()));

        constexpr std::string_view kSymbol = "Loops.Evaluate.1";
        Llvm::JitSession session;
        const auto rejected = session.AddModule(pipeline.llvm->bitcode,
                                                "loop-execution",
                                                kSymbol,
                                                Core::Type::int64());
        REQUIRE_FALSE(rejected);
        const auto result = session.InvokeScalar(kSymbol, Core::Type::int64());
        REQUIRE(result);
        return std::get<std::int64_t>(result.value->payload);
    }

    void
    CheckBothPipelines(const Core::Module &module, std::int64_t expected)
    {
        CHECK(Run(module, false) == expected);
        CHECK(Run(module, true) == expected);
    }
} // namespace

TEST_CASE("for-loop runs its update once per iteration and then re-tests",
          "[llvm][loop][execution]")
{
    for (std::int64_t limit = 0; limit < kLimits; ++limit)
    {
        std::int64_t expected{};
        for (std::int64_t index = 0; index < limit; ++index)
            expected += index;
        CAPTURE(limit);
        CheckBothPipelines(
            LoopModule(Core::Statement::For(
                Compare(Core::Primitive::LessThan, kIndex, limit),
                { Add(kTotal, Variable(kIndex)) },
                { Increment(kIndex) })),
            expected);
    }
}

TEST_CASE("for-loop continue still updates and break skips the update",
          "[llvm][loop][execution]")
{
    for (std::int64_t limit = 0; limit < kLimits; ++limit)
    {
        std::int64_t expected{};
        for (std::int64_t index = 0; index < limit; ++index)
        {
            if (index == 2)
                continue;
            if (index == 9)
                break;
            expected += index;
        }
        CAPTURE(limit);
        CheckBothPipelines(
            LoopModule(Core::Statement::For(
                Compare(Core::Primitive::LessThan, kIndex, limit),
                { When(kIndex, 2, Core::Statement::Continue()),
                  When(kIndex, 9, Core::Statement::Break()),
                  Add(kTotal, Variable(kIndex)) },
                { Increment(kIndex) })),
            expected);
    }
}

TEST_CASE("for-loop observes the index value left by break and by exhaustion",
          "[llvm][loop][execution]")
{
    // Returning the induction variable distinguishes "update ran after the
    // last body" from "update skipped", which a sum of indices cannot.
    for (std::int64_t limit = 0; limit < kLimits; ++limit)
    {
        std::int64_t index = 0;
        for (; index < limit; ++index)
            if (index == 5)
                break;
        auto module = LoopModule(Core::Statement::For(
            Compare(Core::Primitive::LessThan, kIndex, limit),
            { When(kIndex, 5, Core::Statement::Break()) },
            { Increment(kIndex) }));
        module.functions.front().body.back()
            = Core::Statement::Return(Variable(kIndex));
        CAPTURE(limit);
        CheckBothPipelines(module, index);
    }
}

TEST_CASE("for-loop accepts a numeric condition and an empty update",
          "[llvm][loop][execution]")
{
    std::int64_t expected{};
    for (std::int64_t index = 0; 3 - index != 0; ++index)
        expected += index;
    CheckBothPipelines(
        LoopModule(Core::Statement::For(
            Core::Expression::InvokePrimitive(Core::Primitive::Subtract,
                                              { Integer(3), Variable(kIndex) },
                                              Core::Type::int64()),
            { Add(kTotal, Variable(kIndex)) },
            { Increment(kIndex) })),
        expected);

    expected = 0;
    for (std::int64_t index = 0; index < 4;)
    {
        expected += index;
        ++index;
    }
    CheckBothPipelines(LoopModule(Core::Statement::For(
                           Compare(Core::Primitive::LessThan, kIndex, 4),
                           { Add(kTotal, Variable(kIndex)), Increment(kIndex) },
                           {})),
                       expected);
}

TEST_CASE("while-loop does not re-run statements that precede it",
          "[llvm][loop][execution]")
{
    for (std::int64_t limit = 0; limit < kLimits; ++limit)
    {
        std::int64_t expected{};
        std::int64_t index{};
        while (index < limit)
        {
            if (index == 1)
            {
                ++index;
                continue;
            }
            if (index == 7)
                break;
            expected += index;
            ++index;
        }
        CAPTURE(limit);
        CheckBothPipelines(
            LoopModule(Core::Statement::While(
                Compare(Core::Primitive::LessThan, kIndex, limit),
                { Core::Statement::If(
                      Compare(Core::Primitive::Equal, kIndex, 1),
                      { Increment(kIndex), Core::Statement::Continue() },
                      {}),
                  When(kIndex, 7, Core::Statement::Break()),
                  Add(kTotal, Variable(kIndex)),
                  Increment(kIndex) })),
            expected);
    }
}

TEST_CASE("do-while runs its body before the first test and on continue",
          "[llvm][loop][execution]")
{
    for (std::int64_t limit = 0; limit < kLimits; ++limit)
    {
        std::int64_t expected{};
        std::int64_t index{};
        do
        {
            ++index;
            if (index == 2)
                continue;
            if (index == 5)
                break;
            expected += index;
        } while (index < limit);
        CAPTURE(limit);
        CheckBothPipelines(
            LoopModule(Core::Statement::DoWhile(
                { Increment(kIndex),
                  When(kIndex, 2, Core::Statement::Continue()),
                  When(kIndex, 5, Core::Statement::Break()),
                  Add(kTotal, Variable(kIndex)) },
                Compare(Core::Primitive::LessThan, kIndex, limit))),
            expected);
    }
}

TEST_CASE("nested loops transfer only within their own loop",
          "[llvm][loop][execution]")
{
    for (std::int64_t limit = 0; limit < 6; ++limit)
    {
        std::int64_t expected{};
        for (std::int64_t index = 0; index < limit; ++index)
        {
            if (index == 3)
                continue;
            for (std::int64_t inner = 0; inner < 4; ++inner)
            {
                if (inner == 1)
                    continue;
                if (inner == 3)
                    break;
                expected += index + inner;
            }
            std::int64_t tail{};
            while (tail < 2)
            {
                expected += 100;
                ++tail;
            }
        }
        // The inner counters reuse `inner`; rebinding per outer iteration
        // is expressed as an assignment so each binding is defined once.
        auto reset
            = Core::Statement::Assign({ kInner, Spelling(kInner) }, Integer(0));
        auto module = LoopModule(Core::Statement::For(
            Compare(Core::Primitive::LessThan, kIndex, limit),
            { When(kIndex, 3, Core::Statement::Continue()),
              reset,
              Core::Statement::For(
                  Compare(Core::Primitive::LessThan, kInner, 4),
                  { When(kInner, 1, Core::Statement::Continue()),
                    When(kInner, 3, Core::Statement::Break()),
                    Add(kTotal, Variable(kIndex)),
                    Add(kTotal, Variable(kInner)) },
                  { Increment(kInner) }),
              reset,
              Core::Statement::While(
                  Compare(Core::Primitive::LessThan, kInner, 2),
                  { Add(kTotal, Integer(100)), Increment(kInner) }) },
            { Increment(kIndex) }));
        auto &body = module.functions.front().body;
        body.insert(body.begin() + 2, Declare(kInner));
        CAPTURE(limit);
        CheckBothPipelines(module, expected);
    }
}

TEST_CASE("return inside a loop leaves the function with the current value",
          "[llvm][loop][execution]")
{
    // for (index = 0; index < limit; index++) {
    //     if (index == 4) { return total + 1000; }
    //     total = total + index;
    // }
    // return total;
    for (std::int64_t limit = 0; limit < kLimits; ++limit)
    {
        const auto host = [limit]() -> std::int64_t {
            std::int64_t total{};
            for (std::int64_t index = 0; index < limit; ++index)
            {
                if (index == 4)
                    return total + 1000;
                total += index;
            }
            return total;
        };
        CAPTURE(limit);
        CheckBothPipelines(
            LoopModule(Core::Statement::For(
                Compare(Core::Primitive::LessThan, kIndex, limit),
                { Core::Statement::If(
                      Compare(Core::Primitive::Equal, kIndex, 4),
                      { Core::Statement::Return(
                          Core::Expression::InvokePrimitive(
                              Core::Primitive::Add,
                              { Variable(kTotal), Integer(1000) },
                              Core::Type::int64())) },
                      {}),
                  Add(kTotal, Variable(kIndex)) },
                { Increment(kIndex) })),
            host());
    }
}

TEST_CASE("return from a nested loop skips every enclosing update",
          "[llvm][loop][execution]")
{
    // The inner loop returns from inside a while that sits in a for body;
    // neither the inner increment nor the outer update may run afterwards.
    for (std::int64_t limit = 0; limit < 7; ++limit)
    {
        const auto host = [limit]() -> std::int64_t {
            std::int64_t total{};
            for (std::int64_t index = 0; index < limit; ++index)
            {
                std::int64_t inner{};
                while (inner < 3)
                {
                    if (index == 2 && inner == 1)
                        return total * 10 + index;
                    total += inner;
                    ++inner;
                }
            }
            return total;
        };
        auto reset
            = Core::Statement::Assign({ kInner, Spelling(kInner) }, Integer(0));
        auto module = LoopModule(Core::Statement::For(
            Compare(Core::Primitive::LessThan, kIndex, limit),
            { reset,
              Core::Statement::While(
                  Compare(Core::Primitive::LessThan, kInner, 3),
                  { Core::Statement::If(
                        Compare(Core::Primitive::Equal, kIndex, 2),
                        { When(kInner,
                               1,
                               Core::Statement::Return(
                                   Core::Expression::InvokePrimitive(
                                       Core::Primitive::Add,
                                       { Core::Expression::InvokePrimitive(
                                             Core::Primitive::Multiply,
                                             { Variable(kTotal), Integer(10) },
                                             Core::Type::int64()),
                                         Variable(kIndex) },
                                       Core::Type::int64()))) },
                        {}),
                    Add(kTotal, Variable(kInner)),
                    Increment(kInner) }) },
            { Increment(kIndex) }));
        auto &body = module.functions.front().body;
        body.insert(body.begin() + 2, Declare(kInner));
        CAPTURE(limit);
        CheckBothPipelines(module, host());
    }
}

TEST_CASE("do-while returns from its body before the trailing test",
          "[llvm][loop][execution]")
{
    for (std::int64_t limit = 0; limit < kLimits; ++limit)
    {
        const auto host = [limit]() -> std::int64_t {
            std::int64_t total{};
            std::int64_t index{};
            do
            {
                ++index;
                if (index == 6)
                    return -total;
                total += index;
            } while (index < limit);
            return total;
        };
        CAPTURE(limit);
        CheckBothPipelines(
            LoopModule(Core::Statement::DoWhile(
                { Increment(kIndex),
                  When(
                      kIndex,
                      6,
                      Core::Statement::Return(Core::Expression::InvokePrimitive(
                          Core::Primitive::Negate,
                          { Variable(kTotal) },
                          Core::Type::int64()))),
                  Add(kTotal, Variable(kIndex)) },
                Compare(Core::Primitive::LessThan, kIndex, limit))),
            host());
    }
}
