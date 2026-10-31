// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

// Arithmetic whose result or whose failure LLVM has no single instruction for.

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

    auto
    Generator::LowerSignedRoundedDiv(llvm::IRBuilder<> &builder,
                                     llvm::Value *left,
                                     llvm::Value *right) -> llvm::Value *
    {
        // `//` rounds to the nearest integer and sends an exact half
        // away from zero. Keep every comparison in the original integer
        // width: unsigned two's-complement magnitude represents
        // abs(MIN) without introducing an overflowing signed
        // absolute-value call.
        auto *quotient = builder.CreateSDiv(left, right, "rounded.quotient");
        auto *remainder = builder.CreateSRem(left, right, "rounded.remainder");
        auto *zero = llvm::Constant::getNullValue(left->getType());
        auto *one = llvm::ConstantInt::get(left->getType(), 1U);
        auto magnitude = [&](llvm::Value *value, const char *name) {
            auto *negative = builder.CreateICmpSLT(value, zero);
            return builder.CreateSelect(negative,
                                        builder.CreateNeg(value),
                                        value,
                                        name);
        };
        auto *remainderMagnitude
            = magnitude(remainder, "rounded.remainder.magnitude");
        auto *divisorMagnitude = magnitude(right, "rounded.divisor.magnitude");
        auto *half = builder.CreateLShr(divisorMagnitude, one, "rounded.half");
        auto *odd
            = builder.CreateAnd(divisorMagnitude, one, "rounded.divisor.odd");
        auto *threshold = builder.CreateAdd(half, odd, "rounded.threshold");
        auto *adjust = builder.CreateICmpUGE(remainderMagnitude,
                                             threshold,
                                             "rounded.adjust");
        auto *signBits = builder.CreateXor(left, right, "rounded.sign.bits");
        auto *sameSign
            = builder.CreateICmpSGE(signBits, zero, "rounded.same.sign");
        auto *direction = builder.CreateSelect(
            sameSign,
            one,
            llvm::ConstantInt::getSigned(
                llvm::cast<llvm::IntegerType>(left->getType()),
                -1));
        auto *adjusted
            = builder.CreateAdd(quotient, direction, "rounded.adjusted");
        return builder.CreateSelect(adjust,
                                    adjusted,
                                    quotient,
                                    "rounded.result");
    }

    auto
    Generator::LowerUnsignedRoundedDiv(llvm::IRBuilder<> &builder,
                                       llvm::Value *left,
                                       llvm::Value *right) -> llvm::Value *
    {
        auto *one = llvm::ConstantInt::get(left->getType(), 1U);
        auto *quotient = builder.CreateUDiv(left, right, "rounded.quotient");
        auto *remainder = builder.CreateURem(left, right, "rounded.remainder");
        auto *half = builder.CreateLShr(right, one, "rounded.half");
        auto *odd = builder.CreateAnd(right, one, "rounded.divisor.odd");
        auto *threshold = builder.CreateAdd(half, odd, "rounded.threshold");
        auto *adjust
            = builder.CreateICmpUGE(remainder, threshold, "rounded.adjust");
        auto *adjusted = builder.CreateAdd(quotient, one, "rounded.adjusted");
        return builder.CreateSelect(adjust,
                                    adjusted,
                                    quotient,
                                    "rounded.result");
    }

    auto
    Generator::LowerFloatingRoundedDiv(llvm::IRBuilder<> &builder,
                                       llvm::Value *left,
                                       llvm::Value *right) -> llvm::Value *
    {
        auto *quotient = builder.CreateFDiv(left, right, "rounded.quotient");
        auto *roundIntrinsic
            = llvm::Intrinsic::getOrInsertDeclaration(&module,
                                                      llvm::Intrinsic::round,
                                                      { left->getType() });
        auto *rounded = builder.CreateCall(roundIntrinsic,
                                           { quotient },
                                           "rounded.integral");
        return builder.CreateFPToSI(rounded,
                                    llvm::Type::getInt64Ty(context),
                                    "rounded.result");
    }

    auto
    Generator::IntegerPowerFunction(llvm::IntegerType *type) -> llvm::Function *
    {
        const auto name = "__tala_pow_i" + std::to_string(type->getBitWidth());
        if (auto *existing = module.getFunction(name))
            return existing;

        auto *functionType
            = llvm::FunctionType::get(type, { type, type }, false);
        auto *function
            = llvm::Function::Create(functionType,
                                     llvm::GlobalValue::InternalLinkage,
                                     name,
                                     module);
        auto argument = function->arg_begin();
        auto *baseArgument = &*argument++;
        auto *exponentArgument = &*argument;
        baseArgument->setName("base");
        exponentArgument->setName("exponent");

        auto *entry = llvm::BasicBlock::Create(context, "entry", function);
        auto *loop = llvm::BasicBlock::Create(context, "loop", function);
        auto *body = llvm::BasicBlock::Create(context, "body", function);
        auto *exit = llvm::BasicBlock::Create(context, "exit", function);
        llvm::IRBuilder<> powerBuilder(entry);
        powerBuilder.CreateBr(loop);

        powerBuilder.SetInsertPoint(loop);
        auto *result = powerBuilder.CreatePHI(type, 2U, "result");
        auto *base = powerBuilder.CreatePHI(type, 2U, "factor");
        auto *exponent = powerBuilder.CreatePHI(type, 2U, "remaining");
        auto *zero = llvm::ConstantInt::get(type, 0U);
        auto *one = llvm::ConstantInt::get(type, 1U);
        result->addIncoming(one, entry);
        base->addIncoming(baseArgument, entry);
        exponent->addIncoming(exponentArgument, entry);
        powerBuilder.CreateCondBr(powerBuilder.CreateICmpNE(exponent, zero),
                                  body,
                                  exit);

        powerBuilder.SetInsertPoint(body);
        auto *odd
            = powerBuilder.CreateICmpNE(powerBuilder.CreateAnd(exponent, one),
                                        zero,
                                        "odd");
        auto *multiplied = powerBuilder.CreateMul(result, base, "multiplied");
        auto *nextResult
            = powerBuilder.CreateSelect(odd, multiplied, result, "next.result");
        auto *nextBase = powerBuilder.CreateMul(base, base, "next.factor");
        auto *nextExponent
            = powerBuilder.CreateLShr(exponent, one, "next.remaining");
        powerBuilder.CreateBr(loop);
        result->addIncoming(nextResult, body);
        base->addIncoming(nextBase, body);
        exponent->addIncoming(nextExponent, body);

        powerBuilder.SetInsertPoint(exit);
        powerBuilder.CreateRet(result);
        return function;
    }

    // Values that cannot be computed.
    //
    // An integer quotient or remainder by zero, and a shift by an amount that
    // is negative or not less than the width of the shifted value, have no
    // value. A program that needs one fails: it stops there. LLVM gives the
    // same instructions no meaning at all, so without a check an optimizer may
    // remove the computation, or the code after it, as if the program had never
    // needed the value. Each such instruction is therefore preceded by a check
    // that stops the program, and the instruction itself only ever runs on
    // operands it has a value for.

    /// The function that stops the program when its two operands are equal or,
    /// with `below` unset, when the first is not below the second as unsigned
    /// numbers. It is small and always inlined, so that the check costs a
    /// comparison where the operand is not known and nothing where it is.
    auto
    Generator::ComputabilityCheck(llvm::IntegerType *type, bool below)
        -> llvm::Function *
    {
        const auto name = std::string(below ? ".tala.check.below.i"
                                            : ".tala.check.differs.i")
                          + std::to_string(type->getBitWidth());
        if (auto *existing = module.getFunction(name))
            return existing;
        auto *function = llvm::Function::Create(
            llvm::FunctionType::get(llvm::Type::getVoidTy(context),
                                    { type, type },
                                    false),
            llvm::GlobalValue::InternalLinkage,
            name,
            module);
        function->addFnAttr(llvm::Attribute::AlwaysInline);
        function->addFnAttr(llvm::Attribute::NoUnwind);
        auto *entry = llvm::BasicBlock::Create(context, "entry", function);
        auto *fails = llvm::BasicBlock::Create(context, "fails", function);
        auto *computable
            = llvm::BasicBlock::Create(context, "computable", function);
        llvm::IRBuilder<> body(entry);
        auto *holds = below ? body.CreateICmpULT(function->getArg(0U),
                                                 function->getArg(1U))
                            : body.CreateICmpNE(function->getArg(0U),
                                                function->getArg(1U));
        body.CreateCondBr(holds, computable, fails);
        body.SetInsertPoint(fails);
        body.CreateCall(
            llvm::Intrinsic::getOrInsertDeclaration(&module,
                                                    llvm::Intrinsic::trap));
        body.CreateUnreachable();
        body.SetInsertPoint(computable);
        body.CreateRetVoid();
        return function;
    }

    /// Stops the program when an integer divisor is zero, and gives the divisor
    /// the division is carried out with.
    ///
    /// The least value of a signed type divided by minus one has a quotient one
    /// above the greatest value of the type. That is a result that does not
    /// fit, not a value that cannot be computed, and generated code lets every
    /// other integer result that does not fit wrap. Wrapped, the quotient is
    /// the least value again and the remainder is zero, which is what dividing
    /// by one gives; the division is carried out with one. The processor's own
    /// instruction would stop the program instead.
    auto
    Generator::ComputableDivisor(llvm::IRBuilder<> &builder,
                                 llvm::Value *dividend,
                                 llvm::Value *divisor,
                                 bool isSigned) -> llvm::Value *
    {
        auto *type = llvm::cast<llvm::IntegerType>(divisor->getType());
        builder.CreateCall(ComputabilityCheck(type, false),
                           { divisor, llvm::ConstantInt::get(type, 0U) });
        if (!isSigned)
            return divisor;
        auto *least = llvm::ConstantInt::get(
            type,
            llvm::APInt::getSignedMinValue(type->getBitWidth()));
        auto *wraps = builder.CreateAnd(
            builder.CreateICmpEQ(dividend, least),
            builder.CreateICmpEQ(divisor,
                                 llvm::ConstantInt::getSigned(type, -1)),
            "quotient.wraps");
        return builder.CreateSelect(wraps,
                                    llvm::ConstantInt::get(type, 1U),
                                    divisor,
                                    "divisor");
    }

    /// Stops the program when a shift amount is negative or not less than the
    /// width of the shifted value.
    void
    Generator::RequireShiftAmount(llvm::IRBuilder<> &builder,
                                  llvm::Value *amount)
    {
        auto *type = llvm::cast<llvm::IntegerType>(amount->getType());
        builder.CreateCall(
            ComputabilityCheck(type, true),
            { amount, llvm::ConstantInt::get(type, type->getBitWidth()) });
    }
} // namespace Progmasoft::Tala::Backend::LLVM::Generation
