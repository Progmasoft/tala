-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Pure building blocks for lowering expressions that store into locals.

Core expressions never write a local: only 'CoreAssign' and 'CoreBind'
statements do, and every Core optimization relies on that. A source
expression such as @a = b@, @a += b@ or @a++@ therefore lowers to a pair: the
statements that perform its stores, and a store-free expression that reads
the result. This module holds the rules for combining such pairs without
changing what the source observes:

* an operand evaluated before a later store must not see that store;
* an operand that is evaluated lazily keeps its stores lazy;
* a loop condition that stores does so on every test of the condition.
-}
module Progmasoft.Tala.Desugarer.Sequencing
    ( Lowered
    , assignedSymbols
    , survives
    , neutralValue
    , exitUnless
    , whileLoop
    , forLoop
    , doWhileLoop
    , selectInto
    , decideLogical
    ) where

import Progmasoft.Tala.AST (ResolvedName (..), SymbolId, Type, boolType, stringType)
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Scalar (isCoreFloatingType)

{- | Statements that must run before an expression, and the expression.

The statements are in execution order. The expression contains no store; it
is valid only after the statements have run, and it stays valid until one of
the locals it reads is assigned again.
-}
type Lowered = ([CoreStatement], CoreExpression)

{- | Every local that the statements may assign, at any nesting depth.

Bindings are not listed: a binding introduces a fresh symbol, which no
earlier expression can have read. Closure bodies are not entered either. A
closure captures by value when it is created, so a store inside its body
changes the closure's own copy and not the local of the enclosing function.
-}
assignedSymbols :: [CoreStatement] -> [SymbolId]
assignedSymbols = concatMap assigned
    where
        assigned statement = case statement of
            CoreAssign name _ -> [resolvedSymbol name]
            CoreIf _ whenTrue whenFalse -> assignedSymbols whenTrue ++ assignedSymbols whenFalse
            CoreWhile _ body -> assignedSymbols body
            CoreDoWhile body _ -> assignedSymbols body
            CoreFor _ body update -> assignedSymbols body ++ assignedSymbols update
            CoreBind _ -> []
            CoreReturn _ -> []
            CoreEvaluate _ -> []
            CoreBreak -> []
            CoreContinue -> []

{- | Whether an already evaluated operand still has its value after statements
that assign the given locals have run.

A literal always does. A plain read of a local does unless that local is
assigned. Anything else is a computation whose evaluation order relative to
the later statements is observable, through a call, a trap or a read, so it
does not survive and must be bound first.
-}
survives :: [SymbolId] -> CoreExpression -> Bool
survives assigned expression = case expression of
    CoreLiteral _ _ -> True
    CoreVariable name _ -> resolvedSymbol name `notElem` assigned
    _ -> False

{- | Initial value of a result slot that every path assigns before it is read.

The value is never observed; it only gives the slot a well-typed
initializer. It is spelled as CorePrep spells its own neutral slot value.
-}
neutralValue :: Type -> CoreExpression
neutralValue valueType
    | valueType == boolType = CoreLiteral (CoreBoolean False) valueType
    | isCoreFloatingType valueType = CoreLiteral (CoreFloating "0") valueType
    | valueType == stringType = CoreLiteral (CoreString "") valueType
    | otherwise = CoreLiteral (CoreInteger 0) valueType

-- | Leave the innermost loop unless the condition holds.
exitUnless :: CoreExpression -> CoreStatement
exitUnless condition = CoreIf condition [] [CoreBreak]

alwaysTrue :: CoreExpression
alwaysTrue = CoreLiteral (CoreBoolean True) boolType

{- | A @while@ loop whose condition has statements of its own.

Without such statements this is the plain Core loop. With them the condition
moves to the top of the body, where its statements run before every test,
including the test that follows @continue@.
-}
whileLoop :: Lowered -> [CoreStatement] -> CoreStatement
whileLoop ([], condition) body = CoreWhile condition body
whileLoop (prefix, condition) body = CoreWhile alwaysTrue (prefix ++ [exitUnless condition] ++ body)

{- | A @for@ loop whose condition has statements of its own.

The update clause stays in the loop's update position, so @continue@ still
runs the update and then the condition statements.
-}
forLoop :: Lowered -> [CoreStatement] -> [CoreStatement] -> CoreStatement
forLoop ([], condition) body update = CoreFor condition body update
forLoop (prefix, condition) body update = CoreFor alwaysTrue (prefix ++ [exitUnless condition] ++ body) update

{- | A @do@/@while@ loop whose condition has statements of its own.

The body runs once before the first test, and @continue@ must reach the
test. Both hold when the test sits at the top of an unconditional loop and
is skipped on the first pass only, which the given fresh flag records.
-}
doWhileLoop :: ResolvedName -> [CoreStatement] -> Lowered -> [CoreStatement]
doWhileLoop _ body ([], condition) = [CoreDoWhile body condition]
doWhileLoop first body (prefix, condition) =
    [ CoreBind (CoreBinding first boolType True alwaysTrue)
    , CoreWhile
        alwaysTrue
        ( CoreIf
            (CoreVariable first boolType)
            [CoreAssign first (CoreLiteral (CoreBoolean False) boolType)]
            (prefix ++ [exitUnless condition])
            : body
        )
    ]

{- | Evaluate exactly one of two lowered arms into a fresh result slot.

This is the statement form of a conditional expression. It is used when an
arm has statements of its own, which must run only if that arm is selected.
-}
selectInto :: ResolvedName -> Type -> CoreExpression -> Lowered -> Lowered -> Lowered
selectInto result valueType condition (firstPrefix, first) (secondPrefix, second) =
    (
        [ CoreBind (CoreBinding result valueType True (neutralValue valueType))
        , CoreIf
            condition
            (firstPrefix ++ [CoreAssign result first])
            (secondPrefix ++ [CoreAssign result second])
        ]
    , CoreVariable result valueType
    )

{- | Statement form of a short-circuit operator whose right operand has
statements of its own.

The right operand and its statements run only when the left operand does not
decide the result. The result is a Boolean slot; the operands are tested in
Boolean context and are never stored into it, so they may be numeric.
-}
decideLogical :: Bool -> ResolvedName -> CoreExpression -> Lowered -> Lowered
decideLogical isConjunction result left (rightPrefix, right) =
    (
        [ CoreBind (CoreBinding result boolType True (CoreLiteral (CoreBoolean False) boolType))
        , if isConjunction
            then CoreIf left testRight []
            else CoreIf left [setTrue] testRight
        ]
    , CoreVariable result boolType
    )
    where
        setTrue = CoreAssign result alwaysTrue
        testRight = rightPrefix ++ [CoreIf right [setTrue] []]
