-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Small concrete Core executor used only as an independent loop-fact oracle.

The executor intentionally supports a strict, side-effect-free integer subset.
Generated fixtures stay inside that subset; unsupported Core is reported as a
test failure rather than silently assigned invented runtime behavior. For each
finite execution, the abstract loop summary must contain its concrete normal
exit value.
-}
module LoopFlowOracleTests (loopFlowOracleTests) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer.IntegerFacts

loopFlowOracleTests :: [(String, Bool)]
loopFlowOracleTests =
    [ ("small while executions are contained by their abstract exit", all whileScenarioIsContained whileScenarios)
    , ("small do-while executions preserve mandatory-body exits", all doScenarioIsContained doScenarios)
    , ("small for executions route continue through update", all forScenarioIsContained forScenarios)
    , ("nested transfer execution agrees with nearest-loop ownership", nestedScenarioIsContained)
    , ("a concrete break exit is represented even beside a false edge", flaggedBreakIsContained)
    , ("concrete while returns are contained by the return summary", all whileReturnIsContained smallInputs)
    , ("concrete for-update returns are contained by the return summary", all forReturnIsContained smallInputs)
    , ("a do-loop return preserves its exact pre-return state", doReturnIsContained)
    , ("break skips the remaining body statements", breakSkipsBodyTail)
    , ("continue-only cycles have no fabricated normal exit", continueCycleHasNoExit)
    ]

type Scenario = (Integer, Integer, Integer)

smallInputs :: [Integer]
smallInputs = [-2 .. 2]

whileScenarios, doScenarios, forScenarios :: [Scenario]
whileScenarios = [(initial, limit, stopAt) | initial <- smallInputs, limit <- smallInputs, stopAt <- smallInputs]
doScenarios = whileScenarios
forScenarios = whileScenarios

whileScenarioIsContained :: Scenario -> Bool
whileScenarioIsContained (initial, limit, stopAt) =
    let index = indexVariable
        advance = assignIndex (addInteger index 1)
        transfer =
            CoreIf
                (compareInteger CoreEqual index (integerLiteral stopAt))
                [CoreBreak]
                [ CoreIf
                    (compareInteger CoreEqual index (integerLiteral 1))
                    [advance, CoreContinue]
                    [advance]
                ]
        loop = CoreWhile (compareInteger CoreLessThan index (integerLiteral limit)) [transfer]
     in scenarioExitIsContained initial [] loop

doScenarioIsContained :: Scenario -> Bool
doScenarioIsContained (initial, limit, stopAt) =
    let index = indexVariable
        advance = assignIndex (addInteger index 1)
        body =
            [ CoreIf
                (compareInteger CoreEqual index (integerLiteral stopAt))
                [CoreBreak]
                [ CoreIf
                    (compareInteger CoreEqual index (integerLiteral 0))
                    [advance, CoreContinue]
                    [advance]
                ]
            ]
        loop = CoreDoWhile body (compareInteger CoreLessThan index (integerLiteral limit))
     in scenarioExitIsContained initial [] loop

forScenarioIsContained :: Scenario -> Bool
forScenarioIsContained (initial, limit, stopAt) =
    let index = indexVariable
        advance = assignIndex (addInteger index 1)
        body =
            [ CoreIf
                (compareInteger CoreEqual index (integerLiteral stopAt))
                [CoreBreak]
                [ CoreIf
                    (compareInteger CoreEqual index (integerLiteral 1))
                    [CoreContinue]
                    [advance]
                ]
            ]
        update = [advance]
        loop = CoreFor (compareInteger CoreLessThan index (integerLiteral limit)) body update
     in scenarioExitIsContained initial [] loop

nestedScenarioIsContained :: Bool
nestedScenarioIsContained =
    let outerName = resolved 20 "outer"
        innerName = resolved 21 "inner"
        outer = CoreVariable outerName intType
        inner = CoreVariable innerName intType
        innerLoop = CoreDoWhile [CoreBreak] trueLiteral
        forLoop = CoreFor (compareInteger CoreLessThan inner (integerLiteral 1)) [CoreContinue] [CoreBreak]
        outerLoop =
            CoreWhile
                (compareInteger CoreLessThan outer (integerLiteral 3))
                [innerLoop, forLoop, CoreAssign outerName (addInteger outer 1)]
        facts =
            bindFact
                outerName
                0
                (bindFact innerName 0 emptyIntegerFacts)
        environment = Map.fromList [(resolvedSymbol outerName, IntegerValue 0), (resolvedSymbol innerName, IntegerValue 0)]
     in case loopFactSummary facts outerLoop of
            Nothing -> False
            Just summary -> case executeStatement 64 environment outerLoop of
                Completed final -> runtimeInteger outerName final == Just 3 && stateContains summary outerName 3
                _ -> False

flaggedBreakIsContained :: Bool
flaggedBreakIsContained =
    let index = indexVariable
        flag = CoreVariable flagName boolType
        loop =
            CoreWhile
                trueLiteral
                [CoreIf flag [CoreBreak] [assignIndex (addInteger index 1)]]
        initial = initialFacts 2
        environment =
            Map.fromList
                [ (resolvedSymbol indexName, IntegerValue 2)
                , (resolvedSymbol flagName, BooleanValue True)
                ]
     in case loopFactSummary initial loop of
            Nothing -> False
            Just summary -> case executeStatement 64 environment loop of
                Completed final -> runtimeInteger indexName final == Just 2 && stateContains summary indexName 2
                _ -> False

whileReturnIsContained :: Integer -> Bool
whileReturnIsContained initial =
    let index = indexVariable
        loop =
            CoreWhile
                (compareInteger CoreLessThan index (integerLiteral 4))
                [ CoreIf
                    (compareInteger CoreEqual index (integerLiteral 2))
                    [CoreReturn index]
                    [assignIndex (addInteger index 1)]
                ]
     in returnScenarioIsContained initial loop

forReturnIsContained :: Integer -> Bool
forReturnIsContained initial =
    let index = indexVariable
        update =
            [ CoreIf
                (compareInteger CoreEqual index (integerLiteral 3))
                [CoreReturn index]
                [assignIndex (addInteger index 1)]
            ]
        loop = CoreFor (compareInteger CoreLessThan index (integerLiteral 5)) [CoreContinue] update
     in returnScenarioIsContained initial loop

doReturnIsContained :: Bool
doReturnIsContained = returnScenarioIsContained 7 (CoreDoWhile [CoreReturn indexVariable] falseLiteral)

returnScenarioIsContained :: Integer -> CoreStatement -> Bool
returnScenarioIsContained initial loop =
    let facts = initialFacts initial
        environment = Map.singleton (resolvedSymbol indexName) (IntegerValue initial)
     in case loopFactSummary facts loop of
            Nothing -> False
            Just summary -> case executeStatement 64 environment loop of
                Returned final ->
                    maybe False (stateHasValue (loopReturnFacts summary) indexName) (runtimeInteger indexName final)
                Completed _ -> True
                FuelExhausted -> False
                UnsupportedRuntime -> False
                Broke {} -> False
                Continued {} -> False

stateHasValue :: IntegerFacts -> ResolvedName -> Integer -> Bool
stateHasValue facts name value = case lookupIntegerFact facts (resolvedSymbol name) of
    Nothing -> not (isUnreachableFacts facts)
    Just fact -> factContains fact value

breakSkipsBodyTail :: Bool
breakSkipsBodyTail =
    let loop =
            CoreWhile
                trueLiteral
                [CoreBreak, assignIndex (integerLiteral 999)]
        facts = initialFacts 1
        environment = Map.singleton (resolvedSymbol indexName) (IntegerValue 1)
     in case loopFactSummary facts loop of
            Nothing -> False
            Just summary -> case executeStatement 64 environment loop of
                Completed final ->
                    runtimeInteger indexName final == Just 1
                        && stateContains summary indexName 1
                _ -> False

continueCycleHasNoExit :: Bool
continueCycleHasNoExit =
    let loop =
            CoreWhile
                (compareInteger CoreLessThan indexVariable (integerLiteral 2))
                [CoreContinue, assignIndex (integerLiteral 999)]
        facts = initialFacts 0
        environment = Map.singleton (resolvedSymbol indexName) (IntegerValue 0)
     in case loopFactSummary facts loop of
            Nothing -> False
            Just summary ->
                isUnreachableFacts (loopExitFacts summary)
                    && case executeStatement 8 environment loop of
                        FuelExhausted -> True
                        _ -> False

scenarioExitIsContained :: Integer -> [(ResolvedName, Integer)] -> CoreStatement -> Bool
scenarioExitIsContained initial additionalValues loop =
    let facts = foldr (uncurry bindFact) (initialFacts initial) additionalValues
        environment =
            Map.fromList
                ((resolvedSymbol indexName, IntegerValue initial) : map toEntry additionalValues)
     in case loopFactSummary facts loop of
            Nothing -> False
            Just summary -> case executeStatement 64 environment loop of
                Completed final ->
                    maybe False (stateContains summary indexName) (runtimeInteger indexName final)
                FuelExhausted -> False
                UnsupportedRuntime -> False
                Returned {} -> False
                Broke {} -> False
                Continued {} -> False
    where
        toEntry (name, value) = (resolvedSymbol name, IntegerValue value)

initialFacts :: Integer -> IntegerFacts
initialFacts value = bindFact indexName value emptyIntegerFacts

bindFact :: ResolvedName -> Integer -> IntegerFacts -> IntegerFacts
bindFact name value facts =
    transferStatementFacts
        facts
        (CoreBind (CoreBinding name intType True (integerLiteral value)))

stateContains :: LoopFactSummary -> ResolvedName -> Integer -> Bool
stateContains summary name value = case lookupIntegerFact (loopExitFacts summary) (resolvedSymbol name) of
    Nothing -> not (isUnreachableFacts (loopExitFacts summary))
    Just fact -> factContains fact value

factContains :: IntegerFact -> Integer -> Bool
factContains fact value =
    maybe True (<= value) (integerMinimum fact)
        && maybe True (>= value) (integerMaximum fact)
        && not (value == 0 && integerExcludesZero fact)

data RuntimeValue
    = IntegerValue Integer
    | BooleanValue Bool
    deriving (Eq, Ord, Read, Show)

type Runtime = Map SymbolId RuntimeValue

data RuntimeResult
    = Completed Runtime
    | Returned Runtime
    | Broke Runtime
    | Continued Runtime
    | FuelExhausted
    | UnsupportedRuntime
    deriving (Eq, Ord, Read, Show)

executeStatement :: Int -> Runtime -> CoreStatement -> RuntimeResult
executeStatement fuel environment statement = case statement of
    CoreBind binding ->
        case evaluateExpression environment (coreBindingValue binding) of
            Just value -> Completed (Map.insert (resolvedSymbol (coreBindingName binding)) value environment)
            Nothing -> UnsupportedRuntime
    CoreAssign name expression ->
        case evaluateExpression environment expression of
            Just value -> Completed (Map.insert (resolvedSymbol name) value environment)
            Nothing -> UnsupportedRuntime
    CoreReturn expression ->
        maybe UnsupportedRuntime (const (Returned environment)) (evaluateExpression environment expression)
    CoreIf condition whenTrue whenFalse -> doBranch fuel environment condition whenTrue whenFalse
    CoreEvaluate expression -> maybe UnsupportedRuntime (const (Completed environment)) (evaluateExpression environment expression)
    CoreWhile condition body -> runWhile fuel environment condition body
    CoreDoWhile body condition -> runDoWhile fuel environment body condition
    CoreFor condition body update -> runFor fuel environment condition body update
    CoreBreak -> Broke environment
    CoreContinue -> Continued environment

executeStatements :: Int -> Runtime -> [CoreStatement] -> RuntimeResult
executeStatements _ environment [] = Completed environment
executeStatements fuel environment (statement : remaining) =
    case executeStatement fuel environment statement of
        Completed next -> executeStatements fuel next remaining
        abrupt -> abrupt

doBranch :: Int -> Runtime -> CoreExpression -> [CoreStatement] -> [CoreStatement] -> RuntimeResult
doBranch fuel environment condition whenTrue whenFalse =
    case evaluateExpression environment condition of
        Just (BooleanValue True) -> executeStatements fuel environment whenTrue
        Just (BooleanValue False) -> executeStatements fuel environment whenFalse
        _ -> UnsupportedRuntime

runWhile :: Int -> Runtime -> CoreExpression -> [CoreStatement] -> RuntimeResult
runWhile fuel environment condition body
    | fuel <= 0 = FuelExhausted
    | otherwise = case evaluateExpression environment condition of
        Just (BooleanValue False) -> Completed environment
        Just (BooleanValue True) ->
            case executeStatements (fuel - 1) environment body of
                Completed next -> runWhile (fuel - 1) next condition body
                Continued next -> runWhile (fuel - 1) next condition body
                Broke next -> Completed next
                abrupt -> abrupt
        _ -> UnsupportedRuntime

runDoWhile :: Int -> Runtime -> [CoreStatement] -> CoreExpression -> RuntimeResult
runDoWhile fuel environment body condition
    | fuel <= 0 = FuelExhausted
    | otherwise = case executeStatements (fuel - 1) environment body of
        Broke next -> Completed next
        Returned next -> Returned next
        UnsupportedRuntime -> UnsupportedRuntime
        FuelExhausted -> FuelExhausted
        Continued next -> testAgain (fuel - 1) next
        Completed next -> testAgain (fuel - 1) next
    where
        testAgain remaining next = case evaluateExpression next condition of
            Just (BooleanValue False) -> Completed next
            Just (BooleanValue True) -> runDoWhile remaining next body condition
            _ -> UnsupportedRuntime

runFor :: Int -> Runtime -> CoreExpression -> [CoreStatement] -> [CoreStatement] -> RuntimeResult
runFor fuel environment condition body update
    | fuel <= 0 = FuelExhausted
    | otherwise = case evaluateExpression environment condition of
        Just (BooleanValue False) -> Completed environment
        Just (BooleanValue True) ->
            case executeStatements (fuel - 1) environment body of
                Broke next -> Completed next
                Returned next -> Returned next
                UnsupportedRuntime -> UnsupportedRuntime
                FuelExhausted -> FuelExhausted
                Completed next -> updateThenRepeat (fuel - 1) next
                Continued next -> updateThenRepeat (fuel - 1) next
        _ -> UnsupportedRuntime
    where
        updateThenRepeat remaining next = case executeStatements remaining next update of
            Broke afterUpdate -> Completed afterUpdate
            Returned afterUpdate -> Returned afterUpdate
            UnsupportedRuntime -> UnsupportedRuntime
            FuelExhausted -> FuelExhausted
            Completed afterUpdate -> runFor remaining afterUpdate condition body update
            Continued afterUpdate -> runFor remaining afterUpdate condition body update

evaluateExpression :: Runtime -> CoreExpression -> Maybe RuntimeValue
evaluateExpression environment expression = case expression of
    CoreVariable name _ -> Map.lookup (resolvedSymbol name) environment
    CoreLiteral (CoreInteger value) _ -> Just (IntegerValue value)
    CoreLiteral (CoreBoolean value) _ -> Just (BooleanValue value)
    CorePrimitive CoreLogicalAnd [left, right] _ -> do
        BooleanValue leftValue <- evaluateExpression environment left
        if leftValue then evaluateExpression environment right else pure (BooleanValue False)
    CorePrimitive CoreLogicalOr [left, right] _ -> do
        BooleanValue leftValue <- evaluateExpression environment left
        if leftValue then pure (BooleanValue True) else evaluateExpression environment right
    CorePrimitive CoreLogicalNot [value] _ -> do
        BooleanValue boolean <- evaluateExpression environment value
        pure (BooleanValue (not boolean))
    CorePrimitive primitive [left, right] _ -> do
        leftValue <- evaluateExpression environment left
        rightValue <- evaluateExpression environment right
        evaluateBinary primitive leftValue rightValue
    _ -> Nothing

evaluateBinary :: CorePrimitive -> RuntimeValue -> RuntimeValue -> Maybe RuntimeValue
evaluateBinary primitive left right = case (primitive, left, right) of
    (CoreAdd, IntegerValue first, IntegerValue second) -> Just (IntegerValue (first + second))
    (CoreSubtract, IntegerValue first, IntegerValue second) -> Just (IntegerValue (first - second))
    (CoreEqual, first, second) -> Just (BooleanValue (first == second))
    (CoreNotEqual, first, second) -> Just (BooleanValue (first /= second))
    (CoreLessThan, IntegerValue first, IntegerValue second) -> Just (BooleanValue (first < second))
    (CoreLessEqual, IntegerValue first, IntegerValue second) -> Just (BooleanValue (first <= second))
    (CoreGreaterThan, IntegerValue first, IntegerValue second) -> Just (BooleanValue (first > second))
    (CoreGreaterEqual, IntegerValue first, IntegerValue second) -> Just (BooleanValue (first >= second))
    _ -> Nothing

runtimeInteger :: ResolvedName -> Runtime -> Maybe Integer
runtimeInteger name environment = case Map.lookup (resolvedSymbol name) environment of
    Just (IntegerValue value) -> Just value
    _ -> Nothing

assignIndex :: CoreExpression -> CoreStatement
assignIndex = CoreAssign indexName

addInteger :: CoreExpression -> Integer -> CoreExpression
addInteger left right = CorePrimitive CoreAdd [left, integerLiteral right] intType

compareInteger :: CorePrimitive -> CoreExpression -> CoreExpression -> CoreExpression
compareInteger primitive left right = CorePrimitive primitive [left, right] boolType

integerLiteral :: Integer -> CoreExpression
integerLiteral value = CoreLiteral (CoreInteger value) intType

trueLiteral :: CoreExpression
trueLiteral = CoreLiteral (CoreBoolean True) boolType

falseLiteral :: CoreExpression
falseLiteral = CoreLiteral (CoreBoolean False) boolType

indexVariable :: CoreExpression
indexVariable = CoreVariable indexName intType

indexName, flagName :: ResolvedName
indexName = resolved 10 "index"
flagName = resolved 11 "flag"

resolved :: Int -> String -> ResolvedName
resolved symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)
