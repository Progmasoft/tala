// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire/Format.hpp"

namespace tala::core::wire
{
    /// Encoded CorePrep bytes or the error that prevented serialization.
    struct EncodeResult final
    {
        /// Complete versioned CorePrep wire document when encoding succeeds.
        std::vector<std::uint8_t> bytes;
        /// Structured serialization failure, absent on success.
        std::optional<Error> error;
        /// Test whether serialization completed without a wire error.
        /// @return true when error is empty.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return !error.has_value();
        }
    };

    /// Decoded CorePrep module or the error that rejected the document.
    struct DecodeResult final
    {
        /// Module value when structural decoding succeeds.
        std::optional<CorePrepModule> module;
        /// Structured decode failure, absent on success.
        std::optional<Error> error;
        /// Test whether a module was successfully decoded.
        /// @return true when module is present.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return module.has_value();
        }
    };

    /// Encode a CorePrep module with the versioned TACP schema.
    /// @param module Module to serialize.
    /// @param limits Resource ceilings enforced by the writer.
    /// @return Bytes on success or structured error details.
    [[nodiscard]] auto
    encode(const CorePrepModule &module, const Limits &limits = {})
        -> EncodeResult;
    /// Decode bounded TACP bytes into a structural CorePrep module.
    /// @param bytes Complete encoded document.
    /// @param limits Resource ceilings enforced before allocation.
    /// @return Module on success or structured error details.
    [[nodiscard]] auto
    decode(std::span<const std::uint8_t> bytes, const Limits &limits = {})
        -> DecodeResult;
} // namespace tala::core::wire
