// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"

namespace Progmasoft::Tala::Artifact::Wire
{
    /// Allocation and complexity limits applied to Xpp/Xmm wire payloads.
    struct Limits final
    {
        /// Maximum total encoded or decoded size in bytes.
        std::size_t maximumWireBytes{ std::size_t{ 64U } * 1024U * 1024U };
        /// Maximum Unicode scalar count in one text field.
        std::size_t maximumTextScalars{ std::size_t{ 1024U } * 1024U };
        /// Maximum number of functions in one module.
        std::size_t maximumFunctions{ 65535U };
        /// Maximum parameters accepted for one function.
        std::size_t maximumParameters{ 65535U };
        /// Maximum basic blocks accepted for one function.
        std::size_t maximumBlocks{ 1048576U };
        /// Maximum instructions accepted for one function.
        std::size_t maximumInstructions{ 1048576U };
        /// Maximum operands accepted for one instruction.
        std::size_t maximumOperands{ 65535U };
        /// Maximum recursive type nesting depth.
        std::size_t maximumTypeDepth{ 128U };
        /// Maximum encoded byte width for a numeric literal.
        std::size_t maximumNumericBytes{ 4096U };
    };

    /// Reason an artifact wire value could not be encoded or decoded.
    enum class ErrorKind : std::uint8_t
    {
        InvalidMagic,       ///< Header does not identify a supported artifact.
        UnsupportedVersion, ///< Header version is newer or otherwise
                            ///< unsupported.
        TruncatedInput, ///< Input ended before the current field was complete.
        TrailingInput,  ///< Bytes remain after a complete document.
        InvalidTag,     ///< A discriminant is not defined by this version.
        InvalidBoolean, ///< Boolean payload is not encoded as zero or one.
        InvalidScalar,  ///< Text contains a non-scalar Unicode value.
        InvalidSymbol,  ///< Symbol identity or spelling is invalid.
        InvalidInteger, ///< Integer sign/magnitude encoding is non-canonical.
        LimitExceeded,  ///< A configured size or complexity ceiling was hit.
        InvalidModel    ///< Decoded fields violate the artifact model.
    };

    /// Structured failure location and explanation for a wire operation.
    struct Error final
    {
        /// Category suitable for programmatic recovery or diagnostics.
        ErrorKind kind{ ErrorKind::InvalidModel };
        /// Byte offset where the failure was detected.
        std::size_t offset{};
        /// Field path identifying the value being processed.
        std::string context;
        /// Human-readable failure explanation.
        std::string message;

        /// Compare the category, offset, field path, and message.
        /// @return true when all error details match.
        [[nodiscard]] auto
        operator==(const Error &) const -> bool = default;
    };

    /// Bounded encoder for shared scalar and type wire fields.
    ///
    /// Xpp and Xmm retain ownership of their instruction and control-flow
    /// schemas, so these helpers cannot erase stage-specific invariants.
    class Writer final
    {
    public:
        /// Initialize a writer using caller-owned resource limits.
        /// @param limits Limits object that must outlive this writer.
        explicit Writer(const Limits &limits);

        /// Append one unsigned byte.
        /// @param value Byte value to encode.
        void
        Byte(std::uint8_t value);
        /// Append a 16-bit unsigned integer in wire byte order.
        /// @param value Integer value to encode.
        void
        U16(std::uint16_t value);
        /// Append a 32-bit unsigned integer in wire byte order.
        /// @param value Integer value to encode.
        void
        U32(std::uint32_t value);
        /// Append a 64-bit unsigned integer in wire byte order.
        /// @param value Integer value to encode.
        void
        U64(std::uint64_t value);
        /// Append a canonical one-byte Boolean.
        /// @param value Boolean value to encode.
        void
        Boolean(bool value);
        /// Validate and append a bounded collection count.
        /// @param value Count to encode.
        /// @param maximum Maximum count allowed for this collection.
        /// @param context Field path used in any recorded failure.
        void
        Count(std::size_t value, std::size_t maximum, std::string_view context);
        /// Encode Unicode scalar text after checking configured limits.
        /// @param value Text to encode.
        /// @param context Field path used in any recorded failure.
        void
        Text(std::u32string_view value, std::string_view context);
        /// Encode a sequence of qualified-name segments.
        /// @param value Name segments in qualification order.
        /// @param context Field path used in any recorded failure.
        void
        QualifiedName(const std::vector<std::u32string> &value,
                      std::string_view context);
        /// Encode symbol identity and source spelling.
        /// @param value Symbol to encode.
        /// @param context Field path used in any recorded failure.
        void
        Symbol(const ::tala::core::SymbolName &value, std::string_view context);
        /// Encode a structural type, enforcing the maximum nesting depth.
        /// @param value Type to encode.
        /// @param context Field path used in any recorded failure.
        /// @param depth Current recursive depth, normally zero for callers.
        void
        Type(const ::tala::core::Type &value,
             std::string_view context,
             std::size_t depth = 0U);
        /// Encode a literal using its statically declared type.
        /// @param value Literal payload to encode.
        /// @param type Declared type that selects the literal representation.
        /// @param context Field path used in any recorded failure.
        void
        Literal(const ::tala::core::Literal &value,
                const ::tala::core::Type &type,
                std::string_view context);
        /// Record the first encoding failure; subsequent writes become inert.
        /// @param kind Failure category.
        /// @param context Field path where the error occurred.
        /// @param message Human-readable explanation.
        void
        Fail(ErrorKind kind, std::string context, std::string message);

        /// View bytes written so far without transferring ownership.
        /// @return Stable reference to the writer's current byte buffer.
        [[nodiscard]] auto
        Bytes() const -> const std::vector<std::uint8_t> &;
        /// Transfer ownership of the encoded byte buffer to the caller.
        /// @return Bytes written before any recorded failure.
        [[nodiscard]] auto
        TakeBytes() -> std::vector<std::uint8_t>;
        /// Inspect the first recorded encoding failure.
        /// @return Empty when no error was recorded.
        [[nodiscard]] auto
        Failure() const -> const std::optional<Error> &;
        /// Report the current output size in bytes.
        /// @return Number of bytes currently written.
        [[nodiscard]] auto
        Offset() const noexcept -> std::size_t;

    private:
        const Limits &limits_;
        std::vector<std::uint8_t> bytes_;
        std::optional<Error> error_;
    };

    /// Bounds-checked decoder for shared scalar and type wire fields.
    class Reader final
    {
    public:
        /// Initialize a reader over caller-owned bytes and limits.
        /// @param bytes Input buffer, which must outlive this reader.
        /// @param limits Resource limits, which must outlive this reader.
        Reader(std::span<const std::uint8_t> bytes, const Limits &limits);

        /// Read one byte, recording an error if input is exhausted.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded byte, or zero after a recorded failure.
        [[nodiscard]] auto
        Byte(std::string_view context) -> std::uint8_t;
        /// Read a 16-bit unsigned integer in wire byte order.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded value, or zero after a recorded failure.
        [[nodiscard]] auto
        U16(std::string_view context) -> std::uint16_t;
        /// Read a 32-bit unsigned integer in wire byte order.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded value, or zero after a recorded failure.
        [[nodiscard]] auto
        U32(std::string_view context) -> std::uint32_t;
        /// Read a 64-bit unsigned integer in wire byte order.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded value, or zero after a recorded failure.
        [[nodiscard]] auto
        U64(std::string_view context) -> std::uint64_t;
        /// Read a canonical zero-or-one Boolean byte.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded Boolean, or false after a recorded failure.
        [[nodiscard]] auto
        Boolean(std::string_view context) -> bool;
        /// Read and validate a collection count.
        /// @param maximum Maximum count allowed for this collection.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded count, or zero after a recorded failure.
        [[nodiscard]] auto
        Count(std::size_t maximum, std::string_view context) -> std::size_t;
        /// Read bounded Unicode scalar text.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded text, or an empty value after a recorded failure.
        [[nodiscard]] auto
        Text(std::string_view context) -> std::u32string;
        /// Read a qualified name encoded as ordered text segments.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded name segments, or an empty value after a failure.
        [[nodiscard]] auto
        QualifiedName(std::string_view context) -> std::vector<std::u32string>;
        /// Read symbol identity and spelling.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded symbol, or a default symbol after a recorded
        /// failure.
        [[nodiscard]] auto
        Symbol(std::string_view context) -> ::tala::core::SymbolName;
        /// Read a structural type while enforcing recursive depth limits.
        /// @param context Field path used in any recorded failure.
        /// @param depth Current recursive depth, normally zero for callers.
        /// @return Decoded type, or Unit after a recorded failure.
        [[nodiscard]] auto
        Type(std::string_view context, std::size_t depth = 0U)
            -> ::tala::core::Type;
        /// Read a literal representation selected by its declared type.
        /// @param type Static type selecting the literal wire representation.
        /// @param context Field path used in any recorded failure.
        /// @return Decoded literal, or an empty payload after a failure.
        [[nodiscard]] auto
        Literal(const ::tala::core::Type &type, std::string_view context)
            -> ::tala::core::Literal;
        /// Record the first decoding failure; later reads remain inert.
        /// @param kind Failure category.
        /// @param context Field path where the error occurred.
        /// @param message Human-readable explanation.
        void
        Fail(ErrorKind kind, std::string context, std::string message);

        /// Inspect the first recorded decoding failure.
        /// @return Empty when no error was recorded.
        [[nodiscard]] auto
        Failure() const -> const std::optional<Error> &;
        /// Report the byte offset of the next unread input value.
        /// @return Current input cursor.
        [[nodiscard]] auto
        Offset() const noexcept -> std::size_t;
        /// Check whether the reader consumed the complete input buffer.
        /// @return true when no bytes remain.
        [[nodiscard]] auto
        AtEnd() const noexcept -> bool;
        /// Report the total input buffer length.
        /// @return Input size in bytes.
        [[nodiscard]] auto
        InputSize() const noexcept -> std::size_t;

    private:
        std::span<const std::uint8_t> bytes_;
        const Limits &limits_;
        std::size_t offset_{};
        std::optional<Error> error_;
    };

    /// Test whether a code point is a Unicode scalar rather than a surrogate.
    /// @param value Code point to validate.
    /// @return true for Unicode scalar values in the valid range.
    [[nodiscard]] auto
    IsUnicodeScalar(char32_t value) noexcept -> bool;
} // namespace Progmasoft::Tala::Artifact::Wire
