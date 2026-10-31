// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <cstdlib>
#include <deque>
#include <utility>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"

namespace Progmasoft::Tala::Core::CorePrep
{
    namespace
    {
        namespace Prepared = ::tala::core;

        struct State final
        {
            // One counter names every generated symbol of the module:
            // temporaries, condition and short-circuit slots, and lifted
            // closure functions. It starts above every identity in the
            // whole module and is never reset between functions, because
            // identities are module-wide and a per-function start would
            // reuse another function's symbols.
            SymbolId nextSymbol{ 1U };
            Prepared::BlockId nextBlock{ 1U };
            std::vector<Function> pendingFunctions;
            // Innermost first; every pair stores (break exit, continue target).
            std::vector<std::pair<Prepared::BlockId, Prepared::BlockId>>
                loopTargets;
        };

        /// Lower a Core literal to a CorePrep atom.
        ///
        /// Core still carries fixed-width integer payloads. CorePrep has one
        /// canonical integer form, the sign and magnitude that its wire
        /// reader produces, so the adapter converts here. Without this the
        /// same module compares unequal before and after a wire round trip.
        [[nodiscard]] auto
        LowerLiteral(const Expression &expression) -> Prepared::Atom
        {
            if (const auto *wide
                = std::get_if<std::int64_t>(&expression.literal))
                return Prepared::Atom::constant(
                    Prepared::integer_from_signed(*wide),
                    expression.type);
            if (const auto *narrow
                = std::get_if<std::int32_t>(&expression.literal))
                return Prepared::Atom::constant(
                    Prepared::integer_from_signed(*narrow),
                    expression.type);
            return Prepared::Atom::constant(expression.literal,
                                            expression.type);
        }

        [[nodiscard]] auto
        LowerPrimitive(Primitive primitive) -> Prepared::Operation
        {
            // Both enums intentionally follow the TACR/TACP stable operation
            // order. Keep the explicit switch so a future enum edit cannot
            // silently alter the wire contract.
            switch (primitive)
            {
                case Primitive::Add:
                    return Prepared::Operation::Add;
                case Primitive::Subtract:
                    return Prepared::Operation::Subtract;
                case Primitive::Multiply:
                    return Prepared::Operation::Multiply;
                case Primitive::Divide:
                    return Prepared::Operation::Divide;
                case Primitive::FloorDivide:
                    return Prepared::Operation::FloorDivide;
                case Primitive::Remainder:
                    return Prepared::Operation::Remainder;
                case Primitive::LessThan:
                    return Prepared::Operation::LessThan;
                case Primitive::LessEqual:
                    return Prepared::Operation::LessEqual;
                case Primitive::GreaterThan:
                    return Prepared::Operation::GreaterThan;
                case Primitive::GreaterEqual:
                    return Prepared::Operation::GreaterEqual;
                case Primitive::Equal:
                    return Prepared::Operation::Equal;
                case Primitive::NotEqual:
                    return Prepared::Operation::NotEqual;
                case Primitive::LogicalAnd:
                    return Prepared::Operation::LogicalAnd;
                case Primitive::LogicalOr:
                    return Prepared::Operation::LogicalOr;
                case Primitive::Negate:
                    return Prepared::Operation::Negate;
                case Primitive::LogicalNot:
                    return Prepared::Operation::LogicalNot;
                case Primitive::Power:
                    return Prepared::Operation::Power;
                case Primitive::ShiftLeft:
                    return Prepared::Operation::ShiftLeft;
                case Primitive::ShiftRight:
                    return Prepared::Operation::ShiftRight;
                case Primitive::BitwiseAnd:
                    return Prepared::Operation::BitwiseAnd;
                case Primitive::BitwiseXor:
                    return Prepared::Operation::BitwiseXor;
                case Primitive::BitwiseOr:
                    return Prepared::Operation::BitwiseOr;
                case Primitive::BitwiseNot:
                    return Prepared::Operation::BitwiseNot;
                case Primitive::TypeIs:
                    return Prepared::Operation::TypeIs;
                case Primitive::Memoize:
                    return Prepared::Operation::Memoize;
                case Primitive::RuntimeCall:
                    return Prepared::Operation::RuntimeCall;
            }
            // Reaching this point means the Core enum and adapter diverged.
            // C++20 has no std::unreachable; abort explicitly instead of
            // silently translating an unknown primitive to Copy.
            std::abort();
        }

        /**
         * @brief The block receiving instructions plus every finished block.
         *
         * Expression atomization is not confined to one block: a
         * short-circuit operator ends the current block with a branch and
         * continues in a join block. Threading one cursor through both
         * expressions and statements lets either of them close and reopen
         * blocks without a second lowering path.
         */
        struct Cursor final
        {
            State state;
            Prepared::BlockId block{};
            std::vector<Prepared::Instruction> instructions;
            std::vector<Prepared::Block> closed;
            /// False after a return, break or continue ended the region.
            bool open{ true };

            [[gnu::noinline]] void
            Emit(Prepared::Instruction instruction)
            {
                instructions.push_back(std::move(instruction));
            }

            /// End the current block; no block is open until Open is called.
            [[gnu::noinline]] void
            Close(Prepared::Terminator terminator)
            {
                closed.push_back(
                    { block, std::move(instructions), std::move(terminator) });
                instructions.clear();
                open = false;
            }

            void
            Open(const Prepared::BlockId id)
            {
                block = id;
                instructions.clear();
                open = true;
            }

            [[gnu::noinline]] void
            Jump(const Prepared::BlockId target)
            {
                Close({ Prepared::Terminator::Kind::Jump, {}, target, 0U });
            }

            [[gnu::noinline]] void
            Branch(Prepared::Atom condition,
                   const Prepared::BlockId whenTrue,
                   const Prepared::BlockId whenFalse)
            {
                Close({ Prepared::Terminator::Kind::Branch,
                        std::move(condition),
                        whenTrue,
                        whenFalse });
            }

            [[nodiscard, gnu::noinline]] auto
            Temporary(std::u32string prefix) -> SymbolName
            {
                const auto id = state.nextSymbol++;
                const auto digits = std::to_string(id);
                prefix.append(digits.begin(), digits.end());
                return SymbolName{ id, std::move(prefix) };
            }
        };

        struct OperationResult final
        {
            Prepared::Operation operation{ Prepared::Operation::Copy };
            std::vector<Prepared::Atom> operands;
            SymbolName closureFunction{};
            std::vector<Prepared::Capture> captures;
        };

        // The adapter recurses once per level of nesting, and an
        // instruction, an atom and a type are large. The functions on the
        // recursive paths therefore hold as few of them as they can: every
        // instruction is built by a function of its own, which returns
        // before the next level is entered, and the shapes that nest as
        // deep as an expression is long are walked in a loop.
        [[nodiscard]] auto
        Atomize(Cursor &cursor, const Expression &expression) -> Prepared::Atom;

        [[nodiscard]] auto
        ZeroForBooleanContext(const Type &type) -> Prepared::Atom
        {
            if (Prepared::is_floating(type))
                return Prepared::Atom::constant(
                    Prepared::FloatingLiteral{ "0" },
                    type);
            return Prepared::Atom::constant(Prepared::integer_from_signed(0),
                                            type);
        }

        /// Canonicalize a numeric truth value to `value != 0` in the open
        /// block; a Boolean atom is returned unchanged.
        [[nodiscard, gnu::noinline]] auto
        Booleanize(Cursor &cursor, Prepared::Atom atom) -> Prepared::Atom
        {
            if (atom.type == Type::boolean())
                return atom;
            auto temporary = cursor.Temporary(U"$condition");
            std::vector<Prepared::Atom> operands;
            operands.push_back(std::move(atom));
            operands.push_back(ZeroForBooleanContext(operands.front().type));
            cursor.Emit(Prepared::Instruction{
                Prepared::Instruction::Kind::Bind,
                temporary,
                Type::boolean(),
                false,
                Prepared::Operation::NotEqual,
                std::move(operands),
                {},
                {},
            });
            return Prepared::Atom::variable(std::move(temporary),
                                            Type::boolean());
        }

        [[nodiscard]] auto
        IsShortCircuit(const Expression &expression) -> bool
        {
            return expression.kind == Expression::Kind::Primitive
                   && (expression.primitive == Primitive::LogicalAnd
                       || expression.primitive == Primitive::LogicalOr)
                   && expression.operands.size() == 2U;
        }

        /// Emit an instruction that takes the result of an operation.
        [[gnu::noinline]] void
        EmitOperation(Cursor &cursor,
                      const Prepared::Instruction::Kind kind,
                      const SymbolName &symbol,
                      const Type &type,
                      const bool mutableBinding,
                      OperationResult &operation)
        {
            cursor.Emit(
                Prepared::Instruction{ kind,
                                       symbol,
                                       type,
                                       mutableBinding,
                                       operation.operation,
                                       std::move(operation.operands),
                                       std::move(operation.closureFunction),
                                       std::move(operation.captures) });
        }

        /// Emit a binding or an assignment that copies one atom.
        [[gnu::noinline]] void
        EmitCopy(Cursor &cursor,
                 const Prepared::Instruction::Kind kind,
                 const SymbolName &symbol,
                 const Type &type,
                 const bool mutableBinding,
                 Prepared::Atom value)
        {
            cursor.Emit(Prepared::Instruction{
                kind,
                symbol,
                type,
                mutableBinding,
                Prepared::Operation::Copy,
                { std::move(value) },
                {},
                {},
            });
        }

        /**
         * @brief Lower `&&` and `||` as control flow, not as an eager operator.
         *
         * The right operand is evaluated only on the path that needs it, so
         * its calls, traps and non-termination stay conditional exactly as
         * the source wrote them. The result slot is initialized with the
         * short-circuit value before the branch and overwritten only on the
         * path that evaluates the right operand; every predecessor of the
         * join therefore carries an initialized Boolean without a phi node
         * in CorePrep's storage-oriented form. This matches the Haskell
         * CorePrep lowering.
         *
         * The left operand has been evaluated by the caller, which walks a
         * chain of operators in a loop.
         */
        [[nodiscard, gnu::noinline]] auto
        FinishShortCircuit(Cursor &cursor,
                           const Expression &expression,
                           Prepared::Atom left) -> Prepared::Atom
        {
            const auto isOr = expression.primitive == Primitive::LogicalOr;
            auto condition = Booleanize(cursor, std::move(left));
            auto result = cursor.Temporary(U"$shortcircuit");
            EmitCopy(cursor,
                     Prepared::Instruction::Kind::Bind,
                     result,
                     Type::boolean(),
                     true,
                     Prepared::Atom::constant(Prepared::Literal{ isOr },
                                              Type::boolean()));
            const auto rightId = cursor.state.nextBlock;
            const auto joinId = rightId + 1U;
            cursor.state.nextBlock = joinId + 1U;
            if (isOr)
                cursor.Branch(std::move(condition), joinId, rightId);
            else
                cursor.Branch(std::move(condition), rightId, joinId);

            cursor.Open(rightId);
            EmitCopy(cursor,
                     Prepared::Instruction::Kind::Assign,
                     result,
                     Type::boolean(),
                     false,
                     Booleanize(cursor,
                                Atomize(cursor, expression.operands.back())));
            cursor.Jump(joinId);
            cursor.Open(joinId);
            return Prepared::Atom::variable(std::move(result), Type::boolean());
        }

        [[nodiscard]] auto
        IsConditional(const Expression &expression) -> bool
        {
            return expression.kind == Expression::Kind::Conditional
                   && expression.operands.size() == 3U;
        }

        /// The slot and the join of a conditional expression whose false
        /// arm is being evaluated.
        struct OpenConditional final
        {
            SymbolName result;
            const Type *type;
            Prepared::BlockId joinId;
        };

        /// Evaluate the test and the true arm of a conditional expression
        /// and leave its false block open.
        [[gnu::noinline]] void
        BeginConditional(Cursor &cursor,
                         const Expression &expression,
                         std::vector<OpenConditional> &open)
        {
            auto condition
                = Booleanize(cursor, Atomize(cursor, expression.operands[0]));
            auto result = cursor.Temporary(U"$conditional");
            EmitCopy(cursor,
                     Prepared::Instruction::Kind::Bind,
                     result,
                     expression.type,
                     true,
                     expression.type == Type::boolean()
                         ? Prepared::Atom::constant(Prepared::Literal{ false },
                                                    Type::boolean())
                         : ZeroForBooleanContext(expression.type));
            const auto trueId = cursor.state.nextBlock;
            const auto falseId = trueId + 1U;
            const auto joinId = falseId + 1U;
            cursor.state.nextBlock = joinId + 1U;
            cursor.Branch(std::move(condition), trueId, falseId);

            cursor.Open(trueId);
            EmitCopy(cursor,
                     Prepared::Instruction::Kind::Assign,
                     result,
                     expression.type,
                     false,
                     Atomize(cursor, expression.operands[1]));
            cursor.Jump(joinId);
            cursor.Open(falseId);
            open.push_back({ std::move(result), &expression.type, joinId });
        }

        /// Store the value of the false arm and continue in the join.
        [[nodiscard, gnu::noinline]] auto
        EndConditional(Cursor &cursor,
                       const OpenConditional &conditional,
                       Prepared::Atom value) -> Prepared::Atom
        {
            EmitCopy(cursor,
                     Prepared::Instruction::Kind::Assign,
                     conditional.result,
                     *conditional.type,
                     false,
                     std::move(value));
            cursor.Jump(conditional.joinId);
            cursor.Open(conditional.joinId);
            return Prepared::Atom::variable(conditional.result,
                                            *conditional.type);
        }

        /**
         * @brief Lower a conditional expression to a branch over a slot.
         *
         * Exactly one arm is evaluated. The result slot is bound before
         * the branch with the neutral literal of its type and each arm
         * overwrites it on its own path, so the join block reads an
         * initialized value from either predecessor without a phi node.
         * The neutral value is never observable: no path reaches the join
         * without passing through one of the two assignments.
         *
         * A chain `a ? b : c ? d : e` nests in the false arm of each link.
         * The links are lowered in a loop and their joins are completed
         * from the innermost outwards, which creates the symbols and the
         * blocks in the order of the recursive formulation. That order
         * matches the Haskell CorePrep lowering.
         */
        [[nodiscard, gnu::noinline]] auto
        AtomizeConditional(Cursor &cursor, const Expression &expression)
            -> Prepared::Atom
        {
            std::vector<OpenConditional> open;
            const Expression *current = &expression;
            do
            {
                BeginConditional(cursor, *current, open);
                current = &current->operands[2];
            } while (IsConditional(*current));
            auto value = Atomize(cursor, *current);
            while (!open.empty())
            {
                value = EndConditional(cursor, open.back(), std::move(value));
                open.pop_back();
            }
            return value;
        }

        struct PreparedFunctionResult final
        {
            Prepared::Function function;
            std::vector<Function> pendingFunctions;
            SymbolId nextSymbol{};
        };

        /**
         * @brief The highest symbol identity a function mentions.
         *
         * Every statement and expression of the function is visited once,
         * from a worklist: the scan runs before anything else looks at the
         * function, and a recursive one would use stack in proportion to
         * the nesting of the body and to the length of every chain in it.
         */
        [[nodiscard]] auto
        HighestFunctionSymbol(const Function &function) -> SymbolId
        {
            SymbolId highest = function.symbol.id;
            for (const auto &parameter : function.parameters)
                highest = std::max(highest, parameter.symbol.id);

            std::vector<const Statement *> statements;
            std::vector<const Expression *> expressions;
            const auto addStatements
                = [&statements](const std::vector<Statement> &nested) {
                      for (const auto &statement : nested)
                          statements.push_back(&statement);
                  };
            addStatements(function.body);
            while (!statements.empty() || !expressions.empty())
            {
                if (!expressions.empty())
                {
                    const auto &expression = *expressions.back();
                    expressions.pop_back();
                    if (expression.kind == Expression::Kind::Variable)
                        highest = std::max(highest, expression.symbol.id);
                    if (expression.callee)
                        expressions.push_back(expression.callee.get());
                    for (const auto &operand : expression.operands)
                        expressions.push_back(&operand);
                    for (const auto &capture : expression.captures)
                    {
                        highest = std::max(highest, capture.symbol.id);
                        if (capture.value)
                            expressions.push_back(capture.value.get());
                    }
                    for (const auto &parameter : expression.closureParameters)
                        highest = std::max(highest, parameter.first.id);
                    if (expression.closureBody)
                        addStatements(*expression.closureBody);
                    if (expression.kind == Expression::Kind::Let)
                    {
                        highest = std::max(highest, expression.letSymbol.id);
                        if (expression.letValue)
                            expressions.push_back(expression.letValue.get());
                        if (expression.letBody)
                            expressions.push_back(expression.letBody.get());
                    }
                    continue;
                }
                const auto &statement = *statements.back();
                statements.pop_back();
                if (statement.kind == Statement::Kind::Bind)
                {
                    highest = std::max(highest, statement.binding.symbol.id);
                    expressions.push_back(&statement.binding.value);
                }
                else
                {
                    if (statement.kind == Statement::Kind::Assign)
                        highest = std::max(highest, statement.destination.id);
                    expressions.push_back(&statement.expression);
                }
                addStatements(statement.trueBranch);
                addStatements(statement.falseBranch);
                addStatements(statement.loopBody);
                addStatements(statement.loopUpdate);
            }
            return highest;
        }

        [[nodiscard]] auto
        AtomizeCaptures(Cursor &cursor, const std::vector<Capture> &captures)
            -> std::vector<Prepared::Capture>
        {
            std::vector<Prepared::Capture> prepared;
            prepared.reserve(captures.size());
            for (const auto &capture : captures)
            {
                // Core verification requires the value, but keep this total
                // for direct native API callers as well.
                if (!capture.value)
                    std::abort();
                prepared.push_back(Prepared::Capture{
                    capture.mode,
                    capture.symbol,
                    capture.type,
                    Atomize(cursor, *capture.value),
                });
            }
            return prepared;
        }

        /// The operands of a primitive whose first operand was evaluated.
        [[nodiscard, gnu::noinline]] auto
        PrimitiveOperation(Cursor &cursor,
                           const Expression &expression,
                           Prepared::Atom first) -> OperationResult
        {
            std::vector<Prepared::Atom> operands;
            operands.reserve(expression.operands.size());
            operands.push_back(std::move(first));
            for (std::size_t index = 1U; index < expression.operands.size();
                 ++index)
                operands.push_back(Atomize(cursor, expression.operands[index]));
            if (expression.primitive == Primitive::LogicalAnd
                || expression.primitive == Primitive::LogicalOr
                || expression.primitive == Primitive::LogicalNot)
                for (auto &operand : operands)
                    operand = Booleanize(cursor, std::move(operand));
            return { LowerPrimitive(expression.primitive),
                     std::move(operands),
                     {},
                     {} };
        }

        [[nodiscard, gnu::noinline]] auto
        CallOperation(Cursor &cursor, const Expression &expression)
            -> OperationResult
        {
            std::vector<Prepared::Atom> operands;
            operands.reserve(expression.operands.size() + 1U);
            operands.push_back(Atomize(cursor, *expression.callee));
            for (const auto &argument : expression.operands)
                operands.push_back(Atomize(cursor, argument));
            return { Prepared::Operation::Call, std::move(operands), {}, {} };
        }

        [[nodiscard, gnu::noinline]] auto
        ClosureOperation(Cursor &cursor, const Expression &expression)
            -> OperationResult
        {
            if (!expression.closureBody)
                std::abort();
            const auto closureId = cursor.state.nextSymbol++;
            const auto digits = std::to_string(closureId);
            std::u32string spelling = U"$closure";
            spelling.append(digits.begin(), digits.end());
            SymbolName closureName{ closureId, std::move(spelling) };

            auto captures = AtomizeCaptures(cursor, expression.captures);
            std::vector<Parameter> parameters;
            parameters.reserve(expression.captures.size()
                               + expression.closureParameters.size());
            for (const auto &capture : expression.captures)
                parameters.push_back(Parameter{ capture.symbol, capture.type });
            for (const auto &[symbol, type] : expression.closureParameters)
                parameters.push_back(Parameter{ symbol, type });
            cursor.state.pendingFunctions.push_back(Function{
                closureName,
                std::move(parameters),
                expression.closureReturnType,
                *expression.closureBody,
            });
            return { Prepared::Operation::MakeClosure,
                     {},
                     std::move(closureName),
                     std::move(captures) };
        }

        [[nodiscard, gnu::noinline]] auto
        CopyOperation(Prepared::Atom atom) -> OperationResult
        {
            return { Prepared::Operation::Copy, { std::move(atom) }, {}, {} };
        }

        [[nodiscard, gnu::noinline]] auto
        AtomizeOperation(Cursor &cursor, const Expression &expression)
            -> OperationResult
        {
            if (expression.kind == Expression::Kind::Let
                || IsShortCircuit(expression) || IsConditional(expression))
                return CopyOperation(Atomize(cursor, expression));
            if (expression.kind == Expression::Kind::Variable)
                return CopyOperation(Prepared::Atom::variable(expression.symbol,
                                                              expression.type));
            if (expression.kind == Expression::Kind::Literal)
                return CopyOperation(LowerLiteral(expression));
            if (expression.kind == Expression::Kind::Apply)
                return CallOperation(cursor, expression);
            if (expression.kind == Expression::Kind::Closure)
                return ClosureOperation(cursor, expression);
            if (expression.operands.empty())
                return { LowerPrimitive(expression.primitive), {}, {}, {} };
            return PrimitiveOperation(
                cursor,
                expression,
                Atomize(cursor, expression.operands.front()));
        }

        /// Bind the result of an operation to a fresh temporary.
        [[nodiscard, gnu::noinline]] auto
        BindTemporary(Cursor &cursor,
                      const Type &type,
                      OperationResult &operation) -> Prepared::Atom
        {
            auto temporary = cursor.Temporary(U"$coreprep");
            EmitOperation(cursor,
                          Prepared::Instruction::Kind::Bind,
                          temporary,
                          type,
                          false,
                          operation);
            return Prepared::Atom::variable(std::move(temporary), type);
        }

        /// Bind the value of a let expression; its body follows.
        [[gnu::noinline]] void
        BindLet(Cursor &cursor, const Expression &expression)
        {
            if (!expression.letValue || !expression.letBody)
                std::abort();
            // The bound value keeps its own operation, as in the Haskell
            // lowering; an intermediate temporary would make the two
            // adapters disagree on every non-atomic value.
            auto value = AtomizeOperation(cursor, *expression.letValue);
            EmitOperation(cursor,
                          Prepared::Instruction::Kind::Bind,
                          expression.letSymbol,
                          expression.letType,
                          false,
                          value);
        }

        /// An expression that is not walked in a loop.
        [[nodiscard, gnu::noinline]] auto
        AtomizeLeaf(Cursor &cursor, const Expression &expression)
            -> Prepared::Atom
        {
            if (expression.kind == Expression::Kind::Variable)
                return Prepared::Atom::variable(expression.symbol,
                                                expression.type);
            if (expression.kind == Expression::Kind::Literal)
                return LowerLiteral(expression);
            if (expression.kind == Expression::Kind::Let)
                return Atomize(cursor, expression);
            if (expression.kind == Expression::Kind::Conditional)
            {
                // Core verification requires three operands, but keep this
                // total for direct native API callers as well.
                if (!IsConditional(expression))
                    std::abort();
                return AtomizeConditional(cursor, expression);
            }
            auto operation = AtomizeOperation(cursor, expression);
            return BindTemporary(cursor, expression.type, operation);
        }

        /// A primitive from the atom of its first operand.
        [[nodiscard, gnu::noinline]] auto
        CompleteFirstOperand(Cursor &cursor,
                             const Expression &expression,
                             Prepared::Atom first) -> Prepared::Atom
        {
            if (IsShortCircuit(expression))
                return FinishShortCircuit(cursor, expression, std::move(first));
            auto operation
                = PrimitiveOperation(cursor, expression, std::move(first));
            return BindTemporary(cursor, expression.type, operation);
        }

        /**
         * @brief Evaluate an expression into the open block and return the
         * atom that holds its value.
         *
         * A sequence of bindings nests in the body of each let, and a chain
         * of operators in the first operand of each primitive. Both are
         * walked in a loop: the bindings are emitted in order, and the
         * primitives are completed from the innermost outwards once their
         * first operand has a value. The instructions, the symbols and the
         * blocks are created in the order of the recursive formulation.
         */
        [[nodiscard, gnu::noinline]] auto
        Atomize(Cursor &cursor, const Expression &expression) -> Prepared::Atom
        {
            const Expression *current = &expression;
            while (current->kind == Expression::Kind::Let)
            {
                BindLet(cursor, *current);
                current = current->letBody.get();
            }
            std::vector<const Expression *> chain;
            while (current->kind == Expression::Kind::Primitive
                   && !current->operands.empty())
            {
                chain.push_back(current);
                current = &current->operands.front();
            }
            auto atom = AtomizeLeaf(cursor, *current);
            while (!chain.empty())
            {
                atom = CompleteFirstOperand(cursor,
                                            *chain.back(),
                                            std::move(atom));
                chain.pop_back();
            }
            return atom;
        }

        void
        PrepareStatements(Cursor &cursor,
                          const std::vector<Statement> &statements);

        /**
         * @brief Prepare one loop region with a scoped transfer-target pair.
         *
         * The region starts in a fresh block. While it is built, `break`
         * jumps to breakTarget and `continue` to continueTarget; the
         * enclosing pair is restored afterwards, so an inner transfer
         * cannot target an outer loop. A region that is still open at its
         * end jumps to fallthroughTarget.
         *
         * The fallthrough successor is a separate argument because it is
         * not always the `continue` target: a for-loop update region is
         * entered by `continue` but must fall through to the condition.
         * Reusing the continue target there makes the region branch to
         * itself and never re-test the loop condition.
         */
        void
        PrepareLoopRegion(Cursor &cursor,
                          const Prepared::BlockId startId,
                          const Prepared::BlockId breakTarget,
                          const Prepared::BlockId continueTarget,
                          const Prepared::BlockId fallthroughTarget,
                          const std::vector<Statement> &statements)
        {
            cursor.state.loopTargets.emplace_back(breakTarget, continueTarget);
            cursor.Open(startId);
            PrepareStatements(cursor, statements);
            if (cursor.open)
                cursor.Jump(fallthroughTarget);
            cursor.state.loopTargets.pop_back();
        }

        /// Evaluate a loop or branch condition in the open block and branch
        /// on its Boolean atom. Short-circuit operands may leave a different
        /// block open than the one the condition started in.
        [[gnu::noinline]] void
        BranchOnCondition(Cursor &cursor,
                          const Expression &condition,
                          const Prepared::BlockId whenTrue,
                          const Prepared::BlockId whenFalse)
        {
            cursor.Branch(Booleanize(cursor, Atomize(cursor, condition)),
                          whenTrue,
                          whenFalse);
        }

        /// Evaluate the condition of an `if`, then take three consecutive
        /// block identities for its true branch, its false branch and its
        /// join, and branch. Returns the first of the three. The condition
        /// comes first because it may create blocks of its own.
        [[nodiscard, gnu::noinline]] auto
        BranchToNewBlocks(Cursor &cursor, const Expression &condition)
            -> Prepared::BlockId
        {
            auto atom = Booleanize(cursor, Atomize(cursor, condition));
            const auto trueId = cursor.state.nextBlock;
            cursor.state.nextBlock = trueId + 3U;
            cursor.Branch(std::move(atom), trueId, trueId + 1U);
            return trueId;
        }

        void
        PrepareBranchRegion(Cursor &cursor,
                            const Prepared::BlockId startId,
                            const Prepared::BlockId joinId,
                            const std::vector<Statement> &statements)
        {
            cursor.Open(startId);
            PrepareStatements(cursor, statements);
            if (cursor.open)
                cursor.Jump(joinId);
        }

        /**
         * @brief Prepare an `if` and every `else if` that continues it.
         *
         * An `else if` reaches Core as a false branch that holds exactly
         * one nested `if`. Preparing such a chain by recursion uses stack
         * in proportion to its length, and a long chain in valid source
         * would overflow it, so the links are prepared in a loop.
         *
         * The blocks are created, numbered and closed exactly as the
         * recursive formulation would: each link takes three consecutive
         * block identities for its true branch, its false branch and its
         * join; a false branch that only holds the next link opens that
         * link in the false block; and when the last link is done, the
         * joins are completed from the innermost outwards, each enclosing
         * false branch falling through to its own join. Both CorePrep
         * lowerings are compared block by block, so this order is part of
         * the contract.
         */
        [[gnu::noinline]] void
        PrepareConditionalChain(Cursor &cursor, const Statement &first)
        {
            std::vector<Prepared::BlockId> joins;
            const Statement *link = &first;
            for (;;)
            {
                const auto trueId = BranchToNewBlocks(cursor, link->expression);
                const auto falseId = trueId + 1U;
                const auto joinId = falseId + 1U;
                PrepareBranchRegion(cursor, trueId, joinId, link->trueBranch);
                joins.push_back(joinId);
                const auto continues
                    = link->falseBranch.size() == 1U
                      && link->falseBranch.front().kind == Statement::Kind::If;
                if (!continues)
                {
                    PrepareBranchRegion(cursor,
                                        falseId,
                                        joinId,
                                        link->falseBranch);
                    break;
                }
                // The false branch is the next link: it starts in the false
                // block, and its own join is completed before this one.
                cursor.Open(falseId);
                link = &link->falseBranch.front();
            }
            cursor.Open(joins.back());
            joins.pop_back();
            while (!joins.empty())
            {
                // The end of an enclosing false branch: fall through to its
                // join when the inner join is reachable, then continue there.
                if (cursor.open)
                    cursor.Jump(joins.back());
                cursor.Open(joins.back());
                joins.pop_back();
            }
        }

        [[gnu::noinline]] void
        PrepareBinding(Cursor &cursor, const Statement &statement)
        {
            auto operation = AtomizeOperation(cursor, statement.binding.value);
            EmitOperation(cursor,
                          Prepared::Instruction::Kind::Bind,
                          statement.binding.symbol,
                          statement.binding.type,
                          statement.binding.mutableBinding,
                          operation);
        }

        [[gnu::noinline]] void
        PrepareAssignment(Cursor &cursor, const Statement &statement)
        {
            EmitCopy(cursor,
                     Prepared::Instruction::Kind::Assign,
                     statement.destination,
                     statement.expression.type,
                     false,
                     Atomize(cursor, statement.expression));
        }

        [[gnu::noinline]] void
        PrepareEvaluation(Cursor &cursor, const Statement &statement)
        {
            // Only a call may be an instruction whose result is dropped:
            // the record has no result type on the wire, and a reader
            // recovers it from the callee. Any other value is computed
            // into an ordinary temporary, so its operands still run and
            // may trap, and the unused atom is ignored.
            if (statement.expression.kind != Expression::Kind::Apply)
            {
                static_cast<void>(Atomize(cursor, statement.expression));
                return;
            }
            auto operation = AtomizeOperation(cursor, statement.expression);
            EmitOperation(cursor,
                          Prepared::Instruction::Kind::Evaluate,
                          {},
                          statement.expression.type,
                          false,
                          operation);
        }

        [[gnu::noinline]] void
        PrepareReturn(Cursor &cursor, const Statement &statement)
        {
            cursor.Close({ Prepared::Terminator::Kind::Return,
                           Atomize(cursor, statement.expression),
                           0U,
                           0U });
        }

        [[gnu::noinline]] void
        PrepareTransfer(Cursor &cursor, const Statement &statement)
        {
            // Core verification rejects a transfer outside a loop; stay
            // total for direct native API callers.
            if (cursor.state.loopTargets.empty())
            {
                cursor.Close(
                    { Prepared::Terminator::Kind::Unreachable, {}, 0U, 0U });
                return;
            }
            const auto targets = cursor.state.loopTargets.back();
            cursor.Jump(statement.kind == Statement::Kind::Break
                            ? targets.first
                            : targets.second);
        }

        [[gnu::noinline]] void
        PrepareWhile(Cursor &cursor, const Statement &statement)
        {
            // The condition owns a dedicated header block. Folding it into
            // the incoming block would make the back-edge re-execute every
            // straight-line statement that precedes the loop, including the
            // initializers it tests.
            const auto conditionId = cursor.state.nextBlock;
            const auto bodyId = conditionId + 1U;
            const auto exitId = bodyId + 1U;
            cursor.state.nextBlock = exitId + 1U;

            cursor.Jump(conditionId);
            cursor.Open(conditionId);
            BranchOnCondition(cursor, statement.expression, bodyId, exitId);
            PrepareLoopRegion(cursor,
                              bodyId,
                              exitId,
                              conditionId,
                              conditionId,
                              statement.loopBody);
            cursor.Open(exitId);
        }

        [[gnu::noinline]] void
        PrepareDoWhile(Cursor &cursor, const Statement &statement)
        {
            const auto bodyId = cursor.state.nextBlock;
            const auto conditionId = bodyId + 1U;
            const auto exitId = conditionId + 1U;
            cursor.state.nextBlock = exitId + 1U;

            cursor.Jump(bodyId);
            PrepareLoopRegion(cursor,
                              bodyId,
                              exitId,
                              conditionId,
                              conditionId,
                              statement.loopBody);
            cursor.Open(conditionId);
            BranchOnCondition(cursor, statement.expression, bodyId, exitId);
            cursor.Open(exitId);
        }

        [[gnu::noinline]] void
        PrepareFor(Cursor &cursor, const Statement &statement)
        {
            const auto conditionId = cursor.state.nextBlock;
            const auto bodyId = conditionId + 1U;
            const auto updateId = bodyId + 1U;
            const auto exitId = updateId + 1U;
            cursor.state.nextBlock = exitId + 1U;

            cursor.Jump(conditionId);
            cursor.Open(conditionId);
            // A numeric condition's canonicalizing comparison is part of
            // the header and is re-evaluated each pass.
            BranchOnCondition(cursor, statement.expression, bodyId, exitId);
            PrepareLoopRegion(cursor,
                              bodyId,
                              exitId,
                              updateId,
                              updateId,
                              statement.loopBody);
            // `continue` enters the update region; the region itself then
            // returns to the condition, never to its own entry.
            PrepareLoopRegion(cursor,
                              updateId,
                              exitId,
                              updateId,
                              conditionId,
                              statement.loopUpdate);
            cursor.Open(exitId);
        }

        /**
         * @brief Append structured statements to the cursor's open block.
         *
         * On return the cursor is either still open, meaning control falls
         * through to whatever the caller places next, or closed by a
         * return, break or continue, after which the remaining statements
         * of the region are unreachable and are not lowered.
         */
        void
        PrepareStatements(Cursor &cursor,
                          const std::vector<Statement> &statements)
        {
            for (const auto &statement : statements)
            {
                switch (statement.kind)
                {
                    case Statement::Kind::Bind:
                        PrepareBinding(cursor, statement);
                        break;
                    case Statement::Kind::Assign:
                        PrepareAssignment(cursor, statement);
                        break;
                    case Statement::Kind::Evaluate:
                        PrepareEvaluation(cursor, statement);
                        break;
                    case Statement::Kind::Return:
                        PrepareReturn(cursor, statement);
                        return;
                    case Statement::Kind::Break:
                    case Statement::Kind::Continue:
                        PrepareTransfer(cursor, statement);
                        return;
                    case Statement::Kind::While:
                        PrepareWhile(cursor, statement);
                        break;
                    case Statement::Kind::DoWhile:
                        PrepareDoWhile(cursor, statement);
                        break;
                    case Statement::Kind::For:
                        PrepareFor(cursor, statement);
                        break;
                    case Statement::Kind::If:
                        PrepareConditionalChain(cursor, statement);
                        break;
                }
            }
        }

        [[nodiscard]] auto
        PrepareFunction(const Function &function, SymbolId nextSymbol)
            -> PreparedFunctionResult
        {
            std::vector<Prepared::Parameter> parameters;
            parameters.reserve(function.parameters.size());
            for (const auto &parameter : function.parameters)
            {
                parameters.push_back({ parameter.symbol, parameter.type });
            }
            Cursor cursor{ State{ nextSymbol, 1U, {}, {} }, 0U, {}, {}, true };
            PrepareStatements(cursor, function.body);
            // A function without a result may end without a return:
            // reaching the end of its body returns. For a function with a
            // result Core verification proves every path returns, so a body
            // that still falls off its end is marked instead of given an
            // invented value.
            if (cursor.open)
            {
                if (function.returnType.kind == Prepared::Type::Kind::Unit)
                    cursor.Close(
                        { Prepared::Terminator::Kind::Return,
                          Prepared::Atom::constant(Prepared::Literal{},
                                                   Prepared::Type::unit()),
                          0U,
                          0U });
                else
                    cursor.Close({ Prepared::Terminator::Kind::Unreachable,
                                   {},
                                   0U,
                                   0U });
            }
            return {
                Prepared::Function{ function.symbol,
                                    std::move(parameters),
                                    function.returnType,
                                    0U,
                                    std::move(cursor.closed) },
                std::move(cursor.state.pendingFunctions),
                cursor.state.nextSymbol,
            };
        }
    } // namespace

    auto
    Prepare(const Module &module) -> ::tala::core::CorePrepModule
    {
        ::tala::core::CorePrepModule prepared{ module.name,
                                               {},
                                               module.sourceFiles };
        // The queue refers to the functions of the module instead of copying
        // them: a copy would duplicate every statement of the program, and
        // copying nested statements recurses once per level of nesting.
        // Lifted closure bodies are owned by a deque, whose elements keep
        // their addresses while the queue grows.
        std::deque<Function> lifted;
        std::vector<std::pair<const Function *, std::u32string>> pending;
        pending.reserve(module.functions.size());
        for (const auto &function : module.functions)
            pending.emplace_back(&function, function.sourceFile);
        // Lifted closure bodies only mention identities already counted
        // here or generated by the shared counter, so the seed stays valid
        // for functions appended to the queue later.
        SymbolId nextSymbol = 1U;
        for (const auto &[function, _] : pending)
            nextSymbol
                = std::max(nextSymbol, HighestFunctionSymbol(*function) + 1U);

        // Closure bodies are lifted as ordinary Core functions and fed back
        // through the same work queue. This naturally handles nested closures
        // without adding a second, subtly different lowering implementation.
        for (std::size_t index = 0U; index < pending.size(); ++index)
        {
            auto result = PrepareFunction(*pending[index].first, nextSymbol);
            result.function.sourceFile = pending[index].second;
            prepared.functions.push_back(std::move(result.function));
            nextSymbol = result.nextSymbol;
            for (auto &function : result.pendingFunctions)
            {
                lifted.push_back(std::move(function));
                // Copy the owner's path first: growing the queue may move
                // the element it is read from.
                auto sourceFile = pending[index].second;
                pending.emplace_back(&lifted.back(), std::move(sourceFile));
            }
        }
        return prepared;
    }
} // namespace Progmasoft::Tala::Core::CorePrep
