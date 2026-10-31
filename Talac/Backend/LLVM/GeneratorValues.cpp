// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

// Values, calls and the ownership operations on them.

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
    Generator::StringLiteral(llvm::IRBuilder<> &builder,
                             const std::u32string &text) -> llvm::Value *
    {
        // Store one i32 per Unicode scalar. Tala String is
        // intentionally not UTF-8: scalar indexing must not depend on
        // the encoded byte width of earlier text. A trailing zero is
        // storage convenience only and is excluded from the length.
        auto *i32 = llvm::Type::getInt32Ty(context);
        std::vector<llvm::Constant *> units;
        units.reserve(text.size() + 1U);
        for (const auto point : text)
        {
            const auto scalar = static_cast<std::uint32_t>(point);
            if (scalar > 0x10ffffU || (scalar >= 0xd800U && scalar <= 0xdfffU))
            {
                fail(ErrorKind::InvalidUnicode,
                     "TAL2003",
                     "String literal contains an invalid Unicode "
                     "scalar");
                return nullptr;
            }
            units.push_back(llvm::ConstantInt::get(i32, scalar, false));
        }
        units.push_back(llvm::ConstantInt::get(i32, 0, false));
        auto *arrayType = llvm::ArrayType::get(i32, units.size());
        auto *initializer = llvm::ConstantArray::get(arrayType, units);
        const auto name = ".tala.string." + std::to_string(string_index++);
        auto *global
            = new llvm::GlobalVariable(module,
                                       arrayType,
                                       true,
                                       llvm::GlobalValue::PrivateLinkage,
                                       initializer,
                                       name);
        global->setUnnamedAddr(llvm::GlobalValue::UnnamedAddr::Global);
        auto *pointer = llvm::PointerType::get(context, 0);
        auto *sizeType = llvm::Triple(module.getTargetTriple()).isArch64Bit()
                             ? llvm::Type::getInt64Ty(context)
                             : llvm::Type::getInt32Ty(context);
        auto literalFactory = module.getOrInsertFunction(
            "tala_aarc_string_literal",
            llvm::FunctionType::get(pointer, { pointer, sizeType }, false));
        return builder.CreateCall(
            literalFactory,
            { global, llvm::ConstantInt::get(sizeType, text.size(), false) },
            "string.literal");
    }

    auto
    Generator::Immediate(llvm::IRBuilder<> &builder, const xmm::Value &value)
        -> llvm::Value *
    {
        const auto integer_constant
            = [this, &value](core::IntegerLiteral integer) -> llvm::Value * {
            integer = core::normalize_integer(std::move(integer));
            const auto description = core::describe_scalar(value.type);
            if (!description
                || (description->family != core::ScalarFamily::Character
                    && !description->is_integer()))
                return nullptr;
            llvm::APInt bits(description->bit_width,
                             core::integer_hex_magnitude(integer),
                             16);
            if (integer.negative)
                bits = -bits;
            return llvm::ConstantInt::get(context, bits);
        };
        switch (value.type.kind)
        {
            case core::Type::Kind::Unit:
                return nullptr;
            case core::Type::Kind::Bool:
                return llvm::ConstantInt::get(
                    llvm::Type::getInt1Ty(context),
                    std::get<bool>(value.immediate) ? 1U : 0U);
            case core::Type::Kind::Character:
            case core::Type::Kind::Int8:
            case core::Type::Kind::Int16:
            case core::Type::Kind::Int64:
            case core::Type::Kind::Int32:
            case core::Type::Kind::Int128:
            case core::Type::Kind::UInt8:
            case core::Type::Kind::UInt16:
            case core::Type::Kind::UInt32:
            case core::Type::Kind::UInt64:
            case core::Type::Kind::UInt128:
                if (const auto *integer
                    = std::get_if<core::IntegerLiteral>(&value.immediate))
                    return integer_constant(*integer);
                if (const auto *integer64
                    = std::get_if<std::int64_t>(&value.immediate))
                    return integer_constant(
                        core::integer_from_signed(*integer64));
                if (const auto *integer32
                    = std::get_if<std::int32_t>(&value.immediate))
                    return integer_constant(
                        core::integer_from_signed(*integer32));
                return nullptr;
            case core::Type::Kind::Float16:
            case core::Type::Kind::Float32:
            case core::Type::Kind::Float64:
            case core::Type::Kind::Float128:
                if (const auto *floating
                    = std::get_if<core::FloatingLiteral>(&value.immediate))
                    return llvm::ConstantFP::get(types.Lower(value.type),
                                                 floating->spelling);
                return nullptr;
            case core::Type::Kind::String:
                if (std::holds_alternative<std::monostate>(value.immediate))
                    return llvm::ConstantPointerNull::get(
                        llvm::PointerType::get(context, 0));
                return StringLiteral(builder,
                                     std::get<std::u32string>(value.immediate));
            case core::Type::Kind::Function:
            case core::Type::Kind::Named:
                if (std::holds_alternative<std::monostate>(value.immediate))
                    return llvm::ConstantPointerNull::get(
                        llvm::PointerType::get(context, 0));
                return nullptr;
            case core::Type::Kind::TypeVariable:
                return nullptr;
        }
        return nullptr;
    }

    auto
    Generator::LoadValue(llvm::IRBuilder<> &builder,
                         FunctionState &state,
                         const xmm::Value &value) -> llvm::Value *
    {
        if (value.kind == xmm::Value::Kind::Immediate)
            return Immediate(builder, value);
        if (value.kind == xmm::Value::Kind::Function)
        {
            const auto found = functions.find(value.symbol);
            return found == functions.end() ? nullptr : found->second.value;
        }
        const auto slot = state.slots.find(value.reg);
        if (slot == state.slots.end())
            return nullptr;
        const auto name = "r" + std::to_string(value.reg) + ".load";
        return builder.CreateLoad(types.Lower(value.type), slot->second, name);
    }

    auto
    Generator::LowerCall(llvm::IRBuilder<> &builder,
                         FunctionState &state,
                         const xmm::Instruction &instruction) -> llvm::Value *
    {
        if (instruction.operands.empty())
            return nullptr;
        std::vector<llvm::Value *> arguments;
        arguments.reserve(instruction.operands.size() - 1U);
        for (std::size_t index = 1; index < instruction.operands.size();
             ++index)
            arguments.push_back(
                LoadValue(builder, state, instruction.operands[index]));
        if (std::ranges::any_of(arguments, [](const llvm::Value *value) {
                return value == nullptr;
            }))
            return nullptr;
        const auto *name
            = instruction.result_type.kind == core::Type::Kind::Unit
                  ? ""
                  : "call.result";

        if (instruction.operands.front().kind == xmm::Value::Kind::Function)
        {
            // Direct functions retain symbol identity through Xmm.
            // Resolving that identity here keeps recursion and forward
            // calls independent of source order without allocating a
            // closure for ordinary declarations.
            const auto target
                = functions.find(instruction.operands.front().symbol);
            if (target == functions.end())
                return nullptr;
            return builder.CreateCall(target->second.type,
                                      target->second.value,
                                      arguments,
                                      name);
        }

        if (instruction.operands.front().kind != xmm::Value::Kind::Register)
            return nullptr;
        const auto signature = ::Progmasoft::Tala::Core::Callable::Decompose(
            instruction.operands.front().type);
        if (!signature)
            return nullptr;
        auto *closure = LoadValue(builder, state, instruction.operands.front());
        if (closure == nullptr || !closure->getType()->isPointerTy())
            return nullptr;

        auto *pointer = llvm::PointerType::get(context, 0);
        std::vector<llvm::Type *> thunkParameters{ pointer };
        thunkParameters.reserve(signature->parameters.size() + 1U);
        for (const auto &parameter : signature->parameters)
        {
            auto *lowered = types.Lower(parameter);
            if (lowered == nullptr || lowered->isVoidTy())
                return nullptr;
            thunkParameters.push_back(lowered);
        }
        auto *resultType = types.Lower(signature->result);
        if (resultType == nullptr)
            return nullptr;
        auto *thunkType
            = llvm::FunctionType::get(resultType, thunkParameters, false);

        // Every closure payload begins with its invoke thunk. The call
        // site can load this stable prefix without knowing capture
        // count or layout; only the private thunk interprets the
        // remainder of the environment.
        auto *thunk = builder.CreateLoad(pointer, closure, "closure.invoke");
        std::vector<llvm::Value *> thunkArguments{ closure };
        thunkArguments.insert(thunkArguments.end(),
                              arguments.begin(),
                              arguments.end());
        return builder.CreateCall(thunkType, thunk, thunkArguments, name);
    }

    auto
    Generator::RuntimeFunction(std::string_view name,
                               llvm::Type *result,
                               std::initializer_list<llvm::Type *> arguments)
        -> llvm::FunctionCallee
    {
        return module.getOrInsertFunction(
            std::string(name),
            llvm::FunctionType::get(result, arguments, false));
    }

    auto
    Generator::IsPointerAarcType(const core::Type &type) const -> bool
    {
        // String is semantically AARC but still uses the scalar-buffer
        // bridge in this backend revision. Ownership instructions are
        // emitted only after a value has the opaque pointer
        // representation used by Named/callable values.
        return core::UsesAarc(type) || type.kind == core::Type::Kind::Named;
    }

    auto
    Generator::LowerOwnership(llvm::IRBuilder<> &builder,
                              FunctionState &state,
                              const xmm::Instruction &instruction) -> bool
    {
        if (instruction.operands.size() != 1U
            || !IsPointerAarcType(instruction.operands.front().type))
            return false;
        auto *value = LoadValue(builder, state, instruction.operands.front());
        if (value == nullptr || !value->getType()->isPointerTy())
            return false;

        auto *pointer = llvm::PointerType::get(context, 0);
        llvm::Value *result{};
        switch (instruction.opcode)
        {
            case xmm::Opcode::RetainStrong:
                result = builder.CreateCall(
                    RuntimeFunction("tala_aarc_retain_strong",
                                    pointer,
                                    { pointer }),
                    { value },
                    "aarc.strong");
                break;
            case xmm::Opcode::ReleaseStrong:
                builder.CreateCall(
                    RuntimeFunction("tala_aarc_release_strong",
                                    llvm::Type::getVoidTy(context),
                                    { pointer }),
                    { value });
                return true;
            case xmm::Opcode::MakeWeak:
                result
                    = builder.CreateCall(RuntimeFunction("tala_aarc_make_weak",
                                                         pointer,
                                                         { pointer }),
                                         { value },
                                         "aarc.weak");
                break;
            case xmm::Opcode::LockWeak:
                result
                    = builder.CreateCall(RuntimeFunction("tala_aarc_lock_weak",
                                                         pointer,
                                                         { pointer }),
                                         { value },
                                         "aarc.locked");
                break;
            case xmm::Opcode::ReleaseWeak:
                builder.CreateCall(
                    RuntimeFunction("tala_aarc_release_weak",
                                    llvm::Type::getVoidTy(context),
                                    { pointer }),
                    { value });
                return true;
            case xmm::Opcode::MakeUnowned:
                result = builder.CreateCall(
                    RuntimeFunction("tala_aarc_make_unowned",
                                    pointer,
                                    { pointer }),
                    { value },
                    "aarc.unowned");
                break;
            case xmm::Opcode::LoadUnowned:
                result = builder.CreateCall(
                    RuntimeFunction("tala_aarc_load_unowned",
                                    pointer,
                                    { pointer }),
                    { value },
                    "aarc.borrowed");
                break;
            case xmm::Opcode::ReleaseUnowned:
                builder.CreateCall(
                    RuntimeFunction("tala_aarc_release_unowned",
                                    llvm::Type::getVoidTy(context),
                                    { pointer }),
                    { value });
                return true;
            default:
                return false;
        }
        if (result == nullptr || !instruction.has_result)
            return false;
        builder.CreateStore(result, state.slots.at(instruction.destination));
        return true;
    }
} // namespace Progmasoft::Tala::Backend::LLVM::Generation
