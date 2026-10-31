// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <variant>

#include "Progmasoft/Tala/Core/CorePrep.hpp"

/// The catalog of runtime calls.
///
/// A runtime call is an operation that the compiler does not lower to
/// instructions but to a call of a function of the Tala runtime:
/// joining two strings, converting a number for output, writing to the
/// console. Core, CorePrep, Xpp and Xmm each carry it as one operation whose
/// first operand is a literal, the identity of the function, and whose
/// remaining operands are the arguments. This header is what every native
/// stage knows about each function: its identity, the symbol of the runtime
/// that implements it, the types it takes and returns, and whether it does
/// something that can be observed.
///
/// The identities are part of the artifact formats. A function is never
/// renumbered; a new one takes the next free number. The Haskell frontend
/// has the same table in `Progmasoft.Tala.Core.RuntimeCall`, and the tests of
/// both sides pin each row.
namespace tala::core::runtime
{
    /// What an argument of a runtime function may be.
    ///
    /// A function takes a family of types where the language gives the
    /// operation to all of them. The backend widens the argument to the one
    /// representation the runtime function is written for, which changes
    /// no value.
    enum class Parameter : std::uint8_t
    {
        Signed,   ///< A signed integer of at most 64 bits.
        Unsigned, ///< An unsigned integer of at most 64 bits.
        Floating, ///< A floating-point number of at most 64 bits.
        Bool,     ///< `bool`.
        Char,     ///< `char`.
        Text,     ///< `String`.
        Count     ///< `int`: flags, a width or a precision.
    };

    /// What a runtime function returns.
    enum class Result : std::uint8_t
    {
        Nothing, ///< No value.
        Text,    ///< A `String` the caller owns.
        Truth    ///< A `bool`.
    };

    /// The identity of a runtime function, as the first operand carries it.
    enum class Function : std::uint8_t
    {
        TextConcat = 1,         ///< Two strings one after the other.
        TextFromSigned = 2,     ///< A signed integer in decimal.
        TextFromUnsigned = 3,   ///< An unsigned integer in decimal.
        TextFromBool = 4,       ///< `true` or `false`.
        TextFromChar = 5,       ///< The one character.
        TextFormatSigned = 6,   ///< `%d` and `%x` of a signed integer.
        TextFormatUnsigned = 7, ///< `%u` and `%x` of an unsigned integer.
        TextFormatFloating = 8, ///< `%f`.
        TextFormatString = 9,   ///< `%s`.
        TextFormatChar = 10,    ///< `%c`.
        TextNewline = 11,       ///< The line terminator of the platform.
        ConsoleWrite = 12,      ///< Write a string to a standard stream.
        TextEquals = 13,        ///< Whether two strings hold the same text.
        TestFail = 14,          ///< Record and report a failed `#expect`.
        TestEnd = 15,           ///< Close the current test and report it.
        TestFinish = 16         ///< Report the totals of a test run.
    };

    /// One row of the catalog.
    struct Signature final
    {
        /// The identity the first operand holds.
        Function function{ Function::TextConcat };
        /// The symbol of the runtime library that implements the function.
        std::string_view symbol;
        /// The arguments, in order.
        std::span<const Parameter> parameters;
        /// What the function returns.
        Result result{};
        /// Whether a call does something that can be observed apart from
        /// its result. Such a call is never removed, repeated or moved.
        bool observable{};
    };

    namespace detail
    {
        inline constexpr std::array kTwoTexts{ Parameter::Text,
                                               Parameter::Text };
        inline constexpr std::array kSigned{ Parameter::Signed };
        inline constexpr std::array kUnsigned{ Parameter::Unsigned };
        inline constexpr std::array kBool{ Parameter::Bool };
        inline constexpr std::array kChar{ Parameter::Char };
        // Flags, width and precision, and then the value. The value stands
        // last because that is the order of a format's arguments: a width
        // or a precision written as `*` is the argument before the value,
        // and the operands of a call are evaluated in order.
        inline constexpr std::array kFormatSigned{ Parameter::Count,
                                                   Parameter::Count,
                                                   Parameter::Count,
                                                   Parameter::Signed };
        inline constexpr std::array kFormatUnsigned{ Parameter::Count,
                                                     Parameter::Count,
                                                     Parameter::Count,
                                                     Parameter::Unsigned };
        inline constexpr std::array kFormatFloating{ Parameter::Count,
                                                     Parameter::Count,
                                                     Parameter::Count,
                                                     Parameter::Floating };
        inline constexpr std::array kFormatText{ Parameter::Count,
                                                 Parameter::Count,
                                                 Parameter::Count,
                                                 Parameter::Text };
        inline constexpr std::array kFormatChar{ Parameter::Count,
                                                 Parameter::Count,
                                                 Parameter::Count,
                                                 Parameter::Char };
        inline constexpr std::array kWrite{ Parameter::Text, Parameter::Count };
        inline constexpr std::array kText{ Parameter::Text };

        inline constexpr std::array<Signature, 16U> kCatalog{ {
            { Function::TextConcat,
              "tala_text_concat",
              kTwoTexts,
              Result::Text,
              false },
            { Function::TextFromSigned,
              "tala_text_from_signed",
              kSigned,
              Result::Text,
              false },
            { Function::TextFromUnsigned,
              "tala_text_from_unsigned",
              kUnsigned,
              Result::Text,
              false },
            { Function::TextFromBool,
              "tala_text_from_bool",
              kBool,
              Result::Text,
              false },
            { Function::TextFromChar,
              "tala_text_from_char",
              kChar,
              Result::Text,
              false },
            { Function::TextFormatSigned,
              "tala_text_format_signed",
              kFormatSigned,
              Result::Text,
              false },
            { Function::TextFormatUnsigned,
              "tala_text_format_unsigned",
              kFormatUnsigned,
              Result::Text,
              false },
            { Function::TextFormatFloating,
              "tala_text_format_floating",
              kFormatFloating,
              Result::Text,
              false },
            { Function::TextFormatString,
              "tala_text_format_string",
              kFormatText,
              Result::Text,
              false },
            { Function::TextFormatChar,
              "tala_text_format_char",
              kFormatChar,
              Result::Text,
              false },
            { Function::TextNewline,
              "tala_text_newline",
              {},
              Result::Text,
              false },
            { Function::ConsoleWrite,
              "tala_console_write",
              kWrite,
              Result::Nothing,
              true },
            { Function::TextEquals,
              "tala_text_equals",
              kTwoTexts,
              Result::Truth,
              false },
            { Function::TestFail,
              "tala_test_fail",
              kText,
              Result::Nothing,
              true },
            { Function::TestEnd,
              "tala_test_end",
              kText,
              Result::Nothing,
              true },
            { Function::TestFinish,
              "tala_test_finish",
              {},
              Result::Nothing,
              true },
        } };
    } // namespace detail

    /// Every runtime function, in order of identity.
    /// @return The rows of the catalog.
    [[nodiscard]] constexpr auto
    Catalog() noexcept -> std::span<const Signature>
    {
        return detail::kCatalog;
    }

    /// The row of the function with the given identity, or null when no
    /// function has it.
    /// @param identity The number a first operand holds.
    /// @return The row, or null.
    [[nodiscard]] constexpr auto
    Find(const std::uint64_t identity) noexcept -> const Signature *
    {
        for (const auto &signature : detail::kCatalog)
            if (static_cast<std::uint64_t>(signature.function) == identity)
                return &signature;
        return nullptr;
    }

    /// Whether an argument of the given type may stand where the parameter
    /// is.
    /// @param parameter What the function takes at that position.
    /// @param kind The kind of the argument's type.
    /// @return true when the function takes an argument of that type there.
    [[nodiscard]] constexpr auto
    Accepts(const Parameter parameter, const Type::Kind kind) noexcept -> bool
    {
        switch (parameter)
        {
            case Parameter::Signed:
                return kind == Type::Kind::Int8 || kind == Type::Kind::Int16
                       || kind == Type::Kind::Int32
                       || kind == Type::Kind::Int64;
            case Parameter::Unsigned:
                return kind == Type::Kind::UInt8 || kind == Type::Kind::UInt16
                       || kind == Type::Kind::UInt32
                       || kind == Type::Kind::UInt64;
            case Parameter::Floating:
                return kind == Type::Kind::Float16
                       || kind == Type::Kind::Float32
                       || kind == Type::Kind::Float64;
            case Parameter::Bool:
                return kind == Type::Kind::Bool;
            case Parameter::Char:
                return kind == Type::Kind::Character;
            case Parameter::Text:
                return kind == Type::Kind::String;
            case Parameter::Count:
                return kind == Type::Kind::Int64;
        }
        return false;
    }

    /// The type a call of the function has.
    /// @param result What the function returns.
    /// @return The kind of the type of a call.
    [[nodiscard]] constexpr auto
    ResultKind(const Result result) noexcept -> Type::Kind
    {
        return result == Result::Text    ? Type::Kind::String
               : result == Result::Truth ? Type::Kind::Bool
                                         : Type::Kind::Unit;
    }

    /// The identity a first operand names, or nothing when the operand is
    /// not a literal `int` that is not negative and fits sixty-four bits.
    /// The result still has to be looked up: not every number is a function.
    /// @param literal The payload of the first operand.
    /// @param type The type of the first operand.
    /// @return The identity, or nothing.
    [[nodiscard]] inline auto
    IdentityOf(const Literal &literal, const Type &type) noexcept
        -> std::optional<std::uint64_t>
    {
        if (type.kind != Type::Kind::Int64)
            return std::nullopt;
        if (const auto *fixed = std::get_if<std::int64_t>(&literal))
            return *fixed < 0 ? std::nullopt
                              : std::optional<std::uint64_t>(
                                    static_cast<std::uint64_t>(*fixed));
        const auto *integer = std::get_if<IntegerLiteral>(&literal);
        if (integer == nullptr || integer->negative
            || integer->magnitude.size() > 8U)
            return std::nullopt;
        std::uint64_t value = 0U;
        for (std::size_t index = integer->magnitude.size(); index-- > 0U;)
            value = (value << 8U) | integer->magnitude[index];
        return value;
    }

    /// Why a runtime call is malformed, when it is.
    enum class Defect : std::uint8_t
    {
        /// The call is well formed.
        None,
        /// There is no first operand, or it is not an integer literal that
        /// names a function of the catalog.
        Identity,
        /// The number of arguments is not the number the function takes.
        Arity,
        /// An argument has a type its parameter does not accept.
        Argument,
        /// The call does not have the type the function returns.
        Result
    };

    /// Checks the types of a runtime call against its row.
    ///
    /// Each stage finds the row from the literal its own representation
    /// holds and then calls this with the kinds of the arguments, so the
    /// rule is written once.
    /// @param signature The row the first operand names, or null.
    /// @param arguments The kinds of the types of the operands after the
    /// first.
    /// @param result The kind of the type of the call.
    /// @return What is wrong with the call, or Defect::None.
    [[nodiscard]] constexpr auto
    Check(const Signature *signature,
          const std::span<const Type::Kind> arguments,
          const Type::Kind result) noexcept -> Defect
    {
        if (signature == nullptr)
            return Defect::Identity;
        if (arguments.size() != signature->parameters.size())
            return Defect::Arity;
        for (std::size_t index = 0U; index < arguments.size(); ++index)
            if (!Accepts(signature->parameters[index], arguments[index]))
                return Defect::Argument;
        return result == ResultKind(signature->result) ? Defect::None
                                                       : Defect::Result;
    }

    /// What is wrong with a call, in the words every stage reports.
    /// @param defect The defect to describe.
    /// @return A sentence without a stage name or a diagnostic code.
    [[nodiscard]] constexpr auto
    Describe(const Defect defect) noexcept -> std::string_view
    {
        switch (defect)
        {
            case Defect::None:
                return "runtime call is well formed";
            case Defect::Identity:
                return "runtime call must begin with an integer literal that "
                       "names a function of the runtime catalog";
            case Defect::Arity:
                return "runtime call has the wrong number of arguments for "
                       "its function";
            case Defect::Argument:
                return "runtime call argument has a type its function does "
                       "not take";
            case Defect::Result:
                return "runtime call does not have the type its function "
                       "returns";
        }
        return {};
    }
} // namespace tala::core::runtime
