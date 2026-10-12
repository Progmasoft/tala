// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <llvm/ADT/ArrayRef.h>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_set>

#include "Progmasoft/Tala/ADTs/DenseIdMap.hpp"
#include "Progmasoft/Tala/Core/Ownership.hpp"
#include "Progmasoft/Tala/Core/RuntimeCall.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Template.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Talac/Artifact/SourcePath.hpp"

namespace Progmasoft::Tala::Core
{
    namespace
    {
        struct Definition final
        {
            Type type;
            bool mutableBinding{};
            std::u32string spelling;
        };
        using Definitions = ADTs::DenseIdMap<SymbolId, Definition>;

        /// The local definitions visible at one point of a function.
        ///
        /// A branch, a loop body, a let and a closure each see what is
        /// defined around them and add definitions that end with them. An
        /// environment therefore holds only what its own region defines and
        /// refers to the environment of the region around it. Entering a
        /// region costs nothing that depends on how much is already
        /// defined; a copy of everything visible, which is what this
        /// replaced, made a function with many branches or closures cost
        /// the product of the two.
        ///
        /// The environment around a region must outlive the region's own
        /// and must not gain definitions while the inner one is in use.
        /// The verifier walks regions strictly inside one another, so both
        /// hold.
        class Environment final
        {
        public:
            Environment() = default;
            Environment(const Environment &) = delete;
            Environment(Environment &&) = default;
            auto
            operator=(const Environment &) -> Environment & = delete;
            auto
            operator=(Environment &&) -> Environment & = delete;
            ~Environment() = default;

            /// The environment of a region inside this one.
            [[nodiscard]] auto
            Extend() const -> Environment
            {
                Environment inner;
                inner.outer_ = this;
                return inner;
            }

            /// The definition of a symbol in this region or, failing that,
            /// in the nearest region around it that defines it.
            [[nodiscard]] auto
            Find(const SymbolId symbol) const -> const Definition *
            {
                for (const auto *region = this; region != nullptr;
                     region = region->outer_)
                    if (const auto *found = region->own_.Find(symbol))
                        return found;
                return nullptr;
            }

            [[nodiscard]] auto
            Contains(const SymbolId symbol) const -> bool
            {
                return Find(symbol) != nullptr;
            }

            /// Define a symbol in this region. It hides a definition of
            /// the same symbol in a region around this one until this
            /// region ends.
            void
            InsertOrAssign(const SymbolId symbol, Definition definition)
            {
                own_.InsertOrAssign(symbol, std::move(definition));
            }

        private:
            const Environment *outer_{};
            Definitions own_;
        };

        class FunctionVerifier final
        {
        public:
            FunctionVerifier(const Function &function,
                             const Definitions &functions,
                             std::vector<VerificationIssue> &issues)
                : function_(function)
                , functions_(functions)
                , issues_(issues)
            {}

            void
            Run()
            {
                CheckSymbol(function_.symbol,
                            "TAC1006",
                            "Core function symbol must be positive");
                CheckType(function_.returnType,
                          "TAC1003",
                          "Core function has an unresolved return type");
                ADTs::DenseIdSet<SymbolId> parameters;
                parameters.Reserve(function_.parameters.size());
                for (const auto &parameter : function_.parameters)
                {
                    CheckSymbol(parameter.symbol,
                                "TAC1006",
                                "Core parameter symbol must be positive");
                    CheckType(parameter.type,
                              "TAC1007",
                              "Core parameter has an unresolved type");
                    if (!parameters.Insert(parameter.symbol.id))
                        Add("TAC1004",
                            "duplicate Core parameter symbol",
                            parameter.symbol.id);
                    environment_.InsertOrAssign(
                        parameter.symbol.id,
                        Definition{ parameter.type,
                                    false,
                                    parameter.symbol.spelling });
                }
                VerifyStatements(function_.body,
                                 environment_,
                                 function_.returnType);
                if (function_.returnType != Type::unit()
                    && !AlwaysReturns(function_.body))
                    Add("TAC1005",
                        "non-void Core function may complete without returning "
                        "a value");
            }

        private:
            const Function &function_;
            const Definitions &functions_;
            Environment environment_;
            std::vector<VerificationIssue> &issues_;

            [[nodiscard]] auto
            FindDefinition(const Environment &locals,
                           const SymbolId symbol) const -> const Definition *
            {
                if (const auto *found = locals.Find(symbol))
                    return found;
                return functions_.Find(symbol);
            }

            [[nodiscard]] auto
            ContainsDefinition(const Environment &locals,
                               const SymbolId symbol) const -> bool
            {
                return locals.Contains(symbol) || functions_.Contains(symbol);
            }

            // The verifier recurses once per level of nesting. Reporting
            // is therefore kept out of the functions that recurse: the
            // texts are passed as views and become strings only here, so a
            // check costs its caller no string on the stack.
            [[gnu::noinline]] void
            Add(std::string_view code,
                std::string_view message,
                SymbolId symbol = 0U)
            {
                issues_.push_back(VerificationIssue{ std::string(code),
                                                     std::string(message),
                                                     function_.symbol.id,
                                                     symbol });
            }
            void
            CheckSymbol(const SymbolName &symbol,
                        std::string_view code,
                        std::string_view message)
            {
                if (symbol.id == 0U)
                    Add(code, message, symbol.id);
            }
            [[gnu::noinline]] void
            CheckType(const Type &type,
                      std::string_view code,
                      std::string_view message)
            {
                if (ContainsInvalidType(type))
                    Add(code, message);
                for (const auto &templateIssue : Template::Validate(type))
                    Add("TAC1040",
                        "invalid Core template type: " + templateIssue.message);
            }
            [[gnu::noinline]] void
            CheckSameType(const Type &expected,
                          const Type &actual,
                          std::string_view code,
                          std::string_view message,
                          SymbolId symbol = 0U)
            {
                if (expected != actual)
                    Add(code, message, symbol);
            }
            [[nodiscard]] static auto
            ContainsInvalidType(const Type &type) -> bool
            {
                // Core v1 has no ErrorType tag. Empty named types and malformed
                // function component lists are the native model's equivalent
                // unresolved shapes.
                if (type.kind == Type::Kind::Named && type.name.empty())
                    return true;
                if (type.kind == Type::Kind::Function
                    && type.components.empty())
                    return true;
                if (std::ranges::any_of(type.components, ContainsInvalidType))
                    return true;
                return std::ranges::any_of(
                    type.templateArguments,
                    [](const auto &argument) {
                        if (argument.kind
                            == ::tala::core::TemplateArgument::Kind::Type)
                            return !argument.type
                                   || ContainsInvalidType(*argument.type);
                        if (argument.value.kind
                            == ::tala::core::TemplateValue::Kind::Parameter)
                            return argument.value.parameter.id == 0U;
                        return !::tala::core::integer_is_canonical(
                                   argument.value.integer)
                               && argument.value.kind
                                      != ::tala::core::TemplateValue::Kind::
                                          Boolean;
                    });
            }
            /// Whether a statement is a loop that cannot be left: its
            /// condition is the literal true and no `break` leaves it. Such
            /// a loop ends only through a `return` inside it, or not at
            /// all, so control never reaches the statement after it.
            [[nodiscard]] static auto
            CannotBeLeft(const Statement &statement) -> bool
            {
                if (statement.kind != Statement::Kind::While
                    && statement.kind != Statement::Kind::DoWhile
                    && statement.kind != Statement::Kind::For)
                    return false;
                const auto *const condition
                    = std::get_if<bool>(&statement.expression.literal);
                if (statement.expression.kind != Expression::Kind::Literal
                    || condition == nullptr || !*condition)
                    return false;
                // The statements of the loop are searched from a list, so
                // an `else if` chain in the body costs no stack per link.
                // A break in a nested loop leaves that loop.
                std::vector<const std::vector<Statement> *> pending{
                    &statement.loopBody,
                    &statement.loopUpdate
                };
                while (!pending.empty())
                {
                    const auto *const statements = pending.back();
                    pending.pop_back();
                    for (const auto &nested : *statements)
                    {
                        if (nested.kind == Statement::Kind::Break)
                            return false;
                        if (nested.kind == Statement::Kind::If)
                        {
                            pending.push_back(&nested.trueBranch);
                            pending.push_back(&nested.falseBranch);
                        }
                    }
                }
                return true;
            }
            /// Whether control can never fall off the end of the statements:
            /// every path returns, or runs into a loop that cannot be left.
            /// The false
            /// branch of an `if` is followed in a loop rather than by
            /// recursion while it is the last statement to decide the
            /// answer, so an `else if` chain costs no stack per link.
            [[nodiscard]] static auto
            AlwaysReturns(llvm::ArrayRef<Statement> statements) -> bool
            {
                for (;;)
                {
                    const Statement *deciding = nullptr;
                    for (const auto &statement : statements)
                    {
                        if (statement.kind == Statement::Kind::Return
                            || CannotBeLeft(statement))
                            return true;
                        if (statement.kind != Statement::Kind::If
                            || statement.falseBranch.empty()
                            || !AlwaysReturns(statement.trueBranch))
                            continue;
                        // This `if` returns on every path exactly when its
                        // false branch does. Only the last such `if` needs
                        // no recursion: an earlier one that does not return
                        // must still let the statements after it decide.
                        if (&statement == &statements.back())
                        {
                            deciding = &statement;
                            break;
                        }
                        if (AlwaysReturns(statement.falseBranch))
                            return true;
                    }
                    if (deciding == nullptr)
                        return false;
                    statements = deciding->falseBranch;
                }
            }
            /// Where a `break` or `continue` would transfer to. A `for`
            /// update region is inside its loop for `break`, which leaves the
            /// loop, but it is the loop's continuation point itself: a
            /// `continue` there has no later point of the same iteration to
            /// reach and would re-enter the update without testing the
            /// condition. A loop nested in an update opens a body scope again.
            enum class TransferScope : std::uint8_t
            {
                OutsideLoop,
                InLoopBody,
                InForUpdate
            };

            void
            VerifyStatements(const llvm::ArrayRef<Statement> statements,
                             Environment &environment,
                             const Type &expectedReturnType,
                             const TransferScope scope
                             = TransferScope::OutsideLoop)
            {
                for (const auto &statement : statements)
                    VerifyStatement(statement,
                                    environment,
                                    expectedReturnType,
                                    scope);
            }
            /// Whether a false branch is exactly one nested `if`, which is
            /// how an `else if` reaches Core.
            [[nodiscard]] static auto
            ContinuesChain(const Statement &statement) -> bool
            {
                return statement.falseBranch.size() == 1U
                       && statement.falseBranch.front().kind
                              == Statement::Kind::If;
            }

            /**
             * @brief Verify an `if` and every `else if` that continues it.
             *
             * A chain of `else if` links nests one false branch inside the
             * next, so verifying it by recursion uses stack in proportion to
             * its length, and a long chain in valid source would overflow
             * it. The links are walked in a loop instead. The checks, their
             * order and the environments they see are those of the
             * recursive formulation: each link's condition is verified in
             * the environment of the branch that holds it, its true branch
             * in a copy of that environment, and the final false branch in
             * another copy. The environment of a false branch that only
             * holds the next link is not used again, so the walk keeps one
             * environment for the whole chain instead of copying it per
             * link.
             */
            [[gnu::noinline]] void
            VerifyConditionalChain(const Statement &first,
                                   Environment &environment,
                                   const Type &expectedReturnType,
                                   const TransferScope scope)
            {
                const Statement *link = &first;
                // The first condition is verified in the caller's
                // environment; the links after it in the chain's own copy.
                std::optional<Environment> chainEnvironment;
                Environment *linkEnvironment = &environment;
                for (;;)
                {
                    VerifyExpression(link->expression, *linkEnvironment);
                    if (!accepts_boolean_context(link->expression.type))
                        Add("TAC1017",
                            "Core condition must be bool or numeric");
                    auto trueEnvironment = linkEnvironment->Extend();
                    VerifyStatements(link->trueBranch,
                                     trueEnvironment,
                                     expectedReturnType,
                                     scope);
                    if (!ContinuesChain(*link))
                        break;
                    if (!chainEnvironment)
                    {
                        chainEnvironment.emplace(environment.Extend());
                        linkEnvironment = &*chainEnvironment;
                    }
                    link = &link->falseBranch.front();
                }
                auto falseEnvironment = linkEnvironment->Extend();
                VerifyStatements(link->falseBranch,
                                 falseEnvironment,
                                 expectedReturnType,
                                 scope);
            }

            // Each kind of statement and of expression is verified by a
            // function of its own, so that a level of nesting costs the
            // frame of the kind that nests and not the frames of every kind
            // together.
            void
            VerifyStatement(const Statement &statement,
                            Environment &environment,
                            const Type &expectedReturnType,
                            const TransferScope scope)
            {
                switch (statement.kind)
                {
                    case Statement::Kind::Bind:
                        VerifyBinding(statement.binding, environment);
                        return;
                    case Statement::Kind::Assign:
                        VerifyAssignment(statement, environment);
                        return;
                    case Statement::Kind::Return:
                        VerifyExpression(statement.expression, environment);
                        CheckSameType(expectedReturnType,
                                      statement.expression.type,
                                      "TAC1016",
                                      "Core return value has the wrong type");
                        return;
                    case Statement::Kind::If:
                        VerifyConditionalChain(statement,
                                               environment,
                                               expectedReturnType,
                                               scope);
                        return;
                    case Statement::Kind::Evaluate:
                        VerifyExpression(statement.expression, environment);
                        return;
                    case Statement::Kind::While:
                    case Statement::Kind::DoWhile:
                    case Statement::Kind::For:
                        VerifyLoop(statement, environment, expectedReturnType);
                        return;
                    case Statement::Kind::Break:
                        if (scope == TransferScope::OutsideLoop)
                            Add("TAC1064", "Core break appears outside a loop");
                        return;
                    case Statement::Kind::Continue:
                        if (scope == TransferScope::OutsideLoop)
                            Add("TAC1065",
                                "Core continue appears outside a loop");
                        if (scope == TransferScope::InForUpdate)
                            Add("TAC1066",
                                "Core continue appears in a for update "
                                "region");
                        return;
                }
            }
            [[gnu::noinline]] void
            VerifyBinding(const Binding &binding, Environment &environment)
            {
                CheckSymbol(binding.symbol,
                            "TAC1008",
                            "Core binding symbol must be positive");
                CheckType(binding.type,
                          "TAC1009",
                          "Core binding has an unresolved type");
                VerifyExpression(binding.value, environment);
                CheckSameType(binding.type,
                              binding.value.type,
                              "TAC1011",
                              "Core binding value type does not match "
                              "its declaration",
                              binding.symbol.id);
                if (ContainsDefinition(environment, binding.symbol.id))
                    Add("TAC1010",
                        "Core binding symbol is already defined",
                        binding.symbol.id);
                environment.InsertOrAssign(
                    binding.symbol.id,
                    Definition{ binding.type,
                                binding.mutableBinding,
                                binding.symbol.spelling });
            }
            [[gnu::noinline]] void
            VerifyAssignment(const Statement &statement,
                             const Environment &environment)
            {
                CheckSymbol(statement.destination,
                            "TAC1015",
                            "Core assignment symbol must be positive");
                VerifyExpression(statement.expression, environment);
                const auto *found
                    = FindDefinition(environment, statement.destination.id);
                if (found == nullptr)
                    Add("TAC1012",
                        "Core assignment targets an undefined symbol",
                        statement.destination.id);
                else if (!found->mutableBinding)
                    Add("TAC1013",
                        "Core assignment targets an immutable symbol",
                        statement.destination.id);
                else
                    CheckSameType(found->type,
                                  statement.expression.type,
                                  "TAC1014",
                                  "Core assignment value has the wrong type",
                                  statement.destination.id);
            }
            [[gnu::noinline]] void
            VerifyLoop(const Statement &statement,
                       const Environment &environment,
                       const Type &expectedReturnType)
            {
                VerifyExpression(statement.expression, environment);
                if (!accepts_boolean_context(statement.expression.type))
                    Add("TAC1017",
                        "Core loop condition must be bool or numeric");
                auto loopEnvironment = environment.Extend();
                VerifyStatements(statement.loopBody,
                                 loopEnvironment,
                                 expectedReturnType,
                                 TransferScope::InLoopBody);
                if (statement.kind == Statement::Kind::For)
                {
                    auto updateEnvironment = environment.Extend();
                    VerifyStatements(statement.loopUpdate,
                                     updateEnvironment,
                                     expectedReturnType,
                                     TransferScope::InForUpdate);
                }
            }

            /**
             * @brief Verify one expression.
             *
             * A chain of operators nests in the first operand of each
             * primitive, as deep as the chain is long. Those operands are
             * walked in a loop: the type of each primitive is checked on
             * the way down, and its other operands and its own rules on
             * the way back, innermost first. The checks and their order
             * are those of the recursive formulation.
             */
            [[gnu::noinline]] void
            VerifyExpression(const Expression &expression,
                             const Environment &environment)
            {
                std::vector<const Expression *> chain;
                const Expression *current = &expression;
                for (;;)
                {
                    CheckType(current->type,
                              "TAC1018",
                              "Core expression has an unresolved type");
                    if (current->kind != Expression::Kind::Primitive
                        || current->operands.empty())
                        break;
                    chain.push_back(current);
                    current = &current->operands.front();
                }
                VerifyUnchained(*current, environment);
                while (!chain.empty())
                {
                    VerifyPrimitive(*chain.back(), environment);
                    chain.pop_back();
                }
            }
            /// An expression that is not a primitive with operands; its
            /// type was checked.
            void
            VerifyUnchained(const Expression &expression,
                            const Environment &environment)
            {
                switch (expression.kind)
                {
                    case Expression::Kind::Variable:
                        VerifyVariable(expression, environment);
                        return;
                    case Expression::Kind::Literal:
                        VerifyLiteral(expression);
                        return;
                    case Expression::Kind::Apply:
                        VerifyCall(expression, environment);
                        return;
                    case Expression::Kind::Primitive:
                        VerifyPrimitive(expression, environment);
                        return;
                    case Expression::Kind::Closure:
                        VerifyClosure(expression, environment);
                        return;
                    case Expression::Kind::Let:
                        VerifyLet(expression, environment);
                        return;
                    case Expression::Kind::Conditional:
                        VerifyConditional(expression, environment);
                        return;
                }
            }
            [[gnu::noinline]] void
            VerifyVariable(const Expression &expression,
                           const Environment &environment)
            {
                CheckSymbol(expression.symbol,
                            "TAC1019",
                            "Core variable symbol must be positive");
                const auto *found
                    = FindDefinition(environment, expression.symbol.id);
                if (found == nullptr)
                {
                    Add("TAC1020",
                        "Core expression references an undefined symbol",
                        expression.symbol.id);
                    return;
                }
                CheckSameType(found->type,
                              expression.type,
                              "TAC1021",
                              "Core variable type disagrees with its "
                              "definition",
                              expression.symbol.id);
                if (!expression.symbol.spelling.empty()
                    && !found->spelling.empty()
                    && expression.symbol.spelling != found->spelling)
                    Add("TAC1030",
                        "Core symbol spelling disagrees with its definition",
                        expression.symbol.id);
            }
            [[gnu::noinline]] void
            VerifyLet(const Expression &expression,
                      const Environment &environment)
            {
                CheckSymbol(expression.letSymbol,
                            "TAC1045",
                            "Core let symbol must be positive");
                CheckType(expression.letType,
                          "TAC1046",
                          "Core let binding has an unresolved type");
                if (!expression.letValue || !expression.letBody)
                {
                    Add("TAC1047", "Core let value or body is missing");
                    return;
                }
                VerifyExpression(*expression.letValue, environment);
                CheckSameType(expression.letType,
                              expression.letValue->type,
                              "TAC1048",
                              "Core let value has the wrong type");
                auto bodyEnvironment = environment.Extend();
                bodyEnvironment.InsertOrAssign(
                    expression.letSymbol.id,
                    Definition{ expression.letType,
                                false,
                                expression.letSymbol.spelling });
                VerifyExpression(*expression.letBody, bodyEnvironment);
                CheckSameType(expression.type,
                              expression.letBody->type,
                              "TAC1049",
                              "Core let result disagrees with its body");
            }
            [[gnu::noinline]] void
            VerifyConditional(const Expression &expression,
                              const Environment &environment)
            {
                if (expression.operands.size() != 3U)
                {
                    Add("TAC1071",
                        "Core conditional must contain a test and two arms");
                    return;
                }
                const auto &test = expression.operands[0];
                const auto &whenTrue = expression.operands[1];
                const auto &whenFalse = expression.operands[2];
                VerifyExpression(test, environment);
                if (!accepts_boolean_context(test.type))
                    Add("TAC1067",
                        "Core conditional test must be bool or numeric");
                VerifyExpression(whenTrue, environment);
                VerifyExpression(whenFalse, environment);
                CheckSameType(expression.type,
                              whenTrue.type,
                              "TAC1068",
                              "Core conditional result type disagrees with "
                              "its first arm");
                CheckSameType(expression.type,
                              whenFalse.type,
                              "TAC1069",
                              "Core conditional result type disagrees with "
                              "its second arm");
                // The result is materialized in a plain storage slot. Owned
                // values would need move and release rules for that slot.
                if (!accepts_boolean_context(expression.type))
                    Add("TAC1070",
                        "Core conditional result must be bool or numeric");
            }
            [[gnu::noinline]] void
            VerifyLiteral(const Expression &expression)
            {
                if (const auto issue
                    = validate_literal(expression.literal, expression.type))
                    Add("TAC1029",
                        "Core literal payload does not match its type: "
                            + *issue);
            }
            [[gnu::noinline]] void
            VerifyCall(const Expression &expression,
                       const Environment &environment)
            {
                if (!expression.callee)
                {
                    Add("TAC1025", "Core call target is missing");
                    return;
                }
                VerifyExpression(*expression.callee, environment);
                for (const auto &argument : expression.operands)
                    VerifyExpression(argument, environment);
                const auto &calleeType = expression.callee->type;
                if (calleeType.kind != Type::Kind::Function
                    || calleeType.components.empty())
                {
                    Add("TAC1025", "Core call target is not a function");
                    return;
                }
                const auto parameterCount = calleeType.components.size() - 1U;
                if (parameterCount != expression.operands.size())
                    Add("TAC1022", "Core call has the wrong argument count");
                const auto comparable
                    = std::min(parameterCount, expression.operands.size());
                for (std::size_t index = 0; index < comparable; ++index)
                    CheckSameType(calleeType.components[index],
                                  expression.operands[index].type,
                                  "TAC1023",
                                  "Core call argument has the wrong type");
                CheckSameType(
                    calleeType.components.back(),
                    expression.type,
                    "TAC1024",
                    "Core call result type disagrees with the callee");
            }
            /// A call of a runtime function: the first operand is the
            /// literal that names the function, and the rest are checked
            /// against the row of the catalog that function has.
            [[gnu::noinline]] void
            VerifyRuntimeCall(const Expression &expression)
            {
                namespace runtime = ::tala::core::runtime;
                const runtime::Signature *signature = nullptr;
                if (!expression.operands.empty()
                    && expression.operands.front().kind
                           == Expression::Kind::Literal)
                    if (const auto identity = runtime::IdentityOf(
                            expression.operands.front().literal,
                            expression.operands.front().type))
                        signature = runtime::Find(*identity);
                std::vector<Type::Kind> arguments;
                arguments.reserve(expression.operands.size());
                for (std::size_t index = 1U; index < expression.operands.size();
                     ++index)
                    arguments.push_back(expression.operands[index].type.kind);
                const auto defect = runtime::Check(signature,
                                                   arguments,
                                                   expression.type.kind);
                if (defect != runtime::Defect::None)
                    Add("TAC1075",
                        "Core " + std::string(runtime::Describe(defect)));
            }
            /// Verify the operands of a primitive after the first, which
            /// the caller has verified, and then the primitive itself.
            [[gnu::noinline]] void
            VerifyPrimitive(const Expression &expression,
                            const Environment &environment)
            {
                for (std::size_t index = 1U; index < expression.operands.size();
                     ++index)
                    VerifyExpression(expression.operands[index], environment);
                if (expression.primitive == Primitive::RuntimeCall)
                {
                    VerifyRuntimeCall(expression);
                    return;
                }
                const auto memoize = expression.primitive == Primitive::Memoize;
                const auto unary
                    = expression.primitive == Primitive::Negate
                      || expression.primitive == Primitive::LogicalNot
                      || expression.primitive == Primitive::BitwiseNot
                      || memoize;
                const auto logical
                    = expression.primitive == Primitive::LogicalAnd
                      || expression.primitive == Primitive::LogicalOr
                      || expression.primitive == Primitive::LogicalNot;
                const auto integerOnly
                    = expression.primitive == Primitive::ShiftLeft
                      || expression.primitive == Primitive::ShiftRight
                      || expression.primitive == Primitive::BitwiseAnd
                      || expression.primitive == Primitive::BitwiseXor
                      || expression.primitive == Primitive::BitwiseOr
                      || expression.primitive == Primitive::BitwiseNot;
                const auto comparison
                    = expression.primitive >= Primitive::LessThan
                      && expression.primitive <= Primitive::NotEqual;
                if (expression.operands.size() != (unary ? 1U : 2U))
                    Add("TAC1026",
                        "Core primitive has the wrong operand count");
                if (expression.operands.empty())
                    return;
                const auto &operandType = expression.operands.front().type;
                const auto typeTest = expression.primitive == Primitive::TypeIs;
                if (!logical && !typeTest)
                    for (const auto &operand : expression.operands)
                        CheckSameType(
                            operandType,
                            operand.type,
                            "TAC1027",
                            "Core primitive operands must have matching types");

                if (memoize)
                {
                    // The remembered result is kept in the callable, in a
                    // slot that owns nothing.
                    const auto remembers
                        = operandType.kind == Type::Kind::Function
                          && operandType.components.size() == 1U
                          && (operandType.components.front().kind
                                  == Type::Kind::Bool
                              || is_numeric(operandType.components.front()));
                    if (!remembers)
                        Add("TAC1073",
                            "Core memoization requires a callable without "
                            "parameters whose result is bool or numeric");
                }
                else if (typeTest)
                {
                    if (expression.operands.size() == 2U)
                    {
                        const auto &subjectType = expression.operands[0].type;
                        const auto &identityType = expression.operands[1].type;
                        const auto referenceSubject
                            = subjectType.kind == Type::Kind::Named
                              || subjectType.kind == Type::Kind::String
                              || subjectType.kind == Type::Kind::Function;
                        if (!referenceSubject || identityType != Type::uint64())
                            Add("TAC1050",
                                "Core type test requires a reference subject "
                                "and uint identity");
                    }
                }
                else if (logical)
                {
                    for (const auto &operand : expression.operands)
                        if (!accepts_boolean_context(operand.type))
                            Add("TAC1027",
                                "Core logical primitive requires bool or "
                                "numeric operands");
                }
                else if (integerOnly && !is_integer(operandType))
                    Add("TAC1027",
                        "Core bitwise primitive requires integer operands");
                else if (!is_numeric(operandType)
                         && expression.primitive != Primitive::Equal
                         && expression.primitive != Primitive::NotEqual)
                    Add("TAC1027",
                        "Core arithmetic or ordering primitive requires "
                        "numeric operands");

                if (expression.primitive == Primitive::Negate
                    && !is_signed_integer(operandType)
                    && !is_floating(operandType))
                    Add("TAC1027",
                        "Core negation requires a signed integer or floating "
                        "operand");

                const auto expectedResult
                    = logical || comparison || typeTest ? Type::boolean()
                      : expression.primitive == Primitive::FloorDivide
                              && is_floating(operandType)
                          ? Type::int64()
                          : operandType;
                CheckSameType(expectedResult,
                              expression.type,
                              "TAC1028",
                              "Core primitive result has the wrong type");
            }
            [[gnu::noinline]] void
            VerifyClosure(const Expression &expression,
                          const Environment &outerEnvironment)
            {
                if (!expression.closureBody)
                {
                    Add("TAC1031", "Core closure body is missing");
                    return;
                }

                CheckType(expression.closureReturnType,
                          "TAC1032",
                          "Core closure has an unresolved return type");
                auto closureEnvironment = outerEnvironment.Extend();
                ADTs::DenseIdSet<SymbolId> localSymbols;
                localSymbols.Reserve(expression.captures.size()
                                     + expression.closureParameters.size());

                for (const auto &capture : expression.captures)
                {
                    CheckSymbol(capture.symbol,
                                "TAC1033",
                                "Core closure capture symbol must be positive");
                    CheckType(capture.type,
                              "TAC1034",
                              "Core closure capture has an unresolved type");
                    if (capture.mode != CaptureMode::Strong
                        && capture.mode != CaptureMode::Weak
                        && capture.mode != CaptureMode::Unowned)
                        Add("TAC1043",
                            "Core closure capture has an invalid ownership "
                            "mode",
                            capture.symbol.id);
                    if (capture.mode != CaptureMode::Strong
                        && !UsesAarc(capture.type)
                        && capture.type.kind != Type::Kind::Named)
                        Add("TAC1044",
                            "weak or unowned Core capture requires an AARC "
                            "reference value",
                            capture.symbol.id);
                    if (!capture.value)
                    {
                        Add("TAC1035",
                            "Core closure capture value is missing",
                            capture.symbol.id);
                        continue;
                    }
                    VerifyExpression(*capture.value, outerEnvironment);
                    CheckSameType(capture.type,
                                  capture.value->type,
                                  "TAC1036",
                                  "Core closure capture value type does not "
                                  "match its binding",
                                  capture.symbol.id);
                    if (!localSymbols.Insert(capture.symbol.id))
                        Add("TAC1037",
                            "duplicate Core closure local symbol",
                            capture.symbol.id);
                    closureEnvironment.InsertOrAssign(
                        capture.symbol.id,
                        // Captured storage is addressable inside the callable.
                        // Haskell Core verification uses the same mutability
                        // rule; rejecting assignment here split the two TACR
                        // consumers for otherwise identical closure bodies.
                        Definition{ capture.type,
                                    true,
                                    capture.symbol.spelling });
                }

                std::vector<Type> parameterTypes;
                parameterTypes.reserve(expression.closureParameters.size());
                for (const auto &[symbol, type] : expression.closureParameters)
                {
                    CheckSymbol(
                        symbol,
                        "TAC1038",
                        "Core closure parameter symbol must be positive");
                    CheckType(type,
                              "TAC1039",
                              "Core closure parameter has an unresolved type");
                    parameterTypes.push_back(type);
                    if (!localSymbols.Insert(symbol.id))
                        Add("TAC1037",
                            "duplicate Core closure local symbol",
                            symbol.id);
                    closureEnvironment.InsertOrAssign(
                        symbol.id,
                        Definition{ type, false, symbol.spelling });
                }

                const auto expectedType
                    = Type::function(parameterTypes,
                                     expression.closureReturnType);
                CheckSameType(expectedType,
                              expression.type,
                              "TAC1041",
                              "Core closure value type disagrees with its "
                              "parameter and return types");
                VerifyStatements(*expression.closureBody,
                                 closureEnvironment,
                                 expression.closureReturnType,
                                 TransferScope::OutsideLoop);
                if (expression.closureReturnType != Type::unit()
                    && !AlwaysReturns(*expression.closureBody))
                    Add("TAC1042",
                        "non-void Core closure may complete without returning "
                        "a value");
            }
        };
    } // namespace

    auto
    Verify(const Module &module) -> std::vector<VerificationIssue>
    {
        std::vector<VerificationIssue> issues;
        if (module.name.empty()
            || std::ranges::any_of(module.name, [](const auto &part) {
                   return part.empty();
               }))
            issues.push_back(
                { "TAC1001",
                  "Core module name must contain at least one non-empty part",
                  0U,
                  0U });

        std::unordered_set<std::u32string> source_files;
        for (const auto &sourceFile : module.sourceFiles)
        {
            if (!Artifact::IsNormalizedSourcePath(sourceFile))
                issues.push_back({ "TAC1060",
                                   "Core source file must be a normalized, "
                                   "relative .tala path",
                                   0U,
                                   0U });
            if (!source_files.insert(sourceFile).second)
                issues.push_back({ "TAC1061",
                                   "Core source file is listed more than once",
                                   0U,
                                   0U });
        }

        Definitions functions;
        functions.Reserve(module.functions.size());
        for (const auto &function : module.functions)
        {
            if (!function.sourceFile.empty()
                && !Artifact::IsNormalizedSourcePath(function.sourceFile))
                issues.push_back({ "TAC1062",
                                   "Core function owner must be a normalized, "
                                   "relative .tala path",
                                   function.symbol.id,
                                   function.symbol.id });
            if (!module.sourceFiles.empty()
                && !source_files.contains(function.sourceFile))
                issues.push_back({ "TAC1063",
                                   "Core function owner is absent from the "
                                   "module source catalog",
                                   function.symbol.id,
                                   function.symbol.id });
            if (function.symbol.id == 0U)
                issues.push_back({ "TAC1006",
                                   "Core function symbol must be positive",
                                   function.symbol.id,
                                   function.symbol.id });
            const auto functionType = Type::function(
                [&function] {
                    std::vector<Type> types;
                    types.reserve(function.parameters.size());
                    for (const auto &parameter : function.parameters)
                        types.push_back(parameter.type);
                    return types;
                }(),
                function.returnType);
            if (!functions
                     .TryEmplace(function.symbol.id,
                                 Definition{ functionType,
                                             false,
                                             function.symbol.spelling })
                     .inserted)
                issues.push_back({ "TAC1002",
                                   "duplicate Core function symbol",
                                   function.symbol.id,
                                   function.symbol.id });
        }
        for (const auto &function : module.functions)
            FunctionVerifier(function, functions, issues).Run();
        return issues;
    }
} // namespace Progmasoft::Tala::Core
