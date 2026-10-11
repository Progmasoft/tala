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

namespace Visual::XSharp::Backend::LLVM::Generation
{
    namespace
    {

        [[nodiscard]] auto
        PassOptimizationLevel(OptimizationLevel level)
            -> llvm::OptimizationLevel
        {
            switch (level)
            {
                case OptimizationLevel::Debug:
                    return llvm::OptimizationLevel::O0;
                case OptimizationLevel::Less:
                    return llvm::OptimizationLevel::O1;
                case OptimizationLevel::Default:
                    return llvm::OptimizationLevel::O2;
                case OptimizationLevel::Aggressive:
                    return llvm::OptimizationLevel::O3;
            }
            return llvm::OptimizationLevel::O2;
        }

        [[nodiscard]] auto
        CodeGenerationLevel(OptimizationLevel level) -> llvm::CodeGenOptLevel
        {
            switch (level)
            {
                case OptimizationLevel::Debug:
                    return llvm::CodeGenOptLevel::None;
                case OptimizationLevel::Less:
                    return llvm::CodeGenOptLevel::Less;
                case OptimizationLevel::Default:
                    return llvm::CodeGenOptLevel::Default;
                case OptimizationLevel::Aggressive:
                    return llvm::CodeGenOptLevel::Aggressive;
            }
            return llvm::CodeGenOptLevel::Default;
        }

        [[nodiscard]] auto
        NativeTargetsAvailable() -> bool
        {
            // LLVM target initialization mutates process-global registries.
            // Serialize it once even when several compiler sessions lower
            // modules concurrently.
            static std::once_flag once;
            static bool available{};
            std::call_once(once, [] {
                available = !llvm::InitializeNativeTarget()
                            && !llvm::InitializeNativeTargetAsmPrinter();
            });
            return available;
        }
    } // namespace

    void
    Optimize(llvm::Module &module, OptimizationLevel level)
    {
        // Build the standard per-module pipeline through LLVM's C++ pass
        // manager. Keeping every analysis manager local makes ownership
        // explicit and prevents global pass state from leaking between
        // compiler invocations in the same process.
        llvm::LoopAnalysisManager loopAnalyses;
        llvm::FunctionAnalysisManager functionAnalyses;
        llvm::CGSCCAnalysisManager cgsccAnalyses;
        llvm::ModuleAnalysisManager moduleAnalyses;
        llvm::PassBuilder passBuilder;
        passBuilder.registerModuleAnalyses(moduleAnalyses);
        passBuilder.registerCGSCCAnalyses(cgsccAnalyses);
        passBuilder.registerFunctionAnalyses(functionAnalyses);
        passBuilder.registerLoopAnalyses(loopAnalyses);
        passBuilder.crossRegisterProxies(loopAnalyses,
                                         functionAnalyses,
                                         cgsccAnalyses,
                                         moduleAnalyses);
        auto pipeline = passBuilder.buildPerModuleDefaultPipeline(
            PassOptimizationLevel(level));
        pipeline.run(module, moduleAnalyses);
    }

    [[nodiscard]] auto
    ArtifactObjectFormat(const llvm::Triple &triple) -> ObjectFormat
    {
        switch (triple.getObjectFormat())
        {
            case llvm::Triple::COFF:
                return ObjectFormat::Coff;
            case llvm::Triple::ELF:
                return ObjectFormat::Elf;
            case llvm::Triple::MachO:
                return ObjectFormat::MachO;
            case llvm::Triple::Wasm:
                return ObjectFormat::Wasm;
            default:
                return ObjectFormat::Unknown;
        }
    }

    [[nodiscard]] auto
    CreateTargetMachine(llvm::Module &module,
                        OptimizationLevel optimization,
                        std::optional<Error> &error)
        -> std::unique_ptr<llvm::TargetMachine>
    {
        if (!NativeTargetsAvailable())
        {
            error = Error{ ErrorKind::TargetMachine,
                           "VXL2009",
                           "LLVM native target initialization failed",
                           {} };
            return {};
        }
        std::string lookupError;
        const auto triple = llvm::Triple(module.getTargetTriple());
        const auto *target
            = llvm::TargetRegistry::lookupTarget(triple, lookupError);
        if (target == nullptr)
        {
            error = Error{
                ErrorKind::TargetMachine,
                "VXL2010",
                lookupError.empty()
                    ? "LLVM has no code generator for the selected target"
                    : lookupError,
                {}
            };
            return {};
        }
        llvm::TargetOptions targetOptions;
        // `generic` avoids silently selecting host-only CPU extensions that
        // could make a produced executable fail on another machine of the
        // same target.
        // ELF and Mach-O objects are position independent: the linkers of
        // those systems make position-independent executables by default
        // and refuse an object that is not. COFF keeps the default of its
        // target.
        const std::optional<llvm::Reloc::Model> relocation
            = triple.isOSBinFormatCOFF()
                  ? std::nullopt
                  : std::optional<llvm::Reloc::Model>(llvm::Reloc::PIC_);
        auto machine = std::unique_ptr<llvm::TargetMachine>(
            target->createTargetMachine(triple,
                                        "generic",
                                        "",
                                        targetOptions,
                                        relocation,
                                        std::nullopt,
                                        CodeGenerationLevel(optimization)));
        if (!machine)
        {
            error = Error{ ErrorKind::TargetMachine,
                           "VXL2011",
                           "LLVM could not create the selected target machine",
                           {} };
            return {};
        }
        module.setDataLayout(machine->createDataLayout());
        return machine;
    }

    [[nodiscard]] auto
    EmitMachineCode(llvm::Module &module,
                    llvm::TargetMachine &machine,
                    MachineCodeEmission emission,
                    Artifact &artifact) -> std::optional<Error>
    {
        // TargetMachine still exposes emission through the legacy
        // pass-manager adapter. Optimization above remains on LLVM's new
        // pass manager.
        llvm::SmallVector<char, 0> bytes;
        llvm::raw_svector_ostream stream(bytes);
        llvm::legacy::PassManager passes;
        const auto fileType = emission == MachineCodeEmission::Assembly
                                  ? llvm::CodeGenFileType::AssemblyFile
                                  : llvm::CodeGenFileType::ObjectFile;
        if (machine.addPassesToEmitFile(passes, stream, nullptr, fileType))
            return Error{ ErrorKind::MachineCodeEmission,
                          "VXL2012",
                          emission == MachineCodeEmission::Assembly
                              ? "target cannot emit assembly"
                              : "target cannot emit an object file",
                          {} };
        passes.run(module);
        if (bytes.empty())
            return Error{ ErrorKind::MachineCodeEmission,
                          "VXL2013",
                          "LLVM emitted an empty machine-code artifact",
                          {} };
        if (emission == MachineCodeEmission::Assembly)
            artifact.assembly.assign(bytes.begin(), bytes.end());
        else
            artifact.object.assign(
                reinterpret_cast<const std::uint8_t *>(bytes.data()),
                reinterpret_cast<const std::uint8_t *>(bytes.data()
                                                       + bytes.size()));
        return std::nullopt;
    }
} // namespace Visual::XSharp::Backend::LLVM::Generation
