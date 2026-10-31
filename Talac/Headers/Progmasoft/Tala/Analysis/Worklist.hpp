// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>

#include "Progmasoft/Tala/Analysis/ControlFlow.hpp"

namespace Progmasoft::Tala::Analysis
{
    /// Direction in which a dataflow fixed point propagates changes.
    enum class WorklistDirection : std::uint8_t
    {
        Forward, ///< Changed block outputs schedule CFG successors.
        Backward ///< Changed block inputs schedule CFG predecessors.
    };

    /// Instrumentation counters for one worklist-driven analysis.
    struct WorklistStatistics final
    {
        /// Number of times a block was removed for evaluation.
        std::size_t blockEvaluations{};
        /// Number of change notifications submitted by a transfer function.
        std::size_t changeNotifications{};
        /// Total block scheduling operations, including initial seeds.
        std::size_t scheduledBlocks{};
        /// Largest number of unique pending blocks held at once.
        std::size_t peakPendingBlocks{};

        /// Compare all scheduler counters.
        /// @return true when the instrumentation snapshots are equal.
        [[nodiscard]] auto
        operator==(const WorklistStatistics &) const -> bool = default;
    };

    /// Deduplicating CFG work queue with direction-aware initial ordering.
    class DataflowWorklist final
    {
    public:
        /// Seed all reachable blocks in an order suited to propagation.
        /// @param controlFlow Validated reachability and edge facts.
        /// @param direction Direction used to map changes to neighboring
        /// blocks.
        DataflowWorklist(const ControlFlowResult &controlFlow,
                         WorklistDirection direction);

        /// Remove and return the next pending block, if one exists.
        /// @return Next block identity, or empty when the queue is exhausted.
        [[nodiscard]] auto
        Next() -> std::optional<ControlFlowBlockId>;

        /// Schedule dependents affected by a changed transfer result.
        /// @param block Block whose output or input fact changed.
        void
        NotifyChanged(ControlFlowBlockId block);

        /// Explicitly schedule a known reachable block.
        /// @param block Identity to enqueue; unknown/unreachable ids are
        /// ignored.
        void
        Schedule(ControlFlowBlockId block);

        /// Test whether no blocks remain pending.
        /// @return true when the next pop would return an empty optional.
        [[nodiscard]] auto
        Empty() const noexcept -> bool;

        /// Read counters accumulated by this scheduler.
        /// @return Reference to the scheduler-owned statistics snapshot.
        [[nodiscard]] auto
        Statistics() const noexcept -> const WorklistStatistics &;

    private:
        struct Implementation;
        std::unique_ptr<Implementation> implementation_;

    public:
        DataflowWorklist(const DataflowWorklist &) = delete;
        /// Copy assignment is disabled because the scheduler owns unique state.
        auto
        operator=(const DataflowWorklist &) -> DataflowWorklist & = delete;

        /// Transfer scheduler state from another worklist.
        /// @param other Worklist whose state is consumed by the move.
        DataflowWorklist(DataflowWorklist &&other) noexcept;
        /// Replace this state by consuming another worklist.
        /// @param other Source state to move into this object.
        /// @return Reference to this worklist after assignment.
        auto
        operator=(DataflowWorklist &&other) noexcept -> DataflowWorklist &;

        /// Destroy scheduler state owned by the out-of-line implementation.
        ~DataflowWorklist();
    };
} // namespace Progmasoft::Tala::Analysis
