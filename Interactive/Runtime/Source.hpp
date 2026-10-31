// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"

namespace Progmasoft::Tala::Interactive::Runtime
{
    /// @brief Build a namespaced REPL compilation unit without touching disk.
    /// @param cellNumber Unique session cell identity included in the
    /// namespace.
    /// @param expression User-entered Tala expression.
    /// @param previous Prior scalar value when it has a lossless source
    /// spelling.
    /// @return Source text, or no value for invalid/oversize input.
    [[nodiscard]] auto
    BuildCellSource(std::uint64_t cellNumber,
                    std::string_view expression,
                    const std::optional<Backend::LLVM::JitValue> &previous)
        -> std::optional<std::string>;

    /// @brief Find the verified zero-argument cell evaluator's LLVM symbol.
    /// @param module Xmm module produced by the cell's compiler pipeline.
    /// @param cellNumber Namespace identity used to reject stale modules.
    /// @return Mangled symbol when exactly one matching evaluator is present.
    [[nodiscard]] auto
    EvaluationSymbol(const tala::xmm::Module &module, std::uint64_t cellNumber)
        -> std::optional<std::string>;
} // namespace Progmasoft::Tala::Interactive::Runtime
