// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include "Progmasoft/Tala/Backend/LLVM.hpp"

namespace Progmasoft::Tala::Backend::LLVM
{
    auto
    Verify(const Xmm::Module &module) -> std::vector<Issue>
    {
        // Preserve the backend API while delegating ownership to the Xmm stage.
        // Lower calls this adapter as a defense-in-depth check for direct
        // embedding clients.
        return ::Progmasoft::Tala::Xmm::Verify(module);
    }
} // namespace Progmasoft::Tala::Backend::LLVM
