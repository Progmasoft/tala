// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstdint>
#include <vector>

namespace Progmasoft::Tala::Analysis
{
    /// Stable identity used to refer to a basic block in an analysis graph.
    using ControlFlowBlockId = std::uint32_t;

    /// One basic block and its explicitly ordered outgoing control-flow edges.
    struct ControlFlowBlock final
    {
        /// Identity unique within the containing graph.
        ControlFlowBlockId id{};
        /// Successor identities in source/control-transfer order.
        std::vector<ControlFlowBlockId> successors;
    };

    /// Directed control-flow graph supplied to target-independent analyses.
    struct ControlFlowGraph final
    {
        /// Identity of the function's entry block.
        ControlFlowBlockId entry{};
        /// Blocks in caller-owned presentation order; traversal uses edges.
        std::vector<ControlFlowBlock> blocks;
    };

    /// Structural defect found while validating a control-flow graph.
    enum class ControlFlowIssueKind : std::uint8_t
    {
        DuplicateBlock, ///< Two block records use the same identity.
        MissingEntry,   ///< The graph does not define its entry identity.
        MissingTarget   ///< An edge names a block absent from the graph.
    };

    /// Location and kind of one malformed-graph condition.
    struct ControlFlowIssue final
    {
        /// Category of graph defect.
        ControlFlowIssueKind kind{ ControlFlowIssueKind::MissingEntry };
        /// Block where the defect was observed, when applicable.
        ControlFlowBlockId block{};
        /// Missing or conflicting target identity, when applicable.
        ControlFlowBlockId target{};

        /// Compare all diagnostic coordinates and the issue category.
        /// @return true when both issue records describe the same defect.
        [[nodiscard]] auto
        operator==(const ControlFlowIssue &) const -> bool = default;
    };

    /// Reachability and edge facts materialized for one block.
    struct ControlFlowBlockFacts final
    {
        /// Block identity described by these facts.
        ControlFlowBlockId block{};
        /// Whether the block is reachable from the graph entry.
        bool reachable{};
        /// Incoming edges represented as predecessor block identities.
        std::vector<ControlFlowBlockId> predecessors;
        /// Valid outgoing targets in the graph's declared edge order.
        std::vector<ControlFlowBlockId> successors;

        /// Compare all observable facts for a block.
        /// @return true when identities, reachability, and edges match.
        [[nodiscard]] auto
        operator==(const ControlFlowBlockFacts &) const -> bool = default;
    };

    /// Complete result of structural control-flow analysis.
    struct ControlFlowResult final
    {
        /// Structural errors; an empty vector means the graph is well formed.
        std::vector<ControlFlowIssue> issues;
        /// Reachable blocks in deterministic depth-first preorder.
        std::vector<ControlFlowBlockId> preorder;
        /// Reachable blocks in reverse postorder, useful for forward passes.
        std::vector<ControlFlowBlockId> reversePostorder;
        /// Per-block facts sorted by block identity.
        std::vector<ControlFlowBlockFacts> facts;

        /// Test whether graph structure is valid for transformation.
        /// @return true when no structural issue was found.
        [[nodiscard]] auto
        valid() const -> bool
        {
            return issues.empty();
        }
    };

    /// Validate graph identities, resolve edges, and compute deterministic
    /// reachability orders and per-block predecessor/successor facts.
    /// Block vector order is presentation-only; declared successor order is
    /// preserved during traversal and facts are sorted by block identity.
    /// @param graph Graph whose structural contract is being checked.
    /// @return Structural issues and facts, including partial facts on errors.
    [[nodiscard]] auto
    AnalyzeControlFlow(const ControlFlowGraph &graph) -> ControlFlowResult;
} // namespace Progmasoft::Tala::Analysis
