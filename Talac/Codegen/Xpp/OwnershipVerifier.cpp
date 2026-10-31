// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <optional>
#include <string>
#include <unordered_set>
#include <utility>

#include "Progmasoft/Tala/Analysis/OwnershipFlow.hpp"
#include "Progmasoft/Tala/Core/Ownership.hpp"
#include "Progmasoft/Tala/Xpp/OwnershipVerifier.hpp"

namespace Progmasoft::Tala::Xpp
{
    namespace Core = ::tala::core;
    namespace IR = ::tala::xpp;
    namespace Flow = ::Progmasoft::Tala::Analysis::OwnershipFlow;

    namespace
    {
        [[nodiscard]] auto
        IsAarcType(const Core::Type &type) -> bool
        {
            return Core::UsesAarc(type) || type.kind == Core::Type::Kind::Named;
        }

        [[nodiscard]] auto
        IsOwnershipOpcode(IR::Opcode opcode) -> bool
        {
            return opcode >= IR::Opcode::RetainStrong
                   && opcode <= IR::Opcode::ReleaseUnowned;
        }

        [[nodiscard]] auto
        ConsumesOwnership(IR::Opcode opcode) -> bool
        {
            return opcode == IR::Opcode::ReleaseStrong
                   || opcode == IR::Opcode::ReleaseWeak
                   || opcode == IR::Opcode::ReleaseUnowned;
        }

        [[nodiscard]] auto
        InputKind(IR::Opcode opcode) -> Flow::HandleKind
        {
            switch (opcode)
            {
                case IR::Opcode::LockWeak:
                case IR::Opcode::ReleaseWeak:
                    return Flow::HandleKind::Weak;
                case IR::Opcode::LoadUnowned:
                case IR::Opcode::ReleaseUnowned:
                    return Flow::HandleKind::Unowned;
                default:
                    return Flow::HandleKind::Strong;
            }
        }

        [[nodiscard]] auto
        ResultKind(IR::Opcode opcode) -> Flow::HandleKind
        {
            switch (opcode)
            {
                case IR::Opcode::MakeWeak:
                    return Flow::HandleKind::Weak;
                case IR::Opcode::MakeUnowned:
                    return Flow::HandleKind::Unowned;
                default:
                    return Flow::HandleKind::Strong;
            }
        }

        [[nodiscard]] auto
        Successors(const IR::Terminator &terminator)
            -> std::vector<Flow::BlockId>
        {
            switch (terminator.kind)
            {
                case IR::Terminator::Kind::Branch:
                    return { terminator.true_target, terminator.false_target };
                case IR::Terminator::Kind::Jump:
                    return { terminator.true_target };
                case IR::Terminator::Kind::Return:
                case IR::Terminator::Kind::Unreachable:
                    return {};
            }
            return {};
        }

        void
        AppendRead(const IR::Operand &operand,
                   Flow::HandleKind expected,
                   std::size_t instruction,
                   bool terminator,
                   const std::unordered_set<IR::SymbolId> &functions,
                   std::vector<Flow::Action> &actions)
        {
            if (operand.kind != IR::Operand::Kind::Symbol
                || functions.contains(operand.symbol)
                || !IsAarcType(operand.type))
                return;
            actions.push_back({ Flow::ActionKind::Observe,
                                operand.symbol,
                                expected,
                                instruction,
                                terminator });
        }

        void
        AppendInstruction(const IR::Instruction &instruction,
                          std::size_t index,
                          const std::unordered_set<IR::SymbolId> &functions,
                          std::vector<Flow::Action> &actions)
        {
            const auto ownershipOpcode = IsOwnershipOpcode(instruction.opcode);
            for (const auto &operand : instruction.operands)
            {
                if (operand.kind != IR::Operand::Kind::Symbol
                    || functions.contains(operand.symbol)
                    || !IsAarcType(operand.type))
                    continue;
                actions.push_back(
                    { ownershipOpcode && ConsumesOwnership(instruction.opcode)
                          ? Flow::ActionKind::Consume
                          : Flow::ActionKind::Observe,
                      operand.symbol,
                      ownershipOpcode ? InputKind(instruction.opcode)
                                      : Flow::HandleKind::Strong,
                      index,
                      false });
            }

            if (instruction.effect == IR::Instruction::Effect::Discard
                || instruction.destination == 0U)
                return;
            actions.push_back({ IsAarcType(instruction.result_type)
                                    ? Flow::ActionKind::Define
                                    : Flow::ActionKind::Forget,
                                instruction.destination,
                                ownershipOpcode ? ResultKind(instruction.opcode)
                                                : Flow::HandleKind::Strong,
                                index,
                                false });
        }

        [[nodiscard]] auto
        Adapt(const IR::Function &function,
              const std::unordered_set<IR::SymbolId> &functions)
            -> Flow::Function
        {
            Flow::Function model;
            model.entry = function.entry;
            model.initialHandles.reserve(function.parameters.size());
            for (const auto &parameter : function.parameters)
                if (IsAarcType(parameter.type))
                    model.initialHandles.push_back(
                        { parameter.symbol.id, Flow::HandleKind::Strong });

            model.blocks.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
            {
                Flow::Block flowBlock;
                flowBlock.id = block.id;
                flowBlock.successors = Successors(block.terminator);
                flowBlock.actions.reserve(block.instructions.size() * 2U + 1U);
                for (std::size_t index = 0U; index < block.instructions.size();
                     ++index)
                    AppendInstruction(block.instructions[index],
                                      index,
                                      functions,
                                      flowBlock.actions);
                if (block.terminator.kind == IR::Terminator::Kind::Return)
                    AppendRead(block.terminator.value,
                               Flow::HandleKind::Strong,
                               block.instructions.size(),
                               true,
                               functions,
                               flowBlock.actions);
                model.blocks.push_back(std::move(flowBlock));
            }
            return model;
        }

        [[nodiscard]] auto
        Translate(const Flow::Issue &issue, Core::SymbolId function)
            -> std::optional<VerificationIssue>
        {
            switch (issue.kind)
            {
                case Flow::IssueKind::UseAfterConsume:
                    return VerificationIssue{
                        "TAP1042",
                        issue.terminator ? "return uses ownership handle "
                                               + std::to_string(issue.handle)
                                               + " after it was released"
                                         : "instruction uses ownership handle "
                                               + std::to_string(issue.handle)
                                               + " after it was released",
                        function,
                        issue.block,
                        issue.instruction
                    };
                case Flow::IssueKind::HandleKindMismatch:
                    return VerificationIssue{
                        "TAP1043",
                        "ownership operation uses handle "
                            + std::to_string(issue.handle)
                            + " as the wrong runtime representation",
                        function,
                        issue.block,
                        issue.instruction
                    };
                case Flow::IssueKind::PathStateMismatch:
                    return VerificationIssue{
                        "TAP1044",
                        "ownership handle " + std::to_string(issue.handle)
                            + " has incompatible live, released, or "
                              "representation states across incoming paths",
                        function,
                        issue.block,
                        issue.instruction
                    };
                case Flow::IssueKind::DuplicateBlock:
                case Flow::IssueKind::MissingEntry:
                case Flow::IssueKind::InvalidTarget:
                case Flow::IssueKind::InvalidInitialHandle:
                case Flow::IssueKind::ConflictingInitialKind:
                case Flow::IssueKind::InvalidActionHandle:
                    return std::nullopt;
            }
            return std::nullopt;
        }
    } // namespace

    auto
    VerifyOwnership(const IR::Module &module) -> std::vector<VerificationIssue>
    {
        std::unordered_set<IR::SymbolId> functions;
        functions.reserve(module.functions.size());
        for (const auto &function : module.functions)
            if (function.symbol.id != 0U)
                functions.insert(function.symbol.id);

        std::vector<VerificationIssue> issues;
        for (const auto &function : module.functions)
        {
            const auto result = Flow::Analyze(Adapt(function, functions),
                                              { .materializeFacts = false });
            for (const auto &issue : result.issues)
                if (auto translated = Translate(issue, function.symbol.id))
                    issues.push_back(std::move(*translated));
        }
        return issues;
    }
} // namespace Progmasoft::Tala::Xpp
