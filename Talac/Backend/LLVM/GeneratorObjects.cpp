// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

// Objects the runtime owns: closures, their thunks and memoized values.

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
    Generator::CreateClosureThunk(llvm::StructType *payload,
                                  const xmm::Instruction &instruction,
                                  const std::vector<llvm::Type *> &captureTypes,
                                  const FunctionState &target)
        -> llvm::Function *
    {
        const auto signature = ::Progmasoft::Tala::Core::Callable::Decompose(
            instruction.result_type);
        if (!signature)
            return nullptr;

        auto *pointer = llvm::PointerType::get(context, 0);
        std::vector<llvm::Type *> parameterTypes{ pointer };
        parameterTypes.reserve(signature->parameters.size() + 1U);
        for (const auto &parameter : signature->parameters)
        {
            auto *lowered = types.Lower(parameter);
            if (lowered == nullptr || lowered->isVoidTy())
                return nullptr;
            parameterTypes.push_back(lowered);
        }
        auto *resultType = types.Lower(signature->result);
        if (resultType == nullptr)
            return nullptr;

        auto *thunkType
            = llvm::FunctionType::get(resultType, parameterTypes, false);
        const auto name
            = ".tala.aarc.closure.invoke." + std::to_string(closure_index);
        auto *thunk = llvm::Function::Create(thunkType,
                                             llvm::GlobalValue::InternalLinkage,
                                             name,
                                             module);
        auto *entry = llvm::BasicBlock::Create(context, "entry", thunk);
        llvm::IRBuilder<> thunkBuilder(entry);
        auto *environment = thunk->getArg(0U);

        // The lifted target ABI starts with one parameter per capture.
        // Strong captures can be borrowed directly because invoking
        // code holds the closure alive. Weak and unowned slots must be
        // atomically upgraded and balanced around the call so
        // destruction cannot race the body.
        std::vector<llvm::Value *> arguments;
        arguments.reserve(instruction.operands.size()
                          + signature->parameters.size());
        std::vector<llvm::Value *> temporaryStrong;
        temporaryStrong.reserve(instruction.operands.size());
        for (std::size_t index = 0; index < instruction.operands.size();
             ++index)
        {
            auto *slot = thunkBuilder.CreateStructGEP(
                payload,
                environment,
                static_cast<unsigned>(index + 1U));
            llvm::Value *captured = thunkBuilder.CreateLoad(captureTypes[index],
                                                            slot,
                                                            "capture.load");
            switch (instruction.capture_modes[index])
            {
                case core::CaptureMode::Strong:
                    break;
                case core::CaptureMode::Weak:
                    captured = thunkBuilder.CreateCall(
                        RuntimeFunction("tala_aarc_lock_weak",
                                        pointer,
                                        { pointer }),
                        { captured },
                        "capture.locked");
                    temporaryStrong.push_back(captured);
                    break;
                case core::CaptureMode::Unowned:
                    captured = thunkBuilder.CreateCall(
                        RuntimeFunction("tala_aarc_load_unowned",
                                        pointer,
                                        { pointer }),
                        { captured },
                        "capture.loaded");
                    temporaryStrong.push_back(captured);
                    break;
            }
            arguments.push_back(captured);
        }
        for (std::size_t index = 1U; index < thunk->arg_size(); ++index)
            arguments.push_back(thunk->getArg(static_cast<unsigned>(index)));

        const auto *callName = signature->result.kind == core::Type::Kind::Unit
                                   ? ""
                                   : "closure.result";
        auto *result = thunkBuilder.CreateCall(target.type,
                                               target.value,
                                               arguments,
                                               callName);
        for (auto *temporary : temporaryStrong)
            thunkBuilder.CreateCall(
                RuntimeFunction("tala_aarc_release_strong",
                                llvm::Type::getVoidTy(context),
                                { pointer }),
                { temporary });

        if (signature->result.kind == core::Type::Kind::Unit)
            thunkBuilder.CreateRetVoid();
        else
            thunkBuilder.CreateRet(result);
        return thunk;
    }

    /// Whether destroying a closure has anything to release: a strong capture
    /// of an object, or a weak or unowned handle. A closure over numbers and
    /// Booleans alone owns nothing.
    auto
    Generator::ClosureOwnsCaptures(
        const xmm::Instruction &instruction,
        const std::vector<llvm::Type *> &captureTypes) -> bool
    {
        for (std::size_t index = 0; index < instruction.operands.size();
             ++index)
            if (instruction.capture_modes[index] != core::CaptureMode::Strong
                || captureTypes[index]->isPointerTy())
                return true;
        return false;
    }

    /// The destructor of a closure, or null for a closure that owns nothing.
    /// The runtime runs no destructor for an object whose metadata names none,
    /// so such a closure costs no function of its own.
    auto
    Generator::CreateClosureDestructor(
        llvm::StructType *payload,
        const xmm::Instruction &instruction,
        const std::vector<llvm::Type *> &captureTypes) -> llvm::Function *
    {
        if (!ClosureOwnsCaptures(instruction, captureTypes))
            return nullptr;
        auto *pointer = llvm::PointerType::get(context, 0);
        auto *type = llvm::FunctionType::get(llvm::Type::getVoidTy(context),
                                             { pointer },
                                             false);
        const auto name
            = ".tala.aarc.closure.destroy." + std::to_string(closure_index);
        auto *destructor
            = llvm::Function::Create(type,
                                     llvm::GlobalValue::InternalLinkage,
                                     name,
                                     module);
        auto *entry = llvm::BasicBlock::Create(context, "entry", destructor);
        llvm::IRBuilder<> builder(entry);
        auto *object = destructor->getArg(0);

        for (std::size_t index = 0; index < instruction.operands.size();
             ++index)
        {
            const auto mode = instruction.capture_modes[index];
            const auto pointerCapture = captureTypes[index]->isPointerTy();
            if (mode == core::CaptureMode::Strong && !pointerCapture)
                continue;
            auto *slot
                = builder.CreateStructGEP(payload,
                                          object,
                                          static_cast<unsigned>(index + 1U));
            auto *captured = builder.CreateLoad(captureTypes[index], slot);
            if (mode == core::CaptureMode::Strong)
                builder.CreateCall(
                    RuntimeFunction("tala_aarc_release_strong",
                                    llvm::Type::getVoidTy(context),
                                    { pointer }),
                    { captured });
            else if (mode == core::CaptureMode::Weak)
                builder.CreateCall(
                    RuntimeFunction("tala_aarc_release_weak",
                                    llvm::Type::getVoidTy(context),
                                    { pointer }),
                    { captured });
            else
                builder.CreateCall(
                    RuntimeFunction("tala_aarc_release_unowned",
                                    llvm::Type::getVoidTy(context),
                                    { pointer }),
                    { captured });
        }
        builder.CreateRetVoid();
        return destructor;
    }

    /// The LLVM type of the metadata record an allocation is described by; it
    /// mirrors `TalaAarcTypeMetadata` of the public runtime ABI.
    auto
    Generator::ObjectMetadataType() -> llvm::StructType *
    {
        auto *pointer = llvm::PointerType::get(context, 0);
        auto *sizeType = llvm::Triple(module.getTargetTriple()).isArch64Bit()
                             ? llvm::Type::getInt64Ty(context)
                             : llvm::Type::getInt32Ty(context);
        std::array<llvm::Type *, 7U> fields{ llvm::Type::getInt32Ty(context),
                                             llvm::Type::getInt32Ty(context),
                                             llvm::Type::getInt64Ty(context),
                                             sizeType,
                                             sizeType,
                                             pointer,
                                             pointer };
        return llvm::StructType::get(context, fields, false);
    }

    /// Allocates an AARC object with the given payload and destructor.
    ///
    /// TypeMetadata mirrors the public runtime ABI. Size is expressed as an
    /// LLVM constant expression so the target data layout, not the host
    /// compiler, determines the payload size. A null destructor describes an
    /// object that owns nothing. A metadata record that the module already
    /// holds under the given name is used again.
    auto
    Generator::AllocateObject(llvm::IRBuilder<> &builder,
                              llvm::StructType *payload,
                              llvm::Function *destructor,
                              const std::string &metadataName,
                              const char *valueName) -> llvm::Value *
    {
        auto *pointer = llvm::PointerType::get(context, 0);
        if (auto *known = module.getNamedGlobal(metadataName))
            return builder.CreateCall(
                RuntimeFunction("tala_aarc_allocate", pointer, { pointer }),
                { known },
                valueName);
        auto *sizeType = llvm::Triple(module.getTargetTriple()).isArch64Bit()
                             ? llvm::Type::getInt64Ty(context)
                             : llvm::Type::getInt32Ty(context);
        auto *metadataType = ObjectMetadataType();
        auto *payloadSize = llvm::ConstantExpr::getSizeOf(payload);
        if (payloadSize->getType() != sizeType)
        {
            const auto sourceWidth
                = llvm::cast<llvm::IntegerType>(payloadSize->getType())
                      ->getBitWidth();
            const auto targetWidth
                = llvm::cast<llvm::IntegerType>(sizeType)->getBitWidth();
            payloadSize = llvm::ConstantExpr::getCast(
                sourceWidth < targetWidth ? llvm::Instruction::ZExt
                                          : llvm::Instruction::Trunc,
                payloadSize,
                sizeType);
        }
        std::array<llvm::Constant *, 7U> metadataValues{
            llvm::ConstantInt::get(llvm::Type::getInt32Ty(context), 2U),
            llvm::ConstantInt::get(llvm::Type::getInt32Ty(context), 0U),
            llvm::ConstantInt::get(llvm::Type::getInt64Ty(context), 0U),
            payloadSize,
            llvm::ConstantInt::get(sizeType, 16U),
            destructor != nullptr
                ? static_cast<llvm::Constant *>(destructor)
                : static_cast<llvm::Constant *>(
                      llvm::ConstantPointerNull::get(pointer)),
            llvm::ConstantPointerNull::get(pointer)
        };
        auto *metadata = new llvm::GlobalVariable(
            module,
            metadataType,
            true,
            llvm::GlobalValue::PrivateLinkage,
            llvm::ConstantStruct::get(metadataType, metadataValues),
            metadataName);
        return builder.CreateCall(
            RuntimeFunction("tala_aarc_allocate", pointer, { pointer }),
            { metadata },
            valueName);
    }

    /// Lowers a callable that remembers its result.
    ///
    /// The value is an object of its own around the callable that computes the
    /// result. Like every closure it starts with its invoke entry, so a call
    /// site calls it as it calls any callable. Behind the entry it keeps
    /// whether it has a result, the result, and the callable. The entry calls
    /// the callable when there is no result yet, keeps what it returned, and
    /// returns the kept result from then on. Every holder of the object sees
    /// the same result, which is what lets a caller and the method it calls
    /// share one computation.
    ///
    /// The object owns the callable and releases it when it is destroyed. The
    /// result owns nothing: the verifiers admit only Bool and numeric results.
    /// A call that does not return leaves the object without a result.
    ///
    /// Nothing in the object's code depends on which computation it holds, so a
    /// module has one payload type, one entry, one destructor and one metadata
    /// record for each result type, however many values it suspends.
    auto
    Generator::LowerMemoize(llvm::IRBuilder<> &builder,
                            FunctionState &state,
                            const xmm::Instruction &instruction)
        -> llvm::Value *
    {
        const auto signature = ::Progmasoft::Tala::Core::Callable::Decompose(
            instruction.result_type);
        if (!signature || !signature->parameters.empty()
            || instruction.operands.size() != 1U)
            return nullptr;
        auto *resultType = types.Lower(signature->result);
        if (resultType == nullptr || resultType->isVoidTy())
            return nullptr;
        auto *computation
            = LoadValue(builder, state, instruction.operands.front());
        if (computation == nullptr || !computation->getType()->isPointerTy())
            return nullptr;

        constexpr unsigned kInvoke = 0U;
        constexpr unsigned kKnown = 1U;
        constexpr unsigned kResult = 2U;
        constexpr unsigned kComputation = 3U;
        std::string index;
        {
            llvm::raw_string_ostream spelling(index);
            resultType->print(spelling);
        }
        auto *pointer = llvm::PointerType::get(context, 0);
        auto *flagType = llvm::Type::getInt8Ty(context);
        auto *payload = llvm::StructType::getTypeByName(
            context,
            ".tala.aarc.memo.payload." + index);
        if (payload == nullptr)
            payload = llvm::StructType::create(
                context,
                { pointer, flagType, resultType, pointer },
                ".tala.aarc.memo.payload." + index);

        auto *invokeType
            = llvm::FunctionType::get(resultType, { pointer }, false);
        auto *invoke = module.getFunction(".tala.aarc.memo.invoke." + index);
        if (invoke == nullptr)
        {
            invoke = llvm::Function::Create(invokeType,
                                            llvm::GlobalValue::InternalLinkage,
                                            ".tala.aarc.memo.invoke." + index,
                                            module);
            auto *entry = llvm::BasicBlock::Create(context, "entry", invoke);
            auto *compute
                = llvm::BasicBlock::Create(context, "compute", invoke);
            auto *done = llvm::BasicBlock::Create(context, "done", invoke);
            auto *self = invoke->getArg(0U);
            llvm::IRBuilder<> body(entry);
            auto *known
                = body.CreateLoad(flagType,
                                  body.CreateStructGEP(payload, self, kKnown),
                                  "memo.known");
            body.CreateCondBr(
                body.CreateICmpNE(known, llvm::ConstantInt::get(flagType, 0U)),
                done,
                compute);

            body.SetInsertPoint(compute);
            auto *held = body.CreateLoad(
                pointer,
                body.CreateStructGEP(payload, self, kComputation),
                "memo.computation");
            // The callable is a closure: its payload begins with its own invoke
            // entry, which takes the closure and returns the result.
            auto *target = body.CreateLoad(pointer, held, "memo.target");
            auto *computed = body.CreateCall(invokeType,
                                             target,
                                             { held },
                                             "memo.computed");
            body.CreateStore(computed,
                             body.CreateStructGEP(payload, self, kResult));
            body.CreateStore(llvm::ConstantInt::get(flagType, 1U),
                             body.CreateStructGEP(payload, self, kKnown));
            body.CreateBr(done);

            body.SetInsertPoint(done);
            body.CreateRet(
                body.CreateLoad(resultType,
                                body.CreateStructGEP(payload, self, kResult),
                                "memo.result"));
        }

        auto *destructor
            = module.getFunction(".tala.aarc.memo.destroy." + index);
        if (destructor == nullptr)
        {
            destructor = llvm::Function::Create(
                llvm::FunctionType::get(llvm::Type::getVoidTy(context),
                                        { pointer },
                                        false),
                llvm::GlobalValue::InternalLinkage,
                ".tala.aarc.memo.destroy." + index,
                module);
            llvm::IRBuilder<> body(
                llvm::BasicBlock::Create(context, "entry", destructor));
            auto *held
                = body.CreateLoad(pointer,
                                  body.CreateStructGEP(payload,
                                                       destructor->getArg(0U),
                                                       kComputation));
            body.CreateCall(RuntimeFunction("tala_aarc_release_strong",
                                            llvm::Type::getVoidTy(context),
                                            { pointer }),
                            { held });
            body.CreateRetVoid();
        }

        auto *object = AllocateObject(builder,
                                      payload,
                                      destructor,
                                      ".tala.aarc.memo.metadata." + index,
                                      "memo");
        builder.CreateStore(invoke,
                            builder.CreateStructGEP(payload, object, kInvoke));
        builder.CreateStore(llvm::ConstantInt::get(flagType, 0U),
                            builder.CreateStructGEP(payload, object, kKnown));
        builder.CreateStore(llvm::Constant::getNullValue(resultType),
                            builder.CreateStructGEP(payload, object, kResult));
        // The operand stays with its own owner; the object takes a reference
        // of its own.
        auto *owned = builder.CreateCall(
            RuntimeFunction("tala_aarc_retain_strong", pointer, { pointer }),
            { computation },
            "memo.owned");
        builder.CreateStore(
            owned,
            builder.CreateStructGEP(payload, object, kComputation));
        return object;
    }

    auto
    Generator::LowerClosure(llvm::IRBuilder<> &builder,
                            FunctionState &state,
                            const xmm::Instruction &instruction)
        -> llvm::Value *
    {
        const auto target = functions.find(instruction.closure_function);
        if (target == functions.end()
            || instruction.capture_modes.size() != instruction.operands.size())
            return nullptr;

        auto *pointer = llvm::PointerType::get(context, 0);
        std::vector<llvm::Type *> captureTypes;
        captureTypes.reserve(instruction.operands.size());
        std::vector<llvm::Type *> fields{ pointer };
        for (std::size_t index = 0; index < instruction.operands.size();
             ++index)
        {
            auto *type
                = instruction.capture_modes[index] == core::CaptureMode::Strong
                      ? types.Lower(instruction.operands[index].type)
                      : pointer;
            if (type == nullptr || type->isVoidTy())
                return nullptr;
            captureTypes.push_back(type);
            fields.push_back(type);
        }
        auto *payload = llvm::StructType::create(
            context,
            fields,
            ".tala.aarc.closure.payload." + std::to_string(closure_index));
        auto *thunk = CreateClosureThunk(payload,
                                         instruction,
                                         captureTypes,
                                         target->second);
        auto *destructor
            = CreateClosureDestructor(payload, instruction, captureTypes);
        if (thunk == nullptr)
            return nullptr;

        auto *object = AllocateObject(builder,
                                      payload,
                                      destructor,
                                      ".tala.aarc.closure.metadata."
                                          + std::to_string(closure_index++),
                                      "closure");
        builder.CreateStore(thunk,
                            builder.CreateStructGEP(payload, object, 0U));

        for (std::size_t index = 0; index < instruction.operands.size();
             ++index)
        {
            auto *captured
                = LoadValue(builder, state, instruction.operands[index]);
            if (captured == nullptr)
                return nullptr;
            const auto mode = instruction.capture_modes[index];
            if (mode == core::CaptureMode::Strong
                && captureTypes[index]->isPointerTy())
                captured = builder.CreateCall(
                    RuntimeFunction("tala_aarc_retain_strong",
                                    pointer,
                                    { pointer }),
                    { captured },
                    "capture.strong");
            else if (mode == core::CaptureMode::Weak)
                captured
                    = builder.CreateCall(RuntimeFunction("tala_aarc_make_weak",
                                                         pointer,
                                                         { pointer }),
                                         { captured },
                                         "capture.weak");
            else if (mode == core::CaptureMode::Unowned)
                captured = builder.CreateCall(
                    RuntimeFunction("tala_aarc_make_unowned",
                                    pointer,
                                    { pointer }),
                    { captured },
                    "capture.unowned");
            builder.CreateStore(
                captured,
                builder.CreateStructGEP(payload,
                                        object,
                                        static_cast<unsigned>(index + 1U)));
        }
        return object;
    }
} // namespace Progmasoft::Tala::Backend::LLVM::Generation
