// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <optional>
#include <string>

#include "Progmasoft/Tala/Backend/LLVM.hpp"

namespace Progmasoft::Tala::Interactive::Runtime
{
    [[nodiscard]] auto
    SourceBinding(const Backend::LLVM::JitValue &value)
        -> std::optional<std::string>;

    [[nodiscard]] auto
    DisplayValue(const Backend::LLVM::JitValue &value) -> std::string;

    [[nodiscard]] auto
    DisplayType(const tala::core::Type &type) -> std::string;
} // namespace Progmasoft::Tala::Interactive::Runtime
