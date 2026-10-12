// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <optional>
#include <string>

#include "Progmasoft/Tala/Core/CorePrep.hpp"

namespace Progmasoft::Tala::Fuzzing
{
    /**
     * @brief Compare two CorePrep lowerings of the same Core module.
     *
     * The Haskell frontend and the native Core-to-CorePrep adapter must
     * build the same program: the same reachable control-flow graph with the
     * same instructions in every block. Block identities and the identities
     * of generated symbols are allocation details, so both modules are first
     * brought to a canonical form: reachable blocks in depth-first preorder
     * from the entry, true edge before false edge, and `$`-prefixed generated
     * symbols renamed in first-use order while keeping their kind. Source
     * symbols, types, literals, operations, operand order, instruction order
     * and edge roles are compared exactly. Blocks unreachable from the entry
     * are ignored.
     *
     * @param frontend CorePrep produced by the Haskell frontend.
     * @param native CorePrep produced by the native adapter.
     * @return std::nullopt when equivalent, otherwise the first difference.
     */
    [[nodiscard]] auto
    CompareCorePrep(const ::tala::core::CorePrepModule &frontend,
                    const ::tala::core::CorePrepModule &native)
        -> std::optional<std::string>;
} // namespace Progmasoft::Tala::Fuzzing
