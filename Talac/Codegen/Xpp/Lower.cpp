// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstdlib>
#include <utility>

#include "Progmasoft/Tala/Xpp/IR.hpp"

namespace tala::xpp
{
    namespace
    {
        auto
        LowerOperand(const core::Atom &atom) -> Operand
        {
            // CorePrep has already resolved names, so the numeric symbol is
            // authoritative here. Spelling remains on declarations for
            // diagnostics and eventual external mangling.
            return Operand{ atom.kind == core::Atom::Kind::Variable
                                ? Operand::Kind::Symbol
                                : Operand::Kind::Literal,
                            atom.type,
                            atom.symbol.id,
                            atom.literal };
        }

        auto
        LowerOperation(core::Operation operation) -> Opcode
        {
            switch (operation)
            {
                case core::Operation::Copy:
                    return Opcode::Copy;
                case core::Operation::Call:
                    return Opcode::Call;
                case core::Operation::Add:
                    return Opcode::Add;
                case core::Operation::Subtract:
                    return Opcode::Subtract;
                case core::Operation::Multiply:
                    return Opcode::Multiply;
                case core::Operation::Divide:
                    return Opcode::Divide;
                case core::Operation::FloorDivide:
                    return Opcode::FloorDivide;
                case core::Operation::Remainder:
                    return Opcode::Remainder;
                case core::Operation::LessThan:
                    return Opcode::CompareLess;
                case core::Operation::LessEqual:
                    return Opcode::CompareLessEqual;
                case core::Operation::GreaterThan:
                    return Opcode::CompareGreater;
                case core::Operation::GreaterEqual:
                    return Opcode::CompareGreaterEqual;
                case core::Operation::Equal:
                    return Opcode::CompareEqual;
                case core::Operation::NotEqual:
                    return Opcode::CompareNotEqual;
                case core::Operation::LogicalAnd:
                    return Opcode::LogicalAnd;
                case core::Operation::LogicalOr:
                    return Opcode::LogicalOr;
                case core::Operation::Negate:
                    return Opcode::Negate;
                case core::Operation::LogicalNot:
                    return Opcode::LogicalNot;
                case core::Operation::Power:
                    return Opcode::Power;
                case core::Operation::ShiftLeft:
                    return Opcode::ShiftLeft;
                case core::Operation::ShiftRight:
                    return Opcode::ShiftRight;
                case core::Operation::BitwiseAnd:
                    return Opcode::BitwiseAnd;
                case core::Operation::BitwiseXor:
                    return Opcode::BitwiseXor;
                case core::Operation::BitwiseOr:
                    return Opcode::BitwiseOr;
                case core::Operation::BitwiseNot:
                    return Opcode::BitwiseNot;
                case core::Operation::TypeIs:
                    return Opcode::TypeIs;
                case core::Operation::Memoize:
                    return Opcode::Memoize;
                case core::Operation::RuntimeCall:
                    return Opcode::RuntimeCall;
                case core::Operation::MakeClosure:
                    return Opcode::MakeClosure;
            }
            // An unknown CorePrep operation indicates an adapter/version bug;
            // translating it to Copy would silently change program semantics.
            std::abort();
        }

        auto
        LowerInstruction(const core::Instruction &instruction) -> Instruction
        {
            Instruction lowered{};
            // Preserve Bind/Assign/Discard as an explicit effect. Collapsing
            // them into opcode alone would lose the difference between defining
            // storage and mutating it.
            lowered.effect
                = instruction.kind == core::Instruction::Kind::Bind
                      ? Instruction::Effect::Define
                  : instruction.kind == core::Instruction::Kind::Assign
                      ? Instruction::Effect::Store
                      : Instruction::Effect::Discard;
            lowered.opcode = LowerOperation(instruction.operation);
            lowered.destination = instruction.destination.id;
            lowered.result_type = instruction.type;
            lowered.operands.reserve(instruction.operands.size());
            for (const auto &operand : instruction.operands)
                lowered.operands.push_back(LowerOperand(operand));
            if (instruction.operation == core::Operation::MakeClosure)
            {
                lowered.closure_function = instruction.closure_function.id;
                lowered.operands.reserve(instruction.captures.size());
                lowered.capture_modes.reserve(instruction.captures.size());
                for (const auto &capture : instruction.captures)
                {
                    lowered.operands.push_back(LowerOperand(capture.value));
                    lowered.capture_modes.push_back(capture.mode);
                }
            }
            return lowered;
        }

        auto
        LowerTerminator(const core::Terminator &terminator) -> Terminator
        {
            Terminator lowered{};
            switch (terminator.kind)
            {
                case core::Terminator::Kind::Return:
                    lowered.kind = Terminator::Kind::Return;
                    break;
                case core::Terminator::Kind::Branch:
                    lowered.kind = Terminator::Kind::Branch;
                    break;
                case core::Terminator::Kind::Jump:
                    lowered.kind = Terminator::Kind::Jump;
                    break;
                case core::Terminator::Kind::Unreachable:
                    lowered.kind = Terminator::Kind::Unreachable;
                    break;
            }
            lowered.value = LowerOperand(terminator.value);
            lowered.true_target = terminator.true_target;
            lowered.false_target = terminator.false_target;
            return lowered;
        }

    } // namespace

    auto
    lower(const core::CorePrepModule &module) -> Module
    {
        Module lowered{ module.name, {}, module.sourceFiles };
        lowered.functions.reserve(module.functions.size());
        for (const auto &function : module.functions)
        {
            Function loweredFunction{ function.symbol,
                                      function.parameters,
                                      function.return_type,
                                      function.entry,
                                      {} };
            loweredFunction.source_file = function.sourceFile;
            loweredFunction.blocks.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
            {
                Block loweredBlock{ block.id,
                                    {},
                                    LowerTerminator(block.terminator) };
                loweredBlock.instructions.reserve(block.instructions.size());
                for (const auto &instruction : block.instructions)
                    loweredBlock.instructions.push_back(
                        LowerInstruction(instruction));
                loweredFunction.blocks.push_back(std::move(loweredBlock));
            }
            lowered.functions.push_back(std::move(loweredFunction));
        }
        return lowered;
    }

} // namespace tala::xpp
