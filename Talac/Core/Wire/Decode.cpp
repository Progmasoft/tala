// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <limits>
#include <string_view>
#include <type_traits>

#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Talac/Core/Wire/Magic.hpp"

namespace Progmasoft::Tala::Core::Wire
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

            /// @brief Validate the entire envelope before publication.
            /// Header checks precede allocation; the final offset check
            /// rejects trailing bytes and ambiguous encodings.
            [[nodiscard]] auto
            Document() -> DecodeResult
            {
                if (bytes_.size() > limits_.maximumWireBytes)
                    return Failure(ErrorKind::LimitExceeded,
                                   "wire byte length",
                                   "input exceeds configured byte limit");
                for (const auto expected : kMagic)
                    if (Byte("magic") != expected)
                        return Failure(ErrorKind::InvalidMagic,
                                       "magic",
                                       "input is not a Tala Core document");
                const auto version = Unsigned<std::uint16_t>("version");
                if (!error_ && version != kCurrentVersion)
                    Fail(ErrorKind::UnsupportedVersion,
                         "version",
                         "unsupported Core wire version");
                const auto flags = Unsigned<std::uint16_t>("flags");
                if (!error_ && flags != 0U)
                    Fail(ErrorKind::InvalidTag,
                         "flags",
                         "reserved flags must be zero");
                if (error_)
                    return Result();

                Module module;
                module.name = QualifiedName("module name");
                module.sourceFiles
                    = Vector<std::u32string>(limits_.maximumFunctions,
                                             "source file count",
                                             [this] {
                                                 return Text("source file");
                                             });
                module.functions = Vector<Function>(limits_.maximumFunctions,
                                                    "function count",
                                                    [this] {
                                                        return ReadFunction();
                                                    });
                if (!error_ && offset_ != bytes_.size())
                    Fail(ErrorKind::TrailingInput,
                         "document",
                         "bytes remain after Core module");
                if (!error_)
                    module_ = std::move(module);
                return Result();
            }

        private:
            std::span<const std::uint8_t> bytes_;
            const Limits &limits_;
            std::size_t offset_{};
            std::size_t statementDepth_{};
            std::optional<Module> module_;
            std::optional<Error> error_;

            [[nodiscard]] auto
            Result() -> DecodeResult
            {
                return DecodeResult{ std::move(module_), std::move(error_) };
            }
            [[nodiscard]] auto
            Failure(ErrorKind kind, std::string context, std::string message)
                -> DecodeResult
            {
                Fail(kind, std::move(context), std::move(message));
                return Result();
            }
            [[gnu::noinline]] void
            Fail(ErrorKind kind, std::string context, std::string message)
            {
                if (!error_)
                    error_ = Error{ kind,
                                    offset_,
                                    std::move(context),
                                    std::move(message) };
            }
            [[nodiscard]] auto
            Byte(std::string_view context) -> std::uint8_t
            {
                if (offset_ >= bytes_.size())
                {
                    Fail(ErrorKind::TruncatedInput,
                         std::string(context),
                         "input ended before field was complete");
                    return 0U;
                }
                return bytes_[offset_++];
            }
            /**
             * @brief Read an unsigned little-endian wire scalar
             * of a fixed width.
             *
             * This byte order
             * is explicit so host endianness cannot alter TACR.
             */
            template<typename Integer>
            [[nodiscard]] auto
            Unsigned(std::string_view context) -> Integer
            {
                static_assert(std::is_unsigned_v<Integer>);
                Integer result{};
                for (std::size_t shift = 0; shift < sizeof(Integer) * 8U;
                     shift += 8U)
                    result |= static_cast<Integer>(Byte(context)) << shift;
                return result;
            }
            /// @brief Validate an untrusted length before narrowing it.
            /// Callers use the checked count before reserving memory or
            /// decoding recursively, preventing unchecked allocations.
            [[nodiscard]] auto
            Count(std::size_t maximum, std::string_view context) -> std::size_t
            {
                const auto value = Unsigned<std::uint32_t>(context);
                if (!error_ && value > maximum)
                    Fail(ErrorKind::LimitExceeded,
                         std::string(context),
                         "collection count exceeds configured limit");
                return error_ ? 0U : static_cast<std::size_t>(value);
            }
            /// @brief Reserve only after Count enforces the caller's limit.
            template<typename Value, typename Decode>
            [[nodiscard]] auto
            Vector(std::size_t maximum, std::string_view context, Decode decode)
                -> std::vector<Value>
            {
                const auto size = Count(maximum, context);
                std::vector<Value> values;
                values.reserve(size);
                for (std::size_t index = 0; index < size && !error_; ++index)
                    values.push_back(decode());
                return values;
            }
            /// @brief Read UTF-32 text and reject non-scalar values.
            /// TACR counts Unicode scalars, not UTF-8 bytes or UTF-16
            /// code units. Surrogates and values above U+10FFFF are invalid.
            [[nodiscard, gnu::noinline]] auto
            Text(std::string_view context) -> std::u32string
            {
                const auto size = Count(limits_.maximumTextScalars, context);
                std::u32string value;
                value.reserve(size);
                for (std::size_t index = 0; index < size && !error_; ++index)
                {
                    const auto scalar = Unsigned<std::uint32_t>(context);
                    if (scalar > 0x10ffffU
                        || (scalar >= 0xd800U && scalar <= 0xdfffU))
                    {
                        Fail(ErrorKind::InvalidScalar,
                             std::string(context),
                             "wire text contains a non-scalar Unicode value");
                        break;
                    }
                    value.push_back(static_cast<char32_t>(scalar));
                }
                return value;
            }
            [[nodiscard, gnu::noinline]] auto
            QualifiedName(std::string_view context)
                -> std::vector<std::u32string>
            {
                return Vector<std::u32string>(65535U, context, [this, context] {
                    return Text(context);
                });
            }
            [[nodiscard, gnu::noinline]] auto
            Symbol(std::string_view context) -> SymbolName
            {
                const auto id = Unsigned<SymbolId>(context);
                if (!error_ && id == 0U)
                    Fail(ErrorKind::InvalidSymbol,
                         std::string(context),
                         "symbol id must be positive");
                return SymbolName{ id, Text(context) };
            }
            [[nodiscard, gnu::noinline]] auto
            ReadType(std::size_t depth = 0U) -> Type
            {
                if (depth > limits_.maximumTypeDepth)
                {
                    Fail(ErrorKind::LimitExceeded,
                         "type",
                         "type nesting exceeds configured limit");
                    return Type::unit();
                }
                switch (Byte("type tag"))
                {
                    case 0:
                        return Type::unit();
                    case 1:
                        return Type::boolean();
                    case 2:
                        return Type::int64();
                    case 3:
                        return Type::string();
                    case 4:
                    {
                        auto name = QualifiedName("named type");
                        auto arguments = Vector<::tala::core::TemplateArgument>(
                            limits_.maximumOperands,
                            "template argument count",
                            [this, depth] {
                                switch (Byte("template argument tag"))
                                {
                                    case 0:
                                        return ::tala::core::TemplateArgument::
                                            type_argument(ReadType(depth + 1U));
                                    case 1:
                                        return ::tala::core::TemplateArgument::
                                            value_argument(
                                                ::tala::core::TemplateValue::
                                                    integer_value(ReadInteger(
                                                        "template "
                                                        "integer")));
                                    case 2:
                                        return ::tala::core::TemplateArgument::
                                            value_argument(
                                                ::tala::core::TemplateValue::
                                                    boolean_value(
                                                        Boolean("template "
                                                                "boolean")));
                                    case 3:
                                        return ::tala::core::TemplateArgument::
                                            value_argument(
                                                ::tala::core::TemplateValue::
                                                    character_value(ReadInteger(
                                                        "template "
                                                        "character")));
                                    case 4:
                                        return ::tala::core::TemplateArgument::
                                            value_argument(
                                                ::tala::core::TemplateValue::
                                                    parameter_value(
                                                        Symbol("template value "
                                                               "parameter")));
                                    default:
                                        Fail(ErrorKind::InvalidTag,
                                             "template argument tag",
                                             "unknown template argument tag");
                                        return ::tala::core::TemplateArgument{};
                                }
                            });
                        return Type::named_template(std::move(name),
                                                    std::move(arguments));
                    }
                    case 5:
                    {
                        auto parameters
                            = Vector<Type>(limits_.maximumParameters,
                                           "function type parameter count",
                                           [this, depth] {
                                               return ReadType(depth + 1U);
                                           });
                        return Type::function(std::move(parameters),
                                              ReadType(depth + 1U));
                    }
                    case 6:
                        return Type::type_variable(
                            Symbol("type variable symbol"));
                    case 7:
                        return Type::character();
                    case 8:
                        return Type::int8();
                    case 9:
                        return Type::int16();
                    case 10:
                        return Type::int32();
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
                        Fail(ErrorKind::InvalidTag,
                             "type tag",
                             "unknown Core type tag");
                        return Type::unit();
                }
            }
            [[nodiscard]] auto
            Boolean(std::string_view context) -> bool
            {
                const auto value = Byte(context);
                if (value > 1U)
                    Fail(ErrorKind::InvalidBoolean,
                         std::string(context),
                         "boolean byte must be zero or one");
                return value == 1U;
            }
            [[nodiscard, gnu::noinline]] auto
            ReadInteger(std::string_view context)
                -> ::tala::core::IntegerLiteral
            {
                ::tala::core::IntegerLiteral value;
                value.negative = Boolean(std::string(context) + " sign");
                value.magnitude = Vector<std::uint8_t>(
                    limits_.maximumNumericBytes,
                    std::string(context) + " magnitude",
                    [this, context] {
                        return Byte(std::string(context) + " magnitude");
                    });
                if (!::tala::core::integer_is_canonical(value))
                    Fail(ErrorKind::InvalidInteger,
                         std::string(context),
                         "integer magnitude/sign is not canonical");
                return value;
            }
            [[nodiscard, gnu::noinline]] auto
            ReadLiteral() -> Literal
            {
                switch (Byte("literal tag"))
                {
                    case 0:
                        return std::monostate{};
                    case 1:
                        return Boolean("boolean literal");
                    case 2:
                        return static_cast<std::int64_t>(
                            Unsigned<std::uint64_t>("integer literal"));
                    case 3:
                        return Text("string literal");
                    case 4:
                    {
                        ::tala::core::IntegerLiteral value;
                        value.negative = Boolean("integer sign");
                        value.magnitude = Vector<std::uint8_t>(
                            limits_.maximumNumericBytes,
                            "integer magnitude",
                            [this] {
                                return Byte("integer magnitude");
                            });
                        if (!::tala::core::integer_is_canonical(value))
                            Fail(ErrorKind::InvalidInteger,
                                 "integer literal",
                                 "integer magnitude/sign is not canonical");
                        return value;
                    }
                    case 5:
                    {
                        const auto size = Count(limits_.maximumNumericBytes,
                                                "floating literal length");
                        std::string spelling;
                        spelling.reserve(size);
                        for (std::size_t index = 0; index < size && !error_;
                             ++index)
                        {
                            const auto value = Byte("floating literal");
                            if (value > 0x7fU)
                                Fail(ErrorKind::InvalidInteger,
                                     "floating literal",
                                     "floating spelling must be ASCII");
                            else
                                spelling.push_back(static_cast<char>(value));
                        }
                        if (!error_
                            && !::tala::core::floating_spelling_is_valid(
                                spelling))
                            Fail(ErrorKind::InvalidInteger,
                                 "floating literal",
                                 "floating spelling is not canonical");
                        return ::tala::core::FloatingLiteral{ std::move(
                            spelling) };
                    }
                    case 6:
                        return std::monostate{};
                    default:
                        Fail(ErrorKind::InvalidTag,
                             "literal tag",
                             "unknown Core literal tag");
                        return std::monostate{};
                }
            }
            /// The tag bytes of the expressions that the reader walks in a
            /// loop.
            static constexpr std::uint8_t kPrimitiveTag = 3U;
            static constexpr std::uint8_t kLetTag = 5U;
            static constexpr std::uint8_t kConditionalExpressionTag = 6U;

            /// An expression whose header and leading children were read
            /// and that waits for the one child the loop reads next.
            struct Pending final
            {
                std::uint8_t tag{};
                /// The level of this expression.
                std::size_t level{};
                Primitive primitive{ Primitive::Add };
                Type valueType;
                /// Primitive: the number of operands, the first of which is
                /// awaited.
                std::size_t operands{};
                /// Let: the bound symbol, its type and its value; the body
                /// is awaited.
                SymbolName symbol;
                Type bindingType;
                /// Let: the value. Conditional: the test.
                Expression first;
                /// Conditional: the true branch; the false one is awaited.
                Expression second;
            };

            /**
             * @brief Read one expression into its place.
             *
             * Three shapes nest as deep as an expression is long: a chain
             * of operators nests in the first operand of each primitive, a
             * chain of conditional expressions in each false branch, and a
             * sequence of bindings in each let body. Reading them by
             * recursion would use stack in proportion to the length of the
             * chain, so those children are read in a loop: the enclosing
             * expression is kept in a list while its awaited child is read,
             * and the list is folded innermost first. Every other child is
             * read by recursion, which the depth limit bounds. The bytes
             * consumed and the resulting tree are those of the recursive
             * formulation. The first operand of a primitive is at the level
             * of the primitive, so a chain of operators does not count
             * against the depth limit; every other child is one level
             * deeper than its parent.
             *
             * An expression is large. The functions on the path that
             * recurses once per level therefore hold none: an expression is
             * read into its place, and the functions that build one from
             * its parts are separate and return before the next level is
             * entered.
             */
            [[gnu::noinline]] void
            ReadExpressionInto(Expression &expression, std::size_t depth = 0U)
            {
                std::vector<Pending> spine;
                auto level = depth;
                for (;;)
                {
                    if (level > limits_.maximumExpressionDepth)
                    {
                        Fail(ErrorKind::LimitExceeded,
                             "expression",
                             "expression nesting exceeds configured limit");
                        break;
                    }
                    const auto tag = Byte("expression tag");
                    if (tag != kPrimitiveTag && tag != kLetTag
                        && tag != kConditionalExpressionTag)
                    {
                        ReadUnchained(expression, tag, level);
                        break;
                    }
                    if (!ReadPending(tag, level, spine, expression))
                        break;
                    if (tag != kPrimitiveTag)
                        ++level;
                }
                while (!spine.empty() && !error_)
                {
                    Complete(spine.back(), expression);
                    spine.pop_back();
                }
                if (error_)
                    Reset(expression);
            }
            /// Read one expression and return it. For callers that are not
            /// on the path that recurses once per level.
            [[nodiscard, gnu::noinline]] auto
            ReadExpression() -> Expression
            {
                Expression expression;
                ReadExpressionInto(expression);
                return expression;
            }
            [[gnu::noinline]] static void
            Reset(Expression &expression)
            {
                expression = Expression{};
            }

            /// Read the header and the leading children of a primitive, a
            /// let or a conditional whose tag was consumed, into a new last
            /// entry of the list, where it waits for its next child.
            /// Returns false when no child is awaited: `expression` then
            /// holds the result, or the input was rejected.
            [[nodiscard, gnu::noinline]] auto
            ReadPending(std::uint8_t tag,
                        std::size_t level,
                        std::vector<Pending> &spine,
                        Expression &expression) -> bool
            {
                // The entry is filled in place. Nothing appends to this list
                // while its children are read, so the reference stays valid.
                spine.emplace_back();
                auto &pending = spine.back();
                pending.tag = tag;
                pending.level = level;
                const auto primitiveTag
                    = tag == kPrimitiveTag ? Byte("primitive tag") : 0U;
                ReadTypeInto(pending.valueType);
                if (tag == kPrimitiveTag)
                {
                    if (primitiveTag
                        > static_cast<std::uint8_t>(Primitive::RuntimeCall))
                        Fail(ErrorKind::InvalidTag,
                             "primitive tag",
                             "unknown Core primitive tag");
                    else
                        pending.primitive
                            = static_cast<Primitive>(primitiveTag);
                    pending.operands = Count(limits_.maximumOperands,
                                             "primitive operand count");
                    if (!error_ && pending.operands == 0U)
                    {
                        BuildPrimitive(pending, {}, expression);
                        spine.pop_back();
                        return false;
                    }
                }
                else if (tag == kLetTag)
                {
                    ReadLetHeader(pending);
                    ReadExpressionInto(pending.first, level + 1U);
                }
                else
                {
                    // The three children have fixed positions, so the
                    // payload carries no count.
                    ReadExpressionInto(pending.first, level + 1U);
                    ReadExpressionInto(pending.second, level + 1U);
                }
                if (error_)
                {
                    spine.pop_back();
                    return false;
                }
                return true;
            }
            [[gnu::noinline]] void
            ReadTypeInto(Type &type)
            {
                type = ReadType();
            }
            [[gnu::noinline]] void
            ReadLetHeader(Pending &pending)
            {
                pending.symbol = Symbol("let symbol");
                pending.bindingType = ReadType();
            }

            /// Build a pending expression from the child it waited for,
            /// which `expression` holds, reading the operands of a
            /// primitive that follow the first. The result replaces the
            /// child in `expression`.
            [[gnu::noinline]] void
            Complete(Pending &pending, Expression &expression)
            {
                if (pending.tag == kLetTag)
                {
                    BuildLet(pending, expression);
                    return;
                }
                if (pending.tag == kConditionalExpressionTag)
                {
                    BuildConditional(pending, expression);
                    return;
                }
                std::vector<Expression> operands;
                operands.reserve(pending.operands);
                operands.push_back(std::move(expression));
                for (std::size_t index = 1U;
                     index < pending.operands && !error_;
                     ++index)
                {
                    operands.emplace_back();
                    ReadExpressionInto(operands.back(), pending.level + 1U);
                }
                BuildPrimitive(pending, std::move(operands), expression);
            }
            [[gnu::noinline]] static void
            BuildPrimitive(Pending &pending,
                           std::vector<Expression> operands,
                           Expression &expression)
            {
                expression
                    = Expression::InvokePrimitive(pending.primitive,
                                                  std::move(operands),
                                                  std::move(pending.valueType));
            }
            [[gnu::noinline]] static void
            BuildLet(Pending &pending, Expression &expression)
            {
                expression = Expression::Let(std::move(pending.symbol),
                                             std::move(pending.bindingType),
                                             std::move(pending.first),
                                             std::move(expression),
                                             std::move(pending.valueType));
            }
            [[gnu::noinline]] static void
            BuildConditional(Pending &pending, Expression &expression)
            {
                expression
                    = Expression::Conditional(std::move(pending.first),
                                              std::move(pending.second),
                                              std::move(expression),
                                              std::move(pending.valueType));
            }

            /// Read an expression that is not walked in a loop; its tag was
            /// consumed.
            [[gnu::noinline]] void
            ReadUnchained(Expression &expression,
                          std::uint8_t tag,
                          std::size_t depth)
            {
                switch (tag)
                {
                    case 0:
                    case 1:
                        ReadLeaf(expression, tag);
                        return;
                    case 2:
                        ReadApply(expression, depth);
                        return;
                    case 4:
                        ReadClosure(expression, depth);
                        return;
                    default:
                        // The type precedes the payload of every tag and is
                        // consumed before the tag is rejected, as the
                        // recursive formulation did.
                        ReadLeaf(expression, tag);
                        return;
                }
            }
            [[gnu::noinline]] void
            ReadLeaf(Expression &expression, std::uint8_t tag)
            {
                auto valueType = ReadType();
                if (tag == 0U)
                    expression = Expression::Variable(Symbol("variable symbol"),
                                                      std::move(valueType));
                else if (tag == 1U)
                    expression = Expression::Constant(ReadLiteral(),
                                                      std::move(valueType));
                else
                    Fail(ErrorKind::InvalidTag,
                         "expression tag",
                         "unknown Core expression tag");
            }
            /// Read the operands of a call or the like into a list, each
            /// into its place.
            void
            ReadOperands(std::vector<Expression> &operands,
                         std::string_view context,
                         std::size_t depth)
            {
                const auto size = Count(limits_.maximumOperands, context);
                operands.reserve(size);
                for (std::size_t index = 0U; index < size && !error_; ++index)
                {
                    operands.emplace_back();
                    ReadExpressionInto(operands.back(), depth);
                }
            }
            [[gnu::noinline]] void
            ReadApply(Expression &expression, std::size_t depth)
            {
                auto valueType = ReadType();
                // The callee is read into the place of the result and moved
                // out of it when the call is built.
                ReadExpressionInto(expression, depth + 1U);
                std::vector<Expression> arguments;
                ReadOperands(arguments, "call argument count", depth + 1U);
                BuildApply(expression, arguments, valueType);
            }
            [[gnu::noinline]] static void
            BuildApply(Expression &expression,
                       std::vector<Expression> &arguments,
                       Type &valueType)
            {
                expression = Expression::Apply(std::move(expression),
                                               std::move(arguments),
                                               std::move(valueType));
            }
            [[gnu::noinline]] void
            ReadClosure(Expression &expression, std::size_t depth)
            {
                auto valueType = ReadType();
                auto captures
                    = Vector<Capture>(limits_.maximumOperands,
                                      "closure capture count",
                                      [this, depth] {
                                          return ReadCapture(depth + 1U);
                                      });
                auto parameters = Vector<std::pair<SymbolName, Type>>(
                    limits_.maximumParameters,
                    "closure parameter count",
                    [this] {
                        auto parameter = ReadParameter();
                        return std::pair{ std::move(parameter.symbol),
                                          std::move(parameter.type) };
                    });
                auto returnType = ReadType();
                auto body = ReadBody("closure statement count");
                expression = Expression::Closure(std::move(captures),
                                                 std::move(parameters),
                                                 std::move(returnType),
                                                 std::move(body),
                                                 std::move(valueType));
            }
            [[nodiscard, gnu::noinline]] auto
            ReadCapture(std::size_t depth) -> Capture
            {
                const auto tag = Byte("closure capture mode");
                if (tag > 2U)
                    Fail(ErrorKind::InvalidTag,
                         "closure capture mode",
                         "unknown Core closure capture mode");
                Capture capture;
                // A rejected tag never becomes an enumerator.
                capture.mode = tag > 2U ? CaptureMode::Strong
                                        : static_cast<CaptureMode>(tag);
                capture.symbol = Symbol("closure capture symbol");
                capture.type = ReadType();
                capture.value = std::make_shared<Expression>();
                ReadExpressionInto(*capture.value, depth);
                return capture;
            }
            /// Enter one level of statement nesting, or fail when the level
            /// is beyond the limit. Every successful call is paired with
            /// LeaveBody.
            [[nodiscard]] auto
            EnterBody(std::string_view context) -> bool
            {
                if (statementDepth_ >= limits_.maximumStatementDepth)
                {
                    Fail(ErrorKind::LimitExceeded,
                         std::string(context),
                         "statement nesting exceeds configured limit");
                    return false;
                }
                ++statementDepth_;
                return true;
            }
            void
            LeaveBody()
            {
                --statementDepth_;
            }
            /**
             * @brief Read the statements of a function, branch, loop or
             * closure body, one nesting level below the current one.
             *
             * The reader recurses once per level, so the level is bounded
             * like type and expression depth are: input that nests deeper
             * than the limit is rejected before it can exhaust the stack.
             * The level is reader state rather than a parameter because a
             * closure body is reached through an expression.
             *
             * A statement holds two expressions by value and is large. The
             * functions on the path that recurses once per level therefore
             * hold none: a statement is read into its place in the list,
             * and the functions that build one from its parts are separate
             * and return before the next level is entered.
             */
            [[nodiscard, gnu::noinline]] auto
            ReadBody(std::string_view context) -> std::vector<Statement>
            {
                // An empty body holds nothing to recurse into, so it is
                // accepted at any level, as the writer writes it.
                const auto size = Count(limits_.maximumStatements, context);
                std::vector<Statement> statements;
                if (size == 0U || !EnterBody(context))
                    return statements;
                ReadStatements(size, statements);
                LeaveBody();
                return statements;
            }
            void
            ReadStatements(std::size_t size, std::vector<Statement> &statements)
            {
                statements.reserve(size);
                for (std::size_t index = 0; index < size && !error_; ++index)
                {
                    // Nothing else appends to this list while the statement
                    // is read, so the reference stays valid.
                    statements.emplace_back();
                    ReadStatement(statements.back());
                }
            }

            /// The tag byte of a conditional statement.
            static constexpr std::uint8_t kConditionalTag = 3U;

            /// One link of an `else if` chain whose false branch is the
            /// next link.
            struct Link final
            {
                Expression condition;
                std::vector<Statement> whenTrue;
            };

            /**
             * @brief Read a conditional statement whose tag was consumed,
             * and every `else if` that continues it.
             *
             * An `else if` is encoded as a false branch that holds exactly
             * one conditional statement. Reading such a chain by recursion
             * uses stack in proportion to its length, so a long chain in
             * valid source would overflow it. The links are read in a loop
             * into a flat list and nested afterwards, innermost first. The
             * bytes consumed and the resulting tree are those of the
             * recursive formulation.
             */
            [[gnu::noinline]] void
            ReadConditionalChain(Statement &statement)
            {
                std::vector<Link> links;
                std::vector<Statement> finalBranch;
                for (;;)
                {
                    links.emplace_back();
                    ReadExpressionInto(links.back().condition);
                    links.back().whenTrue
                        = ReadBody("true branch statement count");
                    const auto size = Count(limits_.maximumStatements,
                                            "false branch statement count");
                    // A false branch of one conditional is the next link:
                    // take its tag and read it in the next iteration.
                    if (!error_ && size == 1U && offset_ < bytes_.size()
                        && bytes_[offset_] == kConditionalTag)
                    {
                        ++offset_;
                        continue;
                    }
                    // The links of a chain share one level; the last false
                    // branch is a body one level below it.
                    if (size != 0U && EnterBody("false branch statement count"))
                    {
                        ReadStatements(size, finalBranch);
                        LeaveBody();
                    }
                    break;
                }
                NestLink(statement, links.back(), finalBranch);
                links.pop_back();
                while (!links.empty())
                {
                    std::vector<Statement> nested;
                    nested.push_back(std::move(statement));
                    NestLink(statement, links.back(), nested);
                    links.pop_back();
                }
            }
            [[gnu::noinline]] static void
            NestLink(Statement &statement,
                     Link &link,
                     std::vector<Statement> &whenFalse)
            {
                statement = Statement::If(std::move(link.condition),
                                          std::move(link.whenTrue),
                                          std::move(whenFalse));
            }

            // Each kind of statement is read by a function of its own, so
            // that a level of nesting costs the frame of the kind that
            // nests and not the frames of every kind together.
            void
            ReadStatement(Statement &statement)
            {
                switch (Byte("statement tag"))
                {
                    case 0:
                        ReadBinding(statement);
                        return;
                    case 1:
                        ReadAssignment(statement);
                        return;
                    case 2:
                        ReadValueStatement(statement, Statement::Kind::Return);
                        return;
                    case 3:
                        ReadConditionalChain(statement);
                        return;
                    case 4:
                        ReadValueStatement(statement,
                                           Statement::Kind::Evaluate);
                        return;
                    case 5:
                        ReadWhile(statement);
                        return;
                    case 6:
                        ReadDoWhile(statement);
                        return;
                    case 7:
                        ReadFor(statement);
                        return;
                    case 8:
                        SetJump(statement, Statement::Kind::Break);
                        return;
                    case 9:
                        SetJump(statement, Statement::Kind::Continue);
                        return;
                    default:
                        Fail(ErrorKind::InvalidTag,
                             "statement tag",
                             "unknown Core statement tag");
                        return;
                }
            }
            [[gnu::noinline]] void
            ReadBinding(Statement &statement)
            {
                auto symbol = Symbol("binding symbol");
                auto type = ReadType();
                const auto mutableBinding = Boolean("binding mutability");
                auto value = ReadExpression();
                statement = Statement::Bind(Binding{ std::move(symbol),
                                                     std::move(type),
                                                     mutableBinding,
                                                     std::move(value) });
            }
            [[gnu::noinline]] void
            ReadAssignment(Statement &statement)
            {
                auto symbol = Symbol("assignment symbol");
                statement
                    = Statement::Assign(std::move(symbol), ReadExpression());
            }
            [[gnu::noinline]] void
            ReadValueStatement(Statement &statement, Statement::Kind kind)
            {
                statement = kind == Statement::Kind::Return
                                ? Statement::Return(ReadExpression())
                                : Statement::Evaluate(ReadExpression());
            }
            [[gnu::noinline]] static void
            SetJump(Statement &statement, Statement::Kind kind)
            {
                statement = kind == Statement::Kind::Break
                                ? Statement::Break()
                                : Statement::Continue();
            }
            // The loops read their parts into locals that are lists, which
            // are small, and into the statement itself; the builders below
            // put the parts in their final places.
            [[gnu::noinline]] void
            ReadWhile(Statement &statement)
            {
                ReadExpressionInto(statement.expression);
                auto body = ReadBody("while body statement count");
                BuildWhile(statement, body);
            }
            [[gnu::noinline]] void
            ReadDoWhile(Statement &statement)
            {
                auto body = ReadBody("do/while body statement count");
                ReadExpressionInto(statement.expression);
                BuildDoWhile(statement, body);
            }
            [[gnu::noinline]] void
            ReadFor(Statement &statement)
            {
                ReadExpressionInto(statement.expression);
                auto body = ReadBody("for body statement count");
                auto update = ReadBody("for update statement count");
                BuildFor(statement, body, update);
            }
            [[gnu::noinline]] static void
            BuildWhile(Statement &statement, std::vector<Statement> &body)
            {
                statement = Statement::While(std::move(statement.expression),
                                             std::move(body));
            }
            [[gnu::noinline]] static void
            BuildDoWhile(Statement &statement, std::vector<Statement> &body)
            {
                statement = Statement::DoWhile(std::move(body),
                                               std::move(statement.expression));
            }
            [[gnu::noinline]] static void
            BuildFor(Statement &statement,
                     std::vector<Statement> &body,
                     std::vector<Statement> &update)
            {
                statement = Statement::For(std::move(statement.expression),
                                           std::move(body),
                                           std::move(update));
            }
            [[nodiscard, gnu::noinline]] auto
            ReadParameter() -> Parameter
            {
                return Parameter{ Symbol("parameter symbol"), ReadType() };
            }
            [[nodiscard]] auto
            ReadFunction() -> Function
            {
                Function function;
                function.symbol = Symbol("function symbol");
                function.sourceFile = Text("function source file");
                function.parameters
                    = Vector<Parameter>(limits_.maximumParameters,
                                        "parameter count",
                                        [this] {
                                            return ReadParameter();
                                        });
                function.returnType = ReadType();
                function.body = ReadBody("statement count");
                return function;
            }
        };
    } // namespace

    auto
    Decode(std::span<const std::uint8_t> bytes, const Limits &limits)
        -> DecodeResult
    {
        return Reader(bytes, limits).Document();
    }
} // namespace Progmasoft::Tala::Core::Wire
