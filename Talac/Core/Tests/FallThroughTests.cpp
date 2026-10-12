// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"

// How a function ends when its body ends.
//
// A function without a result may end without a return: reaching the end of
// its body returns. A function with a result returns on every path, so the
// end of its body is never reached and the block that stands there is marked
// unreachable instead of being given a value nobody wrote. The adapter used
// to mark both the same way, and a native program whose `Main` ended without
// a return stopped where it should have ended. The Haskell adapter has the
// same cases in `FallThroughTests.hs`.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Prepared = tala::core;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Nothing() -> Core::Expression
    {
        return Core::Expression::Constant(std::monostate{}, Core::Type::unit());
    }

    [[nodiscard]] auto
    Flag() -> Core::Expression
    {
        return Core::Expression::Variable({ 20U, U"flag" },
                                          Core::Type::boolean());
    }

    [[nodiscard]] auto
    Bind(std::uint64_t id, std::int64_t value) -> Core::Statement
    {
        return Core::Statement::Bind(
            { { id, U"local" }, Core::Type::int64(), false, Integer(value) });
    }

    // `if (flag) { return; }`
    [[nodiscard]] auto
    ReturnWhen() -> Core::Statement
    {
        return Core::Statement::If(Flag(),
                                   { Core::Statement::Return(Nothing()) },
                                   {});
    }

    // `if (flag) { return 1; } else { return 2; }`
    [[nodiscard]] auto
    BothReturn(Core::Expression condition = Flag()) -> Core::Statement
    {
        return Core::Statement::If(std::move(condition),
                                   { Core::Statement::Return(Integer(1)) },
                                   { Core::Statement::Return(Integer(2)) });
    }

    [[nodiscard]] auto
    Module(Core::Type result, std::vector<Core::Statement> body) -> Core::Module
    {
        return { { U"FallThrough" },
                 { Core::Function{
                     { 1U, U"Evaluate" },
                     { { { 20U, U"flag" }, Core::Type::boolean() } },
                     std::move(result),
                     std::move(body),
                 } } };
    }

    [[nodiscard]] auto
    ReturnsNothing(const Prepared::Terminator &terminator) -> bool
    {
        return terminator.kind == Prepared::Terminator::Kind::Return
               && terminator.value.type.kind == Prepared::Type::Kind::Unit;
    }

    struct Ends final
    {
        std::size_t returningNothing{};
        std::size_t unreachable{};
        std::size_t blocks{};
    };

    [[nodiscard]] auto
    EndsOf(const Prepared::Function &function) -> Ends
    {
        Ends ends;
        for (const auto &block : function.blocks)
        {
            ++ends.blocks;
            if (ReturnsNothing(block.terminator))
                ++ends.returningNothing;
            if (block.terminator.kind
                == Prepared::Terminator::Kind::Unreachable)
                ++ends.unreachable;
        }
        return ends;
    }

    [[nodiscard]] auto
    Prepare(Core::Type result, std::vector<Core::Statement> body)
        -> Prepared::CorePrepModule
    {
        const auto module = Module(std::move(result), std::move(body));
        REQUIRE(Core::Verify(module).empty());
        auto prepared = Core::CorePrep::Prepare(module);
        REQUIRE(Prepared::verify(prepared).empty());
        return prepared;
    }
} // namespace

TEST_CASE("an empty body without a result returns")
{
    const auto prepared = Prepare(Core::Type::unit(), {});
    const auto ends = EndsOf(prepared.functions.front());
    CHECK(ends.blocks == 1U);
    CHECK(ends.returningNothing == 1U);
    CHECK(ends.unreachable == 0U);
}

TEST_CASE("a body without a result that ends in a binding returns")
{
    const auto prepared = Prepare(Core::Type::unit(), { Bind(2U, 1) });
    const auto ends = EndsOf(prepared.functions.front());
    CHECK(ends.blocks == 1U);
    CHECK(ends.returningNothing == 1U);
    CHECK(ends.unreachable == 0U);
}

TEST_CASE("the block after a conditional return returns")
{
    // One return was written; the other is the end of the body.
    const auto prepared = Prepare(Core::Type::unit(), { ReturnWhen() });
    const auto ends = EndsOf(prepared.functions.front());
    CHECK(ends.returningNothing == 2U);
    CHECK(ends.unreachable == 0U);
}

TEST_CASE("the block after a loop returns")
{
    const auto prepared
        = Prepare(Core::Type::unit(),
                  { Core::Statement::While(Flag(), { Bind(3U, 1) }) });
    const auto ends = EndsOf(prepared.functions.front());
    // The end of the loop body goes back to the loop; only the end of the
    // function's own body returns.
    CHECK(ends.returningNothing == 1U);
    CHECK(ends.unreachable == 0U);
}

TEST_CASE("the block after a loop that is left early returns")
{
    const auto prepared = Prepare(
        Core::Type::unit(),
        { Core::Statement::While(Flag(), { Core::Statement::Break() }) });
    const auto ends = EndsOf(prepared.functions.front());
    CHECK(ends.returningNothing == 1U);
    CHECK(ends.unreachable == 0U);
}

TEST_CASE("statements after a conditional return are followed by a return")
{
    const auto prepared
        = Prepare(Core::Type::unit(), { ReturnWhen(), Bind(2U, 1) });
    const auto ends = EndsOf(prepared.functions.front());
    CHECK(ends.returningNothing == 2U);
    CHECK(ends.unreachable == 0U);
}

TEST_CASE("an explicit return without a value is kept as written")
{
    const auto prepared
        = Prepare(Core::Type::unit(), { Core::Statement::Return(Nothing()) });
    const auto ends = EndsOf(prepared.functions.front());
    CHECK(ends.blocks == 1U);
    CHECK(ends.returningNothing == 1U);
}

TEST_CASE("a body with a result is not given a value at its end")
{
    const auto prepared = Prepare(Core::Type::int64(), { BothReturn() });
    const auto ends = EndsOf(prepared.functions.front());
    CHECK(ends.returningNothing == 0U);
    // Both arms return, so the block after them is never entered.
    CHECK(ends.unreachable == 1U);
}

TEST_CASE("a closure without a result returns at the end of its body")
{
    const auto callable = Core::Type::function({}, Core::Type::unit());
    const auto prepared = Prepare(
        Core::Type::unit(),
        { Core::Statement::Bind({ { 6U, U"act" },
                                  callable,
                                  false,
                                  Core::Expression::Closure({},
                                                            {},
                                                            Core::Type::unit(),
                                                            { Bind(7U, 1) },
                                                            callable) }) });
    REQUIRE(prepared.functions.size() == 2U);
    for (const auto &function : prepared.functions)
    {
        const auto ends = EndsOf(function);
        CHECK(ends.returningNothing == 1U);
        CHECK(ends.unreachable == 0U);
    }
}

TEST_CASE("a closure with a result is not given a value at its end")
{
    const auto callable = Core::Type::function({}, Core::Type::int64());
    const auto prepared = Prepare(
        Core::Type::unit(),
        { Core::Statement::Bind(
            { { 6U, U"pick" },
              callable,
              false,
              Core::Expression::Closure({},
                                        {},
                                        Core::Type::int64(),
                                        { BothReturn(Core::Expression::Constant(
                                            true,
                                            Core::Type::boolean())) },
                                        callable) }) });
    REQUIRE(prepared.functions.size() == 2U);
    const auto lifted = EndsOf(prepared.functions.back());
    CHECK(lifted.returningNothing == 0U);
    CHECK(lifted.unreachable == 1U);
}
