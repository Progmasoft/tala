// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstdint>
#include <initializer_list>
#include <ranges>
#include <tuple>
#include <vector>

#include "Progmasoft/Tala/Analysis/ControlDependence.hpp"

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
    Analyze(std::initializer_list<Analysis::ControlFlowBlock> blocks)
        -> Analysis::ControlDependenceResult
    {
        return Analysis::AnalyzeControlDependence({ 0U, blocks });
    }

    [[nodiscard]] auto
    Facts(const Analysis::ControlDependenceResult &result, const Id block)
        -> const Analysis::ControlDependenceBlockFacts &
    {
        const auto *facts = Analysis::ControlDependenceFactsFor(result, block);
        REQUIRE(facts != nullptr);
        return *facts;
    }

    [[nodiscard]] auto
    Ids(std::initializer_list<Id> values) -> std::vector<Id>
    {
        return values;
    }

    [[nodiscard]] auto
    HasEdge(const Analysis::ControlDependenceResult &result,
            const Id controller,
            const Id successor,
            const Id dependent) -> bool
    {
        return std::ranges::any_of(result.edges, [&](const auto &edge) {
            return std::tuple{ edge.controller, edge.successor, edge.dependent }
                   == std::tuple{ controller, successor, dependent };
        });
    }
} // namespace

TEST_CASE("linear control flow has no control dependencies")
{
    const auto result
        = Analyze({ Block(0U, { 1U }), Block(1U, { 2U }), Block(2U) });
    CHECK(result.available);
    CHECK(result.validForTransformation());
    CHECK(result.edges.empty());
    CHECK(Facts(result, 0U).controllers.empty());
    CHECK(Facts(result, 0U).dependents.empty());
}

TEST_CASE("both diamond arms depend on the branch")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 3U }),
                                  Block(2U, { 3U }),
                                  Block(3U) });
    CHECK(HasEdge(result, 0U, 1U, 1U));
    CHECK(HasEdge(result, 0U, 2U, 2U));
    CHECK(Facts(result, 1U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 2U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 0U).dependents == Ids({ 1U, 2U }));
}

TEST_CASE("the diamond join does not depend on either arm")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 3U }),
                                  Block(2U, { 3U }),
                                  Block(3U) });
    CHECK(Facts(result, 3U).controllers.empty());
    CHECK_FALSE(HasEdge(result, 0U, 1U, 3U));
    CHECK_FALSE(HasEdge(result, 0U, 2U, 3U));
}

TEST_CASE("a multi-block arm keeps edge identity")
{
    const auto result = Analyze({ Block(0U, { 1U, 4U }),
                                  Block(1U, { 2U }),
                                  Block(2U, { 3U }),
                                  Block(3U, { 5U }),
                                  Block(4U, { 5U }),
                                  Block(5U) });
    CHECK(HasEdge(result, 0U, 1U, 1U));
    CHECK(HasEdge(result, 0U, 1U, 2U));
    CHECK(HasEdge(result, 0U, 1U, 3U));
    CHECK(HasEdge(result, 0U, 4U, 4U));
    CHECK(Facts(result, 0U).dependents == Ids({ 1U, 2U, 3U, 4U }));
}

TEST_CASE("nested branches accumulate controllers")
{
    const auto result = Analyze({ Block(0U, { 1U, 6U }),
                                  Block(1U, { 2U, 4U }),
                                  Block(2U, { 3U }),
                                  Block(3U, { 5U }),
                                  Block(4U, { 5U }),
                                  Block(5U, { 7U }),
                                  Block(6U, { 7U }),
                                  Block(7U) });
    CHECK(Facts(result, 1U).controllers == Ids({ 0U }));
    // Summaries contain direct dependence. The outer dependence of these
    // blocks is available through controller 1's own controller relation.
    CHECK(Facts(result, 2U).controllers == Ids({ 1U }));
    CHECK(Facts(result, 3U).controllers == Ids({ 1U }));
    CHECK(Facts(result, 4U).controllers == Ids({ 1U }));
    CHECK(Facts(result, 5U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 7U).controllers.empty());
}

TEST_CASE("an early return controls the continuing suffix")
{
    const auto result = Analyze(
        { Block(0U, { 1U, 2U }), Block(1U), Block(2U, { 3U }), Block(3U) });
    CHECK(result.structure.exits == Ids({ 1U, 3U }));
    CHECK(Facts(result, 1U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 2U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 3U).controllers == Ids({ 0U }));
}

TEST_CASE("multiple exits do not invent a virtual block identity")
{
    const auto result
        = Analyze({ Block(0U, { 1U, 2U }), Block(1U), Block(2U) });
    CHECK(result.available);
    CHECK(Facts(result, 1U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 2U).controllers == Ids({ 0U }));
    CHECK(Analysis::ControlDependenceFactsFor(result, 3U) == nullptr);
}

TEST_CASE("an infinite graph marks control dependence unavailable")
{
    const auto result = Analyze({ Block(0U, { 1U }), Block(1U, { 0U }) });
    CHECK_FALSE(result.available);
    CHECK_FALSE(result.validForTransformation());
    CHECK(result.edges.empty());
    CHECK(Facts(result, 0U).controllers.empty());
}

TEST_CASE("a closed infinite branch makes control dependence unavailable")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U),
                                  Block(2U, { 3U }),
                                  Block(3U, { 2U }) });
    CHECK(result.structure.exits == Ids({ 1U }));
    CHECK_FALSE(result.available);
    CHECK_FALSE(result.validForTransformation());
    CHECK(result.edges.empty());
}

TEST_CASE("malformed CFG cannot authorize a transformation")
{
    const auto result = Analyze({ Block(0U, { 1U, 90U }), Block(1U) });
    CHECK(result.available);
    CHECK_FALSE(result.validForTransformation());
    CHECK_FALSE(result.structure.controlFlow.valid());
}

TEST_CASE("unreachable branches have empty dependence facts")
{
    const auto result = Analyze({ Block(0U),
                                  Block(10U, { 11U, 12U }),
                                  Block(11U, { 13U }),
                                  Block(12U, { 13U }),
                                  Block(13U) });
    CHECK(Facts(result, 10U).controllers.empty());
    CHECK(Facts(result, 10U).dependents.empty());
    CHECK(Facts(result, 11U).controllers.empty());
}

TEST_CASE("a loop body is controlled by the loop header")
{
    const auto result = Analyze({ Block(0U, { 1U }),
                                  Block(1U, { 2U, 4U }),
                                  Block(2U, { 3U }),
                                  Block(3U, { 1U }),
                                  Block(4U) });
    CHECK(Facts(result, 2U).controllers == Ids({ 1U }));
    CHECK(Facts(result, 3U).controllers == Ids({ 1U }));
    CHECK(Facts(result, 4U).controllers.empty());
}

TEST_CASE("a loop header may depend on its own continuing edge")
{
    const auto result = Analyze({ Block(0U, { 1U }),
                                  Block(1U, { 2U, 4U }),
                                  Block(2U, { 3U }),
                                  Block(3U, { 1U }),
                                  Block(4U) });
    // The header is revisited only after taking the body edge. Recording the
    // self-dependence is useful to loop-aware predicate placement.
    CHECK(HasEdge(result, 1U, 2U, 1U));
    CHECK(Facts(result, 1U).controllers == Ids({ 1U }));
}

TEST_CASE("duplicate CFG edges do not duplicate dependence edges")
{
    const auto result = Analyze({ Block(0U, { 1U, 1U, 2U, 2U }),
                                  Block(1U, { 3U }),
                                  Block(2U, { 3U }),
                                  Block(3U) });
    CHECK(result.edges.size() == 2U);
    CHECK(Facts(result, 0U).dependents == Ids({ 1U, 2U }));
}

TEST_CASE("facts and edges are deterministic under block presentation changes")
{
    Analysis::ControlFlowGraph graph{
        0U,
        { Block(0U, { 1U, 2U }),
          Block(1U, { 3U }),
          Block(2U, { 3U }),
          Block(3U) },
    };
    const auto expected = Analysis::AnalyzeControlDependence(graph);
    std::ranges::reverse(graph.blocks);
    const auto actual = Analysis::AnalyzeControlDependence(graph);
    CHECK(actual.edges == expected.edges);
    CHECK(actual.facts == expected.facts);
}

TEST_CASE("facts are sorted by sparse block identity")
{
    Analysis::ControlFlowGraph graph{
        100U,
        { Block(900U),
          Block(100U, { 700U, 800U }),
          Block(800U, { 900U }),
          Block(700U, { 900U }) },
    };
    const auto result = Analysis::AnalyzeControlDependence(graph);
    REQUIRE(result.facts.size() == 4U);
    CHECK(result.facts[0].block == 100U);
    CHECK(result.facts[1].block == 700U);
    CHECK(result.facts[2].block == 800U);
    CHECK(result.facts[3].block == 900U);
}

TEST_CASE("controller and dependent summaries are unique")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 3U, 4U }),
                                  Block(2U, { 5U }),
                                  Block(3U, { 5U }),
                                  Block(4U, { 5U }),
                                  Block(5U) });
    const auto &facts = Facts(result, 3U);
    CHECK(std::ranges::adjacent_find(facts.controllers)
          == facts.controllers.end());
    CHECK(std::ranges::adjacent_find(Facts(result, 0U).dependents)
          == Facts(result, 0U).dependents.end());
}

TEST_CASE("a branch whose arms immediately reconverge records only arm blocks")
{
    const auto result = Analyze({ Block(0U, { 1U, 2U }),
                                  Block(1U, { 4U }),
                                  Block(2U, { 4U }),
                                  Block(4U, { 5U }),
                                  Block(5U) });
    CHECK(result.edges.size() == 2U);
    CHECK(Facts(result, 1U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 2U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 4U).controllers.empty());
    CHECK(Facts(result, 5U).controllers.empty());
}

TEST_CASE("a branch arm containing another complete diamond keeps both "
          "controller levels")
{
    const auto result = Analyze({ Block(0U, { 1U, 7U }),
                                  Block(1U, { 2U, 3U }),
                                  Block(2U, { 4U }),
                                  Block(3U, { 4U }),
                                  Block(4U, { 8U }),
                                  Block(7U, { 8U }),
                                  Block(8U) });
    CHECK(Facts(result, 1U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 2U).controllers == Ids({ 1U }));
    CHECK(Facts(result, 3U).controllers == Ids({ 1U }));
    CHECK(Facts(result, 4U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 7U).controllers == Ids({ 0U }));
    CHECK(Facts(result, 8U).controllers.empty());
}

TEST_CASE("control dependence preserves the selected successor for long arms")
{
    const auto result = Analyze({ Block(0U, { 10U, 20U }),
                                  Block(10U, { 11U }),
                                  Block(11U, { 30U }),
                                  Block(20U, { 21U }),
                                  Block(21U, { 30U }),
                                  Block(30U) });
    CHECK(HasEdge(result, 0U, 10U, 10U));
    CHECK(HasEdge(result, 0U, 10U, 11U));
    CHECK(HasEdge(result, 0U, 20U, 20U));
    CHECK(HasEdge(result, 0U, 20U, 21U));
    CHECK_FALSE(HasEdge(result, 0U, 10U, 20U));
    CHECK_FALSE(HasEdge(result, 0U, 20U, 10U));
}
