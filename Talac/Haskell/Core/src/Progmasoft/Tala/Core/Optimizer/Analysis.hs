-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Progmasoft.Tala.Core.Optimizer.Analysis
    ( Effect (..)
    , EffectEnvironment
    , FunctionEffectReport (..)
    , emptyEffectEnvironment
    , effectEnvironment
    , lookupFunctionEffect
    , combineEffect
    , expressionEffect
    , expressionEffectWith
    , expressionEffectWithFacts
    , primitiveEffectWithProvenNonzeroDivisor
    , expressionSymbols
    , statementSymbols
    , statementsAlwaysReturn
    , discardableExpression
    , discardableExpressionWith
    , discardableExpressionWithFacts
    ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Progmasoft.Tala.AST (ResolvedName, SymbolId, resolvedSymbol)
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer.IntegerFacts
import Progmasoft.Tala.Core.Scalar (isCoreFloatingType, isCoreIntegerType)
import Progmasoft.Tala.RuntimeCall (runtimeFunctionOf, runtimeObservable)

-- Effect ordering is deliberately conservative. The optimizer currently needs
-- one decisive property: only PureEffect may disappear when its value is dead.
-- The remaining constructors retain the strongest reason in diagnostics and
-- reports without pretending that allocation, failure and divergence are
-- interchangeable language effects.

-- | Conservative effect class used to decide whether an expression may vanish.
data Effect
    = PureEffect
    | FailureEffect
    | AllocationEffect
    | CallEffect
    | DivergenceEffect
    deriving (Eq, Ord, Read, Show)

-- The environment is immutable for one optimizer pass. Recomputing it after a
-- structural rewrite is cheap relative to parsing and avoids stale call facts
-- when control-flow simplification removes a call site.
newtype EffectEnvironment = EffectEnvironment (Map SymbolId Effect)
    deriving (Eq, Ord, Read, Show)

-- | Interprocedural effect facts and call-graph properties for one function.
data FunctionEffectReport = FunctionEffectReport
    { effectFunctionName :: ResolvedName
    , effectClassification :: Effect
    , effectDirectCallees :: [SymbolId]
    , effectHasUnknownCall :: Bool
    , effectIsRecursive :: Bool
    }
    deriving (Eq, Ord, Read, Show)

emptyEffectEnvironment :: EffectEnvironment
emptyEffectEnvironment = EffectEnvironment Map.empty

effectEnvironment :: [(SymbolId, Effect)] -> EffectEnvironment
effectEnvironment = EffectEnvironment . Map.fromList

lookupFunctionEffect :: EffectEnvironment -> SymbolId -> Maybe Effect
lookupFunctionEffect (EffectEnvironment values) symbol = Map.lookup symbol values

combineEffect :: Effect -> Effect -> Effect
combineEffect = max

expressionEffect :: CoreExpression -> Effect
expressionEffect = expressionEffectWith emptyEffectEnvironment

expressionEffectWith :: EffectEnvironment -> CoreExpression -> Effect
expressionEffectWith environment = expressionEffectWithFacts environment emptyIntegerFacts

expressionEffectWithFacts :: EffectEnvironment -> IntegerFacts -> CoreExpression -> Effect
expressionEffectWithFacts environment facts expression
    | isUnreachableFacts facts = PureEffect
    | otherwise = case expression of
        CoreVariable _ _ -> PureEffect
        CoreLiteral _ _ -> PureEffect
        CorePrimitive CoreLogicalAnd [left, right] _ ->
            shortCircuitEffect environment facts True left right
        CorePrimitive CoreLogicalOr [left, right] _ ->
            shortCircuitEffect environment facts False left right
        CorePrimitive primitive arguments _ ->
            let (childEffect, afterArguments) = expressionListEffect environment facts arguments
                divisorIsProvenNonzero = case (primitive, arguments) of
                    (CoreDivide, [_, CoreVariable name _]) -> knownNonzero afterArguments name
                    (CoreFloorDivide, [_, CoreVariable name _]) -> knownNonzero afterArguments name
                    (CoreRemainder, [_, CoreVariable name _]) -> knownNonzero afterArguments name
                    _ -> False
                localEffect = primitiveEffectWithProvenNonzeroDivisor divisorIsProvenNonzero primitive arguments
             in combineEffect childEffect localEffect
        CoreLet name valueType value body _ ->
            let valueEffect = expressionEffectWithFacts environment facts value
                afterValue = transferExpressionFacts facts value
                binding = CoreBind (CoreBinding name valueType False value)
                bodyFacts = transferStatementFacts afterValue binding
             in combineEffect valueEffect (expressionEffectWithFacts environment bodyFacts body)
        CoreConditional condition whenTrue whenFalse _ ->
            conditionalEffect environment facts condition whenTrue whenFalse
        CoreApply callee arguments _ ->
            let (nested, _) = expressionListEffect environment facts (callee : arguments)
                invoked = case callee of
                    CoreVariable name _ ->
                        maybe CallEffect id (lookupFunctionEffect environment (resolvedSymbol name))
                    _ -> CallEffect
             in combineEffect invoked nested
        CoreClosure captures _ _ _ _ ->
            let (captureEffect, _) = expressionListEffect environment facts (map coreCaptureValue captures)
             in combineEffect AllocationEffect captureEffect

shortCircuitEffect :: EffectEnvironment -> IntegerFacts -> Bool -> CoreExpression -> CoreExpression -> Effect
shortCircuitEffect environment facts isAnd left right =
    let leftEffect = expressionEffectWithFacts environment facts left
        afterLeft = transferExpressionFacts facts left
        leftTruth = conditionTruthFromFacts facts left
        evaluatesRight = if isAnd then leftTruth /= Just False else leftTruth /= Just True
        rightInput = refineConditionFacts isAnd left afterLeft
        rightEffect
            | evaluatesRight && not (isUnreachableFacts rightInput) =
                expressionEffectWithFacts environment rightInput right
            | otherwise = PureEffect
     in combineEffect leftEffect rightEffect

-- Only the selected arm runs. An arm whose edge is infeasible under the
-- incoming facts contributes no effect, exactly like a skipped right operand.
conditionalEffect ::
    EffectEnvironment -> IntegerFacts -> CoreExpression -> CoreExpression -> CoreExpression -> Effect
conditionalEffect environment facts condition whenTrue whenFalse =
    let conditionEffect = expressionEffectWithFacts environment facts condition
        afterCondition = transferExpressionFacts facts condition
        truth = conditionTruthFromFacts facts condition
        armEffect desired arm =
            let input = refineConditionFacts desired condition afterCondition
             in if truth == Just (not desired) || isUnreachableFacts input
                    then PureEffect
                    else expressionEffectWithFacts environment input arm
     in combineEffect conditionEffect (combineEffect (armEffect True whenTrue) (armEffect False whenFalse))

expressionListEffect :: EffectEnvironment -> IntegerFacts -> [CoreExpression] -> (Effect, IntegerFacts)
expressionListEffect _ facts [] = (PureEffect, facts)
expressionListEffect environment facts (expression : remaining) =
    let currentEffect = expressionEffectWithFacts environment facts expression
        afterCurrent = transferExpressionFacts facts expression
        (laterEffect, finalFacts) = expressionListEffect environment afterCurrent remaining
     in (combineEffect currentEffect laterEffect, finalFacts)

knownNonzero :: IntegerFacts -> ResolvedName -> Bool
knownNonzero facts name =
    maybe False factProvesNonzero (lookupIntegerFact facts (resolvedSymbol name))

-- Integer division can fail even though it has no externally visible write.
-- Treating a variable divisor as pure would let dead-code elimination erase a
-- required divide-by-zero failure. Floating division follows its IEEE target
-- semantics and does not use this failure classification.

{- | Classify the local effect of one already type-checked primitive. The
additional proof is supplied by structured flow analysis, never guessed
from an arbitrary expression. Child-expression effects are combined by the
caller, so proving a divisor nonzero cannot erase a call in an operand.
-}
primitiveEffectWithProvenNonzeroDivisor :: Bool -> CorePrimitive -> [CoreExpression] -> Effect
primitiveEffectWithProvenNonzeroDivisor provenNonzero primitive arguments
    -- A runtime call that writes to the console is observed by whoever
    -- reads the output: it is kept, kept once, and kept where it stands,
    -- like a call of a function that nothing is known about. The others
    -- compute a string and do nothing else.
    | primitive == CoreRuntimeCall = case arguments of
        CoreLiteral (CoreInteger identity) _ : _
            | Just function <- runtimeFunctionOf identity
            , not (runtimeObservable function) ->
                AllocationEffect
        _ -> CallEffect
    | primitive `elem` [CoreDivide, CoreFloorDivide, CoreRemainder]
    , firstTypeIsInteger arguments
    , not (knownNonzeroDivisor arguments || provenNonzero) =
        FailureEffect
    | otherwise = PureEffect

firstTypeIsInteger :: [CoreExpression] -> Bool
firstTypeIsInteger (first : _) = isCoreIntegerType (expressionType first)
firstTypeIsInteger [] = False

knownNonzeroDivisor :: [CoreExpression] -> Bool
knownNonzeroDivisor [_, CoreLiteral (CoreInteger value) _] = value /= 0
knownNonzeroDivisor [_, CoreLiteral (CoreFloating _) valueType] = isCoreFloatingType valueType
knownNonzeroDivisor _ = False

discardableExpression :: CoreExpression -> Bool
discardableExpression = discardableExpressionWith emptyEffectEnvironment

discardableExpressionWith :: EffectEnvironment -> CoreExpression -> Bool
discardableExpressionWith environment expression = expressionEffectWith environment expression == PureEffect

discardableExpressionWithFacts :: EffectEnvironment -> IntegerFacts -> CoreExpression -> Bool
discardableExpressionWithFacts environment facts expression =
    expressionEffectWithFacts environment facts expression == PureEffect

expressionSymbols :: CoreExpression -> Set SymbolId
expressionSymbols expression = case expression of
    CoreVariable name _ -> Set.singleton (resolvedSymbol name)
    CoreLiteral _ _ -> Set.empty
    CoreApply callee arguments _ -> Set.unions (map expressionSymbols (callee : arguments))
    CorePrimitive _ arguments _ -> Set.unions (map expressionSymbols arguments)
    CoreLet name _ value body _ ->
        Set.union (expressionSymbols value) (Set.delete (resolvedSymbol name) (expressionSymbols body))
    CoreConditional condition whenTrue whenFalse _ ->
        Set.unions (map expressionSymbols [condition, whenTrue, whenFalse])
    CoreClosure captures _ _ _ _ -> Set.unions (map (expressionSymbols . coreCaptureValue) captures)

statementSymbols :: CoreStatement -> Set SymbolId
statementSymbols statement = case statement of
    CoreBind binding -> expressionSymbols (coreBindingValue binding)
    CoreAssign _ value -> expressionSymbols value
    CoreReturn value -> expressionSymbols value
    CoreIf condition yes no -> Set.unions (expressionSymbols condition : map statementSymbols (yes ++ no))
    CoreWhile condition body -> Set.union (expressionSymbols condition) (Set.unions (map statementSymbols body))
    CoreDoWhile body condition -> Set.union (Set.unions (map statementSymbols body)) (expressionSymbols condition)
    CoreFor condition body update ->
        Set.unions (expressionSymbols condition : map statementSymbols (body ++ update))
    CoreEvaluate value -> expressionSymbols value
    CoreBreak -> Set.empty
    CoreContinue -> Set.empty

statementsAlwaysReturn :: [CoreStatement] -> Bool
statementsAlwaysReturn [] = False
statementsAlwaysReturn (statement : remaining) = case statement of
    CoreReturn _ -> True
    CoreIf _ yes no ->
        (not (null no) && statementsAlwaysReturn yes && statementsAlwaysReturn no)
            || statementsAlwaysReturn remaining
    _ -> statementsAlwaysReturn remaining
