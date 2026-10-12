// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstdint>
#include <initializer_list>
#include <optional>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Xpp/ControlFlow.hpp"

namespace
{
    namespace Analysis = Progmasoft::Tala::Analysis;
    namespace Xpp = tala::xpp;

    [[nodiscard]] auto
    Return() -> Xpp::Terminator
    {
        Xpp::Terminator value;
        value.kind = Xpp::Terminator::Kind::Return;
        return value;
    }

    [[nodiscard]] auto
    Jump(const Xpp::BlockId target) -> Xpp::Terminator
    {
        Xpp::Terminator value;
        value.kind = Xpp::Terminator::Kind::Jump;
        value.true_target = target;
        return value;
    }

    [[nodiscard]] auto
    Branch(const Xpp::BlockId yes, const Xpp::BlockId no) -> Xpp::Terminator
    {
        Xpp::Terminator value;
        value.kind = Xpp::Terminator::Kind::Branch;
        value.true_target = yes;
        value.false_target = no;
        return value;
    }

    [[nodiscard]] auto
    Block(const Xpp::BlockId id, Xpp::Terminator terminator) -> Xpp::Block
    {
        return { id, {}, std::move(terminator) };
    }

    [[nodiscard]] auto
    Function(std::initializer_list<Xpp::Block> blocks,
             const Xpp::BlockId entry = 0U) -> Xpp::Function
    {
        Xpp::Function function;
        function.symbol = { 1U, U"ControlFlow" };
        function.entry = entry;
        function.blocks = blocks;
        return function;
    }

    [[nodiscard]] auto
    Facts(const Analysis::DominanceResult &result, const Xpp::BlockId block)
        -> const Analysis::DominanceBlockFacts &
    {
        const auto *facts = Analysis::FactsFor(result, block);
        REQUIRE(facts != nullptr);
        return *facts;
    }
} // namespace

TEST_CASE("Xpp control adapter preserves a linear function")
{
    const auto result = Xpp::AnalyzeControlStructure(Function(
        { Block(0U, Jump(1U)), Block(1U, Jump(2U)), Block(2U, Return()) }));
    CHECK(result.validForTransformation());
    CHECK(result.controlFlow.reversePostorder
          == std::vector<Xpp::BlockId>{ 0U, 1U, 2U });
    CHECK(Facts(result, 2U).dominators
          == std::vector<Xpp::BlockId>{ 0U, 1U, 2U });
    CHECK(Facts(result, 0U).immediatePostDominator
          == std::optional<Xpp::BlockId>{ 1U });
}

TEST_CASE("Xpp control adapter maps true and false branch edges")
{
    const auto result
        = Xpp::AnalyzeControlStructure(Function({ Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Jump(3U)),
                                                  Block(2U, Jump(3U)),
                                                  Block(3U, Return()) }));
    CHECK(result.controlFlow.preorder
          == std::vector<Xpp::BlockId>{ 0U, 1U, 3U, 2U });
    CHECK(Facts(result, 1U).dominanceFrontier
          == std::vector<Xpp::BlockId>{ 3U });
    CHECK(Facts(result, 2U).dominanceFrontier
          == std::vector<Xpp::BlockId>{ 3U });
}

TEST_CASE("Xpp return and unreachable terminators are exits")
{
    auto unreachable = Xpp::Terminator{};
    unreachable.kind = Xpp::Terminator::Kind::Unreachable;
    const auto result
        = Xpp::AnalyzeControlStructure(Function({ Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Return()),
                                                  Block(2U, unreachable) }));
    CHECK(result.exits == std::vector<Xpp::BlockId>{ 1U, 2U });
    CHECK(result.hasPostDominance);
}

TEST_CASE("Xpp loop structure reaches native loop analysis")
{
    const auto result
        = Xpp::AnalyzeControlStructure(Function({ Block(0U, Jump(1U)),
                                                  Block(1U, Branch(2U, 4U)),
                                                  Block(2U, Jump(3U)),
                                                  Block(3U, Jump(1U)),
                                                  Block(4U, Return()) }));
    REQUIRE(result.naturalLoops.size() == 1U);
    CHECK(result.naturalLoops.front().header == 1U);
    CHECK(result.naturalLoops.front().latch == 3U);
    CHECK(result.naturalLoops.front().members
          == std::vector<Xpp::BlockId>{ 1U, 2U, 3U });
    CHECK(result.naturalLoops.front().exits == std::vector<Xpp::BlockId>{ 4U });
}

TEST_CASE("Xpp irreducible graph is retained as a capability boundary")
{
    const auto result
        = Xpp::AnalyzeControlStructure(Function({ Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Branch(2U, 3U)),
                                                  Block(2U, Branch(1U, 3U)),
                                                  Block(3U, Return()) }));
    REQUIRE(result.irreducibleRegions.size() == 1U);
    CHECK(result.irreducibleRegions.front().members
          == std::vector<Xpp::BlockId>{ 1U, 2U });
    CHECK(result.irreducibleRegions.front().entries
          == std::vector<Xpp::BlockId>{ 1U, 2U });
}

TEST_CASE("Xpp missing jump target invalidates transformation facts")
{
    const auto result
        = Xpp::AnalyzeControlStructure(Function({ Block(0U, Jump(99U)) }));
    CHECK_FALSE(result.validForTransformation());
    REQUIRE(result.controlFlow.issues.size() == 1U);
    CHECK(result.controlFlow.issues.front().kind
          == Analysis::ControlFlowIssueKind::MissingTarget);
    CHECK(result.controlFlow.issues.front().target == 99U);
}

TEST_CASE("Xpp missing entry invalidates transformation facts")
{
    const auto result
        = Xpp::AnalyzeControlStructure(Function({ Block(1U, Return()) }, 0U));
    CHECK_FALSE(result.validForTransformation());
    CHECK(result.controlFlow.preorder.empty());
    CHECK_FALSE(Facts(result, 1U).reachable);
}

TEST_CASE("Xpp unreachable blocks do not alter loop structure")
{
    const auto result
        = Xpp::AnalyzeControlStructure(Function({ Block(0U, Return()),
                                                  Block(10U, Branch(11U, 12U)),
                                                  Block(11U, Jump(12U)),
                                                  Block(12U, Jump(11U)) }));
    CHECK(result.naturalLoops.empty());
    CHECK(result.irreducibleRegions.empty());
    CHECK_FALSE(Facts(result, 11U).reachable);
}

TEST_CASE("Xpp block presentation does not change structural facts")
{
    const auto ordered
        = Xpp::AnalyzeControlStructure(Function({ Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Jump(3U)),
                                                  Block(2U, Jump(3U)),
                                                  Block(3U, Return()) }));
    const auto shuffled
        = Xpp::AnalyzeControlStructure(Function({ Block(3U, Return()),
                                                  Block(2U, Jump(3U)),
                                                  Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Jump(3U)) }));
    CHECK(shuffled.facts == ordered.facts);
    CHECK(shuffled.naturalLoops == ordered.naturalLoops);
    CHECK(shuffled.irreducibleRegions == ordered.irreducibleRegions);
}
