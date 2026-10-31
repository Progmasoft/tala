-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Regression tests for loop-carried Core facts.

These tests observe the public optimizer result rather than importing the
private abstract-domain implementation. That keeps the contract behavioral:
the optimizer may change its widening strategy without changing which source
paths are provable or which potentially failing operations must remain.
-}
module LoopFlowTests (loopFlowTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Optimizer.IntegerFacts

loopFlowTests :: [(String, Bool)]
loopFlowTests =
    [ ("while false-edge facts reach the following branch", whileCounterExit)
    , ("a pre-test loop that starts false preserves its exact input", falseFirstIteration)
    , ("do-while transfers the mandatory first body execution", doWhileExecutesOnce)
    , ("do-while continue reaches its condition", doWhileContinueReachesCondition)
    , ("for continue still executes the update sequence", forContinueExecutesUpdate)
    , ("break contributes an exit without becoming a back-edge", breakIsAnExit)
    , ("break exits join with the condition-false edge", breakAndConditionExitsJoin)
    , ("a zero-valued break path is not lost at the loop join", breakCanCarryZero)
    , ("a return inside a do-loop does not contaminate normal exit facts", returnDoesNotJoinExit)
    , ("nested-loop break is consumed by its nearest loop", nestedBreakIsLocal)
    , ("nested-loop continue is consumed by its nearest loop", nestedContinueIsLocal)
    , ("calls in loop bodies invalidate loop-carried facts", callInBodyInvalidates)
    , ("calls in loop conditions invalidate loop-carried facts", callInConditionInvalidates)
    , ("overflowing induction arithmetic drops the interval", overflowingInductionIsUnknown)
    , ("a loop assignment can replace nonzero with exact zero", assignmentCanEstablishZero)
    , ("a do-loop join keeps zero exclusion common to both arms", doLoopNonzeroJoin)
    , ("a false while condition prevents body assignments from leaking", falseWhileDoesNotRun)
    , ("a false for condition prevents body assignments from leaking", falseForDoesNotRun)
    , ("an unconditional loop break retains its exact exit value", unconditionalBreakRetainsValue)
    , ("a continue-only infinite path is not treated as a break", continueDoesNotExit)
    , ("loop headers retain stable facts that do not expand", stableHeaderFact)
    , ("condition calls are not folded from stale pre-loop constants", callConditionStaysUnknown)
    , ("widened false-edge summaries include every concrete counter exit", boundedCounterExitOracle)
    , ("the fixed-point solver completes ordinary counters within its cap", boundedCounterSolverBudget)
    , ("do-loop summaries keep first-entry and condition facts distinct", doWhileSummarySeparatesPhases)
    , ("for continue facts enter the update before an update break", forContinueSummary)
    , ("a body break skips the for update", forBreakSkipsUpdate)
    , ("loop return facts remain separate from the normal exit", loopReturnSummary)
    , ("a called body produces unconstrained loop exits", calledBodySummaryIsTop)
    , ("a called for-update drops stale exit facts", callInUpdateInvalidates)
    , ("an update break carries its post-update assignment", updateBreakCarriesUpdatedValue)
    ]
        ++ boundedCounterCases

-- A counted while loop exercises interval widening: the header must stop
-- growing even though the concrete loop may execute many more than eight
-- iterations. Its false condition then proves the complementary lower bound.
whileCounterExit :: Bool
whileCounterExit = postGuardIsRemoved (counterLoop 0 17 WhileCounter)

falseFirstIteration :: Bool
falseFirstIteration = postGuardIsRemoved (counterLoop 12 5 WhileCounter)

doWhileExecutesOnce :: Bool
doWhileExecutesOnce =
    let index = loopVariable
        loop = CoreDoWhile [assign indexName 1] falseLiteral
        program = localLoopProgram 0 loop (notEqual index 1) []
     in postGuardIsRemoved program

doWhileContinueReachesCondition :: Bool
doWhileContinueReachesCondition =
    let index = loopVariable
        loop =
            CoreDoWhile
                [ assign indexName 1
                , CoreContinue
                , assign indexName 0
                ]
                falseLiteral
        program = localLoopProgram 0 loop (notEqual index 1) []
     in postGuardIsRemoved program

forContinueExecutesUpdate :: Bool
forContinueExecutesUpdate =
    let index = loopVariable
        increment = add index 1
        body =
            [ CoreIf
                (equal index 2)
                [CoreContinue]
                [CoreAssign indexName increment]
            ]
        update = [CoreAssign indexName increment]
        loop = CoreFor (lessThan index 4) body update
        program = localLoopProgram 0 loop (lessThan index 4) []
     in postGuardIsRemoved program

breakIsAnExit :: Bool
breakIsAnExit =
    let index = loopVariable
        loop = CoreWhile trueLiteral [CoreIf (equal index 0) [CoreBreak] []]
        program = localLoopProgram 0 loop (equal index 0) []
     in optimizedBody program `containsReturnedDivision` indexName

breakAndConditionExitsJoin :: Bool
breakAndConditionExitsJoin =
    let index = loopVariable
        loop =
            CoreWhile
                (lessThan index 12)
                [ CoreIf
                    (equal index 3)
                    [CoreBreak]
                    [CoreAssign indexName (add index 1)]
                ]
        program = localLoopProgram 0 loop (equal index 3) []
     in topLevelGuardRemains program

breakCanCarryZero :: Bool
breakCanCarryZero =
    let index = loopVariable
        loop = CoreWhile trueLiteral [CoreIf (equal index 0) [CoreBreak] [assign indexName 1]]
        program = localLoopProgram 0 loop (equal index 0) []
     in optimizedBody program `containsReturnedDivision` indexName

returnDoesNotJoinExit :: Bool
returnDoesNotJoinExit =
    let index = loopVariable
        flag = CoreVariable flagName boolType
        loop = CoreDoWhile [CoreIf flag [CoreReturn (literal 99)] [], assign indexName 1] falseLiteral
        program = localLoopProgram 0 loop (notEqual index 1) [(flagName, boolType)]
     in postGuardIsRemoved program

nestedBreakIsLocal :: Bool
nestedBreakIsLocal =
    let index = loopVariable
        inner = CoreWhile trueLiteral [CoreBreak]
        outer =
            CoreWhile
                (lessThan index 1)
                [inner, assign indexName 1]
        program = localLoopProgram 0 outer (lessThan index 1) []
     in postGuardIsRemoved program

nestedContinueIsLocal :: Bool
nestedContinueIsLocal =
    let index = loopVariable
        inner = CoreDoWhile [CoreContinue] falseLiteral
        outer = CoreWhile (lessThan index 1) [inner, assign indexName 1]
        program = localLoopProgram 0 outer (lessThan index 1) []
     in postGuardIsRemoved program

callInBodyInvalidates :: Bool
callInBodyInvalidates =
    let index = loopVariable
        callback = CoreVariable callbackName (FunctionType [] unitType)
        invoke = CoreEvaluate (CoreApply callback [] unitType)
        loop = CoreWhile trueLiteral [invoke, CoreBreak]
        program = localLoopProgram 2 loop (notEqual index 0) [(callbackName, FunctionType [] unitType)]
     in topLevelGuardRemains program

callInConditionInvalidates :: Bool
callInConditionInvalidates =
    let index = loopVariable
        predicate = CoreVariable predicateName (FunctionType [] boolType)
        loop = CoreWhile (CoreApply predicate [] boolType) [CoreBreak]
        program = localLoopProgram 2 loop (notEqual index 0) [(predicateName, FunctionType [] boolType)]
     in topLevelGuardRemains program

overflowingInductionIsUnknown :: Bool
overflowingInductionIsUnknown =
    let index = loopVariable
        flag = CoreVariable flagName boolType
        loop = CoreWhile flag [CoreAssign indexName (add index 1)]
        program = localLoopProgram 0 loop (equal index 0) [(flagName, boolType)]
     in topLevelGuardRemains program

assignmentCanEstablishZero :: Bool
assignmentCanEstablishZero =
    let index = loopVariable
        loop = CoreDoWhile [assign indexName 0] (notEqual index 0)
        program = localLoopProgram 7 loop (notEqual index 0) []
     in postGuardIsRemoved program

doLoopNonzeroJoin :: Bool
doLoopNonzeroJoin =
    let index = loopVariable
        flag = CoreVariable flagName boolType
        loop =
            CoreDoWhile
                [CoreIf flag [assign indexName 2] [assign indexName 3]]
                falseLiteral
        program = localLoopProgram 0 loop (equal index 0) [(flagName, boolType)]
     in postGuardIsRemoved program

falseWhileDoesNotRun :: Bool
falseWhileDoesNotRun =
    let index = loopVariable
        loop = CoreWhile falseLiteral [assign indexName 4]
        program = localLoopProgram 0 loop (notEqual index 0) []
     in postGuardIsRemoved program

falseForDoesNotRun :: Bool
falseForDoesNotRun =
    let index = loopVariable
        loop = CoreFor falseLiteral [assign indexName 4] []
        program = localLoopProgram 0 loop (notEqual index 0) []
     in postGuardIsRemoved program

unconditionalBreakRetainsValue :: Bool
unconditionalBreakRetainsValue =
    let index = loopVariable
        loop = CoreWhile trueLiteral [CoreBreak]
        program = localLoopProgram 6 loop (notEqual index 6) []
     in postGuardIsRemoved program

continueDoesNotExit :: Bool
continueDoesNotExit =
    let index = loopVariable
        loop =
            CoreWhile
                trueLiteral
                [CoreIf (equal index 0) [CoreContinue] [CoreBreak]]
        program = localLoopProgram 0 loop (equal index 0) []
     in topLevelGuardRemains program

stableHeaderFact :: Bool
stableHeaderFact =
    let index = loopVariable
        loop = CoreWhile (lessThan index 4) [CoreEvaluate (equal index 3)]
        program = localLoopProgram 10 loop (notEqual index 10) []
     in postGuardIsRemoved program

callConditionStaysUnknown :: Bool
callConditionStaysUnknown =
    let index = loopVariable
        flag = CoreVariable flagName boolType
        predicate = CoreVariable predicateName (FunctionType [] boolType)
        shortCircuitCondition =
            CorePrimitive
                CoreLogicalAnd
                [flag, CoreApply predicate [] boolType]
                boolType
        loop = CoreWhile shortCircuitCondition [CoreBreak]
        program =
            localLoopProgram
                5
                loop
                (equal index 0)
                [(flagName, boolType), (predicateName, FunctionType [] boolType)]
     in topLevelGuardRemains program

{- | Small bounded counter programs act as an executable oracle for the
false-edge equation. Each loop either starts beyond its limit or advances by
one from a range where the increment is representable. In both cases the
post-loop @index < limit@ edge is infeasible, regardless of the concrete
number of runtime iterations.
-}
boundedCounterCases :: [(String, Bool)]
boundedCounterCases =
    [ ( "bounded counter " ++ show initial ++ " -> " ++ show limit ++ " prunes the false exit guard"
      , postGuardIsRemoved (counterLoop initial limit WhileCounter)
      )
    | initial <- [-4 .. 4]
    , limit <- [-4 .. 4]
    ]

boundedCounterExitOracle :: Bool
boundedCounterExitOracle = all counterSummaryContainsConcreteExit counterPairs

boundedCounterSolverBudget :: Bool
boundedCounterSolverBudget = all counterSummaryIsBounded counterPairs

counterPairs :: [(Integer, Integer)]
counterPairs = [(initial, limit) | initial <- [-4 .. 4], limit <- [-4 .. 4]]

counterSummaryContainsConcreteExit :: (Integer, Integer) -> Bool
counterSummaryContainsConcreteExit (initial, limit) =
    case counterSummary initial limit of
        Nothing -> False
        Just summary -> abstractStateContains (loopExitFacts summary) concreteExit
    where
        concreteExit = if initial < limit then limit else initial

counterSummaryIsBounded :: (Integer, Integer) -> Bool
counterSummaryIsBounded (initial, limit) =
    case counterSummary initial limit of
        Nothing -> False
        Just summary ->
            loopFixedPointIterations summary > 0
                && loopFixedPointIterations summary <= 8
                && not (loopAnalysisWidened summary)

counterSummary :: Integer -> Integer -> Maybe LoopFactSummary
counterSummary initial limit =
    let input = initialFacts initial
        index = loopVariable
        loop = CoreWhile (lessThan index limit) [CoreAssign indexName (add index 1)]
     in loopFactSummary input loop

doWhileSummarySeparatesPhases :: Bool
doWhileSummarySeparatesPhases =
    case loopFactSummary (initialFacts 0) (CoreDoWhile [assign indexName 1] falseLiteral) of
        Nothing -> False
        Just summary ->
            abstractStateIs (loopBodyFacts summary) 0
                && abstractStateIs (loopConditionFacts summary) 1
                && abstractStateIs (loopExitFacts summary) 1

forContinueSummary :: Bool
forContinueSummary =
    let loop = CoreFor (lessThan loopVariable 4) [CoreContinue] [CoreBreak]
     in case loopFactSummary (initialFacts 2) loop of
            Nothing -> False
            Just summary ->
                abstractStateIs (loopUpdateFacts summary) 2
                    && abstractStateIs (loopExitFacts summary) 2

forBreakSkipsUpdate :: Bool
forBreakSkipsUpdate =
    let loop = CoreFor trueLiteral [CoreBreak] [assign indexName 9]
     in case loopFactSummary (initialFacts 6) loop of
            Nothing -> False
            Just summary ->
                isUnreachableFacts (loopUpdateFacts summary)
                    && abstractStateIs (loopExitFacts summary) 6

loopReturnSummary :: Bool
loopReturnSummary =
    let loop = CoreDoWhile [CoreReturn (literal 42)] falseLiteral
     in case loopFactSummary (initialFacts 6) loop of
            Nothing -> False
            Just summary ->
                abstractStateIs (loopReturnFacts summary) 6
                    && isUnreachableFacts (loopExitFacts summary)

calledBodySummaryIsTop :: Bool
calledBodySummaryIsTop =
    let callback = CoreVariable callbackName (FunctionType [] unitType)
        loop = CoreWhile trueLiteral [CoreEvaluate (CoreApply callback [] unitType), CoreBreak]
     in case loopFactSummary (initialFacts 6) loop of
            Nothing -> False
            Just summary ->
                lookupIntegerFact (loopExitFacts summary) (resolvedSymbol indexName) == Nothing

callInUpdateInvalidates :: Bool
callInUpdateInvalidates =
    let callback = CoreVariable callbackName (FunctionType [] unitType)
        loop = CoreFor trueLiteral [CoreContinue] [CoreEvaluate (CoreApply callback [] unitType), CoreBreak]
        program = localLoopProgram 2 loop (equal loopVariable 0) [(callbackName, FunctionType [] unitType)]
     in topLevelGuardRemains program

updateBreakCarriesUpdatedValue :: Bool
updateBreakCarriesUpdatedValue =
    let loop = CoreFor trueLiteral [CoreContinue] [assign indexName 7, CoreBreak]
     in case loopFactSummary (initialFacts 3) loop of
            Nothing -> False
            Just summary ->
                abstractStateIs (loopUpdateFacts summary) 3
                    && abstractStateIs (loopExitFacts summary) 7

initialFacts :: Integer -> IntegerFacts
initialFacts value =
    transferStatementFacts
        emptyIntegerFacts
        (CoreBind (CoreBinding indexName intType True (literal value)))

abstractStateContains :: IntegerFacts -> Integer -> Bool
abstractStateContains state value = case lookupIntegerFact state (resolvedSymbol indexName) of
    Nothing -> not (isUnreachableFacts state)
    Just fact ->
        maybe True (<= value) (integerMinimum fact)
            && maybe True (>= value) (integerMaximum fact)
            && not (value == 0 && integerExcludesZero fact)

abstractStateIs :: IntegerFacts -> Integer -> Bool
abstractStateIs state value =
    not (isUnreachableFacts state)
        && abstractStateContains state value
        && case lookupIntegerFact state (resolvedSymbol indexName) of
            Just fact -> integerMinimum fact == Just value && integerMaximum fact == Just value
            Nothing -> False

data CounterLoop = WhileCounter

counterLoop :: Integer -> Integer -> CounterLoop -> CoreFunction
counterLoop initial limit WhileCounter =
    let index = loopVariable
        loop = CoreWhile (lessThan index limit) [CoreAssign indexName (add index 1)]
     in localLoopProgram initial loop (lessThan index limit) []

localLoopProgram :: Integer -> CoreStatement -> CoreExpression -> [(ResolvedName, Type)] -> CoreFunction
localLoopProgram initial loop postCondition extraParameters =
    CoreFunction
        functionName
        extraParameters
        intType
        [ CoreBind (CoreBinding indexName intType True (literal initial))
        , loop
        , CoreIf
            postCondition
            [CoreReturn (divide (CoreVariable indexName intType))]
            [CoreReturn (literal 0)]
        ]

postGuardIsRemoved :: CoreFunction -> Bool
postGuardIsRemoved function = case optimizedBody function of
    Just statements -> case reverse statements of
        CoreReturn (CoreLiteral (CoreInteger 0) valueType) : _ -> valueType == intType
        _ -> False
    Nothing -> False

topLevelGuardRemains :: CoreFunction -> Bool
topLevelGuardRemains function = case optimizedBody function of
    Just statements -> case reverse statements of
        CoreIf {} : _ -> True
        _ -> False
    Nothing -> False

containsReturnedDivision :: Maybe [CoreStatement] -> ResolvedName -> Bool
containsReturnedDivision maybeStatements name =
    maybe False (any (statementContainsDivision name)) maybeStatements

statementContainsDivision :: ResolvedName -> CoreStatement -> Bool
statementContainsDivision name statement = case statement of
    CoreBind binding -> expressionContainsDivision name (coreBindingValue binding)
    CoreAssign _ expression -> expressionContainsDivision name expression
    CoreReturn expression -> expressionContainsDivision name expression
    CoreIf condition whenTrue whenFalse ->
        expressionContainsDivision name condition
            || any (statementContainsDivision name) whenTrue
            || any (statementContainsDivision name) whenFalse
    CoreEvaluate expression -> expressionContainsDivision name expression
    CoreWhile condition body ->
        expressionContainsDivision name condition || any (statementContainsDivision name) body
    CoreDoWhile body condition ->
        any (statementContainsDivision name) body || expressionContainsDivision name condition
    CoreFor condition body update ->
        expressionContainsDivision name condition
            || any (statementContainsDivision name) body
            || any (statementContainsDivision name) update
    CoreBreak -> False
    CoreContinue -> False

expressionContainsDivision :: ResolvedName -> CoreExpression -> Bool
expressionContainsDivision name expression = case expression of
    CorePrimitive CoreDivide [_numerator, CoreVariable divisor _] _ -> resolvedSymbol divisor == resolvedSymbol name
    CoreVariable {} -> False
    CoreLiteral {} -> False
    CoreApply callee arguments _ ->
        expressionContainsDivision name callee || any (expressionContainsDivision name) arguments
    CorePrimitive _ arguments _ -> any (expressionContainsDivision name) arguments
    CoreLet _ _ value body _ ->
        expressionContainsDivision name value || expressionContainsDivision name body
    CoreConditional condition whenTrue whenFalse _ -> any (expressionContainsDivision name) [condition, whenTrue, whenFalse]
    CoreClosure captures _ _ body _ ->
        any (expressionContainsDivision name . coreCaptureValue) captures
            || any (statementContainsDivision name) body

optimizedBody :: CoreFunction -> Maybe [CoreStatement]
optimizedBody function = do
    result <- either (const Nothing) Just (optimizeCoreWith loopTestOptions (CoreModule moduleName [function]))
    case coreModuleFunctions (optimizedCore result) of
        [optimized] -> Just (coreFunctionBody optimized)
        _ -> Nothing

loopTestOptions :: OptimizerOptions
loopTestOptions =
    defaultOptimizerOptions
        { optimizerInterproceduralEffects = False
        , optimizerInlining = False
        , optimizerDeadCodeElimination = False
        }

assign :: ResolvedName -> Integer -> CoreStatement
assign name value = CoreAssign name (literal value)

add :: CoreExpression -> Integer -> CoreExpression
add left right = CorePrimitive CoreAdd [left, literal right] intType

lessThan :: CoreExpression -> Integer -> CoreExpression
lessThan left right = CorePrimitive CoreLessThan [left, literal right] boolType

equal :: CoreExpression -> Integer -> CoreExpression
equal left right = CorePrimitive CoreEqual [left, literal right] boolType

notEqual :: CoreExpression -> Integer -> CoreExpression
notEqual left right = CorePrimitive CoreNotEqual [left, literal right] boolType

divide :: CoreExpression -> CoreExpression
divide value = CorePrimitive CoreDivide [literal 24, value] intType

literal :: Integer -> CoreExpression
literal value = CoreLiteral (CoreInteger value) intType

trueLiteral, falseLiteral :: CoreExpression
trueLiteral = CoreLiteral (CoreBoolean True) boolType
falseLiteral = CoreLiteral (CoreBoolean False) boolType

indexName, flagName, callbackName, predicateName, functionName :: ResolvedName
indexName = resolved 10 "index"
flagName = resolved 11 "flag"
callbackName = resolved 12 "callback"
predicateName = resolved 13 "predicate"
functionName = resolved 1 "LoopFacts"

loopVariable :: CoreExpression
loopVariable = CoreVariable indexName intType

resolved :: Int -> String -> ResolvedName
resolved symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

moduleName :: QualifiedName
moduleName = QualifiedName [Identifier "Optimizer", Identifier "LoopFlow"]
