// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

// What happens to a generated module after it is built: optimization, the
// target machine and machine code. Private to the LLVM backend.

#include <llvm/IR/Module.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm/TargetParser/Triple.h>
#include <memory>
#include <optional>

#include "Progmasoft/Tala/Backend/LLVM.hpp"

namespace Progmasoft::Tala::Backend::LLVM::Generation
{
    /// Run the standard per-module pipeline of the given level.
    void
    Optimize(llvm::Module &module, OptimizationLevel level);

    /// The object format a target triple produces.
    [[nodiscard]] auto
    ArtifactObjectFormat(const llvm::Triple &triple) -> ObjectFormat;

    /// The target machine of the module's triple; sets the data layout.
    [[nodiscard]] auto
    CreateTargetMachine(llvm::Module &module,
                        OptimizationLevel optimization,
                        std::optional<Error> &error)
        -> std::unique_ptr<llvm::TargetMachine>;

    /// Emit assembly or an object file into the artifact.
    [[nodiscard]] auto
    EmitMachineCode(llvm::Module &module,
                    llvm::TargetMachine &machine,
                    MachineCodeEmission emission,
                    Artifact &artifact) -> std::optional<Error>;
} // namespace Progmasoft::Tala::Backend::LLVM::Generation
