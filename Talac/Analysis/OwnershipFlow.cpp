// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <array>
#include <optional>
#include <unordered_map>
#include <utility>

#include "Progmasoft/Tala/Analysis/ControlFlow.hpp"
#include "Progmasoft/Tala/Analysis/DenseBitSet.hpp"
#include "Progmasoft/Tala/Analysis/OwnershipFlow.hpp"
#include "Progmasoft/Tala/Analysis/Worklist.hpp"

namespace Progmasoft::Tala::Analysis::OwnershipFlow
{
    namespace
    {
        using BlockMap = std::unordered_map<BlockId, const Block *>;
        using FlowFactMap
            = std::unordered_map<BlockId, const ControlFlowBlockFacts *>;

        struct HandleCatalog final
        {
            std::vector<HandleId> handles;
            std::unordered_map<HandleId, std::size_t> indices;

            [[nodiscard]] auto
            Find(const HandleId handle) const -> std::optional<std::size_t>
            {
                const auto found = indices.find(handle);
                return found == indices.end()
                           ? std::nullopt
                           : std::optional<std::size_t>{ found->second };
            }
        };

        // Ownership has five independent may-state bits. A structure-of-arrays
        // representation lets a predecessor join combine 64 handles per word
        // instead of visiting every handle and byte at every block.
        class PackedState final
        {
        public:
            PackedState() = default;

            explicit PackedState(const std::size_t handleCount,
                                 const StateMask initial = 0U)
                : handleCount_(handleCount)
                , states_{
                    DenseBitSet(handleCount), DenseBitSet(handleCount),
                    DenseBitSet(handleCount), DenseBitSet(handleCount),
                    DenseBitSet(handleCount),
                }
            {
                for (std::size_t bit = 0U; bit < states_.size(); ++bit)
                    if ((initial & (StateMask{ 1U } << bit)) != 0U)
                        states_[bit].Fill();
            }

            [[nodiscard]] auto
            At(const std::size_t index) const noexcept -> StateMask
            {
                if (index >= handleCount_)
                    return kAbsent;
                StateMask result{};
                for (std::size_t bit = 0U; bit < states_.size(); ++bit)
                    if (states_[bit].Test(index))
                        result = static_cast<StateMask>(
                            result | (StateMask{ 1U } << bit));
                return result;
            }

            void
            Assign(const std::size_t index, const StateMask value) noexcept
            {
                if (index >= handleCount_)
                    return;
                for (std::size_t bit = 0U; bit < states_.size(); ++bit)
                    states_[bit].Assign(index,
                                        (value & (StateMask{ 1U } << bit))
                                            != 0U);
            }

            void
            UnionWith(const PackedState &other)
            {
                for (std::size_t bit = 0U; bit < states_.size(); ++bit)
                    llvm::cantFail(states_[bit].UnionWith(other.states_[bit]));
            }

            [[nodiscard]] auto
            operator==(const PackedState &) const -> bool = default;

        private:
            std::size_t handleCount_{};
            std::array<DenseBitSet, 5U> states_;
        };

        using FactMap = std::unordered_map<BlockId, PackedState>;

        struct FixedPoint final
        {
            FactMap incoming;
            FactMap outgoing;
            WorklistStatistics statistics;
        };

        [[nodiscard]] auto
        LiveMask() noexcept -> StateMask
        {
            return static_cast<StateMask>(kStrong | kWeak | kUnowned);
        }

        [[nodiscard]] auto
        CatalogBlocks(const Function &function) -> BlockMap
        {
            BlockMap blocks;
            blocks.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
                blocks.try_emplace(block.id, &block);
            return blocks;
        }

        [[nodiscard]] auto
        ControlFlowFor(const Function &function) -> ControlFlowGraph
        {
            ControlFlowGraph graph;
            graph.entry = function.entry;
            graph.blocks.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
                graph.blocks.push_back({ block.id, block.successors });
            return graph;
        }

        void
        AppendControlFlowIssues(const Function &function,
                                const ControlFlowResult &controlFlow,
                                std::vector<Issue> &issues)
        {
            const auto blocks = CatalogBlocks(function);
            for (const auto &issue : controlFlow.issues)
            {
                auto kind = IssueKind::MissingEntry;
                switch (issue.kind)
                {
                    case ControlFlowIssueKind::DuplicateBlock:
                        kind = IssueKind::DuplicateBlock;
                        break;
                    case ControlFlowIssueKind::MissingEntry:
                        kind = IssueKind::MissingEntry;
                        break;
                    case ControlFlowIssueKind::MissingTarget:
                        kind = IssueKind::InvalidTarget;
                        break;
                }

                auto instruction = std::size_t{};
                auto terminator = false;
                if (issue.kind == ControlFlowIssueKind::MissingTarget)
                {
                    if (const auto found = blocks.find(issue.block);
                        found != blocks.end())
                        instruction = found->second->actions.size();
                    terminator = true;
                }
                issues.push_back({ kind,
                                   issue.block,
                                   instruction,
                                   terminator,
                                   0U,
                                   HandleKind::Strong,
                                   kAbsent });
            }
        }

        [[nodiscard]] auto
        FlowFacts(const ControlFlowResult &controlFlow) -> FlowFactMap
        {
            FlowFactMap facts;
            facts.reserve(controlFlow.facts.size());
            for (const auto &block : controlFlow.facts)
                facts.emplace(block.block, &block);
            return facts;
        }

        [[nodiscard]] auto
        BuildHandleCatalog(const Function &function) -> HandleCatalog
        {
            HandleCatalog catalog;
            catalog.handles.reserve(function.initialHandles.size());
            for (const auto &initial : function.initialHandles)
                if (initial.handle != 0U)
                    catalog.handles.push_back(initial.handle);
            for (const auto &block : function.blocks)
                for (const auto &action : block.actions)
                    if (action.handle != 0U)
                        catalog.handles.push_back(action.handle);

            std::ranges::sort(catalog.handles);
            catalog.handles.erase(
                std::unique(catalog.handles.begin(), catalog.handles.end()),
                catalog.handles.end());
            catalog.indices.reserve(catalog.handles.size());
            for (std::size_t index = 0U; index < catalog.handles.size();
                 ++index)
                catalog.indices.emplace(catalog.handles[index], index);
            return catalog;
        }

        [[nodiscard]] auto
        InitialState(const Function &function,
                     const HandleCatalog &catalog,
                     std::vector<Issue> &issues) -> PackedState
        {
            PackedState states(catalog.handles.size(), kAbsent);
            for (const auto &initial : function.initialHandles)
            {
                if (initial.handle == 0U)
                {
                    issues.push_back({ IssueKind::InvalidInitialHandle,
                                       function.entry,
                                       0U,
                                       false,
                                       0U,
                                       initial.kind,
                                       kAbsent });
                    continue;
                }

                const auto index = catalog.Find(initial.handle);
                if (!index)
                    continue;
                const auto expected = StateFor(initial.kind);
                const auto actual = states.At(*index);
                if (actual != kAbsent && actual != expected)
                    issues.push_back({ IssueKind::ConflictingInitialKind,
                                       function.entry,
                                       0U,
                                       false,
                                       initial.handle,
                                       initial.kind,
                                       actual });
                states.Assign(
                    *index,
                    static_cast<StateMask>((actual == kAbsent ? 0U : actual)
                                           | expected));
            }
            return states;
        }

        void
        Apply(const Action &action,
              const HandleCatalog &catalog,
              PackedState &states)
        {
            const auto index = catalog.Find(action.handle);
            if (!index)
                return;

            auto actual = states.At(*index);
            switch (action.kind)
            {
                case ActionKind::Observe:
                    break;
                case ActionKind::Consume:
                {
                    const auto expected = StateFor(action.expected);
                    if ((actual & expected) != 0U)
                    {
                        actual = static_cast<StateMask>(actual & ~expected);
                        actual = static_cast<StateMask>(actual | kConsumed);
                        states.Assign(*index, actual);
                    }
                    break;
                }
                case ActionKind::Define:
                    states.Assign(*index, StateFor(action.expected));
                    break;
                case ActionKind::Forget:
                    states.Assign(*index, kAbsent);
                    break;
            }
        }

        [[nodiscard]] auto
        Transfer(const Block &block,
                 const HandleCatalog &catalog,
                 PackedState incoming) -> PackedState
        {
            for (const auto &action : block.actions)
                Apply(action, catalog, incoming);
            return incoming;
        }

        [[nodiscard]] auto
        JoinPredecessors(const BlockId block,
                         const Function &function,
                         const FlowFactMap &flowFacts,
                         const HandleCatalog &catalog,
                         const PackedState &initial,
                         const FactMap &outgoing) -> PackedState
        {
            // Entry facts are fixed by the external caller. A backedge cannot
            // retroactively manufacture an initial ownership token.
            if (block == function.entry)
                return initial;

            const auto fact = flowFacts.find(block);
            if (fact == flowFacts.end() || fact->second->predecessors.empty())
                return PackedState(catalog.handles.size(), kAbsent);

            PackedState joined(catalog.handles.size());
            for (const auto predecessor : fact->second->predecessors)
            {
                const auto predecessorState = outgoing.find(predecessor);
                if (predecessorState != outgoing.end())
                    joined.UnionWith(predecessorState->second);
            }
            return joined;
        }

        [[nodiscard]] auto
        ComputeFixedPoint(const Function &function,
                          const BlockMap &blocks,
                          const ControlFlowResult &controlFlow,
                          const HandleCatalog &catalog,
                          const PackedState &initial) -> FixedPoint
        {
            FixedPoint result;
            result.incoming.reserve(controlFlow.preorder.size());
            result.outgoing.reserve(controlFlow.preorder.size());
            for (const auto block : controlFlow.preorder)
            {
                result.incoming.emplace(block,
                                        PackedState(catalog.handles.size()));
                result.outgoing.emplace(block,
                                        PackedState(catalog.handles.size()));
            }

            const auto flowFacts = FlowFacts(controlFlow);
            DataflowWorklist worklist(controlFlow, WorklistDirection::Forward);
            while (const auto block = worklist.Next())
            {
                auto nextIncoming = JoinPredecessors(*block,
                                                     function,
                                                     flowFacts,
                                                     catalog,
                                                     initial,
                                                     result.outgoing);
                auto nextOutgoing
                    = Transfer(*blocks.at(*block), catalog, nextIncoming);
                if (result.incoming.at(*block) == nextIncoming
                    && result.outgoing.at(*block) == nextOutgoing)
                    continue;

                result.incoming[*block] = std::move(nextIncoming);
                result.outgoing[*block] = std::move(nextOutgoing);
                worklist.NotifyChanged(*block);
            }
            result.statistics = worklist.Statistics();
            return result;
        }

        [[nodiscard]] auto
        HasOtherLiveKind(const StateMask actual,
                         const StateMask expected) noexcept -> bool
        {
            return (actual & LiveMask() & ~expected) != 0U;
        }

        void
        ValidateRequirement(const Action &action,
                            const BlockId block,
                            const StateMask actual,
                            std::vector<Issue> &issues)
        {
            const auto expected = StateFor(action.expected);
            const auto hasExpected = (actual & expected) != 0U;
            const auto hasConsumed = Contains(actual, kConsumed);
            const auto hasAbsent = Contains(actual, kAbsent);
            const auto hasOtherKind = HasOtherLiveKind(actual, expected);

            if (hasExpected && (hasConsumed || hasAbsent || hasOtherKind))
                issues.push_back({ IssueKind::PathStateMismatch,
                                   block,
                                   action.instruction,
                                   action.terminator,
                                   action.handle,
                                   action.expected,
                                   actual });
            else if (!hasExpected && hasConsumed)
                issues.push_back({ IssueKind::UseAfterConsume,
                                   block,
                                   action.instruction,
                                   action.terminator,
                                   action.handle,
                                   action.expected,
                                   actual });
            else if (!hasExpected && hasOtherKind)
                issues.push_back({ IssueKind::HandleKindMismatch,
                                   block,
                                   action.instruction,
                                   action.terminator,
                                   action.handle,
                                   action.expected,
                                   actual });
            // Definite initialization owns absent-only diagnostics.
        }

        void
        ValidateActions(const BlockMap &blocks,
                        const ControlFlowResult &controlFlow,
                        const HandleCatalog &catalog,
                        const FactMap &incoming,
                        std::vector<Issue> &issues)
        {
            for (const auto blockId : controlFlow.preorder)
            {
                const auto &block = *blocks.at(blockId);
                auto state = incoming.at(blockId);
                for (const auto &action : block.actions)
                {
                    if (action.handle == 0U)
                    {
                        issues.push_back({ IssueKind::InvalidActionHandle,
                                           block.id,
                                           action.instruction,
                                           action.terminator,
                                           0U,
                                           action.expected,
                                           kAbsent });
                        continue;
                    }
                    const auto index = catalog.Find(action.handle);
                    if (!index)
                        continue;
                    if (action.kind == ActionKind::Observe
                        || action.kind == ActionKind::Consume)
                        ValidateRequirement(action,
                                            block.id,
                                            state.At(*index),
                                            issues);
                    Apply(action, catalog, state);
                }
            }
        }

        [[nodiscard]] auto
        VisibleFacts(const HandleCatalog &catalog, const PackedState &states)
            -> std::vector<HandleFact>
        {
            std::vector<HandleFact> facts;
            facts.reserve(catalog.handles.size());
            for (std::size_t index = 0U; index < catalog.handles.size();
                 ++index)
            {
                const auto state = states.At(index);
                facts.push_back(
                    { catalog.handles[index],
                      state == 0U ? static_cast<StateMask>(kAbsent) : state });
            }
            return facts;
        }

        [[nodiscard]] auto
        BuildFacts(const ControlFlowResult &controlFlow,
                   const HandleCatalog &catalog,
                   const FactMap &incoming,
                   const FactMap &outgoing) -> std::vector<BlockFacts>
        {
            const PackedState unreachable(catalog.handles.size(), kAbsent);
            std::vector<BlockFacts> facts;
            facts.reserve(controlFlow.facts.size());
            for (const auto &flow : controlFlow.facts)
            {
                facts.push_back(
                    { flow.block,
                      flow.reachable,
                      VisibleFacts(catalog,
                                   flow.reachable ? incoming.at(flow.block)
                                                  : unreachable),
                      VisibleFacts(catalog,
                                   flow.reachable ? outgoing.at(flow.block)
                                                  : unreachable) });
            }
            return facts;
        }
    } // namespace

    auto
    StateFor(const HandleKind kind) noexcept -> StateMask
    {
        switch (kind)
        {
            case HandleKind::Strong:
                return kStrong;
            case HandleKind::Weak:
                return kWeak;
            case HandleKind::Unowned:
                return kUnowned;
        }
        return kAbsent;
    }

    auto
    Contains(const StateMask states, const StateMask state) noexcept -> bool
    {
        return (states & static_cast<StateMask>(state)) != 0U;
    }

    auto
    IsExactly(const StateMask states, const HandleKind kind) noexcept -> bool
    {
        return states == StateFor(kind);
    }

    auto
    Analyze(const Function &function, const AnalysisOptions options) -> Result
    {
        Result result;
        const auto blocks = CatalogBlocks(function);
        const auto controlFlow = AnalyzeControlFlow(ControlFlowFor(function));
        AppendControlFlowIssues(function, controlFlow, result.issues);
        const auto catalog = BuildHandleCatalog(function);
        const auto initial = InitialState(function, catalog, result.issues);
        const auto fixedPoint = ComputeFixedPoint(function,
                                                  blocks,
                                                  controlFlow,
                                                  catalog,
                                                  initial);

        ValidateActions(blocks,
                        controlFlow,
                        catalog,
                        fixedPoint.incoming,
                        result.issues);
        if (options.materializeFacts)
            result.facts = BuildFacts(controlFlow,
                                      catalog,
                                      fixedPoint.incoming,
                                      fixedPoint.outgoing);
        result.statistics = fixedPoint.statistics;
        return result;
    }
} // namespace Progmasoft::Tala::Analysis::OwnershipFlow
