// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <deque>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "Progmasoft/Tala/Analysis/Worklist.hpp"

namespace Progmasoft::Tala::Analysis
{
    struct DataflowWorklist::Implementation final
    {
        using EdgeMap = std::unordered_map<ControlFlowBlockId,
                                           std::vector<ControlFlowBlockId>>;

        WorklistDirection direction{ WorklistDirection::Forward };
        EdgeMap forwardEdges;
        EdgeMap backwardEdges;
        std::unordered_set<ControlFlowBlockId> reachable;
        std::unordered_set<ControlFlowBlockId> scheduled;
        std::deque<ControlFlowBlockId> pending;
        WorklistStatistics statistics;

        Implementation(const ControlFlowResult &controlFlow,
                       const WorklistDirection requestedDirection)
            : direction(requestedDirection)
        {
            forwardEdges.reserve(controlFlow.facts.size());
            backwardEdges.reserve(controlFlow.facts.size());
            reachable.reserve(controlFlow.preorder.size());

            for (const auto &facts : controlFlow.facts)
            {
                forwardEdges.emplace(facts.block, facts.successors);
                backwardEdges.emplace(facts.block, facts.predecessors);
                if (facts.reachable)
                    reachable.insert(facts.block);
            }

            std::vector<ControlFlowBlockId> initial
                = controlFlow.reversePostorder;
            if (direction == WorklistDirection::Backward)
                std::ranges::reverse(initial);
            for (const auto block : initial)
                Schedule(block);
        }

        void
        Schedule(const ControlFlowBlockId block)
        {
            if (!reachable.contains(block) || !scheduled.insert(block).second)
                return;
            pending.push_back(block);
            ++statistics.scheduledBlocks;
            statistics.peakPendingBlocks
                = std::max(statistics.peakPendingBlocks, pending.size());
        }

        [[nodiscard]] auto
        Next() -> std::optional<ControlFlowBlockId>
        {
            if (pending.empty())
                return std::nullopt;
            const auto block = pending.front();
            pending.pop_front();
            scheduled.erase(block);
            ++statistics.blockEvaluations;
            return block;
        }

        void
        NotifyChanged(const ControlFlowBlockId block)
        {
            ++statistics.changeNotifications;
            const auto &edges = direction == WorklistDirection::Forward
                                    ? forwardEdges
                                    : backwardEdges;
            const auto found = edges.find(block);
            if (found == edges.end())
                return;
            for (const auto affected : found->second)
                Schedule(affected);
        }
    };

    DataflowWorklist::DataflowWorklist(const ControlFlowResult &controlFlow,
                                       const WorklistDirection direction)
        : implementation_(
              std::make_unique<Implementation>(controlFlow, direction))
    {}

    DataflowWorklist::DataflowWorklist(DataflowWorklist &&other) noexcept
        = default;

    auto
    DataflowWorklist::operator=(DataflowWorklist &&other) noexcept
        -> DataflowWorklist & = default;

    DataflowWorklist::~DataflowWorklist() = default;

    auto
    DataflowWorklist::Next() -> std::optional<ControlFlowBlockId>
    {
        return implementation_ == nullptr ? std::nullopt
                                          : implementation_->Next();
    }

    void
    DataflowWorklist::NotifyChanged(const ControlFlowBlockId block)
    {
        if (implementation_ != nullptr)
            implementation_->NotifyChanged(block);
    }

    void
    DataflowWorklist::Schedule(const ControlFlowBlockId block)
    {
        if (implementation_ != nullptr)
            implementation_->Schedule(block);
    }

    auto
    DataflowWorklist::Empty() const noexcept -> bool
    {
        return implementation_ == nullptr || implementation_->pending.empty();
    }

    auto
    DataflowWorklist::Statistics() const noexcept -> const WorklistStatistics &
    {
        static constexpr WorklistStatistics kEmptyStatistics{};
        return implementation_ == nullptr ? kEmptyStatistics
                                          : implementation_->statistics;
    }
} // namespace Progmasoft::Tala::Analysis
