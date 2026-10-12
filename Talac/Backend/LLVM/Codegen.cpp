// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

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

#include "Emission.hpp"
#include "Generator.hpp"

namespace Progmasoft::Tala::Backend::LLVM
{
    using Generation::ArtifactObjectFormat;
    using Generation::CreateTargetMachine;
    using Generation::EmitMachineCode;
    using Generation::Failure;
    using Generation::Generator;
    using Generation::ModuleName;
    using Generation::Optimize;

    auto
    Lower(const Xmm::Module &source, const Options &options) -> Result
    {
        // Reject malformed Xmm before allocating LLVM state. Besides clearer
        // diagnostics, this keeps construction free to rely on verified block,
        // type and symbol invariants instead of duplicating defensive checks at
        // every IRBuilder call.
        auto issues = Verify(source);
        if (!issues.empty())
        {
            Result result;
            result.error
                = Error{ ErrorKind::InvalidXmm,
                         "TAL2000",
                         "Xmm verification failed before LLVM lowering",
                         std::move(issues) };
            return result;
        }
        if (options.definition_source_file && options.executableEntry)
            return Failure(ErrorKind::InvalidEntryPoint,
                           "TAL2020",
                           "source-partitioned lowering cannot synthesize an "
                           "executable entry point");
        if (options.definition_source_file && !source.source_files.empty()
            && std::ranges::find(source.source_files,
                                 *options.definition_source_file)
                   == source.source_files.end())
            return Failure(ErrorKind::InvalidXmm,
                           "TAL2021",
                           "selected source is absent from the Xmm source "
                           "catalog");

        llvm::LLVMContext context;
        const auto name = ModuleName(source);
        if (!name)
            return Failure(ErrorKind::InvalidUnicode,
                           "TAL2001",
                           "module name contains an invalid Unicode scalar");
        llvm::Module module(*name, context);

        std::string triple = options.target_triple;
        if (triple.empty())
            triple = llvm::sys::getDefaultTargetTriple();
        if (triple.empty())
            return Failure(ErrorKind::LlvmConstruction,
                           "TAL2004",
                           "LLVM did not provide a default target triple");
        module.setTargetTriple(llvm::Triple(triple));

        std::optional<Error> targetError;
        std::unique_ptr<llvm::TargetMachine> targetMachine;
        if (options.machineCode != MachineCodeEmission::None)
        {
            // Fix the data layout before generating functions and before
            // optimization reasons about pointer widths, alignment, or calling
            // conventions.
            targetMachine = CreateTargetMachine(module,
                                                options.optimization,
                                                targetError);
            if (!targetMachine)
                return Result{ std::nullopt, std::move(targetError) };
        }

        Generator generator(context, module);
        if (!generator.DeclareFunctions(source))
            return Result{ std::nullopt, std::move(generator.error) };
        std::size_t definitionCount{};
        for (auto &[_, function] : generator.functions)
        {
            if (options.definition_source_file
                && function.source->source_file
                       != *options.definition_source_file)
                continue;
            if (!generator.DefineFunction(function))
                return Failure(
                    ErrorKind::LlvmConstruction,
                    "TAL2005",
                    "failed to lower an Xmm instruction or terminator");
            ++definitionCount;
        }
        if (options.executableEntry
            && !generator.CreateExecutableEntry(llvm::Triple(triple)))
            return Result{ std::nullopt, std::move(generator.error) };

        if (options.verify_module)
        {
            // LLVM verification runs before optimization so a backend
            // construction defect cannot be hidden or transformed into a less
            // useful pass-manager failure.
            std::string message;
            llvm::raw_string_ostream diagnostics(message);
            if (llvm::verifyModule(module, &diagnostics))
            {
                diagnostics.flush();
                return Failure(ErrorKind::LlvmVerification,
                               "TAL2006",
                               message.empty()
                                   ? "LLVM rejected the generated module"
                                   : std::move(message));
            }
        }

        Optimize(module, options.optimization);

        std::string printed;
        llvm::raw_string_ostream printedStream(printed);
        module.print(printedStream, nullptr);
        printedStream.flush();
        llvm::SmallVector<char, 0> bitcode;
        llvm::raw_svector_ostream bitcodeStream(bitcode);
        llvm::WriteBitcodeToFile(module, bitcodeStream);
        Artifact artifact;
        // Copy both products before the local module and context are destroyed.
        // Artifact consequently has ordinary C++ value semantics and no LLVM
        // ABI or lifetime obligation is imposed on CLI, tests or future object
        // emitters.
        artifact.llvm_ir = std::move(printed);
        artifact.bitcode.assign(
            reinterpret_cast<const std::uint8_t *>(bitcode.data()),
            reinterpret_cast<const std::uint8_t *>(bitcode.data()
                                                   + bitcode.size()));
        artifact.target_triple = std::move(triple);
        // Preserve the format beside its bytes. The linker can reject
        // mismatched input without guessing from a filename or reparsing an
        // object header.
        artifact.objectFormat
            = ArtifactObjectFormat(llvm::Triple(artifact.target_triple));
        artifact.function_count = definitionCount;
        if (targetMachine)
            if (auto error = EmitMachineCode(module,
                                             *targetMachine,
                                             options.machineCode,
                                             artifact))
                return Result{ std::nullopt, std::move(error) };
        return Result{ std::move(artifact), std::nullopt };
    }
} // namespace Progmasoft::Tala::Backend::LLVM
