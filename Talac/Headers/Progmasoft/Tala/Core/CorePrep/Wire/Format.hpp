// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace tala::core::wire
{
    /// Four-byte identifier at the beginning of each CorePrep wire document.
    inline constexpr std::uint8_t magic[] = { 'T', 'A', 'C', 'P' };
    /// Current CorePrep wire schema version.
    inline constexpr std::uint16_t current_version = 8;

    /// Resource ceilings checked while encoding or decoding CorePrep data.
    struct Limits final
    {
        /// Maximum total serialized size in bytes.
        std::size_t maximum_wire_bytes{ std::size_t{ 64U } * 1024U * 1024U };
        /// Maximum Unicode code points accepted in one string.
        std::size_t maximum_string_code_points{ std::size_t{ 1024U } * 1024U };
        /// Maximum function count in a module.
        std::size_t maximum_functions{ 65535U };
        /// Maximum parameters in one function.
        std::size_t maximum_parameters_per_function{ 65535U };
        /// Maximum basic blocks in one function.
        std::size_t maximum_blocks_per_function{ 1048576U };
        /// Maximum instructions in one block.
        std::size_t maximum_instructions_per_block{ 1048576U };
        /// Maximum operands in one instruction.
        std::size_t maximum_operands_per_instruction{ 65535U };
        /// Maximum recursive nesting of a type.
        std::size_t maximum_type_depth{ 128U };
        /// Maximum encoded byte count for a numeric literal.
        std::size_t maximum_numeric_bytes{ 4096U };
    };

    /// Failure category reported by the CorePrep wire codec.
    enum class ErrorKind : std::uint8_t
    {
        InvalidMagic, ///< Header magic does not match the CorePrep format.
        UnsupportedVersion, ///< Header version is not supported by this codec.
        TruncatedInput,     ///< Input ended before a field was complete.
        TrailingInput,      ///< Bytes remain after one complete document.
        InvalidTag,         ///< A discriminant is not part of the wire schema.
        InvalidBoolean,     ///< Boolean encoding is not zero or one.
        InvalidCodePoint,   ///< Text contains an invalid Unicode scalar.
        InvalidCount,       ///< A collection count is malformed.
        InvalidSymbol,      ///< Symbol identity or spelling is invalid.
        InvalidInteger,     ///< Integer encoding is not canonical.
        UnsupportedType,    ///< Type cannot be represented by this schema.
        LimitExceeded       ///< A configured resource ceiling was exceeded.
    };

    /// Wire codec failure with byte offset and field context.
    struct Error final
    {
        /// Failure category suitable for programmatic handling.
        ErrorKind kind{ ErrorKind::InvalidTag };
        /// Byte position at which the failure was detected.
        std::size_t offset{};
        /// Field path identifying the value being processed.
        std::string context;
        /// Human-readable explanation of the failure.
        std::string message;
    };
} // namespace tala::core::wire
