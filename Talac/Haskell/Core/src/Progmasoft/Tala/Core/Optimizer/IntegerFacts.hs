-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Path-sensitive integer facts for Core optimization and effect analysis.

Facts form a small abstract domain. Each known integer has an interval and an
independent "zero is excluded" bit; the latter preserves useful information
for disjoint intervals such as x < 0 || x > 0. The whole environment also has
a bottom element, used when a branch condition is contradictory. Unknown
calls invalidate the environment because Core does not yet carry a complete
mod/ref summary for captured mutable storage.
-}
module Progmasoft.Tala.Core.Optimizer.IntegerFacts
    ( IntegerFact (..)
    , IntegerFacts
    , emptyIntegerFacts
    , unreachableIntegerFacts
    , isUnreachableFacts
    , lookupIntegerFact
    , forgetIntegerFact
    , factOfIntegerExpression
    , factProvesNonzero
    , transferExpressionFacts
    , transferStatementFacts
    , transferStatementsFacts
    , LoopFactSummary (..)
    , loopFactSummary
    , refineConditionFacts
    , joinIntegerFacts
    , conditionTruthFromFacts
    , expressionInvokesCallable
    ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST (ResolvedName, SymbolId, Type, resolvedSymbol)
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Scalar
    ( coreIntegerBitWidth
    , coreIntegerIsSigned
    , integerFitsCoreType
    , isCoreIntegerType
    )

-- | An inclusive interval plus the useful non-convex fact that zero is absent.
data IntegerFact = IntegerFact
    { integerMinimum :: Maybe Integer
    -- ^ Inclusive lower bound, if established.
    , integerMaximum :: Maybe Integer
    -- ^ Inclusive upper bound, if established.
    , integerExcludesZero :: Bool
    -- ^ True when every represented value is nonzero.
    }
    deriving (Eq, Ord, Read, Show)

{- | Facts valid at one program point, or bottom when that point is unreachable.
Missing symbol entries mean no path-specific refinement is stored.
-}
data IntegerFacts
    = ReachableFacts (Map SymbolId IntegerFact)
    | UnreachableFacts
    deriving (Eq, Ord, Read, Show)

{- | Fixed-point facts for one structured loop.

The header is the state before a pre-test loop's condition (or before a
post-test loop's first body execution). Condition, body, and update inputs are
reported separately because a @continue@ reaches different program points in
the three Core loop forms. Exit facts join the false-condition edge with every
reachable @break@ edge. Return facts are retained for clients which need to
account for effects in paths that do not leave the function normally.
-}
data LoopFactSummary = LoopFactSummary
    { loopHeaderFacts :: IntegerFacts
    -- ^ Widened input facts at the loop's back-edge join.
    , loopConditionFacts :: IntegerFacts
    -- ^ Facts immediately before evaluating the condition.
    , loopBodyFacts :: IntegerFacts
    -- ^ Facts on entry to the body after a true condition, or at do-loop entry.
    , loopUpdateFacts :: IntegerFacts
    -- ^ Facts at a @for@ update; unreachable for loops without an update.
    , loopExitFacts :: IntegerFacts
    -- ^ Facts valid after normal loop termination, including breaks.
    , loopReturnFacts :: IntegerFacts
    -- ^ Facts on function-returning paths inside the loop.
    , loopFixedPointIterations :: Int
    -- ^ Transfer rounds used to reach stability, or the configured cap.
    , loopAnalysisWidened :: Bool
    -- ^ True when the conservative cap fallback was needed.
    }
    deriving (Eq, Ord, Read, Show)

-- | Reachable input state with no path-specific symbol constraints.
emptyIntegerFacts :: IntegerFacts
emptyIntegerFacts = ReachableFacts Map.empty

-- | Bottom state used for a contradictory or infeasible control-flow edge.
unreachableIntegerFacts :: IntegerFacts
unreachableIntegerFacts = UnreachableFacts

-- | Test whether no execution reaches the represented program point.
isUnreachableFacts :: IntegerFacts -> Bool
isUnreachableFacts UnreachableFacts = True
isUnreachableFacts _ = False

-- | Look up the current refinement for a semantic symbol identity.
lookupIntegerFact :: IntegerFacts -> SymbolId -> Maybe IntegerFact
lookupIntegerFact (ReachableFacts facts) symbol = Map.lookup symbol facts
lookupIntegerFact UnreachableFacts _ = Nothing

-- | Forget one symbol after a write whose resulting value is not modeled.
forgetIntegerFact :: IntegerFacts -> SymbolId -> IntegerFacts
forgetIntegerFact (ReachableFacts facts) symbol = ReachableFacts (Map.delete symbol facts)
forgetIntegerFact UnreachableFacts _ = UnreachableFacts

setIntegerFact :: IntegerFacts -> SymbolId -> Maybe IntegerFact -> IntegerFacts
setIntegerFact UnreachableFacts _ _ = UnreachableFacts
setIntegerFact (ReachableFacts facts) symbol value =
    case value of
        Nothing -> ReachableFacts (Map.delete symbol facts)
        Just fact
            | impossibleFact fact -> UnreachableFacts
            | otherwise -> ReachableFacts (Map.insert symbol fact facts)

unknownFact :: IntegerFact
unknownFact = IntegerFact Nothing Nothing False

exactFact :: Integer -> IntegerFact
exactFact value = IntegerFact (Just value) (Just value) (value /= 0)

factForLiteral :: Integer -> IntegerFact
factForLiteral = exactFact

typeRange :: Type -> IntegerFact
typeRange valueType = case (coreIntegerBitWidth valueType, coreIntegerIsSigned valueType) of
    (Just width, Just True) ->
        let limit = 2 ^ (width - 1)
         in IntegerFact (Just (negate limit)) (Just (limit - 1)) False
    (Just width, Just False) -> IntegerFact (Just 0) (Just (2 ^ width - 1)) False
    _ -> unknownFact

factIsExact :: IntegerFact -> Maybe Integer
factIsExact fact = case (integerMinimum fact, integerMaximum fact) of
    (Just lower, Just upper) | lower == upper -> Just lower
    _ -> Nothing

factIsZero :: IntegerFact -> Bool
factIsZero fact = factIsExact fact == Just 0

factContains :: IntegerFact -> Integer -> Bool
factContains fact value =
    maybe True (<= value) (integerMinimum fact)
        && maybe True (>= value) (integerMaximum fact)
        && not (value == 0 && integerExcludesZero fact)

impossibleFact :: IntegerFact -> Bool
impossibleFact fact =
    maybe
        False
        (\lower -> maybe False (lower >) (integerMaximum fact))
        (integerMinimum fact)
        || (integerExcludesZero fact && factIsZero fact)

-- | Prove that every value represented by this fact is different from zero.
factProvesNonzero :: IntegerFact -> Bool
factProvesNonzero fact =
    integerExcludesZero fact
        || maybe False (> 0) (integerMinimum fact)
        || maybe False (< 0) (integerMaximum fact)

factTruth :: IntegerFact -> Maybe Bool
factTruth fact
    | factIsZero fact = Just False
    | factProvesNonzero fact = Just True
    | otherwise = Nothing

{- | Derive an interval for the supported pure integer subset of a Core expression.
Unsupported expressions return 'Nothing'; callers must not treat that as a
proof of safety or as an empty set of values.
-}
factOfIntegerExpression :: IntegerFacts -> CoreExpression -> Maybe IntegerFact
factOfIntegerExpression facts expression = case expression of
    CoreLiteral (CoreInteger value) valueType
        | isCoreIntegerType valueType -> Just (factForLiteral value)
    CoreVariable name valueType
        | isCoreIntegerType valueType ->
            Just (maybe (typeRange valueType) id (lookupIntegerFact facts (resolvedSymbol name)))
    CorePrimitive CoreNegate [value] valueType
        | isCoreIntegerType valueType -> negateFact valueType <$> factOfIntegerExpression facts value
    CorePrimitive primitive [left, right] valueType
        | isCoreIntegerType valueType -> do
            leftFact <- factOfIntegerExpression facts left
            rightFact <- factOfIntegerExpression facts right
            combineIntegerFacts primitive valueType leftFact rightFact
    CoreLet name _ value body resultType
        | isCoreIntegerType resultType ->
            let afterValue = transferExpressionFacts facts value
                bound = setIntegerFact afterValue (resolvedSymbol name) (factOfIntegerExpression afterValue value)
             in factOfIntegerExpression bound body
    CoreConditional condition whenTrue whenFalse resultType
        | isCoreIntegerType resultType ->
            let afterCondition = transferExpressionFacts facts condition
                trueFacts = refineConditionFacts True condition afterCondition
                falseFacts = refineConditionFacts False condition afterCondition
             in case (isUnreachableFacts trueFacts, isUnreachableFacts falseFacts) of
                    (True, True) -> Nothing
                    (True, False) -> factOfIntegerExpression falseFacts whenFalse
                    (False, True) -> factOfIntegerExpression trueFacts whenTrue
                    (False, False) ->
                        joinFact
                            <$> factOfIntegerExpression trueFacts whenTrue
                            <*> factOfIntegerExpression falseFacts whenFalse
    _ -> Nothing

combineIntegerFacts :: CorePrimitive -> Type -> IntegerFact -> IntegerFact -> Maybe IntegerFact
combineIntegerFacts primitive resultType left right = case primitive of
    CoreAdd -> intervalResult resultType (+) left right
    CoreSubtract -> intervalResult resultType (-) left right
    CoreMultiply -> multiplyResult resultType left right
    _ -> Nothing

intervalResult :: Type -> (Integer -> Integer -> Integer) -> IntegerFact -> IntegerFact -> Maybe IntegerFact
intervalResult resultType operation left right = do
    lowerLeft <- integerMinimum left
    upperLeft <- integerMaximum left
    lowerRight <- integerMinimum right
    upperRight <- integerMaximum right
    let candidates =
            [ operation lowerLeft lowerRight
            , operation lowerLeft upperRight
            , operation upperLeft lowerRight
            , operation upperLeft upperRight
            ]
    checkedInterval resultType (minimum candidates) (maximum candidates)

multiplyResult :: Type -> IntegerFact -> IntegerFact -> Maybe IntegerFact
multiplyResult resultType left right =
    intervalResultWithCandidates
        resultType
        left
        right
        [ (*)
        ]
    where
        intervalResultWithCandidates valueType leftFact rightFact operations = do
            lowerLeft <- integerMinimum leftFact
            upperLeft <- integerMaximum leftFact
            lowerRight <- integerMinimum rightFact
            upperRight <- integerMaximum rightFact
            let products =
                    [ operation leftValue rightValue
                    | operation <- operations
                    , leftValue <- [lowerLeft, upperLeft]
                    , rightValue <- [lowerRight, upperRight]
                    ]
            result <- checkedInterval valueType (minimum products) (maximum products)
            pure result {integerExcludesZero = factProvesNonzero leftFact && factProvesNonzero rightFact}

checkedInterval :: Type -> Integer -> Integer -> Maybe IntegerFact
checkedInterval valueType lower upper
    | not (integerFitsCoreType valueType lower && integerFitsCoreType valueType upper) = Nothing
    | otherwise =
        let excludesZero = lower > 0 || upper < 0
         in Just (IntegerFact (Just lower) (Just upper) excludesZero)

negateFact :: Type -> IntegerFact -> IntegerFact
negateFact valueType fact = case (integerMaximum fact, integerMinimum fact) of
    (Just upper, Just lower)
        | integerFitsCoreType valueType (negate upper)
        , integerFitsCoreType valueType (negate lower) ->
            IntegerFact
                (Just (negate upper))
                (Just (negate lower))
                (integerExcludesZero fact || lower > 0 || upper < 0)
    _ -> unknownFact

{- | Account for expression evaluation, invalidating refinements at calls.
Calls can mutate captured cells; Core has no complete read/write summary yet.
-}
transferExpressionFacts :: IntegerFacts -> CoreExpression -> IntegerFacts
transferExpressionFacts UnreachableFacts _ = UnreachableFacts
transferExpressionFacts facts (CorePrimitive CoreLogicalAnd [left, right] _) =
    transferShortCircuitFacts True facts left right
transferExpressionFacts facts (CorePrimitive CoreLogicalOr [left, right] _) =
    transferShortCircuitFacts False facts left right
transferExpressionFacts facts (CoreConditional condition whenTrue whenFalse _) =
    let afterCondition = transferExpressionFacts facts condition
        afterTrue = transferExpressionFacts (refineConditionFacts True condition afterCondition) whenTrue
        afterFalse = transferExpressionFacts (refineConditionFacts False condition afterCondition) whenFalse
     in joinIntegerFacts afterTrue afterFalse
transferExpressionFacts facts expression
    | expressionInvokesCallable expression = emptyIntegerFacts
    | otherwise = facts

transferShortCircuitFacts :: Bool -> IntegerFacts -> CoreExpression -> CoreExpression -> IntegerFacts
transferShortCircuitFacts isAnd facts left right =
    let afterLeft = transferExpressionFacts facts left
        leftTruth = conditionTruthFromFacts facts left
        rightInput = refineConditionFacts isAnd left afterLeft
        afterRight = transferExpressionFacts rightInput right
        evaluatesRight = if isAnd then leftTruth /= Just False else leftTruth /= Just True
     in if not evaluatesRight
            then afterLeft
            else case leftTruth of
                Just _ -> afterRight
                Nothing -> joinIntegerFacts afterLeft afterRight

-- | Whether evaluating an expression can invoke a callable.
expressionInvokesCallable :: CoreExpression -> Bool
expressionInvokesCallable expression = case expression of
    CoreVariable {} -> False
    CoreLiteral {} -> False
    CoreApply {} -> True
    CorePrimitive _ arguments _ -> any expressionInvokesCallable arguments
    CoreLet _ _ value body _ -> expressionInvokesCallable value || expressionInvokesCallable body
    CoreConditional condition whenTrue whenFalse _ ->
        any expressionInvokesCallable [condition, whenTrue, whenFalse]
    -- A closure body is deferred; only its capture initializers run now.
    CoreClosure captures _ _ _ _ -> any (expressionInvokesCallable . coreCaptureValue) captures

{- | Transfer one statement's normal-completion facts to the next program point.
Break, continue, and return edges are consumed by the nearest owning flow
construct and therefore do not appear as normal continuation here.
-}
transferStatementFacts :: IntegerFacts -> CoreStatement -> IntegerFacts
transferStatementFacts facts = flowNormalFacts . analyzeStatementFlow facts

-- | Transfer statements in source order until no normal path remains.
transferStatementsFacts :: IntegerFacts -> [CoreStatement] -> IntegerFacts
transferStatementsFacts facts = flowNormalFacts . analyzeSequenceFlow facts

{- | Summarize the data-flow behavior of a structured Core loop.  A bounded
ascending iteration discovers loop-carried facts; interval widening prevents
induction variables from requiring one analysis round per runtime iteration.
If an unusual transfer shape does not stabilize within the cap, the pass
recomputes one sound summary from the reachable top state rather than exposing
the last, potentially under-approximating iteration.
-}
loopFactSummary :: IntegerFacts -> CoreStatement -> Maybe LoopFactSummary
loopFactSummary input statement = case statement of
    CoreWhile condition body ->
        Just $ solve body (whileStep condition body [])
    CoreDoWhile body condition ->
        Just $ solve body (doWhileStep body condition)
    CoreFor condition body update ->
        Just $ solve (body ++ update) (whileStep condition body update)
    _ -> Nothing
    where
        -- Every round of the fixed point analyses the loop body, and with it
        -- every loop nested in the body, each of which iterates in turn: the
        -- work is the product of the rounds of all enclosing loops, which is
        -- exponential in the depth of the nest. Only the innermost levels
        -- iterate; a loop with a deeper nest inside it is summarized in one
        -- pass from the state that assumes nothing, which is always sound
        -- and is what the iteration falls back to when it does not settle.
        solve nested step
            | loopNestingHeight nested >= iteratedLoopNesting = summarize 1 True emptyIntegerFacts (step emptyIntegerFacts)
            | otherwise = solveLoop input step

{- | How many levels of nested loops are iterated to a fixed point. A loop
whose body holds this many levels of loops or more is summarized in a single
pass, so the cost of a nest grows with its size and not exponentially with
its depth.
-}
iteratedLoopNesting :: Int
iteratedLoopNesting = 2

-- | The deepest nest of loops in the statements: 0 when they hold no loop.
loopNestingHeight :: [CoreStatement] -> Int
loopNestingHeight = foldr (max . statementHeight) 0
    where
        statementHeight statement = case statement of
            CoreIf _ whenTrue whenFalse -> max (loopNestingHeight whenTrue) (loopNestingHeight whenFalse)
            CoreWhile _ body -> 1 + loopNestingHeight body
            CoreDoWhile body _ -> 1 + loopNestingHeight body
            CoreFor _ body update -> 1 + max (loopNestingHeight body) (loopNestingHeight update)
            _ -> 0

loopIterationLimit :: Int
loopIterationLimit = 8

data LoopStep = LoopStep
    { stepConditionFacts :: IntegerFacts
    , stepBodyFacts :: IntegerFacts
    , stepUpdateFacts :: IntegerFacts
    , stepBackEdgeFacts :: IntegerFacts
    , stepExitFacts :: IntegerFacts
    , stepReturnFacts :: IntegerFacts
    }

solveLoop :: IntegerFacts -> (IntegerFacts -> LoopStep) -> LoopFactSummary
solveLoop UnreachableFacts step = summarize 0 False UnreachableFacts (step UnreachableFacts)
solveLoop entry step = iterateHeader 0 entry
    where
        iterateHeader rounds header =
            let current = step header
                candidate = joinIntegerFacts header (stepBackEdgeFacts current)
                widened = widenIntegerFacts header candidate
                nextRound = rounds + 1
             in if widened == header
                    then summarize nextRound False header current
                    else
                        if nextRound >= loopIterationLimit
                            then conservativeSummary nextRound
                            else iterateHeader nextRound widened
        conservativeSummary rounds =
            let top = step emptyIntegerFacts
             in summarize rounds True emptyIntegerFacts top

summarize :: Int -> Bool -> IntegerFacts -> LoopStep -> LoopFactSummary
summarize rounds widened header step =
    LoopFactSummary
        { loopHeaderFacts = header
        , loopConditionFacts = stepConditionFacts step
        , loopBodyFacts = stepBodyFacts step
        , loopUpdateFacts = stepUpdateFacts step
        , loopExitFacts = stepExitFacts step
        , loopReturnFacts = stepReturnFacts step
        , loopFixedPointIterations = rounds
        , loopAnalysisWidened = widened
        }

whileStep :: CoreExpression -> [CoreStatement] -> [CoreStatement] -> IntegerFacts -> LoopStep
whileStep condition body update header =
    let conditionTrue = refineConditionFacts True condition header
        conditionFalse = refineConditionFacts False condition header
        bodyFlow = analyzeSequenceFlow conditionTrue body
        updateInput = joinIntegerFacts (flowNormalFacts bodyFlow) (flowContinueFacts bodyFlow)
        updateFlow = analyzeSequenceFlow updateInput update
        loopBackEdge
            | null update = updateInput
            | otherwise = joinIntegerFacts (flowNormalFacts updateFlow) (flowContinueFacts updateFlow)
        exits =
            joinIntegerFacts
                conditionFalse
                ( joinIntegerFacts
                    (flowBreakFacts bodyFlow)
                    (flowBreakFacts updateFlow)
                )
        returns = joinIntegerFacts (flowReturnFacts bodyFlow) (flowReturnFacts updateFlow)
     in LoopStep
            { stepConditionFacts = header
            , stepBodyFacts = conditionTrue
            , stepUpdateFacts = if null update then unreachableIntegerFacts else updateInput
            , stepBackEdgeFacts = loopBackEdge
            , stepExitFacts = exits
            , stepReturnFacts = returns
            }

doWhileStep :: [CoreStatement] -> CoreExpression -> IntegerFacts -> LoopStep
doWhileStep body condition header =
    let bodyFlow = analyzeSequenceFlow header body
        conditionInput = joinIntegerFacts (flowNormalFacts bodyFlow) (flowContinueFacts bodyFlow)
        conditionTrue = refineConditionFacts True condition conditionInput
        conditionFalse = refineConditionFacts False condition conditionInput
     in LoopStep
            { stepConditionFacts = conditionInput
            , stepBodyFacts = header
            , stepUpdateFacts = unreachableIntegerFacts
            , stepBackEdgeFacts = conditionTrue
            , stepExitFacts = joinIntegerFacts (flowBreakFacts bodyFlow) conditionFalse
            , stepReturnFacts = flowReturnFacts bodyFlow
            }

{- | Widen an ascending interval sequence.  A lower bound that moves down or
an upper bound that moves up becomes unknown; stable and narrowing endpoints
are retained.  A fact missing from either state is discarded, and zero
exclusion survives only if both states prove it.  These rules guarantee the
result contains both represented value sets and force expanding induction
intervals to stabilize after at most one widening round.
-}
widenIntegerFacts :: IntegerFacts -> IntegerFacts -> IntegerFacts
widenIntegerFacts UnreachableFacts next = next
widenIntegerFacts previous UnreachableFacts = previous
widenIntegerFacts (ReachableFacts previous) (ReachableFacts next) =
    ReachableFacts (Map.mergeWithKey widenExisting (const Map.empty) (const Map.empty) previous next)
    where
        widenExisting _ old new = Just (widenIntegerFact old new)

widenIntegerFact :: IntegerFact -> IntegerFact -> IntegerFact
widenIntegerFact previous next =
    IntegerFact
        { integerMinimum = widenLower (integerMinimum previous) (integerMinimum next)
        , integerMaximum = widenUpper (integerMaximum previous) (integerMaximum next)
        , integerExcludesZero = integerExcludesZero previous && integerExcludesZero next
        }
    where
        widenLower (Just old) (Just new)
            | new >= old = Just old
            | otherwise = Nothing
        widenLower _ _ = Nothing
        widenUpper (Just old) (Just new)
            | new <= old = Just old
            | otherwise = Nothing
        widenUpper _ _ = Nothing

data StatementFlowFacts = StatementFlowFacts
    { flowNormalFacts :: IntegerFacts
    , flowBreakFacts :: IntegerFacts
    , flowContinueFacts :: IntegerFacts
    , flowReturnFacts :: IntegerFacts
    }

unreachableFlow :: StatementFlowFacts
unreachableFlow =
    StatementFlowFacts
        { flowNormalFacts = unreachableIntegerFacts
        , flowBreakFacts = unreachableIntegerFacts
        , flowContinueFacts = unreachableIntegerFacts
        , flowReturnFacts = unreachableIntegerFacts
        }

analyzeStatementFlow :: IntegerFacts -> CoreStatement -> StatementFlowFacts
analyzeStatementFlow UnreachableFacts _ = unreachableFlow
analyzeStatementFlow facts statement = case statement of
    CoreBind binding ->
        let value = coreBindingValue binding
            afterValue = transferExpressionFacts facts value
            known
                | expressionInvokesCallable value = Nothing
                | isCoreIntegerType (coreBindingType binding) = factOfIntegerExpression facts value
                | otherwise = Nothing
         in normalFlow (setIntegerFact afterValue (resolvedSymbol (coreBindingName binding)) known)
    CoreAssign name value ->
        let afterValue = transferExpressionFacts facts value
            known
                | expressionInvokesCallable value = Nothing
                | otherwise = factOfIntegerExpression facts value
         in normalFlow (setIntegerFact afterValue (resolvedSymbol name) known)
    CoreReturn value ->
        let afterValue = transferExpressionFacts facts value
         in unreachableFlow {flowReturnFacts = afterValue}
    CoreEvaluate value -> normalFlow (transferExpressionFacts facts value)
    CoreIf condition whenTrue whenFalse ->
        let trueInput = refineConditionFacts True condition facts
            falseInput = refineConditionFacts False condition facts
            trueFlow = analyzeSequenceFlow trueInput whenTrue
            falseFlow = analyzeSequenceFlow falseInput whenFalse
         in joinFlowFacts trueFlow falseFlow
    CoreWhile {} -> loopNormalFlow facts statement
    CoreDoWhile {} -> loopNormalFlow facts statement
    CoreFor {} -> loopNormalFlow facts statement
    CoreBreak -> unreachableFlow {flowBreakFacts = facts}
    CoreContinue -> unreachableFlow {flowContinueFacts = facts}

loopNormalFlow :: IntegerFacts -> CoreStatement -> StatementFlowFacts
loopNormalFlow facts statement = case loopFactSummary facts statement of
    Nothing -> normalFlow emptyIntegerFacts
    Just summary ->
        StatementFlowFacts
            { flowNormalFacts = loopExitFacts summary
            , flowBreakFacts = unreachableIntegerFacts
            , flowContinueFacts = unreachableIntegerFacts
            , flowReturnFacts = loopReturnFacts summary
            }

normalFlow :: IntegerFacts -> StatementFlowFacts
normalFlow facts = unreachableFlow {flowNormalFacts = facts}

joinFlowFacts :: StatementFlowFacts -> StatementFlowFacts -> StatementFlowFacts
joinFlowFacts left right =
    StatementFlowFacts
        { flowNormalFacts = joinIntegerFacts (flowNormalFacts left) (flowNormalFacts right)
        , flowBreakFacts = joinIntegerFacts (flowBreakFacts left) (flowBreakFacts right)
        , flowContinueFacts = joinIntegerFacts (flowContinueFacts left) (flowContinueFacts right)
        , flowReturnFacts = joinIntegerFacts (flowReturnFacts left) (flowReturnFacts right)
        }

{- | Sequence a block while carrying each abrupt edge independently.  In
particular, a break or continue in one conditional arm is not accidentally
joined with the normal state and mistaken for a loop exit or back-edge.
-}
analyzeSequenceFlow :: IntegerFacts -> [CoreStatement] -> StatementFlowFacts
analyzeSequenceFlow input statements = sequenceFrom input statements
    where
        sequenceFrom facts [] = normalFlow facts
        sequenceFrom facts (statement : remaining) =
            let current = analyzeStatementFlow facts statement
                later = sequenceFrom (flowNormalFacts current) remaining
             in StatementFlowFacts
                    { flowNormalFacts = flowNormalFacts later
                    , flowBreakFacts = joinIntegerFacts (flowBreakFacts current) (flowBreakFacts later)
                    , flowContinueFacts = joinIntegerFacts (flowContinueFacts current) (flowContinueFacts later)
                    , flowReturnFacts = joinIntegerFacts (flowReturnFacts current) (flowReturnFacts later)
                    }

-- At control-flow joins, form an interval hull and retain zero exclusion only
-- when every continuing path excludes zero. Unreachable arms are identities.

-- | Merge feasible paths, retaining only facts valid on every incoming path.
joinIntegerFacts :: IntegerFacts -> IntegerFacts -> IntegerFacts
joinIntegerFacts UnreachableFacts reachable = reachable
joinIntegerFacts reachable UnreachableFacts = reachable
joinIntegerFacts (ReachableFacts left) (ReachableFacts right) =
    ReachableFacts (Map.mergeWithKey combine (const Map.empty) (const Map.empty) left right)
    where
        combine _ first second = Just (joinFact first second)

joinFact :: IntegerFact -> IntegerFact -> IntegerFact
joinFact left right =
    IntegerFact
        { integerMinimum = lowerHull (integerMinimum left) (integerMinimum right)
        , integerMaximum = upperHull (integerMaximum left) (integerMaximum right)
        , integerExcludesZero = factProvesNonzero left && factProvesNonzero right
        }
    where
        lowerHull (Just first) (Just second) = Just (min first second)
        lowerHull _ _ = Nothing
        upperHull (Just first) (Just second) = Just (max first second)
        upperHull _ _ = Nothing

{- | Refine facts for the requested truth edge of a condition.
True and false edges may carry different intervals or reachability.
-}
refineConditionFacts :: Bool -> CoreExpression -> IntegerFacts -> IntegerFacts
refineConditionFacts _ _ UnreachableFacts = UnreachableFacts
refineConditionFacts desired expression facts = refine expression
    where
        refine value = case value of
            CoreLiteral (CoreBoolean literal) _
                | literal /= desired -> UnreachableFacts
            CoreLiteral (CoreInteger literal) valueType
                | isCoreIntegerType valueType
                , (literal /= 0) /= desired ->
                    UnreachableFacts
            CoreVariable name valueType
                | isCoreIntegerType valueType ->
                    constrainVariable name valueType (if desired then nonzeroConstraint else zeroConstraint) facts
            CorePrimitive CoreLogicalNot [nested] _ -> refineConditionFacts (not desired) nested facts
            CorePrimitive CoreLogicalAnd [left, right] _
                | desired ->
                    refineConditionFacts True right (refineConditionFacts True left facts)
                | otherwise ->
                    joinIntegerFacts
                        (refineConditionFacts False left facts)
                        (refineConditionFacts False right (refineConditionFacts True left facts))
            CorePrimitive CoreLogicalOr [left, right] _
                | desired ->
                    joinIntegerFacts
                        (refineConditionFacts True left facts)
                        (refineConditionFacts True right (refineConditionFacts False left facts))
                | otherwise ->
                    refineConditionFacts False right (refineConditionFacts False left facts)
            CorePrimitive primitive [left, right] _
                | any expressionInvokesCallable [left, right] -> emptyIntegerFacts
                | otherwise -> refineComparison desired primitive left right facts
            CoreApply {} -> emptyIntegerFacts
            CoreLet name valueType initializer body _ ->
                let afterInitializer = transferExpressionFacts facts initializer
                    binding = CoreBind (CoreBinding name valueType False initializer)
                    afterBinding = transferStatementFacts afterInitializer binding
                    afterBody = refineConditionFacts desired body afterBinding
                 in forgetIntegerFact afterBody (resolvedSymbol name)
            -- The requested truth can come from either arm; each arm is
            -- reached only along its own edge of the selecting condition.
            CoreConditional condition whenTrue whenFalse _ ->
                let afterCondition = transferExpressionFacts facts condition
                    throughTrue =
                        refineConditionFacts desired whenTrue (refineConditionFacts True condition afterCondition)
                    throughFalse =
                        refineConditionFacts desired whenFalse (refineConditionFacts False condition afterCondition)
                 in joinIntegerFacts throughTrue throughFalse
            _
                | expressionInvokesCallable value -> emptyIntegerFacts
                | otherwise -> facts

data IntegerConstraint
    = LowerBound Integer
    | UpperBound Integer
    | ExactValue Integer
    | ExcludeZero

zeroConstraint, nonzeroConstraint :: IntegerConstraint
zeroConstraint = ExactValue 0
nonzeroConstraint = ExcludeZero

constrainVariable :: ResolvedName -> Type -> IntegerConstraint -> IntegerFacts -> IntegerFacts
constrainVariable name valueType constraint facts =
    let symbol = resolvedSymbol name
        current = maybe (typeRange valueType) id (lookupIntegerFact facts symbol)
        refined = applyConstraint constraint current
     in setIntegerFact facts symbol (Just refined)

applyConstraint :: IntegerConstraint -> IntegerFact -> IntegerFact
applyConstraint constraint fact = case constraint of
    LowerBound value ->
        fact {integerMinimum = Just (maybe value (max value) (integerMinimum fact))}
    UpperBound value ->
        fact {integerMaximum = Just (maybe value (min value) (integerMaximum fact))}
    ExactValue value
        | factContains fact value -> IntegerFact (Just value) (Just value) (integerExcludesZero fact)
        | otherwise -> IntegerFact (Just 1) (Just 0) True
    ExcludeZero -> fact {integerExcludesZero = True}

refineComparison :: Bool -> CorePrimitive -> CoreExpression -> CoreExpression -> IntegerFacts -> IntegerFacts
refineComparison desired primitive left right facts =
    case (integerVariable left, integerVariable right) of
        (Just (leftName, leftType), Just (rightName, rightType)) ->
            refineVariableAgainstVariable desired primitive leftName leftType rightName rightType facts
        _ -> case (integerVariable left, integerLiteral right) of
            (Just (name, valueType), Just value) -> refineVariableAgainstLiteral desired primitive name valueType value facts
            _ -> case (integerLiteral left, integerVariable right) of
                (Just value, Just (name, valueType)) ->
                    refineVariableAgainstLiteral desired (reversePrimitive primitive) name valueType value facts
                _ -> facts

-- Relational comparisons transfer only interval information already proved on
-- the opposite operand. Equality additionally carries the zero-exclusion bit:
-- if equal values are known to avoid zero, both symbols must avoid zero.
refineVariableAgainstVariable ::
    Bool -> CorePrimitive -> ResolvedName -> Type -> ResolvedName -> Type -> IntegerFacts -> IntegerFacts
refineVariableAgainstVariable desired primitive leftName leftType rightName rightType facts
    | resolvedSymbol leftName == resolvedSymbol rightName =
        if comparisonAlwaysTrueForSelf primitive == desired then facts else UnreachableFacts
    | otherwise = case (primitive, desired) of
        (CoreEqual, True) -> refineEquality
        (CoreNotEqual, False) -> refineEquality
        (CoreEqual, False) -> refineInequality
        (CoreNotEqual, True) -> refineInequality
        (CoreLessThan, True) -> refineStrictLessThan
        (CoreLessThan, False) -> refineGreaterEqual
        (CoreLessEqual, True) -> refineLessEqual
        (CoreLessEqual, False) -> refineStrictGreaterThan
        (CoreGreaterThan, True) -> refineStrictGreaterThan
        (CoreGreaterThan, False) -> refineLessEqual
        (CoreGreaterEqual, True) -> refineGreaterEqual
        (CoreGreaterEqual, False) -> refineStrictLessThan
        _ -> facts
    where
        leftSymbol = resolvedSymbol leftName
        rightSymbol = resolvedSymbol rightName
        leftFact = factForSymbol facts leftSymbol leftType
        rightFact = factForSymbol facts rightSymbol rightType

        refineEquality =
            case intersectFacts leftFact rightFact of
                Nothing -> UnreachableFacts
                Just common ->
                    setIntegerFact
                        (setIntegerFact facts leftSymbol (Just common))
                        rightSymbol
                        (Just common)

        refineInequality =
            case (factIsZero leftFact, factIsZero rightFact) of
                (True, _) -> constrainVariable rightName rightType ExcludeZero facts
                (_, True) -> constrainVariable leftName leftType ExcludeZero facts
                _ -> facts

        refineStrictLessThan =
            applyPairConstraints
                (upperConstraint ((subtract 1) <$> integerMaximum rightFact))
                (lowerConstraint ((+ 1) <$> integerMinimum leftFact))

        refineLessEqual =
            applyPairConstraints
                (upperConstraint (integerMaximum rightFact))
                (lowerConstraint (integerMinimum leftFact))

        refineStrictGreaterThan =
            applyPairConstraints
                (lowerConstraint ((+ 1) <$> integerMinimum rightFact))
                (upperConstraint ((subtract 1) <$> integerMaximum leftFact))

        refineGreaterEqual =
            applyPairConstraints
                (lowerConstraint (integerMinimum rightFact))
                (upperConstraint (integerMaximum leftFact))

        applyPairConstraints leftConstraint rightConstraint =
            let afterLeft = maybe facts (\constraint -> constrainVariable leftName leftType constraint facts) leftConstraint
             in maybe afterLeft (\constraint -> constrainVariable rightName rightType constraint afterLeft) rightConstraint

        upperConstraint = fmap UpperBound
        lowerConstraint = fmap LowerBound

comparisonAlwaysTrueForSelf :: CorePrimitive -> Bool
comparisonAlwaysTrueForSelf primitive = case primitive of
    CoreEqual -> True
    CoreNotEqual -> False
    CoreLessThan -> False
    CoreLessEqual -> True
    CoreGreaterThan -> False
    CoreGreaterEqual -> True
    _ -> False

factForSymbol :: IntegerFacts -> SymbolId -> Type -> IntegerFact
factForSymbol facts symbol valueType = maybe (typeRange valueType) id (lookupIntegerFact facts symbol)

intersectFacts :: IntegerFact -> IntegerFact -> Maybe IntegerFact
intersectFacts left right =
    let common =
            IntegerFact
                { integerMinimum = maxLower (integerMinimum left) (integerMinimum right)
                , integerMaximum = minUpper (integerMaximum left) (integerMaximum right)
                , integerExcludesZero = integerExcludesZero left || integerExcludesZero right
                }
     in if impossibleFact common then Nothing else Just common
    where
        maxLower (Just first) (Just second) = Just (max first second)
        maxLower (Just value) Nothing = Just value
        maxLower Nothing (Just value) = Just value
        maxLower Nothing Nothing = Nothing
        minUpper (Just first) (Just second) = Just (min first second)
        minUpper (Just value) Nothing = Just value
        minUpper Nothing (Just value) = Just value
        minUpper Nothing Nothing = Nothing

refineVariableAgainstLiteral ::
    Bool -> CorePrimitive -> ResolvedName -> Type -> Integer -> IntegerFacts -> IntegerFacts
refineVariableAgainstLiteral desired primitive name valueType value facts =
    case constraintFor primitive desired value of
        Just constraint -> constrainVariable name valueType constraint facts
        Nothing -> facts

constraintFor :: CorePrimitive -> Bool -> Integer -> Maybe IntegerConstraint
constraintFor primitive desired value = case (primitive, desired) of
    (CoreEqual, True) -> Just (ExactValue value)
    (CoreEqual, False) | value == 0 -> Just ExcludeZero
    (CoreNotEqual, True) | value == 0 -> Just ExcludeZero
    (CoreNotEqual, False) -> Just (ExactValue value)
    (CoreLessThan, True) -> Just (UpperBound (value - 1))
    (CoreLessThan, False) -> Just (LowerBound value)
    (CoreLessEqual, True) -> Just (UpperBound value)
    (CoreLessEqual, False) -> Just (LowerBound (value + 1))
    (CoreGreaterThan, True) -> Just (LowerBound (value + 1))
    (CoreGreaterThan, False) -> Just (UpperBound value)
    (CoreGreaterEqual, True) -> Just (LowerBound value)
    (CoreGreaterEqual, False) -> Just (UpperBound (value - 1))
    _ -> Nothing

integerVariable :: CoreExpression -> Maybe (ResolvedName, Type)
integerVariable (CoreVariable name valueType)
    | isCoreIntegerType valueType = Just (name, valueType)
integerVariable _ = Nothing

integerLiteral :: CoreExpression -> Maybe Integer
integerLiteral (CoreLiteral (CoreInteger value) valueType)
    | isCoreIntegerType valueType = Just value
integerLiteral _ = Nothing

reversePrimitive :: CorePrimitive -> CorePrimitive
reversePrimitive primitive = case primitive of
    CoreLessThan -> CoreGreaterThan
    CoreLessEqual -> CoreGreaterEqual
    CoreGreaterThan -> CoreLessThan
    CoreGreaterEqual -> CoreLessEqual
    _ -> primitive

-- | Determine truth only when one condition edge is provably infeasible.
conditionTruthFromFacts :: IntegerFacts -> CoreExpression -> Maybe Bool
conditionTruthFromFacts UnreachableFacts _ = Nothing
conditionTruthFromFacts facts expression
    | expressionInvokesCallable expression = Nothing
    | isUnreachableFacts (refineConditionFacts True expression facts) = Just False
    | isUnreachableFacts (refineConditionFacts False expression facts) = Just True
    | otherwise = truth expression
    where
        truth value = case value of
            CoreLiteral (CoreBoolean boolean) _ -> Just boolean
            CoreLiteral (CoreInteger integerValue) valueType
                | isCoreIntegerType valueType -> Just (integerValue /= 0)
            CoreVariable name valueType
                | isCoreIntegerType valueType ->
                    factTruth =<< factOfIntegerExpression facts (CoreVariable name valueType)
            CorePrimitive CoreLogicalNot [nested] _ -> not <$> conditionTruthFromFacts facts nested
            CorePrimitive CoreLogicalAnd [left, right] _ ->
                (&&) <$> conditionTruthFromFacts facts left <*> conditionTruthFromFacts facts right
            CorePrimitive CoreLogicalOr [left, right] _ ->
                (||) <$> conditionTruthFromFacts facts left <*> conditionTruthFromFacts facts right
            CorePrimitive primitive [left, right] _ -> comparisonTruth facts primitive left right
            CoreConditional condition whenTrue whenFalse _ ->
                case conditionTruthFromFacts facts condition of
                    Just True -> conditionTruthFromFacts (refineConditionFacts True condition facts) whenTrue
                    Just False -> conditionTruthFromFacts (refineConditionFacts False condition facts) whenFalse
                    Nothing -> Nothing
            _ -> Nothing

comparisonTruth :: IntegerFacts -> CorePrimitive -> CoreExpression -> CoreExpression -> Maybe Bool
comparisonTruth facts primitive leftExpression rightExpression =
    case (integerVariable leftExpression, integerVariable rightExpression) of
        (Just (leftName, leftType), Just (rightName, rightType)) ->
            compareFacts
                primitive
                (factForSymbol facts (resolvedSymbol leftName) leftType)
                (factForSymbol facts (resolvedSymbol rightName) rightType)
        _ -> case (integerVariable leftExpression, integerLiteral rightExpression) of
            (Just (name, valueType), Just literal) ->
                compareInterval
                    primitive
                    (Just (maybe (typeRange valueType) id (lookupIntegerFact facts (resolvedSymbol name))))
                    literal
            _ -> case (integerLiteral leftExpression, integerVariable rightExpression) of
                (Just literal, Just (name, valueType)) ->
                    compareInterval
                        (reversePrimitive primitive)
                        (Just (maybe (typeRange valueType) id (lookupIntegerFact facts (resolvedSymbol name))))
                        literal
                _ -> case (integerLiteral leftExpression, integerLiteral rightExpression) of
                    (Just left, Just right) -> evaluateIntegerComparison primitive left right
                    _ -> Nothing

compareFacts :: CorePrimitive -> IntegerFact -> IntegerFact -> Maybe Bool
compareFacts primitive left right
    | factIsExact left == factIsExact right
    , Just leftValue <- factIsExact left
    , Just rightValue <- factIsExact right =
        evaluateIntegerComparison primitive leftValue rightValue
    | otherwise = case primitive of
        CoreEqual
            | disjointFacts left right -> Just False
        CoreNotEqual
            | disjointFacts left right -> Just True
        CoreLessThan
            | bothBounded (integerMaximum left) (integerMinimum right) (<) -> Just True
            | bothBounded (integerMinimum left) (integerMaximum right) (>=) -> Just False
        CoreLessEqual
            | bothBounded (integerMaximum left) (integerMinimum right) (<=) -> Just True
            | bothBounded (integerMinimum left) (integerMaximum right) (>) -> Just False
        CoreGreaterThan
            | bothBounded (integerMinimum left) (integerMaximum right) (>) -> Just True
            | bothBounded (integerMaximum left) (integerMinimum right) (<=) -> Just False
        CoreGreaterEqual
            | bothBounded (integerMinimum left) (integerMaximum right) (>=) -> Just True
            | bothBounded (integerMaximum left) (integerMinimum right) (<) -> Just False
        _ -> Nothing
    where
        bothBounded (Just first) (Just second) relation = relation first second
        bothBounded _ _ _ = False

disjointFacts :: IntegerFact -> IntegerFact -> Bool
disjointFacts left right =
    maybe False (\leftUpper -> maybe False (leftUpper <) (integerMinimum right)) (integerMaximum left)
        || maybe False (\rightUpper -> maybe False (rightUpper <) (integerMinimum left)) (integerMaximum right)
        || (factIsZero left && factProvesNonzero right)
        || (factIsZero right && factProvesNonzero left)
compareInterval :: CorePrimitive -> Maybe IntegerFact -> Integer -> Maybe Bool
compareInterval primitive maybeFact literal = do
    fact <- maybeFact
    let lower = integerMinimum fact
        upper = integerMaximum fact
        alwaysTrue = case primitive of
            CoreEqual -> factIsExact fact == Just literal
            CoreNotEqual -> not (factContains fact literal)
            CoreLessThan -> maybe False (< literal) upper
            CoreLessEqual -> maybe False (<= literal) upper
            CoreGreaterThan -> maybe False (> literal) lower
            CoreGreaterEqual -> maybe False (>= literal) lower
            _ -> False
        alwaysFalse = case primitive of
            CoreEqual -> not (factContains fact literal)
            CoreNotEqual -> factIsExact fact == Just literal
            CoreLessThan -> maybe False (>= literal) lower
            CoreLessEqual -> maybe False (> literal) lower
            CoreGreaterThan -> maybe False (<= literal) upper
            CoreGreaterEqual -> maybe False (< literal) upper
            _ -> False
    if alwaysTrue then Just True else if alwaysFalse then Just False else Nothing

evaluateIntegerComparison :: CorePrimitive -> Integer -> Integer -> Maybe Bool
evaluateIntegerComparison primitive left right = case primitive of
    CoreEqual -> Just (left == right)
    CoreNotEqual -> Just (left /= right)
    CoreLessThan -> Just (left < right)
    CoreLessEqual -> Just (left <= right)
    CoreGreaterThan -> Just (left > right)
    CoreGreaterEqual -> Just (left >= right)
    _ -> Nothing
