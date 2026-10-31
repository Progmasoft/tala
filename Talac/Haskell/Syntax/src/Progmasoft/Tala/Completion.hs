-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Whether control can reach the end of a statement or an expression.

This is a fact about control flow and is kept apart from types. A block that
ends with @return@, an @if@ expression whose two blocks both leave, and a
call one of whose arguments is such an expression never produce a value, but
no type says so: the question is answered from the typed tree by the
functions of this module. The type checker uses them to decide what must
have a value, and the desugarer uses the same functions to lower what never
completes as statements alone, so that nothing is stored for a value that
does not exist.

The answers err on the side of completing: a call is assumed to return, and
a condition is assumed to be able to take either value unless it is the
literal @true@. Whether a @break@ or @continue@ has a loop to leave is a
separate rule of the type checker.
-}
module Progmasoft.Tala.Completion
    ( blockCannotComplete
    , statementCannotComplete
    , doesNotComplete
    , neverCompletingOperand
    , matchArmsAlwaysAccept
    , acceptsEveryValue
    , isUnguarded
    , blockTransfers
    , statementTransfers
    , expressionTransfers
    , isBreak
    , isContinue
    ) where

import Progmasoft.Tala.AST

{- | Whether control can never reach the end of a block.

A statement cannot complete normally when it is a @return@, a @break@ or a
@continue@; an @if@ with an @else@ whose two blocks both cannot; a nested
block that cannot; a loop whose condition is the constant true, or absent in
a @for@, and that no @break@ leaves; a statement @match@ some arm of which
always accepts and all of whose arms cannot; or any statement an expression
of which is always evaluated and never completes. A block cannot complete
when one of its statements cannot, because the statements after that one are
never reached.
-}
blockCannotComplete :: Block name Type -> Bool
blockCannotComplete (Block statements) = any statementCannotComplete statements

-- | Whether control can never reach the point after a statement.
statementCannotComplete :: Statement name Type -> Bool
statementCannotComplete statement = case statement of
    ReturnStatement {} -> True
    BreakStatement {} -> True
    ContinueStatement {} -> True
    BindingStatement _ _ _ _ _ value -> doesNotComplete value
    AssignmentStatement _ _ _ value -> doesNotComplete value
    CompoundAssignmentStatement _ _ _ _ value -> doesNotComplete value
    DiscardStatement _ value -> doesNotComplete value
    IfStatement _ condition whenTrue whenFalse ->
        doesNotComplete condition
            || maybe False (\block -> blockCannotComplete whenTrue && blockCannotComplete block) whenFalse
    GuardStatement _ condition _ -> doesNotComplete condition
    BlockStatement _ nested -> blockCannotComplete nested
    -- A loop ends normally when a break leaves it, from its body or from
    -- its condition. Without one it does not end when its condition is the
    -- constant true or never completes; a do/while also when its body
    -- cannot complete, because its body runs first.
    WhileStatement _ condition body ->
        not (leftByBreak (expressionTransfers condition ++ blockTransfers body))
            && (doesNotComplete condition || isConstantTrue condition)
    DoWhileStatement _ body condition ->
        not (leftByBreak (expressionTransfers condition ++ blockTransfers body))
            && (doesNotComplete condition || isConstantTrue condition)
    ForStatement _ initializer condition updates body ->
        maybe False statementCannotComplete initializer
            || ( not
                    ( leftByBreak
                        ( maybe [] expressionTransfers condition
                            ++ blockTransfers body
                            ++ concatMap statementTransfers updates
                        )
                    )
                    && maybe True (\test -> doesNotComplete test || isConstantTrue test) condition
               )
    ExpressionStatement _ value _ -> doesNotComplete value
    _ -> False
    where
        isConstantTrue expression = case expression of
            LiteralExpression _ (BooleanLiteral True) _ -> True
            _ -> False
        leftByBreak = any isBreak

{- | Whether evaluating an expression never yields a value.

That is so when a part of it that is always evaluated never does, or when it
is a choice every branch of which leaves: an @if@ expression whose two
blocks do not complete, a block used as a value that cannot complete or
whose final expression does not, or a @match@ one arm of which always
accepts and no arm of which completes. An operand that is evaluated only
sometimes, such as the right operand of @&&@, decides nothing.
-}
doesNotComplete :: Expression name Type -> Bool
doesNotComplete expression = case expression of
    -- The final expression of a block is its last statement, so one walk
    -- of the statements covers it; a second look at it here would double
    -- the work at every level of nested blocks.
    BlockExpression _ block _ -> blockCannotComplete block
    ConditionalExpression _ condition first second _ ->
        doesNotComplete condition || (doesNotComplete first && doesNotComplete second)
    MatchExpression _ subjects arms _ ->
        any doesNotComplete subjects
            || ( not (null arms)
                    && matchArmsAlwaysAccept (subjectTypesOf arms) arms
                    && all (doesNotComplete . matchArmBody) arms
               )
    -- A loop used as an expression yields the value of the break that
    -- leaves it; without such a break it never yields one.
    LoopExpression _ loop _ -> statementCannotComplete loop
    _ -> case neverCompletingOperand expression of
        Just _ -> True
        Nothing -> False
    where
        -- Every typed pattern carries the type of the value it accepts.
        subjectTypesOf arms = case arms of
            first : _ -> map matchPatternAnnotation (matchArmPatterns first)
            [] -> []

{- | The operands of an expression that are evaluated before its first
operand that never completes, and that operand; nothing when every operand
that is always evaluated completes. Choices between branches are not
operands in this sense and are answered by 'doesNotComplete' itself.
-}
neverCompletingOperand :: Expression name Type -> Maybe ([Expression name Type], Expression name Type)
neverCompletingOperand expression = case break doesNotComplete (alwaysEvaluated expression) of
    (before, operand : _) -> Just (before, operand)
    (_, []) -> Nothing
    where
        alwaysEvaluated value = case value of
            MemberAccessExpression _ receiver _ _ -> [receiver]
            MethodReferenceExpression _ receiver _ _ -> [receiver]
            CallExpression _ callee arguments _ -> callee : arguments
            UnaryExpression _ _ operand _ -> [operand]
            BinaryExpression _ operator left right _
                | operator `elem` [LogicalAnd, LogicalOr] -> [left]
                | otherwise -> [left, right]
            IsPatternExpression _ subject _ _ -> [subject]
            CoalesceExpression _ left _ _ -> [left]
            AssignmentExpression _ _ _ operand _ -> [operand]
            MatchExpression _ subjects _ _ -> subjects
            _ -> []

-- | Whether a pattern accepts every value of its subject.
acceptsEveryValue :: MatchPattern name annotation -> Bool
acceptsEveryValue patternValue = case patternValue of
    MatchWildcardPattern {} -> True
    MatchTypePattern {} -> True
    _ -> False

{- | Whether some arm is certain to accept, whatever the subjects are.

That is the case when an arm without a guard has only patterns that accept
every value. It is also the case when every subject has a closed set of
values, a @bool@ or an enum, and the arms without guards accept each
combination of those values between them; the combinations are enumerated,
up to 'maximumEnumeratedCombinations' of them. Nothing else is recognized: a
guard may be false, and the literals of a wider type are never listed in
full.
-}
matchArmsAlwaysAccept :: [Type] -> [MatchArm name annotation] -> Bool
matchArmsAlwaysAccept subjectTypes arms = any catchAll unguarded || coversClosedValues
    where
        unguarded = filter isUnguarded arms
        catchAll arm = all acceptsEveryValue (matchArmPatterns arm)
        coversClosedValues = case traverse closedValues subjectTypes of
            Just domains
                | not (null domains)
                , product (map length domains) <= maximumEnumeratedCombinations ->
                    all (\values -> any (`acceptsLiterals` values) unguarded) (sequence domains)
            _ -> False

-- | The values of a type that has a closed set of them, as the literals a pattern names.
closedValues :: Type -> Maybe [Literal]
closedValues valueType
    | valueType == boolType = Just [BooleanLiteral True, BooleanLiteral False]
    | otherwise = map IntegerLiteral <$> enumMemberValues valueType

{- | The most combinations of subject values that are enumerated to decide
whether a match accepts every value. A match with more is complete only
through a catch-all arm; the bound keeps the check linear in practice.
-}
maximumEnumeratedCombinations :: Int
maximumEnumeratedCombinations = 256

-- | Whether an arm's patterns accept the given values of its subjects.
acceptsLiterals :: MatchArm name annotation -> [Literal] -> Bool
acceptsLiterals arm values =
    length (matchArmPatterns arm) == length values && and (zipWith accepts (matchArmPatterns arm) values)
    where
        accepts patternValue value = case patternValue of
            MatchLiteralPattern _ literal _ -> literal == value
            _ -> acceptsEveryValue patternValue

-- | Whether an arm has no guard.
isUnguarded :: MatchArm name annotation -> Bool
isUnguarded arm = case matchArmGuard arm of
    Nothing -> True
    Just _ -> False

{- | The @break@ and @continue@ statements in a block that target the loop
the block belongs to.

Loops nested in the block keep their own transfers, in their bodies and in
their conditions and update clauses. A transfer in a block used as a value
inside an expression targets the same loop as one in a statement, so
expressions are searched as well; closures and loops used as expressions
are not, because a transfer in them cannot reach this loop.
-}
blockTransfers :: Block name annotation -> [Statement name annotation]
blockTransfers (Block statements) = concatMap statementTransfers statements

-- | The transfers of one statement that target the loop around it.
statementTransfers :: Statement name annotation -> [Statement name annotation]
statementTransfers statement = case statement of
    BreakStatement _ value -> statement : maybe [] expressionTransfers value
    ContinueStatement {} -> [statement]
    BindingStatement _ _ _ _ _ value -> expressionTransfers value
    AssignmentStatement _ _ _ value -> expressionTransfers value
    ReturnStatement _ value -> maybe [] expressionTransfers value
    IfStatement _ condition whenTrue whenFalse ->
        expressionTransfers condition ++ blockTransfers whenTrue ++ maybe [] blockTransfers whenFalse
    WhileStatement {} -> []
    DoWhileStatement {} -> []
    ForStatement _ initializer _ _ _ -> maybe [] statementTransfers initializer
    ForEachStatement _ _ _ _ _ source _ -> expressionTransfers source
    IncrementStatement {} -> []
    CompoundAssignmentStatement _ _ _ _ value -> expressionTransfers value
    DiscardStatement _ value -> expressionTransfers value
    GuardStatement _ condition block -> expressionTransfers condition ++ blockTransfers block
    BlockStatement _ block -> blockTransfers block
    ExpressionStatement _ value _ -> expressionTransfers value

-- | The transfers in an expression that target the loop around it.
expressionTransfers :: Expression name annotation -> [Statement name annotation]
expressionTransfers expression = case expression of
    NameExpression {} -> []
    LiteralExpression {} -> []
    MemberAccessExpression _ receiver _ _ -> expressionTransfers receiver
    MethodReferenceExpression _ receiver _ _ -> expressionTransfers receiver
    CallExpression _ callee arguments _ -> concatMap expressionTransfers (callee : arguments)
    UnaryExpression _ _ value _ -> expressionTransfers value
    BinaryExpression _ _ left right _ -> expressionTransfers left ++ expressionTransfers right
    IsPatternExpression _ subject _ _ -> expressionTransfers subject
    ConditionalExpression _ condition first second _ -> concatMap expressionTransfers [condition, first, second]
    CoalesceExpression _ left fallback _ -> expressionTransfers left ++ expressionTransfers fallback
    AssignmentExpression _ _ _ value _ -> expressionTransfers value
    IncrementExpression {} -> []
    LoopExpression {} -> []
    BlockExpression _ block _ -> blockTransfers block
    MatchExpression _ subjects arms _ ->
        concatMap expressionTransfers subjects
            ++ concatMap (\arm -> maybe [] expressionTransfers (matchArmGuard arm) ++ expressionTransfers (matchArmBody arm)) arms
    CallableExpression {} -> []

-- | Whether a statement is a @break@.
isBreak :: Statement name annotation -> Bool
isBreak statement = case statement of
    BreakStatement {} -> True
    _ -> False

-- | Whether a statement is a @continue@.
isContinue :: Statement name annotation -> Bool
isContinue statement = case statement of
    ContinueStatement {} -> True
    _ -> False
