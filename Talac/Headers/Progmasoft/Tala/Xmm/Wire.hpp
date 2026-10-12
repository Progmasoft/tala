// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <vector>

#include "Progmasoft/Tala/Artifact/WireSupport.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"

namespace Progmasoft::Tala::Xmm::Wire
{
    /// Current Xmm wire schema version; decoders require an exact match.
    inline constexpr std::uint16_t kCurrentVersion = 7U;
    /// Shared resource ceilings for Xmm wire operations.
    using Limits = Artifact::Wire::Limits;
    /// Structured wire failure with byte offset and field context.
    using Error = Artifact::Wire::Error;
    /// Category of a malformed or unsupported wire field.
    using ErrorKind = Artifact::Wire::ErrorKind;

    /// Encoded document or structured failure.
    struct EncodeResult final
    {
        /// Complete serialized Xmm bytes when encoding succeeds.
        std::vector<std::uint8_t> bytes;
        /// Encoding failure, absent on success.
        std::optional<Error> error;
        /// Test whether encoding completed.
        /// @return true when no wire error was produced.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return !error;
        }
    };

    /// Decoded Xmm module or structured failure.
    struct DecodeResult final
    {
        /// Module payload when decoding succeeds.
        std::optional<::tala::xmm::Module> module;
        /// Decode failure, absent on success.
        std::optional<Error> error;
        /// Test whether decoding produced a module.
        /// @return true when module is present.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return module.has_value();
        }
    };

    /// Serialize an Xmm module using the current versioned wire schema.
    /// @param module Xmm module to encode.
    /// @param limits Resource ceilings applied before allocation and traversal.
    /// @return Encoded bytes or the first structured serialization error.
    [[nodiscard]] auto
    Encode(const ::tala::xmm::Module &module, const Limits &limits = {})
        -> EncodeResult;
    /// Decode bounded wire bytes into a structural Xmm module.
    /// Decoding does not replace semantic Xmm verification.
    /// @param bytes Complete encoded document.
    /// @param limits Resource ceilings applied to untrusted input.
    /// @return Decoded module or the first structured wire error.
    [[nodiscard]] auto
    Decode(std::span<const std::uint8_t> bytes, const Limits &limits = {})
        -> DecodeResult;
} // namespace Progmasoft::Tala::Xmm::Wire
