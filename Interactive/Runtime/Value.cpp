// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <array>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <fmt/format.h>
#include <limits>
#include <string>
#include <system_error>
#include <type_traits>
#include <variant>

#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Value.hpp"

namespace Progmasoft::Tala::Interactive::Runtime
{
    namespace
    {
        [[nodiscard]] auto
        IntegerText(std::int64_t value) -> std::string
        {
            return fmt::format("{}", value);
        }

        [[nodiscard]] auto
        IntegerText(std::uint64_t value) -> std::string
        {
            return fmt::format("{}", value);
        }

        [[nodiscard]] auto
        FloatingText(double value, std::uint16_t width)
            -> std::optional<std::string>
        {
            std::array<char, 128> buffer{};
            if (width == 32U)
            {
                const auto narrowed = static_cast<float>(value);
                const auto [end, error]
                    = std::to_chars(buffer.data(),
                                    buffer.data() + buffer.size(),
                                    narrowed,
                                    std::chars_format::general,
                                    std::numeric_limits<float>::max_digits10);
                if (error != std::errc{})
                    return std::nullopt;
                return std::string(buffer.data(), end);
            }
            if (width != 64U)
                return std::nullopt;
            const auto [end, error]
                = std::to_chars(buffer.data(),
                                buffer.data() + buffer.size(),
                                value,
                                std::chars_format::general,
                                std::numeric_limits<double>::max_digits10);
            if (error != std::errc{})
                return std::nullopt;
            return std::string(buffer.data(), end);
        }

        [[nodiscard]] auto
        CharacterLiteral(char32_t value) -> std::optional<std::string>
        {
            // Escaping every character avoids injecting a quote, physical line
            // break, or source encoding into the next cell's generated binding.
            const auto scalar = static_cast<std::uint32_t>(value);
            if (scalar > 0x10ffffU || (scalar >= 0xd800U && scalar <= 0xdfffU))
                return std::nullopt;
            if (scalar <= 0xffffU)
                return fmt::format("'\\u{:04X}'", scalar);
            return fmt::format("'\\U{:08X}'", scalar);
        }
    } // namespace

    auto
    SourceBinding(const Backend::LLVM::JitValue &value)
        -> std::optional<std::string>
    {
        const auto description = tala::core::describe_scalar(value.type);
        if (!description)
            return std::nullopt;

        return std::visit(
            [&](const auto &payload) -> std::optional<std::string> {
                using Value = std::remove_cvref_t<decltype(payload)>;
                if constexpr (std::is_same_v<Value, bool>)
                {
                    if (description->family
                        != tala::core::ScalarFamily::Boolean)
                        return std::nullopt;
                    return fmt::format("bool taliPrevious = {};",
                                       payload ? "true" : "false");
                }
                else if constexpr (std::is_same_v<Value, char32_t>)
                {
                    if (description->family
                        != tala::core::ScalarFamily::Character)
                        return std::nullopt;
                    const auto literal = CharacterLiteral(payload);
                    if (!literal)
                        return std::nullopt;
                    return fmt::format("char taliPrevious = {};", *literal);
                }
                else if constexpr (std::is_same_v<Value, std::int64_t>)
                {
                    if (description->family
                            != tala::core::ScalarFamily::SignedInteger
                        || description->bit_width > 64U)
                        return std::nullopt;
                    if (description->bit_width < 64U)
                    {
                        const auto limit = std::int64_t{ 1 }
                                           << (description->bit_width - 1U);
                        if (payload < -limit || payload >= limit)
                            return std::nullopt;
                    }
                    return fmt::format("{} taliPrevious = {};",
                                       description->spelling,
                                       IntegerText(payload));
                }
                else if constexpr (std::is_same_v<Value, std::uint64_t>)
                {
                    if (description->family
                            != tala::core::ScalarFamily::UnsignedInteger
                        || description->bit_width > 64U)
                        return std::nullopt;
                    if (description->bit_width < 64U
                        && payload >= (std::uint64_t{ 1 }
                                       << description->bit_width))
                        return std::nullopt;
                    return fmt::format("{} taliPrevious = {};",
                                       description->spelling,
                                       IntegerText(payload));
                }
                else if constexpr (std::is_same_v<Value, double>)
                {
                    if (description->family
                        != tala::core::ScalarFamily::Floating)
                        return std::nullopt;
                    auto literal
                        = FloatingText(payload, description->bit_width);
                    if (!literal)
                        return std::nullopt;
                    return fmt::format("{} taliPrevious = {};",
                                       description->spelling,
                                       *literal);
                }
                else
                    return std::nullopt;
            },
            value.payload);
    }

    auto
    DisplayValue(const Backend::LLVM::JitValue &value) -> std::string
    {
        return std::visit(
            [](const auto &payload) -> std::string {
                using Value = std::remove_cvref_t<decltype(payload)>;
                if constexpr (std::is_same_v<Value, std::monostate>)
                    return "void";
                else if constexpr (std::is_same_v<Value, bool>)
                    return payload ? "true" : "false";
                else if constexpr (std::is_same_v<Value, char32_t>)
                    return fmt::format("U+{:04X}",
                                       static_cast<std::uint32_t>(payload));
                else if constexpr (std::is_same_v<Value, std::int64_t>
                                   || std::is_same_v<Value, std::uint64_t>)
                    return IntegerText(payload);
                else if constexpr (std::is_same_v<Value, double>)
                    return fmt::format("{}", payload);
                else
                    return "<unsupported>";
            },
            value.payload);
    }

    auto
    DisplayType(const tala::core::Type &type) -> std::string
    {
        if (type.kind == tala::core::Type::Kind::Unit)
            return "void";
        if (const auto scalar = tala::core::describe_scalar(type))
            return std::string(scalar->spelling);
        if (type.kind == tala::core::Type::Kind::String)
            return "String";
        if (type.kind == tala::core::Type::Kind::Function)
            return "function";
        if (type.kind == tala::core::Type::Kind::Named)
        {
            std::string name;
            for (const auto &part : type.name)
            {
                if (!name.empty())
                    name.push_back('.');
                for (const auto scalar : part)
                {
                    if (scalar > 0x7fU)
                        return "named Tala type";
                    name.push_back(static_cast<char>(scalar));
                }
            }
            if (!type.templateArguments.empty())
                name.append("<...>");
            return name.empty() ? "named Tala type" : name;
        }
        return "unknown";
    }
} // namespace Progmasoft::Tala::Interactive::Runtime
