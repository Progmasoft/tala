// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstdint>
#include <initializer_list>
#include <optional>
#include <ranges>
#include <vector>

#include "Progmasoft/Tala/Analysis/Dominance.hpp"

namespace
{
    namespace Analysis = Progmasoft::Tala::Analysis;
    using Id = Analysis::ControlFlowBlockId;

    [[nodiscard]] auto
    Block(const Id id, std::initializer_list<Id> successors = {})
        -> Analysis::ControlFlowBlock
    {
        return { id, successors };
    }

    [[nodiscard]] auto
    Graph(std::initializer_list<Analysis::ControlFlowBlock> blocks,
          const Id entry = 0U) -> Analysis::ControlFlowGraph
    {
        return { entry, blocks };
    }

    [[nodiscard]] auto
    Analyze(std::initializer_list<Analysis::ControlFlowBlock> blocks,
            const Id entry = 0U) -> Analysis::DominanceResult
    {
        return Analysis::AnalyzeDominance(Graph(blocks, entry));
    }

    [[nodiscard]] auto
    Facts(const Analysis::DominanceResult &result, const Id block)
        -> const Analysis::DominanceBlockFacts &
    {
        const auto *facts = Analysis::FactsFor(result, block);
        REQUIRE(facts != nullptr);
        return *facts;
    }

    [[nodiscard]] auto
    Ids(std::initializer_list<Id> values) -> std::vector<Id>
    {
        return values;
    }
} // namespace

TEST_CASE("dominance accepts a singleton function")
{
    const auto result = Analyze({ Block(0U) });
    CHECK(result.validForTransformation());
    CHECK(result.exits == Ids({ 0U }));
    CHECK(result.hasPostDominance);
    CHECK(Facts(result, 0U).dominators == Ids({ 0U }));
    CHECK(Facts(result, 0U).postDominators == Ids({ 0U }));
    CHECK_FALSE(Facts(result, 0U).immediateDominator.has_value());
    CHECK_FALSE(Facts(result, 0U).immediatePostDominator.has_value());
}

TEST_CASE("a linear chain has exact dominator prefixes")
{
    const auto result = Analyze(
        { Block(0U, { 1U }), Block(1U, { 2U }), Block(2U, { 3U }), Block(3U) });
    CHECK(Facts(result, 0U).dominators == Ids({ 0U }));
    CHECK(Facts(result, 1U).dominators == Ids({ 0U, 1U }));
    CHECK(Facts(result, 2U).dominators == Ids({ 0U, 1U, 2U }));
    CHECK(Facts(result, 3U).dominators == Ids({ 0U, 1U, 2U, 3U }));
}

TEST_CASE("a linear chain has exact immediate dominators")
{
    const auto result = Analyze(
        { Block(0U, { 1U }), Block(1U, { 2U }), Block(2U, { 3U }), Block(3U) });
    CHECK(Facts(result, 1U).immediateDominator == std::optional<Id>{ 0U });
    CHECK(Facts(result, 2U).immediateDominator == std::optional<Id>{ 1U });
    CHECK(Facts(result, 3U).immediateDominator == std::optional<Id>{ 2U });
}

TEST_CASE("a linear chain has reverse post-dominator prefixes")
{
    const auto result = Analyze(
        { Block(0U, { 1U }), Block(1U, { 2U }), Block(2U, { 3U }), Block(3U) });
    CHECK(Facts(result, 3U).postDominators == Ids({ 3U }));
    CHECK(Facts(result, 2U).postDominators == Ids({ 2U, 3U }));
    CHECK(Facts(result, 1U).postDominators == Ids({ 1U, 2U, 3U }));
    CHECK(Facts(result, 0U).postDominators == Ids({ 0U, 1U, 2U, 3U }));
}

TEST_CASE("a linear chain has exact immediate post-dominators")
{
    const auto result = Analyze(
        { Block(0U, { 1U }), Block(1U, { 2U }), Block(2U, { 3U }), Block(3U) });
    CHECK(Facts(result, 0U).immediatePostDominator == std::optional<Id>{ 1U });
    CHECK(Facts(result, 1U).immediatePostDominator == std::optional<Id>{ 2U });
    CHECK(Facts(result, 2U).immediatePostDominator == std::optional<Id>{ 3U });
}

TEST_CASE("dominance queries distinguish strict and reflexive relations")
{
    const auto result = Analyze({ Block(0U, { 1U }), Block(1U) });
    CHECK(Analysis::Dominates(result, 0U, 0U));
    CHECK(Analysis::Dominates(result, 0U, 1U));
    CHECK_FALSE(Analysis::StrictlyDominates(result, 0U, 0U));
    CHECK(Analysis::StrictlyDominates(result, 0U, 1U));
}

TEST_CASE("post-dominance queries distinguish strict and reflexive relations")
{
    const auto result = Analyze({ Block(0U, { 1U }), Block(1U) });
    CHECK(Analysis::PostDominates(result, 1U, 1U));
    CHECK(Analysis::PostDominates(result, 1U, 0U));
    CHECK_FALSE(Analysis::StrictlyPostDominates(result, 1U, 1U));
    CHECK(Analysis::StrictlyPostDominates(result, 1U, 0U));
}

TEST_CASE("diamond arms do not dominate their join")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 3U }),
                                  Block(2U, { 3U }),
                                  Block(3U) });
    CHECK(Facts(result, 3U).dominators == Ids({ 0U, 3U }));
    CHECK(Facts(result, 3U).immediateDominator == std::optional<Id>{ 0U });
    CHECK_FALSE(Analysis::Dominates(result, 1U, 3U));
    CHECK_FALSE(Analysis::Dominates(result, 2U, 3U));
}

TEST_CASE("diamond join post-dominates both arms")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 3U }),
                                  Block(2U, { 3U }),
                                  Block(3U) });
    CHECK(Analysis::PostDominates(result, 3U, 0U));
    CHECK(Analysis::PostDominates(result, 3U, 1U));
    CHECK(Analysis::PostDominates(result, 3U, 2U));
    CHECK(Facts(result, 0U).immediatePostDominator == std::optional<Id>{ 3U });
}

TEST_CASE("diamond arms place the join in their dominance frontier")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 3U }),
                                  Block(2U, { 3U }),
                                  Block(3U) });
    CHECK(Facts(result, 0U).dominanceFrontier.empty());
    CHECK(Facts(result, 1U).dominanceFrontier == Ids({ 3U }));
    CHECK(Facts(result, 2U).dominanceFrontier == Ids({ 3U }));
    CHECK(Facts(result, 3U).dominanceFrontier.empty());
}

TEST_CASE("diamond arms expose the branch in their post-dominance frontier")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 3U }),
                                  Block(2U, { 3U }),
                                  Block(3U) });
    CHECK(Facts(result, 1U).postDominanceFrontier == Ids({ 0U }));
    CHECK(Facts(result, 2U).postDominanceFrontier == Ids({ 0U }));
}

TEST_CASE("nested diamonds compute independent frontiers")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 3U }),
                                  Block(2U, { 3U }),
                                  Block(3U, { 4U, 5U }),
                                  Block(4U, { 6U }),
                                  Block(5U, { 6U }),
                                  Block(6U) });
    CHECK(Facts(result, 1U).dominanceFrontier == Ids({ 3U }));
    CHECK(Facts(result, 2U).dominanceFrontier == Ids({ 3U }));
    CHECK(Facts(result, 4U).dominanceFrontier == Ids({ 6U }));
    CHECK(Facts(result, 5U).dominanceFrontier == Ids({ 6U }));
}

TEST_CASE("multiple exits retain common post-dominators only")
{
    const auto result
        = Analyze({ Block(0U, { 1U, 2U }), Block(1U), Block(2U) });
    CHECK(result.exits == Ids({ 1U, 2U }));
    CHECK(result.hasPostDominance);
    CHECK(Facts(result, 0U).postDominators == Ids({ 0U }));
    CHECK_FALSE(Facts(result, 0U).immediatePostDominator.has_value());
}

TEST_CASE("one arm can have a private suffix before a distinct exit")
{
    const auto result = Analyze(
        { Block(0U, { 1U, 2U }), Block(1U, { 3U }), Block(2U), Block(3U) });
    CHECK(Facts(result, 1U).postDominators == Ids({ 1U, 3U }));
    CHECK(Facts(result, 1U).immediatePostDominator == std::optional<Id>{ 3U });
    CHECK(Facts(result, 0U).postDominators == Ids({ 0U }));
}

TEST_CASE("an infinite function reports unavailable post-dominance")
{
    const auto result = Analyze({ Block(0U, { 1U }), Block(1U, { 0U }) });
    CHECK(result.exits.empty());
    CHECK_FALSE(result.hasPostDominance);
    CHECK(Facts(result, 0U).postDominators.empty());
    CHECK(Facts(result, 1U).postDominators.empty());
    CHECK_FALSE(Analysis::PostDominates(result, 0U, 0U));
}

TEST_CASE("unreachable exits do not create post-dominance roots")
{
    const auto result = Analyze({ Block(0U, { 0U }), Block(9U) });
    CHECK(result.exits.empty());
    CHECK_FALSE(result.hasPostDominance);
    CHECK_FALSE(Facts(result, 9U).reachable);
}

TEST_CASE(
    "a returning arm beside a closed infinite arm has no post-dominance proof")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U),
                                  Block(2U, { 3U }),
                                  Block(3U, { 2U }) });
    CHECK(result.exits == Ids({ 1U }));
    CHECK_FALSE(result.hasPostDominance);
    CHECK(Facts(result, 0U).postDominators.empty());
    CHECK(Facts(result, 1U).postDominators.empty());
    CHECK(Facts(result, 2U).postDominators.empty());
    CHECK_FALSE(Analysis::PostDominates(result, 1U, 0U));
}

TEST_CASE("unreachable blocks have no fabricated structural facts")
{
    const auto result = Analyze({ Block(0U), Block(4U, { 5U }), Block(5U) });
    CHECK_FALSE(Facts(result, 4U).reachable);
    CHECK(Facts(result, 4U).dominators.empty());
    CHECK(Facts(result, 4U).postDominators.empty());
    CHECK(Facts(result, 4U).dominanceFrontier.empty());
    CHECK(Facts(result, 4U).loopDepth == 0U);
}

TEST_CASE("missing entry preserves malformed CFG diagnostics")
{
    const auto result = Analyze({ Block(1U) }, 0U);
    CHECK_FALSE(result.validForTransformation());
    CHECK(result.controlFlow.preorder.empty());
    CHECK_FALSE(result.hasPostDominance);
    CHECK_FALSE(Facts(result, 1U).reachable);
}

TEST_CASE("missing targets never enter a dominance set")
{
    const auto result = Analyze({ Block(0U, { 1U, 99U }), Block(1U) });
    CHECK_FALSE(result.validForTransformation());
    CHECK(Facts(result, 1U).dominators == Ids({ 0U, 1U }));
    CHECK(Analysis::FactsFor(result, 99U) == nullptr);
}

TEST_CASE("a self loop is one natural loop")
{
    const auto result = Analyze({ Block(0U, { 0U, 1U }), Block(1U) });
    REQUIRE(result.naturalLoops.size() == 1U);
    CHECK(result.naturalLoops.front().header == 0U);
    CHECK(result.naturalLoops.front().latch == 0U);
    CHECK(result.naturalLoops.front().members == Ids({ 0U }));
    CHECK(result.naturalLoops.front().exits == Ids({ 1U }));
    CHECK(Facts(result, 0U).loopDepth == 1U);
}

TEST_CASE("a while-shaped cycle produces header latch members and exit")
{
    const auto result = Analyze({ Block(0U, { 1U }),
                                  Block(1U, { 2U, 4U }),
                                  Block(2U, { 3U }),
                                  Block(3U, { 1U }),
                                  Block(4U) });
    REQUIRE(result.naturalLoops.size() == 1U);
    const auto &loop = result.naturalLoops.front();
    CHECK(loop.header == 1U);
    CHECK(loop.latch == 3U);
    CHECK(loop.members == Ids({ 1U, 2U, 3U }));
    CHECK(loop.exits == Ids({ 4U }));
}

TEST_CASE("loop membership is reflected on every contained block")
{
    const auto result = Analyze({ Block(0U, { 1U }),
                                  Block(1U, { 2U, 4U }),
                                  Block(2U, { 3U }),
                                  Block(3U, { 1U }),
                                  Block(4U) });
    CHECK(Facts(result, 0U).loopDepth == 0U);
    CHECK(Facts(result, 1U).loopHeaders == Ids({ 1U }));
    CHECK(Facts(result, 2U).loopHeaders == Ids({ 1U }));
    CHECK(Facts(result, 3U).loopHeaders == Ids({ 1U }));
    CHECK(Facts(result, 4U).loopDepth == 0U);
}

TEST_CASE("a loop with two latches preserves both back edges")
{
    const auto result = Analyze({ Block(0U, { 1U }),
                                  Block(1U, { 2U, 3U }),
                                  Block(2U, { 1U }),
                                  Block(3U, { 1U, 4U }),
                                  Block(4U) });
    REQUIRE(result.naturalLoops.size() == 2U);
    CHECK(result.naturalLoops[0].header == 1U);
    CHECK(result.naturalLoops[0].latch == 2U);
    CHECK(result.naturalLoops[1].header == 1U);
    CHECK(result.naturalLoops[1].latch == 3U);
    CHECK(Facts(result, 1U).loopDepth == 2U);
    CHECK(Facts(result, 1U).loopHeaders == Ids({ 1U }));
}

TEST_CASE("nested natural loops have additive loop depth")
{
    const auto result = Analyze({ Block(0U, { 1U }),
                                  Block(1U, { 2U, 7U }),
                                  Block(2U, { 3U }),
                                  Block(3U, { 4U, 6U }),
                                  Block(4U, { 5U }),
                                  Block(5U, { 3U }),
                                  Block(6U, { 1U }),
                                  Block(7U) });
    REQUIRE(result.naturalLoops.size() == 2U);
    CHECK(Facts(result, 1U).loopDepth == 1U);
    CHECK(Facts(result, 2U).loopDepth == 1U);
    CHECK(Facts(result, 3U).loopDepth == 2U);
    CHECK(Facts(result, 4U).loopDepth == 2U);
    CHECK(Facts(result, 5U).loopDepth == 2U);
    CHECK(Facts(result, 6U).loopDepth == 1U);
}

TEST_CASE("natural loop exit set is unique and sorted")
{
    const auto result = Analyze({ Block(0U, { 1U }),
                                  Block(1U, { 2U, 8U }),
                                  Block(2U, { 3U, 9U, 8U }),
                                  Block(3U, { 1U }),
                                  Block(8U),
                                  Block(9U) });
    REQUIRE(result.naturalLoops.size() == 1U);
    CHECK(result.naturalLoops.front().exits == Ids({ 8U, 9U }));
}

TEST_CASE("a reducible loop is not classified as irreducible")
{
    const auto result = Analyze({ Block(0U, { 1U }),
                                  Block(1U, { 2U, 3U }),
                                  Block(2U, { 1U }),
                                  Block(3U) });
    CHECK(result.irreducibleRegions.empty());
}

TEST_CASE("a two-entry cycle is classified as irreducible")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 2U, 3U }),
                                  Block(2U, { 1U, 3U }),
                                  Block(3U) });
    REQUIRE(result.irreducibleRegions.size() == 1U);
    CHECK(result.irreducibleRegions.front().members == Ids({ 1U, 2U }));
    CHECK(result.irreducibleRegions.front().entries == Ids({ 1U, 2U }));
    CHECK(result.naturalLoops.empty());
}

TEST_CASE("an irreducible region can have a single external predecessor block")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 2U }),
                                  Block(2U, { 1U, 3U }),
                                  Block(3U) });
    REQUIRE(result.irreducibleRegions.size() == 1U);
    CHECK(result.irreducibleRegions.front().entries == Ids({ 1U, 2U }));
}

TEST_CASE("acyclic SCCs are never reported as irreducible")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 3U }),
                                  Block(2U, { 3U }),
                                  Block(3U) });
    CHECK(result.irreducibleRegions.empty());
}

TEST_CASE("an unreachable irreducible cycle is ignored")
{
    const auto result = Analyze({ Block(0U),
                                  Block(10U, { 11U, 12U }),
                                  Block(11U, { 12U }),
                                  Block(12U, { 11U }) });
    CHECK(result.irreducibleRegions.empty());
    CHECK(result.naturalLoops.empty());
}

TEST_CASE("block presentation order cannot change dominance facts")
{
    auto graph = Graph({ Block(0U, { 1U, 2U }),
                         Block(1U, { 3U }),
                         Block(2U, { 3U }),
                         Block(3U, { 4U, 5U }),
                         Block(4U, { 3U }),
                         Block(5U) });
    const auto expected = Analysis::AnalyzeDominance(graph);
    std::ranges::reverse(graph.blocks);
    const auto actual = Analysis::AnalyzeDominance(graph);
    CHECK(actual.facts == expected.facts);
    CHECK(actual.naturalLoops == expected.naturalLoops);
    CHECK(actual.irreducibleRegions == expected.irreducibleRegions);
    CHECK(actual.exits == expected.exits);
}

TEST_CASE("successor declaration order cannot change set-valued facts")
{
    const auto left = Analyze({ Block(0U, { 1U, 2U }),
                                Block(1U, { 3U }),
                                Block(2U, { 3U }),
                                Block(3U) });
    const auto right = Analyze({ Block(0U, { 2U, 1U }),
                                 Block(1U, { 3U }),
                                 Block(2U, { 3U }),
                                 Block(3U) });
    CHECK(left.facts == right.facts);
    CHECK(left.naturalLoops == right.naturalLoops);
}

TEST_CASE("sparse large block identities are not treated as vector indexes")
{
    const auto result = Analyze({ Block(100U, { 900000U }),
                                  Block(900000U, { 4000000000U }),
                                  Block(4000000000U) },
                                100U);
    CHECK(result.validForTransformation());
    CHECK(Facts(result, 4000000000U).dominators
          == Ids({ 100U, 900000U, 4000000000U }));
    CHECK(Facts(result, 100U).immediatePostDominator
          == std::optional<Id>{ 900000U });
}

TEST_CASE("facts lookup returns null for absent identity")
{
    const auto result = Analyze({ Block(0U) });
    CHECK(Analysis::FactsFor(result, 44U) == nullptr);
    CHECK_FALSE(Analysis::Dominates(result, 0U, 44U));
    CHECK_FALSE(Analysis::PostDominates(result, 0U, 44U));
}

TEST_CASE("deep acyclic graphs do not use native recursion")
{
    Analysis::ControlFlowGraph graph;
    graph.entry = 0U;
    constexpr Id kBlockCount = 1024U;
    graph.blocks.reserve(kBlockCount);
    for (Id id = 0U; id < kBlockCount; ++id)
    {
        Analysis::ControlFlowBlock block{ id, {} };
        if (id + 1U < kBlockCount)
            block.successors.push_back(id + 1U);
        graph.blocks.push_back(std::move(block));
    }
    const auto result = Analysis::AnalyzeDominance(graph);
    CHECK(result.validForTransformation());
    CHECK(result.facts.size() == kBlockCount);
    CHECK(Facts(result, kBlockCount - 1U).dominators.size() == kBlockCount);
}

TEST_CASE("deep cycles do not use native recursion")
{
    Analysis::ControlFlowGraph graph;
    graph.entry = 0U;
    constexpr Id kBlockCount = 1024U;
    graph.blocks.reserve(kBlockCount);
    for (Id id = 0U; id < kBlockCount; ++id)
    {
        Analysis::ControlFlowBlock block{ id, { id + 1U } };
        graph.blocks.push_back(std::move(block));
    }
    graph.blocks.back().successors = { 0U };
    const auto result = Analysis::AnalyzeDominance(graph);
    CHECK(result.validForTransformation());
    REQUIRE(result.naturalLoops.size() == 1U);
    CHECK(result.naturalLoops.front().members.size() == kBlockCount);
    CHECK_FALSE(result.hasPostDominance);
}
