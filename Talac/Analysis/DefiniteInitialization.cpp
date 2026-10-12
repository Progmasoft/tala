// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <optional>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#include "Progmasoft/Tala/Analysis/ControlFlow.hpp"
#include "Progmasoft/Tala/Analysis/DefiniteInitialization.hpp"
#include "Progmasoft/Tala/Analysis/DenseBitSet.hpp"
#include "Progmasoft/Tala/Analysis/Worklist.hpp"

namespace Progmasoft::Tala::Analysis
{
    namespace
    {
        using BlockMap = std::unordered_map<BlockId, const Block *>;
        using FlowFactMap
            = std::unordered_map<BlockId, const ControlFlowBlockFacts *>;
        using FactMap = std::unordered_map<BlockId, DenseBitSet>;

        struct StorageCatalog final
        {
            std::vector<StorageId> storage;
            std::unordered_map<StorageId, std::size_t> indices;

            [[nodiscard]] auto
            Find(const StorageId value) const -> std::optional<std::size_t>
            {
                const auto found = indices.find(value);
                return found == indices.end()
                           ? std::nullopt
                           : std::optional<std::size_t>{ found->second };
            }
        };

        struct FixedPoint final
        {
            FactMap incoming;
            FactMap outgoing;
            WorklistStatistics statistics;
        };

        [[nodiscard]] auto
        BuildStorageCatalog(const Function &function,
                            std::vector<Issue> &issues) -> StorageCatalog
        {
            StorageCatalog catalog;
            catalog.storage.reserve(function.declarations.size());
            std::unordered_set<StorageId> unique;
            unique.reserve(function.declarations.size());
            for (const auto storage : function.declarations)
            {
                if (!unique.insert(storage).second)
                {
                    issues.push_back({ IssueKind::DuplicateDeclaration,
                                       function.entry,
                                       0U,
                                       false,
                                       storage,
                                       0U });
                    continue;
                }
                catalog.storage.push_back(storage);
            }

            // A sorted catalog makes dense bit positions deterministic. Facts
            // can then be materialized without a second per-block sort.
            std::ranges::sort(catalog.storage);
            catalog.indices.reserve(catalog.storage.size());
            for (std::size_t index = 0U; index < catalog.storage.size();
                 ++index)
                catalog.indices.emplace(catalog.storage[index], index);
            return catalog;
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
                auto instruction = std::size_t{};
                auto terminator = false;
                if (issue.kind == ControlFlowIssueKind::MissingTarget)
                {
                    if (const auto found = blocks.find(issue.block);
                        found != blocks.end())
                        instruction = found->second->accesses.size();
                    terminator = true;
                }

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
                        kind = IssueKind::MissingTarget;
                        break;
                }
                issues.push_back({ kind,
                                   issue.block,
                                   instruction,
                                   terminator,
                                   0U,
                                   issue.target });
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
        InitialStorage(const Function &function,
                       const StorageCatalog &catalog,
                       std::vector<Issue> &issues) -> DenseBitSet
        {
            DenseBitSet initialized(catalog.storage.size());
            for (const auto storage : function.initiallyInitialized)
            {
                const auto index = catalog.Find(storage);
                if (!index)
                {
                    issues.push_back({ IssueKind::UnknownInitialStorage,
                                       function.entry,
                                       0U,
                                       false,
                                       storage,
                                       0U });
                    continue;
                }
                initialized.Set(*index);
            }
            return initialized;
        }

        [[nodiscard]] auto
        TransferWrites(const Block &block,
                       const StorageCatalog &catalog,
                       DenseBitSet initialized) -> DenseBitSet
        {
            for (const auto &access : block.accesses)
                if (access.write)
                    if (const auto index = catalog.Find(*access.write))
                        initialized.Set(*index);
            return initialized;
        }

        [[nodiscard]] auto
        IncomingFacts(const BlockId block,
                      const Function &function,
                      const FlowFactMap &flowFacts,
                      const StorageCatalog &catalog,
                      const DenseBitSet &initial,
                      const FactMap &outgoing) -> DenseBitSet
        {
            // The entry represents the external call edge. Backedges never add
            // initialization to the first invocation.
            if (block == function.entry)
                return initial;

            const auto fact = flowFacts.find(block);
            if (fact == flowFacts.end() || fact->second->predecessors.empty())
                return DenseBitSet(catalog.storage.size());

            bool first = true;
            DenseBitSet incoming(catalog.storage.size());
            for (const auto predecessor : fact->second->predecessors)
            {
                const auto predecessorFacts = outgoing.find(predecessor);
                if (predecessorFacts == outgoing.end())
                    continue;
                if (first)
                {
                    incoming = predecessorFacts->second;
                    first = false;
                }
                else
                    llvm::cantFail(
                        incoming.IntersectWith(predecessorFacts->second));
            }
            return incoming;
        }

        [[nodiscard]] auto
        ComputeFixedPoint(const Function &function,
                          const BlockMap &blocks,
                          const ControlFlowResult &controlFlow,
                          const StorageCatalog &catalog,
                          const DenseBitSet &initial) -> FixedPoint
        {
            FixedPoint result;
            result.incoming.reserve(controlFlow.preorder.size());
            result.outgoing.reserve(controlFlow.preorder.size());

            // Must-analysis top is every declared storage bit. One machine word
            // carries 64 declarations, so joins no longer hash and copy each
            // SymbolId/register individually at every block.
            const DenseBitSet top(catalog.storage.size(), true);
            for (const auto block : controlFlow.preorder)
            {
                auto incoming = block == function.entry ? initial : top;
                result.outgoing.emplace(
                    block,
                    TransferWrites(*blocks.at(block), catalog, incoming));
                result.incoming.emplace(block, std::move(incoming));
            }

            const auto flowFacts = FlowFacts(controlFlow);
            DataflowWorklist worklist(controlFlow, WorklistDirection::Forward);
            while (const auto block = worklist.Next())
            {
                auto nextIncoming = IncomingFacts(*block,
                                                  function,
                                                  flowFacts,
                                                  catalog,
                                                  initial,
                                                  result.outgoing);
                auto nextOutgoing
                    = TransferWrites(*blocks.at(*block), catalog, nextIncoming);
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

        void
        ValidateAccesses(const BlockMap &blocks,
                         const ControlFlowResult &controlFlow,
                         const StorageCatalog &catalog,
                         const FactMap &incoming,
                         std::vector<Issue> &issues)
        {
            for (const auto blockId : controlFlow.preorder)
            {
                const auto &block = *blocks.at(blockId);
                auto initialized = incoming.at(blockId);
                for (const auto &access : block.accesses)
                {
                    for (const auto storage : access.reads)
                    {
                        const auto index = catalog.Find(storage);
                        if (!index)
                            issues.push_back({ IssueKind::UnknownReadStorage,
                                               block.id,
                                               access.instruction,
                                               access.terminator,
                                               storage,
                                               0U });
                        else if (!initialized.Test(*index))
                            issues.push_back(
                                { IssueKind::ReadBeforeInitialization,
                                  block.id,
                                  access.instruction,
                                  access.terminator,
                                  storage,
                                  0U });
                    }

                    const auto write = access.write;
                    if (!write)
                        continue;
                    const auto index = catalog.Find(*write);
                    if (!index)
                        issues.push_back({ IssueKind::UnknownWriteStorage,
                                           block.id,
                                           access.instruction,
                                           access.terminator,
                                           *write,
                                           0U });
                    else
                        initialized.Set(*index);
                }
            }
        }

        [[nodiscard]] auto
        VisibleStorage(const StorageCatalog &catalog, const DenseBitSet &bits)
            -> std::vector<StorageId>
        {
            const auto indices = bits.SetIndices();
            std::vector<StorageId> storage;
            storage.reserve(indices.size());
            for (const auto index : indices)
                storage.push_back(catalog.storage[index]);
            return storage;
        }

        [[nodiscard]] auto
        BuildFacts(const ControlFlowResult &controlFlow,
                   const StorageCatalog &catalog,
                   const FactMap &incoming,
                   const FactMap &outgoing) -> std::vector<BlockFacts>
        {
            std::vector<BlockFacts> facts;
            facts.reserve(controlFlow.facts.size());
            for (const auto &flow : controlFlow.facts)
            {
                facts.push_back(
                    { flow.block,
                      flow.reachable,
                      flow.reachable
                          ? VisibleStorage(catalog, incoming.at(flow.block))
                          : std::vector<StorageId>{},
                      flow.reachable
                          ? VisibleStorage(catalog, outgoing.at(flow.block))
                          : std::vector<StorageId>{} });
            }
            return facts;
        }
    } // namespace

    auto
    Analyze(const Function &function, const AnalysisOptions options) -> Result
    {
        Result result;
        const auto catalog = BuildStorageCatalog(function, result.issues);
        const auto blocks = CatalogBlocks(function);
        const auto controlFlow = AnalyzeControlFlow(ControlFlowFor(function));
        AppendControlFlowIssues(function, controlFlow, result.issues);
        const auto initial = InitialStorage(function, catalog, result.issues);
        const auto fixedPoint = ComputeFixedPoint(function,
                                                  blocks,
                                                  controlFlow,
                                                  catalog,
                                                  initial);

        ValidateAccesses(blocks,
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
} // namespace Progmasoft::Tala::Analysis
