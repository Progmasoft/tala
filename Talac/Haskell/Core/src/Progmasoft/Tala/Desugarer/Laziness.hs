-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | What the lowering needs to know to evaluate a value by need.

Tala is a lazy language: a value is computed when it is first needed and
at most once, and a value that is never needed is never computed. Its effects
are not lazy: a store into a variable and a transfer of control happen where
they are written. The source has no notation for either fact; the compiler
tells the two kinds of expression apart.

This module holds that distinction for the initializer of a local binding.
An initializer may be deferred when evaluating it later gives what evaluating
it now would give: it stores nothing, transfers nowhere, and reads the
variables it names as they are where the binding stands. Deferring it is
observable only when it might fail or never return, so only then is it worth
a flag and a test at every use.
-}
module Progmasoft.Tala.Desugarer.Laziness
    ( deferrableExpression
    , worthDeferring
    , expressionNames
    , renameNames
    , capturedSymbols
    , ArgumentNeeds
    , alwaysReads
    , neededTwice
    , neededNext
    ) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core

{- | Whether evaluating an expression at a later point of the same function
gives the value that evaluating it in place would give, provided the
variables it reads still have the values they had.

That holds for expressions built from names, literals, operators, tests and
calls: a call cannot store into a local of its caller. It does not hold for
an expression that stores, that leaves, or that contains statements.
-}
deferrableExpression :: Expression name annotation -> Bool
deferrableExpression expression = case expression of
    NameExpression {} -> True
    LiteralExpression {} -> True
    MemberAccessExpression _ receiver _ _ -> deferrableExpression receiver
    MethodReferenceExpression _ receiver _ _ -> deferrableExpression receiver
    CallExpression _ callee arguments _ -> all deferrableExpression (callee : arguments)
    UnaryExpression _ _ value _ -> deferrableExpression value
    BinaryExpression _ _ left right _ -> deferrableExpression left && deferrableExpression right
    IsPatternExpression _ subject _ _ -> deferrableExpression subject
    ConditionalExpression _ condition first second _ -> all deferrableExpression [condition, first, second]
    CoalesceExpression {} -> False
    AssignmentExpression {} -> False
    IncrementExpression {} -> False
    LoopExpression {} -> False
    BlockExpression {} -> False
    MatchExpression {} -> False
    CallableExpression {} -> False

{- | Whether an expression can fail or never return, which is when it matters
whether it is evaluated at all: it calls something, or it divides.
-}
worthDeferring :: Expression name annotation -> Bool
worthDeferring expression = case expression of
    CallExpression {} -> True
    BinaryExpression _ operator left right _ ->
        operator `elem` [Divide, FloorDivide, Remainder] || worthDeferring left || worthDeferring right
    MemberAccessExpression _ receiver _ _ -> worthDeferring receiver
    MethodReferenceExpression _ receiver _ _ -> worthDeferring receiver
    UnaryExpression _ _ value _ -> worthDeferring value
    IsPatternExpression _ subject _ _ -> worthDeferring subject
    ConditionalExpression _ condition first second _ -> any worthDeferring [condition, first, second]
    _ -> False

-- | The names an expression that may be deferred reads, with their types.
expressionNames :: Expression name annotation -> [(name, annotation)]
expressionNames expression = [(name, annotation) | NameExpression _ name annotation <- nameReads expression]

{- | The reads of a name in an expression that may be deferred, in the order
they are written.

The reads are gathered in front of the ones that follow them. Appending the
reads of a right operand to those of a left one would copy the reads of a
chain of operators once for each operator of the chain.
-}
nameReads :: Expression name annotation -> [Expression name annotation]
nameReads expression = collect expression []
    where
        collect value following = case value of
            NameExpression {} -> value : following
            MemberAccessExpression _ receiver _ _ -> collect receiver following
            MethodReferenceExpression _ receiver _ _ -> collect receiver following
            CallExpression _ callee arguments _ -> foldr collect following (callee : arguments)
            UnaryExpression _ _ operand _ -> collect operand following
            BinaryExpression _ _ left right _ -> collect left (collect right following)
            IsPatternExpression _ subject _ _ -> collect subject following
            ConditionalExpression _ condition first second _ -> foldr collect following [condition, first, second]
            _ -> following

{- | Replace the names an expression that may be deferred reads. A name that
has no replacement is kept.
-}
renameNames :: (name -> name) -> Expression name annotation -> Expression name annotation
renameNames rename expression = case expression of
    NameExpression spanValue name annotation -> NameExpression spanValue (rename name) annotation
    MemberAccessExpression spanValue receiver member annotation ->
        MemberAccessExpression spanValue (renameNames rename receiver) member annotation
    MethodReferenceExpression spanValue receiver member annotation ->
        MethodReferenceExpression spanValue (renameNames rename receiver) member annotation
    CallExpression spanValue callee arguments annotation ->
        CallExpression spanValue (renameNames rename callee) (map (renameNames rename) arguments) annotation
    UnaryExpression spanValue operator value annotation ->
        UnaryExpression spanValue operator (renameNames rename value) annotation
    BinaryExpression spanValue operator left right annotation ->
        BinaryExpression spanValue operator (renameNames rename left) (renameNames rename right) annotation
    IsPatternExpression spanValue subject patternValue annotation ->
        IsPatternExpression spanValue (renameNames rename subject) patternValue annotation
    ConditionalExpression spanValue condition first second annotation ->
        ConditionalExpression
            spanValue
            (renameNames rename condition)
            (renameNames rename first)
            (renameNames rename second)
            annotation
    _ -> expression

{- | For the name of a method whose parameters may be passed by need, which
of them are, in declaration order; nothing for any other name. A call of
such a method does not read an argument it passes by need: the method may
never need it.
-}
type ArgumentNeeds name = name -> Maybe [Bool]

{- | Whether evaluating an expression always reads the given name, whatever
values it meets: the name stands where neither a short-circuit operator, nor
a conditional, nor a parameter that is passed by need can skip it. Blocks,
matches, loops and callables used as values are not searched; the answer for
them is that it is not known.
-}
alwaysReads :: (Eq name) => ArgumentNeeds name -> name -> Expression name annotation -> Bool
alwaysReads needs name expression = case expression of
    NameExpression _ found _ -> found == name
    MemberAccessExpression _ receiver _ _ -> always receiver
    MethodReferenceExpression _ receiver _ _ -> always receiver
    CallExpression _ (NameExpression _ callee _) arguments _
        | Just flags <- needs callee
        , length flags == length arguments ->
            any always [argument | (False, argument) <- zip flags arguments]
    CallExpression _ callee arguments _ -> any always (callee : arguments)
    UnaryExpression _ _ value _ -> always value
    BinaryExpression _ operator left right _
        | operator `elem` [LogicalAnd, LogicalOr] -> always left
        | otherwise -> always left || always right
    IsPatternExpression _ subject _ _ -> always subject
    ConditionalExpression _ condition _ _ _ -> always condition
    AssignmentExpression _ _ _ value _ -> always value
    _ -> False
    where
        always = alwaysReads needs name

{- | The reads of the given values by need that an expression is certain to
evaluate and holds more than once, one read for each such value.

Computing those values ahead of the expression changes nothing that can be
observed except which of two computations fails first when both fail: the
expression has no effect, and it evaluates each of them whenever it is
evaluated.
-}
neededTwice ::
    ArgumentNeeds ResolvedName ->
    [SymbolId] ->
    Expression ResolvedName annotation ->
    [(ResolvedName, Expression ResolvedName annotation)]
neededTwice needs deferred expression
    | null deferred || not (deferrableExpression expression) = []
    | otherwise = go Set.empty namesRead
    where
        namesRead = [(name, found) | found@(NameExpression _ name _) <- nameReads expression]
        byNeed = Set.fromList deferred
        -- How often each value by need is read. Looking for a second read
        -- among the reads that follow would walk them for every name.
        counts = Map.fromListWith (+) [(symbol, 1 :: Int) | (name, _) <- namesRead, let symbol = resolvedSymbol name, Set.member symbol byNeed]
        go _ [] = []
        go seen ((name, found) : remaining)
            | Set.member symbol seen = go seen remaining
            | Map.findWithDefault 0 symbol counts > 1
            , alwaysReads needs name expression =
                (name, found) : go (Set.insert symbol seen) remaining
            | otherwise = go (Set.insert symbol seen) remaining
            where
                symbol = resolvedSymbol name

{- | Whether the statement that follows a binding is certain to read it.

A value that is certain to be needed by the very next statement may be
computed where its binding stands: nothing can be observed between the two
places except which of two computations fails first when both fail. That
saves the flag and the test for the common case of a value that is used at
once.

The next statement reads the name for certain when the expression it
evaluates first always reads it. A binding evaluates its initializer first
only when it is itself evaluated in place, which the second argument
decides for it from the statements after it.
-}
neededNext ::
    (Eq name) =>
    ArgumentNeeds name ->
    -- | Whether a later binding is evaluated in place, given what follows it.
    (name -> annotation -> Expression name annotation -> [Statement name annotation] -> Bool) ->
    name ->
    [Statement name annotation] ->
    Bool
neededNext needs inPlaceBinding name following = case following of
    next : later -> case next of
        BindingStatement _ _ _ bound annotation value ->
            always value && inPlaceBinding bound annotation value later
        AssignmentStatement _ _ _ value -> always value
        CompoundAssignmentStatement _ _ _ _ value -> always value
        ReturnStatement _ (Just value) -> always value
        IfStatement _ condition _ _ -> always condition
        GuardStatement _ condition _ -> always condition
        WhileStatement _ condition _ -> always condition
        DiscardStatement _ value -> always value
        ExpressionStatement _ value _ -> always value
        _ -> False
    [] -> False
    where
        always = alwaysReads needs name

{- | Every local that a closure created by the statements captures, at any
depth. A closure takes the value of a capture when it is created, so a
binding that a closure captures has to have its value by then.
-}
capturedSymbols :: [CoreStatement] -> [SymbolId]
capturedSymbols = concatMap statement
    where
        statement value = case value of
            CoreBind binding -> expression (coreBindingValue binding)
            CoreAssign _ assigned -> expression assigned
            CoreReturn returned -> expression returned
            CoreEvaluate evaluated -> expression evaluated
            CoreIf condition whenTrue whenFalse -> expression condition ++ capturedSymbols whenTrue ++ capturedSymbols whenFalse
            CoreWhile condition body -> expression condition ++ capturedSymbols body
            CoreDoWhile body condition -> capturedSymbols body ++ expression condition
            CoreFor condition body update -> expression condition ++ capturedSymbols body ++ capturedSymbols update
            CoreBreak -> []
            CoreContinue -> []
        expression value = case value of
            CoreVariable {} -> []
            CoreLiteral {} -> []
            CoreApply callee arguments _ -> concatMap expression (callee : arguments)
            CorePrimitive _ arguments _ -> concatMap expression arguments
            CoreLet _ _ bound body _ -> expression bound ++ expression body
            CoreConditional condition whenTrue whenFalse _ -> concatMap expression [condition, whenTrue, whenFalse]
            CoreClosure captures _ _ body _ ->
                map (resolvedSymbol . coreCaptureName) captures
                    ++ concatMap (expression . coreCaptureValue) captures
                    ++ capturedSymbols body
