// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

#include "Progmasoft/Tala/Core/IR.hpp"

namespace Progmasoft::Tala::Core::Wire
{
    /// Current TACR schema version. Decoders require an exact match.
    inline constexpr std::uint16_t kCurrentVersion = 10;

    /// Per-call resource ceilings for encoding and decoding.
    /// Untrusted input is checked against these bounds before allocation.
    struct Limits final
    {
        /// Maximum total document size in bytes.
        std::size_t maximumWireBytes{ std::size_t{ 64U } * 1024U * 1024U };
        /// Maximum Unicode scalar count in one text field.
        std::size_t maximumTextScalars{ std::size_t{ 1024U } * 1024U };
        /// Maximum number of functions in one module.
        std::size_t maximumFunctions{ 65535U };
        /// Maximum parameters in one function or closure signature.
        std::size_t maximumParameters{ 65535U };
        /// Maximum statements in a function, branch, or closure body.
        std::size_t maximumStatements{ 1048576U };
        /// Maximum values in one operand or template-argument list.
        std::size_t maximumOperands{ 65535U };
        /// Maximum recursive type nesting depth.
        std::size_t maximumTypeDepth{ 128U };
        /// Maximum recursive expression nesting depth.
        std::size_t maximumExpressionDepth{ 4096U };
        /// Maximum nesting depth of statement bodies: function, branch,
        /// loop and closure bodies. The links of an `else if` chain share
        /// one level. The frontend limits source nesting far below this.
        std::size_t maximumStatementDepth{ 4096U };
        /// Maximum encoded magnitude bytes in one numeric literal.
        std::size_t maximumNumericBytes{ 4096U };
    };

    /// Stable categories for malformed or unrepresentable wire values.
    enum class ErrorKind : std::uint8_t
    {
        InvalidMagic,       ///< Header magic does not match TACR.
        UnsupportedVersion, ///< Header version is not supported.
        TruncatedInput,     ///< Input ended before a field was complete.
        TrailingInput,      ///< Bytes remain after one complete document.
        InvalidTag,         ///< A discriminant is not defined by the schema.
        InvalidBoolean,     ///< Boolean encoding is not zero or one.
        InvalidScalar,      ///< Text contains a non-scalar Unicode value.
        InvalidCount,       ///< A collection count is malformed.
        InvalidSymbol,      ///< Symbol identity or spelling is invalid.
        InvalidInteger,     ///< Integer representation is not canonical.
        UnsupportedType,    ///< A Core type is not representable in TACR.
        LimitExceeded       ///< A configured resource ceiling was exceeded.
    };

    /// Encode/decode failure with a byte offset and field context.
    struct Error final
    {
        /// Failure category suitable for programmatic handling.
        ErrorKind kind{ ErrorKind::InvalidTag };
        /// Reader or writer offset where the contract failed.
        std::size_t offset{};
        /// Field path identifying the value being processed.
        std::string context;
        /// Human-readable explanation; presentation belongs to the caller.
        std::string message;
    };

    /// Encoded bytes or the error that prevented serialization.
    struct EncodeResult final
    {
        /// Complete TACR bytes when encoding succeeds.
        std::vector<std::uint8_t> bytes;
        /// Failure details when encoding does not succeed.
        std::optional<Error> error;
        /// Test whether encoding completed without an error.
        /// @return true when error is empty.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return !error.has_value();
        }
    };

    /// Structurally decoded module or the error that rejected it.
    struct DecodeResult final
    {
        /// Decoded Core module when parsing succeeds.
        std::optional<Module> module;
        /// Failure details when the payload is rejected.
        std::optional<Error> error;
        /// Test whether a module was decoded successfully.
        /// @return true when module exists and error is empty.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return module.has_value();
        }
    };

    /// Serialize a Core module using the current TACR schema.
    /// Successful encoding does not replace semantic verification.
    /// @param module Module to encode.
    /// @param limits Resource limits enforced before and during serialization.
    /// @return Serialized document or a structured wire error.
    [[nodiscard]] auto
    Encode(const Module &module, const Limits &limits = {}) -> EncodeResult;

    /// Decode bounded TACR bytes without granting them semantic trust.
    /// Call the Core verifier before optimization, adaptation, or lowering.
    /// @param bytes Complete TACR document to decode.
    /// @param limits Resource ceilings enforced before allocation.
    /// @return Decoded structural module or a wire error.
    [[nodiscard]] auto
    Decode(std::span<const std::uint8_t> bytes, const Limits &limits = {})
        -> DecodeResult;
} // namespace Progmasoft::Tala::Core::Wire
