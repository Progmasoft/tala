// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <cstddef>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "CorePrepParity.hpp"

namespace Progmasoft::Tala::Fuzzing
{
    namespace
    {
        namespace Prepared = ::tala::core;

        // Canonical identities start far above any real symbol so a renamed
        // generated symbol can never equal a source symbol.
        constexpr Prepared::SymbolId kCanonicalBase = Prepared::SymbolId{ 1 }
                                                      << 48U;

        /// Generated symbols are spelled with a leading `$`, which cannot
        /// occur in a source identifier.
        [[nodiscard]] auto
        IsGenerated(const Prepared::SymbolName &symbol) -> bool
        {
            return !symbol.spelling.empty() && symbol.spelling.front() == U'$';
        }

        /// `$coreprep17` and `$coreprep4` are the same kind of temporary;
        /// the digits only repeat the identity.
        [[nodiscard]] auto
        KindOf(const std::u32string &spelling) -> std::u32string
        {
            auto end = spelling.size();
            while (end > 0U && spelling[end - 1U] >= U'0'
                   && spelling[end - 1U] <= U'9')
                --end;
            return spelling.substr(0U, end);
        }

        /**
         * @brief Renames generated symbols in first-use order.
         *
         * Both lowerings may number temporaries differently, and one module
         * shares one numbering because a lifted closure is named in its
         * parent and defined later. Source symbols are never renamed.
         */
        class Renamer final
        {
        public:
            void
            Apply(Prepared::SymbolName &symbol)
            {
                if (!IsGenerated(symbol))
                    return;
                const auto [found, inserted]
                    = names_.try_emplace(symbol.id, Prepared::SymbolName{});
                if (inserted)
                    found->second = { kCanonicalBase + names_.size(),
                                      KindOf(symbol.spelling) };
                symbol = found->second;
            }

            void
            Apply(Prepared::Atom &atom)
            {
                if (atom.kind == Prepared::Atom::Kind::Variable)
                    Apply(atom.symbol);
            }

        private:
            std::unordered_map<Prepared::SymbolId, Prepared::SymbolName> names_;
        };

        [[nodiscard]] auto
        Successors(const Prepared::Block &block)
            -> std::vector<Prepared::BlockId>
        {
            switch (block.terminator.kind)
            {
                case Prepared::Terminator::Kind::Jump:
                    return { block.terminator.true_target };
                case Prepared::Terminator::Kind::Branch:
                    return { block.terminator.true_target,
                             block.terminator.false_target };
                case Prepared::Terminator::Kind::Return:
                case Prepared::Terminator::Kind::Unreachable:
                    break;
            }
            return {};
        }

        /**
         * @brief Reorders reachable blocks in depth-first preorder.
         *
         * Block identities are allocation artifacts. Following the true
         * edge before the false edge from the entry gives both lowerings
         * the same order exactly when their control-flow graphs are
         * isomorphic with matching edge roles. Blocks that cannot be
         * reached from the entry, such as the join after two returning
         * branches, never execute and are left out.
         */
        void
        CanonicalizeBlocks(Prepared::Function &function)
        {
            std::unordered_map<Prepared::BlockId, std::size_t> position;
            for (std::size_t index = 0U; index < function.blocks.size();
                 ++index)
                position.emplace(function.blocks[index].id, index);

            std::unordered_map<Prepared::BlockId, Prepared::BlockId> renumbered;
            std::vector<std::size_t> order;
            std::vector<Prepared::BlockId> pending{ function.entry };
            while (!pending.empty())
            {
                const auto id = pending.back();
                pending.pop_back();
                const auto found = position.find(id);
                if (found == position.end() || renumbered.contains(id))
                    continue;
                renumbered.emplace(
                    id,
                    static_cast<Prepared::BlockId>(order.size()));
                order.push_back(found->second);
                auto successors = Successors(function.blocks[found->second]);
                // The stack reverses order, so push the false edge first.
                std::ranges::reverse(successors);
                pending.insert(pending.end(),
                               successors.begin(),
                               successors.end());
            }

            const auto target = [&renumbered](Prepared::BlockId id) {
                const auto found = renumbered.find(id);
                // A dangling target is a verifier matter; keep it distinct
                // from every canonical block.
                return found == renumbered.end() ? ~Prepared::BlockId{}
                                                 : found->second;
            };
            std::vector<Prepared::Block> blocks;
            blocks.reserve(order.size());
            for (const auto index : order)
            {
                auto block = std::move(function.blocks[index]);
                block.id = static_cast<Prepared::BlockId>(blocks.size());
                switch (block.terminator.kind)
                {
                    case Prepared::Terminator::Kind::Branch:
                        block.terminator.false_target
                            = target(block.terminator.false_target);
                        [[fallthrough]];
                    case Prepared::Terminator::Kind::Jump:
                        block.terminator.true_target
                            = target(block.terminator.true_target);
                        break;
                    case Prepared::Terminator::Kind::Return:
                    case Prepared::Terminator::Kind::Unreachable:
                        break;
                }
                blocks.push_back(std::move(block));
            }
            function.blocks = std::move(blocks);
            function.entry = 0U;
        }

        [[nodiscard]] auto
        Canonicalize(Prepared::CorePrepModule module)
            -> Prepared::CorePrepModule
        {
            Renamer renamer;
            for (auto &function : module.functions)
            {
                CanonicalizeBlocks(function);
                renamer.Apply(function.symbol);
                for (auto &parameter : function.parameters)
                    renamer.Apply(parameter.symbol);
                for (auto &block : function.blocks)
                {
                    for (auto &instruction : block.instructions)
                    {
                        // Operands are read before the destination is
                        // written, so name them first.
                        for (auto &operand : instruction.operands)
                            renamer.Apply(operand);
                        for (auto &capture : instruction.captures)
                        {
                            renamer.Apply(capture.value);
                            renamer.Apply(capture.symbol);
                        }
                        renamer.Apply(instruction.closure_function);
                        renamer.Apply(instruction.destination);
                    }
                    renamer.Apply(block.terminator.value);
                }
            }
            return module;
        }

        [[nodiscard]] auto
        Narrow(const std::u32string &text) -> std::string
        {
            std::string result;
            for (const auto point : text)
                result.push_back(point < 0x80U ? static_cast<char>(point)
                                               : '?');
            return result;
        }

        [[nodiscard]] auto
        Describe(const Prepared::Instruction &instruction) -> std::string
        {
            return "kind "
                   + std::to_string(static_cast<unsigned>(instruction.kind))
                   + ", operation "
                   + std::to_string(
                       static_cast<unsigned>(instruction.operation))
                   + ", destination " + Narrow(instruction.destination.spelling)
                   + ", " + std::to_string(instruction.operands.size())
                   + " operand(s)";
        }

        [[nodiscard]] auto
        Describe(const Prepared::Terminator &terminator) -> std::string
        {
            return "terminator kind "
                   + std::to_string(static_cast<unsigned>(terminator.kind))
                   + " -> " + std::to_string(terminator.true_target) + "/"
                   + std::to_string(terminator.false_target);
        }

        [[nodiscard]] auto
        FirstDifference(const Prepared::Function &frontend,
                        const Prepared::Function &native) -> std::string
        {
            if (frontend.symbol != native.symbol
                || frontend.parameters != native.parameters
                || frontend.return_type != native.return_type
                || frontend.sourceFile != native.sourceFile)
                return "signature or source owner differs";
            if (frontend.blocks.size() != native.blocks.size())
                return "reachable block count "
                       + std::to_string(frontend.blocks.size())
                       + " (frontend) versus "
                       + std::to_string(native.blocks.size()) + " (native)";
            for (std::size_t block = 0U; block < frontend.blocks.size();
                 ++block)
            {
                const auto &left = frontend.blocks[block];
                const auto &right = native.blocks[block];
                const auto where = "canonical block " + std::to_string(block);
                const auto shared = std::min(left.instructions.size(),
                                             right.instructions.size());
                for (std::size_t index = 0U; index < shared; ++index)
                    if (left.instructions[index] != right.instructions[index])
                        return where + ", instruction " + std::to_string(index)
                               + ": frontend {"
                               + Describe(left.instructions[index])
                               + "} versus native {"
                               + Describe(right.instructions[index]) + "}";
                if (left.instructions.size() != right.instructions.size())
                    return where + ": "
                           + std::to_string(left.instructions.size())
                           + " instruction(s) (frontend) versus "
                           + std::to_string(right.instructions.size())
                           + " (native)";
                if (left.terminator != right.terminator)
                    return where + ": frontend {" + Describe(left.terminator)
                           + "} versus native {" + Describe(right.terminator)
                           + "}";
            }
            return "functions differ outside their blocks";
        }
    } // namespace

    auto
    CompareCorePrep(const Prepared::CorePrepModule &frontend,
                    const Prepared::CorePrepModule &native)
        -> std::optional<std::string>
    {
        const auto left = Canonicalize(frontend);
        const auto right = Canonicalize(native);
        if (left == right)
            return std::nullopt;
        if (left.name != right.name || left.sourceFiles != right.sourceFiles)
            return "module name or source catalog differs";
        if (left.functions.size() != right.functions.size())
            return "function count " + std::to_string(left.functions.size())
                   + " (frontend) versus "
                   + std::to_string(right.functions.size()) + " (native)";
        for (std::size_t index = 0U; index < left.functions.size(); ++index)
            if (left.functions[index] != right.functions[index])
                return "function " + std::to_string(index) + " ("
                       + Narrow(left.functions[index].symbol.spelling) + "): "
                       + FirstDifference(left.functions[index],
                                         right.functions[index]);
        return "modules differ";
    }
} // namespace Progmasoft::Tala::Fuzzing
