// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace Progmasoft::Tala::Driver::ProjectArtifacts
{
    // A source path is always project-relative and slash-normalized. The
    // flattened file name is a display-independent basename, not a path that
    // can escape the output directory.
    struct SourceOutput final
    {
        std::u32string source_file;
        std::string file_name;
        [[nodiscard]] auto
        operator==(const SourceOutput &) const -> bool = default;
    };

    struct PlanResult final
    {
        std::vector<SourceOutput> outputs;
        std::string diagnostic;
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return diagnostic.empty();
        }
    };

    struct ArtifactFile final
    {
        std::string file_name;
        std::vector<std::uint8_t> bytes;
    };

    // Convert one source catalog into flattened object or assembly names.
    // Planning is side-effect-free, deterministic, and rejects path traversal,
    // malformed Unicode, missing extensions, and portable name collisions.
    [[nodiscard]] auto
    PlanSourceOutputs(std::span<const std::u32string> source_files,
                      std::string_view extension) -> PlanResult;

    // Commit a complete set of sibling artifacts. New bytes are first written
    // and flushed into a private same-filesystem staging directory. Existing
    // outputs are moved to private backups immediately before replacement and
    // restored in reverse order if a later rename fails.
    [[nodiscard]] auto
    CommitArtifactFiles(const std::filesystem::path &output_directory,
                        std::span<const ArtifactFile> files)
        -> std::optional<std::string>;
} // namespace Progmasoft::Tala::Driver::ProjectArtifacts
