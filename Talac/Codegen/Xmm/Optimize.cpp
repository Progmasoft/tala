// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Analysis/ControlFlow.hpp"
#include "Progmasoft/Tala/Analysis/Liveness.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"

namespace tala::xmm
{
    namespace
    {
        namespace Live = ::Progmasoft::Tala::Analysis::Liveness;
        namespace Flow = ::Progmasoft::Tala::Analysis;

        using BlockMap = std::unordered_map<BlockId, Block *>;
        using TargetCache = std::unordered_map<BlockId, BlockId>;

        [[nodiscard]] auto
        Successors(const Terminator &terminator) -> std::vector<BlockId>
        {
            switch (terminator.kind)
            {
                case Terminator::Kind::Branch:
                    return { terminator.true_target, terminator.false_target };
                case Terminator::Kind::Jump:
                    return { terminator.true_target };
                case Terminator::Kind::Return:
                case Terminator::Kind::Unreachable:
                    return {};
            }
            return {};
        }

        [[nodiscard]] auto
        ControlFlowFor(const Function &function) -> Flow::ControlFlowGraph
        {
            Flow::ControlFlowGraph graph;
            graph.entry = function.entry;
            graph.blocks.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
                graph.blocks.push_back(
                    { block.id, Successors(block.terminator) });
            return graph;
        }

        [[nodiscard]] auto
        IsSelfMove(const Instruction &instruction) -> bool
        {
            return instruction.opcode == Opcode::Move && instruction.has_result
                   && instruction.operands.size() == 1U
                   && instruction.operands.front().kind == Value::Kind::Register
                   && instruction.destination
                          == instruction.operands.front().reg;
        }

        [[nodiscard]] auto
        IsRemovableWrite(const Instruction &instruction) -> bool
        {
            // These instructions only materialize an immediate or copy a
            // register. Arithmetic, calls, allocations, and ownership actions
            // remain observable until their exact trap/effect contract proves
            // a wider elimination set.
            return instruction.has_result
                   && (instruction.opcode == Opcode::LoadImmediate
                       || instruction.opcode == Opcode::Move);
        }

        void
        AppendRead(const Value &value, std::vector<Live::StorageId> &reads)
        {
            if (value.kind == Value::Kind::Register)
                reads.push_back(value.reg);
        }

        [[nodiscard]] auto
        LivenessFunction(const Function &function) -> Live::Function
        {
            Live::Function model;
            model.entry = function.entry;
            model.blocks.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
            {
                Live::Block liveBlock;
                liveBlock.id = block.id;
                liveBlock.successors = Successors(block.terminator);
                liveBlock.accesses.reserve(block.instructions.size() + 1U);
                for (std::size_t index = 0U; index < block.instructions.size();
                     ++index)
                {
                    const auto &instruction = block.instructions[index];
                    Live::Access access;
                    access.instruction = index;
                    for (const auto &operand : instruction.operands)
                        AppendRead(operand, access.reads);
                    if (instruction.has_result)
                        access.write = instruction.destination;
                    access.removable = IsRemovableWrite(instruction);
                    liveBlock.accesses.push_back(std::move(access));
                }

                Live::Access terminator;
                terminator.instruction = block.instructions.size();
                terminator.terminator = true;
                if (block.terminator.kind == Terminator::Kind::Return
                    || block.terminator.kind == Terminator::Kind::Branch)
                    AppendRead(block.terminator.value, terminator.reads);
                liveBlock.accesses.push_back(std::move(terminator));
                model.blocks.push_back(std::move(liveBlock));
            }
            return model;
        }

        [[nodiscard]] auto
        RemoveDeadMaterializations(Function &function) -> bool
        {
            const auto result = Live::Analyze(LivenessFunction(function),
                                              { .materializeLiveSets = false });
            if (!result.valid())
                return false;

            std::unordered_map<BlockId, const Live::BlockFacts *> facts;
            facts.reserve(result.facts.size());
            for (const auto &block : result.facts)
                facts.emplace(block.block, &block);

            bool changed = false;
            for (auto &block : function.blocks)
            {
                const auto found = facts.find(block.id);
                if (found == facts.end() || !found->second->reachable)
                    continue;
                const auto &accesses = found->second->accesses;
                std::size_t index = 0U;
                std::erase_if(block.instructions, [&](const Instruction &) {
                    const auto remove
                        = index < accesses.size() && !accesses[index].retained;
                    ++index;
                    changed = changed || remove;
                    return remove;
                });
            }
            return changed;
        }

        [[nodiscard]] auto
        CatalogBlocks(Function &function) -> BlockMap
        {
            BlockMap blocks;
            blocks.reserve(function.blocks.size());
            for (auto &block : function.blocks)
                blocks.emplace(block.id, &block);
            return blocks;
        }

        [[nodiscard]] auto
        ResolveTrampoline(const BlockId start,
                          const BlockMap &blocks,
                          TargetCache &cache) -> BlockId
        {
            if (const auto found = cache.find(start); found != cache.end())
                return found->second;

            std::vector<BlockId> path;
            std::unordered_map<BlockId, std::size_t> positions;
            auto current = start;
            while (true)
            {
                if (const auto found = cache.find(current);
                    found != cache.end())
                {
                    for (const auto block : path)
                        cache.emplace(block, found->second);
                    return found->second;
                }

                const auto block = blocks.find(current);
                if (block == blocks.end()
                    || !block->second->instructions.empty()
                    || block->second->terminator.kind != Terminator::Kind::Jump
                    || block->second->terminator.true_target == current)
                {
                    for (const auto visited : path)
                        cache.emplace(visited, current);
                    cache.emplace(current, current);
                    return current;
                }

                if (const auto cycle = positions.find(current);
                    cycle != positions.end())
                {
                    for (std::size_t index = cycle->second; index < path.size();
                         ++index)
                        cache.emplace(path[index], path[index]);
                    for (std::size_t index = 0U; index < cycle->second; ++index)
                        cache.emplace(path[index], current);
                    return cache.at(start);
                }

                positions.emplace(current, path.size());
                path.push_back(current);
                current = block->second->terminator.true_target;
            }
        }

        [[nodiscard]] auto
        ThreadTrampolines(Function &function) -> bool
        {
            const auto blocks = CatalogBlocks(function);
            TargetCache cache;
            cache.reserve(blocks.size());
            bool changed = false;
            for (auto &block : function.blocks)
            {
                auto &terminator = block.terminator;
                if (terminator.kind == Terminator::Kind::Jump)
                {
                    const auto target
                        = ResolveTrampoline(terminator.true_target,
                                            blocks,
                                            cache);
                    changed = changed || target != terminator.true_target;
                    terminator.true_target = target;
                }
                else if (terminator.kind == Terminator::Kind::Branch)
                {
                    const auto trueTarget
                        = ResolveTrampoline(terminator.true_target,
                                            blocks,
                                            cache);
                    const auto falseTarget
                        = ResolveTrampoline(terminator.false_target,
                                            blocks,
                                            cache);
                    changed = changed || trueTarget != terminator.true_target
                              || falseTarget != terminator.false_target;
                    terminator.true_target = trueTarget;
                    terminator.false_target = falseTarget;
                    if (trueTarget == falseTarget)
                    {
                        terminator.kind = Terminator::Kind::Jump;
                        terminator.false_target = 0U;
                        changed = true;
                    }
                }
            }
            return changed;
        }

        [[nodiscard]] auto
        RetainReachableReversePostorder(Function &function) -> bool
        {
            const auto flow
                = Flow::AnalyzeControlFlow(ControlFlowFor(function));
            if (!flow.valid())
                return false;
            const auto &order = flow.reversePostorder;
            const std::unordered_set<BlockId> reachable(order.begin(),
                                                        order.end());
            std::vector<BlockId> previousOrder;
            previousOrder.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
                previousOrder.push_back(block.id);
            std::erase_if(function.blocks, [&reachable](const Block &block) {
                return !reachable.contains(block.id);
            });

            std::unordered_map<BlockId, std::size_t> positions;
            positions.reserve(order.size());
            for (std::size_t index = 0U; index < order.size(); ++index)
                positions.emplace(order[index], index);
            std::ranges::sort(
                function.blocks,
                [&positions](const Block &left, const Block &right) {
                    return positions.at(left.id) < positions.at(right.id);
                });
            std::vector<BlockId> currentOrder;
            currentOrder.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
                currentOrder.push_back(block.id);
            return previousOrder != currentOrder;
        }

        void
        OptimizeFunction(Function &function)
        {
            for (auto &block : function.blocks)
                std::erase_if(block.instructions, IsSelfMove);

            bool changed = true;
            while (changed)
            {
                changed = false;
                changed = RetainReachableReversePostorder(function) || changed;
                changed = RemoveDeadMaterializations(function) || changed;
                changed = ThreadTrampolines(function) || changed;
            }
        }
    } // namespace

    auto
    optimize(Module module) -> Module
    {
        for (auto &function : module.functions)
            OptimizeFunction(function);
        return module;
    }
} // namespace tala::xmm
