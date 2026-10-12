// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <limits>
#include <type_traits>
#include <utility>

#include "Progmasoft/Tala/Artifact/WireSupport.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"

namespace Progmasoft::Tala::Artifact::Wire
{
    namespace
    {
        namespace Core = ::tala::core;

        template<typename Integer>
        void
        AppendUnsigned(std::vector<std::uint8_t> &bytes, Integer value)
        {
            static_assert(std::is_unsigned_v<Integer>);
            for (std::size_t shift = 0; shift < sizeof(Integer) * 8U;
                 shift += 8U)
                bytes.push_back(
                    static_cast<std::uint8_t>((value >> shift) & 0xffU));
        }

        template<typename Integer>
        auto
        ReadUnsigned(Reader &reader, std::string_view context) -> Integer
        {
            static_assert(std::is_unsigned_v<Integer>);
            Integer value{};
            for (std::size_t shift = 0; shift < sizeof(Integer) * 8U;
                 shift += 8U)
                value |= static_cast<Integer>(reader.Byte(context)) << shift;
            return value;
        }

        auto
        IntegerPayload(const Core::Literal &literal)
            -> std::optional<Core::IntegerLiteral>
        {
            if (const auto *value = std::get_if<Core::IntegerLiteral>(&literal))
                return *value;
            if (const auto *value = std::get_if<std::int64_t>(&literal))
                return Core::integer_from_signed(*value);
            if (const auto *value = std::get_if<std::int32_t>(&literal))
                return Core::integer_from_signed(*value);
            return std::nullopt;
        }
    } // namespace

    Writer::Writer(const Limits &limits)
        : limits_(limits)
    {
        bytes_.reserve(4096U);
    }

    void
    Writer::Byte(std::uint8_t value)
    {
        if (error_)
            return;
        if (bytes_.size() >= limits_.maximumWireBytes)
        {
            Fail(ErrorKind::LimitExceeded,
                 "wire byte length",
                 "encoded artifact exceeds configured byte limit");
            return;
        }
        bytes_.push_back(value);
    }

    void
    Writer::U16(std::uint16_t value)
    {
        if (error_)
            return;
        if (bytes_.size() + sizeof(value) > limits_.maximumWireBytes)
        {
            Fail(ErrorKind::LimitExceeded,
                 "wire byte length",
                 "encoded artifact exceeds configured byte limit");
            return;
        }
        AppendUnsigned(bytes_, value);
    }

    void
    Writer::U32(std::uint32_t value)
    {
        if (error_)
            return;
        if (bytes_.size() + sizeof(value) > limits_.maximumWireBytes)
        {
            Fail(ErrorKind::LimitExceeded,
                 "wire byte length",
                 "encoded artifact exceeds configured byte limit");
            return;
        }
        AppendUnsigned(bytes_, value);
    }

    void
    Writer::U64(std::uint64_t value)
    {
        if (error_)
            return;
        if (bytes_.size() + sizeof(value) > limits_.maximumWireBytes)
        {
            Fail(ErrorKind::LimitExceeded,
                 "wire byte length",
                 "encoded artifact exceeds configured byte limit");
            return;
        }
        AppendUnsigned(bytes_, value);
    }

    void
    Writer::Boolean(bool value)
    {
        Byte(value ? 1U : 0U);
    }

    void
    Writer::Count(std::size_t value,
                  std::size_t maximum,
                  std::string_view context)
    {
        if (value > maximum
            || value > std::numeric_limits<std::uint32_t>::max())
        {
            Fail(ErrorKind::LimitExceeded,
                 std::string(context),
                 "collection count exceeds configured limit");
            return;
        }
        U32(static_cast<std::uint32_t>(value));
    }

    void
    Writer::Text(std::u32string_view value, std::string_view context)
    {
        Count(value.size(), limits_.maximumTextScalars, context);
        for (const auto scalar : value)
        {
            if (!IsUnicodeScalar(scalar))
            {
                Fail(ErrorKind::InvalidScalar,
                     std::string(context),
                     "text contains a non-scalar Unicode value");
                return;
            }
            U32(static_cast<std::uint32_t>(scalar));
        }
    }

    void
    Writer::QualifiedName(const std::vector<std::u32string> &value,
                          std::string_view context)
    {
        Count(value.size(), 65535U, context);
        for (const auto &part : value)
            Text(part, context);
    }

    void
    Writer::Symbol(const Core::SymbolName &value, std::string_view context)
    {
        if (value.id == 0U)
        {
            Fail(ErrorKind::InvalidSymbol,
                 std::string(context),
                 "symbol id must be positive");
            return;
        }
        U64(value.id);
        Text(value.spelling, context);
    }

    void
    Writer::Type(const Core::Type &value,
                 std::string_view context,
                 std::size_t depth)
    {
        if (depth > limits_.maximumTypeDepth)
        {
            Fail(ErrorKind::LimitExceeded,
                 std::string(context),
                 "type nesting exceeds configured limit");
            return;
        }
        Byte(static_cast<std::uint8_t>(value.kind));
        switch (value.kind)
        {
            case Core::Type::Kind::Named:
                QualifiedName(value.name, "named type");
                if (!value.components.empty())
                {
                    Fail(ErrorKind::InvalidModel,
                         std::string(context),
                         "named type contains function components");
                    break;
                }
                Count(value.templateArguments.size(),
                      limits_.maximumOperands,
                      "template argument count");
                for (const auto &argument : value.templateArguments)
                {
                    Byte(static_cast<std::uint8_t>(argument.kind));
                    if (argument.kind == Core::TemplateArgument::Kind::Type)
                    {
                        if (!argument.type)
                        {
                            Fail(ErrorKind::InvalidModel,
                                 std::string(context),
                                 "type template argument has no type payload");
                            break;
                        }
                        Type(*argument.type, context, depth + 1U);
                        continue;
                    }

                    const auto &templateValue = argument.value;
                    Byte(static_cast<std::uint8_t>(templateValue.kind));
                    if (templateValue.kind
                        == Core::TemplateValue::Kind::Boolean)
                    {
                        Boolean(templateValue.boolean);
                    }
                    else if (templateValue.kind
                             == Core::TemplateValue::Kind::Parameter)
                    {
                        Symbol(templateValue.parameter,
                               "template value parameter");
                    }
                    else
                    {
                        if (!Core::integer_is_canonical(templateValue.integer))
                        {
                            Fail(ErrorKind::InvalidInteger,
                                 std::string(context),
                                 "template integer payload is not canonical");
                            break;
                        }
                        Boolean(templateValue.integer.negative);
                        Count(templateValue.integer.magnitude.size(),
                              limits_.maximumNumericBytes,
                              "template integer magnitude");
                        for (const auto octet : templateValue.integer.magnitude)
                            Byte(octet);
                    }
                }
                break;
            case Core::Type::Kind::Function:
                if (value.components.empty())
                {
                    Fail(ErrorKind::InvalidModel,
                         std::string(context),
                         "function type is missing its result component");
                    break;
                }
                Count(value.components.size(),
                      limits_.maximumParameters + 1U,
                      "function type component count");
                for (const auto &component : value.components)
                    Type(component, context, depth + 1U);
                break;
            case Core::Type::Kind::TypeVariable:
                Symbol(value.variable, "type variable");
                break;
            default:
                if (!value.name.empty() || !value.components.empty()
                    || !value.templateArguments.empty()
                    || value.variable.id != 0U)
                    Fail(ErrorKind::InvalidModel,
                         std::string(context),
                         "scalar type contains aggregate payload");
                break;
        }
    }

    void
    Writer::Literal(const Core::Literal &value,
                    const Core::Type &type,
                    std::string_view context)
    {
        if (const auto issue = Core::validate_literal(value, type))
        {
            Fail(ErrorKind::InvalidModel, std::string(context), *issue);
            return;
        }
        if (std::holds_alternative<std::monostate>(value))
        {
            Byte(0U);
            return;
        }
        if (const auto *boolean = std::get_if<bool>(&value))
        {
            Byte(1U);
            Boolean(*boolean);
            return;
        }
        if (const auto integer = IntegerPayload(value))
        {
            Byte(2U);
            Boolean(integer->negative);
            Count(integer->magnitude.size(),
                  limits_.maximumNumericBytes,
                  "integer magnitude");
            for (const auto octet : integer->magnitude)
                Byte(octet);
            return;
        }
        if (const auto *floating = std::get_if<Core::FloatingLiteral>(&value))
        {
            Byte(3U);
            Count(floating->spelling.size(),
                  limits_.maximumNumericBytes,
                  "floating spelling");
            for (const auto character : floating->spelling)
                Byte(static_cast<std::uint8_t>(character));
            return;
        }
        if (const auto *text = std::get_if<std::u32string>(&value))
        {
            Byte(4U);
            Text(*text, "string literal");
            return;
        }
        Fail(ErrorKind::InvalidModel,
             std::string(context),
             "literal variant is not supported by artifact wire");
    }

    void
    Writer::Fail(ErrorKind kind, std::string context, std::string message)
    {
        if (!error_)
            error_ = Error{ kind,
                            bytes_.size(),
                            std::move(context),
                            std::move(message) };
    }

    auto
    Writer::Bytes() const -> const std::vector<std::uint8_t> &
    {
        return bytes_;
    }

    auto
    Writer::TakeBytes() -> std::vector<std::uint8_t>
    {
        return std::move(bytes_);
    }

    auto
    Writer::Failure() const -> const std::optional<Error> &
    {
        return error_;
    }

    auto
    Writer::Offset() const noexcept -> std::size_t
    {
        return bytes_.size();
    }

    Reader::Reader(std::span<const std::uint8_t> bytes, const Limits &limits)
        : bytes_(bytes)
        , limits_(limits)
    {
        if (bytes.size() > limits.maximumWireBytes)
            Fail(ErrorKind::LimitExceeded,
                 "wire byte length",
                 "input exceeds configured byte limit");
    }

    auto
    Reader::Byte(std::string_view context) -> std::uint8_t
    {
        if (error_)
            return 0U;
        if (offset_ >= bytes_.size())
        {
            Fail(ErrorKind::TruncatedInput,
                 std::string(context),
                 "input ended before field was complete");
            return 0U;
        }
        return bytes_[offset_++];
    }

    auto
    Reader::U16(std::string_view context) -> std::uint16_t
    {
        return ReadUnsigned<std::uint16_t>(*this, context);
    }

    auto
    Reader::U32(std::string_view context) -> std::uint32_t
    {
        return ReadUnsigned<std::uint32_t>(*this, context);
    }

    auto
    Reader::U64(std::string_view context) -> std::uint64_t
    {
        return ReadUnsigned<std::uint64_t>(*this, context);
    }

    auto
    Reader::Boolean(std::string_view context) -> bool
    {
        const auto value = Byte(context);
        if (!error_ && value > 1U)
            Fail(ErrorKind::InvalidBoolean,
                 std::string(context),
                 "boolean byte must be zero or one");
        return value == 1U;
    }

    auto
    Reader::Count(std::size_t maximum, std::string_view context) -> std::size_t
    {
        const auto value = U32(context);
        if (!error_ && value > maximum)
            Fail(ErrorKind::LimitExceeded,
                 std::string(context),
                 "collection count exceeds configured limit");
        return error_ ? 0U : static_cast<std::size_t>(value);
    }

    auto
    Reader::Text(std::string_view context) -> std::u32string
    {
        const auto count = Count(limits_.maximumTextScalars, context);
        std::u32string value;
        value.reserve(count);
        for (std::size_t index = 0; index < count && !error_; ++index)
        {
            const auto scalar = U32(context);
            if (!IsUnicodeScalar(static_cast<char32_t>(scalar)))
                Fail(ErrorKind::InvalidScalar,
                     std::string(context),
                     "text contains a non-scalar Unicode value");
            else
                value.push_back(static_cast<char32_t>(scalar));
        }
        return value;
    }

    auto
    Reader::QualifiedName(std::string_view context)
        -> std::vector<std::u32string>
    {
        const auto count = Count(65535U, context);
        std::vector<std::u32string> value;
        value.reserve(count);
        for (std::size_t index = 0; index < count && !error_; ++index)
            value.push_back(Text(context));
        return value;
    }

    auto
    Reader::Symbol(std::string_view context) -> Core::SymbolName
    {
        const auto id = U64(context);
        if (!error_ && id == 0U)
            Fail(ErrorKind::InvalidSymbol,
                 std::string(context),
                 "symbol id must be positive");
        return Core::SymbolName{ id, Text(context) };
    }

    auto
    Reader::Type(std::string_view context, std::size_t depth) -> Core::Type
    {
        if (depth > limits_.maximumTypeDepth)
        {
            Fail(ErrorKind::LimitExceeded,
                 std::string(context),
                 "type nesting exceeds configured limit");
            return Core::Type::unit();
        }
        const auto tag = Byte("type tag");
        if (tag > static_cast<std::uint8_t>(Core::Type::Kind::TypeVariable))
        {
            Fail(ErrorKind::InvalidTag,
                 "type tag",
                 "unknown artifact type tag");
            return Core::Type::unit();
        }
        const auto kind = static_cast<Core::Type::Kind>(tag);
        if (kind == Core::Type::Kind::Named)
        {
            auto name = QualifiedName("named type");
            const auto count
                = Count(limits_.maximumOperands, "template argument count");
            std::vector<Core::TemplateArgument> arguments;
            arguments.reserve(count);
            for (std::size_t index = 0; index < count && !error_; ++index)
            {
                const auto argumentKind = Byte("template argument kind");
                if (argumentKind
                    == static_cast<std::uint8_t>(
                        Core::TemplateArgument::Kind::Type))
                {
                    arguments.push_back(Core::TemplateArgument::type_argument(
                        Type(context, depth + 1U)));
                    continue;
                }
                if (argumentKind
                    != static_cast<std::uint8_t>(
                        Core::TemplateArgument::Kind::Value))
                {
                    Fail(ErrorKind::InvalidTag,
                         "template argument kind",
                         "unknown template argument kind");
                    break;
                }

                const auto valueKindByte = Byte("template value kind");
                if (valueKindByte > static_cast<std::uint8_t>(
                        Core::TemplateValue::Kind::Parameter))
                {
                    Fail(ErrorKind::InvalidTag,
                         "template value kind",
                         "unknown template value kind");
                    break;
                }
                const auto valueKind
                    = static_cast<Core::TemplateValue::Kind>(valueKindByte);
                Core::TemplateValue value;
                if (valueKind == Core::TemplateValue::Kind::Boolean)
                    value = Core::TemplateValue::boolean_value(
                        Boolean("template boolean value"));
                else if (valueKind == Core::TemplateValue::Kind::Parameter)
                    value = Core::TemplateValue::parameter_value(
                        Symbol("template value parameter"));
                else
                {
                    Core::IntegerLiteral integer;
                    integer.negative = Boolean("template integer sign");
                    const auto magnitudeCount
                        = Count(limits_.maximumNumericBytes,
                                "template integer magnitude");
                    integer.magnitude.reserve(magnitudeCount);
                    for (std::size_t magnitudeIndex = 0;
                         magnitudeIndex < magnitudeCount && !error_;
                         ++magnitudeIndex)
                        integer.magnitude.push_back(
                            Byte("template integer magnitude"));
                    if (!error_ && !Core::integer_is_canonical(integer))
                        Fail(ErrorKind::InvalidInteger,
                             std::string(context),
                             "template integer payload is not canonical");
                    value = valueKind == Core::TemplateValue::Kind::Character
                                ? Core::TemplateValue::character_value(
                                      std::move(integer))
                                : Core::TemplateValue::integer_value(
                                      std::move(integer));
                }
                arguments.push_back(
                    Core::TemplateArgument::value_argument(std::move(value)));
            }
            return Core::Type::named_template(std::move(name),
                                              std::move(arguments));
        }
        if (kind == Core::Type::Kind::Function)
        {
            const auto count = Count(limits_.maximumParameters + 1U,
                                     "function type component count");
            if (!error_ && count == 0U)
                Fail(ErrorKind::InvalidModel,
                     std::string(context),
                     "function type is missing its result component");
            std::vector<Core::Type> components;
            components.reserve(count);
            for (std::size_t index = 0; index < count && !error_; ++index)
                components.push_back(Type(context, depth + 1U));
            if (components.empty())
                return Core::Type::unit();
            auto result = std::move(components.back());
            components.pop_back();
            return Core::Type::function(std::move(components),
                                        std::move(result));
        }
        if (kind == Core::Type::Kind::TypeVariable)
            return Core::Type::type_variable(Symbol("type variable"));
        return Core::Type{ kind, {}, {}, {}, {} };
    }

    auto
    Reader::Literal(const Core::Type &type, std::string_view context)
        -> Core::Literal
    {
        Core::Literal value;
        switch (Byte("literal tag"))
        {
            case 0U:
                value = std::monostate{};
                break;
            case 1U:
                value = Boolean("boolean literal");
                break;
            case 2U:
            {
                Core::IntegerLiteral integer;
                integer.negative = Boolean("integer sign");
                const auto count
                    = Count(limits_.maximumNumericBytes, "integer magnitude");
                integer.magnitude.reserve(count);
                for (std::size_t index = 0; index < count && !error_; ++index)
                    integer.magnitude.push_back(Byte("integer magnitude"));
                if (!error_ && !Core::integer_is_canonical(integer))
                    Fail(ErrorKind::InvalidInteger,
                         std::string(context),
                         "integer payload is not canonical");
                value = std::move(integer);
                break;
            }
            case 3U:
            {
                const auto count
                    = Count(limits_.maximumNumericBytes, "floating spelling");
                std::string spelling;
                spelling.reserve(count);
                for (std::size_t index = 0; index < count && !error_; ++index)
                {
                    const auto character = Byte("floating spelling");
                    if (character > 0x7fU)
                        Fail(ErrorKind::InvalidInteger,
                             std::string(context),
                             "floating spelling must be ASCII");
                    else
                        spelling.push_back(static_cast<char>(character));
                }
                value = Core::FloatingLiteral{ std::move(spelling) };
                break;
            }
            case 4U:
                value = Text("string literal");
                break;
            default:
                Fail(ErrorKind::InvalidTag,
                     "literal tag",
                     "unknown artifact literal tag");
                value = std::monostate{};
                break;
        }
        if (!error_)
            if (const auto issue = Core::validate_literal(value, type))
                Fail(ErrorKind::InvalidModel, std::string(context), *issue);
        return value;
    }

    void
    Reader::Fail(ErrorKind kind, std::string context, std::string message)
    {
        if (!error_)
            error_ = Error{ kind,
                            offset_,
                            std::move(context),
                            std::move(message) };
    }

    auto
    Reader::Failure() const -> const std::optional<Error> &
    {
        return error_;
    }

    auto
    Reader::Offset() const noexcept -> std::size_t
    {
        return offset_;
    }

    auto
    Reader::AtEnd() const noexcept -> bool
    {
        return offset_ == bytes_.size();
    }

    auto
    Reader::InputSize() const noexcept -> std::size_t
    {
        return bytes_.size();
    }

    auto
    IsUnicodeScalar(char32_t value) noexcept -> bool
    {
        const auto scalar = static_cast<std::uint32_t>(value);
        return scalar <= 0x10ffffU && (scalar < 0xd800U || scalar > 0xdfffU);
    }
} // namespace Progmasoft::Tala::Artifact::Wire
