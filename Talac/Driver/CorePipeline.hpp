// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#pragma once

#include <cstdint>
#include <filesystem>
#include <span>

#include "Talac/Cli/Arguments/Options.hpp"

// This internal C++20 boundary receives typed options; the artifact pipeline
// never reparses CLI spellings or exposes the retired C driver naming.
[[nodiscard]] bool
ProcessCoreArtifact(const char *path,
                    PipelineAction action,
                    BuildOutput output,
                    const CompilerSettings *settings,
                    const char *targetTriple);
[[nodiscard]] bool
ProcessCoreArtifactAs(const char *path,
                      const char *artifactBasePath,
                      PipelineAction action,
                      BuildOutput output,
                      const CompilerSettings *settings,
                      const char *targetTriple);
[[nodiscard]] bool
ProcessCoreBytesAs(std::span<const std::uint8_t> bytes,
                   const char *sourceName,
                   const char *artifactBasePath,
                   PipelineAction action,
                   BuildOutput output,
                   const CompilerSettings *settings,
                   const char *targetTriple);
[[nodiscard]] bool
ProcessProjectCoreArtifacts(const std::filesystem::path &corePath,
                            const std::filesystem::path &outputDirectory,
                            BuildOutput output,
                            const CompilerSettings *settings,
                            const char *targetTriple);
[[nodiscard]] bool
ProcessProjectCoreBytes(std::span<const std::uint8_t> bytes,
                        const char *sourceName,
                        const std::filesystem::path &outputDirectory,
                        BuildOutput output,
                        const CompilerSettings *settings,
                        const char *targetTriple);
[[nodiscard]] bool
ProcessXppArtifactAs(const char *path,
                     const char *artifactBasePath,
                     PipelineAction action,
                     BuildOutput output,
                     const CompilerSettings *settings,
                     const char *targetTriple);
[[nodiscard]] bool
ProcessXmmArtifactAs(const char *path,
                     const char *artifactBasePath,
                     PipelineAction action,
                     BuildOutput output,
                     const CompilerSettings *settings,
                     const char *targetTriple);
