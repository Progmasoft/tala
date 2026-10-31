// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <map>
#include <ranges>
#include <set>
#include <tuple>

#include "Progmasoft/Tala/Analysis/ControlDependence.hpp"

namespace Progmasoft::Tala::Analysis
{
    namespace
    {
        using BlockSet = std::set<ControlFlowBlockId>;

        [[nodiscard]] auto
        PostDominatorChain(const DominanceResult &structure,
                           const ControlFlowBlockId start,
                           const std::optional<ControlFlowBlockId> stop)
            -> std::vector<ControlFlowBlockId>
        {
            std::vector<ControlFlowBlockId> result;
            BlockSet visited;
            auto current = std::optional<ControlFlowBlockId>{ start };
            while (current && current != stop
                   && visited.insert(*current).second)
            {
                result.push_back(*current);
                const auto *facts = FactsFor(structure, *current);
                current = facts == nullptr ? std::nullopt
                                           : facts->immediatePostDominator;
            }
            return result;
        }

        [[nodiscard]] auto
        BuildEdges(const DominanceResult &structure)
            -> std::vector<ControlDependenceEdge>
        {
            std::vector<ControlDependenceEdge> edges;
            for (const auto &controller : structure.controlFlow.facts)
            {
                if (!controller.reachable || controller.successors.size() < 2U)
                    continue;
                const auto *controllerFacts
                    = FactsFor(structure, controller.block);
                if (controllerFacts == nullptr)
                    continue;
                for (const auto successor : controller.successors)
                {
                    // A post-dominating successor executes regardless of the
                    // branch outcome and therefore contributes no dependency.
                    if (PostDominates(structure, successor, controller.block))
                        continue;
                    for (const auto dependent : PostDominatorChain(
                             structure,
                             successor,
                             controllerFacts->immediatePostDominator))
                        edges.push_back(
                            { controller.block, successor, dependent });
                }
            }
            std::ranges::sort(edges, [](const auto &left, const auto &right) {
                return std::tuple{ left.controller,
                                   left.successor,
                                   left.dependent }
                       < std::tuple{ right.controller,
                                     right.successor,
                                     right.dependent };
            });
            edges.erase(std::unique(edges.begin(), edges.end()), edges.end());
            return edges;
        }

        [[nodiscard]] auto
        BuildFacts(const DominanceResult &structure,
                   const std::vector<ControlDependenceEdge> &edges)
            -> std::vector<ControlDependenceBlockFacts>
        {
            std::map<ControlFlowBlockId, BlockSet> controllers;
            std::map<ControlFlowBlockId, BlockSet> dependents;
            for (const auto &block : structure.controlFlow.facts)
            {
                controllers.emplace(block.block, BlockSet{});
                dependents.emplace(block.block, BlockSet{});
            }
            for (const auto &edge : edges)
            {
                controllers.at(edge.dependent).insert(edge.controller);
                dependents.at(edge.controller).insert(edge.dependent);
            }

            std::vector<ControlDependenceBlockFacts> facts;
            facts.reserve(structure.controlFlow.facts.size());
            for (const auto &[block, controllerSet] : controllers)
                facts.push_back(
                    { block,
                      { controllerSet.begin(), controllerSet.end() },
                      { dependents.at(block).begin(),
                        dependents.at(block).end() } });
            return facts;
        }
    } // namespace

    auto
    AnalyzeControlDependence(const ControlFlowGraph &graph)
        -> ControlDependenceResult
    {
        ControlDependenceResult result;
        result.structure = AnalyzeDominance(graph);
        result.available = result.structure.hasPostDominance;
        if (result.available)
            result.edges = BuildEdges(result.structure);
        result.facts = BuildFacts(result.structure, result.edges);
        return result;
    }

    auto
    ControlDependenceFactsFor(const ControlDependenceResult &result,
                              const ControlFlowBlockId block)
        -> const ControlDependenceBlockFacts *
    {
        const auto found
            = std::ranges::lower_bound(result.facts,
                                       block,
                                       {},
                                       &ControlDependenceBlockFacts::block);
        return found != result.facts.end() && found->block == block ? &*found
                                                                    : nullptr;
    }
} // namespace Progmasoft::Tala::Analysis
