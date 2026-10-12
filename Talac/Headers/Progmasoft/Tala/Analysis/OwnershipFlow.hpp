// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "Progmasoft/Tala/Analysis/Worklist.hpp"

namespace Progmasoft::Tala::Analysis::OwnershipFlow
{
    /// Identity width used by the shared control-flow ownership model.
    using BlockId = std::uint32_t;
    // Xpp symbols are 64-bit while Xmm registers are 32-bit. The common
    // analysis uses the wider identity so adapters never truncate a valid
    // source symbol.
    using HandleId = std::uint64_t;

    // Xpp and Xmm intentionally erase source-level weak/unowned syntax from the
    // value type. HandleKind restores the runtime representation distinction
    // for dataflow without leaking AARC details into the general Type model.
    enum class HandleKind : std::uint8_t
    {
        Strong, ///< Owns one strong reference-count token.
        Weak,   ///< Observes an allocation through the weak control block.
        Unowned ///< Borrows a reference without extending its lifetime.
    };

    enum class ActionKind : std::uint8_t
    {
        Observe, ///< Require a live token without changing its ownership state.
        Consume, ///< Release a token; every path must contain one matching
                 ///< token.
        Define,  ///< Replace the destination's abstract ownership state.
        Forget   ///< Stop tracking storage reused for a non-AARC value.
    };

    /// One ownership-sensitive use or definition at an instruction boundary.
    struct Action final
    {
        /// Kind of abstract ownership transfer represented by this action.
        ActionKind kind{ ActionKind::Observe };
        /// Storage identity read, consumed, defined, or forgotten.
        HandleId handle{};
        /// Ownership kind required by an observation or consumption.
        HandleKind expected{ HandleKind::Strong };
        /// Zero-based instruction index within the containing block.
        std::size_t instruction{};
        /// Whether the action belongs to the block terminator instead.
        bool terminator{};

        /// Compare action location and ownership transfer semantics.
        /// @return true when all action fields are equal.
        [[nodiscard]] auto
        operator==(const Action &) const -> bool = default;
    };

    /// Basic block in the stage-neutral ownership control-flow input.
    struct Block final
    {
        /// Unique identity within the function.
        BlockId id{};
        /// Successor blocks in declared branch order.
        std::vector<BlockId> successors;
        /// Ownership operations in program order.
        std::vector<Action> actions;

        /// Compare block identity, edges, and ordered actions.
        /// @return true when the block descriptions are identical.
        [[nodiscard]] auto
        operator==(const Block &) const -> bool = default;
    };

    /// Ownership handle known to be live at function entry.
    struct InitialHandle final
    {
        /// Storage identity of the incoming handle.
        HandleId handle{};
        /// Ownership representation carried by the incoming value.
        HandleKind kind{ HandleKind::Strong };

        /// Compare identity and initial ownership kind.
        /// @return true when both initial-handle descriptions match.
        [[nodiscard]] auto
        operator==(const InitialHandle &) const -> bool = default;
    };

    /// CFG and entry state for one function's ownership analysis.
    struct Function final
    {
        /// Entry block identity.
        BlockId entry{};
        /// Handles supplied live at entry, before the first action.
        std::vector<InitialHandle> initialHandles;
        /// Function blocks; identities and edges define execution structure.
        std::vector<Block> blocks;

        /// Compare complete input functions, including presentation order.
        /// @return true when entry state and block vectors match.
        [[nodiscard]] auto
        operator==(const Function &) const -> bool = default;
    };

    /// Bit set of ownership states that may reach one program point.
    using StateMask = std::uint8_t;

    /// State mask bit indicating that the handle has no live token.
    inline constexpr StateMask kAbsent = 1U << 0U;
    /// State mask bit indicating a live strong token.
    inline constexpr StateMask kStrong = 1U << 1U;
    /// State mask bit indicating a weak handle state.
    inline constexpr StateMask kWeak = 1U << 2U;
    /// State mask bit indicating an unowned borrow state.
    inline constexpr StateMask kUnowned = 1U << 3U;
    /// State mask bit indicating that the ownership token was consumed.
    inline constexpr StateMask kConsumed = 1U << 4U;

    /// Abstract ownership states reaching a particular handle at a block edge.
    struct HandleFact final
    {
        /// Handle identity summarized by this fact.
        HandleId handle{};
        /// Union of possible states across all reachable paths.
        StateMask states{ kAbsent };

        /// Compare a handle identity and its possible ownership states.
        /// @return true when both facts are equal.
        [[nodiscard]] auto
        operator==(const HandleFact &) const -> bool = default;
    };

    /// Incoming and outgoing abstract states for one reachable block.
    struct BlockFacts final
    {
        /// Block identity summarized by these facts.
        BlockId block{};
        /// Whether this block is reachable from the function entry.
        bool reachable{};
        /// Sorted handle states before the first block action.
        std::vector<HandleFact> incoming;
        /// Sorted handle states after the final block action.
        std::vector<HandleFact> outgoing;

        /// Compare reachability and both boundary state maps.
        /// @return true when the block facts match exactly.
        [[nodiscard]] auto
        operator==(const BlockFacts &) const -> bool = default;
    };

    enum class IssueKind : std::uint8_t
    {
        DuplicateBlock,         ///< Multiple block records use one identity.
        MissingEntry,           ///< The declared entry block is absent.
        InvalidTarget,          ///< An edge targets an undefined block.
        InvalidInitialHandle,   ///< Entry state repeats one handle identity.
        ConflictingInitialKind, ///< One handle has conflicting entry kinds.
        InvalidActionHandle,    ///< An action refers to an invalid identity.
        UseAfterConsume,        ///< A path observes a token after its release.
        HandleKindMismatch, ///< The live token kind differs from expectation.
        PathStateMismatch   ///< A join permits incompatible path states.
    };

    /// Diagnostic location and state details for an ownership violation.
    struct Issue final
    {
        /// Category of invalid ownership behavior or malformed input.
        IssueKind kind{ IssueKind::InvalidActionHandle };
        /// Block containing the offending action.
        BlockId block{};
        /// Instruction index for an instruction-level action.
        std::size_t instruction{};
        /// Whether the issue was observed at the block terminator.
        bool terminator{};
        /// Handle identity involved in the violation.
        HandleId handle{};
        /// Ownership kind required at this use, when applicable.
        HandleKind expected{ HandleKind::Strong };
        /// Union of abstract states that actually reached the use.
        StateMask actual{ kAbsent };

        /// Compare issue category, program point, and ownership state data.
        /// @return true when both diagnostics identify the same issue.
        [[nodiscard]] auto
        operator==(const Issue &) const -> bool = default;
    };

    /// Fixed-point output, optional boundary facts, and scheduler counters.
    struct Result final
    {
        /// Materialized block facts when requested by analysis options.
        std::vector<BlockFacts> facts;
        /// All structural and ownership-state errors in deterministic order.
        std::vector<Issue> issues;
        /// Worklist effort used to reach the fixed point.
        WorklistStatistics statistics;

        /// Compare semantic outputs, intentionally excluding scheduler cost.
        /// @param other Result to compare against.
        /// @return true when facts and diagnostics match.
        [[nodiscard]] auto
        operator==(const Result &other) const -> bool
        {
            // Scheduler statistics describe evaluation cost, not semantic
            // facts. Presentation-order invariance tests compare only
            // observable analysis meaning so a different but valid queue path
            // cannot change equality.
            return facts == other.facts && issues == other.issues;
        }
    };

    /// Controls how much intermediate state the analysis retains.
    struct AnalysisOptions final
    {
        // Full block facts are useful for diagnostics tooling and tests but can
        // dominate verification time for large functions. Stage verifiers ask
        // only for issues and scheduler statistics.
        /// Retain per-block boundary facts for inspection and diagnostics.
        bool materializeFacts{ true };
    };

    /// Convert an ownership representation into its corresponding state bit.
    /// @param kind Handle representation being encoded.
    /// @return The singleton mask for that representation.
    [[nodiscard]] auto
    StateFor(HandleKind kind) noexcept -> StateMask;

    [[nodiscard]] auto
    Contains(StateMask states, StateMask state) noexcept -> bool;

    [[nodiscard]] auto
    IsExactly(StateMask states, HandleKind kind) noexcept -> bool;

    /// Compute the forward may-state fixed point for ownership handles.
    /// Join points union all reachable states so a consumed or mismatched path
    /// cannot be hidden by a different predecessor's valid state.
    /// @param function CFG and ownership actions to analyze.
    /// @param options Select whether full block facts are materialized.
    /// @return Issues, optional facts, and scheduler statistics.
    [[nodiscard]] auto
    Analyze(const Function &function, AnalysisOptions options = {}) -> Result;
} // namespace Progmasoft::Tala::Analysis::OwnershipFlow
  /// Test whether a state mask includes a particular state bit.
  /// @param states Union of possible states.
  /// @param state State bit to test.
  /// @return true when state is present in states.
  /// Test whether a mask contains exactly one requested live handle state.
  /// @param states Union of possible states.
  /// @param kind Expected ownership representation.
  /// @return true when states contains only the matching live state.
