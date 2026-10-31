// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

#include "Progmasoft/Tala/Analysis/Worklist.hpp"

namespace Progmasoft::Tala::Analysis
{
    /// Storage identity tracked by definite-initialization analysis.
    using StorageId = std::uint64_t;
    /// Basic-block identity used by the analysis CFG.
    using BlockId = std::uint32_t;

    /// Storage effects at one instruction position or block terminator.
    struct AccessPoint final
    {
        /// Original zero-based instruction index within the block.
        std::size_t instruction{};
        /// Whether this access models the terminator rather than an
        /// instruction.
        bool terminator{};
        /// Storage read before the optional destination write.
        std::vector<StorageId> reads;
        /// Storage initialized by this access, if it writes a value.
        std::optional<StorageId> write;
    };

    /// Control-flow block and its ordered storage effects.
    struct Block final
    {
        /// Unique identity within the function.
        BlockId id{};
        /// Successor identities in declared branch order.
        std::vector<BlockId> successors;
        /// Reads and writes in program order.
        std::vector<AccessPoint> accesses;
    };

    /// Function-level definite-initialization input model.
    struct Function final
    {
        /// Entry block used to establish reachable execution paths.
        BlockId entry{};
        /// Storage identities permitted to be accessed by the function.
        std::vector<StorageId> declarations;
        /// Declared values already initialized on entry.
        std::vector<StorageId> initiallyInitialized;
        /// Function blocks and their read/write effects.
        std::vector<Block> blocks;
    };

    enum class IssueKind : std::uint8_t
    {
        DuplicateBlock,          ///< Multiple block records use one identity.
        MissingEntry,            ///< The declared entry block is absent.
        MissingTarget,           ///< An edge targets an undefined block.
        DuplicateDeclaration,    ///< A storage identity is declared more than
                                 ///< once.
        UnknownInitialStorage,   ///< Entry state names undeclared storage.
        UnknownReadStorage,      ///< An access reads undeclared storage.
        UnknownWriteStorage,     ///< An access writes undeclared storage.
        ReadBeforeInitialization ///< A reachable read is not definitely
                                 ///< initialized.
    };

    /// Definite-initialization diagnostic with an exact program point.
    struct Issue final
    {
        /// Structural or initialization failure category.
        IssueKind kind{ IssueKind::MissingEntry };
        /// Block containing the invalid access, when applicable.
        BlockId block{};
        /// Instruction ordinal for an instruction-level issue.
        std::size_t instruction{};
        /// Whether the issue is attached to a block terminator.
        bool terminator{};
        /// Storage identity involved in the issue.
        StorageId storage{};
        /// Invalid CFG target identity for a missing-target issue.
        BlockId target{};

        /// Compare diagnostic category and source coordinates.
        /// @return true when both issue records identify the same problem.
        [[nodiscard]] auto
        operator==(const Issue &) const -> bool = default;
    };

    /// Reachability and must-initialized sets at a block's boundaries.
    struct BlockFacts final
    {
        /// Block identity described by this record.
        BlockId block{};
        /// Whether the block is reachable from entry.
        bool reachable{};
        /// Values initialized on every path entering the block.
        std::vector<StorageId> initializedOnEntry;
        /// Values initialized on every path leaving the block.
        std::vector<StorageId> initializedOnExit;

        /// Compare block identity, reachability, and must-state sets.
        /// @return true when all observable facts match.
        [[nodiscard]] auto
        operator==(const BlockFacts &) const -> bool = default;
    };

    /// Fixed-point result with diagnostics and optional block boundary facts.
    struct Result final
    {
        /// Invalid CFG or read-before-initialization diagnostics.
        std::vector<Issue> issues;
        /// Materialized entry and exit state for each reachable block.
        std::vector<BlockFacts> facts;
        /// Worklist counters for fixed-point analysis.
        WorklistStatistics statistics;

        /// Test whether input structure and all reachable reads are valid.
        /// @return true when the issue list is empty.
        [[nodiscard]] auto
        valid() const -> bool
        {
            return issues.empty();
        }
    };

    /// Controls materialization of the analysis boundary states.
    struct AnalysisOptions final
    {
        // Verifiers normally need diagnostics but not a complete copy of every
        // block boundary set. Clients such as tests and optimization passes can
        // retain the default materialized fact view.
        /// Keep per-block sets for diagnostics, tests, or later analyses.
        bool materializeFacts{ true };
    };

    /// Compute the forward must-initialization fixed point for one function.
    /// A value is initialized at a join only if every reachable predecessor
    /// provides it; declared block vector order is never execution order.
    /// @param function CFG, declarations, entry state, and access effects.
    /// @param options Select whether per-block state sets are retained.
    /// @return Initialization errors, optional block facts, and counters.
    [[nodiscard]] auto
    Analyze(const Function &function, AnalysisOptions options = {}) -> Result;
} // namespace Progmasoft::Tala::Analysis
