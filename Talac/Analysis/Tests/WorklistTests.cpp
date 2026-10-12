// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Analysis/ControlFlow.hpp"
#include "Progmasoft/Tala/Analysis/Worklist.hpp"

namespace
{
    namespace Analysis = Progmasoft::Tala::Analysis;

    [[nodiscard]] auto
    Graph(std::initializer_list<Analysis::ControlFlowBlock> blocks,
          const Analysis::ControlFlowBlockId entry = 0U)
        -> Analysis::ControlFlowResult
    {
        return Analysis::AnalyzeControlFlow({ entry, blocks });
    }

    [[nodiscard]] auto
    Drain(Analysis::DataflowWorklist &worklist)
        -> std::vector<Analysis::ControlFlowBlockId>
    {
        std::vector<Analysis::ControlFlowBlockId> order;
        while (const auto block = worklist.Next())
            order.push_back(*block);
        return order;
    }
} // namespace

TEST_CASE("forward worklist starts in reverse postorder")
{
    const auto flow = Graph({
        { 0U, { 2U, 1U } },
        { 1U, { 3U } },
        { 2U, { 3U } },
        { 3U, {} },
    });
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Forward);
    CHECK(Drain(worklist) == flow.reversePostorder);
}

TEST_CASE("backward worklist starts in postorder")
{
    const auto flow = Graph({
        { 0U, { 1U } },
        { 1U, { 2U } },
        { 2U, {} },
    });
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Backward);
    CHECK(Drain(worklist)
          == std::vector<Analysis::ControlFlowBlockId>{ 2U, 1U, 0U });
}

TEST_CASE("forward change schedules reachable successors")
{
    const auto flow = Graph({
        { 0U, { 1U, 2U } },
        { 1U, { 3U } },
        { 2U, { 3U } },
        { 3U, {} },
    });
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Forward);
    static_cast<void>(Drain(worklist));

    worklist.NotifyChanged(0U);
    CHECK(Drain(worklist)
          == std::vector<Analysis::ControlFlowBlockId>{ 1U, 2U });
}

TEST_CASE("backward change schedules reachable predecessors")
{
    const auto flow = Graph({
        { 0U, { 1U, 2U } },
        { 1U, { 3U } },
        { 2U, { 3U } },
        { 3U, {} },
    });
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Backward);
    static_cast<void>(Drain(worklist));

    worklist.NotifyChanged(3U);
    CHECK(Drain(worklist)
          == std::vector<Analysis::ControlFlowBlockId>{ 1U, 2U });
}

TEST_CASE("duplicate scheduling is coalesced")
{
    const auto flow = Graph({ { 0U, { 1U } }, { 1U, {} } });
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Forward);
    static_cast<void>(Drain(worklist));

    worklist.Schedule(1U);
    worklist.Schedule(1U);
    worklist.Schedule(1U);
    CHECK(Drain(worklist) == std::vector<Analysis::ControlFlowBlockId>{ 1U });
}

TEST_CASE("unreachable and unknown identities cannot enter the worklist")
{
    const auto flow = Graph({ { 0U, {} }, { 8U, { 9U } }, { 9U, {} } });
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Forward);
    CHECK(Drain(worklist) == std::vector<Analysis::ControlFlowBlockId>{ 0U });

    worklist.Schedule(8U);
    worklist.Schedule(9U);
    worklist.Schedule(999U);
    CHECK(worklist.Empty());
}

TEST_CASE("self loops are rescheduled only after their current evaluation")
{
    const auto flow = Graph({ { 0U, { 0U } } });
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Forward);
    REQUIRE(worklist.Next()
            == std::optional<Analysis::ControlFlowBlockId>{ 0U });
    worklist.NotifyChanged(0U);
    REQUIRE(worklist.Next()
            == std::optional<Analysis::ControlFlowBlockId>{ 0U });
    CHECK(worklist.Empty());
}

TEST_CASE("change scheduling preserves canonical edge order")
{
    const auto flow = Graph({
        { 0U, { 9U, 3U, 7U } },
        { 3U, {} },
        { 7U, {} },
        { 9U, {} },
    });
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Forward);
    static_cast<void>(Drain(worklist));

    worklist.NotifyChanged(0U);
    // Control-flow facts sort identity sets. The scheduler therefore produces
    // repeatable propagation even if a source terminator stores another order.
    CHECK(Drain(worklist)
          == std::vector<Analysis::ControlFlowBlockId>{ 3U, 7U, 9U });
}

TEST_CASE("statistics distinguish evaluation, notification, and scheduling")
{
    const auto flow = Graph({ { 0U, { 1U } }, { 1U, {} } });
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Forward);
    CHECK(worklist.Statistics().scheduledBlocks == 2U);
    CHECK(worklist.Statistics().peakPendingBlocks == 2U);

    REQUIRE(worklist.Next().has_value());
    worklist.NotifyChanged(0U);
    CHECK(worklist.Statistics().changeNotifications == 1U);
    // Block 1 was already pending, so no duplicate schedule is counted.
    CHECK(worklist.Statistics().scheduledBlocks == 2U);
    static_cast<void>(Drain(worklist));
    CHECK(worklist.Statistics().blockEvaluations == 2U);
}

TEST_CASE("moving a worklist preserves pending state and statistics")
{
    const auto flow = Graph({ { 0U, { 1U } }, { 1U, {} } });
    Analysis::DataflowWorklist source(flow,
                                      Analysis::WorklistDirection::Forward);
    REQUIRE(source.Next() == std::optional<Analysis::ControlFlowBlockId>{ 0U });

    Analysis::DataflowWorklist destination(std::move(source));
    CHECK(Drain(destination)
          == std::vector<Analysis::ControlFlowBlockId>{ 1U });
    CHECK(destination.Statistics().blockEvaluations == 2U);
    // The moved-from state is the contract under test.
    // NOLINTNEXTLINE(bugprone-use-after-move)
    CHECK(source.Empty());
}

TEST_CASE("move assignment releases old state and adopts new work")
{
    const auto firstFlow = Graph({ { 0U, {} } });
    const auto secondFlow = Graph({ { 4U, { 5U } }, { 5U, {} } }, 4U);
    Analysis::DataflowWorklist first(firstFlow,
                                     Analysis::WorklistDirection::Forward);
    Analysis::DataflowWorklist second(secondFlow,
                                      Analysis::WorklistDirection::Forward);

    first = std::move(second);
    CHECK(Drain(first) == secondFlow.reversePostorder);
    // The moved-from state is the contract under test.
    // NOLINTNEXTLINE(bugprone-use-after-move)
    CHECK(second.Empty());
}

TEST_CASE("long chains are initially evaluated once per reachable block")
{
    Analysis::ControlFlowGraph graph;
    graph.entry = 0U;
    constexpr std::uint32_t kBlockCount = 1024U;
    graph.blocks.reserve(kBlockCount);
    for (std::uint32_t id = 0U; id < kBlockCount; ++id)
    {
        Analysis::ControlFlowBlock block;
        block.id = id;
        if (id + 1U < kBlockCount)
            block.successors.push_back(id + 1U);
        graph.blocks.push_back(std::move(block));
    }

    const auto flow = Analysis::AnalyzeControlFlow(graph);
    Analysis::DataflowWorklist worklist(flow,
                                        Analysis::WorklistDirection::Forward);
    const auto order = Drain(worklist);
    CHECK(order.size() == kBlockCount);
    CHECK(worklist.Statistics().blockEvaluations == kBlockCount);
    CHECK(worklist.Statistics().scheduledBlocks == kBlockCount);
}
