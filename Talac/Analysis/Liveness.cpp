// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <ranges>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#include "Progmasoft/Tala/Analysis/DenseBitSet.hpp"
#include "Progmasoft/Tala/Analysis/Liveness.hpp"
#include "Progmasoft/Tala/Analysis/Worklist.hpp"

namespace Progmasoft::Tala::Analysis::Liveness
{
    namespace
    {
        using BlockMap = std::unordered_map<BlockId, const Block *>;
        using FactMap = std::unordered_map<BlockId, DenseBitSet>;
        using FlowFactMap
            = std::unordered_map<BlockId, const ControlFlowBlockFacts *>;

        struct StorageCatalog final
        {
            std::vector<StorageId> storage;
            std::unordered_map<StorageId, std::size_t> indices;

            [[nodiscard]] auto
            Find(const StorageId value) const -> std::size_t
            {
                return indices.at(value);
            }
        };

        [[nodiscard]] auto
        BuildStorageCatalog(const Function &function) -> StorageCatalog
        {
            StorageCatalog catalog;
            for (const auto &block : function.blocks)
            {
                for (const auto &access : block.accesses)
                {
                    catalog.storage.insert(catalog.storage.end(),
                                           access.reads.begin(),
                                           access.reads.end());
                    if (access.write)
                        catalog.storage.push_back(*access.write);
                }
            }

            // Stage identities are sparse 64-bit values, not array indices.
            // Sorting once gives stable dense positions without constraining
            // the SymbolId or virtual-register allocator used by either
            // consumer.
            std::ranges::sort(catalog.storage);
            const auto unique = std::ranges::unique(catalog.storage);
            catalog.storage.erase(unique.begin(), unique.end());
            catalog.indices.reserve(catalog.storage.size());
            for (std::size_t index = 0U; index < catalog.storage.size();
                 ++index)
                catalog.indices.emplace(catalog.storage[index], index);
            return catalog;
        }

        [[nodiscard]] auto
        Visible(const StorageCatalog &catalog, const DenseBitSet &values)
            -> std::vector<StorageId>
        {
            std::vector<StorageId> result;
            for (const auto index : values.SetIndices())
                result.push_back(catalog.storage[index]);
            return result;
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
        CatalogFlowFacts(const ControlFlowResult &flow) -> FlowFactMap
        {
            FlowFactMap facts;
            facts.reserve(flow.facts.size());
            for (const auto &block : flow.facts)
                facts.emplace(block.block, &block);
            return facts;
        }

        [[nodiscard]] auto
        Apply(const Access &access,
              const StorageCatalog &catalog,
              DenseBitSet live) -> DenseBitSet
        {
            if (access.write)
            {
                const auto destination = catalog.Find(*access.write);
                // A removable dead definition is semantically absent. Its
                // operands therefore cannot retain an otherwise dead producer.
                if (access.removable && !live.Test(destination))
                    return live;
                live.Reset(destination);
            }
            for (const auto read : access.reads)
                live.Set(catalog.Find(read));
            return live;
        }

        [[nodiscard]] auto
        Transfer(const Block &block,
                 const StorageCatalog &catalog,
                 DenseBitSet live) -> DenseBitSet
        {
            for (const auto &access : std::views::reverse(block.accesses))
                live = Apply(access, catalog, std::move(live));
            return live;
        }

        [[nodiscard]] auto
        ExitFacts(const ControlFlowBlockFacts &block,
                  const FactMap &incoming,
                  const std::size_t storageCount) -> DenseBitSet
        {
            DenseBitSet live(storageCount);
            for (const auto successor : block.successors)
                if (const auto found = incoming.find(successor);
                    found != incoming.end())
                    llvm::cantFail(live.UnionWith(found->second));
            return live;
        }

        [[nodiscard]] auto
        ComputeFixedPoint(const ControlFlowResult &flow,
                          const BlockMap &blocks,
                          const StorageCatalog &catalog,
                          FactMap &incoming,
                          FactMap &outgoing) -> WorklistStatistics
        {
            const auto flowFacts = CatalogFlowFacts(flow);
            incoming.reserve(flow.preorder.size());
            outgoing.reserve(flow.preorder.size());
            for (const auto block : flow.preorder)
            {
                incoming.emplace(block, DenseBitSet(catalog.storage.size()));
                outgoing.emplace(block, DenseBitSet(catalog.storage.size()));
            }

            DataflowWorklist worklist(flow, WorklistDirection::Backward);
            while (const auto block = worklist.Next())
            {
                auto nextOutgoing = ExitFacts(*flowFacts.at(*block),
                                              incoming,
                                              catalog.storage.size());
                auto nextIncoming
                    = Transfer(*blocks.at(*block), catalog, nextOutgoing);
                if (incoming.at(*block) == nextIncoming
                    && outgoing.at(*block) == nextOutgoing)
                    continue;

                incoming.at(*block) = std::move(nextIncoming);
                outgoing.at(*block) = std::move(nextOutgoing);
                worklist.NotifyChanged(*block);
            }
            return worklist.Statistics();
        }

        [[nodiscard]] auto
        BuildAccessFacts(const Block &block,
                         const StorageCatalog &catalog,
                         DenseBitSet live,
                         const bool materializeLiveSets)
            -> std::vector<AccessFacts>
        {
            std::vector<AccessFacts> reversed;
            reversed.reserve(block.accesses.size());
            for (const auto &access : std::views::reverse(block.accesses))
            {
                auto liveAfter = materializeLiveSets ? Visible(catalog, live)
                                                     : std::vector<StorageId>{};
                const auto retained = !access.write || !access.removable
                                      || live.Test(catalog.Find(*access.write));
                if (retained)
                    live = Apply(access, catalog, std::move(live));
                reversed.push_back({
                    access.instruction,
                    access.terminator,
                    retained,
                    materializeLiveSets ? Visible(catalog, live)
                                        : std::vector<StorageId>{},
                    std::move(liveAfter),
                });
            }
            return { reversed.rbegin(), reversed.rend() };
        }

        [[nodiscard]] auto
        BuildFacts(const Function &function,
                   const ControlFlowResult &flow,
                   const StorageCatalog &catalog,
                   const FactMap &incoming,
                   const FactMap &outgoing,
                   const bool materializeLiveSets) -> std::vector<BlockFacts>
        {
            const std::unordered_set<BlockId> reachable(flow.preorder.begin(),
                                                        flow.preorder.end());
            std::vector<BlockFacts> facts;
            facts.reserve(function.blocks.size());
            std::unordered_set<BlockId> emitted;
            for (const auto &block : function.blocks)
            {
                // ControlFlow reports duplicate identities. Exposing one fact
                // record keeps malformed input deterministic and prevents an
                // optimizer from applying contradictory removal decisions.
                if (!emitted.insert(block.id).second)
                    continue;
                const auto isReachable = reachable.contains(block.id);
                if (!isReachable)
                {
                    std::vector<AccessFacts> accessFacts;
                    accessFacts.reserve(block.accesses.size());
                    for (const auto &access : block.accesses)
                        accessFacts.push_back({ access.instruction,
                                                access.terminator,
                                                true,
                                                {},
                                                {} });
                    facts.push_back(
                        { block.id, false, {}, {}, std::move(accessFacts) });
                    continue;
                }
                facts.push_back({
                    block.id,
                    true,
                    materializeLiveSets
                        ? Visible(catalog, incoming.at(block.id))
                        : std::vector<StorageId>{},
                    materializeLiveSets
                        ? Visible(catalog, outgoing.at(block.id))
                        : std::vector<StorageId>{},
                    BuildAccessFacts(block,
                                     catalog,
                                     outgoing.at(block.id),
                                     materializeLiveSets),
                });
            }
            std::ranges::sort(facts, {}, &BlockFacts::block);
            return facts;
        }
    } // namespace

    auto
    Analyze(const Function &function, const AnalysisOptions options) -> Result
    {
        const auto flow = AnalyzeControlFlow(ControlFlowFor(function));
        Result result;
        result.issues = flow.issues;
        const auto blocks = CatalogBlocks(function);
        const auto catalog = BuildStorageCatalog(function);
        FactMap incoming;
        FactMap outgoing;
        result.statistics
            = ComputeFixedPoint(flow, blocks, catalog, incoming, outgoing);
        result.facts = BuildFacts(function,
                                  flow,
                                  catalog,
                                  incoming,
                                  outgoing,
                                  options.materializeLiveSets);
        return result;
    }
} // namespace Progmasoft::Tala::Analysis::Liveness
