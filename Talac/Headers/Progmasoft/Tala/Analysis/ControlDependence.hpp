// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>
#include <vector>

#include "Progmasoft/Tala/Analysis/Dominance.hpp"

namespace Progmasoft::Tala::Analysis
{
    /// One CFG edge and block pair expressing a control-dependence relation.
    struct ControlDependenceEdge final
    {
        /// Block whose branch outcome controls execution.
        ControlFlowBlockId controller{};
        /// Successor edge of the controller that establishes the relation.
        ControlFlowBlockId successor{};
        /// Block whose execution is controlled by that edge.
        ControlFlowBlockId dependent{};

        /// Compare edge identity and both endpoints.
        /// @return true when the dependence edge is identical.
        [[nodiscard]] auto
        operator==(const ControlDependenceEdge &) const -> bool = default;
    };

    /// Incoming controllers and outgoing dependents for one CFG block.
    struct ControlDependenceBlockFacts final
    {
        /// Block summarized by these facts.
        ControlFlowBlockId block{};
        /// Unique controller blocks, in deterministic order.
        std::vector<ControlFlowBlockId> controllers;
        /// Unique blocks controlled by this block, in deterministic order.
        std::vector<ControlFlowBlockId> dependents;

        /// Compare the block identity and its relation sets.
        /// @return true when all control-dependence facts match.
        [[nodiscard]] auto
        operator==(const ControlDependenceBlockFacts &) const -> bool = default;
    };

    /// Control-dependence relations derived from CFG dominance structure.
    struct ControlDependenceResult final
    {
        /// Dominance analysis reused to establish post-dominance boundaries.
        DominanceResult structure;
        /// Edge-sensitive dependence relations in deterministic order.
        std::vector<ControlDependenceEdge> edges;
        /// Per-block controller and dependent summaries.
        std::vector<ControlDependenceBlockFacts> facts;
        /// Whether complete control-dependence facts are available.
        bool available{};

        /// Check whether the result may justify a transformation.
        /// @return true when facts are available and the CFG is valid.
        [[nodiscard]] auto
        validForTransformation() const -> bool
        {
            return available && structure.validForTransformation();
        }
    };

    /// Derive edge-sensitive control dependence from post-dominance.
    /// The controlling successor is retained so branch-arm predicates and
    /// profile weights are not collapsed into a block-only relation.
    /// @param graph Control-flow graph to analyze.
    /// @return Dominance structure and, when derivable, dependence facts.
    [[nodiscard]] auto
    AnalyzeControlDependence(const ControlFlowGraph &graph)
        -> ControlDependenceResult;

    [[nodiscard]] auto
    ControlDependenceFactsFor(const ControlDependenceResult &result,
                              ControlFlowBlockId block)
        -> const ControlDependenceBlockFacts *;
} // namespace Progmasoft::Tala::Analysis
  /// Find one block's dependence summary in a completed analysis result.
  /// @param result Analysis result to search.
  /// @param block Identity of the requested block.
  /// @return Pointer to stable result-owned facts, or null when absent.
