// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

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
        class Writer final
        {
        public:
            explicit Writer(const Limits &limits)
                : limits_(limits)
            {}
            void
            Document(const Module &module)
            {
                for (const auto value : kMagic)
                    Byte(value);
                Unsigned(kCurrentVersion);
                Unsigned<std::uint16_t>(0U);
                QualifiedName(module.name, "module name");
                Vector(module.sourceFiles,
                       limits_.maximumFunctions,
                       "source file count",
                       [this](const std::u32string &sourceFile) {
                           Text(sourceFile, "source file");
                       });
                Vector(module.functions,
                       limits_.maximumFunctions,
                       "function count",
                       [this](const Function &function) {
                           WriteFunction(function);
                       });
            }
            [[nodiscard]] auto
            Finish() && -> EncodeResult
            {
                if (!error_ && bytes_.size() > limits_.maximumWireBytes)
                    Fail(ErrorKind::LimitExceeded,
                         "wire byte length",
                         "encoded document exceeds configured limit");
                return EncodeResult{ std::move(bytes_), std::move(error_) };
            }

        private:
            const Limits &limits_;
            std::vector<std::uint8_t> bytes_;
            std::size_t statementDepth_{};
            std::optional<Error> error_;

            void
            Fail(ErrorKind kind, std::string context, std::string message)
            {
                if (!error_)
                    error_ = Error{ kind,
                                    bytes_.size(),
                                    std::move(context),
                                    std::move(message) };
            }
            void
            Byte(std::uint8_t value)
            {
                if (!error_)
                    bytes_.push_back(value);
            }
            template<typename Integer>
            void
            Unsigned(Integer value)
            {
                static_assert(std::is_unsigned_v<Integer>);
                for (std::size_t shift = 0; shift < sizeof(Integer) * 8U;
                     shift += 8U)
                    Byte(static_cast<std::uint8_t>(
                        (value >> shift) & static_cast<Integer>(0xffU)));
            }
            void
            Count(std::size_t value,
                  std::size_t maximum,
                  std::string_view context)
            {
                if (value > maximum
                    || value > std::numeric_limits<std::uint32_t>::max())
                    Fail(ErrorKind::LimitExceeded,
                         std::string(context),
                         "collection count exceeds wire limit");
                else
                    Unsigned(static_cast<std::uint32_t>(value));
            }
            template<typename Value, typename Encode>
            void
            Vector(const std::vector<Value> &values,
                   std::size_t maximum,
                   std::string_view context,
                   Encode encode)
            {
                Count(values.size(), maximum, context);
                for (const auto &value : values)
                {
                    if (error_)
                        return;
                    encode(value);
                }
            }
            void
            Text(const std::u32string &value, std::string_view context)
            {
                Count(value.size(), limits_.maximumTextScalars, context);
                for (const auto scalar : value)
                {
                    const auto numeric = static_cast<std::uint32_t>(scalar);
                    if (numeric > 0x10ffffU
                        || (numeric >= 0xd800U && numeric <= 0xdfffU))
                    {
                        Fail(ErrorKind::InvalidScalar,
                             std::string(context),
                             "text contains a non-scalar Unicode value");
                        return;
                    }
                    Unsigned(numeric);
                }
            }
            void
            QualifiedName(const std::vector<std::u32string> &parts,
                          std::string_view context)
            {
                Vector(parts,
                       65535U,
                       context,
                       [this, context](const auto &part) {
                           Text(part, context);
                       });
            }
            void
            Symbol(const SymbolName &symbol, std::string_view context)
            {
                if (symbol.id == 0U)
                {
                    Fail(ErrorKind::InvalidSymbol,
                         std::string(context),
                         "symbol id must be positive");
                    return;
                }
                Unsigned(symbol.id);
                Text(symbol.spelling, context);
            }
            void
            WriteType(const Type &type, std::size_t depth = 0U)
            {
                if (depth > limits_.maximumTypeDepth)
                {
                    Fail(ErrorKind::LimitExceeded,
                         "type",
                         "type nesting exceeds configured limit");
                    return;
                }
                switch (type.kind)
                {
                    case Type::Kind::Unit:
                        Byte(0);
                        return;
                    case Type::Kind::Bool:
                        Byte(1);
                        return;
                    case Type::Kind::Int64:
                        Byte(2);
                        return;
                    case Type::Kind::String:
                        Byte(3);
                        return;
                    case Type::Kind::Named:
                        Byte(4);
                        QualifiedName(type.name, "named type");
                        Vector(type.templateArguments,
                               limits_.maximumOperands,
                               "template argument count",
                               [this, depth](const auto &argument) {
                                   if (argument.kind
                                       == ::tala::core::TemplateArgument::Kind::
                                           Type)
                                   {
                                       Byte(0);
                                       if (!argument.type)
                                       {
                                           Fail(ErrorKind::UnsupportedType,
                                                "template argument",
                                                "type argument has no payload");
                                           return;
                                       }
                                       WriteType(*argument.type, depth + 1U);
                                       return;
                                   }
                                   switch (argument.value.kind)
                                   {
                                       case ::tala::core::TemplateValue::Kind::
                                           Integer:
                                           Byte(1);
                                           WriteInteger(argument.value.integer,
                                                        "template integer");
                                           return;
                                       case ::tala::core::TemplateValue::Kind::
                                           Boolean:
                                           Byte(2);
                                           Byte(argument.value.boolean ? 1U
                                                                       : 0U);
                                           return;
                                       case ::tala::core::TemplateValue::Kind::
                                           Character:
                                           Byte(3);
                                           WriteInteger(argument.value.integer,
                                                        "template character");
                                           return;
                                       case ::tala::core::TemplateValue::Kind::
                                           Parameter:
                                           Byte(4);
                                           Symbol(argument.value.parameter,
                                                  "template value parameter");
                                           return;
                                   }
                               });
                        return;
                    case Type::Kind::Function:
                        Byte(5);
                        if (type.components.empty())
                        {
                            Fail(ErrorKind::UnsupportedType,
                                 "function type",
                                 "function type has no result component");
                            return;
                        }
                        Count(type.components.size() - 1U,
                              limits_.maximumParameters,
                              "function type parameter count");
                        for (std::size_t index = 0;
                             index + 1U < type.components.size();
                             ++index)
                            WriteType(type.components[index], depth + 1U);
                        WriteType(type.components.back(), depth + 1U);
                        return;
                    case Type::Kind::TypeVariable:
                        Byte(6);
                        Symbol(type.variable, "type variable symbol");
                        return;
                    case Type::Kind::Character:
                        Byte(7);
                        return;
                    case Type::Kind::Int8:
                        Byte(8);
                        return;
                    case Type::Kind::Int16:
                        Byte(9);
                        return;
                    case Type::Kind::Int32:
                        Byte(10);
                        return;
                    case Type::Kind::Int128:
                        Byte(11);
                        return;
                    case Type::Kind::UInt8:
                        Byte(12);
                        return;
                    case Type::Kind::UInt16:
                        Byte(13);
                        return;
                    case Type::Kind::UInt32:
                        Byte(14);
                        return;
                    case Type::Kind::UInt64:
                        Byte(15);
                        return;
                    case Type::Kind::UInt128:
                        Byte(16);
                        return;
                    case Type::Kind::Float16:
                        Byte(17);
                        return;
                    case Type::Kind::Float32:
                        Byte(18);
                        return;
                    case Type::Kind::Float64:
                        Byte(19);
                        return;
                    case Type::Kind::Float128:
                        Byte(20);
                        return;
                }
            }
            void
            WriteInteger(const ::tala::core::IntegerLiteral &integer,
                         std::string_view context)
            {
                if (!::tala::core::integer_is_canonical(integer))
                {
                    Fail(ErrorKind::InvalidInteger,
                         std::string(context),
                         "integer magnitude/sign is not canonical");
                    return;
                }
                Byte(integer.negative ? 1U : 0U);
                Vector(integer.magnitude,
                       limits_.maximumNumericBytes,
                       std::string(context) + " magnitude",
                       [this](const auto octet) {
                           Byte(octet);
                       });
            }
            void
            WriteLiteral(const Literal &literal, const Type &valueType)
            {
                if (std::holds_alternative<std::monostate>(literal))
                    Byte(valueType.kind == Type::Kind::Unit ? 0U : 6U);
                else if (const auto *boolean = std::get_if<bool>(&literal))
                {
                    Byte(1);
                    Byte(*boolean ? 1U : 0U);
                }
                else if (const auto *integer
                         = std::get_if<std::int64_t>(&literal))
                {
                    Byte(2);
                    Unsigned(static_cast<std::uint64_t>(*integer));
                }
                else if (const auto *string
                         = std::get_if<std::u32string>(&literal))
                {
                    Byte(3);
                    Text(*string, "string literal");
                }
                else if (const auto *wideInteger
                         = std::get_if<::tala::core::IntegerLiteral>(&literal))
                {
                    if (!::tala::core::integer_is_canonical(*wideInteger))
                    {
                        Fail(ErrorKind::InvalidInteger,
                             "integer literal",
                             "integer magnitude/sign is not canonical");
                        return;
                    }
                    Byte(4);
                    Byte(wideInteger->negative ? 1U : 0U);
                    Vector(wideInteger->magnitude,
                           limits_.maximumNumericBytes,
                           "integer magnitude",
                           [this](const std::uint8_t octet) {
                               Byte(octet);
                           });
                }
                else if (const auto *floating
                         = std::get_if<::tala::core::FloatingLiteral>(&literal))
                {
                    if (!::tala::core::floating_spelling_is_valid(
                            floating->spelling))
                    {
                        Fail(ErrorKind::InvalidInteger,
                             "floating literal",
                             "floating spelling is not canonical");
                        return;
                    }
                    Byte(5);
                    Count(floating->spelling.size(),
                          limits_.maximumNumericBytes,
                          "floating literal length");
                    for (const auto character : floating->spelling)
                        Byte(static_cast<std::uint8_t>(character));
                }
                else if (const auto *narrowInteger
                         = std::get_if<std::int32_t>(&literal))
                {
                    Byte(4);
                    const auto normalized
                        = ::tala::core::integer_from_signed(*narrowInteger);
                    Byte(normalized.negative ? 1U : 0U);
                    Vector(normalized.magnitude,
                           limits_.maximumNumericBytes,
                           "integer magnitude",
                           [this](const std::uint8_t octet) {
                               Byte(octet);
                           });
                }
                else
                    Fail(ErrorKind::UnsupportedType,
                         "literal",
                         "literal cannot cross the Core v5 boundary");
            }
            /**
             * @brief Write one expression.
             *
             * A chain of operators nests in the first operand of each
             * primitive, as deep as the chain is long. The headers of those
             * primitives are written in a loop, then the innermost first
             * operand, then the remaining operands of each primitive from
             * the innermost outwards, which is the order of the nested
             * formulation. The first operand of a primitive is at the depth
             * of the primitive, so a chain does not count against the
             * expression depth limit; every other child is one level deeper.
             */
            void
            WriteExpression(const Expression &root, std::size_t depth = 0U)
            {
                std::vector<const Expression *> chain;
                const Expression *current = &root;
                while (!error_ && current->kind == Expression::Kind::Primitive
                       && !current->operands.empty())
                {
                    if (depth > limits_.maximumExpressionDepth)
                        break;
                    Byte(static_cast<std::uint8_t>(current->kind));
                    Byte(static_cast<std::uint8_t>(current->primitive));
                    WriteType(current->type);
                    Count(current->operands.size(),
                          limits_.maximumOperands,
                          "primitive operand count");
                    chain.push_back(current);
                    current = &current->operands.front();
                }
                WriteUnchained(*current, depth);
                while (!chain.empty() && !error_)
                {
                    const auto &operands = chain.back()->operands;
                    for (std::size_t index = 1U;
                         index < operands.size() && !error_;
                         ++index)
                        WriteExpression(operands[index], depth + 1U);
                    chain.pop_back();
                }
            }
            /// An expression that is not a primitive with operands.
            void
            WriteUnchained(const Expression &expression, std::size_t depth)
            {
                if (depth > limits_.maximumExpressionDepth)
                {
                    Fail(ErrorKind::LimitExceeded,
                         "expression",
                         "expression nesting exceeds configured limit");
                    return;
                }
                Byte(static_cast<std::uint8_t>(expression.kind));
                if (expression.kind == Expression::Kind::Primitive)
                    Byte(static_cast<std::uint8_t>(expression.primitive));
                WriteType(expression.type);
                switch (expression.kind)
                {
                    case Expression::Kind::Variable:
                        Symbol(expression.symbol, "variable symbol");
                        return;
                    case Expression::Kind::Literal:
                        WriteLiteral(expression.literal, expression.type);
                        return;
                    case Expression::Kind::Apply:
                        if (!expression.callee)
                        {
                            Fail(ErrorKind::InvalidCount,
                                 "callee",
                                 "Core call must contain a callee");
                            return;
                        }
                        WriteExpression(*expression.callee, depth + 1U);
                        Vector(expression.operands,
                               limits_.maximumOperands,
                               "call argument count",
                               [this, depth](const Expression &value) {
                                   WriteExpression(value, depth + 1U);
                               });
                        return;
                    case Expression::Kind::Primitive:
                        Vector(expression.operands,
                               limits_.maximumOperands,
                               "primitive operand count",
                               [this, depth](const Expression &value) {
                                   WriteExpression(value, depth + 1U);
                               });
                        return;
                    case Expression::Kind::Closure:
                        Vector(
                            expression.captures,
                            limits_.maximumOperands,
                            "closure capture count",
                            [this, depth](const Capture &capture) {
                                if (capture.mode != CaptureMode::Strong
                                    && capture.mode != CaptureMode::Weak
                                    && capture.mode != CaptureMode::Unowned)
                                {
                                    Fail(ErrorKind::InvalidTag,
                                         "closure capture mode",
                                         "unknown Core closure capture mode");
                                    return;
                                }
                                Byte(static_cast<std::uint8_t>(capture.mode));
                                Symbol(capture.symbol,
                                       "closure capture symbol");
                                WriteType(capture.type);
                                if (!capture.value)
                                {
                                    Fail(ErrorKind::InvalidCount,
                                         "closure capture value",
                                         "Core closure capture must contain a "
                                         "value");
                                    return;
                                }
                                WriteExpression(*capture.value, depth + 1U);
                            });
                        Vector(expression.closureParameters,
                               limits_.maximumParameters,
                               "closure parameter count",
                               [this](const auto &parameter) {
                                   Symbol(parameter.first, "parameter symbol");
                                   WriteType(parameter.second);
                               });
                        WriteType(expression.closureReturnType);
                        if (!expression.closureBody)
                        {
                            Fail(ErrorKind::InvalidCount,
                                 "closure body",
                                 "Core closure must contain a body");
                            return;
                        }
                        WriteBody(*expression.closureBody,
                                  "closure statement count");
                        return;
                    case Expression::Kind::Let:
                        Symbol(expression.letSymbol, "let symbol");
                        WriteType(expression.letType);
                        if (!expression.letValue || !expression.letBody)
                        {
                            Fail(ErrorKind::InvalidCount,
                                 "let expression",
                                 "Core let must contain a value and body");
                            return;
                        }
                        WriteExpression(*expression.letValue, depth + 1U);
                        WriteExpression(*expression.letBody, depth + 1U);
                        return;
                    case Expression::Kind::Conditional:
                        if (expression.operands.size() != 3U)
                        {
                            Fail(ErrorKind::InvalidCount,
                                 "conditional expression",
                                 "Core conditional must contain a test and "
                                 "two arms");
                            return;
                        }
                        for (const auto &operand : expression.operands)
                            WriteExpression(operand, depth + 1U);
                        return;
                }
            }
            /**
             * @brief Write the statements of a body, one nesting level below
             * the current one, with the limit the reader enforces. A module
             * the reader would reject is not written.
             */
            void
            WriteBody(const std::vector<Statement> &statements,
                      std::string_view context)
            {
                if (statements.empty())
                {
                    Count(0U, limits_.maximumStatements, context);
                    return;
                }
                if (statementDepth_ >= limits_.maximumStatementDepth)
                {
                    Fail(ErrorKind::LimitExceeded,
                         std::string(context),
                         "statement nesting exceeds wire limit");
                    return;
                }
                ++statementDepth_;
                Vector(statements,
                       limits_.maximumStatements,
                       context,
                       [this](const Statement &value) {
                           WriteStatement(value);
                       });
                --statementDepth_;
            }
            void
            WriteStatement(const Statement &statement)
            {
                Byte(static_cast<std::uint8_t>(statement.kind));
                switch (statement.kind)
                {
                    case Statement::Kind::Bind:
                        Symbol(statement.binding.symbol, "binding symbol");
                        WriteType(statement.binding.type);
                        Byte(statement.binding.mutableBinding ? 1U : 0U);
                        WriteExpression(statement.binding.value);
                        return;
                    case Statement::Kind::Assign:
                        Symbol(statement.destination, "assignment symbol");
                        WriteExpression(statement.expression);
                        return;
                    case Statement::Kind::Return:
                        WriteExpression(statement.expression);
                        return;
                    case Statement::Kind::If:
                    {
                        // An `else if` chain is written in a loop for the
                        // reason ReadConditionalChain reads it in one: a
                        // false branch of exactly one conditional is the
                        // next link, and its bytes are its count, its tag
                        // and then the link itself.
                        const Statement *link = &statement;
                        while (!error_)
                        {
                            WriteExpression(link->expression);
                            WriteBody(link->trueBranch,
                                      "true branch statement count");
                            const auto continues
                                = link->falseBranch.size() == 1U
                                  && link->falseBranch.front().kind
                                         == Statement::Kind::If;
                            if (!continues)
                            {
                                WriteBody(link->falseBranch,
                                          "false branch statement count");
                                break;
                            }
                            Count(1U,
                                  limits_.maximumStatements,
                                  "false branch statement count");
                            link = &link->falseBranch.front();
                            Byte(static_cast<std::uint8_t>(link->kind));
                        }
                        return;
                    }
                    case Statement::Kind::Evaluate:
                        WriteExpression(statement.expression);
                        return;
                    case Statement::Kind::While:
                        WriteExpression(statement.expression);
                        WriteBody(statement.loopBody,
                                  "while body statement count");
                        return;
                    case Statement::Kind::DoWhile:
                        WriteBody(statement.loopBody,
                                  "do/while body statement count");
                        WriteExpression(statement.expression);
                        return;
                    case Statement::Kind::For:
                        WriteExpression(statement.expression);
                        WriteBody(statement.loopBody,
                                  "for body statement count");
                        WriteBody(statement.loopUpdate,
                                  "for update statement count");
                        return;
                    case Statement::Kind::Break:
                    case Statement::Kind::Continue:
                        return;
                }
            }
            void
            WriteFunction(const Function &function)
            {
                Symbol(function.symbol, "function symbol");
                Text(function.sourceFile, "function source file");
                Vector(function.parameters,
                       limits_.maximumParameters,
                       "parameter count",
                       [this](const Parameter &parameter) {
                           Symbol(parameter.symbol, "parameter symbol");
                           WriteType(parameter.type);
                       });
                WriteType(function.returnType);
                WriteBody(function.body, "statement count");
            }
        };
    } // namespace

    auto
    Encode(const Module &module, const Limits &limits) -> EncodeResult
    {
        Writer writer(limits);
        writer.Document(module);
        return std::move(writer).Finish();
    }
} // namespace Progmasoft::Tala::Core::Wire
