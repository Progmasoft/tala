-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module IntegerFlowTests (integerFlowTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Scalar (coreIntegerBitWidth, coreIntegerIsSigned, coreIntegerTypeNames)
import Prelude hiding (compare)

integerFlowTests :: [(String, Bool)]
integerFlowTests =
    [ ("unguarded integer division remains failure-capable", effectIs FailureEffect unguardedDivision)
    , ("unguarded floor division remains failure-capable", effectIs FailureEffect unguardedFloorDivision)
    , ("unguarded remainder remains failure-capable", effectIs FailureEffect unguardedRemainder)
    , ("x != 0 true edge proves a safe divisor", effectIs PureEffect guardedNotEqual)
    , ("x == 0 false edge proves a safe divisor", effectIs PureEffect guardedFalseEqual)
    , ("zero on the left is normalized", effectIs PureEffect guardedReversedComparison)
    ,
        ( "positive and negative ranges prove nonzero"
        , effectIs PureEffect guardedPositive && effectIs PureEffect guardedNegative
        )
    ,
        ( "false <= and >= comparisons prove nonzero"
        , effectIs PureEffect guardedFalseLessEqual && effectIs PureEffect guardedFalseGreaterEqual
        )
    , ("the zero-valued path remains failure-capable", effectIs FailureEffect guardedZeroEdge)
    , ("assignment to zero invalidates a nonzero proof", effectIs FailureEffect assignedZero)
    , ("assignment to nonzero establishes a fresh proof", effectIs PureEffect assignedNonzero)
    , ("calls invalidate facts established by a guard", effectIs CallEffect callAfterGuard)
    , ("calls inside conditions do not leak facts", effectIs CallEffect callInCondition)
    , ("a guard after a call can establish a fresh divisor fact", callBeforeGuardRemovesDeadDivision)
    , ("a call after a guard invalidates the divisor fact", callAfterGuardKeepsDeadDivision)
    , ("false logical-and skips a failure-capable right operand", falseAndSkipsFailure)
    , ("true logical-or skips a failure-capable right operand", trueOrSkipsFailure)
    , ("short-circuit right operand uses its path facts", guardedLogicalRightIsDiscardable)
    , ("conjunction true edges combine operand facts", effectIs PureEffect guardedConjunction)
    , ("disjunction true edges preserve common facts", effectIs PureEffect guardedDisjunction)
    , ("false conjunction joins retain shared facts", effectIs PureEffect falseConjunction)
    , ("false disjunction proves both operands false", effectIs PureEffect falseDisjunction)
    , ("nested contradictory branches are folded", nestedContradictionIsRemoved)
    , ("conflicting branch assignments drop facts", effectIs FailureEffect conflictingJoin)
    , ("equivalent branch assignments retain facts", effectIs PureEffect commonJoin)
    , ("a guarded closure body retains its proof", closureBodyRetainsGuard)
    , ("all failure-capable integer primitives use the same proof", guardedOperatorMatrix)
    , ("comparison direction and operand order are conservative", comparisonMatrix)
    , ("branch-edge mutation updates the abstract state", branchMutationMatrix)
    , ("integer comparison bounds fold contradictory paths", contradictoryBoundsAreRemoved)
    , ("integer comparison bounds fold redundant tests", redundantBoundTestIsRemoved)
    , ("type limits seed range facts", unsignedComparisonUsesTypeRange)
    , ("proved facts survive a join when both paths exclude zero", nonzeroJoinSurvives)
    , ("arithmetic range facts compose through mutable locals", arithmeticFactSurvivesBinding)
    , ("arithmetic overflow discards an interval proof", overflowingArithmeticIsConservative)
    , ("equality transfers a nonzero fact between symbols", equalityTransfersNonzero)
    , ("equality intersects both operand ranges", equalityIntersectsRanges)
    , ("false equality transfers zero exclusion", falseEqualityTransfersNonzero)
    , ("strict ordering transfers a positive lower bound", orderingTransfersPositiveBound)
    , ("strict ordering transfers a negative upper bound", orderingTransfersNegativeBound)
    , ("ordering false edges transfer inverse bounds", orderingFalseEdgeTransfersBound)
    , ("same-symbol comparisons select their only feasible edge", sameSymbolComparisonIsFolded)
    , ("disjoint integer intervals fold equality", disjointIntervalsFoldEquality)
    , ("disjoint integer intervals fold ordering", disjointIntervalsFoldOrdering)
    , ("bounded arithmetic agrees with the concrete interval oracle", arithmeticRangeMatrix)
    , ("every integer type seeds its exact signed boundary", integerTypeBoundaryMatrix)
    ]
        ++ boundedComparisonCases
        ++ relationalComparisonCases
        ++ [("bounded comparisons match the integer oracle", boundedComparisonMatrix)]

guardedOperatorMatrix :: Bool
guardedOperatorMatrix = all (effectIs PureEffect . guardedPrimitive) [CoreDivide, CoreFloorDivide, CoreRemainder]

comparisonMatrix :: Bool
comparisonMatrix = all check comparisons
    where
        comparisons =
            [ (CoreNotEqual, True, True)
            , (CoreNotEqual, False, False)
            , (CoreEqual, True, False)
            , (CoreEqual, False, True)
            , (CoreGreaterThan, True, True)
            , (CoreGreaterThan, False, False)
            , (CoreLessThan, True, True)
            , (CoreLessThan, False, False)
            , (CoreGreaterEqual, True, False)
            , (CoreGreaterEqual, False, True)
            , (CoreLessEqual, True, False)
            , (CoreLessEqual, False, True)
            ]
        check (operator, truth, proof) =
            let expected = if proof then PureEffect else FailureEffect
             in effectIs expected (comparisonGuard operator truth False)
                    && effectIs expected (comparisonGuard operator truth True)

branchMutationMatrix :: Bool
branchMutationMatrix =
    all check [(True, 0), (True, 8), (False, 0), (False, 8)]
    where
        check (trueEdge, assigned) =
            effectIs (if assigned == 0 then FailureEffect else PureEffect) (mutateGuardedEdge trueEdge assigned)

contradictoryBoundsAreRemoved :: Bool
contradictoryBoundsAreRemoved =
    let condition =
            operationBool
                CoreLogicalAnd
                [compare CoreGreaterThan x (integer 4), compare CoreLessThan x (integer 5)]
        function = intFunction [CoreIf condition [CoreReturn (divide x)] [CoreReturn zero]]
     in effectIs PureEffect function
            && case optimize function of
                Just [CoreReturn (CoreLiteral (CoreInteger 0) _)] -> True
                _ -> False

redundantBoundTestIsRemoved :: Bool
redundantBoundTestIsRemoved =
    let nested =
            CoreIf
                (compare CoreGreaterThan x (integer 8))
                [ CoreIf
                    (compare CoreGreaterThan x (integer 2))
                    [CoreReturn (divide x)]
                    [CoreReturn (integer 99)]
                ]
                [CoreReturn zero]
     in case optimize (intFunction [nested]) of
            Just [CoreIf _ [CoreReturn (CorePrimitive CoreDivide _ _)] [CoreReturn _]] -> True
            _ -> False

unsignedComparisonUsesTypeRange :: Bool
unsignedComparisonUsesTypeRange =
    let parameter = resolved 30 "unsignedValue"
        function =
            CoreFunction
                mainName
                [(parameter, ubyteType)]
                boolType
                [ CoreIf
                    (CorePrimitive CoreLessThan [variable parameter ubyteType, CoreLiteral (CoreInteger 0) ubyteType] boolType)
                    [CoreReturn (CoreLiteral (CoreBoolean True) boolType)]
                    [CoreReturn (CoreLiteral (CoreBoolean False) boolType)]
                ]
     in case optimize function of
            Just [CoreReturn (CoreLiteral (CoreBoolean False) _)] -> True
            _ -> False

nonzeroJoinSurvives :: Bool
nonzeroJoinSurvives =
    let initialize = CoreBind (CoreBinding mutableName intType True x)
        body =
            [ initialize
            , CoreIf
                (compare CoreNotEqual x zero)
                [ CoreIf
                    (variable flagName boolType)
                    [CoreAssign mutableName x]
                    [CoreAssign mutableName (integer 2)]
                , CoreReturn (divide mutableValue)
                ]
                [CoreReturn zero]
            ]
     in effectIs PureEffect (intFunction body)

arithmeticFactSurvivesBinding :: Bool
arithmeticFactSurvivesBinding =
    let local = resolved 31 "local"
        binding = CoreBind (CoreBinding local intType True (integer 0))
        assign = CoreAssign local (CorePrimitive CoreAdd [x, integer 2] intType)
        divideLocal = CoreReturn (divide (variable local intType))
        condition = compare CoreEqual x (integer 3)
     in effectIs PureEffect (intFunction [CoreIf condition [binding, assign, divideLocal] [CoreReturn zero]])

overflowingArithmeticIsConservative :: Bool
overflowingArithmeticIsConservative =
    let maximumInt = CoreLiteral (CoreInteger (2 ^ (63 :: Int) - 1)) intType
        expression = CorePrimitive CoreAdd [x, integer 2] intType
        function =
            intFunction
                [ CoreBind (CoreBinding mutableName intType True maximumInt)
                , CoreAssign mutableName expression
                , CoreReturn (divide mutableValue)
                ]
     in effectIs FailureEffect function

arithmeticRangeMatrix :: Bool
arithmeticRangeMatrix = all check generatedCases
    where
        operators = [CoreAdd, CoreSubtract, CoreMultiply]
        generatedCases =
            [ (operator, lower, upper, constant)
            | operator <- operators
            , lower <- [-2 .. 2]
            , upper <- [lower .. 2]
            , constant <- [-2 .. 2]
            ]
        check (operator, lower, upper, constant) =
            let concreteValues = map (\value -> applyInteger operator value constant) [lower .. upper]
                allNonzero = all (/= 0) concreteValues
                rangeGuard =
                    operationBool
                        CoreLogicalAnd
                        [ compare CoreGreaterEqual x (integer lower)
                        , compare CoreLessEqual x (integer upper)
                        ]
                derivedValue = CorePrimitive operator [x, integer constant] intType
                binding = CoreBind (CoreBinding derivedName intType True derivedValue)
                useDerived = CoreReturn (divide (variable derivedName intType))
                function = intFunction [CoreIf rangeGuard [binding, useDerived] [CoreReturn zero]]
             in effectIs (if allNonzero then PureEffect else FailureEffect) function

applyInteger :: CorePrimitive -> Integer -> Integer -> Integer
applyInteger primitive left right = case primitive of
    CoreAdd -> left + right
    CoreSubtract -> left - right
    CoreMultiply -> left * right
    _ -> left

integerTypeBoundaryMatrix :: Bool
integerTypeBoundaryMatrix = all checkType coreIntegerTypeNames
    where
        checkType typeName =
            case (coreIntegerBitWidth valueType, coreIntegerIsSigned valueType) of
                (Just width, Just signed) ->
                    let magnitude = 2 ^ (width - if signed then 1 else 0)
                        minimumValue = if signed then negate magnitude else 0
                        maximumValue = magnitude - 1
                        belowMinimum = checkComparison CoreLessThan minimumValue False
                        atOrAboveMinimum = checkComparison CoreGreaterEqual minimumValue True
                        aboveMaximum = checkComparison CoreGreaterThan maximumValue False
                        atOrBelowMaximum = checkComparison CoreLessEqual maximumValue True
                     in and [belowMinimum, atOrAboveMinimum, aboveMaximum, atOrBelowMaximum]
                _ -> False
            where
                valueType = namedType typeName
                checkComparison operator boundary expected =
                    let parameter = resolved 50 typeName
                        expression = compare operator (variable parameter valueType) (CoreLiteral (CoreInteger boundary) valueType)
                        function =
                            CoreFunction
                                mainName
                                [(parameter, valueType)]
                                boolType
                                [CoreIf expression [CoreReturn trueValue] [CoreReturn falseValue]]
                     in case optimize function of
                            Just [CoreReturn (CoreLiteral (CoreBoolean actual) _)] -> actual == expected
                            _ -> False
                trueValue = CoreLiteral (CoreBoolean True) boolType
                falseValue = CoreLiteral (CoreBoolean False) boolType

equalityTransfersNonzero :: Bool
equalityTransfersNonzero =
    let condition = operationBool CoreLogicalAnd [compare CoreNotEqual y zero, compare CoreEqual x y]
     in effectIs PureEffect (guarded condition True)

equalityIntersectsRanges :: Bool
equalityIntersectsRanges =
    let condition =
            operationBool
                CoreLogicalAnd
                [ compare CoreGreaterThan x (integer 4)
                , operationBool
                    CoreLogicalAnd
                    [compare CoreLessThan x (integer 9), compare CoreEqual x y]
                ]
     in effectIs PureEffect (guarded condition True)

falseEqualityTransfersNonzero :: Bool
falseEqualityTransfersNonzero =
    let condition = operationBool CoreLogicalAnd [compare CoreEqual y zero, compare CoreNotEqual x y]
     in effectIs PureEffect (guarded condition True)

orderingTransfersPositiveBound :: Bool
orderingTransfersPositiveBound =
    let condition = operationBool CoreLogicalAnd [compare CoreGreaterEqual y zero, compare CoreGreaterThan x y]
     in effectIs PureEffect (guarded condition True)

orderingTransfersNegativeBound :: Bool
orderingTransfersNegativeBound =
    let condition = operationBool CoreLogicalAnd [compare CoreLessEqual y zero, compare CoreLessThan x y]
     in effectIs PureEffect (guarded condition True)

orderingFalseEdgeTransfersBound :: Bool
orderingFalseEdgeTransfersBound =
    let condition = compare CoreLessThan x y
        guardedFunction =
            intFunction
                [ CoreIf
                    (compare CoreGreaterThan y zero)
                    [CoreIf condition [CoreReturn zero] [CoreReturn (divide x)]]
                    [CoreReturn zero]
                ]
     in effectIs PureEffect guardedFunction

sameSymbolComparisonIsFolded :: Bool
sameSymbolComparisonIsFolded =
    all
        check
        [ (CoreEqual, True)
        , (CoreNotEqual, False)
        , (CoreLessThan, False)
        , (CoreLessEqual, True)
        , (CoreGreaterThan, False)
        , (CoreGreaterEqual, True)
        ]
    where
        check (operator, result) =
            let condition = compare operator x x
                whenTrue = if result then [CoreReturn (divide x)] else [CoreReturn zero]
                whenFalse = if result then [CoreReturn zero] else [CoreReturn (divide x)]
                guardedFunction =
                    intFunction
                        [ CoreIf
                            (compare CoreNotEqual x zero)
                            [CoreIf condition whenTrue whenFalse]
                            [CoreReturn zero]
                        ]
             in effectIs PureEffect guardedFunction

disjointIntervalsFoldEquality :: Bool
disjointIntervalsFoldEquality =
    let outer =
            CoreIf
                (compare CoreGreaterThan x (integer 4))
                [ CoreIf
                    (compare CoreLessThan y (integer 0))
                    [ CoreIf
                        (compare CoreEqual x y)
                        [CoreReturn (integer 1)]
                        [CoreReturn (integer 2)]
                    ]
                    [CoreReturn zero]
                ]
                [CoreReturn zero]
     in case optimize (intFunction [outer]) of
            Just [CoreIf _ [CoreIf _ [CoreReturn (CoreLiteral (CoreInteger 2) _)] [CoreReturn _]] [CoreReturn _]] -> True
            _ -> False

disjointIntervalsFoldOrdering :: Bool
disjointIntervalsFoldOrdering =
    let outer =
            CoreIf
                (compare CoreGreaterThan x (integer 4))
                [ CoreIf
                    (compare CoreLessThan y zero)
                    [ CoreIf
                        (compare CoreLessThan x y)
                        [CoreReturn (integer 1)]
                        [CoreReturn (integer 2)]
                    ]
                    [CoreReturn zero]
                ]
                [CoreReturn zero]
     in case optimize (intFunction [outer]) of
            Just [CoreIf _ [CoreIf _ [CoreReturn (CoreLiteral (CoreInteger 2) _)] [CoreReturn _]] [CoreReturn _]] -> True
            _ -> False

boundedComparisonMatrix :: Bool
boundedComparisonMatrix = all snd boundedComparisonCases

boundedComparisonCases :: [(String, Bool)]
boundedComparisonCases = map makeCase generatedCases
    where
        operators = [CoreEqual, CoreNotEqual, CoreLessThan, CoreLessEqual, CoreGreaterThan, CoreGreaterEqual]
        generatedCases =
            [ (operator, boundary, truth, reversed)
            | operator <- operators
            , boundary <- [-3 .. 3]
            , truth <- [False, True]
            , reversed <- [False, True]
            ]
        makeCase (operator, boundary, truth, reversed) =
            ( label operator boundary truth reversed
            , effectIs
                (if comparisonProvesNonzero operator boundary truth reversed then PureEffect else FailureEffect)
                (comparisonAgainstLiteral operator boundary truth reversed)
            )
        label operator boundary truth reversed =
            "oracle " ++ show operator ++ " " ++ show boundary ++ " " ++ show truth ++ " reversed=" ++ show reversed

relationalComparisonCases :: [(String, Bool)]
relationalComparisonCases = map makeCase generatedCases
    where
        operators = [CoreEqual, CoreNotEqual, CoreLessThan, CoreLessEqual, CoreGreaterThan, CoreGreaterEqual]
        generatedCases =
            [ (operator, boundary, truth, reversed)
            | operator <- operators
            , boundary <- [-3 .. 3]
            , truth <- [False, True]
            , reversed <- [False, True]
            ]
        makeCase (operator, boundary, truth, reversed) =
            let normalized = if reversed then reverseComparison operator else operator
             in ( "relational oracle " ++ show operator ++ " " ++ show boundary ++ " true=" ++ show truth ++ " reversed=" ++ show reversed
                , effectIs
                    (if comparisonProvesNonzero normalized boundary truth False then PureEffect else FailureEffect)
                    (comparisonAgainstKnownVariable operator boundary truth reversed)
                )

comparisonAgainstKnownVariable :: CorePrimitive -> Integer -> Bool -> Bool -> CoreFunction
comparisonAgainstKnownVariable operator boundary truth reversed =
    let equality = compare CoreEqual y (integer boundary)
        relation = if reversed then compare operator y x else compare operator x y
        divideArm = [CoreReturn (divide x)]
        safeArm = [CoreReturn zero]
        whenTrue = if truth then divideArm else safeArm
        whenFalse = if truth then safeArm else divideArm
     in intFunction
            [ CoreIf
                equality
                [CoreIf relation whenTrue whenFalse]
                [CoreReturn zero]
            ]

comparisonProvesNonzero :: CorePrimitive -> Integer -> Bool -> Bool -> Bool
comparisonProvesNonzero operator boundary truth reversed = case normalized of
    CoreEqual -> (truth && boundary /= 0) || (not truth && boundary == 0)
    CoreNotEqual -> (truth && boundary == 0) || (not truth && boundary /= 0)
    CoreLessThan -> (truth && boundary <= 0) || (not truth && boundary > 0)
    CoreLessEqual -> (truth && boundary < 0) || (not truth && boundary >= 0)
    CoreGreaterThan -> (truth && boundary >= 0) || (not truth && boundary < 0)
    CoreGreaterEqual -> (truth && boundary > 0) || (not truth && boundary <= 0)
    _ -> False
    where
        normalized = if reversed then reverseComparison operator else operator

reverseComparison :: CorePrimitive -> CorePrimitive
reverseComparison operator = case operator of
    CoreLessThan -> CoreGreaterThan
    CoreLessEqual -> CoreGreaterEqual
    CoreGreaterThan -> CoreLessThan
    CoreGreaterEqual -> CoreLessEqual
    _ -> operator

comparisonAgainstLiteral :: CorePrimitive -> Integer -> Bool -> Bool -> CoreFunction
comparisonAgainstLiteral operator boundary truth reversed =
    let literal = integer boundary
        condition = if reversed then compareReversed operator literal x else compare operator x literal
        divideArm = [CoreReturn (divide x)]
        zeroArm = [CoreReturn zero]
        whenTrue = if truth then divideArm else zeroArm
        whenFalse = if truth then zeroArm else divideArm
     in intFunction [CoreIf condition whenTrue whenFalse]

unguardedDivision, unguardedFloorDivision, unguardedRemainder :: CoreFunction
unguardedDivision = intFunction [CoreReturn (divide x)]
unguardedFloorDivision = intFunction [CoreReturn (operation CoreFloorDivide x)]
unguardedRemainder = intFunction [CoreReturn (operation CoreRemainder x)]

guardedNotEqual, guardedFalseEqual, guardedReversedComparison :: CoreFunction
guardedNotEqual = guarded (compare CoreNotEqual x zero) True
guardedFalseEqual = guarded (compare CoreEqual x zero) False
guardedReversedComparison = guarded (compareReversed CoreNotEqual zero x) True

guardedPositive, guardedNegative, guardedFalseLessEqual, guardedFalseGreaterEqual :: CoreFunction
guardedPositive = guarded (compare CoreGreaterThan x zero) True
guardedNegative = guarded (compare CoreLessThan x zero) True
guardedFalseLessEqual = guarded (compare CoreLessEqual x zero) False
guardedFalseGreaterEqual = guarded (compare CoreGreaterEqual x zero) False
guardedZeroEdge, assignedZero, assignedNonzero :: CoreFunction
guardedZeroEdge = guarded (compare CoreEqual x zero) True
assignedZero = intFunction [mutableBinding, CoreAssign mutableName zero, CoreReturn (divide mutableValue)]
assignedNonzero = intFunction [mutableBinding, CoreAssign mutableName (integer 4), CoreReturn (divide mutableValue)]

callAfterGuard, callInCondition, guardedConjunction, guardedDisjunction :: CoreFunction
callAfterGuard =
    guardedBody (compare CoreNotEqual x zero) [CoreEvaluate unitCallback, CoreReturn (divide x)]
callInCondition =
    guardedBody (operationBool CoreLogicalAnd [compare CoreNotEqual x zero, boolCallback]) [CoreReturn (divide x)]
guardedConjunction =
    guarded
        (operationBool CoreLogicalAnd [compare CoreNotEqual x zero, compare CoreGreaterThan y zero])
        True
guardedDisjunction =
    guarded
        ( operationBool
            CoreLogicalAnd
            [ compare CoreNotEqual x zero
            , operationBool CoreLogicalOr [compare CoreNotEqual y zero, compare CoreEqual y zero]
            ]
        )
        True

callBeforeGuardRemovesDeadDivision :: Bool
callBeforeGuardRemovesDeadDivision =
    optimizedDivisionShape
        (operationBool CoreLogicalAnd [boolCallback, compare CoreNotEqual x zero])
        False

callAfterGuardKeepsDeadDivision :: Bool
callAfterGuardKeepsDeadDivision =
    optimizedDivisionShape
        (operationBool CoreLogicalAnd [compare CoreNotEqual x zero, boolCallback])
        True

optimizedDivisionShape :: CoreExpression -> Bool -> Bool
optimizedDivisionShape condition expectedDivision =
    case optimize function of
        Just body -> containsDivision body == expectedDivision && containsCall body
        Nothing -> False
    where
        function =
            intFunction
                [ CoreIf condition [CoreEvaluate (divide x)] []
                , CoreReturn zero
                ]

falseAndSkipsFailure :: Bool
falseAndSkipsFailure =
    discardedCondition
        (operationBool CoreLogicalAnd [falseLiteral, divide zero])

trueOrSkipsFailure :: Bool
trueOrSkipsFailure =
    discardedCondition
        (operationBool CoreLogicalOr [trueLiteral, divide zero])

guardedLogicalRightIsDiscardable :: Bool
guardedLogicalRightIsDiscardable =
    discardedCondition
        (operationBool CoreLogicalAnd [compare CoreNotEqual x zero, divide x])

discardedCondition :: CoreExpression -> Bool
discardedCondition expression =
    case optimize (intFunction [CoreEvaluate expression, CoreReturn zero]) of
        Just [CoreReturn (CoreLiteral (CoreInteger 0) _)] -> True
        _ -> False

containsDivision :: [CoreStatement] -> Bool
containsDivision = any (statementContainsPrimitive CoreDivide)

containsCall :: [CoreStatement] -> Bool
containsCall = any statementContainsCall

statementContainsPrimitive :: CorePrimitive -> CoreStatement -> Bool
statementContainsPrimitive primitive statement = case statement of
    CoreBind binding -> expressionContainsPrimitive primitive (coreBindingValue binding)
    CoreAssign _ value -> expressionContainsPrimitive primitive value
    CoreReturn value -> expressionContainsPrimitive primitive value
    CoreEvaluate value -> expressionContainsPrimitive primitive value
    CoreIf condition whenTrue whenFalse ->
        expressionContainsPrimitive primitive condition
            || containsPrimitiveInStatements primitive whenTrue
            || containsPrimitiveInStatements primitive whenFalse
    CoreWhile condition body ->
        expressionContainsPrimitive primitive condition || containsPrimitiveInStatements primitive body
    CoreDoWhile body condition ->
        containsPrimitiveInStatements primitive body || expressionContainsPrimitive primitive condition
    CoreFor condition updates body ->
        expressionContainsPrimitive primitive condition
            || containsPrimitiveInStatements primitive updates
            || containsPrimitiveInStatements primitive body
    CoreBreak -> False
    CoreContinue -> False

containsPrimitiveInStatements :: CorePrimitive -> [CoreStatement] -> Bool
containsPrimitiveInStatements primitive = any (statementContainsPrimitive primitive)

expressionContainsPrimitive :: CorePrimitive -> CoreExpression -> Bool
expressionContainsPrimitive primitive expression = case expression of
    CoreVariable _ _ -> False
    CoreLiteral _ _ -> False
    CoreApply callee arguments _ ->
        any (expressionContainsPrimitive primitive) (callee : arguments)
    CorePrimitive current arguments _ ->
        current == primitive || any (expressionContainsPrimitive primitive) arguments
    CoreLet _ _ value body _ ->
        expressionContainsPrimitive primitive value || expressionContainsPrimitive primitive body
    CoreConditional condition whenTrue whenFalse _ -> any (expressionContainsPrimitive primitive) [condition, whenTrue, whenFalse]
    CoreClosure captures _ _ body _ ->
        any (expressionContainsPrimitive primitive . coreCaptureValue) captures
            || containsPrimitiveInStatements primitive body

statementContainsCall :: CoreStatement -> Bool
statementContainsCall statement = case statement of
    CoreBind binding -> expressionContainsCall (coreBindingValue binding)
    CoreAssign _ value -> expressionContainsCall value
    CoreReturn value -> expressionContainsCall value
    CoreEvaluate value -> expressionContainsCall value
    CoreIf condition whenTrue whenFalse ->
        expressionContainsCall condition || any statementContainsCall (whenTrue ++ whenFalse)
    CoreWhile condition body -> expressionContainsCall condition || any statementContainsCall body
    CoreDoWhile body condition -> any statementContainsCall body || expressionContainsCall condition
    CoreFor condition updates body ->
        expressionContainsCall condition || any statementContainsCall updates || any statementContainsCall body
    CoreBreak -> False
    CoreContinue -> False

expressionContainsCall :: CoreExpression -> Bool
expressionContainsCall expression = case expression of
    CoreVariable _ _ -> False
    CoreLiteral _ _ -> False
    CoreApply {} -> True
    CorePrimitive _ arguments _ -> any expressionContainsCall arguments
    CoreLet _ _ value body _ -> expressionContainsCall value || expressionContainsCall body
    CoreConditional condition whenTrue whenFalse _ -> any expressionContainsCall [condition, whenTrue, whenFalse]
    CoreClosure captures _ _ body _ ->
        any (expressionContainsCall . coreCaptureValue) captures
            || any statementContainsCall body

falseConjunction, falseDisjunction :: CoreFunction
falseConjunction =
    let condition = operationBool CoreLogicalAnd [compare CoreNotEqual y zero, variable flagName boolType]
     in intFunction
            [ CoreIf
                (compare CoreNotEqual x zero)
                [CoreIf condition [CoreReturn zero] [CoreReturn (divide x)]]
                [CoreReturn zero]
            ]
falseDisjunction =
    let condition = operationBool CoreLogicalOr [compare CoreEqual x zero, compare CoreEqual y zero]
     in intFunction [CoreIf condition [CoreReturn zero] [CoreReturn (divide x)]]

conflictingJoin, commonJoin :: CoreFunction
conflictingJoin =
    intFunction
        [ mutableBinding
        , CoreIf (variable flagName boolType) [CoreAssign mutableName zero] [CoreAssign mutableName (integer 2)]
        , CoreReturn (divide mutableValue)
        ]
commonJoin =
    intFunction
        [ mutableBinding
        , CoreIf (variable flagName boolType) [CoreAssign mutableName (integer 2)] [CoreAssign mutableName (integer 9)]
        , CoreReturn (divide mutableValue)
        ]

comparisonGuard :: CorePrimitive -> Bool -> Bool -> CoreFunction
comparisonGuard operator truth reverseOperands =
    let condition = if reverseOperands then compareReversed operator zero x else compare operator x zero
        yes = if truth then [CoreReturn (divide x)] else [CoreReturn zero]
        no = if truth then [CoreReturn zero] else [CoreReturn (divide x)]
     in intFunction [CoreIf condition yes no]

guardedPrimitive :: CorePrimitive -> CoreFunction
guardedPrimitive operator =
    intFunction
        [ CoreIf
            (compare CoreNotEqual x zero)
            [CoreReturn (operation operator x)]
            [CoreReturn zero]
        ]

mutateGuardedEdge :: Bool -> Integer -> CoreFunction
mutateGuardedEdge trueEdge value =
    let condition = compare CoreNotEqual mutableValue zero
        mutated = [CoreAssign mutableName (integer value), CoreReturn (divide mutableValue)]
        retained = [CoreReturn zero]
     in intFunction
            [ mutableBinding
            , CoreIf (if trueEdge then condition else operationBool CoreLogicalNot [condition]) mutated retained
            ]

nestedContradictionIsRemoved :: Bool
nestedContradictionIsRemoved =
    let function =
            intFunction
                [ CoreIf
                    (compare CoreNotEqual x zero)
                    [CoreIf (compare CoreEqual x zero) [CoreReturn (integer 99)] [CoreReturn (divide x)]]
                    [CoreReturn zero]
                ]
     in case optimize function of
            Just [CoreIf _ [CoreReturn (CorePrimitive CoreDivide _ _)] [CoreReturn _]] -> True
            _ -> False

closureBodyRetainsGuard :: Bool
closureBodyRetainsGuard =
    let closure =
            CoreClosure
                []
                [(xName, intType)]
                intType
                [CoreIf (compare CoreNotEqual x zero) [CoreReturn (divide x)] [CoreReturn zero]]
                (FunctionType [intType] intType)
        function = CoreFunction mainName [] (FunctionType [intType] intType) [CoreReturn closure]
     in case optimize function of
            Just [CoreReturn (CoreClosure _ _ _ [CoreIf _ [CoreReturn (CorePrimitive CoreDivide _ _)] [CoreReturn _]] _)] -> True
            _ -> False

guarded :: CoreExpression -> Bool -> CoreFunction
guarded condition trueEdge =
    let yes = if trueEdge then [CoreReturn (divide x)] else [CoreReturn zero]
        no = if trueEdge then [CoreReturn zero] else [CoreReturn (divide x)]
     in intFunction [CoreIf condition yes no]

guardedBody :: CoreExpression -> [CoreStatement] -> CoreFunction
guardedBody condition unsafeArm = intFunction [CoreIf condition unsafeArm [CoreReturn zero]]

intFunction :: [CoreStatement] -> CoreFunction
intFunction = CoreFunction mainName parameters intType

parameters :: [(ResolvedName, Type)]
parameters =
    [ (xName, intType)
    , (yName, intType)
    , (flagName, boolType)
    , (unitCallbackName, FunctionType [] unitType)
    , (boolCallbackName, FunctionType [] boolType)
    ]

mainName, xName, yName, flagName, unitCallbackName, boolCallbackName, mutableName, derivedName :: ResolvedName
mainName = resolved 1 "Main"
xName = resolved 10 "x"
yName = resolved 11 "y"
flagName = resolved 12 "flag"
unitCallbackName = resolved 13 "unitCallback"
boolCallbackName = resolved 14 "boolCallback"
mutableName = resolved 15 "mutableValue"
derivedName = resolved 32 "derived"

ubyteType :: Type
ubyteType = namedType "ubyte"

x, y, zero, unitCallback, boolCallback, mutableValue :: CoreExpression
x = variable xName intType
y = variable yName intType
zero = integer 0
unitCallback = CoreApply (variable unitCallbackName (FunctionType [] unitType)) [] unitType
boolCallback = CoreApply (variable boolCallbackName (FunctionType [] boolType)) [] boolType
trueLiteral, falseLiteral :: CoreExpression
trueLiteral = CoreLiteral (CoreBoolean True) boolType
falseLiteral = CoreLiteral (CoreBoolean False) boolType
mutableValue = variable mutableName intType

mutableBinding :: CoreStatement
mutableBinding = CoreBind (CoreBinding mutableName intType True x)

integer :: Integer -> CoreExpression
integer value = CoreLiteral (CoreInteger value) intType

variable :: ResolvedName -> Type -> CoreExpression
variable = CoreVariable

compare :: CorePrimitive -> CoreExpression -> CoreExpression -> CoreExpression
compare operator left right = CorePrimitive operator [left, right] boolType

compareReversed :: CorePrimitive -> CoreExpression -> CoreExpression -> CoreExpression
compareReversed operator left right = CorePrimitive operator [left, right] boolType

operation :: CorePrimitive -> CoreExpression -> CoreExpression
operation operator divisor = CorePrimitive operator [integer 12, divisor] intType

divide :: CoreExpression -> CoreExpression
divide = operation CoreDivide

operationBool :: CorePrimitive -> [CoreExpression] -> CoreExpression
operationBool operator operands = CorePrimitive operator operands boolType

resolved :: Int -> String -> ResolvedName
resolved symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

effectIs :: Effect -> CoreFunction -> Bool
effectIs expected function =
    case optimizeCoreWith defaultOptimizerOptions (CoreModule moduleName [function]) of
        Right result -> case optimizationEffectReports result of
            [report] -> effectClassification report == expected
            _ -> False
        Left _ -> False
    where
        moduleName = QualifiedName [Identifier "Optimizer", Identifier "IntegerFlow"]

optimize :: CoreFunction -> Maybe [CoreStatement]
optimize function =
    case optimizeCoreWith defaultOptimizerOptions (CoreModule moduleName [function]) of
        Right result -> case coreModuleFunctions (optimizedCore result) of
            [optimizedFunction] -> Just (coreFunctionBody optimizedFunction)
            _ -> Nothing
        Left _ -> Nothing
    where
        moduleName = QualifiedName [Identifier "Optimizer", Identifier "IntegerFlow"]
