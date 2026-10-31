// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

#include "Progmasoft/Tala/Analysis/Worklist.hpp"

namespace Progmasoft::Tala::Analysis::Liveness
{
    /// CFG block identity used by the liveness input model.
    using BlockId = ControlFlowBlockId;
    /// Stage-neutral storage identity for symbols or virtual registers.
    using StorageId = std::uint64_t;

    /// Read/write effects and dead-write policy for one instruction point.
    struct Access final
    {
        /// Instruction ordinal within its block.
        std::size_t instruction{};
        /// Whether this access represents the block terminator.
        bool terminator{};
        /// Values read before the optional destination write.
        std::vector<StorageId> reads;
        /// Destination defined by the access, if it writes one.
        std::optional<StorageId> write;
        /// Whether the adapter has proved removing a dead write is safe.
        bool removable{};

        /// Compare instruction location and all read/write properties.
        /// @return true when both access descriptions match.
        [[nodiscard]] auto
        operator==(const Access &) const -> bool = default;
    };

    /// One block and its ordered access sequence.
    struct Block final
    {
        /// Unique identity within the function.
        BlockId id{};
        /// Successors in declared control-flow edge order.
        std::vector<BlockId> successors;
        /// Instruction and terminator accesses in execution order.
        std::vector<Access> accesses;

        /// Compare block identity, edges, and access ordering.
        /// @return true when both block descriptions match.
        [[nodiscard]] auto
        operator==(const Block &) const -> bool = default;
    };

    /// Liveness analysis input for one function.
    struct Function final
    {
        /// Entry block from which reachability is computed.
        BlockId entry{};
        /// Basic blocks and their access effects.
        std::vector<Block> blocks;
    };

    /// Live-before/live-after and retention decision for one access.
    struct AccessFacts final
    {
        /// Original instruction ordinal supplied by the adapter.
        std::size_t instruction{};
        /// Whether this fact belongs to a terminator.
        bool terminator{};
        /// Whether the access remains necessary after dead-write elimination.
        bool retained{ true };
        /// Values live immediately before executing the access.
        std::vector<StorageId> liveBefore;
        /// Values live immediately after executing the access.
        std::vector<StorageId> liveAfter;

        /// Compare location, retention, and both live sets.
        /// @return true when all access facts are equal.
        [[nodiscard]] auto
        operator==(const AccessFacts &) const -> bool = default;
    };

    /// Reachability and boundary liveness facts for a CFG block.
    struct BlockFacts final
    {
        /// Block identity summarized by the fact record.
        BlockId block{};
        /// Whether the block can execute from the entry.
        bool reachable{};
        /// Values live at the first instruction boundary.
        std::vector<StorageId> liveOnEntry;
        /// Values live after the block's final access.
        std::vector<StorageId> liveOnExit;
        /// Per-access details in original instruction order.
        std::vector<AccessFacts> accesses;

        /// Compare reachability and every materialized liveness fact.
        /// @return true when both block summaries are equal.
        [[nodiscard]] auto
        operator==(const BlockFacts &) const -> bool = default;
    };

    /// Result of liveness fixed-point analysis and optional dead-write pruning.
    struct Result final
    {
        /// Structural CFG errors found before dataflow facts were trusted.
        std::vector<ControlFlowIssue> issues;
        /// Per-block facts when materialization was enabled.
        std::vector<BlockFacts> facts;
        /// Worklist iteration statistics.
        WorklistStatistics statistics;

        /// Test whether structural input and analysis are valid.
        /// @return true when no CFG issue was found.
        [[nodiscard]] auto
        valid() const -> bool
        {
            return issues.empty();
        }
    };

    /// Controls whether expanded per-value live sets are retained.
    struct AnalysisOptions final
    {
        // Optimizers need reachability and retention decisions but do not
        // consume expanded live-before/live-after vectors. Diagnostic and
        // analysis clients retain the complete fact view by default.
        /// Retain detailed live-before/live-after sets for consumers.
        bool materializeLiveSets{ true };
    };

    /// Compute a least backward liveness fixed point for the supplied CFG.
    /// A removable write with a dead destination is dropped together with its
    /// reads, allowing dead producer chains to disappear in one pass.
    /// @param function Function CFG and stage-provided access effects.
    /// @param options Whether expanded liveness sets are materialized.
    /// @return Structural errors, liveness facts, and worklist statistics.
    [[nodiscard]] auto
    Analyze(const Function &function, AnalysisOptions options = {}) -> Result;
} // namespace Progmasoft::Tala::Analysis::Liveness
