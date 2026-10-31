// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <limits>
#include <string_view>
#include <type_traits>

#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"

namespace tala::core::wire
{
    namespace
    {
        class Reader final
        {
        public:
            Reader(std::span<const std::uint8_t> bytes, const Limits &limits)
                : bytes_(bytes)
                , limits_(limits)
            {}

            [[nodiscard]] auto
            document() -> DecodeResult
            {
                if (bytes_.size() > limits_.maximum_wire_bytes)
                    return failure(ErrorKind::LimitExceeded,
                                   "wire byte length",
                                   "input exceeds configured byte limit");
                for (const auto expected : magic)
                    if (byte("magic") != expected)
                        return failure(
                            ErrorKind::InvalidMagic,
                            "magic",
                            "input is not a Tala CorePrep wire document");
                if (error_)
                    return result();
                const auto version = unsigned_integer<std::uint16_t>("version");
                if (!error_ && version != current_version)
                    fail(ErrorKind::UnsupportedVersion,
                         "version",
                         "unsupported CorePrep wire version");
                const auto flags = unsigned_integer<std::uint16_t>("flags");
                if (!error_ && flags != 0)
                    fail(ErrorKind::InvalidTag,
                         "flags",
                         "reserved wire flags must be zero");
                if (error_)
                    return result();
                CorePrepModule module;
                module.name = qualified_name("module name");
                module.sourceFiles
                    = vector<std::u32string>(limits_.maximum_functions,
                                             "source file count",
                                             [this] {
                                                 return text("source file");
                                             });
                module.functions = vector<Function>(limits_.maximum_functions,
                                                    "function count",
                                                    [this] {
                                                        return function();
                                                    });
                if (!error_ && offset_ != bytes_.size())
                    fail(ErrorKind::TrailingInput,
                         "document",
                         "bytes remain after CorePrep module");
                if (!error_)
                    module_ = std::move(module);
                return result();
            }

        private:
            std::span<const std::uint8_t> bytes_;
            const Limits &limits_;
            std::size_t offset_{};
            std::optional<CorePrepModule> module_;
            std::optional<Error> error_;

            [[nodiscard]] auto
            result() -> DecodeResult
            {
                return DecodeResult{ std::move(module_), std::move(error_) };
            }
            [[nodiscard]] auto
            failure(ErrorKind kind, std::string context, std::string message)
                -> DecodeResult
            {
                fail(kind, std::move(context), std::move(message));
                return result();
            }
            void
            fail(ErrorKind kind, std::string context, std::string message)
            {
                if (!error_)
                    error_ = Error{ kind,
                                    offset_,
                                    std::move(context),
                                    std::move(message) };
            }

            [[nodiscard]] auto
            byte(std::string_view context) -> std::uint8_t
            {
                if (offset_ >= bytes_.size())
                {
                    fail(ErrorKind::TruncatedInput,
                         std::string(context),
                         "input ended before the requested byte");
                    return 0;
                }
                return bytes_[offset_++];
            }

            template<typename Integer>
            [[nodiscard]] auto
            unsigned_integer(std::string_view context) -> Integer
            {
                static_assert(std::is_unsigned_v<Integer>);
                Integer result{};
                for (std::size_t shift = 0; shift < sizeof(Integer) * 8U;
                     shift += 8U)
                    result |= static_cast<Integer>(byte(context)) << shift;
                return result;
            }

            [[nodiscard]] auto
            count(std::size_t maximum, std::string_view context) -> std::size_t
            {
                const auto value = unsigned_integer<std::uint32_t>(context);
                if (!error_ && value > maximum)
                    fail(ErrorKind::LimitExceeded,
                         std::string(context),
                         "collection count exceeds configured limit");
                return error_ ? 0U : static_cast<std::size_t>(value);
            }

            template<typename Value, typename Decode>
            [[nodiscard]] auto
            vector(std::size_t maximum, std::string_view context, Decode decode)
                -> std::vector<Value>
            {
                const auto size = count(maximum, context);
                std::vector<Value> values;
                if (error_)
                    return values;
                values.reserve(size);
                for (std::size_t index = 0; index < size && !error_; ++index)
                    values.push_back(decode());
                return values;
            }

            [[nodiscard]] auto
            text(std::string_view context) -> std::u32string
            {
                const auto size
                    = count(limits_.maximum_string_code_points, context);
                std::u32string value;
                value.reserve(size);
                for (std::size_t index = 0; index < size && !error_; ++index)
                {
                    const auto code_point
                        = unsigned_integer<std::uint32_t>(context);
                    if (code_point > 0x10ffffU
                        || (code_point >= 0xd800U && code_point <= 0xdfffU))
                    {
                        fail(ErrorKind::InvalidCodePoint,
                             std::string(context),
                             "wire text contains a non-scalar Unicode code "
                             "point");
                        break;
                    }
                    value.push_back(static_cast<char32_t>(code_point));
                }
                return value;
            }

            [[nodiscard]] auto
            qualified_name(std::string_view context)
                -> std::vector<std::u32string>
            {
                return vector<std::u32string>(65535U, context, [this, context] {
                    return text(context);
                });
            }

            [[nodiscard]] auto
            symbol(std::string_view context) -> SymbolName
            {
                const auto id = unsigned_integer<SymbolId>(context);
                if (!error_ && id == 0)
                    fail(ErrorKind::InvalidSymbol,
                         std::string(context),
                         "symbol id must be positive");
                return SymbolName{ id, text(context) };
            }

            [[nodiscard]] auto
            type(std::size_t depth = 0) -> Type
            {
                if (depth > limits_.maximum_type_depth)
                {
                    fail(ErrorKind::LimitExceeded,
                         "type",
                         "type nesting exceeds configured limit");
                    return Type::unit();
                }
                const auto tag = byte("type tag");
                switch (tag)
                {
                    case 0:
                        return Type::unit();
                    case 1:
                        return Type::boolean();
                    case 2:
                        return Type::int64();
                    case 3:
                        return Type::int32();
                    case 4:
                        return Type::string();
                    case 5:
                    {
                        auto parameters
                            = vector<Type>(65535U,
                                           "function type parameter count",
                                           [this, depth] {
                                               return type(depth + 1U);
                                           });
                        auto result = type(depth + 1U);
                        return Type::function(std::move(parameters),
                                              std::move(result));
                    }
                    case 6:
                    {
                        auto name = qualified_name("named type");
                        auto arguments = vector<TemplateArgument>(
                            65535U,
                            "template argument count",
                            [this, depth] {
                                switch (byte("template argument tag"))
                                {
                                    case 0:
                                        return TemplateArgument::type_argument(
                                            type(depth + 1U));
                                    case 1:
                                        return TemplateArgument::value_argument(
                                            TemplateValue::integer_value(
                                                integer("template integer")));
                                    case 2:
                                        return TemplateArgument::value_argument(
                                            TemplateValue::boolean_value(
                                                boolean("template boolean")));
                                    case 3:
                                        return TemplateArgument::value_argument(
                                            TemplateValue::character_value(
                                                integer("template character")));
                                    case 4:
                                        return TemplateArgument::value_argument(
                                            TemplateValue::parameter_value(
                                                symbol("template value "
                                                       "parameter")));
                                    default:
                                        fail(ErrorKind::InvalidTag,
                                             "template argument tag",
                                             "unknown template argument tag");
                                        return TemplateArgument{};
                                }
                            });
                        return Type::named_template(std::move(name),
                                                    std::move(arguments));
                    }
                    case 7:
                        return Type::type_variable(
                            symbol("type variable symbol"));
                    case 8:
                        return Type::character();
                    case 9:
                        return Type::int8();
                    case 10:
                        return Type::int16();
                    case 11:
                        return Type::int128();
                    case 12:
                        return Type::uint8();
                    case 13:
                        return Type::uint16();
                    case 14:
                        return Type::uint32();
                    case 15:
                        return Type::uint64();
                    case 16:
                        return Type::uint128();
                    case 17:
                        return Type::float16();
                    case 18:
                        return Type::float32();
                    case 19:
                        return Type::float64();
                    case 20:
                        return Type::float128();
                    default:
                        fail(ErrorKind::InvalidTag,
                             "type tag",
                             "unknown CorePrep type tag");
                        return Type::unit();
                }
            }

            [[nodiscard]] auto
            boolean(std::string_view context) -> bool
            {
                const auto value = byte(context);
                if (value > 1U)
                    fail(ErrorKind::InvalidBoolean,
                         std::string(context),
                         "boolean byte must be zero or one");
                return value == 1U;
            }

            [[nodiscard]] auto
            integer(std::string_view context) -> IntegerLiteral
            {
                IntegerLiteral value;
                value.negative = boolean(std::string(context) + " sign");
                value.magnitude = vector<std::uint8_t>(
                    limits_.maximum_numeric_bytes,
                    std::string(context) + " magnitude",
                    [this, context] {
                        return byte(std::string(context) + " magnitude");
                    });
                if (!integer_is_canonical(value))
                    fail(ErrorKind::InvalidInteger,
                         std::string(context),
                         "integer magnitude/sign is not canonical");
                return value;
            }

            [[nodiscard]] auto
            literal(const Type &value_type) -> Literal
            {
                const auto literalTag = byte("literal tag");
                switch (literalTag)
                {
                    case 0U:
                        if (value_type.kind != Type::Kind::Unit)
                            fail(ErrorKind::UnsupportedType,
                                 "unit literal",
                                 "unit tag requires unit type");
                        return std::monostate{};
                    case 1U:
                        if (value_type.kind != Type::Kind::Bool)
                            fail(ErrorKind::UnsupportedType,
                                 "boolean literal",
                                 "boolean tag requires bool type");
                        return boolean("boolean literal");
                    case 2U:
                    {
                        IntegerLiteral value;
                        value.negative = boolean("integer sign");
                        value.magnitude = vector<std::uint8_t>(
                            limits_.maximum_numeric_bytes,
                            "integer magnitude",
                            [this] {
                                return byte("integer magnitude");
                            });
                        if (!integer_is_canonical(value))
                            fail(ErrorKind::InvalidInteger,
                                 "integer literal",
                                 "integer magnitude/sign is not canonical");
                        else if (!integer_fits(value, value_type)
                                 && value_type.kind != Type::Kind::Character)
                            fail(ErrorKind::InvalidInteger,
                                 "integer literal",
                                 "integer does not fit its declared scalar "
                                 "type");
                        else if (value_type.kind == Type::Kind::Character
                                 && (value.negative
                                     || value.magnitude.size() > 4U))
                            fail(ErrorKind::InvalidInteger,
                                 "character literal",
                                 "character payload exceeds unsigned 32-bit "
                                 "range");
                        return value;
                    }
                    case 4U:
                    {
                        const auto size = count(limits_.maximum_numeric_bytes,
                                                "floating literal length");
                        std::string spelling;
                        spelling.reserve(size);
                        for (std::size_t index = 0; index < size && !error_;
                             ++index)
                        {
                            const auto value = byte("floating literal");
                            if (value > 0x7fU)
                                fail(ErrorKind::InvalidInteger,
                                     "floating literal",
                                     "floating spelling must be ASCII");
                            else
                                spelling.push_back(static_cast<char>(value));
                        }
                        if (!error_ && !floating_spelling_is_valid(spelling))
                            fail(ErrorKind::InvalidInteger,
                                 "floating literal",
                                 "floating spelling is not canonical");
                        return FloatingLiteral{ std::move(spelling) };
                    }
                    case 3U:
                        if (value_type.kind != Type::Kind::String)
                            fail(ErrorKind::UnsupportedType,
                                 "string literal",
                                 "string tag requires String type");
                        return text("string literal");
                    case 5U:
                        if (value_type.kind != Type::Kind::Function
                            && value_type.kind != Type::Kind::Named
                            && value_type.kind != Type::Kind::String)
                            fail(ErrorKind::UnsupportedType,
                                 "null literal",
                                 "null tag requires an AARC reference type");
                        return std::monostate{};
                    default:
                        break;
                }
                fail(ErrorKind::InvalidTag,
                     "literal tag",
                     "unknown CorePrep literal tag");
                return std::monostate{};
            }

            [[nodiscard]] auto
            atom() -> Atom
            {
                const auto tag = byte("atom tag");
                auto value_type = type();
                if (tag == 0U)
                    return Atom::variable(symbol("variable symbol"),
                                          std::move(value_type));
                if (tag == 1U)
                {
                    auto value = literal(value_type);
                    return Atom::constant(std::move(value),
                                          std::move(value_type));
                }
                fail(ErrorKind::InvalidTag,
                     "atom tag",
                     "unknown CorePrep atom tag");
                return {};
            }

            [[nodiscard]] auto
            operation_tag() -> Operation
            {
                const auto tag = byte("operation tag");
                if (tag > static_cast<std::uint8_t>(Operation::RuntimeCall))
                {
                    fail(ErrorKind::InvalidTag,
                         "operation tag",
                         "unknown CorePrep operation tag");
                    return Operation::Copy;
                }
                return static_cast<Operation>(tag);
            }

            [[nodiscard]] auto
            capture_mode() -> CaptureMode
            {
                const auto tag = byte("capture mode");
                if (tag > static_cast<std::uint8_t>(CaptureMode::Unowned))
                {
                    fail(ErrorKind::InvalidTag,
                         "capture mode",
                         "unknown CorePrep capture mode");
                    return CaptureMode::Strong;
                }
                return static_cast<CaptureMode>(tag);
            }

            [[nodiscard]] auto
            capture() -> Capture
            {
                Capture value;
                value.mode = capture_mode();
                value.symbol = symbol("capture symbol");
                value.type = type();
                value.value = atom();
                return value;
            }

            void
            operation(Instruction &value)
            {
                value.operation = operation_tag();
                if (value.operation == Operation::MakeClosure)
                {
                    value.closure_function = symbol("closure function symbol");
                    value.captures = vector<Capture>(
                        limits_.maximum_operands_per_instruction,
                        "closure capture count",
                        [this] {
                            return capture();
                        });
                    return;
                }
                value.operands
                    = vector<Atom>(limits_.maximum_operands_per_instruction,
                                   "operand count",
                                   [this] {
                                       return atom();
                                   });
                if (error_)
                    return;
                if (value.operation == Operation::Copy
                    && value.operands.size() != 1U)
                    fail(ErrorKind::InvalidCount,
                         "copy",
                         "copy must contain exactly one operand");
                if (value.operation == Operation::Call
                    && value.operands.empty())
                    fail(ErrorKind::InvalidCount,
                         "call",
                         "call must contain a callee operand");
            }

            [[nodiscard]] auto
            instruction() -> Instruction
            {
                Instruction value;
                const auto tag = byte("instruction tag");
                if (tag
                    > static_cast<std::uint8_t>(Instruction::Kind::Evaluate))
                {
                    fail(ErrorKind::InvalidTag,
                         "instruction tag",
                         "unknown CorePrep instruction tag");
                    return value;
                }
                value.kind = static_cast<Instruction::Kind>(tag);
                switch (value.kind)
                {
                    case Instruction::Kind::Bind:
                        value.destination = symbol("binding symbol");
                        value.type = type();
                        value.mutable_binding = boolean("binding mutability");
                        operation(value);
                        break;
                    case Instruction::Kind::Assign:
                        value.destination = symbol("assignment symbol");
                        value.operands.push_back(atom());
                        value.operation = Operation::Copy;
                        value.type = value.operands.empty()
                                         ? Type::unit()
                                         : value.operands.front().type;
                        break;
                    case Instruction::Kind::Evaluate:
                        operation(value);
                        // The record carries no result type. A discarded
                        // call still produces its callee's result, and Xpp
                        // checks that type against the signature, so it is
                        // recovered from the callee atom rather than left
                        // as Unit.
                        if (value.operation == Operation::Call
                            && !value.operands.empty()
                            && value.operands.front().type.kind
                                   == Type::Kind::Function
                            && !value.operands.front().type.components.empty())
                            value.type
                                = value.operands.front().type.components.back();
                        break;
                }
                return value;
            }

            [[nodiscard]] auto
            terminator() -> Terminator
            {
                Terminator value;
                const auto tag = byte("terminator tag");
                if (tag
                    > static_cast<std::uint8_t>(Terminator::Kind::Unreachable))
                {
                    fail(ErrorKind::InvalidTag,
                         "terminator tag",
                         "unknown CorePrep terminator tag");
                    return value;
                }
                value.kind = static_cast<Terminator::Kind>(tag);
                switch (value.kind)
                {
                    case Terminator::Kind::Return:
                        value.value = atom();
                        break;
                    case Terminator::Kind::Branch:
                        value.value = atom();
                        value.true_target
                            = unsigned_integer<BlockId>("true target");
                        value.false_target
                            = unsigned_integer<BlockId>("false target");
                        break;
                    case Terminator::Kind::Jump:
                        value.true_target
                            = unsigned_integer<BlockId>("jump target");
                        break;
                    case Terminator::Kind::Unreachable:
                        break;
                }
                return value;
            }

            [[nodiscard]] auto
            block() -> Block
            {
                Block value;
                value.id = unsigned_integer<BlockId>("block id");
                value.instructions = vector<Instruction>(
                    limits_.maximum_instructions_per_block,
                    "instruction count",
                    [this] {
                        return instruction();
                    });
                value.terminator = terminator();
                return value;
            }

            [[nodiscard]] auto
            parameter() -> Parameter
            {
                return Parameter{ symbol("parameter symbol"), type() };
            }

            [[nodiscard]] auto
            function() -> Function
            {
                Function value;
                value.symbol = symbol("function symbol");
                value.sourceFile = text("function source file");
                value.parameters
                    = vector<Parameter>(limits_.maximum_parameters_per_function,
                                        "parameter count",
                                        [this] {
                                            return parameter();
                                        });
                value.return_type = type();
                value.entry = unsigned_integer<BlockId>("entry block");
                value.blocks
                    = vector<Block>(limits_.maximum_blocks_per_function,
                                    "block count",
                                    [this] {
                                        return block();
                                    });
                return value;
            }
        };
    } // namespace

    auto
    decode(std::span<const std::uint8_t> bytes, const Limits &limits)
        -> DecodeResult
    {
        return Reader(bytes, limits).document();
    }
} // namespace tala::core::wire
