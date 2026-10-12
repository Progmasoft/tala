// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <limits>
#include <string_view>
#include <type_traits>

#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"

namespace tala::core::wire
{
    namespace
    {
        class Writer final
        {
        public:
            explicit Writer(const Limits &limits)
                : limits_(limits)
            {}

            [[nodiscard]] auto
            finish() && -> EncodeResult
            {
                if (!error_ && bytes_.size() > limits_.maximum_wire_bytes)
                    fail(ErrorKind::LimitExceeded,
                         "wire byte length",
                         "encoded document exceeds configured byte limit");
                return EncodeResult{ std::move(bytes_), std::move(error_) };
            }

            void
            document(const CorePrepModule &module)
            {
                for (const auto value : magic)
                    byte(value);
                unsigned_integer(current_version);
                unsigned_integer<std::uint16_t>(0);
                qualified_name(module.name, "module name");
                vector(module.sourceFiles,
                       limits_.maximum_functions,
                       "source file count",
                       [this](const std::u32string &sourceFile) {
                           text(sourceFile, "source file");
                       });
                vector(module.functions,
                       limits_.maximum_functions,
                       "function count",
                       [this](const Function &function) {
                           this->function(function);
                       });
            }

        private:
            const Limits &limits_;
            std::vector<std::uint8_t> bytes_;
            std::optional<Error> error_;

            void
            fail(ErrorKind kind, std::string context, std::string message)
            {
                if (!error_)
                    error_ = Error{ kind,
                                    bytes_.size(),
                                    std::move(context),
                                    std::move(message) };
            }

            void
            byte(std::uint8_t value)
            {
                if (!error_)
                    bytes_.push_back(value);
            }

            template<typename Integer>
            void
            unsigned_integer(Integer value)
            {
                static_assert(std::is_unsigned_v<Integer>);
                for (std::size_t shift = 0; shift < sizeof(Integer) * 8U;
                     shift += 8U)
                    byte(static_cast<std::uint8_t>(
                        (value >> shift) & static_cast<Integer>(0xffU)));
            }

            void
            count(std::size_t value,
                  std::size_t maximum,
                  std::string_view context)
            {
                if (value > maximum
                    || value > std::numeric_limits<std::uint32_t>::max())
                {
                    fail(ErrorKind::LimitExceeded,
                         std::string(context),
                         "collection count exceeds wire limit");
                    return;
                }
                unsigned_integer(static_cast<std::uint32_t>(value));
            }

            template<typename Value, typename Encode>
            void
            vector(const std::vector<Value> &values,
                   std::size_t maximum,
                   std::string_view context,
                   Encode encode)
            {
                count(values.size(), maximum, context);
                if (error_)
                    return;
                for (const auto &value : values)
                {
                    encode(value);
                    if (error_)
                        return;
                }
            }

            void
            text(const std::u32string &value, std::string_view context)
            {
                count(value.size(),
                      limits_.maximum_string_code_points,
                      context);
                for (const auto code_point : value)
                {
                    const auto numeric = static_cast<std::uint32_t>(code_point);
                    if (numeric > 0x10ffffU
                        || (numeric >= 0xd800U && numeric <= 0xdfffU))
                    {
                        fail(ErrorKind::InvalidCodePoint,
                             std::string(context),
                             "text contains a non-scalar Unicode code point");
                        return;
                    }
                    unsigned_integer(numeric);
                }
            }

            void
            qualified_name(const std::vector<std::u32string> &parts,
                           std::string_view context)
            {
                vector(parts,
                       65535U,
                       context,
                       [this, context](const std::u32string &part) {
                           text(part, context);
                       });
            }

            void
            symbol(const SymbolName &name, std::string_view context)
            {
                if (name.id == 0)
                {
                    fail(ErrorKind::InvalidSymbol,
                         std::string(context),
                         "symbol id must be positive");
                    return;
                }
                unsigned_integer(name.id);
                text(name.spelling, context);
            }

            void
            type(const Type &value, std::size_t depth = 0)
            {
                if (depth > limits_.maximum_type_depth)
                {
                    fail(ErrorKind::LimitExceeded,
                         "type",
                         "type nesting exceeds configured limit");
                    return;
                }
                const auto primitive_tag
                    = [](const Type::Kind kind) -> std::optional<std::uint8_t> {
                    using enum Type::Kind;
                    switch (kind)
                    {
                        case Unit:
                            return 0;
                        case Bool:
                            return 1;
                        case Int64:
                            return 2;
                        case Int32:
                            return 3;
                        case String:
                            return 4;
                        case Function:
                            return 5;
                        case Named:
                            return 6;
                        case TypeVariable:
                            return 7;
                        case Character:
                            return 8;
                        case Int8:
                            return 9;
                        case Int16:
                            return 10;
                        case Int128:
                            return 11;
                        case UInt8:
                            return 12;
                        case UInt16:
                            return 13;
                        case UInt32:
                            return 14;
                        case UInt64:
                            return 15;
                        case UInt128:
                            return 16;
                        case Float16:
                            return 17;
                        case Float32:
                            return 18;
                        case Float64:
                            return 19;
                        case Float128:
                            return 20;
                    }
                    return std::nullopt;
                }(value.kind);
                if (!primitive_tag)
                {
                    fail(ErrorKind::UnsupportedType,
                         "type",
                         "type has no CorePrep wire tag");
                    return;
                }
                byte(*primitive_tag);
                switch (value.kind)
                {
                    case Type::Kind::Unit:
                    case Type::Kind::Bool:
                    case Type::Kind::Character:
                    case Type::Kind::Int8:
                    case Type::Kind::Int16:
                    case Type::Kind::Int64:
                    case Type::Kind::Int32:
                    case Type::Kind::Int128:
                    case Type::Kind::UInt8:
                    case Type::Kind::UInt16:
                    case Type::Kind::UInt32:
                    case Type::Kind::UInt64:
                    case Type::Kind::UInt128:
                    case Type::Kind::Float16:
                    case Type::Kind::Float32:
                    case Type::Kind::Float64:
                    case Type::Kind::Float128:
                    case Type::Kind::String:
                        return;
                    case Type::Kind::Function:
                        if (value.components.empty())
                        {
                            fail(ErrorKind::UnsupportedType,
                                 "function type",
                                 "function type has no result component");
                            return;
                        }
                        count(value.components.size() - 1U,
                              65535U,
                              "function type parameter count");
                        for (std::size_t index = 0;
                             index + 1U < value.components.size();
                             ++index)
                            type(value.components[index], depth + 1U);
                        type(value.components.back(), depth + 1U);
                        return;
                    case Type::Kind::Named:
                        qualified_name(value.name, "named type");
                        vector(
                            value.templateArguments,
                            65535U,
                            "template argument count",
                            [this, depth](const TemplateArgument &argument) {
                                if (argument.kind
                                    == TemplateArgument::Kind::Type)
                                {
                                    byte(0);
                                    if (!argument.type)
                                    {
                                        fail(ErrorKind::UnsupportedType,
                                             "template argument",
                                             "type argument has no payload");
                                        return;
                                    }
                                    type(*argument.type, depth + 1U);
                                    return;
                                }
                                switch (argument.value.kind)
                                {
                                    case TemplateValue::Kind::Integer:
                                        byte(1);
                                        template_integer(argument.value.integer,
                                                         "template integer");
                                        return;
                                    case TemplateValue::Kind::Boolean:
                                        byte(2);
                                        byte(argument.value.boolean ? 1U : 0U);
                                        return;
                                    case TemplateValue::Kind::Character:
                                        byte(3);
                                        template_integer(argument.value.integer,
                                                         "template character");
                                        return;
                                    case TemplateValue::Kind::Parameter:
                                        byte(4);
                                        symbol(argument.value.parameter,
                                               "template value parameter");
                                        return;
                                }
                            });
                        return;
                    case Type::Kind::TypeVariable:
                        symbol(value.variable, "type variable symbol");
                        return;
                }
            }

            void
            template_integer(IntegerLiteral value, std::string_view context)
            {
                value = normalize_integer(std::move(value));
                if (!integer_is_canonical(value))
                {
                    fail(ErrorKind::InvalidInteger,
                         std::string(context),
                         "integer magnitude/sign is not canonical");
                    return;
                }
                byte(value.negative ? 1U : 0U);
                vector(value.magnitude,
                       limits_.maximum_numeric_bytes,
                       std::string(context) + " magnitude",
                       [this](const auto octet) {
                           byte(octet);
                       });
            }

            void
            literal(const Atom &value)
            {
                const auto write_integer
                    = [this, &value](IntegerLiteral integer) {
                          integer = normalize_integer(std::move(integer));
                          if (const auto issue
                              = validate_literal(integer, value.type))
                          {
                              fail(ErrorKind::InvalidInteger,
                                   "integer literal",
                                   *issue);
                              return;
                          }
                          byte(integer.negative ? 1U : 0U);
                          vector(integer.magnitude,
                                 limits_.maximum_numeric_bytes,
                                 "integer magnitude",
                                 [this](const std::uint8_t octet) {
                                     byte(octet);
                                 });
                      };
                switch (value.type.kind)
                {
                    case Type::Kind::Unit:
                        if (!std::holds_alternative<std::monostate>(
                                value.literal))
                            fail(ErrorKind::UnsupportedType,
                                 "unit literal",
                                 "literal payload does not match unit type");
                        byte(0U);
                        return;
                    case Type::Kind::Bool:
                        if (const auto *boolean
                            = std::get_if<bool>(&value.literal))
                        {
                            byte(1U);
                            byte(*boolean ? 1U : 0U);
                        }
                        else
                            fail(ErrorKind::UnsupportedType,
                                 "bool literal",
                                 "literal payload does not match bool type");
                        return;
                    case Type::Kind::Character:
                    case Type::Kind::Int8:
                    case Type::Kind::Int16:
                    case Type::Kind::Int32:
                    case Type::Kind::Int64:
                    case Type::Kind::Int128:
                    case Type::Kind::UInt8:
                    case Type::Kind::UInt16:
                    case Type::Kind::UInt32:
                    case Type::Kind::UInt64:
                    case Type::Kind::UInt128:
                        byte(2U);
                        if (const auto *integer
                            = std::get_if<IntegerLiteral>(&value.literal))
                            write_integer(*integer);
                        else if (const auto *integer64
                                 = std::get_if<std::int64_t>(&value.literal))
                            write_integer(integer_from_signed(*integer64));
                        else if (const auto *integer32
                                 = std::get_if<std::int32_t>(&value.literal))
                            write_integer(integer_from_signed(*integer32));
                        else
                            fail(ErrorKind::UnsupportedType,
                                 "integer literal",
                                 "literal payload does not match integer type");
                        return;
                    case Type::Kind::Float16:
                    case Type::Kind::Float32:
                    case Type::Kind::Float64:
                    case Type::Kind::Float128:
                        byte(4U);
                        if (const auto *floating
                            = std::get_if<FloatingLiteral>(&value.literal))
                        {
                            if (const auto issue
                                = validate_literal(*floating, value.type))
                            {
                                fail(ErrorKind::InvalidInteger,
                                     "floating literal",
                                     *issue);
                                return;
                            }
                            count(floating->spelling.size(),
                                  limits_.maximum_numeric_bytes,
                                  "floating literal length");
                            for (const auto character : floating->spelling)
                                byte(static_cast<std::uint8_t>(character));
                        }
                        else
                            fail(
                                ErrorKind::UnsupportedType,
                                "floating literal",
                                "literal payload does not match floating type");
                        return;
                    case Type::Kind::String:
                        if (const auto *string
                            = std::get_if<std::u32string>(&value.literal))
                        {
                            byte(3U);
                            text(*string, "string literal");
                        }
                        else if (std::holds_alternative<std::monostate>(
                                     value.literal))
                            byte(5U);
                        else
                            fail(ErrorKind::UnsupportedType,
                                 "string literal",
                                 "literal payload does not match string type");
                        return;
                    case Type::Kind::Function:
                    case Type::Kind::Named:
                        if (std::holds_alternative<std::monostate>(
                                value.literal))
                            byte(5U);
                        else
                            fail(ErrorKind::UnsupportedType,
                                 "literal",
                                 "reference literal must be null");
                        return;
                    case Type::Kind::TypeVariable:
                        fail(ErrorKind::UnsupportedType,
                             "literal",
                             "non-primitive literal types cannot cross "
                             "CorePrep wire");
                        return;
                }
            }

            void
            atom(const Atom &value)
            {
                byte(static_cast<std::uint8_t>(value.kind));
                type(value.type);
                if (value.kind == Atom::Kind::Variable)
                    symbol(value.symbol, "variable symbol");
                else
                    literal(value);
            }

            void
            capture(const Capture &value)
            {
                byte(static_cast<std::uint8_t>(value.mode));
                symbol(value.symbol, "capture symbol");
                type(value.type);
                atom(value.value);
            }

            void
            operation(Operation operation, const std::vector<Atom> &operands)
            {
                byte(static_cast<std::uint8_t>(operation));
                vector(operands,
                       limits_.maximum_operands_per_instruction,
                       "operand count",
                       [this](const Atom &operand) {
                           atom(operand);
                       });
            }

            void
            operation(const Instruction &instruction)
            {
                byte(static_cast<std::uint8_t>(instruction.operation));
                if (instruction.operation == Operation::MakeClosure)
                {
                    symbol(instruction.closure_function,
                           "closure function symbol");
                    vector(instruction.captures,
                           limits_.maximum_operands_per_instruction,
                           "closure capture count",
                           [this](const Capture &value) {
                               capture(value);
                           });
                    return;
                }
                vector(instruction.operands,
                       limits_.maximum_operands_per_instruction,
                       "operand count",
                       [this](const Atom &operand) {
                           atom(operand);
                       });
            }

            void
            instruction(const Instruction &value)
            {
                byte(static_cast<std::uint8_t>(value.kind));
                switch (value.kind)
                {
                    case Instruction::Kind::Bind:
                        symbol(value.destination, "binding symbol");
                        type(value.type);
                        byte(value.mutable_binding ? 1U : 0U);
                        operation(value);
                        return;
                    case Instruction::Kind::Assign:
                        symbol(value.destination, "assignment symbol");
                        if (value.operands.size() != 1U)
                        {
                            fail(ErrorKind::InvalidCount,
                                 "assignment",
                                 "assignment must contain exactly one atom");
                            return;
                        }
                        atom(value.operands.front());
                        return;
                    case Instruction::Kind::Evaluate:
                        operation(value);
                        return;
                }
            }

            void
            terminator(const Terminator &value)
            {
                byte(static_cast<std::uint8_t>(value.kind));
                switch (value.kind)
                {
                    case Terminator::Kind::Return:
                        atom(value.value);
                        return;
                    case Terminator::Kind::Branch:
                        atom(value.value);
                        unsigned_integer(value.true_target);
                        unsigned_integer(value.false_target);
                        return;
                    case Terminator::Kind::Jump:
                        unsigned_integer(value.true_target);
                        return;
                    case Terminator::Kind::Unreachable:
                        return;
                }
            }

            void
            block(const Block &value)
            {
                unsigned_integer(value.id);
                vector(value.instructions,
                       limits_.maximum_instructions_per_block,
                       "instruction count",
                       [this](const Instruction &item) {
                           instruction(item);
                       });
                terminator(value.terminator);
            }

            void
            parameter(const Parameter &value)
            {
                symbol(value.symbol, "parameter symbol");
                type(value.type);
            }

            void
            function(const Function &value)
            {
                symbol(value.symbol, "function symbol");
                text(value.sourceFile, "function source file");
                vector(value.parameters,
                       limits_.maximum_parameters_per_function,
                       "parameter count",
                       [this](const Parameter &item) {
                           parameter(item);
                       });
                type(value.return_type);
                unsigned_integer(value.entry);
                vector(value.blocks,
                       limits_.maximum_blocks_per_function,
                       "block count",
                       [this](const Block &item) {
                           block(item);
                       });
            }
        };
    } // namespace

    auto
    encode(const CorePrepModule &module, const Limits &limits) -> EncodeResult
    {
        Writer writer(limits);
        writer.document(module);
        return std::move(writer).finish();
    }
} // namespace tala::core::wire
