// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>
#include <memory>
#include <utility>
#include <variant>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Namespace.hpp"

namespace Progmasoft::Tala::Core
{
    /// Stable declaration identity used by the source-level Core tree.
    using SymbolId = ::tala::core::SymbolId;
    /// Resolved declaration identity together with its source spelling.
    using SymbolName = ::tala::core::SymbolName;
    /// Structural scalar, nominal, or callable type shared with CorePrep.
    using Type = ::tala::core::Type;
    /// Literal payload supported by source-level Core expressions.
    using Literal = ::tala::core::Literal;

    /// Built-in operation represented directly in a typed Core expression.
    enum class Primitive : std::uint8_t
    {
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

    /// Closure capture ownership contract shared with CorePrep.
    using CaptureMode = ::tala::core::CaptureMode;

    /// Forward declaration used by recursive closure capture expressions.
    struct Expression;

    /// One lexical value captured by a closure expression.
    ///
    /// value is evaluated in the enclosing environment. symbol and type name
    /// the corresponding binding in the lifted closure body.
    struct Capture final
    {
        /// Retain, weakly observe, or unownedly reference the captured object.
        CaptureMode mode{ CaptureMode::Strong };
        /// Binding identity exposed within the lifted closure.
        SymbolName symbol{};
        /// Static type of the captured binding.
        Type type{ Type::unit() };
        /// Source expression evaluated in the enclosing lexical scope.
        std::shared_ptr<Expression> value;

        /// Compare capture semantics and the captured expression structurally.
        /// @param other Capture to compare with this value.
        /// @return true when all capture metadata and values are equal.
        [[nodiscard]] auto
        operator==(const Capture &other) const -> bool;
    };

    /// Forward declaration used by nested structured statements.
    struct Statement;

    /// Typed Core expression consumed by desugaring and CorePrep lowering.
    struct Expression final
    {
        /// Selects the active expression payload fields.
        enum class Kind : std::uint8_t
        {
            Variable,  ///< Resolved local or parameter reference.
            Literal,   ///< Constant literal value.
            Apply,     ///< Function invocation.
            Primitive, ///< Built-in operation application.
            Closure,   ///< Anonymous function with explicit captures.
            Let,       ///< Lexical binding followed by a body expression.
            /// Two-way selection that evaluates exactly one of two arms.
            /// operands holds the test, the first arm and the second arm.
            Conditional
        };

        /// Active expression category.
        Kind kind{ Kind::Literal };
        /// Statically inferred result type.
        Type type{ Type::unit() };
        /// Referenced binding when kind is Variable or Let.
        SymbolName symbol{};
        /// Constant payload when kind is Literal.
        Literal literal{};
        /// Built-in operation when kind is Primitive.
        Core::Primitive primitive{ Core::Primitive::Add };
        /// Called expression when kind is Apply.
        std::shared_ptr<Expression> callee;
        /// Bound value when kind is Let.
        std::shared_ptr<Expression> letValue;
        /// Body expression evaluated after the Let binding.
        std::shared_ptr<Expression> letBody;
        /// Binding identity introduced by a Let expression.
        SymbolName letSymbol{};
        /// Binding type for the Let expression.
        Type letType{ Type::unit() };
        /// Ordered call or primitive arguments; for Conditional, the test
        /// followed by the first and the second arm.
        std::vector<Expression> operands;
        /// Lexical values captured by a closure.
        std::vector<Capture> captures;
        /// Closure parameters in declaration order.
        std::vector<std::pair<SymbolName, Type>> closureParameters;
        /// Declared closure result type.
        Type closureReturnType{ Type::unit() };
        /// Structured closure body; null outside closure expressions.
        std::shared_ptr<std::vector<Statement>> closureBody;

        /// Construct the default value of every member.
        Expression() = default;
        /// Copy every member; nested values are copied recursively.
        Expression(const Expression &) = default;
        /// Move every member.
        Expression(Expression &&) = default;
        /// Copy-assign every member.
        /// @return This value.
        auto
        operator=(const Expression &) -> Expression & = default;
        /// Move-assign every member.
        /// @return This value.
        auto
        operator=(Expression &&) -> Expression & = default;
        /**
         * @brief Release the operands without recursing once per operand
         * level.
         *
         * A chain of operators nests as deep as it is long, in the first
         * operand of each primitive. The operands are moved to a list and
         * released from there, so the stack this uses does not grow with
         * the length of a chain.
         */
        ~Expression();

        /// Construct a typed reference to a resolved binding.
        /// @param name Resolved binding identity.
        /// @param valueType Static type of the binding.
        /// @return A Variable expression with the given symbol and type.
        [[nodiscard]] static auto
        Variable(SymbolName name, Type valueType) -> Expression;
        /// Construct a typed constant expression.
        /// @param value Literal payload to retain.
        /// @param valueType Static type assigned to the literal.
        /// @return A Literal expression carrying the supplied value.
        [[nodiscard]] static auto
        Constant(Literal value, Type valueType) -> Expression;
        /// Construct a function application expression.
        /// @param target Callee expression.
        /// @param arguments Arguments in source evaluation order.
        /// @param resultType Statically resolved result type.
        /// @return An Apply expression with owned child expressions.
        [[nodiscard]] static auto
        Apply(Expression target,
              std::vector<Expression> arguments,
              Type resultType) -> Expression;
        /// Construct an application of a built-in primitive operation.
        /// @param operation Primitive operation to execute.
        /// @param arguments Operands in source evaluation order.
        /// @param resultType Statically resolved result type.
        /// @return A Primitive expression with the supplied operands.
        [[nodiscard]] static auto
        InvokePrimitive(Core::Primitive operation,
                        std::vector<Expression> arguments,
                        Type resultType) -> Expression;
        /// Construct a closure with explicit captures, signature, and body.
        /// @param captured Values captured from the enclosing lexical scope.
        /// @param parameters Closure parameters and their declared types.
        /// @param returnType Declared closure result type.
        /// @param body Structured statements executed by the closure.
        /// @param valueType Static function type of the closure expression.
        /// @return A Closure expression retaining all closure metadata.
        [[nodiscard]] static auto
        Closure(std::vector<Capture> captured,
                std::vector<std::pair<SymbolName, Type>> parameters,
                Type returnType,
                std::vector<Statement> body,
                Type valueType) -> Expression;
        /// Construct a lexical binding expression.
        /// @param name Identity of the newly introduced binding.
        /// @param bindingType Declared type of the bound value.
        /// @param value Expression evaluated before entering the body.
        /// @param body Expression evaluated with the new binding in scope.
        /// @param resultType Static type of the body result.
        /// @return A Let expression containing the binding and body.
        [[nodiscard]] static auto
        Let(SymbolName name,
            Type bindingType,
            Expression value,
            Expression body,
            Type resultType) -> Expression;
        /// Construct a selection between two lazily evaluated arms.
        /// @param test Value tested in Boolean context.
        /// @param whenTrue Arm evaluated when the test is true.
        /// @param whenFalse Arm evaluated when the test is false.
        /// @param resultType Static type shared by both arms.
        /// @return A Conditional expression owning the three children.
        [[nodiscard]] static auto
        Conditional(Expression test,
                    Expression whenTrue,
                    Expression whenFalse,
                    Type resultType) -> Expression;
        /// Compare kind-specific payloads and their child expressions.
        /// @param other Expression to compare with this value.
        /// @return true when both trees have identical structure and types.
        [[nodiscard]] auto
        operator==(const Expression &other) const -> bool;
    };

    /// Local binding introduced by a statement or expression.
    struct Binding final
    {
        /// Resolved identity of the local binding.
        SymbolName symbol{};
        /// Declared type of the bound value.
        Type type{ Type::unit() };
        /// Whether subsequent assignments may update this binding.
        bool mutableBinding{};
        /// Initializer evaluated when the binding is introduced.
        Expression value{};
        /// Compare binding identity, mutability, type, and initializer.
        /// @return true when all binding properties match.
        [[nodiscard]] auto
        operator==(const Binding &) const -> bool = default;
    };

    /// Structured statement in a Core function or closure body.
    struct Statement final
    {
        /// Selects which statement-specific fields are active.
        enum class Kind : std::uint8_t
        {
            Bind,     ///< Introduces a local binding.
            Assign,   ///< Updates an existing mutable binding.
            Return,   ///< Returns an expression value from the function.
            If,       ///< Selects between two structured statement branches.
            Evaluate, ///< Evaluates an expression for its effects.
            While,    ///< Pre-test loop.
            DoWhile,  ///< Post-test loop.
            For,      ///< Loop with condition, body, and update regions.
            Break,    ///< Exits the innermost active loop.
            Continue  ///< Continues at the innermost loop's next step.
        };

        /// Active statement category.
        Kind kind{ Kind::Evaluate };
        /// Binding payload when kind is Bind.
        Binding binding{};
        /// Assignment destination when kind is Assign.
        SymbolName destination{};
        /// Return value, condition, assignment value, or evaluated expression.
        Expression expression{};
        /// Then branch statements of an If statement.
        std::vector<Statement> trueBranch;
        /// Else branch statements of an If statement.
        std::vector<Statement> falseBranch;
        /// Body of While, DoWhile, or For loops.
        std::vector<Statement> loopBody;
        /// Update region executed after each For body iteration.
        std::vector<Statement> loopUpdate;

        /// Construct the default value of every member.
        Statement() = default;
        /// Copy every member; nested values are copied recursively.
        Statement(const Statement &) = default;
        /// Move every member.
        Statement(Statement &&) = default;
        /// Copy-assign every member.
        /// @return This value.
        auto
        operator=(const Statement &) -> Statement & = default;
        /// Move-assign every member.
        /// @return This value.
        auto
        operator=(Statement &&) -> Statement & = default;
        /**
         * @brief Release the nested statements without recursing once per
         * level.
         *
         * An `else if` chain nests as deep as it is long. The branches and
         * loop regions are moved to a list and released from there, so the
         * stack this uses does not grow with the length of a chain or the
         * depth of nesting.
         */
        ~Statement();

        /// Introduce a local binding.
        /// @param value Binding and initializer to add.
        /// @return A Bind statement containing value.
        [[nodiscard]] static auto
        Bind(Binding value) -> Statement;
        /// Assign a new value to a mutable local binding.
        /// @param target Destination binding identity.
        /// @param value Expression evaluated and assigned to target.
        /// @return An Assign statement.
        [[nodiscard]] static auto
        Assign(SymbolName target, Expression value) -> Statement;
        /// Return a value from the current function or closure.
        /// @param value Expression evaluated as the return value.
        /// @return A Return statement.
        [[nodiscard]] static auto
        Return(Expression value) -> Statement;
        /// Select between two structured statement branches.
        /// @param condition Boolean expression selecting the branch.
        /// @param whenTrue Statements executed when condition is true.
        /// @param whenFalse Statements executed when condition is false.
        /// @return An If statement preserving both branch bodies.
        [[nodiscard]] static auto
        If(Expression condition,
           std::vector<Statement> whenTrue,
           std::vector<Statement> whenFalse) -> Statement;
        /// Evaluate an expression while discarding its resulting value.
        /// @param value Expression whose effects are preserved.
        /// @return An Evaluate statement.
        [[nodiscard]] static auto
        Evaluate(Expression value) -> Statement;
        /**
         * @brief Build a pre-test loop with an ordered, structured body.
         *
         * CorePrep evaluates the condition before each body entry and uses
         * the innermost loop's header as the `continue` destination.
         * @param condition Boolean expression tested before each iteration.
         * @param body Statements executed while condition evaluates to true.
         * @return A While statement with a pre-test control-flow shape.
         */
        [[nodiscard]] static auto
        While(Expression condition, std::vector<Statement> body) -> Statement;
        /**
         * @brief Build a post-test loop whose body executes before its test.
         *
         * `continue` transfers to the trailing condition, not to the body
         * entry.
         * @param body Statements executed before each condition check.
         * @param condition Boolean expression tested after each body pass.
         * @return A DoWhile statement with a post-test control-flow shape.
         */
        [[nodiscard]] static auto
        DoWhile(std::vector<Statement> body, Expression condition) -> Statement;
        /**
         * @brief Build a classic loop with distinct body and update regions.
         *
         * Keeping updates separate ensures `continue` runs them before the
         * next condition check.
         * @param condition Boolean expression tested before each body pass.
         * @param body Statements executed for each successful condition test.
         * @param update Statements run after the body, including on continue.
         * @return A For statement with distinct body and update regions.
         */
        [[nodiscard]] static auto
        For(Expression condition,
            std::vector<Statement> body,
            std::vector<Statement> update) -> Statement;
        /// Exit the innermost active loop.
        /// @return A Break statement.
        [[nodiscard]] static auto
        Break() -> Statement;
        /// Continue at the innermost loop's language-defined target.
        /// @return A Continue statement.
        [[nodiscard]] static auto
        Continue() -> Statement;
        /// Compare statement category and all active nested data.
        /// @return true when both statements have equal structure.
        [[nodiscard]] auto
        operator==(const Statement &) const -> bool = default;
    };

    /// Named parameter in a Core function signature.
    struct Parameter final
    {
        /// Resolved parameter binding identity.
        SymbolName symbol{};
        /// Declared parameter type.
        Type type{ Type::unit() };
        /// Compare parameter identity and type.
        /// @return true when both parameter fields match.
        [[nodiscard]] auto
        operator==(const Parameter &) const -> bool = default;
    };

    /// Top-level Core function, including source ownership for emission.
    struct Function final
    {
        /// Resolved function declaration.
        SymbolName symbol{};
        /// Parameters in declaration order.
        std::vector<Parameter> parameters;
        /// Declared result type.
        Type returnType{ Type::unit() };
        /// Ordered function body.
        std::vector<Statement> body;
        /// Project-relative source path that owns the emitted definition.
        std::u32string sourceFile{};
        /// Compare function identity, signature, source owner, and body.
        /// @return true when all function fields match.
        [[nodiscard]] auto
        operator==(const Function &) const -> bool = default;
    };

    /// Source module containing typed functions and the selected source set.
    struct Module final
    {
        /// Qualified module name represented as Unicode path segments.
        std::vector<std::u32string> name;
        /// Functions in deterministic declaration order.
        std::vector<Function> functions;
        /// Project-relative sources, including files without declarations.
        std::vector<std::u32string> sourceFiles{};
        /// Compare module name, source set, and contained functions.
        /// @return true when all module fields match.
        [[nodiscard]] auto
        operator==(const Module &) const -> bool = default;
    };
} // namespace Progmasoft::Tala::Core
