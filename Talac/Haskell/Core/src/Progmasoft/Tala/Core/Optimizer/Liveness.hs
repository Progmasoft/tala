-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Progmasoft.Tala.Core.Optimizer.Liveness
    ( eliminateDeadCode
    , eliminateDeadCodeWith
    ) where

import Data.Set (Set)
import Data.Set qualified as Set
import Progmasoft.Tala.AST (ResolvedName, SymbolId, resolvedSymbol)
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer.Analysis
import Progmasoft.Tala.Core.Optimizer.IntegerFacts
import Progmasoft.Tala.Core.Symbols (coreStatementSymbols)

-- Value liveness and declaration retention are deliberately separate. A
-- retained assignment kills the previous stored value, but it still requires
-- the CoreBind which declares its storage. Using one set for both concerns
-- either drops that declaration or falsely keeps every earlier assignment.
data LiveState = LiveState
    { liveValues :: Set SymbolId
    , requiredDeclarations :: Set SymbolId
    }

emptyLiveState :: LiveState
emptyLiveState = LiveState Set.empty Set.empty

stateForSymbols :: Set SymbolId -> LiveState
stateForSymbols symbols = LiveState symbols symbols

addRequiredSymbols :: Set SymbolId -> LiveState -> LiveState
addRequiredSymbols symbols state =
    LiveState
        { liveValues = Set.union symbols (liveValues state)
        , requiredDeclarations = Set.union symbols (requiredDeclarations state)
        }

mergeLiveStates :: [LiveState] -> LiveState
mergeLiveStates = foldl merge emptyLiveState
    where
        merge left right =
            LiveState
                { liveValues = Set.union (liveValues left) (liveValues right)
                , requiredDeclarations =
                    Set.union (requiredDeclarations left) (requiredDeclarations right)
                }

eliminateDeadCode :: CoreModule -> CoreModule
eliminateDeadCode = eliminateDeadCodeWith emptyEffectEnvironment

eliminateDeadCodeWith :: EffectEnvironment -> CoreModule -> CoreModule
eliminateDeadCodeWith environment moduleValue =
    moduleValue {coreModuleFunctions = map (eliminateFunction environment) (coreModuleFunctions moduleValue)}

eliminateFunction :: EffectEnvironment -> CoreFunction -> CoreFunction
eliminateFunction environment function =
    function
        { coreFunctionBody =
            fst (eliminateStatements environment emptyIntegerFacts emptyLiveState (coreFunctionBody function))
        }

-- Liveness runs backwards. The returned state describes storage and values
-- required before the optimized statement list executes. Function symbols
-- can occur in both sets; because they have no local CoreBind, they simply
-- flow to the function boundary and are ignored by this local pass.
eliminateStatements :: EffectEnvironment -> IntegerFacts -> LiveState -> [CoreStatement] -> ([CoreStatement], LiveState)
eliminateStatements environment incomingFacts liveAfter statements =
    foldr eliminateWithFacts ([], liveAfter) (zip (factsBeforeStatements incomingFacts statements) statements)
    where
        eliminateWithFacts (facts, statement) = eliminateOne environment facts statement

factsBeforeStatements :: IntegerFacts -> [CoreStatement] -> [IntegerFacts]
factsBeforeStatements _ [] = []
factsBeforeStatements facts (statement : remaining) =
    facts : factsBeforeStatements (transferStatementFacts facts statement) remaining

eliminateOne ::
    EffectEnvironment -> IntegerFacts -> CoreStatement -> ([CoreStatement], LiveState) -> ([CoreStatement], LiveState)
eliminateOne environment facts statement (remaining, liveAfter) = case statement of
    CoreReturn value ->
        let optimized = optimizeExpression environment value
         in ([CoreReturn optimized], stateForSymbols (expressionSymbols optimized))
    CoreEvaluate value ->
        let optimized = optimizeExpression environment value
         in if discardableExpressionWithFacts environment facts optimized
                then (remaining, liveAfter)
                else
                    ( CoreEvaluate optimized : remaining
                    , addRequiredSymbols (expressionSymbols optimized) liveAfter
                    )
    CoreBind binding -> eliminateBinding environment facts binding remaining liveAfter
    CoreAssign name value -> eliminateAssignment environment facts name value remaining liveAfter
    CoreIf condition yes no -> eliminateBranch environment facts condition yes no remaining liveAfter
    CoreWhile condition body ->
        preserveLoop (CoreWhile (optimizeExpression environment condition) body) statement remaining liveAfter
    CoreDoWhile body condition ->
        preserveLoop (CoreDoWhile body (optimizeExpression environment condition)) statement remaining liveAfter
    CoreFor condition body update ->
        preserveLoop (CoreFor (optimizeExpression environment condition) body update) statement remaining liveAfter
    CoreBreak -> (CoreBreak : remaining, liveAfter)
    CoreContinue -> (CoreContinue : remaining, liveAfter)

-- Loops have backedges, so a single reverse tree walk is not a sound liveness
-- solution. Preserve their bodies verbatim and conservatively mark every
-- symbol in the loop live until the dedicated loop fixed-point pass is added.
preserveLoop :: CoreStatement -> CoreStatement -> [CoreStatement] -> LiveState -> ([CoreStatement], LiveState)
preserveLoop optimized original remaining liveAfter =
    let symbols = Set.fromList (map (resolvedSymbol) (coreStatementSymbols original))
     in (optimized : remaining, addRequiredSymbols symbols liveAfter)

eliminateBinding ::
    EffectEnvironment -> IntegerFacts -> CoreBinding -> [CoreStatement] -> LiveState -> ([CoreStatement], LiveState)
eliminateBinding environment facts binding remaining liveAfter =
    let symbol = resolvedSymbol (coreBindingName binding)
        value = optimizeExpression environment (coreBindingValue binding)
        valueIsNeeded = Set.member symbol (liveValues liveAfter)
        declarationIsNeeded = Set.member symbol (requiredDeclarations liveAfter)
        beforeDefinition =
            LiveState
                { liveValues = Set.delete symbol (liveValues liveAfter)
                , requiredDeclarations = Set.delete symbol (requiredDeclarations liveAfter)
                }
     in if valueIsNeeded || declarationIsNeeded
            then
                ( CoreBind binding {coreBindingValue = value} : remaining
                , addRequiredSymbols (expressionSymbols value) beforeDefinition
                )
            else preserveDeadValue environment facts value remaining beforeDefinition

eliminateAssignment ::
    EffectEnvironment ->
    IntegerFacts ->
    ResolvedName ->
    CoreExpression ->
    [CoreStatement] ->
    LiveState ->
    ([CoreStatement], LiveState)
eliminateAssignment environment facts name source remaining liveAfter =
    let symbol = resolvedSymbol name
        value = optimizeExpression environment source
        beforeWrite = liveAfter {liveValues = Set.delete symbol (liveValues liveAfter)}
     in if Set.member symbol (liveValues liveAfter)
            then
                -- The write supplies the value required later, so an earlier
                -- value of the target is dead. Its declaration is different:
                -- the retained assignment still needs storage to exist.
                let withSource = addRequiredSymbols (expressionSymbols value) beforeWrite
                    withDeclaration =
                        withSource
                            { requiredDeclarations =
                                Set.insert symbol (requiredDeclarations withSource)
                            }
                 in (CoreAssign name value : remaining, withDeclaration)
            else preserveDeadValue environment facts value remaining beforeWrite

eliminateBranch ::
    EffectEnvironment ->
    IntegerFacts ->
    CoreExpression ->
    [CoreStatement] ->
    [CoreStatement] ->
    [CoreStatement] ->
    LiveState ->
    ([CoreStatement], LiveState)
eliminateBranch environment facts condition yes no remaining liveAfter =
    let optimizedCondition = optimizeExpression environment condition
        afterCondition = transferExpressionFacts facts condition
        trueFacts = refineConditionFacts True condition afterCondition
        falseFacts = refineConditionFacts False condition afterCondition
        (optimizedYes, liveYes) = eliminateStatements environment trueFacts liveAfter yes
        (optimizedNo, liveNo) = eliminateStatements environment falseFacts liveAfter no
        branchState = mergeLiveStates [liveYes, liveNo]
        liveBefore = addRequiredSymbols (expressionSymbols optimizedCondition) branchState
     in (CoreIf optimizedCondition optimizedYes optimizedNo : remaining, liveBefore)

preserveDeadValue ::
    EffectEnvironment -> IntegerFacts -> CoreExpression -> [CoreStatement] -> LiveState -> ([CoreStatement], LiveState)
preserveDeadValue environment facts value remaining liveAfter
    | discardableExpressionWithFacts environment facts value = (remaining, liveAfter)
    | otherwise =
        ( CoreEvaluate value : remaining
        , addRequiredSymbols (expressionSymbols value) liveAfter
        )

-- Closure bodies are independent liveness regions. Capture initializers are
-- evaluated outside the closure, while the body is analyzed from its own
-- return and effect roots. The module effect environment is still valid for
-- direct calls made when that callable eventually executes.
optimizeExpression :: EffectEnvironment -> CoreExpression -> CoreExpression
optimizeExpression environment expression = case expression of
    CoreVariable {} -> expression
    CoreLiteral {} -> expression
    CoreApply callee arguments valueType ->
        CoreApply
            (optimizeExpression environment callee)
            (map (optimizeExpression environment) arguments)
            valueType
    CorePrimitive primitive arguments valueType ->
        CorePrimitive primitive (map (optimizeExpression environment) arguments) valueType
    CoreLet name bindingType value body valueType ->
        CoreLet
            name
            bindingType
            (optimizeExpression environment value)
            (optimizeExpression environment body)
            valueType
    CoreConditional condition whenTrue whenFalse valueType ->
        CoreConditional
            (optimizeExpression environment condition)
            (optimizeExpression environment whenTrue)
            (optimizeExpression environment whenFalse)
            valueType
    CoreClosure captures parameters returnType body valueType ->
        CoreClosure
            [capture {coreCaptureValue = optimizeExpression environment (coreCaptureValue capture)} | capture <- captures]
            parameters
            returnType
            (fst (eliminateStatements environment emptyIntegerFacts emptyLiveState body))
            valueType
