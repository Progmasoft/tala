-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Lowering of value blocks and of @match@ to Core statements.

Core has no block expression and no match. Both lower to the pair that every
storing expression lowers to: statements that run first, and a store-free
expression for the value. A match becomes a chain of 'CoreIf' statements that
test the arms in order, so exactly one body runs and no Core expression, wire
format, or later stage changes.

The lowering of the expressions and blocks inside these forms belongs to the
main desugarer, which passes it in through 'BranchLowering'.
-}
module Progmasoft.Tala.Desugarer.Branching
    ( BranchLowering (..)
    , lowerValueBlock
    , lowerMatch
    , lowerSelection
    , lowerNeverCompleting
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Completion
import Progmasoft.Tala.Core
import Progmasoft.Tala.Desugarer.Sequencing
import Progmasoft.Tala.RuntimeCall (RuntimeFunction (TextEquals), runtimeFunctionIdentity)

-- | The parts of the main desugarer that the branching forms are built on.
data BranchLowering lower = BranchLowering
    { branchExpression :: Expression ResolvedName Type -> lower Lowered
    -- ^ Lower an expression to its statements and its value.
    , branchDiscarded :: Expression ResolvedName Type -> lower [CoreStatement]
    -- ^ Lower an expression whose value is dropped.
    , branchStatements :: [Statement ResolvedName Type] -> lower [CoreStatement]
    {- ^ Lower statements in statement position. The caller decides where a
    @break value;@ among them stores its value.
    -}
    , branchOperands :: [Lowered] -> lower ([CoreStatement], [CoreExpression])
    -- ^ Combine operands that are all evaluated, in order.
    , branchFresh :: String -> lower ResolvedName
    -- ^ A fresh compiler-generated local with the given name prefix.
    , branchType :: Type -> Type
    -- ^ The Core type of a source type.
    , branchLiteral :: Type -> Literal -> CoreLiteral
    -- ^ The Core literal of a source literal of the given Core type.
    }

{- | Lower an expression that never yields a value, as the statements that
run until control leaves.

Such an expression has no Core value, so none is made up for it: there is no
result slot, no placeholder and nothing for a join to read. The operands
that are evaluated before the one that never completes are evaluated for
their effects, in order; the operands after it are never reached and are not
lowered. A choice every branch of which leaves is a conditional statement
over the statements of its branches.
-}
lowerNeverCompleting ::
    (Monad lower) => BranchLowering lower -> Expression ResolvedName Type -> lower [CoreStatement]
lowerNeverCompleting lowering expression = case expression of
    BlockExpression _ (Block statements) _ -> case reverse statements of
        ExpressionStatement _ value False : before
            | not (blockCannotComplete (Block (reverse before))) -> do
                leading <- branchStatements lowering (reverse before)
                final <- lowerNeverCompleting lowering value
                pure (leading ++ final)
        _ -> branchStatements lowering statements
    ConditionalExpression _ condition first second _
        | doesNotComplete condition -> lowerNeverCompleting lowering condition
        | otherwise -> do
            (prefix, test) <- branchExpression lowering condition
            whenTrue <- lowerNeverCompleting lowering first
            whenFalse <- lowerNeverCompleting lowering second
            pure (prefix ++ [CoreIf test whenTrue whenFalse])
    MatchExpression _ subjects arms _
        | not (any doesNotComplete subjects) -> fst <$> lowerMatch lowering voidType subjects arms
    -- A loop that no break leaves: the loop statement itself.
    LoopExpression _ loop _ -> branchStatements lowering [loop]
    _ -> case neverCompletingOperand expression of
        Just (before, operand) -> do
            -- Reading a name or a literal has no effect to keep.
            evaluated <- mapM (branchDiscarded lowering) (filter hasEvaluation before)
            final <- lowerNeverCompleting lowering operand
            pure (concat evaluated ++ final)
        -- Not reached for an expression that never completes; an
        -- expression that does is evaluated for its effects.
        Nothing -> branchDiscarded lowering expression
    where
        hasEvaluation operand = case operand of
            NameExpression {} -> False
            LiteralExpression {} -> False
            _ -> True

{- | Lower a two-way choice exactly one of whose branches completes.

The result slot is assigned only on the branch that completes. The other
branch leaves with @return@, @break@ or @continue@, which are ordinary Core
statements wherever they stand; it is lowered as its statements alone and
never reaches the read of the slot.
-}
lowerSelection ::
    (Monad lower) =>
    BranchLowering lower ->
    Type ->
    Lowered ->
    Expression ResolvedName Type ->
    Expression ResolvedName Type ->
    lower Lowered
lowerSelection lowering valueType (conditionPrefix, condition) first second = do
    result <- branchFresh lowering "$selected"
    let resultType = branchType lowering valueType
        branch value
            | doesNotComplete value = lowerNeverCompleting lowering value
            | otherwise = do
                (prefix, lowered) <- branchExpression lowering value
                pure (prefix ++ [CoreAssign result lowered])
    whenTrue <- branch first
    whenFalse <- branch second
    pure
        ( conditionPrefix
            ++ [ CoreBind (CoreBinding result resultType True (neutralValue resultType))
               , CoreIf condition whenTrue whenFalse
               ]
        , CoreVariable result resultType
        )

{- | Lower a block used as a value.

The leading statements run in order; the value is the final expression. A
block that does not complete has no value; the forms that hold one lower it
through 'lowerNeverCompleting' and never ask for its value.
-}
lowerValueBlock :: (Monad lower) => BranchLowering lower -> Block ResolvedName Type -> lower Lowered
lowerValueBlock lowering (Block statements) = case reverse statements of
    ExpressionStatement _ value False : before -> do
        leading <- branchStatements lowering (reverse before)
        (prefix, lowered) <- branchExpression lowering value
        pure (leading ++ prefix, lowered)
    _ -> do
        leading <- branchStatements lowering statements
        pure (leading, CoreLiteral CoreUnit unitType)

{- | Lower a @match@.

The subjects are evaluated once, left to right, and each is bound to a local
so that every arm tests the same values. The names the arms bind are bound
next, each to its subject: binding a scalar that was already evaluated has no
effect of its own, and no arm can see a name of another arm. The arms then
form one chain of conditionals, each arm in the false branch of the one
before it. That is the shape of an @else if@ chain, which every stage walks
in a loop, so the lowering of a match is as deep as one arm whatever the
number of arms.

A match whose type is @void@ is the statement form: its arm bodies run for
their effects and its value is the unit literal. Otherwise every arm that
completes stores its value into a result slot, and an arm whose block leaves
stores nothing. The type checker guarantees that the slot is assigned on
every path that reaches its read, because some arm always accepts.
-}
lowerMatch ::
    (Monad lower) =>
    BranchLowering lower ->
    Type ->
    [Expression ResolvedName Type] ->
    [MatchArm ResolvedName Type] ->
    lower Lowered
lowerMatch lowering annotation subjects arms = do
    loweredSubjects <- mapM (branchExpression lowering) subjects
    (subjectPrefix, subjectValues) <- branchOperands lowering loweredSubjects
    subjectNames <- mapM (const (branchFresh lowering "$subject")) subjectValues
    let subjectTypes = map expressionType subjectValues
        subjectBindings =
            [ CoreBind (CoreBinding name valueType False value)
            | (name, valueType, value) <- zip3 subjectNames subjectTypes subjectValues
            ]
        subjectReads = zipWith CoreVariable subjectNames subjectTypes
        patternBindings =
            [ CoreBind (CoreBinding name (expressionType subject) True subject)
            | arm <- arms
            , (MatchTypePattern _ _ (Just name) _, subject) <- zip (matchArmPatterns arm) subjectReads
            ]
        prefix = subjectPrefix ++ subjectBindings ++ patternBindings
    if annotation == voidType
        then do
            chain <- lowerArms lowering Nothing subjectReads arms
            pure (prefix ++ chain, CoreLiteral CoreUnit unitType)
        else do
            result <- branchFresh lowering "$matched"
            let resultType = branchType lowering annotation
            chain <- lowerArms lowering (Just result) subjectReads arms
            pure
                ( prefix ++ CoreBind (CoreBinding result resultType True (neutralValue resultType)) : chain
                , CoreVariable result resultType
                )

{- | Lower the arms from the given one on, as the false branch of the arm
before them.

An arm that always accepts ends the chain with its body; the type checker
has rejected any arm after it. A guard is the last operand of the arm's
test, behind the short-circuit conjunction, so it runs only when the
patterns accept. Only a guard that stores into a local needs statements of
its own; they go before the conditional of its arm, inside the false branch
of the arm before it, and that arm alone adds a level of nesting.
-}
lowerArms ::
    (Monad lower) =>
    BranchLowering lower ->
    Maybe ResolvedName ->
    [CoreExpression] ->
    [MatchArm ResolvedName Type] ->
    lower [CoreStatement]
lowerArms _ _ _ [] = pure []
lowerArms lowering result subjects (arm : remaining) = do
    let tests = concatMap (uncurry (patternTests lowering)) (zip (matchArmPatterns arm) subjects)
    body <- lowerArmBody lowering result (matchArmBody arm)
    later <- lowerArms lowering result subjects remaining
    case (tests, matchArmGuard arm) of
        ([], Nothing) -> pure body
        (_, Nothing) -> pure [CoreIf (conjunction tests) body later]
        (_, Just guard) -> do
            (guardPrefix, guardValue) <- branchExpression lowering guard
            if null guardPrefix
                then pure [CoreIf (conjunction (tests ++ [guardValue])) body later]
                else
                    if null tests
                        then pure (guardPrefix ++ [CoreIf guardValue body later])
                        else do
                            accepted <- branchFresh lowering "$accepted"
                            let (statements, decision) =
                                    decideLogical True accepted (conjunction tests) (guardPrefix, guardValue)
                            pure (statements ++ [CoreIf decision body later])

{- | The comparisons one pattern needs against its subject.

A pattern that accepts every value needs none. The @null@ and enum case
patterns are rejected by the type checker; they lower to a test that never
holds so that a tree which reached here by mistake cannot select their arm.
-}
patternTests ::
    BranchLowering lower -> MatchPattern ResolvedName Type -> CoreExpression -> [CoreExpression]
patternTests lowering patternValue subject = case patternValue of
    MatchWildcardPattern {} -> []
    MatchTypePattern {} -> []
    -- Two strings are equal when they hold the same characters, which the
    -- runtime decides: the comparison is the call that `==` is.
    MatchLiteralPattern _ literal literalType
        | literalType == stringType ->
            [ CorePrimitive
                CoreRuntimeCall
                [ CoreLiteral (CoreInteger (runtimeFunctionIdentity TextEquals)) intType
                , subject
                , CoreLiteral (branchLiteral lowering stringType literal) stringType
                ]
                boolType
            ]
    MatchLiteralPattern _ literal literalType ->
        let loweredType = branchType lowering literalType
         in [CorePrimitive CoreEqual [subject, CoreLiteral (branchLiteral lowering loweredType literal) loweredType] boolType]
    MatchNullPattern {} -> [CoreLiteral (CoreBoolean False) boolType]
    MatchCasePattern {} -> [CoreLiteral (CoreBoolean False) boolType]

-- The comparisons are Booleans without effects, so for them the
-- short-circuit primitive only decides how many run. A guard, when there is
-- one, is the last operand and is therefore evaluated only when every
-- comparison held; it may be numeric, which the primitive tests in Boolean
-- context. A lone operand is used as it is: a conditional statement tests a
-- numeric condition in Boolean context as well.
conjunction :: [CoreExpression] -> CoreExpression
conjunction tests = case tests of
    [] -> CoreLiteral (CoreBoolean True) boolType
    [test] -> test
    test : remaining -> CorePrimitive CoreLogicalAnd [test, conjunction remaining] boolType

{- | Lower the body of an arm.

With a result slot, the body is an expression whose value is stored. Without
one, a block body is a statement block and any other body is evaluated for
its effects.
-}
lowerArmBody ::
    (Monad lower) => BranchLowering lower -> Maybe ResolvedName -> Expression ResolvedName Type -> lower [CoreStatement]
lowerArmBody lowering result body = case (result, body) of
    (Just slot, _)
        | doesNotComplete body -> lowerNeverCompleting lowering body
        | otherwise -> do
            (prefix, value) <- branchExpression lowering body
            pure (prefix ++ [CoreAssign slot value])
    (Nothing, BlockExpression _ (Block statements) _) -> branchStatements lowering statements
    (Nothing, _)
        | doesNotComplete body -> lowerNeverCompleting lowering body
        | otherwise -> branchDiscarded lowering body
