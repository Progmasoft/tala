// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <cstdlib>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#include "Progmasoft/Tala/Xmm/IR.hpp"

namespace tala::xmm
{
    namespace
    {
        struct RegisterMap final
        {
            // Allocate deterministically on first encounter while preserving
            // one register for each resolved symbol across all blocks. Register
            // zero remains invalid/reserved.
            std::unordered_map<xpp::SymbolId, VirtualRegister> registers;
            VirtualRegister next{ 1U };

            void
            Reserve(xpp::SymbolId symbol)
            {
                if (!registers.contains(symbol))
                    registers.emplace(symbol, next++);
            }

            auto
            Get(xpp::SymbolId symbol) -> VirtualRegister
            {
                Reserve(symbol);
                return registers.at(symbol);
            }
        };

        [[nodiscard]] auto
        RegisterMapFor(const xpp::Function &function) -> RegisterMap
        {
            RegisterMap map;
            // Parameter register order is ABI-visible. Local identities are
            // then assigned in numeric symbol order so a wire decoder or CFG
            // optimizer may reorder blocks without renumbering the function.
            for (const auto &parameter : function.parameters)
                map.Reserve(parameter.symbol.id);

            std::vector<xpp::SymbolId> locals;
            for (const auto &block : function.blocks)
                for (const auto &instruction : block.instructions)
                    if (instruction.effect != xpp::Instruction::Effect::Discard)
                        locals.push_back(instruction.destination);
            std::ranges::sort(locals);
            locals.erase(std::unique(locals.begin(), locals.end()),
                         locals.end());
            for (const auto symbol : locals)
                map.Reserve(symbol);
            return map;
        }

        auto
        LowerOpcode(xpp::Opcode opcode) -> Opcode
        {
            switch (opcode)
            {
                case xpp::Opcode::Copy:
                    return Opcode::Move;
                case xpp::Opcode::Call:
                    return Opcode::Call;
                case xpp::Opcode::Add:
                    return Opcode::Add;
                case xpp::Opcode::Subtract:
                    return Opcode::Subtract;
                case xpp::Opcode::Multiply:
                    return Opcode::Multiply;
                case xpp::Opcode::Divide:
                    return Opcode::Divide;
                case xpp::Opcode::FloorDivide:
                    return Opcode::FloorDivide;
                case xpp::Opcode::Remainder:
                    return Opcode::Remainder;
                case xpp::Opcode::CompareLess:
                    return Opcode::CompareLess;
                case xpp::Opcode::CompareLessEqual:
                    return Opcode::CompareLessEqual;
                case xpp::Opcode::CompareGreater:
                    return Opcode::CompareGreater;
                case xpp::Opcode::CompareGreaterEqual:
                    return Opcode::CompareGreaterEqual;
                case xpp::Opcode::CompareEqual:
                    return Opcode::CompareEqual;
                case xpp::Opcode::CompareNotEqual:
                    return Opcode::CompareNotEqual;
                case xpp::Opcode::LogicalAnd:
                    return Opcode::AndBool;
                case xpp::Opcode::LogicalOr:
                    return Opcode::OrBool;
                case xpp::Opcode::Negate:
                    return Opcode::Negate;
                case xpp::Opcode::LogicalNot:
                    return Opcode::NotBool;
                case xpp::Opcode::Power:
                    return Opcode::Power;
                case xpp::Opcode::ShiftLeft:
                    return Opcode::ShiftLeft;
                case xpp::Opcode::ShiftRight:
                    return Opcode::ShiftRight;
                case xpp::Opcode::BitwiseAnd:
                    return Opcode::BitwiseAnd;
                case xpp::Opcode::BitwiseXor:
                    return Opcode::BitwiseXor;
                case xpp::Opcode::BitwiseOr:
                    return Opcode::BitwiseOr;
                case xpp::Opcode::BitwiseNot:
                    return Opcode::BitwiseNot;
                case xpp::Opcode::TypeIs:
                    return Opcode::TypeIs;
                case xpp::Opcode::Memoize:
                    return Opcode::Memoize;
                case xpp::Opcode::RuntimeCall:
                    return Opcode::RuntimeCall;
                case xpp::Opcode::MakeClosure:
                    return Opcode::MakeClosure;
                case xpp::Opcode::RetainStrong:
                    return Opcode::RetainStrong;
                case xpp::Opcode::ReleaseStrong:
                    return Opcode::ReleaseStrong;
                case xpp::Opcode::MakeWeak:
                    return Opcode::MakeWeak;
                case xpp::Opcode::LockWeak:
                    return Opcode::LockWeak;
                case xpp::Opcode::ReleaseWeak:
                    return Opcode::ReleaseWeak;
                case xpp::Opcode::MakeUnowned:
                    return Opcode::MakeUnowned;
                case xpp::Opcode::LoadUnowned:
                    return Opcode::LoadUnowned;
                case xpp::Opcode::ReleaseUnowned:
                    return Opcode::ReleaseUnowned;
            }
            // Never turn a newly added Xpp opcode into a plausible Move. The
            // explicit failure keeps stage-version drift observable in tests.
            std::abort();
        }

        auto
        LowerValue(const xpp::Operand &operand,
                   RegisterMap &map,
                   const std::unordered_set<xpp::SymbolId> &directFunctions)
            -> Value
        {
            if (operand.kind == xpp::Operand::Kind::Symbol)
            {
                if (operand.type.kind == core::Type::Kind::Function
                    && directFunctions.contains(operand.symbol))
                    // Direct callees retain symbol identity and never consume a
                    // data register. Function-typed local storage is
                    // deliberately excluded: it contains an AARC closure
                    // pointer and must become an ordinary Xmm register.
                    return Value{ Value::Kind::Function,
                                  operand.type,
                                  0U,
                                  operand.symbol,
                                  {} };
                return Value{ Value::Kind::Register,
                              operand.type,
                              map.Get(operand.symbol),
                              0U,
                              {} };
            }
            return Value{ Value::Kind::Immediate,
                          operand.type,
                          0U,
                          0U,
                          operand.literal };
        }

        auto
        LowerTerminator(
            const xpp::Terminator &terminator,
            RegisterMap &map,
            const std::unordered_set<xpp::SymbolId> &directFunctions)
            -> Terminator
        {
            Terminator lowered{
                Terminator::Kind::Unreachable,
                LowerValue(terminator.value, map, directFunctions),
                terminator.true_target,
                terminator.false_target,
            };
            switch (terminator.kind)
            {
                case xpp::Terminator::Kind::Return:
                    lowered.kind = Terminator::Kind::Return;
                    break;
                case xpp::Terminator::Kind::Branch:
                    lowered.kind = Terminator::Kind::Branch;
                    break;
                case xpp::Terminator::Kind::Jump:
                    lowered.kind = Terminator::Kind::Jump;
                    break;
                case xpp::Terminator::Kind::Unreachable:
                    lowered.kind = Terminator::Kind::Unreachable;
                    break;
            }
            return lowered;
        }

    } // namespace

    auto
    lower(const xpp::Module &module) -> Module
    {
        Module lowered{ module.name, {}, module.source_files };
        lowered.functions.reserve(module.functions.size());
        std::unordered_set<xpp::SymbolId> directFunctions;
        directFunctions.reserve(module.functions.size());
        for (const auto &function : module.functions)
            directFunctions.insert(function.symbol.id);
        for (const auto &function : module.functions)
        {
            auto registerMap = RegisterMapFor(function);
            Function loweredFunction{
                function.symbol, {}, {}, function.return_type,
                function.entry,  {}
            };
            loweredFunction.source_file = function.source_file;
            for (const auto &parameter : function.parameters)
            {
                loweredFunction.parameter_registers.push_back(
                    registerMap.Get(parameter.symbol.id));
                loweredFunction.parameter_types.push_back(parameter.type);
            }
            loweredFunction.blocks.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
            {
                Block loweredBlock{ block.id, {}, {} };
                loweredBlock.instructions.reserve(block.instructions.size());
                for (const auto &instruction : block.instructions)
                {
                    Instruction loweredInstruction{};
                    loweredInstruction.opcode = LowerOpcode(instruction.opcode);
                    loweredInstruction.has_result
                        = instruction.effect
                          != xpp::Instruction::Effect::Discard;
                    loweredInstruction.result_type = instruction.result_type;
                    if (loweredInstruction.has_result)
                        loweredInstruction.destination
                            = registerMap.Get(instruction.destination);
                    for (const auto &operand : instruction.operands)
                        loweredInstruction.operands.push_back(
                            LowerValue(operand, registerMap, directFunctions));
                    loweredInstruction.closure_function
                        = instruction.closure_function;
                    loweredInstruction.capture_modes
                        = instruction.capture_modes;
                    loweredBlock.instructions.push_back(
                        std::move(loweredInstruction));
                }
                loweredBlock.terminator = LowerTerminator(block.terminator,
                                                          registerMap,
                                                          directFunctions);
                loweredFunction.blocks.push_back(std::move(loweredBlock));
            }
            lowered.functions.push_back(std::move(loweredFunction));
        }
        return lowered;
    }

} // namespace tala::xmm
