// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#pragma once

#include <cstddef>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"

namespace Progmasoft::Tala::Driver::Incremental
{
    /// What a build through the incremental directory left behind.
    struct Outcome final
    {
        /// The objects to link: one for each source, then the process entry.
        std::vector<std::filesystem::path> objects;
        /// How many sources were lowered; the others kept their object.
        std::size_t recompiled{};
        /// How many sources the program has.
        std::size_t sources{};
        /// Object format of the target, for the linker.
        Backend::LLVM::ObjectFormat objectFormat{
            Backend::LLVM::ObjectFormat::Unknown
        };
        /// Resolved target triple, for the linker.
        std::string targetTriple;
        /// Why there are no objects.
        std::optional<std::string> error;
    };

    /// The key of the object of one source: the functions the source owns,
    /// the signatures of the functions they refer to, and [context], which
    /// holds what else decides the object. Nothing else enters, so a change
    /// in another file reaches this one only through what it calls.
    /// @return Hexadecimal digest, or nothing when the Xmm cannot be encoded.
    [[nodiscard]] auto
    SourceKey(const tala::xmm::Module &module,
              const std::u32string &source,
              std::string_view context) -> std::optional<std::string>;

    /// Makes the objects of [program] in [directory], lowering only the
    /// sources whose key has no object yet, on several threads. The objects
    /// use symbols of their own, which a new function elsewhere leaves
    /// alone, so that it recompiles the source it is in. Objects no
    /// source of this build uses are removed, so the directory holds one
    /// program and does not grow.
    [[nodiscard]] auto
    BuildObjects(const tala::xmm::Module &program,
                 const Backend::LLVM::Options &options,
                 const std::filesystem::path &directory,
                 std::string_view context) -> Outcome;
} // namespace Progmasoft::Tala::Driver::Incremental
