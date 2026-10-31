// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

/// @namespace Progmasoft::Tala::Cli::Frontend
/// @brief Ownership-safe C++ adapter for the Haskell frontend shared library.
namespace Progmasoft::Tala::Cli::Frontend
{
    /// @brief Kinds of data that may be synchronously delivered by the
    /// frontend.
    // Mirrors the 32-bit kind argument of the C ABI callback.
    // NOLINTNEXTLINE(performance-enum-size)
    enum class OutputKind : std::uint32_t
    {
        CoreWire = 0,          ///< Versioned, verified Core wire bytes.
        ProjectSourceList = 1, ///< NUL-delimited UTF-8 source paths.
        DiagnosticWire = 2,    ///< Structured source diagnostics.
        ErrorText = 3,         ///< Human-readable UTF-8 failure text.
        CorePrepWire = 4,      ///< Frontend CorePrep lowering; testing only.
        WarningText = 5        ///< Warnings that accompany a successful result.
    };

    /// @brief Stable operation outcomes returned by the C ABI.
    // Mirrors the 32-bit status the C ABI entry points return.
    // NOLINTNEXTLINE(performance-enum-size)
    enum class Status : std::int32_t
    {
        Success = 0,        ///< The request completed and delivered its result.
        Diagnostics = 1,    ///< Source was rejected by normal compiler
                            ///< diagnostics.
        InvalidRequest = 2, ///< The argument frame did not satisfy the ABI.
        InternalError = 3,  ///< The frontend encountered an internal failure.
        OutputRejected = 4  ///< The C++ receiver rejected a borrowed buffer.
    };

    /// @brief Owned result copied out of the frontend's callback-scoped memory.
    struct Result final
    {
        Status status{ Status::InternalError };   ///< Frontend status code.
        OutputKind kind{ OutputKind::ErrorText }; ///< Meaning of @ref bytes.
        std::vector<std::uint8_t>
            bytes;         ///< Caller-owned copy of returned bytes.
        std::string error; ///< Local ABI or runtime failure description.
        /// Rendered warnings of a successful request; empty when there are
        /// none. A rejected request carries its warnings in @ref bytes.
        std::string warnings;

        /// @brief Report whether the frontend completed successfully.
        /// @return true only when status is Success.
        [[nodiscard]] auto
        succeeded() const noexcept -> bool
        {
            return status == Status::Success;
        }
    };

    /// @brief Execute a driver request through the in-process Haskell frontend.
    /// @param arguments Logical argv values, excluding the executable name.
    /// @return Status and an owned copy of the one delivered output buffer.
    [[nodiscard]] auto
    Execute(std::span<const std::string> arguments) -> Result;

    /// @brief Compile one in-memory Tala source buffer to verified Core.
    /// @param source UTF-8 source bytes; malformed source is a normal
    /// diagnostic.
    /// @return An owned Core payload or diagnostic text with its status.
    [[nodiscard]] auto
    CompileSource(std::span<const std::uint8_t> source) -> Result;

    /// @brief Exercise production lexer or parser logic on arbitrary bytes.
    /// @param stage Zero selects lexing; one selects parsing.
    /// @param source Candidate bytes; invalid encodings are ordinary inputs.
    /// @return True when the frontend runtime and ABI call completed.
    [[nodiscard]] auto
    FuzzSyntax(std::uint32_t stage, std::span<const std::uint8_t> source)
        -> bool;

    /// @brief Compile source bytes through the normal frontend and Core wire
    /// encoder.
    /// @param source Candidate source bytes; malformed input is permitted.
    /// @return An owned result; diagnostics are not treated as runtime
    /// failures.
    [[nodiscard]] auto
    FuzzCompile(std::span<const std::uint8_t> source) -> Result;

    /// @brief Core and the frontend's own CorePrep from one compilation.
    struct StageResult final
    {
        Result core; ///< Status and Core wire, as returned by FuzzCompile.
        /// Frontend-lowered CorePrep wire; empty unless core succeeded.
        std::vector<std::uint8_t> corePrep;
    };

    /// @brief Compile source bytes and keep both frontend artifacts.
    ///
    /// The native pipeline lowers Core to CorePrep with its own adapter. This
    /// testing route additionally returns the Haskell lowering of the same
    /// Core so the two can be compared.
    /// @param source Candidate source bytes; malformed input is permitted.
    /// @return Owned Core and CorePrep buffers; a successful status without
    /// CorePrep is reported as an internal error.
    [[nodiscard]] auto
    FuzzCompileStages(std::span<const std::uint8_t> source) -> StageResult;
} // namespace Progmasoft::Tala::Cli::Frontend
