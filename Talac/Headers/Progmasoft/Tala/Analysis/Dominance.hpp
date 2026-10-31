// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

#include "Progmasoft/Tala/Analysis/ControlFlow.hpp"

namespace Progmasoft::Tala::Analysis
{
    /// Dominance, post-dominance, and loop facts for one CFG block.
    struct DominanceBlockFacts final
    {
        /// Block identity described by these facts.
        ControlFlowBlockId block{};
        /// Whether the block is reachable from the graph entry.
        bool reachable{};
        /// Nearest strict dominator, when one exists.
        std::optional<ControlFlowBlockId> immediateDominator;
        /// Nearest strict post-dominator, when one exists.
        std::optional<ControlFlowBlockId> immediatePostDominator;
        /// All blocks dominating this block, including itself when reachable.
        std::vector<ControlFlowBlockId> dominators;
        /// All blocks post-dominating this block under the analysis exit model.
        std::vector<ControlFlowBlockId> postDominators;
        /// Join points at which this block's dominance relation ends.
        std::vector<ControlFlowBlockId> dominanceFrontier;
        /// Join points at which this block's post-dominance relation ends.
        std::vector<ControlFlowBlockId> postDominanceFrontier;
        /// Headers of natural loops containing this block.
        std::vector<ControlFlowBlockId> loopHeaders;
        /// Number of nested natural loops containing this block.
        std::size_t loopDepth{};

        /// Compare every materialized dominance and loop property.
        /// @return true when all fields are equal.
        [[nodiscard]] auto
        operator==(const DominanceBlockFacts &) const -> bool = default;
    };

    /// A natural loop identified by its backedge and dominated region.
    struct NaturalLoop final
    {
        /// Header dominated by the loop's backedge source.
        ControlFlowBlockId header{};
        /// Latch block whose edge returns to the header.
        ControlFlowBlockId latch{};
        /// Blocks belonging to the loop, including header and latch.
        std::vector<ControlFlowBlockId> members;
        /// Edges leaving the loop, represented by their source blocks.
        std::vector<ControlFlowBlockId> exits;

        /// Compare loop identity and its ordered block sets.
        /// @return true when all loop facts match.
        [[nodiscard]] auto
        operator==(const NaturalLoop &) const -> bool = default;
    };

    /// Cyclic strongly connected region without a unique dominating header.
    struct IrreducibleRegion final
    {
        /// Members of the cyclic strongly connected component.
        std::vector<ControlFlowBlockId> members;
        /// Blocks receiving edges from outside the region.
        std::vector<ControlFlowBlockId> entries;

        /// Compare cyclic component membership and external entry points.
        /// @return true when both regions have identical members and entries.
        [[nodiscard]] auto
        operator==(const IrreducibleRegion &) const -> bool = default;
    };

    /// Complete dominance result and discovered loop structures.
    struct DominanceResult final
    {
        /// Structural graph analysis on which all remaining facts depend.
        ControlFlowResult controlFlow;
        /// Dominance and loop-depth facts, sorted by block identity.
        std::vector<DominanceBlockFacts> facts;
        /// Natural loops discovered from dominance backedges.
        std::vector<NaturalLoop> naturalLoops;
        /// Cyclic components that cannot be represented as natural loops.
        std::vector<IrreducibleRegion> irreducibleRegions;
        /// Reachable blocks with no outgoing edge.
        std::vector<ControlFlowBlockId> exits;
        /// Whether post-dominance facts were computed for this graph.
        bool hasPostDominance{};

        /// Check whether structural CFG facts are safe to use for a transform.
        /// Malformed graphs can still carry partial facts for diagnostics.
        /// @return true only when the underlying CFG is well formed.
        [[nodiscard]] auto
        validForTransformation() const -> bool
        {
            return controlFlow.valid();
        }
    };

    /// Compute dominators, post-dominators, frontiers, and loop regions.
    /// @param graph CFG whose structure and loops are being analyzed.
    /// @return Deterministic facts and any structural input issues.
    [[nodiscard]] auto
    AnalyzeDominance(const ControlFlowGraph &graph) -> DominanceResult;

    /// Test whether a candidate block dominates another block.
    /// @param result Completed dominance facts.
    /// @param dominator Candidate dominating block identity.
    /// @param block Block whose dominator set is queried.
    /// @return true when dominator is in block's dominator set.
    [[nodiscard]] auto
    Dominates(const DominanceResult &result,
              ControlFlowBlockId dominator,
              ControlFlowBlockId block) -> bool;

    /// Test dominance while excluding the reflexive block-equals-itself case.
    /// @param result Completed dominance facts.
    /// @param dominator Candidate strict dominator identity.
    /// @param block Block whose dominator set is queried.
    /// @return true when dominator differs from and dominates block.
    [[nodiscard]] auto
    StrictlyDominates(const DominanceResult &result,
                      ControlFlowBlockId dominator,
                      ControlFlowBlockId block) -> bool;

    /// Test whether a candidate block post-dominates another block.
    /// @param result Completed post-dominance facts.
    /// @param postDominator Candidate post-dominating block identity.
    /// @param block Block whose post-dominator set is queried.
    /// @return true when postDominator is in block's post-dominator set.
    [[nodiscard]] auto
    PostDominates(const DominanceResult &result,
                  ControlFlowBlockId postDominator,
                  ControlFlowBlockId block) -> bool;

    /// Test post-dominance while excluding the reflexive relation.
    /// @param result Completed post-dominance facts.
    /// @param postDominator Candidate strict post-dominator identity.
    /// @param block Block whose post-dominator set is queried.
    /// @return true when identities differ and the relation holds.
    [[nodiscard]] auto
    StrictlyPostDominates(const DominanceResult &result,
                          ControlFlowBlockId postDominator,
                          ControlFlowBlockId block) -> bool;

    /// Find a block's dominance and loop facts in a completed analysis.
    /// @param result Analysis result to search.
    /// @param block Requested CFG block identity.
    /// @return Pointer to result-owned facts, or null when unavailable.
    [[nodiscard]] auto
    FactsFor(const DominanceResult &result, ControlFlowBlockId block)
        -> const DominanceBlockFacts *;
} // namespace Progmasoft::Tala::Analysis
