// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// One Xmm instruction or terminator at a time.

#include <algorithm>
#include <array>
#include <limits>
#include <llvm/ADT/APInt.h>
#include <llvm/ADT/SmallVector.h>
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/IR/BasicBlock.h>
#include <llvm/IR/Constants.h>
#include <llvm/IR/DerivedTypes.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/GlobalVariable.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/Intrinsics.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/LegacyPassManager.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/Verifier.h>
#include <llvm/MC/TargetRegistry.h>
#include <llvm/Passes/OptimizationLevel.h>
#include <llvm/Passes/PassBuilder.h>
#include <llvm/Support/CodeGen.h>
#include <llvm/Support/TargetSelect.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm/Target/TargetOptions.h>
#include <llvm/TargetParser/Host.h>
#include <llvm/TargetParser/Triple.h>
#include <memory>
#include <mutex>
#include <ranges>
#include <string>
#include <unordered_map>
#include <utility>

#include "Generator.hpp"

namespace Progmasoft::Tala::Backend::LLVM::Generation
{

    /// Lowers a call of a function of the runtime.
    ///
    /// The verifiers have checked the call against its row of the catalog. An
    /// argument that the row gives a family of types is widened here to the one
    /// representation the runtime function is written for: a signed integer is
    /// sign-extended and an unsigned one zero-extended to sixty-four bits, and
    /// a floating-point number is extended to a `double`. None of these changes
    /// the value. A string result arrives with a reference the caller owns;
    /// when nothing takes it, it is released here. A Boolean result arrives as
    /// the byte the C ABI returns and is narrowed to the one bit a Bool is
    /// here.
    auto
    Generator::LowerRuntimeCall(llvm::IRBuilder<> &builder,
                                FunctionState &state,
                                const xmm::Instruction &instruction) -> bool
    {
        namespace runtime = core::runtime;
        if (instruction.operands.empty()
            || instruction.operands.front().kind != xmm::Value::Kind::Immediate)
            return false;
        const auto identity
            = runtime::IdentityOf(instruction.operands.front().immediate,
                                  instruction.operands.front().type);
        const auto *signature = identity ? runtime::Find(*identity) : nullptr;
        if (signature == nullptr
            || instruction.operands.size() != signature->parameters.size() + 1U)
            return false;

        auto *pointer = llvm::PointerType::get(context, 0);
        auto *word = llvm::Type::getInt64Ty(context);
        std::vector<llvm::Type *> parameterTypes;
        std::vector<llvm::Value *> arguments;
        parameterTypes.reserve(signature->parameters.size());
        arguments.reserve(signature->parameters.size());
        for (std::size_t index = 0U; index < signature->parameters.size();
             ++index)
        {
            auto *value
                = LoadValue(builder, state, instruction.operands[index + 1U]);
            if (value == nullptr)
                return false;
            llvm::Type *expected = word;
            switch (signature->parameters[index])
            {
                case runtime::Parameter::Signed:
                case runtime::Parameter::Count:
                    if (!value->getType()->isIntegerTy())
                        return false;
                    value = builder.CreateSExtOrTrunc(value,
                                                      word,
                                                      "runtime.signed");
                    break;
                case runtime::Parameter::Unsigned:
                    if (!value->getType()->isIntegerTy())
                        return false;
                    value = builder.CreateZExtOrTrunc(value,
                                                      word,
                                                      "runtime.unsigned");
                    break;
                case runtime::Parameter::Floating:
                    expected = llvm::Type::getDoubleTy(context);
                    if (!value->getType()->isFloatingPointTy())
                        return false;
                    if (value->getType() != expected)
                        value = builder.CreateFPExt(value,
                                                    expected,
                                                    "runtime.floating");
                    break;
                case runtime::Parameter::Bool:
                    // The C ABI passes a `bool` as a byte that is zero or one.
                    expected = llvm::Type::getInt8Ty(context);
                    if (!value->getType()->isIntegerTy())
                        return false;
                    value = builder.CreateZExtOrTrunc(value,
                                                      expected,
                                                      "runtime.bool");
                    break;
                case runtime::Parameter::Char:
                    expected = llvm::Type::getInt32Ty(context);
                    if (!value->getType()->isIntegerTy())
                        return false;
                    value = builder.CreateZExtOrTrunc(value,
                                                      expected,
                                                      "runtime.char");
                    break;
                case runtime::Parameter::Text:
                    expected = pointer;
                    if (!value->getType()->isPointerTy())
                        return false;
                    break;
            }
            parameterTypes.push_back(expected);
            arguments.push_back(value);
        }

        const auto yieldsText = signature->result == runtime::Result::Text;
        const auto yieldsTruth = signature->result == runtime::Result::Truth;
        auto callee = module.getOrInsertFunction(
            std::string(signature->symbol),
            llvm::FunctionType::get(yieldsText ? pointer
                                    : yieldsTruth
                                        ? llvm::Type::getInt8Ty(context)
                                        : llvm::Type::getVoidTy(context),
                                    parameterTypes,
                                    false));
        auto *result = builder.CreateCall(callee,
                                          arguments,
                                          yieldsText    ? "runtime.text"
                                          : yieldsTruth ? "runtime.truth"
                                                        : "");
        if (yieldsTruth)
        {
            if (instruction.has_result)
                builder.CreateStore(
                    builder.CreateICmpNE(
                        result,
                        llvm::ConstantInt::get(result->getType(), 0U),
                        "runtime.bool"),
                    state.slots.at(instruction.destination));
            return true;
        }
        if (!yieldsText)
            return true;
        if (instruction.has_result)
            builder.CreateStore(result,
                                state.slots.at(instruction.destination));
        else
            builder.CreateCall(RuntimeFunction("tala_aarc_release_strong",
                                               llvm::Type::getVoidTy(context),
                                               { pointer }),
                               { result });
        return true;
    }

    auto
    Generator::LowerInstruction(llvm::IRBuilder<> &builder,
                                FunctionState &state,
                                const xmm::Instruction &instruction) -> bool
    {
        if (instruction.opcode == xmm::Opcode::RuntimeCall)
            return LowerRuntimeCall(builder, state, instruction);
        if (instruction.opcode == xmm::Opcode::Call)
        {
            auto *result = LowerCall(builder, state, instruction);
            if (result == nullptr)
                return false;
            if (instruction.has_result)
                builder.CreateStore(result,
                                    state.slots.at(instruction.destination));
            return true;
        }
        if (instruction.opcode == xmm::Opcode::MakeClosure
            || instruction.opcode == xmm::Opcode::Memoize)
        {
            auto *result = instruction.opcode == xmm::Opcode::Memoize
                               ? LowerMemoize(builder, state, instruction)
                               : LowerClosure(builder, state, instruction);
            if (result == nullptr)
                return false;
            if (instruction.has_result)
                builder.CreateStore(result,
                                    state.slots.at(instruction.destination));
            else
            {
                // Closure construction retains every strong capture, and a
                // remembering callable retains its computation.  A discarded
                // one still performs those observable ownership actions, but
                // its temporary owner must be released immediately or a dead
                // expression leaks both the object and what it holds.
                builder.CreateCall(
                    RuntimeFunction("tala_aarc_release_strong",
                                    llvm::Type::getVoidTy(context),
                                    { llvm::PointerType::get(context, 0) }),
                    { result });
            }
            return true;
        }
        if (instruction.opcode >= xmm::Opcode::RetainStrong
            && instruction.opcode <= xmm::Opcode::ReleaseUnowned)
            return LowerOwnership(builder, state, instruction);
        std::vector<llvm::Value *> operands;
        operands.reserve(instruction.operands.size());
        for (const auto &operand : instruction.operands)
            operands.push_back(LoadValue(builder, state, operand));
        if (std::ranges::any_of(operands, [](const llvm::Value *value) {
                return value == nullptr;
            }))
            return false;

        llvm::Value *result{};
        const auto &operandType = instruction.operands.empty()
                                      ? instruction.result_type
                                      : instruction.operands.front().type;
        const auto floating = core::is_floating(operandType);
        const auto unsignedInteger
            = core::is_unsigned_integer(operandType)
              || operandType.kind == core::Type::Kind::Character;
        switch (instruction.opcode)
        {
            case xmm::Opcode::Divide:
            case xmm::Opcode::FloorDivide:
            case xmm::Opcode::Remainder:
                if (!floating)
                    operands[1] = ComputableDivisor(builder,
                                                    operands[0],
                                                    operands[1],
                                                    !unsignedInteger);
                break;
            case xmm::Opcode::ShiftLeft:
            case xmm::Opcode::ShiftRight:
                RequireShiftAmount(builder, operands[1]);
                break;
            default:
                break;
        }
        switch (instruction.opcode)
        {
            case xmm::Opcode::LoadImmediate:
            case xmm::Opcode::Move:
                result = operands[0];
                break;
            case xmm::Opcode::Add:
                result
                    = floating
                          ? builder.CreateFAdd(operands[0], operands[1], "add")
                          : builder.CreateAdd(operands[0], operands[1], "add");
                break;
            case xmm::Opcode::Subtract:
                result
                    = floating
                          ? builder.CreateFSub(operands[0], operands[1], "sub")
                          : builder.CreateSub(operands[0], operands[1], "sub");
                break;
            case xmm::Opcode::Multiply:
                result
                    = floating
                          ? builder.CreateFMul(operands[0], operands[1], "mul")
                          : builder.CreateMul(operands[0], operands[1], "mul");
                break;
            case xmm::Opcode::Divide:
                result
                    = floating
                          ? builder.CreateFDiv(operands[0], operands[1], "div")
                      : unsignedInteger
                          ? builder.CreateUDiv(operands[0], operands[1], "div")
                          : builder.CreateSDiv(operands[0], operands[1], "div");
                break;
            case xmm::Opcode::FloorDivide:
                result = floating ? LowerFloatingRoundedDiv(builder,
                                                            operands[0],
                                                            operands[1])
                         : unsignedInteger
                             ? LowerUnsignedRoundedDiv(builder,
                                                       operands[0],
                                                       operands[1])
                             : LowerSignedRoundedDiv(builder,
                                                     operands[0],
                                                     operands[1]);
                break;
            case xmm::Opcode::Remainder:
                result
                    = floating
                          ? builder.CreateFRem(operands[0], operands[1], "rem")
                      : unsignedInteger
                          ? builder.CreateURem(operands[0], operands[1], "rem")
                          : builder.CreateSRem(operands[0], operands[1], "rem");
                break;
            case xmm::Opcode::Power:
                if (floating)
                {
                    auto *intrinsic = llvm::Intrinsic::getOrInsertDeclaration(
                        &module,
                        llvm::Intrinsic::pow,
                        { operands[0]->getType() });
                    result = builder.CreateCall(intrinsic,
                                                { operands[0], operands[1] },
                                                "power");
                }
                else
                    result = builder.CreateCall(
                        IntegerPowerFunction(llvm::cast<llvm::IntegerType>(
                            operands[0]->getType())),
                        { operands[0], operands[1] },
                        "power");
                break;
            case xmm::Opcode::ShiftLeft:
                result
                    = builder.CreateShl(operands[0], operands[1], "shift.left");
                break;
            case xmm::Opcode::ShiftRight:
                result = unsignedInteger ? builder.CreateLShr(operands[0],
                                                              operands[1],
                                                              "shift.right")
                                         : builder.CreateAShr(operands[0],
                                                              operands[1],
                                                              "shift.right");
                break;
            case xmm::Opcode::BitwiseAnd:
                result = builder.CreateAnd(operands[0],
                                           operands[1],
                                           "bitwise.and");
                break;
            case xmm::Opcode::BitwiseXor:
                result = builder.CreateXor(operands[0],
                                           operands[1],
                                           "bitwise.xor");
                break;
            case xmm::Opcode::BitwiseOr:
                result
                    = builder.CreateOr(operands[0], operands[1], "bitwise.or");
                break;
            case xmm::Opcode::BitwiseNot:
                result = builder.CreateNot(operands[0], "bitwise.not");
                break;
            case xmm::Opcode::TypeIs:
                result = builder.CreateCall(
                    RuntimeFunction("tala_aarc_is_exact_type",
                                    llvm::Type::getInt1Ty(context),
                                    { llvm::PointerType::get(context, 0),
                                      llvm::Type::getInt64Ty(context) }),
                    { operands[0], operands[1] },
                    "type.is");
                break;
            case xmm::Opcode::CompareLess:
                result = floating          ? builder.CreateFCmpOLT(operands[0],
                                                                   operands[1],
                                                                   "less")
                         : unsignedInteger ? builder.CreateICmpULT(operands[0],
                                                                   operands[1],
                                                                   "less")
                                           : builder.CreateICmpSLT(operands[0],
                                                                   operands[1],
                                                                   "less");
                break;
            case xmm::Opcode::CompareLessEqual:
                result = floating ? builder.CreateFCmpOLE(operands[0],
                                                          operands[1],
                                                          "less.equal")
                         : unsignedInteger
                             ? builder.CreateICmpULE(operands[0],
                                                     operands[1],
                                                     "less.equal")
                             : builder.CreateICmpSLE(operands[0],
                                                     operands[1],
                                                     "less.equal");
                break;
            case xmm::Opcode::CompareGreater:
                result = floating          ? builder.CreateFCmpOGT(operands[0],
                                                                   operands[1],
                                                                   "greater")
                         : unsignedInteger ? builder.CreateICmpUGT(operands[0],
                                                                   operands[1],
                                                                   "greater")
                                           : builder.CreateICmpSGT(operands[0],
                                                                   operands[1],
                                                                   "greater");
                break;
            case xmm::Opcode::CompareGreaterEqual:
                result = floating ? builder.CreateFCmpOGE(operands[0],
                                                          operands[1],
                                                          "greater.equal")
                         : unsignedInteger
                             ? builder.CreateICmpUGE(operands[0],
                                                     operands[1],
                                                     "greater.equal")
                             : builder.CreateICmpSGE(operands[0],
                                                     operands[1],
                                                     "greater.equal");
                break;
            case xmm::Opcode::CompareEqual:
                result = floating ? builder.CreateFCmpOEQ(operands[0],
                                                          operands[1],
                                                          "equal")
                                  : builder.CreateICmpEQ(operands[0],
                                                         operands[1],
                                                         "equal");
                break;
            case xmm::Opcode::CompareNotEqual:
                result = floating ? builder.CreateFCmpUNE(operands[0],
                                                          operands[1],
                                                          "not.equal")
                                  : builder.CreateICmpNE(operands[0],
                                                         operands[1],
                                                         "not.equal");
                break;
            case xmm::Opcode::AndBool:
                result = builder.CreateAnd(operands[0],
                                           operands[1],
                                           "logical.and");
                break;
            case xmm::Opcode::OrBool:
                result
                    = builder.CreateOr(operands[0], operands[1], "logical.or");
                break;
            case xmm::Opcode::Negate:
                result = floating ? builder.CreateFNeg(operands[0], "negate")
                                  : builder.CreateNeg(operands[0], "negate");
                break;
            case xmm::Opcode::NotBool:
                result = builder.CreateNot(operands[0], "logical.not");
                break;
            case xmm::Opcode::Call:
            case xmm::Opcode::MakeClosure:
            case xmm::Opcode::Memoize:
            case xmm::Opcode::RuntimeCall:
            case xmm::Opcode::RetainStrong:
            case xmm::Opcode::ReleaseStrong:
            case xmm::Opcode::MakeWeak:
            case xmm::Opcode::LockWeak:
            case xmm::Opcode::ReleaseWeak:
            case xmm::Opcode::MakeUnowned:
            case xmm::Opcode::LoadUnowned:
            case xmm::Opcode::ReleaseUnowned:
                break;
        }
        if (instruction.has_result && result != nullptr)
            builder.CreateStore(result,
                                state.slots.at(instruction.destination));
        return result != nullptr;
    }

    auto
    Generator::LowerTerminator(llvm::IRBuilder<> &builder,
                               FunctionState &state,
                               const xmm::Terminator &terminator) -> bool
    {
        switch (terminator.kind)
        {
            case xmm::Terminator::Kind::Return:
                if (state.source->return_type.kind == core::Type::Kind::Unit)
                    builder.CreateRetVoid();
                else
                {
                    auto *value = LoadValue(builder, state, terminator.value);
                    if (value == nullptr)
                        return false;
                    builder.CreateRet(value);
                }
                return true;
            case xmm::Terminator::Kind::Branch:
            {
                auto *condition = LoadValue(builder, state, terminator.value);
                if (condition == nullptr)
                    return false;
                builder.CreateCondBr(condition,
                                     state.blocks.at(terminator.true_target),
                                     state.blocks.at(terminator.false_target));
                return true;
            }
            case xmm::Terminator::Kind::Jump:
                builder.CreateBr(state.blocks.at(terminator.true_target));
                return true;
            case xmm::Terminator::Kind::Unreachable:
                builder.CreateUnreachable();
                return true;
        }
        return false;
    }
} // namespace Progmasoft::Tala::Backend::LLVM::Generation
