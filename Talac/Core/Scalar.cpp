// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <array>
#include <cctype>
#include <limits>

#include "Progmasoft/Tala/Core/Scalar.hpp"

namespace tala::core
{
    auto
    ScalarDescription::is_numeric() const noexcept -> bool
    {
        return is_integer() || is_floating();
    }

    auto
    ScalarDescription::is_integer() const noexcept -> bool
    {
        return family == ScalarFamily::SignedInteger
               || family == ScalarFamily::UnsignedInteger;
    }

    auto
    ScalarDescription::is_signed() const noexcept -> bool
    {
        return family == ScalarFamily::SignedInteger;
    }

    auto
    ScalarDescription::is_floating() const noexcept -> bool
    {
        return family == ScalarFamily::Floating;
    }

    auto
    describe_scalar(const Type &type) noexcept
        -> std::optional<ScalarDescription>
    {
        // This table is the native side of the language scalar catalog. Keep
        // it explicit: deriving widths from C++ types would make the compiler
        // ABI-dependent, while deriving signedness from LLVM integer types is
        // impossible because LLVM intentionally uses one bit-vector type for
        // both families.
        //
        // Source spellings are retained here for diagnostics and tests. They
        // are not aliases for C-family meanings: Tala long is i32 and int
        // is i64. Any new entry must also receive wire tags, verifier rules,
        // Xpp/Xmm coverage, and an LLVM lowering case.
        using enum Type::Kind;
        switch (type.kind)
        {
            case Bool:
                return ScalarDescription{ ScalarFamily::Boolean, 8, "bool" };
            case Character:
                return ScalarDescription{ ScalarFamily::Character, 32, "char" };
            case Int8:
                return ScalarDescription{ ScalarFamily::SignedInteger,
                                          8,
                                          "byte" };
            case Int16:
                return ScalarDescription{ ScalarFamily::SignedInteger,
                                          16,
                                          "short" };
            case Int32:
                return ScalarDescription{ ScalarFamily::SignedInteger,
                                          32,
                                          "long" };
            case Int64:
                return ScalarDescription{ ScalarFamily::SignedInteger,
                                          64,
                                          "int" };
            case Int128:
                return ScalarDescription{ ScalarFamily::SignedInteger,
                                          128,
                                          "longint" };
            case UInt8:
                return ScalarDescription{ ScalarFamily::UnsignedInteger,
                                          8,
                                          "ubyte" };
            case UInt16:
                return ScalarDescription{ ScalarFamily::UnsignedInteger,
                                          16,
                                          "ushort" };
            case UInt32:
                return ScalarDescription{ ScalarFamily::UnsignedInteger,
                                          32,
                                          "ulong" };
            case UInt64:
                return ScalarDescription{ ScalarFamily::UnsignedInteger,
                                          64,
                                          "uint" };
            case UInt128:
                return ScalarDescription{ ScalarFamily::UnsignedInteger,
                                          128,
                                          "ulongint" };
            case Float16:
                return ScalarDescription{ ScalarFamily::Floating,
                                          16,
                                          "sfloat" };
            case Float32:
                return ScalarDescription{ ScalarFamily::Floating,
                                          32,
                                          "lfloat" };
            case Float64:
                return ScalarDescription{ ScalarFamily::Floating, 64, "float" };
            case Float128:
                return ScalarDescription{ ScalarFamily::Floating,
                                          128,
                                          "double" };
            case Unit:
            case String:
            case Function:
            case Named:
            case TypeVariable:
                return std::nullopt;
        }
        return std::nullopt;
    }

    auto
    is_numeric(const Type &type) noexcept -> bool
    {
        const auto description = describe_scalar(type);
        return description && description->is_numeric();
    }

    auto
    is_integer(const Type &type) noexcept -> bool
    {
        const auto description = describe_scalar(type);
        return description && description->is_integer();
    }

    auto
    is_signed_integer(const Type &type) noexcept -> bool
    {
        const auto description = describe_scalar(type);
        return description
               && description->family == ScalarFamily::SignedInteger;
    }

    auto
    is_unsigned_integer(const Type &type) noexcept -> bool
    {
        const auto description = describe_scalar(type);
        return description
               && description->family == ScalarFamily::UnsignedInteger;
    }

    auto
    is_floating(const Type &type) noexcept -> bool
    {
        const auto description = describe_scalar(type);
        return description && description->is_floating();
    }

    auto
    accepts_boolean_context(const Type &type) noexcept -> bool
    {
        return type.kind == Type::Kind::Bool || is_numeric(type);
    }

    auto
    normalize_integer(IntegerLiteral value) -> IntegerLiteral
    {
        const auto first_non_zero
            = std::ranges::find_if(value.magnitude,
                                   [](const std::uint8_t octet) {
                                       return octet != 0U;
                                   });
        value.magnitude.erase(value.magnitude.begin(), first_non_zero);
        if (value.magnitude.empty())
            value.negative = false;
        return value;
    }

    auto
    integer_is_canonical(const IntegerLiteral &value) noexcept -> bool
    {
        if (value.magnitude.empty())
            return !value.negative;
        return value.magnitude.front() != 0U;
    }

    auto
    integer_is_zero(const IntegerLiteral &value) noexcept -> bool
    {
        return value.magnitude.empty()
               || std::ranges::all_of(value.magnitude,
                                      [](const std::uint8_t octet) {
                                          return octet == 0U;
                                      });
    }

    namespace
    {
        auto
        significant_bits(const IntegerLiteral &value) noexcept -> std::size_t
        {
            if (value.magnitude.empty())
                return 0U;
            const auto first = value.magnitude.front();
            std::size_t highBits = 8U;
            for (std::uint8_t mask = 0x80U; mask != 0U && (first & mask) == 0U;
                 mask >>= 1U)
                --highBits;
            return (value.magnitude.size() - 1U) * 8U + highBits;
        }

        auto
        is_exact_signed_minimum(const IntegerLiteral &value,
                                const std::size_t width) noexcept -> bool
        {
            if (!value.negative || significant_bits(value) != width)
                return false;
            const auto first = value.magnitude.front();
            if (first != static_cast<std::uint8_t>(1U << ((width - 1U) % 8U)))
                return false;
            return std::ranges::all_of(value.magnitude.begin() + 1,
                                       value.magnitude.end(),
                                       [](const std::uint8_t octet) {
                                           return octet == 0U;
                                       });
        }
    } // namespace

    auto
    integer_fits(const IntegerLiteral &value, const Type &type) noexcept -> bool
    {
        const auto description = describe_scalar(type);
        if (!description || !integer_is_canonical(value))
            return false;
        if (description->family == ScalarFamily::Character)
            return !value.negative && significant_bits(value) <= 32U;
        if (!description->is_integer())
            return false;
        const auto bits = significant_bits(value);
        if (description->family == ScalarFamily::UnsignedInteger)
            return !value.negative && bits <= description->bit_width;
        if (!value.negative)
            return bits < description->bit_width;
        return bits < description->bit_width
               || is_exact_signed_minimum(value, description->bit_width);
    }

    auto
    integer_from_unsigned(std::uint64_t value) -> IntegerLiteral
    {
        IntegerLiteral result;
        while (value != 0U)
        {
            result.magnitude.push_back(
                static_cast<std::uint8_t>(value & 0xffU));
            value >>= 8U;
        }
        std::ranges::reverse(result.magnitude);
        return result;
    }

    auto
    integer_from_signed(const std::int64_t value) -> IntegerLiteral
    {
        // -(INT64_MIN) is not representable, so compute the magnitude in
        // unsigned space.
        const auto negative = value < 0;
        const auto magnitude
            = negative ? std::uint64_t{ 0 } - static_cast<std::uint64_t>(value)
                       : static_cast<std::uint64_t>(value);
        auto result = integer_from_unsigned(magnitude);
        result.negative = negative && !result.magnitude.empty();
        return result;
    }

    auto
    integer_hex_magnitude(const IntegerLiteral &value) -> std::string
    {
        static constexpr std::array<char, 16> kDigits
            = { '0', '1', '2', '3', '4', '5', '6', '7',
                '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };
        if (value.magnitude.empty())
            return "0";
        std::string result;
        result.reserve(value.magnitude.size() * 2U);
        for (const auto octet : value.magnitude)
        {
            result.push_back(kDigits[octet >> 4U]);
            result.push_back(kDigits[octet & 0x0fU]);
        }
        if (result.size() > 1U && result.front() == '0')
            result.erase(result.begin());
        return result;
    }

    auto
    floating_spelling_is_valid(const std::string_view spelling) noexcept -> bool
    {
        if (spelling.empty())
            return false;
        if (spelling == "nan" || spelling == "+nan" || spelling == "-nan"
            || spelling == "inf" || spelling == "+inf" || spelling == "-inf")
            return true;

        std::size_t cursor = 0U;
        if (spelling[cursor] == '+' || spelling[cursor] == '-')
            ++cursor;
        bool integralDigits = false;
        while (cursor < spelling.size()
               && std::isdigit(static_cast<unsigned char>(spelling[cursor]))
                      != 0)
        {
            integralDigits = true;
            ++cursor;
        }
        bool fractionalDigits = false;
        if (cursor < spelling.size() && spelling[cursor] == '.')
        {
            ++cursor;
            while (cursor < spelling.size()
                   && std::isdigit(static_cast<unsigned char>(spelling[cursor]))
                          != 0)
            {
                fractionalDigits = true;
                ++cursor;
            }
        }
        if (!integralDigits && !fractionalDigits)
            return false;
        if (cursor < spelling.size()
            && (spelling[cursor] == 'e' || spelling[cursor] == 'E'))
        {
            ++cursor;
            if (cursor < spelling.size()
                && (spelling[cursor] == '+' || spelling[cursor] == '-'))
                ++cursor;
            const auto exponentStart = cursor;
            while (cursor < spelling.size()
                   && std::isdigit(static_cast<unsigned char>(spelling[cursor]))
                          != 0)
                ++cursor;
            if (cursor == exponentStart)
                return false;
        }
        return cursor == spelling.size();
    }

    auto
    validate_literal(const Literal &literal, const Type &type)
        -> std::optional<std::string>
    {
        if (std::holds_alternative<std::monostate>(literal))
            return type.kind == Type::Kind::Unit
                           || type.kind == Type::Kind::Named
                           || type.kind == Type::Kind::String
                           || type.kind == Type::Kind::Function
                       ? std::nullopt
                       : std::optional<std::string>{
                             "empty payload requires unit or an AARC reference "
                             "type"
                         };
        if (std::holds_alternative<bool>(literal))
            return type.kind == Type::Kind::Bool
                       ? std::nullopt
                       : std::optional<std::string>{
                             "boolean payload requires bool type"
                         };
        if (const auto *legacy = std::get_if<std::int64_t>(&literal))
            return integer_fits(integer_from_signed(*legacy), type)
                       ? std::nullopt
                       : std::optional<std::string>{
                             "signed integer payload is outside its scalar type"
                         };
        if (const auto *legacy = std::get_if<std::int32_t>(&literal))
            return integer_fits(integer_from_signed(*legacy), type)
                       ? std::nullopt
                       : std::optional<std::string>{
                             "signed integer payload is outside its scalar type"
                         };
        if (const auto *integer = std::get_if<IntegerLiteral>(&literal))
            return integer_fits(*integer, type)
                       ? std::nullopt
                       : std::optional<std::string>{
                             "integer payload is non-canonical or outside its "
                             "scalar type"
                         };
        if (const auto *floating = std::get_if<FloatingLiteral>(&literal))
        {
            if (!is_floating(type))
                return "floating payload requires a floating scalar type";
            if (!floating_spelling_is_valid(floating->spelling))
                return "floating payload has an invalid canonical spelling";
            return std::nullopt;
        }
        if (std::holds_alternative<std::u32string>(literal))
            return type.kind == Type::Kind::String
                       ? std::nullopt
                       : std::optional<std::string>{
                             "text payload requires string type"
                         };
        return "unknown literal payload";
    }
} // namespace tala::core
