// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>

#include "Progmasoft/Tala/Core/CorePrep.hpp"

namespace tala::core
{
    /// Numeric or primitive family associated with a Core scalar type.
    enum class ScalarFamily : std::uint8_t
    {
        None,
        Boolean,
        Character,
        SignedInteger,
        UnsignedInteger,
        Floating
    };

    /// Canonical family, width, and source spelling for one scalar type.
    struct ScalarDescription final
    {
        /// Semantic family of the described type.
        ScalarFamily family{ ScalarFamily::None };
        /// Bit width for integer and floating scalar families.
        std::uint16_t bit_width{};
        /// Canonical source-language spelling.
        std::string_view spelling;

        /// Test whether the scalar is an integer or floating type.
        /// @return true for signed integer, unsigned integer, or floating
        /// types.
        [[nodiscard]] auto
        is_numeric() const noexcept -> bool;
        /// Test whether the scalar is a signed or unsigned integer.
        /// @return true for either integer family.
        [[nodiscard]] auto
        is_integer() const noexcept -> bool;
        /// Test whether the scalar uses signed integer semantics.
        /// @return true only for SignedInteger.
        [[nodiscard]] auto
        is_signed() const noexcept -> bool;
        /// Test whether the scalar uses floating-point semantics.
        /// @return true only for Floating.
        [[nodiscard]] auto
        is_floating() const noexcept -> bool;
    };

    /// Describe a built-in scalar type; aggregate and unresolved types are
    /// absent.
    /// @param type Core type tag to classify.
    /// @return Canonical scalar metadata when type is a built-in scalar.
    [[nodiscard]] auto
    describe_scalar(const Type &type) noexcept
        -> std::optional<ScalarDescription>;
    /// Test whether a Core type is integer or floating point.
    /// @param type Type to inspect.
    /// @return true for any numeric scalar type.
    [[nodiscard]] auto
    is_numeric(const Type &type) noexcept -> bool;
    /// Test whether a Core type is a signed or unsigned integer.
    /// @param type Type to inspect.
    /// @return true for integer scalar types.
    [[nodiscard]] auto
    is_integer(const Type &type) noexcept -> bool;
    /// Test whether a Core type is a signed integer.
    /// @param type Type to inspect.
    /// @return true only for signed integer scalar types.
    [[nodiscard]] auto
    is_signed_integer(const Type &type) noexcept -> bool;
    /// Test whether a Core type is an unsigned integer.
    /// @param type Type to inspect.
    /// @return true only for unsigned integer scalar types.
    [[nodiscard]] auto
    is_unsigned_integer(const Type &type) noexcept -> bool;
    /// Test whether a Core type is floating point.
    /// @param type Type to inspect.
    /// @return true only for floating scalar types.
    [[nodiscard]] auto
    is_floating(const Type &type) noexcept -> bool;
    /// Test whether a type is accepted as a Boolean condition.
    /// @param type Type used in the condition.
    /// @return true when the language permits Boolean-context conversion.
    [[nodiscard]] auto
    accepts_boolean_context(const Type &type) noexcept -> bool;

    /// Normalize an integer to the canonical sign/magnitude representation.
    /// @param value Integer value to normalize.
    /// @return Canonical sign and magnitude form.
    [[nodiscard]] auto
    normalize_integer(IntegerLiteral value) -> IntegerLiteral;
    /// Test whether an integer already uses canonical sign/magnitude bytes.
    /// @param value Integer to validate.
    /// @return true when sign and magnitude encoding is canonical.
    [[nodiscard]] auto
    integer_is_canonical(const IntegerLiteral &value) noexcept -> bool;
    /// Test whether an integer represents mathematical zero.
    /// @param value Integer to inspect.
    /// @return true when every magnitude byte is zero.
    [[nodiscard]] auto
    integer_is_zero(const IntegerLiteral &value) noexcept -> bool;
    /// Test whether an integer fits the range of a declared scalar type.
    /// @param value Canonical integer value.
    /// @param type Target scalar type.
    /// @return true when value is representable by type.
    [[nodiscard]] auto
    integer_fits(const IntegerLiteral &value, const Type &type) noexcept
        -> bool;
    /// Convert a signed host integer to the canonical arbitrary-width form.
    /// @param value Signed host integer to convert.
    /// @return Canonical sign/magnitude integer.
    [[nodiscard]] auto
    integer_from_signed(std::int64_t value) -> IntegerLiteral;
    /// Convert an unsigned host integer to the canonical arbitrary-width form.
    /// @param value Unsigned host integer to convert.
    /// @return Canonical non-negative integer.
    [[nodiscard]] auto
    integer_from_unsigned(std::uint64_t value) -> IntegerLiteral;
    /// Render the magnitude as lowercase hexadecimal without a prefix.
    /// @param value Integer whose magnitude is rendered.
    /// @return Stable hexadecimal magnitude string.
    [[nodiscard]] auto
    integer_hex_magnitude(const IntegerLiteral &value) -> std::string;

    /// Validate locale-independent decimal or LLVM APFloat special spelling.
    /// @param spelling Floating-point token spelling to validate.
    /// @return true when spelling belongs to the supported wire grammar.
    [[nodiscard]] auto
    floating_spelling_is_valid(std::string_view spelling) noexcept -> bool;

    /// Validate a literal variant and ensure its value fits the declared type.
    /// @param literal Literal payload supplied by a decoded or built module.
    /// @param type Declared scalar type associated with the payload.
    /// @return Empty on success or a diagnostic-ready validation reason.
    [[nodiscard]] auto
    validate_literal(const Literal &literal, const Type &type)
        -> std::optional<std::string>;
} // namespace tala::core
