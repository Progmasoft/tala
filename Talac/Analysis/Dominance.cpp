// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <iterator>
#include <map>
#include <ranges>
#include <set>
#include <unordered_set>
#include <utility>

#include "Progmasoft/Tala/Analysis/Dominance.hpp"

namespace Progmasoft::Tala::Analysis
{
    namespace
    {
        using BlockSet = std::set<ControlFlowBlockId>;
        using BlockSets = std::map<ControlFlowBlockId, BlockSet>;
        using ParentMap
            = std::map<ControlFlowBlockId, std::optional<ControlFlowBlockId>>;
        using EdgeMap
            = std::map<ControlFlowBlockId, std::vector<ControlFlowBlockId>>;

        [[nodiscard]] auto
        ReachableIds(const ControlFlowResult &flow) -> BlockSet
        {
            return { flow.preorder.begin(), flow.preorder.end() };
        }

        [[nodiscard]] auto
        ReachableEdges(const ControlFlowResult &flow, const bool reverse)
            -> EdgeMap
        {
            EdgeMap edges;
            for (const auto &facts : flow.facts)
                if (facts.reachable)
                    edges.emplace(facts.block,
                                  reverse ? facts.predecessors
                                          : facts.successors);
            return edges;
        }

        [[nodiscard]] auto
        Intersection(const BlockSet &left, const BlockSet &right) -> BlockSet
        {
            BlockSet result;
            std::ranges::set_intersection(left,
                                          right,
                                          std::inserter(result, result.end()));
            return result;
        }

        [[nodiscard]] auto
        IntersectInputs(const std::vector<ControlFlowBlockId> &inputs,
                        const BlockSets &sets,
                        const BlockSet &fallback) -> BlockSet
        {
            if (inputs.empty())
                return fallback;
            auto found = sets.find(inputs.front());
            BlockSet result = found == sets.end() ? fallback : found->second;
            for (auto input = std::next(inputs.begin()); input != inputs.end();
                 ++input)
            {
                found = sets.find(*input);
                if (found == sets.end())
                    return {};
                result = Intersection(result, found->second);
            }
            return result;
        }

        [[nodiscard]] auto
        ComputeDominatingSets(const BlockSet &nodes,
                              const std::vector<ControlFlowBlockId> &roots,
                              const EdgeMap &predecessors,
                              const std::vector<ControlFlowBlockId> &visitOrder)
            -> BlockSets
        {
            const BlockSet rootSet(roots.begin(), roots.end());
            BlockSets result;
            for (const auto node : nodes)
                result.emplace(node,
                               rootSet.contains(node) ? BlockSet{ node }
                                                      : nodes);

            // The finite set lattice can lose at most |V| facts per node, so
            // convergence does not depend on an arbitrary iteration budget.
            bool changed = true;
            while (changed)
            {
                changed = false;
                for (const auto node : visitOrder)
                {
                    if (rootSet.contains(node))
                        continue;
                    const auto edge = predecessors.find(node);
                    const auto incoming
                        = edge == predecessors.end()
                              ? std::vector<ControlFlowBlockId>{}
                              : edge->second;
                    auto next = incoming.empty()
                                    ? BlockSet{ node }
                                    : IntersectInputs(incoming, result, nodes);
                    next.insert(node);
                    if (next != result.at(node))
                    {
                        result.at(node) = std::move(next);
                        changed = true;
                    }
                }
            }
            return result;
        }

        [[nodiscard]] auto
        ImmediateParents(const BlockSet &nodes,
                         const std::vector<ControlFlowBlockId> &roots,
                         const BlockSets &dominatingSets) -> ParentMap
        {
            const BlockSet rootSet(roots.begin(), roots.end());
            ParentMap parents;
            for (const auto node : nodes)
            {
                if (rootSet.contains(node))
                {
                    parents.emplace(node, std::nullopt);
                    continue;
                }
                auto strict = dominatingSets.at(node);
                strict.erase(node);
                std::optional<ControlFlowBlockId> immediate;
                std::size_t greatestDepth = 0U;
                for (const auto candidate : strict)
                {
                    const auto depth = dominatingSets.at(candidate).size();
                    if (!immediate || depth > greatestDepth)
                    {
                        immediate = candidate;
                        greatestDepth = depth;
                    }
                }
                parents.emplace(node, immediate);
            }
            return parents;
        }

        [[nodiscard]] auto
        ComputeFrontiers(const BlockSet &nodes,
                         const EdgeMap &predecessors,
                         const ParentMap &parents) -> BlockSets
        {
            BlockSets frontiers;
            for (const auto node : nodes)
                frontiers.emplace(node, BlockSet{});
            for (const auto join : nodes)
            {
                const auto incoming = predecessors.find(join);
                if (incoming == predecessors.end()
                    || incoming->second.size() < 2U)
                    continue;
                const auto stop = parents.at(join);
                for (const auto predecessor : incoming->second)
                {
                    auto runner
                        = std::optional<ControlFlowBlockId>{ predecessor };
                    std::unordered_set<ControlFlowBlockId> visited;
                    while (runner && runner != stop
                           && visited.insert(*runner).second)
                    {
                        frontiers.at(*runner).insert(join);
                        runner = parents.at(*runner);
                    }
                }
            }
            return frontiers;
        }

        [[nodiscard]] auto
        ToVector(const BlockSet &values) -> std::vector<ControlFlowBlockId>
        {
            return { values.begin(), values.end() };
        }

        [[nodiscard]] auto
        FindExits(const ControlFlowResult &flow)
            -> std::vector<ControlFlowBlockId>
        {
            std::vector<ControlFlowBlockId> exits;
            for (const auto &facts : flow.facts)
                if (facts.reachable && facts.successors.empty())
                    exits.push_back(facts.block);
            return exits;
        }

        [[nodiscard]] auto
        EveryReachableBlockCanReachAnExit(
            const BlockSet &nodes,
            const std::vector<ControlFlowBlockId> &exits,
            const EdgeMap &predecessors) -> bool
        {
            if (exits.empty())
                return false;
            BlockSet reachesExit(exits.begin(), exits.end());
            std::vector<ControlFlowBlockId> worklist(exits.begin(),
                                                     exits.end());
            while (!worklist.empty())
            {
                const auto current = worklist.back();
                worklist.pop_back();
                const auto found = predecessors.find(current);
                if (found == predecessors.end())
                    continue;
                for (const auto predecessor : found->second)
                    if (reachesExit.insert(predecessor).second)
                        worklist.push_back(predecessor);
            }
            return reachesExit == nodes;
        }

        [[nodiscard]] auto
        ReverseOrder(const std::vector<ControlFlowBlockId> &order)
            -> std::vector<ControlFlowBlockId>
        {
            return { order.rbegin(), order.rend() };
        }

        [[nodiscard]] auto
        NaturalLoopMembers(const ControlFlowBlockId header,
                           const ControlFlowBlockId latch,
                           const EdgeMap &predecessors) -> BlockSet
        {
            BlockSet members{ header, latch };
            std::vector<ControlFlowBlockId> worklist;
            if (latch != header)
                worklist.push_back(latch);
            while (!worklist.empty())
            {
                const auto current = worklist.back();
                worklist.pop_back();
                const auto found = predecessors.find(current);
                if (found == predecessors.end())
                    continue;
                for (const auto predecessor : found->second)
                    if (members.insert(predecessor).second
                        && predecessor != header)
                        worklist.push_back(predecessor);
            }
            return members;
        }

        [[nodiscard]] auto
        LoopExits(const BlockSet &members, const EdgeMap &successors)
            -> BlockSet
        {
            BlockSet exits;
            for (const auto member : members)
            {
                const auto found = successors.find(member);
                if (found == successors.end())
                    continue;
                for (const auto target : found->second)
                    if (!members.contains(target))
                        exits.insert(target);
            }
            return exits;
        }

        [[nodiscard]] auto
        FindNaturalLoops(const BlockSet &nodes,
                         const EdgeMap &successors,
                         const EdgeMap &predecessors,
                         const BlockSets &dominators)
            -> std::vector<NaturalLoop>
        {
            std::vector<NaturalLoop> loops;
            for (const auto source : nodes)
            {
                const auto outgoing = successors.find(source);
                if (outgoing == successors.end())
                    continue;
                for (const auto target : outgoing->second)
                {
                    if (!dominators.at(source).contains(target))
                        continue;
                    const auto members
                        = NaturalLoopMembers(target, source, predecessors);
                    loops.push_back(
                        { target,
                          source,
                          ToVector(members),
                          ToVector(LoopExits(members, successors)) });
                }
            }
            std::ranges::sort(
                loops,
                [](const NaturalLoop &left, const NaturalLoop &right) {
                    return std::pair{ left.header, left.latch }
                           < std::pair{ right.header, right.latch };
                });
            return loops;
        }

        struct SearchFrame final
        {
            ControlFlowBlockId block{};
            std::size_t next{};
        };

        [[nodiscard]] auto
        FinishOrder(const BlockSet &nodes, const EdgeMap &successors)
            -> std::vector<ControlFlowBlockId>
        {
            std::unordered_set<ControlFlowBlockId> visited;
            std::vector<ControlFlowBlockId> finished;
            for (const auto start : nodes)
            {
                if (!visited.insert(start).second)
                    continue;
                std::vector<SearchFrame> stack{ { start, 0U } };
                while (!stack.empty())
                {
                    auto &frame = stack.back();
                    const auto found = successors.find(frame.block);
                    const auto targets = found == successors.end()
                                             ? std::vector<ControlFlowBlockId>{}
                                             : found->second;
                    if (frame.next < targets.size())
                    {
                        const auto target = targets[frame.next++];
                        if (visited.insert(target).second)
                            stack.push_back({ target, 0U });
                        continue;
                    }
                    finished.push_back(frame.block);
                    stack.pop_back();
                }
            }
            return finished;
        }

        [[nodiscard]] auto
        StronglyConnectedComponents(const BlockSet &nodes,
                                    const EdgeMap &successors,
                                    const EdgeMap &predecessors)
            -> std::vector<BlockSet>
        {
            const auto order = FinishOrder(nodes, successors);
            std::unordered_set<ControlFlowBlockId> visited;
            std::vector<BlockSet> components;
            for (const auto current : std::views::reverse(order))
            {
                if (!visited.insert(current).second)
                    continue;
                BlockSet component;
                std::vector<ControlFlowBlockId> worklist{ current };
                while (!worklist.empty())
                {
                    const auto block = worklist.back();
                    worklist.pop_back();
                    component.insert(block);
                    const auto found = predecessors.find(block);
                    if (found == predecessors.end())
                        continue;
                    for (const auto source : found->second)
                        if (visited.insert(source).second)
                            worklist.push_back(source);
                }
                components.push_back(std::move(component));
            }
            return components;
        }

        [[nodiscard]] auto
        IsCyclicComponent(const BlockSet &component, const EdgeMap &successors)
            -> bool
        {
            if (component.size() > 1U)
                return true;
            if (component.empty())
                return false;
            const auto block = *component.begin();
            const auto found = successors.find(block);
            return found != successors.end()
                   && std::ranges::find(found->second, block)
                          != found->second.end();
        }

        [[nodiscard]] auto
        RegionEntries(const BlockSet &component, const EdgeMap &predecessors)
            -> BlockSet
        {
            BlockSet entries;
            for (const auto member : component)
            {
                const auto found = predecessors.find(member);
                if (found != predecessors.end()
                    && std::ranges::any_of(found->second,
                                           [&component](const auto source) {
                                               return !component.contains(
                                                   source);
                                           }))
                    entries.insert(member);
            }
            return entries;
        }

        [[nodiscard]] auto
        HasDominatingHeader(const BlockSet &component,
                            const BlockSets &dominators) -> bool
        {
            return std::ranges::any_of(component, [&](const auto candidate) {
                return std::ranges::all_of(component, [&](const auto member) {
                    return dominators.at(member).contains(candidate);
                });
            });
        }

        [[nodiscard]] auto
        FindIrreducibleRegions(const BlockSet &nodes,
                               const EdgeMap &successors,
                               const EdgeMap &predecessors,
                               const BlockSets &dominators)
            -> std::vector<IrreducibleRegion>
        {
            std::vector<IrreducibleRegion> regions;
            for (const auto &component :
                 StronglyConnectedComponents(nodes, successors, predecessors))
            {
                if (!IsCyclicComponent(component, successors)
                    || HasDominatingHeader(component, dominators))
                    continue;
                regions.push_back(
                    { ToVector(component),
                      ToVector(RegionEntries(component, predecessors)) });
            }
            std::ranges::sort(regions, [](const auto &left, const auto &right) {
                return left.members < right.members;
            });
            return regions;
        }

        void
        AddLoopFacts(std::vector<DominanceBlockFacts> &facts,
                     const std::vector<NaturalLoop> &loops)
        {
            for (auto &blockFacts : facts)
            {
                for (const auto &loop : loops)
                {
                    if (!std::ranges::binary_search(loop.members,
                                                    blockFacts.block))
                        continue;
                    ++blockFacts.loopDepth;
                    blockFacts.loopHeaders.push_back(loop.header);
                }
                std::ranges::sort(blockFacts.loopHeaders);
                blockFacts.loopHeaders.erase(
                    std::unique(blockFacts.loopHeaders.begin(),
                                blockFacts.loopHeaders.end()),
                    blockFacts.loopHeaders.end());
            }
        }

        [[nodiscard]] auto
        BuildBlockFacts(const ControlFlowResult &flow,
                        const BlockSets &dominators,
                        const ParentMap &immediateDominators,
                        const BlockSets &frontiers,
                        const BlockSets &postDominators,
                        const ParentMap &immediatePostDominators,
                        const BlockSets &postFrontiers,
                        const bool hasPostDominance)
            -> std::vector<DominanceBlockFacts>
        {
            std::vector<DominanceBlockFacts> result;
            result.reserve(flow.facts.size());
            for (const auto &flowFacts : flow.facts)
            {
                DominanceBlockFacts facts;
                facts.block = flowFacts.block;
                facts.reachable = flowFacts.reachable;
                if (flowFacts.reachable)
                {
                    facts.immediateDominator
                        = immediateDominators.at(flowFacts.block);
                    facts.dominators = ToVector(dominators.at(flowFacts.block));
                    facts.dominanceFrontier
                        = ToVector(frontiers.at(flowFacts.block));
                    if (hasPostDominance)
                    {
                        facts.immediatePostDominator
                            = immediatePostDominators.at(flowFacts.block);
                        facts.postDominators
                            = ToVector(postDominators.at(flowFacts.block));
                        facts.postDominanceFrontier
                            = ToVector(postFrontiers.at(flowFacts.block));
                    }
                }
                result.push_back(std::move(facts));
            }
            return result;
        }
    } // namespace

    auto
    AnalyzeDominance(const ControlFlowGraph &graph) -> DominanceResult
    {
        DominanceResult result;
        result.controlFlow = AnalyzeControlFlow(graph);
        const auto nodes = ReachableIds(result.controlFlow);
        const auto successors = ReachableEdges(result.controlFlow, false);
        const auto predecessors = ReachableEdges(result.controlFlow, true);

        if (nodes.empty())
        {
            for (const auto &flowFacts : result.controlFlow.facts)
            {
                DominanceBlockFacts facts;
                facts.block = flowFacts.block;
                facts.reachable = false;
                result.facts.push_back(std::move(facts));
            }
            return result;
        }

        const auto dominators
            = ComputeDominatingSets(nodes,
                                    { graph.entry },
                                    predecessors,
                                    result.controlFlow.reversePostorder);
        const auto immediateDominators
            = ImmediateParents(nodes, { graph.entry }, dominators);
        const auto frontiers
            = ComputeFrontiers(nodes, predecessors, immediateDominators);

        result.exits = FindExits(result.controlFlow);
        // A closed non-returning SCC next to a returning arm would otherwise
        // leave the all-node initialization in place as false proof. Decline
        // post-dominance unless every reachable block can reach a real exit.
        result.hasPostDominance
            = EveryReachableBlockCanReachAnExit(nodes,
                                                result.exits,
                                                predecessors);
        BlockSets postDominators;
        ParentMap immediatePostDominators;
        BlockSets postFrontiers;
        if (result.hasPostDominance)
        {
            postDominators = ComputeDominatingSets(
                nodes,
                result.exits,
                successors,
                ReverseOrder(result.controlFlow.reversePostorder));
            immediatePostDominators
                = ImmediateParents(nodes, result.exits, postDominators);
            postFrontiers
                = ComputeFrontiers(nodes, successors, immediatePostDominators);
        }

        result.naturalLoops
            = FindNaturalLoops(nodes, successors, predecessors, dominators);
        result.irreducibleRegions = FindIrreducibleRegions(nodes,
                                                           successors,
                                                           predecessors,
                                                           dominators);
        result.facts = BuildBlockFacts(result.controlFlow,
                                       dominators,
                                       immediateDominators,
                                       frontiers,
                                       postDominators,
                                       immediatePostDominators,
                                       postFrontiers,
                                       result.hasPostDominance);
        AddLoopFacts(result.facts, result.naturalLoops);
        return result;
    }

    auto
    FactsFor(const DominanceResult &result, const ControlFlowBlockId block)
        -> const DominanceBlockFacts *
    {
        const auto found
            = std::ranges::lower_bound(result.facts,
                                       block,
                                       {},
                                       &DominanceBlockFacts::block);
        return found != result.facts.end() && found->block == block ? &*found
                                                                    : nullptr;
    }

    auto
    Dominates(const DominanceResult &result,
              const ControlFlowBlockId dominator,
              const ControlFlowBlockId block) -> bool
    {
        const auto *facts = FactsFor(result, block);
        return facts != nullptr && facts->reachable
               && std::ranges::binary_search(facts->dominators, dominator);
    }

    auto
    StrictlyDominates(const DominanceResult &result,
                      const ControlFlowBlockId dominator,
                      const ControlFlowBlockId block) -> bool
    {
        return dominator != block && Dominates(result, dominator, block);
    }

    auto
    PostDominates(const DominanceResult &result,
                  const ControlFlowBlockId postDominator,
                  const ControlFlowBlockId block) -> bool
    {
        const auto *facts = FactsFor(result, block);
        return result.hasPostDominance && facts != nullptr && facts->reachable
               && std::ranges::binary_search(facts->postDominators,
                                             postDominator);
    }

    auto
    StrictlyPostDominates(const DominanceResult &result,
                          const ControlFlowBlockId postDominator,
                          const ControlFlowBlockId block) -> bool
    {
        return postDominator != block
               && PostDominates(result, postDominator, block);
    }
} // namespace Progmasoft::Tala::Analysis
