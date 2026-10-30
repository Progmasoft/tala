// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// Declaring and defining functions, and the entry of an executable.

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
    namespace
    {
        [[nodiscard]] auto
        AppendUtf8(std::string &result, char32_t point) -> bool
        {
            // UTF-8 is used here only for LLVM identifiers and
            // diagnostic-facing metadata. It is not the in-memory
            // representation of Tala String values; those retain their
            // Unicode-scalar ABI and are lowered separately by StringLiteral.
            const auto value = static_cast<std::uint32_t>(point);
            if (value > 0x10ffffU || (value >= 0xd800U && value <= 0xdfffU))
                return false;
            if (value <= 0x7fU)
                result.push_back(static_cast<char>(value));
            else if (value <= 0x7ffU)
            {
                result.push_back(static_cast<char>(0xc0U | value >> 6U));
                result.push_back(static_cast<char>(0x80U | (value & 0x3fU)));
            }
            else if (value <= 0xffffU)
            {
                result.push_back(static_cast<char>(0xe0U | value >> 12U));
                result.push_back(
                    static_cast<char>(0x80U | ((value >> 6U) & 0x3fU)));
                result.push_back(static_cast<char>(0x80U | (value & 0x3fU)));
            }
            else
            {
                result.push_back(static_cast<char>(0xf0U | value >> 18U));
                result.push_back(
                    static_cast<char>(0x80U | ((value >> 12U) & 0x3fU)));
                result.push_back(
                    static_cast<char>(0x80U | ((value >> 6U) & 0x3fU)));
                result.push_back(static_cast<char>(0x80U | (value & 0x3fU)));
            }
            return true;
        }

        [[nodiscard]] auto
        Utf8(std::u32string_view text) -> std::optional<std::string>
        {
            std::string result;
            result.reserve(text.size());
            for (const auto point : text)
                if (!AppendUtf8(result, point))
                    return std::nullopt;
            return result;
        }

    } // namespace

    [[nodiscard]] auto
    Failure(ErrorKind kind, std::string code, std::string message) -> Result
    {
        Result result;
        result.error = Error{ kind, std::move(code), std::move(message), {} };
        return result;
    }

    [[nodiscard]] auto
    ModuleName(const xmm::Module &module) -> std::optional<std::string>
    {
        std::string result;
        for (const auto &part : module.name)
        {
            const auto encoded = Utf8(part);
            if (!encoded)
                return std::nullopt;
            if (!result.empty())
                result.push_back('.');
            result += *encoded;
        }
        return result;
    }

    [[nodiscard]] auto
    SymbolName(const xmm::Module &module, const xmm::Function &function)
        -> std::optional<std::string>
    {
        auto result = ModuleName(module);
        const auto spelling = Utf8(function.symbol.spelling);
        if (!result || !spelling)
            return std::nullopt;
        result->append(".");
        result->append(*spelling);
        result->append(".");
        result->append(std::to_string(function.symbol.id));
        // LLVM reserves every global name beginning with `llvm.` for
        // intrinsics and rejects a module that defines one, but `llvm`
        // is an ordinary namespace name in source. `$` cannot occur in
        // a source identifier, so the prefixed name is unambiguous and
        // cannot collide with another module's symbol.
        if (result->starts_with("llvm."))
            result->insert(0U, 1U, '$');
        return result;
    }

    auto
    Generator::FunctionType(const xmm::Function &function) const
        -> llvm::FunctionType *
    {
        std::vector<llvm::Type *> parameters;
        parameters.reserve(function.parameter_types.size());
        for (const auto &parameter : function.parameter_types)
            parameters.push_back(types.Lower(parameter));
        auto *result = types.Lower(function.return_type);
        if (result == nullptr
            || std::ranges::any_of(parameters, [](const llvm::Type *item) {
                   return item == nullptr;
               }))
            return nullptr;
        return llvm::FunctionType::get(result, parameters, false);
    }

    auto
    Generator::DeclareFunctions(const xmm::Module &source) -> bool
    {
        // Declare every function before emitting any body. Calls
        // therefore resolve by stable symbol id regardless of source
        // order, and direct recursion needs no special case during
        // instruction lowering.
        for (const auto &function : source.functions)
        {
            const auto name = SymbolName(source, function);
            auto *type = FunctionType(function);
            if (!name)
            {
                fail(ErrorKind::InvalidUnicode,
                     "TAL2001",
                     "module or function name contains an invalid "
                     "Unicode scalar");
                return false;
            }
            if (type == nullptr)
            {
                fail(ErrorKind::UnsupportedType,
                     "TAL2002",
                     "function signature cannot be represented in LLVM");
                return false;
            }
            auto *value
                = llvm::Function::Create(type,
                                         llvm::GlobalValue::ExternalLinkage,
                                         *name,
                                         module);
            functions.emplace(
                function.symbol.id,
                FunctionState{ &function, value, type, {}, {}, {} });
        }
        return true;
    }

    void
    Generator::DiscoverRegisters(FunctionState &state)
    {
        for (std::size_t index = 0;
             index < state.source->parameter_registers.size();
             ++index)
            state.register_types.emplace(
                state.source->parameter_registers[index],
                state.source->parameter_types[index]);
        for (const auto &block : state.source->blocks)
            for (const auto &instruction : block.instructions)
                if (instruction.has_result)
                    state.register_types.emplace(instruction.destination,
                                                 instruction.result_type);
    }

    auto
    Generator::CreateBlocksAndSlots(FunctionState &state) -> bool
    {
        // All allocas belong to the entry block even when the first
        // write appears in a later block. This gives each Xmm register
        // one address for the whole function and lets LLVM's
        // optimization pipeline promote eligible slots back to SSA.
        for (const auto &block : state.source->blocks)
        {
            const auto blockName = "block." + std::to_string(block.id);
            state.blocks.emplace(
                block.id,
                llvm::BasicBlock::Create(context, blockName, state.value));
        }
        const auto entry = state.blocks.find(state.source->entry);
        if (entry == state.blocks.end())
            return false;

        llvm::IRBuilder<> builder(entry->second);
        DiscoverRegisters(state);
        std::vector<xmm::VirtualRegister> ordered;
        ordered.reserve(state.register_types.size());
        for (const auto &[reg, _] : state.register_types)
            ordered.push_back(reg);
        std::ranges::sort(ordered);
        for (const auto reg : ordered)
        {
            auto *type = types.Lower(state.register_types.at(reg));
            if (type == nullptr || type->isVoidTy())
                continue;
            const auto name = "r" + std::to_string(reg);
            state.slots.emplace(reg, builder.CreateAlloca(type, nullptr, name));
        }
        for (std::size_t index = 0;
             index < state.source->parameter_registers.size();
             ++index)
        {
            const auto reg = state.source->parameter_registers[index];
            const auto slot = state.slots.find(reg);
            if (slot != state.slots.end())
                builder.CreateStore(
                    state.value->getArg(static_cast<unsigned>(index)),
                    slot->second);
        }
        return true;
    }

    // The ownership runtime an executable carries in its own module.

    auto
    Generator::DefineFunction(FunctionState &state) -> bool
    {
        if (!CreateBlocksAndSlots(state))
            return false;
        llvm::IRBuilder<> builder(context);
        for (const auto &block : state.source->blocks)
        {
            builder.SetInsertPoint(state.blocks.at(block.id));
            for (const auto &instruction : block.instructions)
                if (!LowerInstruction(builder, state, instruction))
                    return false;
            if (!LowerTerminator(builder, state, block.terminator))
                return false;
        }
        return true;
    }

    auto
    Generator::CreateExecutableEntry(const llvm::Triple &triple) -> bool
    {
        // Project selection has already narrowed compilation to the
        // requested Core module. Guard the ABI-critical method shape
        // once more before an operating-system entry symbol is
        // synthesized.
        const FunctionState *entry{};
        for (const auto &[_, candidate] : functions)
        {
            if (candidate.source->symbol.spelling != U"Main"
                || !candidate.source->parameter_types.empty()
                || candidate.source->return_type.kind != core::Type::Kind::Unit)
                continue;
            if (entry != nullptr)
            {
                fail(ErrorKind::InvalidEntryPoint,
                     "TAL2008",
                     "native executable contains more than one "
                     "parameterless void Main function");
                return false;
            }
            entry = &candidate;
        }
        if (entry == nullptr)
        {
            fail(ErrorKind::InvalidEntryPoint,
                 "TAL2007",
                 "native executable requires one parameterless void "
                 "Main function");
            return false;
        }

        // The source entry remains a normal Tala function. A tiny
        // platform ABI bridge is synthesized only for executable
        // emission, so object/library builds never acquire an
        // accidental process entry symbol.
        const auto entryName = triple.isOSWindows() ? "mainCRTStartup" : "main";
        // Code for a Windows target that uses floating point refers to
        // `_fltused`, which a C runtime defines. A Tala executable has none,
        // and with TalaRT in talart.dll none of the runtime either, so the
        // executable defines it. TalaRT's archive defines it as well; the
        // linker keeps any one of them.
        if (triple.isOSWindows()
            && module.getNamedGlobal("_fltused") == nullptr)
        {
            auto *int32 = llvm::Type::getInt32Ty(context);
            auto *fltused = new llvm::GlobalVariable(
                module,
                int32,
                false,
                llvm::GlobalValue::LinkOnceODRLinkage,
                llvm::ConstantInt::get(int32, 0x9875),
                "_fltused");
            fltused->setComdat(module.getOrInsertComdat("_fltused"));
        }
        auto *entryType
            = llvm::FunctionType::get(llvm::Type::getInt32Ty(context), false);
        auto *bridge
            = llvm::Function::Create(entryType,
                                     llvm::GlobalValue::ExternalLinkage,
                                     entryName,
                                     module);
        auto *block = llvm::BasicBlock::Create(context, "entry", bridge);
        llvm::IRBuilder<> builder(block);
        builder.CreateCall(entry->type, entry->value);
        // A test build ends with the status of its tests; any other
        // program with zero.
        if (module.getFunction("tala_test_end") != nullptr)
        {
            auto status
                = module.getOrInsertFunction("tala_test_status", entryType);
            builder.CreateRet(builder.CreateCall(status));
        }
        else
            builder.CreateRet(
                llvm::ConstantInt::get(llvm::Type::getInt32Ty(context), 0));
        // What the program calls of the runtime, it finds in the
        // runtime library the executable is linked with.
        return true;
    }

    void
    Generator::fail(ErrorKind kind, std::string code, std::string message)
    {
        if (!error)
            error = Error{ kind, std::move(code), std::move(message), {} };
    }
} // namespace Progmasoft::Tala::Backend::LLVM::Generation
