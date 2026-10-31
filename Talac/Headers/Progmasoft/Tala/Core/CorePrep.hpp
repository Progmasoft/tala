// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "Progmasoft/Tala/Namespace.hpp"

namespace tala::core
{
    /// Stable identifier assigned to a declaration by name resolution.
    using SymbolId = std::uint64_t;
    /// Function-local identifier used to connect basic blocks.
    using BlockId = std::uint32_t;

    /// Pairs a stable symbol identifier with its readable source spelling.
    struct SymbolName final
    {
        /// Identity used for semantic comparisons; spelling is not identity.
        SymbolId id{};
        /// Unicode code points used when formatting diagnostics and dumps.
        std::u32string spelling;
        /// Compare both identity and spelling for deterministic IR equality.
        /// @return true when both fields match.
        [[nodiscard]] auto
        operator==(const SymbolName &) const -> bool = default;
    };

    /// Canonical sign/magnitude representation of an arbitrary-width integer.
    ///
    /// Magnitude is stored as little-endian bytes and is independent of host
    /// integer width, so specialization keys remain portable across targets.
    struct IntegerLiteral final
    {
        /// Whether the represented mathematical value is negative.
        bool negative{};
        /// Unsigned magnitude in little-endian byte order; zero is empty or
        /// zeroed.
        std::vector<std::uint8_t> magnitude;
        /// Compare the canonical sign and magnitude representation.
        /// @return true when sign and magnitude match.
        [[nodiscard]] auto
        operator==(const IntegerLiteral &) const -> bool = default;
    };

    /// A compile-time value carried by a template argument.
    struct TemplateValue final
    {
        /// Discriminant selecting which payload field is meaningful.
        enum class Kind : std::uint8_t
        {
            Integer,   ///< Arbitrary-width integral value.
            Boolean,   ///< Boolean value.
            Character, ///< Unicode scalar value represented as an integer.
            Parameter  ///< Reference to a value parameter not yet substituted.
        };

        /// Active template-value category.
        Kind kind{ Kind::Integer };
        /// Payload used by Integer and Character values.
        IntegerLiteral integer;
        /// Payload used by Boolean values.
        bool boolean{};
        /// Payload used by Parameter values.
        SymbolName parameter;

        /// Construct an integer-valued template argument.
        /// @param value Canonical integer payload to retain.
        /// @return Template value tagged as Integer.
        [[nodiscard]] static auto
        integer_value(IntegerLiteral value) -> TemplateValue;
        /// Construct a Boolean-valued template argument.
        /// @param value Boolean payload.
        /// @return Template value tagged as Boolean.
        [[nodiscard]] static auto
        boolean_value(bool value) -> TemplateValue;
        /// Construct a character-valued template argument.
        /// @param value Unicode scalar encoded using the integer payload form.
        /// @return Template value tagged as Character.
        [[nodiscard]] static auto
        character_value(IntegerLiteral value) -> TemplateValue;
        /// Construct a reference to an unsubstituted value parameter.
        /// @param value Resolved parameter identity and spelling.
        /// @return Template value tagged as Parameter.
        [[nodiscard]] static auto
        parameter_value(SymbolName value) -> TemplateValue;
        /// Compare category and payload for specialization-key equality.
        /// @return true when the active category and its payload match.
        [[nodiscard]] auto
        operator==(const TemplateValue &) const -> bool = default;
    };

    /// Forward declaration required by the recursive template-argument model.
    struct Type;

    /// A type-valued or constant-valued argument in a generic type application.
    ///
    /// The immutable shared type payload breaks recursive layout while equality
    /// remains structural rather than dependent on pointer identity.
    struct TemplateArgument final
    {
        /// Selects the active type or constant payload.
        enum class Kind : std::uint8_t
        {
            Type, ///< A concrete or partially substituted type argument.
            Value ///< A compile-time constant argument.
        };

        /// Active template-argument category.
        Kind kind{ Kind::Type };
        /// Immutable type payload when kind is Type; null means no payload.
        std::shared_ptr<const Type> type;
        /// Constant payload when kind is Value.
        TemplateValue value;

        /// Create an immutable type argument.
        /// @param value Type whose value is copied into owned immutable
        /// storage.
        /// @return An argument tagged as Type with an owned immutable payload.
        [[nodiscard]] static auto
        type_argument(Type value) -> TemplateArgument;
        /// Create a compile-time constant argument.
        /// @param value Constant value to store.
        /// @return An argument tagged as Value.
        [[nodiscard]] static auto
        value_argument(TemplateValue value) -> TemplateArgument;
        /// Compare arguments by category and semantic payload.
        /// @param other Argument to compare with this value.
        /// @return true when both arguments represent the same template value.
        [[nodiscard]] auto
        operator==(const TemplateArgument &other) const -> bool;
    };

    /// Structural type representation shared by CorePrep and its wire verifier.
    struct Type final
    {
        /// Built-in, callable, nominal, or unresolved generic type category.
        enum class Kind : std::uint8_t
        {
            Unit,      ///< Unit result type used by procedures.
            Bool,      ///< Boolean scalar type.
            Character, ///< Unicode scalar character type.
            Int8,      ///< Signed 8-bit integer type.
            Int16,     ///< Signed 16-bit integer type.
            Int64,     ///< Signed 64-bit integer type.
            Int32,     ///< Signed 32-bit integer type.
            Int128,    ///< Signed 128-bit integer type.
            UInt8,     ///< Unsigned 8-bit integer type.
            UInt16,    ///< Unsigned 16-bit integer type.
            UInt32,    ///< Unsigned 32-bit integer type.
            UInt64,    ///< Unsigned 64-bit integer type.
            UInt128,   ///< Unsigned 128-bit integer type.
            Float16,   ///< 16-bit floating-point type.
            Float32,   ///< 32-bit floating-point type.
            Float64,   ///< 64-bit floating-point type.
            Float128,  ///< 128-bit floating-point type.
            String,    ///< Managed string type.
            Function,  ///< Function type with parameter components and result.
            Named, ///< Qualified nominal type with ordered generic arguments.
            TypeVariable ///< Unsubstituted type parameter.
        };
        /// Active type category.
        Kind kind{ Kind::Unit };
        /// Qualified name for Named types; empty for other categories.
        std::vector<std::u32string> name;
        /// Function parameters followed by the result; unused by other kinds.
        std::vector<Type> components;
        /// Ordered generic arguments for a Named type.
        std::vector<TemplateArgument> templateArguments;
        /// Identity of the parameter represented by a TypeVariable.
        SymbolName variable;

        /// Construct the procedure result type.
        /// @return A Type tagged as Unit.
        [[nodiscard]] static auto
        unit() -> Type
        {
            return Type{ Kind::Unit, {}, {}, {}, {} };
        }
        /// Construct the Boolean scalar type.
        /// @return A Type tagged as Bool.
        [[nodiscard]] static auto
        boolean() -> Type
        {
            return Type{ Kind::Bool, {}, {}, {}, {} };
        }
        /// Construct a signed 64-bit integer type.
        /// @return A Type tagged as Int64.
        [[nodiscard]] static auto
        int64() -> Type
        {
            return Type{ Kind::Int64, {}, {}, {}, {} };
        }
        /// Construct a signed 32-bit integer type.
        /// @return A Type tagged as Int32.
        [[nodiscard]] static auto
        int32() -> Type
        {
            return Type{ Kind::Int32, {}, {}, {}, {} };
        }
        /// Construct the Unicode scalar character type.
        /// @return A Type tagged as Character.
        [[nodiscard]] static auto
        character() -> Type
        {
            return Type{ Kind::Character, {}, {}, {}, {} };
        }
        /// Construct a signed 8-bit integer type.
        /// @return A Type tagged as Int8.
        [[nodiscard]] static auto
        int8() -> Type
        {
            return Type{ Kind::Int8, {}, {}, {}, {} };
        }
        /// Construct a signed 16-bit integer type.
        /// @return A Type tagged as Int16.
        [[nodiscard]] static auto
        int16() -> Type
        {
            return Type{ Kind::Int16, {}, {}, {}, {} };
        }
        /// Construct a signed 128-bit integer type.
        /// @return A Type tagged as Int128.
        [[nodiscard]] static auto
        int128() -> Type
        {
            return Type{ Kind::Int128, {}, {}, {}, {} };
        }
        /// Construct an unsigned 8-bit integer type.
        /// @return A Type tagged as UInt8.
        [[nodiscard]] static auto
        uint8() -> Type
        {
            return Type{ Kind::UInt8, {}, {}, {}, {} };
        }
        /// Construct an unsigned 16-bit integer type.
        /// @return A Type tagged as UInt16.
        [[nodiscard]] static auto
        uint16() -> Type
        {
            return Type{ Kind::UInt16, {}, {}, {}, {} };
        }
        /// Construct an unsigned 32-bit integer type.
        /// @return A Type tagged as UInt32.
        [[nodiscard]] static auto
        uint32() -> Type
        {
            return Type{ Kind::UInt32, {}, {}, {}, {} };
        }
        /// Construct an unsigned 64-bit integer type.
        /// @return A Type tagged as UInt64.
        [[nodiscard]] static auto
        uint64() -> Type
        {
            return Type{ Kind::UInt64, {}, {}, {}, {} };
        }
        /// Construct an unsigned 128-bit integer type.
        /// @return A Type tagged as UInt128.
        [[nodiscard]] static auto
        uint128() -> Type
        {
            return Type{ Kind::UInt128, {}, {}, {}, {} };
        }
        /// Construct a 16-bit floating-point type.
        /// @return A Type tagged as Float16.
        [[nodiscard]] static auto
        float16() -> Type
        {
            return Type{ Kind::Float16, {}, {}, {}, {} };
        }
        /// Construct a 32-bit floating-point type.
        /// @return A Type tagged as Float32.
        [[nodiscard]] static auto
        float32() -> Type
        {
            return Type{ Kind::Float32, {}, {}, {}, {} };
        }
        /// Construct a 64-bit floating-point type.
        /// @return A Type tagged as Float64.
        [[nodiscard]] static auto
        float64() -> Type
        {
            return Type{ Kind::Float64, {}, {}, {}, {} };
        }
        /// Construct a 128-bit floating-point type.
        /// @return A Type tagged as Float128.
        [[nodiscard]] static auto
        float128() -> Type
        {
            return Type{ Kind::Float128, {}, {}, {}, {} };
        }
        /// Construct the managed string type.
        /// @return A Type tagged as String.
        [[nodiscard]] static auto
        string() -> Type
        {
            return Type{ Kind::String, {}, {}, {}, {} };
        }
        /// Construct a function type from its parameter types and result type.
        /// @param parameters Parameters in declaration order.
        /// @param result Function result type appended after the parameters.
        /// @return A Type whose components end with the result type.
        [[nodiscard]] static auto
        function(std::vector<Type> parameters, Type result) -> Type
        {
            parameters.push_back(std::move(result));
            return Type{ Kind::Function, {}, std::move(parameters), {}, {} };
        }
        /// Construct a nominal type whose generic arguments are all types.
        /// @param qualified_name Fully qualified nominal type name.
        /// @param arguments Type arguments in declaration order.
        /// @return A Type tagged as Named with converted type arguments.
        [[nodiscard]] static auto
        named(std::vector<std::u32string> qualified_name,
              std::vector<Type> arguments = {}) -> Type
        {
            std::vector<TemplateArgument> converted;
            converted.reserve(arguments.size());
            for (auto &argument : arguments)
                converted.push_back(
                    TemplateArgument::type_argument(std::move(argument)));
            return Type{ Kind::Named,
                         std::move(qualified_name),
                         {},
                         std::move(converted),
                         {} };
        }
        /// Construct a nominal type with mixed type and value arguments.
        /// @param qualified_name Fully qualified nominal type name.
        /// @param arguments Ordered type or compile-time value arguments.
        /// @return A Type tagged as Named with the supplied arguments.
        [[nodiscard]] static auto
        named_template(std::vector<std::u32string> qualified_name,
                       std::vector<TemplateArgument> arguments) -> Type
        {
            return Type{ Kind::Named,
                         std::move(qualified_name),
                         {},
                         std::move(arguments),
                         {} };
        }
        /// Construct an unresolved generic type variable.
        /// @param symbol Identity of the declared type parameter.
        /// @return A Type tagged as TypeVariable.
        [[nodiscard]] static auto
        type_variable(SymbolName symbol) -> Type
        {
            return Type{ Kind::TypeVariable, {}, {}, {}, std::move(symbol) };
        }
        /// Compare the full structural type, including generic arguments.
        /// @return true when every type component matches.
        [[nodiscard]] auto
        operator==(const Type &) const -> bool = default;
    };

    inline auto
    TemplateValue::integer_value(IntegerLiteral value) -> TemplateValue
    {
        return TemplateValue{ Kind::Integer, std::move(value), false, {} };
    }

    inline auto
    TemplateValue::boolean_value(const bool value) -> TemplateValue
    {
        return TemplateValue{ Kind::Boolean, {}, value, {} };
    }

    inline auto
    TemplateValue::character_value(IntegerLiteral value) -> TemplateValue
    {
        return TemplateValue{ Kind::Character, std::move(value), false, {} };
    }

    inline auto
    TemplateValue::parameter_value(SymbolName value) -> TemplateValue
    {
        return TemplateValue{ Kind::Parameter, {}, false, std::move(value) };
    }

    inline auto
    TemplateArgument::type_argument(Type value) -> TemplateArgument
    {
        TemplateArgument result;
        result.kind = Kind::Type;
        result.type = std::make_shared<const Type>(std::move(value));
        return result;
    }

    inline auto
    TemplateArgument::value_argument(TemplateValue value) -> TemplateArgument
    {
        TemplateArgument result;
        result.kind = Kind::Value;
        result.value = std::move(value);
        return result;
    }

    inline auto
    TemplateArgument::operator==(const TemplateArgument &other) const -> bool
    {
        if (kind != other.kind)
            return false;
        if (kind == Kind::Value)
            return value == other.value;
        if (!type || !other.type)
            return type == other.type;
        return *type == *other.type;
    }

    /// Decimal spelling retained until the backend applies the target float
    /// format.
    ///
    /// Wire verification accepts only the canonical numeric grammar, so the
    /// field is not an unrestricted textual representation.
    struct FloatingLiteral final
    {
        /// Canonical decimal spelling used for deterministic serialization.
        std::string spelling;
        /// Compare canonical spellings without target floating-point
        /// conversion.
        /// @return true when both decimal spellings are identical.
        [[nodiscard]] auto
        operator==(const FloatingLiteral &) const -> bool = default;
    };

    /// Literal payloads supported by the in-memory CorePrep representation.
    ///
    /// Fixed-width integer alternatives remain for native v2 source
    /// compatibility; new wire decoders normalize integers to IntegerLiteral.
    using Literal = std::variant<std::monostate,
                                 bool,
                                 std::int64_t,
                                 std::int32_t,
                                 IntegerLiteral,
                                 FloatingLiteral,
                                 std::u32string>;

    /// A typed variable reference or literal operand in an instruction.
    struct Atom final
    {
        /// Distinguishes symbol references from literal payloads.
        enum class Kind : std::uint8_t
        {
            /// Reads the binding identified by symbol.
            Variable,
            /// Reads the constant stored in literal.
            Literal /**< Reads the constant stored in literal. */
        };
        /// Active operand category.
        Kind kind{ Kind::Literal };
        /// Static type used by verification and lowering.
        Type type{ Type::unit() };
        /// Referenced binding when kind is Variable.
        SymbolName symbol{};
        /// Constant payload when kind is Literal.
        Literal literal{};

        /// Create a typed variable operand.
        /// @param name Resolved binding identity.
        /// @param value_type Static type of the binding.
        /// @return A Variable atom carrying the supplied identity and type.
        [[nodiscard]] static auto
        variable(SymbolName name, Type value_type) -> Atom
        {
            return Atom{ Kind::Variable,
                         std::move(value_type),
                         std::move(name),
                         {} };
        }
        /// Create a variable operand when only its numeric identity is known.
        /// @param id Stable binding identity.
        /// @param value_type Static type of the binding.
        /// @return A Variable atom with an empty spelling and supplied type.
        [[nodiscard]] static auto
        variable(SymbolId id, Type value_type) -> Atom
        {
            return variable(SymbolName{ id, {} }, std::move(value_type));
        }
        /// Create a typed literal operand.
        /// @param value Literal value to retain.
        /// @param value_type Static type assigned to the literal.
        /// @return A Literal atom carrying the supplied payload and type.
        [[nodiscard]] static auto
        constant(Literal value, Type value_type) -> Atom
        {
            return Atom{ Kind::Literal,
                         std::move(value_type),
                         {},
                         std::move(value) };
        }
        /// Compare the operand tag, type, and active payload.
        /// @return true when both atoms represent the same operand.
        [[nodiscard]] auto
        operator==(const Atom &) const -> bool = default;
    };

    /// Ownership policy applied when a closure captures a binding.
    enum class CaptureMode : std::uint8_t
    {
        Strong, ///< Retain the captured object for the closure lifetime.
        Weak,   ///< Observe the object without extending its lifetime.
        Unowned ///< Use a non-retaining reference whose lifetime is guaranteed.
    };

    /// Binding captured from an enclosing lexical scope into a closure.
    struct Capture final
    {
        /// Ownership behavior that must survive closure lowering.
        CaptureMode mode{ CaptureMode::Strong };
        /// Binding identity visible in the lifted closure.
        SymbolName symbol{};
        /// Static type of the captured binding.
        Type type{ Type::unit() };
        /// Value expression evaluated in the enclosing lexical environment.
        Atom value{};
        /// Compare capture ownership and binding metadata.
        /// @return true when mode, binding, type, and value match.
        [[nodiscard]] auto
        operator==(const Capture &) const -> bool = default;
    };

    /// Operation encoded by a CorePrep instruction.
    enum class Operation : std::uint8_t
    {
        Copy,     ///< Copy one operand into the destination.
        Call,     ///< Call the function supplied as the first operand.
        Add,      ///< Arithmetic addition.
        Subtract, ///< Arithmetic subtraction.
        Multiply, ///< Arithmetic multiplication.
        Divide,   ///< Truncating arithmetic division.
        /// Rounded division `//`: nearest integer, halves away from zero.
        /// The enumerator keeps its historical name; it never floors.
        FloorDivide,
        Remainder,    ///< Arithmetic remainder.
        LessThan,     ///< Ordered less-than comparison.
        LessEqual,    ///< Ordered less-than-or-equal comparison.
        GreaterThan,  ///< Ordered greater-than comparison.
        GreaterEqual, ///< Ordered greater-than-or-equal comparison.
        Equal,        ///< Value equality comparison.
        NotEqual,     ///< Value inequality comparison.
        LogicalAnd,   ///< Boolean conjunction.
        LogicalOr,    ///< Boolean disjunction.
        Negate,       ///< Arithmetic negation.
        LogicalNot,   ///< Boolean negation.
        MakeClosure,  ///< Construct a closure using closure metadata.
        Power,        ///< Exponentiation.
        ShiftLeft,    ///< Left bit shift.
        ShiftRight,   ///< Right bit shift.
        BitwiseAnd,   ///< Bitwise conjunction.
        BitwiseXor,   ///< Bitwise exclusive disjunction.
        BitwiseOr,    ///< Bitwise inclusive disjunction.
        BitwiseNot,   ///< Bitwise complement.
        TypeIs,       ///< Runtime type test.
        /// A callable that remembers its result. The operand is a callable
        /// without parameters; the result calls it at most once, at its
        /// own first call, and returns what it returned from then on.
        Memoize,
        /// A call of a function of the runtime. The first operand is an
        /// integer literal, the identity of the function in the catalog of
        /// `Tala/Core/RuntimeCall.hpp`; the operands after it are
        /// the arguments.
        RuntimeCall
    };

    /// One binding, assignment, or value-producing operation in a basic block.
    struct Instruction final
    {
        /// Describes how this instruction contributes to block evaluation.
        enum class Kind : std::uint8_t
        {
            /// Introduces a local destination binding.
            Bind,
            /// Updates an existing mutable destination.
            Assign,
            /// Computes a value without introducing a binding.
            Evaluate /**< Computes a value without introducing a binding. */
        };
        /// Active instruction category.
        Kind kind{ Kind::Evaluate };
        /// Destination binding for Bind and Assign instructions.
        SymbolName destination{};
        /// Result type of the operation.
        Type type{ Type::unit() };
        /// Whether a binding introduced by Bind may be reassigned.
        bool mutable_binding{};
        /// Operation to apply to operands.
        Operation operation{ Operation::Copy };
        /// Ordered inputs consumed by the operation.
        std::vector<Atom> operands;
        /// Lifted function target used only by MakeClosure.
        SymbolName closure_function{};
        /// Captures and their ownership modes used only by MakeClosure.
        std::vector<Capture> captures;
        /// Compare every semantic instruction field.
        /// @return true when the full instruction payload matches.
        [[nodiscard]] auto
        operator==(const Instruction &) const -> bool = default;
    };

    /// Control-flow action that ends a basic block.
    struct Terminator final
    {
        /// Selects the branch, return, or unreachable behavior.
        enum class Kind : std::uint8_t
        {
            /// Return value to the caller.
            Return,
            /// Choose one successor using a Boolean value.
            Branch,
            /// Transfer unconditionally to one successor.
            Jump,
            /// Marks a block with no valid continuation.
            Unreachable /**< Marks a block with no valid continuation. */
        };
        /// Active control-flow operation.
        Kind kind{ Kind::Unreachable };
        /// Returned value or Boolean branch condition, depending on kind.
        Atom value{};
        /// Successor selected when a Branch condition is true.
        BlockId true_target{};
        /// Successor selected when a Branch condition is false.
        BlockId false_target{};
        /// Compare terminator category, value, and successor identifiers.
        /// @return true when the full control-flow operation matches.
        [[nodiscard]] auto
        operator==(const Terminator &) const -> bool = default;
    };

    /// Ordered instructions and one terminating control-flow operation.
    struct Block final
    {
        /// Function-local block identifier.
        BlockId id{};
        /// Instructions evaluated before the terminator.
        std::vector<Instruction> instructions;
        /// Required final control-flow operation for the block.
        Terminator terminator;
        /// Compare block identity and complete contents.
        /// @return true when identifier, instructions, and terminator match.
        [[nodiscard]] auto
        operator==(const Block &) const -> bool = default;
    };

    /// Named function parameter and its declared type.
    struct Parameter final
    {
        /// Resolved parameter binding.
        SymbolName symbol{};
        /// Declared parameter type.
        Type type{ Type::unit() };
        /// Compare parameter identity and type.
        /// @return true when both symbol and type match.
        [[nodiscard]] auto
        operator==(const Parameter &) const -> bool = default;
    };

    /// Function body represented as explicit basic blocks.
    struct Function final
    {
        /// Resolved function symbol.
        SymbolName symbol{};
        /// Parameters in source declaration order.
        std::vector<Parameter> parameters;
        /// Declared return type.
        Type return_type{ Type::unit() };
        /// Identifier of the entry block in blocks.
        BlockId entry{};
        /// Function-local control-flow graph.
        std::vector<Block> blocks;
        /// Project-relative source path owning this function definition.
        std::u32string sourceFile{};
        /// Compare signature, origin, entry, and body.
        /// @return true when the complete function representation matches.
        [[nodiscard]] auto
        operator==(const Function &) const -> bool = default;
    };

    /// CorePrep compilation unit consumed by verification and backend lowering.
    struct CorePrepModule final
    {
        /// Qualified module name as Unicode path segments.
        std::vector<std::u32string> name;
        /// Function definitions in deterministic module order.
        std::vector<Function> functions;
        /// Project-relative source files, including files with no declarations.
        std::vector<std::u32string> sourceFiles{};
        /// Compare module identity, source set, and function contents.
        /// @return true when module metadata and all functions match.
        [[nodiscard]] auto
        operator==(const CorePrepModule &) const -> bool = default;
    };

} // namespace tala::core
