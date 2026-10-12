-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Interprocedural effect inference for verified Core.

The analysis proves only effects needed for safe dead-result elimination. A
direct call is removable when its complete transitive call graph is known,
non-recursive, allocation-free and failure-free. Unknown and indirect calls
remain observable. Recursive SCCs remain observable because removing a call
could remove nontermination even when every expression is otherwise pure.
-}
module Progmasoft.Tala.Core.Optimizer.EffectInference
    ( inferFunctionEffects
    ) where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Progmasoft.Tala.AST (ResolvedName, SymbolId, resolvedSymbol)
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer.Analysis
import Progmasoft.Tala.Core.Optimizer.IntegerFacts

data DirectFacts = DirectFacts
    { directLocalEffect :: Effect
    , directCallees :: Set SymbolId
    , directHasUnknownCall :: Bool
    }
    deriving (Eq, Ord, Read, Show)

emptyDirectFacts :: DirectFacts
emptyDirectFacts = DirectFacts PureEffect Set.empty False

combineFacts :: DirectFacts -> DirectFacts -> DirectFacts
combineFacts left right =
    DirectFacts
        { directLocalEffect = combineEffect (directLocalEffect left) (directLocalEffect right)
        , directCallees = Set.union (directCallees left) (directCallees right)
        , directHasUnknownCall = directHasUnknownCall left || directHasUnknownCall right
        }

inferFunctionEffects :: CoreModule -> (EffectEnvironment, [FunctionEffectReport])
inferFunctionEffects moduleValue =
    let functions = coreModuleFunctions moduleValue
        catalog = Map.fromList [(resolvedSymbol (coreFunctionName function), function) | function <- functions]
        knownSymbols = Map.keysSet catalog
        pureKnown = effectEnvironment [(symbol, PureEffect) | symbol <- Map.keys catalog]
        facts = Map.map (functionFacts knownSymbols pureKnown) catalog
        recursive = recursiveSymbols facts
        initial = Map.mapWithKey (initialEffect recursive) facts
        solved = solveEffects recursive facts initial
        reports = map (functionReport facts recursive solved) functions
     in (effectEnvironment (Map.toAscList solved), reports)

initialEffect :: Set SymbolId -> SymbolId -> DirectFacts -> Effect
initialEffect recursive symbol facts
    | Set.member symbol recursive = DivergenceEffect
    | directHasUnknownCall facts = combineEffect CallEffect (directLocalEffect facts)
    | otherwise = directLocalEffect facts

solveEffects :: Set SymbolId -> Map SymbolId DirectFacts -> Map SymbolId Effect -> Map SymbolId Effect
solveEffects recursive facts initial = go 0 initial
    where
        maximumIterations = Map.size facts + 1
        go iteration current
            | iteration >= maximumIterations = current
            | next == current = current
            | otherwise = go (iteration + 1) next
            where
                next = Map.mapWithKey (resolveOne current) facts
        resolveOne current symbol direct =
            foldl'
                combineEffect
                (initialEffect recursive symbol direct)
                [Map.findWithDefault CallEffect callee current | callee <- Set.toAscList (directCallees direct)]

functionReport ::
    Map SymbolId DirectFacts -> Set SymbolId -> Map SymbolId Effect -> CoreFunction -> FunctionEffectReport
functionReport facts recursive solved function =
    let name = coreFunctionName function
        symbol = resolvedSymbol name
        direct = Map.findWithDefault emptyDirectFacts symbol facts
     in FunctionEffectReport
            { effectFunctionName = name
            , effectClassification = Map.findWithDefault CallEffect symbol solved
            , effectDirectCallees = Set.toAscList (directCallees direct)
            , effectHasUnknownCall = directHasUnknownCall direct
            , effectIsRecursive = Set.member symbol recursive
            }

recursiveSymbols :: Map SymbolId DirectFacts -> Set SymbolId
recursiveSymbols facts =
    Set.fromList
        [ symbol
        | component <- stronglyConnComp graphNodes
        , symbol <- cyclicMembers component
        ]
    where
        graphNodes =
            [ (symbol, symbol, Set.toAscList (directCallees direct))
            | (symbol, direct) <- Map.toAscList facts
            ]
        cyclicMembers (CyclicSCC symbols) = sort symbols
        cyclicMembers (AcyclicSCC _) = []

functionFacts :: Set SymbolId -> EffectEnvironment -> CoreFunction -> DirectFacts
functionFacts knownSymbols pureKnown function =
    fst (statementsFacts knownSymbols pureKnown emptyIntegerFacts (coreFunctionBody function))

statementsFacts ::
    Set SymbolId ->
    EffectEnvironment ->
    IntegerFacts ->
    [CoreStatement] ->
    (DirectFacts, IntegerFacts)
statementsFacts _ _ facts _ | isUnreachableFacts facts = (emptyDirectFacts, unreachableIntegerFacts)
statementsFacts _ _ facts [] = (emptyDirectFacts, facts)
statementsFacts knownSymbols pureKnown facts (statement : remaining) =
    let (current, afterCurrent) = statementFacts knownSymbols pureKnown facts statement
     in if statementAlwaysReturns statement
            then (current, afterCurrent)
            else
                let (later, finalFacts) = statementsFacts knownSymbols pureKnown afterCurrent remaining
                 in (combineFacts current later, finalFacts)

statementAlwaysReturns :: CoreStatement -> Bool
statementAlwaysReturns (CoreReturn _) = True
statementAlwaysReturns (CoreIf _ yes no) = not (null no) && statementsAlwaysReturn yes && statementsAlwaysReturn no
statementAlwaysReturns _ = False

statementFacts :: Set SymbolId -> EffectEnvironment -> IntegerFacts -> CoreStatement -> (DirectFacts, IntegerFacts)
statementFacts knownSymbols pureKnown facts statement = case statement of
    CoreBind binding ->
        let (valueFacts, _) = expressionFacts knownSymbols pureKnown facts (coreBindingValue binding)
         in (valueFacts, transferStatementFacts facts statement)
    CoreAssign _ value ->
        let (valueFacts, _) = expressionFacts knownSymbols pureKnown facts value
         in (valueFacts, transferStatementFacts facts statement)
    CoreReturn value ->
        let (valueFacts, _) = expressionFacts knownSymbols pureKnown facts value
         in (valueFacts, transferStatementFacts facts statement)
    CoreEvaluate value ->
        let (valueFacts, _) = expressionFacts knownSymbols pureKnown facts value
         in (valueFacts, transferStatementFacts facts statement)
    CoreIf condition yes no ->
        let (conditionFacts, afterCondition) = expressionFacts knownSymbols pureKnown facts condition
            whenTrue = refineConditionFacts True condition afterCondition
            whenFalse = refineConditionFacts False condition afterCondition
            knownTruth = conditionTruthFromFacts afterCondition condition
            (trueFacts, afterTrue) = statementsFacts knownSymbols pureKnown whenTrue yes
            (falseFacts, afterFalse) = statementsFacts knownSymbols pureKnown whenFalse no
            trueUnreachable = isUnreachableFacts whenTrue
            falseUnreachable = isUnreachableFacts whenFalse
            branchFacts = case knownTruth of
                Just True -> trueFacts
                Just False -> falseFacts
                Nothing
                    | trueUnreachable -> falseFacts
                    | falseUnreachable -> trueFacts
                    | otherwise -> combineFacts trueFacts falseFacts
            continuationFacts = case knownTruth of
                Just True -> afterTrue
                Just False -> afterFalse
                Nothing
                    | trueUnreachable -> afterFalse
                    | falseUnreachable -> afterTrue
                    | otherwise -> case (statementsAlwaysReturn yes, statementsAlwaysReturn no) of
                        (True, False) -> afterFalse
                        (False, True) -> afterTrue
                        (True, True) -> unreachableIntegerFacts
                        (False, False) -> joinIntegerFacts afterTrue afterFalse
         in (combineFacts conditionFacts branchFacts, continuationFacts)
    CoreWhile condition body ->
        let summary = loopFactSummary facts statement
            conditionInput = maybe emptyIntegerFacts loopConditionFacts summary
            bodyInput = maybe emptyIntegerFacts loopBodyFacts summary
            (conditionFacts, _) = expressionFacts knownSymbols pureKnown conditionInput condition
            (bodyFacts, _) = statementsFacts knownSymbols pureKnown bodyInput body
            divergence = emptyDirectFacts {directLocalEffect = DivergenceEffect}
            afterLoop = maybe emptyIntegerFacts loopExitFacts summary
         in (combineFacts divergence (combineFacts conditionFacts bodyFacts), afterLoop)
    CoreDoWhile body condition ->
        let summary = loopFactSummary facts statement
            bodyInput = maybe emptyIntegerFacts loopBodyFacts summary
            conditionInput = maybe emptyIntegerFacts loopConditionFacts summary
            (bodyFacts, _) = statementsFacts knownSymbols pureKnown bodyInput body
            (conditionFacts, _) = expressionFacts knownSymbols pureKnown conditionInput condition
            divergence = emptyDirectFacts {directLocalEffect = DivergenceEffect}
            afterLoop = maybe emptyIntegerFacts loopExitFacts summary
         in (combineFacts divergence (combineFacts bodyFacts conditionFacts), afterLoop)
    CoreFor condition body update ->
        let summary = loopFactSummary facts statement
            conditionInput = maybe emptyIntegerFacts loopConditionFacts summary
            bodyInput = maybe emptyIntegerFacts loopBodyFacts summary
            updateInput = maybe emptyIntegerFacts loopUpdateFacts summary
            (conditionFacts, _) = expressionFacts knownSymbols pureKnown conditionInput condition
            (bodyFacts, _) = statementsFacts knownSymbols pureKnown bodyInput body
            (updateFacts, _) = statementsFacts knownSymbols pureKnown updateInput update
            divergence = emptyDirectFacts {directLocalEffect = DivergenceEffect}
            afterLoop = maybe emptyIntegerFacts loopExitFacts summary
         in (combineFacts divergence (combineFacts conditionFacts (combineFacts bodyFacts updateFacts)), afterLoop)
    CoreBreak -> (emptyDirectFacts, unreachableIntegerFacts)
    CoreContinue -> (emptyDirectFacts, unreachableIntegerFacts)

expressionFacts ::
    Set SymbolId ->
    EffectEnvironment ->
    IntegerFacts ->
    CoreExpression ->
    (DirectFacts, IntegerFacts)
expressionFacts _ _ facts _ | isUnreachableFacts facts = (emptyDirectFacts, unreachableIntegerFacts)
expressionFacts _ _ facts (CoreVariable _ _) = (emptyDirectFacts, facts)
expressionFacts _ _ facts (CoreLiteral _ _) = (emptyDirectFacts, facts)
expressionFacts knownSymbols pureKnown facts (CorePrimitive primitive arguments _) =
    let (children, afterArguments) = expressionListFacts knownSymbols pureKnown facts arguments
        provenNonzero = case (primitive, arguments) of
            (CoreDivide, [_, CoreVariable name _]) -> knownNonzero afterArguments name
            (CoreFloorDivide, [_, CoreVariable name _]) -> knownNonzero afterArguments name
            (CoreRemainder, [_, CoreVariable name _]) -> knownNonzero afterArguments name
            _ -> False
        local = primitiveEffectWithProvenNonzeroDivisor provenNonzero primitive arguments
     in (children {directLocalEffect = combineEffect local (directLocalEffect children)}, afterArguments)
expressionFacts knownSymbols pureKnown facts (CoreLet name valueType value body _) =
    let (valueFacts, afterValue) = expressionFacts knownSymbols pureKnown facts value
        boundState = transferStatementFacts afterValue (CoreBind (CoreBinding name valueType False value))
        (bodyFacts, afterBody) = expressionFacts knownSymbols pureKnown boundState body
     in (combineFacts valueFacts bodyFacts, afterBody)
expressionFacts knownSymbols pureKnown facts (CoreConditional condition whenTrue whenFalse _) =
    -- Summaries are path-insensitive: both arms contribute their direct
    -- effects and callees, and the continuation keeps only shared facts.
    let (conditionFacts, afterCondition) = expressionFacts knownSymbols pureKnown facts condition
        (trueFacts, afterTrue) =
            expressionFacts knownSymbols pureKnown (refineConditionFacts True condition afterCondition) whenTrue
        (falseFacts, afterFalse) =
            expressionFacts knownSymbols pureKnown (refineConditionFacts False condition afterCondition) whenFalse
     in (combineFacts conditionFacts (combineFacts trueFacts falseFacts), joinIntegerFacts afterTrue afterFalse)
expressionFacts knownSymbols pureKnown facts (CoreApply callee arguments _) =
    let (children, _) = expressionListFacts knownSymbols pureKnown facts (callee : arguments)
        invoked = case directCallee callee of
            Just symbol
                | Set.member symbol knownSymbols ->
                    children {directCallees = Set.insert symbol (directCallees children)}
            _ -> children {directHasUnknownCall = True}
     in (invoked, emptyIntegerFacts)
expressionFacts knownSymbols pureKnown facts (CoreClosure captures _ _ _ _) =
    let values = map coreCaptureValue captures
        (children, afterCaptures) = expressionListFacts knownSymbols pureKnown facts values
     in (children {directLocalEffect = combineEffect AllocationEffect (directLocalEffect children)}, afterCaptures)

expressionListFacts ::
    Set SymbolId ->
    EffectEnvironment ->
    IntegerFacts ->
    [CoreExpression] ->
    (DirectFacts, IntegerFacts)
expressionListFacts _ _ facts [] = (emptyDirectFacts, facts)
expressionListFacts knownSymbols pureKnown facts (expression : remaining) =
    let (current, afterCurrent) = expressionFacts knownSymbols pureKnown facts expression
        (later, finalFacts) = expressionListFacts knownSymbols pureKnown afterCurrent remaining
     in (combineFacts current later, finalFacts)

directCallee :: CoreExpression -> Maybe SymbolId
directCallee (CoreVariable name _) = Just (resolvedSymbol name)
directCallee _ = Nothing

knownNonzero :: IntegerFacts -> ResolvedName -> Bool
knownNonzero facts name =
    maybe False factProvesNonzero (lookupIntegerFact facts (resolvedSymbol name))
