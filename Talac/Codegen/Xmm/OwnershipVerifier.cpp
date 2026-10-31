// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <optional>
#include <string>
#include <utility>

#include "Progmasoft/Tala/Analysis/OwnershipFlow.hpp"
#include "Progmasoft/Tala/Core/Ownership.hpp"
#include "Progmasoft/Tala/Xmm/OwnershipVerifier.hpp"

namespace Progmasoft::Tala::Xmm
{
    namespace Core = ::tala::core;
    namespace IR = ::tala::xmm;
    namespace Flow = ::Progmasoft::Tala::Analysis::OwnershipFlow;

    namespace
    {
        [[nodiscard]] auto
        IsAarcType(const Core::Type &type) -> bool
        {
            // Named types reaching Xmm do not yet carry a nominal declaration
            // catalog. Conservatively tracking them is safer than allowing a
            // class handle to bypass lifetime verification.
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
        AppendRead(const IR::Value &value,
                   Flow::HandleKind expected,
                   std::size_t instruction,
                   bool terminator,
                   std::vector<Flow::Action> &actions)
        {
            if (value.kind != IR::Value::Kind::Register
                || !IsAarcType(value.type))
                return;
            actions.push_back({ Flow::ActionKind::Observe,
                                value.reg,
                                expected,
                                instruction,
                                terminator });
        }

        void
        AppendInstruction(const IR::Instruction &instruction,
                          std::size_t index,
                          std::vector<Flow::Action> &actions)
        {
            const auto ownershipOpcode = IsOwnershipOpcode(instruction.opcode);
            for (const auto &operand : instruction.operands)
            {
                if (operand.kind != IR::Value::Kind::Register
                    || !IsAarcType(operand.type))
                    continue;
                actions.push_back(
                    { ownershipOpcode && ConsumesOwnership(instruction.opcode)
                          ? Flow::ActionKind::Consume
                          : Flow::ActionKind::Observe,
                      operand.reg,
                      ownershipOpcode ? InputKind(instruction.opcode)
                                      : Flow::HandleKind::Strong,
                      index,
                      false });
            }

            if (!instruction.has_result || instruction.destination == 0U)
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
        Adapt(const IR::Function &function) -> Flow::Function
        {
            Flow::Function model;
            model.entry = function.entry;
            const auto parameterCount
                = std::min(function.parameter_registers.size(),
                           function.parameter_types.size());
            model.initialHandles.reserve(parameterCount);
            for (std::size_t index = 0U; index < parameterCount; ++index)
                if (IsAarcType(function.parameter_types[index]))
                    model.initialHandles.push_back(
                        { function.parameter_registers[index],
                          Flow::HandleKind::Strong });

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
                                      flowBlock.actions);
                if (block.terminator.kind == IR::Terminator::Kind::Return)
                    AppendRead(block.terminator.value,
                               Flow::HandleKind::Strong,
                               block.instructions.size(),
                               true,
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
                        IssueKind::OwnershipUseAfterRelease,
                        "TAL1046",
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
                        IssueKind::OwnershipKindMismatch,
                        "TAL1047",
                        "ownership operation uses handle "
                            + std::to_string(issue.handle)
                            + " as the wrong runtime representation",
                        function,
                        issue.block,
                        issue.instruction
                    };
                case Flow::IssueKind::PathStateMismatch:
                    return VerificationIssue{
                        IssueKind::OwnershipPathMismatch,
                        "TAL1048",
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
                    // The structural verifier reports these with the
                    // established Xmm diagnostic codes. Ownership must not
                    // duplicate them.
                    return std::nullopt;
            }
            return std::nullopt;
        }
    } // namespace

    auto
    VerifyOwnership(const IR::Function &function)
        -> std::vector<VerificationIssue>
    {
        std::vector<VerificationIssue> issues;
        const auto result
            = Flow::Analyze(Adapt(function), { .materializeFacts = false });
        issues.reserve(result.issues.size());
        for (const auto &issue : result.issues)
            if (auto translated = Translate(issue, function.symbol.id))
                issues.push_back(std::move(*translated));
        return issues;
    }
} // namespace Progmasoft::Tala::Xmm
