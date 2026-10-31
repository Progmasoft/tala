// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Core/IR.hpp"

namespace Progmasoft::Tala::Core::CorePrep
{
    // Prepare is the adapting layer between verified, nested Core and the flat
    // typed CorePrep CFG consumed by Xpp. It deliberately performs no
    // optimization and invents no types; it only atomizes expressions and makes
    // source control flow explicit.
    [[nodiscard]] auto
    Prepare(const Module &module) -> ::tala::core::CorePrepModule;
} // namespace Progmasoft::Tala::Core::CorePrep
