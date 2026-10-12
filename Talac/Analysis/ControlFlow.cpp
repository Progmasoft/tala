// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#include "Progmasoft/Tala/Analysis/ControlFlow.hpp"

namespace Progmasoft::Tala::Analysis
{
    namespace
    {
        using BlockMap
            = std::unordered_map<ControlFlowBlockId, const ControlFlowBlock *>;
        using EdgeMap = std::unordered_map<ControlFlowBlockId,
                                           std::vector<ControlFlowBlockId>>;

        [[nodiscard]] auto
        CatalogBlocks(const ControlFlowGraph &graph,
                      std::vector<ControlFlowIssue> &issues) -> BlockMap
        {
            BlockMap blocks;
            blocks.reserve(graph.blocks.size());
            for (const auto &block : graph.blocks)
                if (!blocks.emplace(block.id, &block).second)
                    issues.push_back(
                        { ControlFlowIssueKind::DuplicateBlock, block.id, 0U });
            if (!blocks.contains(graph.entry))
                issues.push_back(
                    { ControlFlowIssueKind::MissingEntry, graph.entry, 0U });
            return blocks;
        }

        [[nodiscard]] auto
        ValidSuccessors(const ControlFlowGraph &graph,
                        const BlockMap &blocks,
                        std::vector<ControlFlowIssue> &issues) -> EdgeMap
        {
            EdgeMap successors;
            successors.reserve(blocks.size());
            for (const auto &[id, block] : blocks)
            {
                static_cast<void>(block);
                successors.emplace(id, std::vector<ControlFlowBlockId>{});
            }

            // Diagnose duplicate block records separately and use the first
            // record as the canonical identity. This keeps malformed input
            // finite and deterministic instead of merging contradictory edges.
            std::unordered_set<ControlFlowBlockId> visitedBlocks;
            for (const auto &block : graph.blocks)
            {
                if (!visitedBlocks.insert(block.id).second)
                    continue;
                std::unordered_set<ControlFlowBlockId> uniqueTargets;
                for (const auto target : block.successors)
                {
                    if (!blocks.contains(target))
                    {
                        issues.push_back({ ControlFlowIssueKind::MissingTarget,
                                           block.id,
                                           target });
                        continue;
                    }
                    if (uniqueTargets.insert(target).second)
                        successors.at(block.id).push_back(target);
                }
            }
            return successors;
        }

        [[nodiscard]] auto
        BuildPredecessors(const BlockMap &blocks, const EdgeMap &successors)
            -> EdgeMap
        {
            EdgeMap predecessors;
            predecessors.reserve(blocks.size());
            for (const auto &[id, block] : blocks)
            {
                static_cast<void>(block);
                predecessors.emplace(id, std::vector<ControlFlowBlockId>{});
            }
            for (const auto &[source, targets] : successors)
                for (const auto target : targets)
                    predecessors.at(target).push_back(source);
            for (auto &[id, sources] : predecessors)
            {
                static_cast<void>(id);
                std::ranges::sort(sources);
            }
            return predecessors;
        }

        struct TraversalFrame final
        {
            ControlFlowBlockId block{};
            std::size_t nextSuccessor{};
        };

        void
        Traverse(const ControlFlowBlockId entry,
                 const BlockMap &blocks,
                 const EdgeMap &successors,
                 std::vector<ControlFlowBlockId> &preorder,
                 std::vector<ControlFlowBlockId> &reversePostorder)
        {
            if (!blocks.contains(entry))
                return;

            std::unordered_set<ControlFlowBlockId> discovered;
            std::vector<ControlFlowBlockId> postorder;
            std::vector<TraversalFrame> stack;
            discovered.insert(entry);
            preorder.push_back(entry);
            stack.push_back({ entry, 0U });

            // An explicit frame stack avoids native recursion depth becoming a
            // property of accepted compiler IR. Successors retain semantic
            // true/false order while block presentation remains irrelevant.
            while (!stack.empty())
            {
                auto &frame = stack.back();
                const auto &targets = successors.at(frame.block);
                if (frame.nextSuccessor < targets.size())
                {
                    const auto target = targets[frame.nextSuccessor++];
                    if (discovered.insert(target).second)
                    {
                        preorder.push_back(target);
                        stack.push_back({ target, 0U });
                    }
                    continue;
                }
                postorder.push_back(frame.block);
                stack.pop_back();
            }
            reversePostorder.assign(postorder.rbegin(), postorder.rend());
        }

        [[nodiscard]] auto
        BuildFacts(const BlockMap &blocks,
                   const EdgeMap &predecessors,
                   const EdgeMap &successors,
                   const std::vector<ControlFlowBlockId> &preorder)
            -> std::vector<ControlFlowBlockFacts>
        {
            const std::unordered_set<ControlFlowBlockId> reachable(
                preorder.begin(),
                preorder.end());
            std::vector<ControlFlowBlockFacts> facts;
            facts.reserve(blocks.size());
            for (const auto &[id, block] : blocks)
            {
                static_cast<void>(block);
                auto sources = predecessors.at(id);
                auto targets = successors.at(id);
                std::erase_if(sources, [&reachable](const auto source) {
                    return !reachable.contains(source);
                });
                std::ranges::sort(targets);
                facts.push_back({ id,
                                  reachable.contains(id),
                                  std::move(sources),
                                  std::move(targets) });
            }
            std::ranges::sort(facts, {}, &ControlFlowBlockFacts::block);
            return facts;
        }
    } // namespace

    auto
    AnalyzeControlFlow(const ControlFlowGraph &graph) -> ControlFlowResult
    {
        ControlFlowResult result;
        const auto blocks = CatalogBlocks(graph, result.issues);
        const auto successors = ValidSuccessors(graph, blocks, result.issues);
        const auto predecessors = BuildPredecessors(blocks, successors);
        Traverse(graph.entry,
                 blocks,
                 successors,
                 result.preorder,
                 result.reversePostorder);
        result.facts
            = BuildFacts(blocks, predecessors, successors, result.preorder);
        return result;
    }
} // namespace Progmasoft::Tala::Analysis
