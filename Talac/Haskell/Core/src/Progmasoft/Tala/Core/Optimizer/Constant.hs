-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Progmasoft.Tala.Core.Optimizer.Constant
    ( propagateConstants
    , simplifyExpression
    ) where

import Data.Bits (complement, shiftL, shiftR, xor, (.&.), (.|.))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer.Floating (floatingTruthValue, foldFloatingPrimitive)
import Progmasoft.Tala.Core.Optimizer.IntegerFacts
import Progmasoft.Tala.Core.Scalar (coreIntegerBitWidth, coreIntegerIsSigned, integerFitsCoreType)

type ConstantEnvironment = Map SymbolId CoreExpression

propagateConstants :: CoreModule -> CoreModule
propagateConstants moduleValue =
    moduleValue {coreModuleFunctions = map simplifyFunction (coreModuleFunctions moduleValue)}

simplifyFunction :: CoreFunction -> CoreFunction
simplifyFunction function =
    let (body, _, _) = simplifyStatements Map.empty emptyIntegerFacts (coreFunctionBody function)
     in function {coreFunctionBody = body}

simplifyStatements ::
    ConstantEnvironment -> IntegerFacts -> [CoreStatement] -> ([CoreStatement], ConstantEnvironment, IntegerFacts)
simplifyStatements environment facts [] = ([], environment, facts)
simplifyStatements environment facts (statement : remaining) =
    let (simplified, nextEnvironment, nextFacts) = simplifyStatement environment facts statement
        (rest, finalEnvironment, finalFacts) =
            if statementAlwaysReturns simplified
                then ([], nextEnvironment, nextFacts)
                else simplifyStatements nextEnvironment nextFacts remaining
     in (simplified : rest, finalEnvironment, finalFacts)

simplifyStatement ::
    ConstantEnvironment -> IntegerFacts -> CoreStatement -> (CoreStatement, ConstantEnvironment, IntegerFacts)
simplifyStatement environment facts statement = case statement of
    CoreBind binding ->
        let value = simplifyExpressionWithFacts environment facts (coreBindingValue binding)
            changed = binding {coreBindingValue = value}
            nextEnvironment
                | not (coreBindingMutable binding)
                , isPropagatable value =
                    Map.insert (resolvedSymbol (coreBindingName binding)) value environment
                | otherwise = Map.delete (resolvedSymbol (coreBindingName binding)) environment
            nextFacts = transferStatementFacts facts (CoreBind changed)
         in (CoreBind changed, nextEnvironment, nextFacts)
    CoreAssign name value ->
        let simplified = simplifyExpressionWithFacts environment facts value
            changed = CoreAssign name simplified
         in (changed, Map.delete (resolvedSymbol name) environment, transferStatementFacts facts changed)
    CoreReturn value ->
        let simplified = simplifyExpressionWithFacts environment facts value
            changed = CoreReturn simplified
         in (changed, environment, transferStatementFacts facts changed)
    CoreEvaluate value ->
        let simplified = simplifyExpressionWithFacts environment facts value
            changed = CoreEvaluate simplified
         in (changed, environment, transferStatementFacts facts changed)
    CoreIf condition yes no ->
        let simplifiedCondition = simplifyExpressionWithFacts environment facts condition
            afterCondition = transferExpressionFacts facts simplifiedCondition
            trueInput = refineConditionFacts True simplifiedCondition afterCondition
            falseInput = refineConditionFacts False simplifiedCondition afterCondition
            (simplifiedYes, trueConstants, trueFacts) = simplifyStatements environment trueInput yes
            (simplifiedNo, falseConstants, falseFacts) = simplifyStatements environment falseInput no
            changed = CoreIf simplifiedCondition simplifiedYes simplifiedNo
            knownTruth = conditionTruthFromFacts afterCondition simplifiedCondition
            nextConstants = case knownTruth of
                Just True -> trueConstants
                Just False -> falseConstants
                Nothing -> joinConstants environment trueConstants falseConstants
            nextFacts = case knownTruth of
                Just True -> trueFacts
                Just False -> falseFacts
                Nothing -> case (statementsAlwaysReturn simplifiedYes, statementsAlwaysReturn simplifiedNo) of
                    (True, False) -> falseFacts
                    (False, True) -> trueFacts
                    (True, True) -> emptyIntegerFacts
                    (False, False) -> joinIntegerFacts trueFacts falseFacts
         in (changed, nextConstants, nextFacts)
    CoreWhile condition body ->
        let loop = CoreWhile condition body
         in case loopFactSummary facts loop of
                Nothing -> (loop, Map.empty, emptyIntegerFacts)
                Just summary ->
                    let rewrittenCondition =
                            simplifyExpressionWithFacts environment (loopConditionFacts summary) condition
                        (rewrittenBody, _, _) =
                            simplifyStatements Map.empty (loopBodyFacts summary) body
                     in (CoreWhile rewrittenCondition rewrittenBody, Map.empty, loopExitFacts summary)
    CoreDoWhile body condition ->
        let loop = CoreDoWhile body condition
         in case loopFactSummary facts loop of
                Nothing -> (loop, Map.empty, emptyIntegerFacts)
                Just summary ->
                    let (rewrittenBody, _, _) =
                            simplifyStatements Map.empty (loopBodyFacts summary) body
                        rewrittenCondition =
                            simplifyExpressionWithFacts Map.empty (loopConditionFacts summary) condition
                     in (CoreDoWhile rewrittenBody rewrittenCondition, Map.empty, loopExitFacts summary)
    CoreFor condition body update ->
        let loop = CoreFor condition body update
         in case loopFactSummary facts loop of
                Nothing -> (loop, Map.empty, emptyIntegerFacts)
                Just summary ->
                    let rewrittenCondition =
                            simplifyExpressionWithFacts environment (loopConditionFacts summary) condition
                        (rewrittenBody, _, _) =
                            simplifyStatements Map.empty (loopBodyFacts summary) body
                        (rewrittenUpdate, _, _) =
                            simplifyStatements Map.empty (loopUpdateFacts summary) update
                     in (CoreFor rewrittenCondition rewrittenBody rewrittenUpdate, Map.empty, loopExitFacts summary)
    CoreBreak -> (CoreBreak, environment, unreachableIntegerFacts)
    CoreContinue -> (CoreContinue, environment, unreachableIntegerFacts)

joinConstants :: ConstantEnvironment -> ConstantEnvironment -> ConstantEnvironment -> ConstantEnvironment
joinConstants incoming whenTrue whenFalse =
    Map.filterWithKey common incoming
    where
        common symbol _ = Map.lookup symbol whenTrue == Map.lookup symbol whenFalse

statementAlwaysReturns :: CoreStatement -> Bool
statementAlwaysReturns statement = case statement of
    CoreReturn _ -> True
    CoreIf _ whenTrue whenFalse ->
        not (null whenFalse) && statementsAlwaysReturn whenTrue && statementsAlwaysReturn whenFalse
    _ -> False

statementsAlwaysReturn :: [CoreStatement] -> Bool
statementsAlwaysReturn [] = False
statementsAlwaysReturn (statement : remaining) = statementAlwaysReturns statement || statementsAlwaysReturn remaining

-- Propagation is intentionally limited to literals. Duplicating calls,
-- closure allocations, or arbitrary primitive trees could change effects or
-- grow code. Algebraic simplification still operates on the use site.
isPropagatable :: CoreExpression -> Bool
isPropagatable CoreLiteral {} = True
isPropagatable _ = False

simplifyExpression :: ConstantEnvironment -> CoreExpression -> CoreExpression
simplifyExpression environment = simplifyExpressionUsing environment emptyIntegerFacts

simplifyExpressionWithFacts :: ConstantEnvironment -> IntegerFacts -> CoreExpression -> CoreExpression
simplifyExpressionWithFacts environment facts expression =
    simplifyExpressionUsing environment effectiveFacts expression
    where
        effectiveFacts
            | expressionInvokesCallable expression = emptyIntegerFacts
            | otherwise = facts

simplifyExpressionUsing :: ConstantEnvironment -> IntegerFacts -> CoreExpression -> CoreExpression
simplifyExpressionUsing environment facts expression = case expression of
    CoreVariable name valueType ->
        case Map.lookup (resolvedSymbol name) environment of
            Just constant | expressionType constant == valueType -> constant
            _ -> expression
    CoreLiteral {} -> expression
    CoreApply callee arguments valueType ->
        CoreApply
            (simplifyExpressionUsing environment facts callee)
            (map (simplifyExpressionUsing environment facts) arguments)
            valueType
    CorePrimitive primitive arguments valueType ->
        -- The facts are consulted for Boolean results only. Asking them
        -- about every node would evaluate the whole operand tree again at
        -- each level of an operator chain, which is quadratic in its length.
        let simplified = foldPrimitive primitive (map (simplifyExpressionUsing environment facts) arguments) valueType
         in if valueType /= boolType || not (withinFactQueryBudget simplified)
                then simplified
                else case conditionTruthFromFacts facts simplified of
                    Just truth -> CoreLiteral (CoreBoolean truth) boolType
                    Nothing -> simplified
    CoreLet name bindingType value body valueType ->
        let simplifiedValue = simplifyExpressionUsing environment facts value
            bodyEnvironment =
                if isPropagatable simplifiedValue
                    then Map.insert (resolvedSymbol name) simplifiedValue environment
                    else Map.delete (resolvedSymbol name) environment
            bodyFacts = transferStatementFacts facts (CoreBind (CoreBinding name bindingType False simplifiedValue))
         in CoreLet name bindingType simplifiedValue (simplifyExpressionWithFacts bodyEnvironment bodyFacts body) valueType
    CoreConditional condition whenTrue whenFalse valueType ->
        let simplifiedCondition = simplifyExpressionUsing environment facts condition
            afterCondition = transferExpressionFacts facts simplifiedCondition
            simplifyArm desired =
                simplifyExpressionWithFacts
                    environment
                    (refineConditionFacts desired simplifiedCondition afterCondition)
         in -- A literal test has no effects, so the conditional is its selected arm.
            case simplifiedCondition of
                CoreLiteral (CoreBoolean selected) _ ->
                    if selected then simplifyArm True whenTrue else simplifyArm False whenFalse
                CoreLiteral (CoreInteger selected) _ ->
                    if selected /= 0 then simplifyArm True whenTrue else simplifyArm False whenFalse
                _ -> CoreConditional simplifiedCondition (simplifyArm True whenTrue) (simplifyArm False whenFalse) valueType
    CoreClosure captures parameters returnType body valueType ->
        let simplifiedCaptures = map simplifyCapture captures
            captureConstants =
                [ (resolvedSymbol (coreCaptureName capture), coreCaptureValue capture)
                | capture <- simplifiedCaptures
                , isPropagatable (coreCaptureValue capture)
                ]
            parameterSymbols = map (resolvedSymbol . fst) parameters
            bodyEnvironment = foldr Map.delete (Map.fromList captureConstants) parameterSymbols
            -- Captures may name mutable storage through a cell. Constant
            -- propagation preserves the legacy literal case above, but a
            -- zero-ness proof must not assume that a captured value stays
            -- unchanged between closure creation and invocation.
            bodyFacts = emptyIntegerFacts
            (simplifiedBody, _, _) = simplifyStatements bodyEnvironment bodyFacts body
         in CoreClosure simplifiedCaptures parameters returnType simplifiedBody valueType
    where
        simplifyCapture capture =
            capture {coreCaptureValue = simplifyExpressionWithFacts environment facts (coreCaptureValue capture)}

{- | The largest condition, in expression nodes, whose truth is looked up in
the integer facts while it is simplified.

The lookup walks the condition, and it is made at every Boolean node from
the leaves up, so on a chain of @&&@ or @||@ its cost grows with a power of
the length of the chain: 200 comparisons took 47 seconds. A condition of
ordinary size is far below the budget. A longer one is still simplified by
folding; only the facts are not asked about its larger parts.
-}
factQueryNodeBudget :: Int
factQueryNodeBudget = 256

{- | Whether an expression has at most 'factQueryNodeBudget' nodes; the
count stops as soon as the budget is exceeded.
-}
withinFactQueryBudget :: CoreExpression -> Bool
withinFactQueryBudget root = go factQueryNodeBudget [root]
    where
        go _ [] = True
        go remaining (expression : pending)
            | remaining <= 0 = False
            | otherwise = go (remaining - 1) (children expression ++ pending)
        children expression = case expression of
            CoreVariable {} -> []
            CoreLiteral {} -> []
            CoreApply callee arguments _ -> callee : arguments
            CorePrimitive _ arguments _ -> arguments
            CoreLet _ _ value body _ -> [value, body]
            CoreConditional condition whenTrue whenFalse _ -> [condition, whenTrue, whenFalse]
            CoreClosure captures _ _ _ _ -> map coreCaptureValue captures

foldPrimitive :: CorePrimitive -> [CoreExpression] -> Type -> CoreExpression
foldPrimitive primitive arguments valueType =
    case evaluatePrimitive primitive arguments valueType of
        Just folded -> folded
        Nothing -> simplifyIdentity primitive arguments valueType

evaluatePrimitive :: CorePrimitive -> [CoreExpression] -> Type -> Maybe CoreExpression
evaluatePrimitive primitive arguments valueType =
    case (primitive, mapM integerLiteral arguments) of
        (CoreAdd, Just [a, b]) -> integer (a + b)
        (CoreSubtract, Just [a, b]) -> integer (a - b)
        (CoreMultiply, Just [a, b]) -> integer (a * b)
        (CoreDivide, Just [a, b]) | b /= 0 -> integer (a `quot` b)
        (CoreFloorDivide, Just [a, b]) | b /= 0 -> integer (roundedIntegerDivision a b)
        (CoreRemainder, Just [a, b]) | b /= 0 -> integer (a `rem` b)
        (CoreNegate, Just [value]) -> integer (-value)
        (CorePower, Just [base, exponentValue]) -> integerPower base exponentValue
        (CoreShiftLeft, Just [value, amount]) -> shiftInteger shiftL value amount
        (CoreShiftRight, Just [value, amount]) -> shiftInteger shiftR value amount
        (CoreBitwiseNot, Just [value]) -> bitwiseComplement value
        (CoreBitwiseAnd, Just [a, b]) -> integer (a .&. b)
        (CoreBitwiseXor, Just [a, b]) -> integer (xor a b)
        (CoreBitwiseOr, Just [a, b]) -> integer (a .|. b)
        (CoreBitwiseNot, Just [value]) -> integer (complement value)
        (CoreLessThan, Just [a, b]) -> Just (boolean (a < b))
        (CoreLessEqual, Just [a, b]) -> Just (boolean (a <= b))
        (CoreGreaterThan, Just [a, b]) -> Just (boolean (a > b))
        (CoreGreaterEqual, Just [a, b]) -> Just (boolean (a >= b))
        (CoreEqual, Just [a, b]) -> Just (boolean (a == b))
        (CoreNotEqual, Just [a, b]) -> Just (boolean (a /= b))
        _ -> case foldFloatingPrimitive primitive arguments valueType of
            Just folded -> Just folded
            Nothing -> evaluateBoolean primitive arguments
    where
        integer result
            | integerFitsCoreType valueType result = Just (CoreLiteral (CoreInteger result) valueType)
            | otherwise = Nothing
        boolean result = CoreLiteral (CoreBoolean result) boolType
        integerPower base exponentValue = boundedPower base exponentValue
        boundedPower base exponentValue
            | exponentValue < 0 = Nothing
            | base == 0 = integer (if exponentValue == 0 then 1 else 0)
            | base == 1 = integer 1
            | base == -1 = integer (if even exponentValue then 1 else -1)
            | otherwise = powerLoop 1 base exponentValue
        powerLoop accumulated factor remaining
            | remaining == 0 = integer accumulated
            | otherwise =
                let (nextAccumulated, canContinue) =
                        if odd remaining
                            then
                                let nextProduct = accumulated * factor
                                 in (nextProduct, integerFitsCoreType valueType nextProduct)
                            else (accumulated, True)
                    nextRemaining = remaining `quot` 2
                 in if not canContinue
                        then Nothing
                        else
                            if nextRemaining == 0
                                then integer nextAccumulated
                                else
                                    let squaredFactor = factor * factor
                                     in if integerFitsCoreType valueType squaredFactor
                                            then powerLoop nextAccumulated squaredFactor nextRemaining
                                            else Nothing
        shiftInteger shift value amount = do
            width <- coreIntegerBitWidth valueType
            if amount < 0 || amount >= toInteger width
                then Nothing
                else integer (shift value (fromInteger amount))
        bitwiseComplement value = do
            width <- coreIntegerBitWidth valueType
            isSigned <- coreIntegerIsSigned valueType
            let complemented =
                    if isSigned
                        then complement value
                        else complement value .&. ((1 `shiftL` width) - 1)
            integer complemented

roundedIntegerDivision :: Integer -> Integer -> Integer
roundedIntegerDivision dividend divisor =
    let (quotient, remainder) = dividend `quotRem` divisor
        adjustment = signum dividend * signum divisor
     in if 2 * abs remainder >= abs divisor then quotient + adjustment else quotient

evaluateBoolean :: CorePrimitive -> [CoreExpression] -> Maybe CoreExpression
evaluateBoolean primitive arguments = case (primitive, mapM truthValue arguments) of
    -- Equality compares Boolean values only here. Numeric equality has its own
    -- exact-value rule above and must never fall back to truthiness comparison.
    (CoreEqual, Just [left, right]) | all booleanLiteral arguments -> Just (boolean (left == right))
    (CoreNotEqual, Just [left, right]) | all booleanLiteral arguments -> Just (boolean (left /= right))
    (CoreLogicalNot, Just [value]) -> Just (boolean (not value))
    (CoreLogicalAnd, Just [left, right]) -> Just (boolean (left && right))
    (CoreLogicalOr, Just [left, right]) -> Just (boolean (left || right))
    _ -> Nothing
    where
        boolean result = CoreLiteral (CoreBoolean result) boolType

booleanLiteral :: CoreExpression -> Bool
booleanLiteral (CoreLiteral (CoreBoolean _) _) = True
booleanLiteral _ = False

-- View patterns would obscure the data-flow rules in diagnostics, so literal
-- extraction remains explicit and total.
integerLiteral :: CoreExpression -> Maybe Integer
integerLiteral (CoreLiteral (CoreInteger value) _) = Just value
integerLiteral _ = Nothing

truthValue :: CoreExpression -> Maybe Bool
truthValue (CoreLiteral (CoreBoolean value) _) = Just value
truthValue (CoreLiteral (CoreInteger value) _) = Just (value /= 0)
truthValue expression@CoreLiteral {} = floatingTruthValue expression
truthValue _ = Nothing

simplifyIdentity :: CorePrimitive -> [CoreExpression] -> Type -> CoreExpression
simplifyIdentity primitive arguments valueType = case (primitive, arguments) of
    (CoreAdd, [value, zero]) | isIntegerLiteral 0 zero -> value
    (CoreAdd, [zero, value]) | isIntegerLiteral 0 zero -> value
    (CoreSubtract, [value, zero]) | isIntegerLiteral 0 zero -> value
    (CoreMultiply, [value, one]) | isIntegerLiteral 1 one -> value
    (CoreMultiply, [one, value]) | isIntegerLiteral 1 one -> value
    (CoreDivide, [value, one]) | isIntegerLiteral 1 one -> value
    (CoreFloorDivide, [value, one])
        | isIntegerLiteral 1 one
        , expressionType value == valueType ->
            value
    (CoreRemainder, [value, one])
        | isIntegerLiteral 1 one, isSimpleValue value -> CoreLiteral (CoreInteger 0) valueType
    (CoreNegate, [CorePrimitive CoreNegate [value] innerType])
        | innerType == valueType -> value
    (CoreLogicalNot, [CorePrimitive CoreLogicalNot [value] innerType])
        | innerType == boolType, expressionType value == boolType -> value
    _ -> CorePrimitive primitive arguments valueType

-- Remainder-by-one may erase evaluation only for values which cannot carry
-- an effect. More general expressions remain intact until an effect-aware
-- rewrite can preserve their evaluation explicitly.
isSimpleValue :: CoreExpression -> Bool
isSimpleValue CoreVariable {} = True
isSimpleValue CoreLiteral {} = True
isSimpleValue _ = False

isIntegerLiteral :: Integer -> CoreExpression -> Bool
isIntegerLiteral expected expression = integerLiteral expression == Just expected
