// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <cstddef>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Analysis/Liveness.hpp"
#include "Progmasoft/Tala/Core/Ownership.hpp"
#include "Progmasoft/Tala/Xpp/OwnershipPlacement.hpp"

namespace Progmasoft::Tala::Xpp
{
    namespace Core = ::tala::core;
    namespace IR = ::tala::xpp;
    namespace Live = ::Progmasoft::Tala::Analysis::Liveness;

    namespace
    {
        using SymbolSet = std::unordered_set<IR::SymbolId>;
        using Effect = IR::Instruction::Effect;

        [[nodiscard]] auto
        IsAarc(const Core::Type &type) -> bool
        {
            // The same classification as the ownership verifier, so every
            // value it tracks has an owner here.
            return Core::UsesAarc(type) || type.kind == Core::Type::Kind::Named;
        }

        [[nodiscard]] auto
        IsSymbol(const IR::Operand &operand) -> bool
        {
            return operand.kind == IR::Operand::Kind::Symbol;
        }

        [[nodiscard]] auto
        SymbolOperand(IR::SymbolId symbol, const Core::Type &type)
            -> IR::Operand
        {
            IR::Operand operand;
            operand.kind = IR::Operand::Kind::Symbol;
            operand.type = type;
            operand.symbol = symbol;
            return operand;
        }

        [[nodiscard]] auto
        Release(IR::SymbolId symbol, const Core::Type &type) -> IR::Instruction
        {
            IR::Instruction instruction;
            instruction.effect = Effect::Discard;
            instruction.opcode = IR::Opcode::ReleaseStrong;
            instruction.result_type = Core::Type::unit();
            instruction.operands.push_back(SymbolOperand(symbol, type));
            return instruction;
        }

        /// `destination = opcode source`, defining a new symbol.
        [[nodiscard]] auto
        DefineFrom(IR::Opcode opcode,
                   IR::SymbolId destination,
                   IR::SymbolId source,
                   const Core::Type &type) -> IR::Instruction
        {
            IR::Instruction instruction;
            instruction.effect = Effect::Define;
            instruction.opcode = opcode;
            instruction.destination = destination;
            instruction.result_type = type;
            instruction.operands.push_back(SymbolOperand(source, type));
            return instruction;
        }

        /// A closure of a method, without captures.
        [[nodiscard]] auto
        MethodClosure(IR::SymbolId destination,
                      IR::SymbolId method,
                      const Core::Type &type) -> IR::Instruction
        {
            IR::Instruction instruction;
            instruction.effect = Effect::Define;
            instruction.opcode = IR::Opcode::MakeClosure;
            instruction.destination = destination;
            instruction.result_type = type;
            instruction.closure_function = method;
            return instruction;
        }

        [[nodiscard]] auto
        Contains(const std::vector<Live::StorageId> &symbols,
                 IR::SymbolId symbol) -> bool
        {
            return std::ranges::find(symbols, symbol) != symbols.end();
        }

        /// The targets of a terminator, one for each edge it has.
        [[nodiscard]] auto
        Edges(IR::Terminator &terminator) -> std::vector<IR::BlockId *>
        {
            switch (terminator.kind)
            {
                case IR::Terminator::Kind::Branch:
                    return { &terminator.true_target,
                             &terminator.false_target };
                case IR::Terminator::Kind::Jump:
                    return { &terminator.true_target };
                case IR::Terminator::Kind::Return:
                case IR::Terminator::Kind::Unreachable:
                    return {};
            }
            return {};
        }

        /// Places the ownership of one function.
        class Placer final
        {
        public:
            Placer(IR::Function &function,
                   const SymbolSet &methods,
                   IR::SymbolId &nextSymbol)
                : function_(function)
                , methods_(methods)
                , nextSymbol_(nextSymbol)
            {
                for (const auto &block : function_.blocks)
                    nextBlock_ = std::max(nextBlock_, block.id + 1U);
            }

            void
            Run()
            {
                OwnAssignedParameters();
                for (const auto &parameter : function_.parameters)
                    if (IsAarc(parameter.type))
                        borrowed_.insert(parameter.symbol.id);
                MaterializeMethodValues();
                Normalize();
                Place();
            }

        private:
            [[nodiscard]] auto
            Fresh() -> IR::SymbolId
            {
                return nextSymbol_++;
            }

            [[nodiscard]] auto
            IsMethod(const IR::Operand &operand) const -> bool
            {
                return IsSymbol(operand) && methods_.contains(operand.symbol);
            }

            /// Whether a symbol holds a reference this function must
            /// release.
            [[nodiscard]] auto
            Owned(IR::SymbolId symbol, const Core::Type &type) const -> bool
            {
                return IsAarc(type) && !methods_.contains(symbol)
                       && !borrowed_.contains(symbol);
            }

            [[nodiscard]] auto
            Owned(const IR::Operand &operand) const -> bool
            {
                return IsSymbol(operand) && Owned(operand.symbol, operand.type);
            }

            /**
             * A parameter is borrowed, but one the body assigns holds an
             * owned value from the assignment on. Such a parameter is
             * copied into a local of the body at entry, with a reference
             * of its own, and the body uses the local: a symbol is then
             * borrowed or owned, never one after the other.
             */
            void
            OwnAssignedParameters()
            {
                SymbolSet assigned;
                for (const auto &block : function_.blocks)
                    for (const auto &instruction : block.instructions)
                        if (instruction.effect == Effect::Store)
                            assigned.insert(instruction.destination);

                std::vector<IR::Instruction> copies;
                std::unordered_map<IR::SymbolId, IR::SymbolId> locals;
                for (const auto &parameter : function_.parameters)
                {
                    if (!IsAarc(parameter.type)
                        || !assigned.contains(parameter.symbol.id))
                        continue;
                    const auto local = Fresh();
                    locals.emplace(parameter.symbol.id, local);
                    copies.push_back(DefineFrom(IR::Opcode::RetainStrong,
                                                local,
                                                parameter.symbol.id,
                                                parameter.type));
                }
                if (copies.empty())
                    return;

                const auto rename = [&locals](IR::SymbolId &symbol) {
                    if (const auto found = locals.find(symbol);
                        found != locals.end())
                        symbol = found->second;
                };
                for (auto &block : function_.blocks)
                {
                    for (auto &instruction : block.instructions)
                    {
                        if (instruction.effect != Effect::Discard)
                            rename(instruction.destination);
                        for (auto &operand : instruction.operands)
                            if (IsSymbol(operand))
                                rename(operand.symbol);
                    }
                    if (IsSymbol(block.terminator.value))
                        rename(block.terminator.value.symbol);
                }

                // The copies run once, also when the entry block is the
                // target of a loop.
                IR::Block entry;
                entry.id = nextBlock_++;
                entry.instructions = std::move(copies);
                entry.terminator.kind = IR::Terminator::Kind::Jump;
                entry.terminator.true_target = function_.entry;
                function_.entry = entry.id;
                function_.blocks.insert(function_.blocks.begin(),
                                        std::move(entry));
            }

            /**
             * A method named where a value is expected becomes a closure
             * without captures. The callee of a direct call stays a
             * method: such a call needs no closure.
             *
             * A string literal used as an operand becomes a local in the
             * same pass, for the same reason: both are objects created at
             * a use, and an object needs a symbol to be released by.
             */
            void
            MaterializeMethodValues()
            {
                for (auto &block : function_.blocks)
                {
                    std::vector<IR::Instruction> rewritten;
                    rewritten.reserve(block.instructions.size());
                    for (auto &instruction : block.instructions)
                    {
                        if (instruction.opcode == IR::Opcode::Copy
                            && instruction.effect != Effect::Discard
                            && instruction.operands.size() == 1U
                            && IsMethod(instruction.operands.front()))
                        {
                            auto closure = MethodClosure(
                                instruction.destination,
                                instruction.operands.front().symbol,
                                instruction.result_type);
                            closure.effect = instruction.effect;
                            rewritten.push_back(std::move(closure));
                            continue;
                        }
                        // A string literal that is an operand creates a
                        // string where it is used. Unless the instruction
                        // is the binding of that string, nothing names the
                        // new object and nothing could release it, so it
                        // gets a symbol of its own first.
                        const auto binds
                            = instruction.opcode == IR::Opcode::Copy
                              && instruction.effect != Effect::Discard
                              && instruction.operands.size() == 1U;
                        if (!binds)
                            for (auto &operand : instruction.operands)
                            {
                                if (operand.kind != IR::Operand::Kind::Literal
                                    || !IsAarc(operand.type))
                                    continue;
                                const auto created = Fresh();
                                IR::Instruction literal;
                                literal.effect = Effect::Define;
                                literal.opcode = IR::Opcode::Copy;
                                literal.destination = created;
                                literal.result_type = operand.type;
                                literal.operands.push_back(operand);
                                rewritten.push_back(std::move(literal));
                                operand = SymbolOperand(created, operand.type);
                            }
                        const std::size_t first
                            = instruction.opcode == IR::Opcode::Call ? 1U : 0U;
                        for (std::size_t index = first;
                             index < instruction.operands.size();
                             ++index)
                        {
                            auto &operand = instruction.operands[index];
                            if (!IsMethod(operand))
                                continue;
                            const auto closure = Fresh();
                            rewritten.push_back(MethodClosure(closure,
                                                              operand.symbol,
                                                              operand.type));
                            operand.symbol = closure;
                        }
                        rewritten.push_back(std::move(instruction));
                    }
                    auto &terminator = block.terminator;
                    if (terminator.kind == IR::Terminator::Kind::Return
                        && IsMethod(terminator.value))
                    {
                        const auto closure = Fresh();
                        rewritten.push_back(
                            MethodClosure(closure,
                                          terminator.value.symbol,
                                          terminator.value.type));
                        terminator.value.symbol = closure;
                    }
                    block.instructions = std::move(rewritten);
                }
            }

            /**
             * Bring every instruction to a form in which each owned value
             * has a symbol of its own:
             *
             * - a call whose owned result is discarded defines a symbol,
             *   so that the result can be released;
             * - an instruction that reads the symbol it writes reads the
             *   old value from a symbol of its own, so that the old value
             *   can be released after the new one is stored;
             * - a borrowed value that is returned is retained first,
             *   because the caller receives an owned result.
             */
            void
            Normalize()
            {
                for (auto &block : function_.blocks)
                {
                    std::vector<IR::Instruction> rewritten;
                    rewritten.reserve(block.instructions.size());
                    for (auto &instruction : block.instructions)
                    {
                        if (instruction.effect == Effect::Discard
                            && (instruction.opcode == IR::Opcode::Call
                                || instruction.opcode
                                       == IR::Opcode::RuntimeCall)
                            && IsAarc(instruction.result_type))
                        {
                            instruction.effect = Effect::Define;
                            instruction.destination = Fresh();
                        }
                        const auto rewrites
                            = instruction.effect != Effect::Discard
                              && Owned(instruction.destination,
                                       instruction.result_type)
                              && !IsSelfCopy(instruction)
                              && std::ranges::any_of(
                                  instruction.operands,
                                  [&](const IR::Operand &operand) {
                                      return IsSymbol(operand)
                                             && operand.symbol
                                                    == instruction.destination;
                                  });
                        if (rewrites)
                        {
                            const auto previous = Fresh();
                            rewritten.push_back(
                                DefineFrom(IR::Opcode::Copy,
                                           previous,
                                           instruction.destination,
                                           instruction.result_type));
                            for (auto &operand : instruction.operands)
                                if (IsSymbol(operand)
                                    && operand.symbol
                                           == instruction.destination)
                                    operand.symbol = previous;
                        }
                        rewritten.push_back(std::move(instruction));
                    }
                    auto &terminator = block.terminator;
                    if (terminator.kind == IR::Terminator::Kind::Return
                        && IsSymbol(terminator.value)
                        && IsAarc(terminator.value.type)
                        && borrowed_.contains(terminator.value.symbol))
                    {
                        const auto owned = Fresh();
                        rewritten.push_back(DefineFrom(IR::Opcode::RetainStrong,
                                                       owned,
                                                       terminator.value.symbol,
                                                       terminator.value.type));
                        terminator.value.symbol = owned;
                    }
                    block.instructions = std::move(rewritten);
                }
            }

            [[nodiscard]] static auto
            IsSelfCopy(const IR::Instruction &instruction) -> bool
            {
                return instruction.opcode == IR::Opcode::Copy
                       && instruction.effect != Effect::Discard
                       && instruction.operands.size() == 1U
                       && IsSymbol(instruction.operands.front())
                       && instruction.operands.front().symbol
                              == instruction.destination;
            }

            /// The liveness problem of the owned symbols alone.
            [[nodiscard]] auto
            LivenessModel() -> Live::Function
            {
                Live::Function model;
                model.entry = function_.entry;
                model.blocks.reserve(function_.blocks.size());
                for (auto &block : function_.blocks)
                {
                    Live::Block live;
                    live.id = block.id;
                    for (const auto *target : Edges(block.terminator))
                        live.successors.push_back(*target);
                    live.accesses.reserve(block.instructions.size() + 1U);
                    for (std::size_t index = 0U;
                         index < block.instructions.size();
                         ++index)
                    {
                        const auto &instruction = block.instructions[index];
                        Live::Access access;
                        access.instruction = index;
                        for (const auto &operand : instruction.operands)
                            if (Owned(operand))
                            {
                                access.reads.push_back(operand.symbol);
                                types_.insert_or_assign(operand.symbol,
                                                        operand.type);
                            }
                        if (instruction.effect != Effect::Discard
                            && Owned(instruction.destination,
                                     instruction.result_type))
                        {
                            access.write = instruction.destination;
                            types_.insert_or_assign(instruction.destination,
                                                    instruction.result_type);
                        }
                        live.accesses.push_back(std::move(access));
                    }
                    Live::Access terminator;
                    terminator.instruction = block.instructions.size();
                    terminator.terminator = true;
                    if (block.terminator.kind == IR::Terminator::Kind::Return
                        && Owned(block.terminator.value))
                        terminator.reads.push_back(
                            block.terminator.value.symbol);
                    live.accesses.push_back(std::move(terminator));
                    model.blocks.push_back(std::move(live));
                }
                return model;
            }

            [[nodiscard]] auto
            ReleaseOf(IR::SymbolId symbol) const -> IR::Instruction
            {
                return Release(symbol, types_.at(symbol));
            }

            /**
             * Write the retains and the releases. A value is released
             * after the instruction that uses it last, after the
             * instruction that defines it when nothing uses it, and on the
             * edge on which it dies when it lives on another edge of the
             * same branch. A returned value leaves with its reference.
             */
            void
            Place()
            {
                const auto analysis = Live::Analyze(LivenessModel());
                // A function with a malformed graph is left as it is; the
                // verifier reports the graph.
                if (!analysis.valid())
                    return;

                std::unordered_map<IR::BlockId, const Live::BlockFacts *> facts;
                facts.reserve(analysis.facts.size());
                for (const auto &block : analysis.facts)
                    if (block.reachable)
                        facts.emplace(block.block, &block);

                std::unordered_map<IR::BlockId, std::size_t> predecessors;
                predecessors[function_.entry] = 1U;
                for (auto &block : function_.blocks)
                    if (facts.contains(block.id))
                        for (const auto *target : Edges(block.terminator))
                            ++predecessors[*target];

                std::unordered_map<IR::BlockId, std::vector<IR::Instruction>>
                    prefixes;
                std::vector<IR::Block> added;
                for (auto &block : function_.blocks)
                {
                    const auto found = facts.find(block.id);
                    if (found == facts.end())
                        continue;
                    const auto &blockFacts = *found->second;
                    PlaceInBlock(block, blockFacts);

                    for (auto *target : Edges(block.terminator))
                    {
                        const auto successor = facts.find(*target);
                        if (successor == facts.end())
                            continue;
                        auto dying = blockFacts.liveOnExit;
                        std::erase_if(dying, [&](Live::StorageId symbol) {
                            return Contains(successor->second->liveOnEntry,
                                            symbol);
                        });
                        if (dying.empty())
                            continue;
                        std::ranges::sort(dying);
                        std::vector<IR::Instruction> releases;
                        releases.reserve(dying.size());
                        for (const auto symbol : dying)
                            releases.push_back(ReleaseOf(symbol));
                        if (predecessors[*target] == 1U)
                        {
                            prefixes[*target] = std::move(releases);
                            continue;
                        }
                        IR::Block edge;
                        edge.id = nextBlock_++;
                        edge.instructions = std::move(releases);
                        edge.terminator.kind = IR::Terminator::Kind::Jump;
                        edge.terminator.true_target = *target;
                        *target = edge.id;
                        added.push_back(std::move(edge));
                    }
                }

                for (auto &block : function_.blocks)
                    if (const auto prefix = prefixes.find(block.id);
                        prefix != prefixes.end())
                        block.instructions.insert(
                            block.instructions.begin(),
                            std::make_move_iterator(prefix->second.begin()),
                            std::make_move_iterator(prefix->second.end()));
                for (auto &block : added)
                    function_.blocks.push_back(std::move(block));
            }

            void
            PlaceInBlock(IR::Block &block, const Live::BlockFacts &facts)
            {
                std::vector<IR::Instruction> rewritten;
                rewritten.reserve(block.instructions.size());
                for (std::size_t index = 0U; index < block.instructions.size();
                     ++index)
                {
                    auto &instruction = block.instructions[index];
                    // A copy of a symbol onto itself moves nothing.
                    if (IsSelfCopy(instruction)
                        && IsAarc(instruction.result_type))
                        continue;
                    const auto &after = facts.accesses[index].liveAfter;
                    const auto writes = instruction.effect != Effect::Discard
                                        && Owned(instruction.destination,
                                                 instruction.result_type);

                    // The source of a copy that takes over its reference.
                    bool moves = false;
                    IR::SymbolId moved{};
                    if (instruction.opcode == IR::Opcode::Copy
                        && instruction.effect != Effect::Discard
                        && instruction.operands.size() == 1U
                        && IsSymbol(instruction.operands.front())
                        && IsAarc(instruction.result_type))
                    {
                        const auto source = instruction.operands.front().symbol;
                        if (borrowed_.contains(source)
                            || Contains(after, source))
                            instruction.opcode = IR::Opcode::RetainStrong;
                        else if (Owned(instruction.operands.front()))
                        {
                            moves = true;
                            moved = source;
                        }
                    }

                    std::vector<IR::SymbolId> dying;
                    for (const auto &operand : instruction.operands)
                        if (Owned(operand) && !Contains(after, operand.symbol)
                            && (!moves || operand.symbol != moved)
                            && std::ranges::find(dying, operand.symbol)
                                   == dying.end())
                            dying.push_back(operand.symbol);
                    const auto destination = instruction.destination;
                    rewritten.push_back(std::move(instruction));
                    for (const auto symbol : dying)
                        rewritten.push_back(ReleaseOf(symbol));
                    if (writes && !Contains(after, destination))
                        rewritten.push_back(ReleaseOf(destination));
                }
                block.instructions = std::move(rewritten);
            }

            IR::Function &function_;
            const SymbolSet &methods_;
            IR::SymbolId &nextSymbol_;
            IR::BlockId nextBlock_{};
            /// Parameters: the caller keeps them alive.
            SymbolSet borrowed_;
            /// The type of each owned symbol, for the operand of its
            /// release.
            std::unordered_map<IR::SymbolId, Core::Type> types_;
        };

        /// One more than every symbol the module mentions.
        [[nodiscard]] auto
        FirstFreeSymbol(const IR::Module &module) -> IR::SymbolId
        {
            IR::SymbolId next = 1U;
            const auto see = [&next](IR::SymbolId symbol) {
                next = std::max(next, symbol + 1U);
            };
            for (const auto &function : module.functions)
            {
                see(function.symbol.id);
                for (const auto &parameter : function.parameters)
                    see(parameter.symbol.id);
                for (const auto &block : function.blocks)
                {
                    for (const auto &instruction : block.instructions)
                    {
                        see(instruction.destination);
                        see(instruction.closure_function);
                        for (const auto &operand : instruction.operands)
                            if (IsSymbol(operand))
                                see(operand.symbol);
                    }
                    if (IsSymbol(block.terminator.value))
                        see(block.terminator.value.symbol);
                }
            }
            return next;
        }
    } // namespace

    auto
    PlaceOwnership(IR::Module module) -> IR::Module
    {
        SymbolSet methods;
        methods.reserve(module.functions.size());
        for (const auto &function : module.functions)
            methods.insert(function.symbol.id);
        auto nextSymbol = FirstFreeSymbol(module);
        for (auto &function : module.functions)
            Placer(function, methods, nextSymbol).Run();
        return module;
    }
} // namespace Progmasoft::Tala::Xpp
