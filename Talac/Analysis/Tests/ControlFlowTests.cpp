// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <array>
#include <cstdint>
#include <initializer_list>
#include <ranges>
#include <vector>

#include "Progmasoft/Tala/Analysis/ControlFlow.hpp"

namespace
{
    namespace Analysis = Progmasoft::Tala::Analysis;

    [[nodiscard]] auto
    Block(const Analysis::ControlFlowBlockId id,
          std::initializer_list<Analysis::ControlFlowBlockId> successors = {})
        -> Analysis::ControlFlowBlock
    {
        return { id, successors };
    }

    [[nodiscard]] auto
    Graph(std::initializer_list<Analysis::ControlFlowBlock> blocks,
          const Analysis::ControlFlowBlockId entry = 0U)
        -> Analysis::ControlFlowGraph
    {
        return { entry, blocks };
    }

    [[nodiscard]] auto
    HasIssue(const Analysis::ControlFlowResult &result,
             const Analysis::ControlFlowIssueKind kind) -> bool
    {
        return std::ranges::any_of(result.issues, [kind](const auto &issue) {
            return issue.kind == kind;
        });
    }

    [[nodiscard]] auto
    FactsFor(const Analysis::ControlFlowResult &result,
             const Analysis::ControlFlowBlockId block)
        -> const Analysis::ControlFlowBlockFacts &
    {
        const auto found
            = std::ranges::find(result.facts,
                                block,
                                &Analysis::ControlFlowBlockFacts::block);
        REQUIRE(found != result.facts.end());
        return *found;
    }
} // namespace

TEST_CASE("control-flow analysis accepts one entry block")
{
    const auto result = Analysis::AnalyzeControlFlow(Graph({ Block(0U) }));
    CHECK(result.valid());
    CHECK(result.preorder == std::vector<Analysis::ControlFlowBlockId>{ 0U });
    CHECK(result.reversePostorder
          == std::vector<Analysis::ControlFlowBlockId>{ 0U });
    REQUIRE(result.facts.size() == 1U);
    CHECK(result.facts.front().reachable);
}

TEST_CASE("control-flow analysis rejects an absent entry")
{
    const auto result = Analysis::AnalyzeControlFlow(Graph({ Block(1U) }));
    CHECK_FALSE(result.valid());
    CHECK(HasIssue(result, Analysis::ControlFlowIssueKind::MissingEntry));
    CHECK(result.preorder.empty());
    CHECK_FALSE(FactsFor(result, 1U).reachable);
}

TEST_CASE("control-flow analysis diagnoses duplicate identities")
{
    const auto result
        = Analysis::AnalyzeControlFlow(Graph({ Block(0U), Block(0U) }));
    CHECK(HasIssue(result, Analysis::ControlFlowIssueKind::DuplicateBlock));
    CHECK(result.facts.size() == 1U);
}

TEST_CASE("the first duplicate record is canonical")
{
    const auto result = Analysis::AnalyzeControlFlow(
        Graph({ Block(0U, { 1U }), Block(0U, { 2U }), Block(1U), Block(2U) }));
    CHECK(HasIssue(result, Analysis::ControlFlowIssueKind::DuplicateBlock));
    CHECK(FactsFor(result, 1U).reachable);
    CHECK_FALSE(FactsFor(result, 2U).reachable);
}

TEST_CASE("missing targets retain their source and target identities")
{
    const auto result
        = Analysis::AnalyzeControlFlow(Graph({ Block(0U, { 90U }) }));
    REQUIRE(result.issues.size() == 1U);
    CHECK(result.issues.front().kind
          == Analysis::ControlFlowIssueKind::MissingTarget);
    CHECK(result.issues.front().block == 0U);
    CHECK(result.issues.front().target == 90U);
}

TEST_CASE("invalid targets are not traversed")
{
    const auto result = Analysis::AnalyzeControlFlow(
        Graph({ Block(0U, { 90U }), Block(1U) }));
    CHECK(result.preorder == std::vector<Analysis::ControlFlowBlockId>{ 0U });
    CHECK_FALSE(FactsFor(result, 1U).reachable);
}

TEST_CASE("duplicate edges are represented once")
{
    const auto result = Analysis::AnalyzeControlFlow(
        Graph({ Block(0U, { 1U, 1U, 1U }), Block(1U) }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 0U).successors
          == std::vector<Analysis::ControlFlowBlockId>{ 1U });
    CHECK(FactsFor(result, 1U).predecessors
          == std::vector<Analysis::ControlFlowBlockId>{ 0U });
}

TEST_CASE("preorder follows declared successor order")
{
    const auto result = Analysis::AnalyzeControlFlow(
        Graph({ Block(0U, { 2U, 1U }), Block(1U), Block(2U) }));
    CHECK(result.preorder
          == std::vector<Analysis::ControlFlowBlockId>{ 0U, 2U, 1U });
}

TEST_CASE("reverse postorder keeps entry before a diamond")
{
    const auto result
        = Analysis::AnalyzeControlFlow(Graph({ Block(0U, { 1U, 2U }),
                                               Block(1U, { 3U }),
                                               Block(2U, { 3U }),
                                               Block(3U) }));
    REQUIRE(result.reversePostorder.size() == 4U);
    CHECK(result.reversePostorder.front() == 0U);
    CHECK(result.reversePostorder.back() == 3U);
}

TEST_CASE("diamond joins expose both predecessors")
{
    const auto result
        = Analysis::AnalyzeControlFlow(Graph({ Block(0U, { 1U, 2U }),
                                               Block(1U, { 3U }),
                                               Block(2U, { 3U }),
                                               Block(3U) }));
    CHECK(FactsFor(result, 3U).predecessors
          == std::vector<Analysis::ControlFlowBlockId>{ 1U, 2U });
}

TEST_CASE("unreachable predecessors are filtered from observable facts")
{
    const auto result = Analysis::AnalyzeControlFlow(
        Graph({ Block(0U, { 2U }), Block(1U, { 2U }), Block(2U) }));
    CHECK(FactsFor(result, 2U).predecessors
          == std::vector<Analysis::ControlFlowBlockId>{ 0U });
}

TEST_CASE("unreachable blocks retain their valid successors")
{
    const auto result = Analysis::AnalyzeControlFlow(
        Graph({ Block(0U), Block(1U, { 2U }), Block(2U) }));
    CHECK_FALSE(FactsFor(result, 1U).reachable);
    CHECK(FactsFor(result, 1U).successors
          == std::vector<Analysis::ControlFlowBlockId>{ 2U });
    CHECK(FactsFor(result, 2U).predecessors.empty());
}

TEST_CASE("self loops terminate traversal")
{
    const auto result
        = Analysis::AnalyzeControlFlow(Graph({ Block(0U, { 0U }) }));
    CHECK(result.valid());
    CHECK(result.preorder == std::vector<Analysis::ControlFlowBlockId>{ 0U });
    CHECK(result.reversePostorder
          == std::vector<Analysis::ControlFlowBlockId>{ 0U });
    CHECK(FactsFor(result, 0U).predecessors
          == std::vector<Analysis::ControlFlowBlockId>{ 0U });
}

TEST_CASE("multi-block loops are traversed once")
{
    const auto result
        = Analysis::AnalyzeControlFlow(Graph({ Block(0U, { 1U }),
                                               Block(1U, { 2U }),
                                               Block(2U, { 1U, 3U }),
                                               Block(3U) }));
    CHECK(result.preorder
          == std::vector<Analysis::ControlFlowBlockId>{ 0U, 1U, 2U, 3U });
    CHECK(result.reversePostorder
          == std::vector<Analysis::ControlFlowBlockId>{ 0U, 1U, 2U, 3U });
}

TEST_CASE("block facts are sorted by identity")
{
    const auto result = Analysis::AnalyzeControlFlow(
        Graph({ Block(90U), Block(0U), Block(20U), Block(3U) }));
    REQUIRE(result.facts.size() == 4U);
    CHECK(result.facts[0].block == 0U);
    CHECK(result.facts[1].block == 3U);
    CHECK(result.facts[2].block == 20U);
    CHECK(result.facts[3].block == 90U);
}

TEST_CASE("successor facts are sorted without changing traversal order")
{
    const auto result = Analysis::AnalyzeControlFlow(
        Graph({ Block(0U, { 8U, 2U, 5U }), Block(2U), Block(5U), Block(8U) }));
    CHECK(result.preorder
          == std::vector<Analysis::ControlFlowBlockId>{ 0U, 8U, 2U, 5U });
    CHECK(FactsFor(result, 0U).successors
          == std::vector<Analysis::ControlFlowBlockId>{ 2U, 5U, 8U });
}

TEST_CASE("predecessor facts are sorted regardless of edge discovery")
{
    const auto result
        = Analysis::AnalyzeControlFlow(Graph({ Block(0U, { 9U, 2U }),
                                               Block(2U, { 12U }),
                                               Block(9U, { 12U }),
                                               Block(12U) }));
    CHECK(FactsFor(result, 12U).predecessors
          == std::vector<Analysis::ControlFlowBlockId>{ 2U, 9U });
}

TEST_CASE("presentation order does not change traversal")
{
    auto graph = Graph({ Block(0U, { 1U, 2U }),
                         Block(1U, { 3U }),
                         Block(2U, { 3U }),
                         Block(3U) });
    const auto expected = Analysis::AnalyzeControlFlow(graph);
    graph.blocks = { graph.blocks[3],
                     graph.blocks[1],
                     graph.blocks[0],
                     graph.blocks[2] };
    const auto actual = Analysis::AnalyzeControlFlow(graph);
    CHECK(actual.issues == expected.issues);
    CHECK(actual.preorder == expected.preorder);
    CHECK(actual.reversePostorder == expected.reversePostorder);
    CHECK(actual.facts == expected.facts);
}

TEST_CASE("every presentation permutation has the same result")
{
    auto graph = Graph({ Block(0U, { 1U }),
                         Block(1U, { 2U, 3U }),
                         Block(2U, { 4U }),
                         Block(3U, { 4U }),
                         Block(4U) });
    const auto expected = Analysis::AnalyzeControlFlow(graph);
    std::ranges::sort(graph.blocks, {}, &Analysis::ControlFlowBlock::id);
    do
    {
        const auto actual = Analysis::AnalyzeControlFlow(graph);
        CHECK(actual.preorder == expected.preorder);
        CHECK(actual.reversePostorder == expected.reversePostorder);
        CHECK(actual.facts == expected.facts);
    } while (std::ranges::next_permutation(graph.blocks,
                                           {},
                                           &Analysis::ControlFlowBlock::id)
                 .found);
}

TEST_CASE("iterative traversal handles a deep graph")
{
    Analysis::ControlFlowGraph graph;
    graph.entry = 0U;
    constexpr Analysis::ControlFlowBlockId kBlockCount = 4096U;
    graph.blocks.reserve(kBlockCount);
    for (Analysis::ControlFlowBlockId id = 0U; id < kBlockCount; ++id)
    {
        Analysis::ControlFlowBlock block;
        block.id = id;
        if (id + 1U < kBlockCount)
            block.successors.push_back(id + 1U);
        graph.blocks.push_back(std::move(block));
    }
    const auto result = Analysis::AnalyzeControlFlow(graph);
    CHECK(result.valid());
    CHECK(result.preorder.size() == kBlockCount);
    CHECK(result.reversePostorder.size() == kBlockCount);
    CHECK(result.reversePostorder.front() == 0U);
    CHECK(result.reversePostorder.back() == kBlockCount - 1U);
}
