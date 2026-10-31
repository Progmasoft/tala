-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module CoreOptimizerTests (coreOptimizerTests) where

import Data.Bits (complement, shiftL, shiftR, xor, (.&.), (.|.))
import Data.List (nub)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Scalar
import Progmasoft.Tala.Core.Verifier (verifyCore)

-- This suite exercises the optimizer as a verified Core-to-Core boundary.
-- Small constructor helpers keep each case focused on the rewrite contract
-- rather than on incidental SymbolId and module boilerplate.
coreOptimizerTests :: [(String, Bool)]
coreOptimizerTests =
    [ ("Core scalar facts classify every integer type", all isCoreIntegerType integerTypes)
    , ("Core scalar facts classify every floating type", all isCoreFloatingType floatingTypes)
    , ("Core scalar facts reject bool as numeric", not (isCoreNumericType boolType))
    , ("Core scalar spelling rejects applied types", coreTypeSpelling appliedIntType == "")
    , ("Core scalar width catalog covers signed and unsigned integers", integerWidthsMatchTypes)
    , ("Core scalar ranges agree with every declared width", integerRangesMatchWidths)
    ,
        ( "Core scalar layout lookup rejects floating and applied types"
        , coreIntegerBitWidth (namedType "float") == Nothing
            && coreIntegerBitWidth appliedIntType == Nothing
            && coreIntegerIsSigned (namedType "float") == Nothing
        )
    , ("byte accepts its lower boundary", integerFitsCoreType byteType (-128))
    , ("byte accepts its upper boundary", integerFitsCoreType byteType 127)
    , ("byte rejects lower overflow", not (integerFitsCoreType byteType (-129)))
    , ("byte rejects upper overflow", not (integerFitsCoreType byteType 128))
    , ("ubyte accepts zero", integerFitsCoreType ubyteType 0)
    , ("ubyte accepts 255", integerFitsCoreType ubyteType 255)
    , ("ubyte rejects negative values", not (integerFitsCoreType ubyteType (-1)))
    , ("ubyte rejects 256", not (integerFitsCoreType ubyteType 256))
    , ("int accepts signed 64-bit minimum", integerFitsCoreType intType (negate (2 ^ (63 :: Int))))
    , ("int accepts signed 64-bit maximum", integerFitsCoreType intType (2 ^ (63 :: Int) - 1))
    , ("uint accepts unsigned 64-bit maximum", integerFitsCoreType uintType (2 ^ (64 :: Int) - 1))
    , ("uint rejects unsigned 64-bit overflow", not (integerFitsCoreType uintType (2 ^ (64 :: Int))))
    , ("longint accepts signed 128-bit minimum", integerFitsCoreType longintType (negate (2 ^ (127 :: Int))))
    , ("ulongint accepts unsigned 128-bit maximum", integerFitsCoreType ulongintType (2 ^ (128 :: Int) - 1))
    , ("floating spelling accepts an integer mantissa", validCoreFloatingSpelling "42")
    , ("floating spelling accepts a fractional mantissa", validCoreFloatingSpelling "42.125")
    , ("floating spelling accepts a leading point", validCoreFloatingSpelling ".5")
    , ("floating spelling accepts a trailing point", validCoreFloatingSpelling "5.")
    , ("floating spelling accepts a signed exponent", validCoreFloatingSpelling "-1.5e+20")
    , ("floating spelling accepts infinity", validCoreFloatingSpelling "+inf")
    , ("floating spelling accepts NaN", validCoreFloatingSpelling "-nan")
    , ("floating spelling rejects an empty value", not (validCoreFloatingSpelling ""))
    , ("floating spelling rejects a bare sign", not (validCoreFloatingSpelling "-"))
    , ("floating spelling rejects a bare point", not (validCoreFloatingSpelling "."))
    , ("floating spelling rejects a missing exponent", not (validCoreFloatingSpelling "1e"))
    , ("floating spelling rejects repeated exponents", not (validCoreFloatingSpelling "1e2e3"))
    , ("floating spelling rejects Unicode decimal digits", not (validCoreFloatingSpelling "١.0"))
    , ("constant propagation folds an immutable chain", immutableChain)
    , ("constant propagation does not cross a mutable assignment", mutableInvalidation)
    , ("integer addition folds", primitiveFolds CoreAdd 20 22 42)
    , ("integer subtraction folds", primitiveFolds CoreSubtract 20 22 (-2))
    , ("integer multiplication folds", primitiveFolds CoreMultiply 6 7 42)
    , ("integer power folds a small nonnegative exponent", typedPrimitiveFolds CorePower intType 3 4 81)
    , ("power and shifts respect every Core integer width at both edges", integerOperationBoundaryMatrix)
    , ("integer arithmetic overflow stays explicit for every Core scalar", integerArithmeticOverflowMatrix)
    , integerOperatorOracleMatrix
    , ("integer unary folds preserve boundaries for every Core scalar", integerUnaryBoundaryMatrix)
    , ("integer power folds zero exponent", typedPrimitiveFolds CorePower intType 9 0 1)
    ,
        ( "zero raised to a large exponent folds without constructing a power"
        , typedPrimitiveFolds CorePower intType 0 (2 ^ (63 :: Int) - 1) 0
        )
    ,
        ( "one raised to a maximum-width exponent folds directly"
        , typedPrimitiveFolds CorePower intType 1 (2 ^ (63 :: Int) - 1) 1
        )
    ,
        ( "negative one power uses exponent parity without large intermediates"
        , typedPrimitiveFolds CorePower intType (-1) (2 ^ (63 :: Int) - 1) (-1)
        )
    ,
        ( "signed 128-bit minimum is accepted from a bounded power"
        , typedPrimitiveFolds CorePower longintType (-2) 127 (negate (2 ^ (127 :: Int)))
        )
    ,
        ( "unsigned 128-bit high bit is accepted from a bounded power"
        , typedPrimitiveFolds CorePower ulongintType 2 127 (2 ^ (127 :: Int))
        )
    , ("unsigned 128-bit overflow remains explicit", overflowingPower ulongintType 2 128)
    , ("untrusted huge exponents remain explicit without materializing the result", hugePowerRemainsExplicit)
    , ("left shift folds within the integer width", typedPrimitiveFolds CoreShiftLeft intType 3 4 48)
    , ("right shift preserves sign for a negative integer", typedPrimitiveFolds CoreShiftRight intType (-16) 2 (-4))
    , ("shift equal to the type width remains explicit", overflowingShift intType CoreShiftLeft 1 64)
    , ("128-bit shift count cannot wrap through the host Int width", hugeShiftRemainsExplicit)
    , ("integer division truncates toward zero", primitiveFolds CoreDivide (-7) 3 (-2))
    , ("integer rounded division chooses nearest", primitiveFolds CoreFloorDivide (-7) 3 (-2))
    , ("integer rounded division moves halves away from zero", primitiveFolds CoreFloorDivide 7 2 4)
    , ("integer remainder follows truncating division", primitiveFolds CoreRemainder (-7) 3 (-1))
    , ("division by zero remains explicit", divisionByZeroRetained CoreDivide)
    , ("floor division by zero remains explicit", divisionByZeroRetained CoreFloorDivide)
    , ("remainder by zero remains explicit", divisionByZeroRetained CoreRemainder)
    , ("integer negation folds", unaryFolds CoreNegate 42 (integer (-42)))
    , ("bitwise complement matches each integer type's finite width", bitwiseComplementBoundaries)
    , ("logical not folds boolean values", unaryFolds CoreLogicalNot 1 (boolean False))
    , ("logical not treats numeric zero as false", unaryFolds CoreLogicalNot 0 (boolean True))
    , ("less-than comparison folds", comparisonFolds CoreLessThan 1 2 True)
    , ("less-equal comparison folds", comparisonFolds CoreLessEqual 2 2 True)
    , ("greater-than comparison folds", comparisonFolds CoreGreaterThan 3 2 True)
    , ("greater-equal comparison folds", comparisonFolds CoreGreaterEqual 2 2 True)
    , ("equality comparison folds", comparisonFolds CoreEqual 2 2 True)
    , ("inequality comparison folds", comparisonFolds CoreNotEqual 2 3 True)
    , ("logical and folds", logicalFolds CoreLogicalAnd True False False)
    , ("logical or folds", logicalFolds CoreLogicalOr False True True)
    , ("overflowing byte addition is retained", overflowingByteAddition)
    , ("addition by zero returns the live operand", identityRewrite CoreAdd 0)
    , ("subtraction by zero returns the live operand", identityRewrite CoreSubtract 0)
    , ("multiplication by one returns the live operand", identityRewrite CoreMultiply 1)
    , ("division by one returns the live operand", identityRewrite CoreDivide 1)
    , ("floor division by one returns the live operand", identityRewrite CoreFloorDivide 1)
    , ("remainder by one becomes zero for a simple operand", remainderIdentity)
    , ("double arithmetic negation collapses", doubleNegation)
    , ("double boolean negation collapses", doubleLogicalNot)
    , ("double logical negation preserves numeric-to-bool conversion", numericDoubleLogicalNot)
    , ("a true branch selects its then statements", knownBranch True)
    , ("a false branch selects its else statements", knownBranch False)
    , ("numeric zero selects an else branch", numericBranch 0 2)
    , ("nonzero numeric conditions select a then branch", numericBranch (-3) 1)
    , ("identical pure branches discard their condition", identicalPureBranches)
    , ("identical branches retain an effectful condition", identicalEffectfulBranches)
    , ("empty branches retain an effectful condition", emptyEffectfulBranches)
    , ("statements after return are unreachable", unreachableAfterReturn)
    , ("a fully returning branch makes following code unreachable", unreachableAfterBranch)
    , ("unused literal bindings are removed", deadLiteralBinding)
    , ("unused primitive evaluations are removed", deadPrimitiveEvaluation)
    , ("unused calls are retained as evaluations", deadCallResultPreserved)
    , ("unused closure allocations are retained as evaluations", deadClosurePreserved)
    , ("dead pure assignments are removed", deadAssignment)
    , ("assignments feeding a return remain live", liveAssignment)
    , ("an overwritten assignment is removed without losing its declaration", overwrittenAssignment)
    , ("a branch assignment retains its declaration", branchAssignmentRetainsDeclaration)
    , ("a dead branch assignment does not retain storage", deadBranchAssignment)
    , ("effectful dead binding initializers become evaluations", effectfulBindingBecomesEvaluation)
    , ("closure bodies are optimized as independent regions", closureBodyOptimized)
    , ("literal captures propagate into closure bodies", closureCapturePropagates)
    , ("closure parameters shadow capture constants", closureParameterShadowsCapture)
    , ("disabling all passes preserves the verified module", disabledPipelineIsIdentity)
    , ("disabling constant propagation retains arithmetic", constantPassCanBeDisabled)
    , ("disabling control-flow simplification retains branches", controlFlowPassCanBeDisabled)
    , ("disabling dead-code elimination retains dead bindings", deadCodePassCanBeDisabled)
    , ("the default pipeline reaches a fixed point", reportsConvergence)
    , ("a one-iteration limit reports an unfinished fixed point", reportsIterationLimit)
    , ("optimizer metrics count functions", metricsCountFunctions)
    , ("optimizer metrics report removed statements", metricsReportReduction)
    , ("optimizer metrics count calls and closures", metricsCountEffects)
    , ("pass reports preserve pipeline order", reportsPreservePassOrder)
    , ("pass reports identify changing passes", reportsIdentifyChanges)
    , ("pass reports include every completed iteration", reportsCoverIterations)
    , ("disabled passes are absent from reports", reportsOmitDisabledPasses)
    , ("pass report metrics form a continuous chain", reportMetricsAreContinuous)
    , ("optimizer output is idempotent", optimizerIsIdempotent)
    , ("optimizer output passes the Core verifier", optimizedOutputVerifies)
    , ("optimizer rejects an invalid input module", invalidInputRejected)
    ]

name :: Int -> String -> ResolvedName
name symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

moduleName :: QualifiedName
moduleName = QualifiedName [Identifier "Optimizer", Identifier "Tests"]

entryName, calleeName, predicateName, valueName, secondName, capturedValueName, closureParameterName :: ResolvedName
entryName = name 1 "Main"
calleeName = name 2 "Effect"
predicateName = name 3 "Predicate"
valueName = name 10 "value"
secondName = name 11 "second"
capturedValueName = name 12 "captured"
closureParameterName = name 13 "parameter"

byteType, ubyteType, uintType, longintType, ulongintType :: Type
byteType = namedType "byte"
ubyteType = namedType "ubyte"
uintType = namedType "uint"
longintType = namedType "longint"
ulongintType = namedType "ulongint"

integerTypes, floatingTypes :: [Type]
integerTypes = map namedType coreIntegerTypeNames
floatingTypes = map namedType coreFloatingTypeNames

integerWidthsMatchTypes :: Bool
integerWidthsMatchTypes =
    map coreIntegerBitWidth integerTypes
        == map Just [32, 8, 16, 32, 64, 128, 8, 16, 32, 64, 128]

integerRangesMatchWidths :: Bool
integerRangesMatchWidths = all checkType integerTypes
    where
        checkType valueType = case (coreIntegerBitWidth valueType, coreIntegerIsSigned valueType) of
            (Just width, Just isSigned) ->
                let signBits = if isSigned then 1 else 0
                    magnitude = 2 ^ (width - signBits)
                    minimumValue = if isSigned then negate magnitude else 0
                    maximumValue = magnitude - 1
                 in integerFitsCoreType valueType minimumValue
                        && integerFitsCoreType valueType maximumValue
                        && not (integerFitsCoreType valueType (minimumValue - 1))
                        && not (integerFitsCoreType valueType (maximumValue + 1))
            _ -> False

bitwiseComplementBoundaries :: Bool
bitwiseComplementBoundaries = all checkType integerTypes
    where
        checkType valueType = case (coreIntegerBitWidth valueType, coreIntegerIsSigned valueType) of
            (Just width, Just isSigned) ->
                let signBits = if isSigned then 1 else 0
                    magnitude = 2 ^ (width - signBits)
                    minimumValue = if isSigned then negate magnitude else 0
                    maximumValue = magnitude - 1
                    zeroComplement = if isSigned then -1 else maximumValue
                 in typedUnaryPrimitiveFolds CoreBitwiseNot valueType 0 zeroComplement
                        && typedUnaryPrimitiveFolds CoreBitwiseNot valueType minimumValue maximumValue
                        && typedUnaryPrimitiveFolds CoreBitwiseNot valueType maximumValue minimumValue
            _ -> False

integerOperationBoundaryMatrix :: Bool
integerOperationBoundaryMatrix = all checkType integerTypes
    where
        checkType valueType = case (coreIntegerBitWidth valueType, coreIntegerIsSigned valueType) of
            (Just width, Just isSigned) ->
                let signedBits = if isSigned then 1 else 0
                    minimumValue = if isSigned then negate (2 ^ (width - 1)) else 0
                    maximumValue = 2 ^ (width - signedBits) - 1
                    highestSafeShift = width - signedBits - 1
                    safeShiftResult = 2 ^ highestSafeShift
                    minimumPowerExponent = width - 1
                    minimumPowerResult = negate (2 ^ minimumPowerExponent)
                    rightShiftInput = if isSigned then minimumValue else maximumValue
                    rightShiftExpected = if isSigned then -1 else 1
                 in typedPrimitiveFolds CoreShiftLeft valueType 1 (toInteger highestSafeShift) safeShiftResult
                        && typedPrimitiveFolds CoreShiftRight valueType rightShiftInput (toInteger (width - 1)) rightShiftExpected
                        && ( not isSigned
                                || typedPrimitiveFolds CorePower valueType (-2) (toInteger minimumPowerExponent) minimumPowerResult
                           )
                        && overflowingShift valueType CoreShiftLeft 1 (toInteger width)
                        && overflowingPower valueType 2 (toInteger (width - signedBits))
            _ -> False

integerArithmeticOverflowMatrix :: Bool
integerArithmeticOverflowMatrix = all checkType integerTypes
    where
        checkType valueType = case (coreIntegerBitWidth valueType, coreIntegerIsSigned valueType) of
            (Just width, Just isSigned) ->
                let highestValue = 2 ^ (width - if isSigned then 1 else 0) - 1
                    overflowing = CorePrimitive CoreAdd [literal highestValue, literal 1] valueType
                 in returnExpression (moduleWith [entry valueType [CoreReturn overflowing]]) == Just overflowing
            _ -> False
            where
                literal value = CoreLiteral (CoreInteger value) valueType

integerOperatorOracleMatrix :: (String, Bool)
integerOperatorOracleMatrix = case optimizeCoreWith defaultOptimizerOptions input of
    Left diagnostics -> ("integer Core oracle module verifies (" ++ show diagnostics ++ ")", False)
    Right result ->
        let actualExpressions =
                [ expression
                | function <- coreModuleFunctions (optimizedCore result)
                , [CoreReturn expression] <- [coreFunctionBody function]
                ]
            mismatches =
                [ (show (valueType, operation, left, right), expected, actual)
                | ((valueType, operation, left, right, expected), actual) <- zip cases actualExpressions
                , expected /= actual
                ]
         in ( "integer Core folding agrees with the width-aware operator oracle " ++ show (take 3 mismatches)
            , null mismatches && length actualExpressions == length cases
            )
    where
        cases =
            [ (valueType, operation, left, right, expected)
            | valueType <- integerTypes
            , width <- maybeToList (coreIntegerBitWidth valueType)
            , isSigned <- maybeToList (coreIntegerIsSigned valueType)
            , let magnitude = 2 ^ (width - if isSigned then 1 else 0)
            , let minimumValue = if isSigned then negate magnitude else 0
            , let maximumValue = magnitude - 1
            , left <- nub [minimumValue, minimumValue + 1, -1, 0, 1, maximumValue - 1, maximumValue]
            , integerFitsCoreType valueType left
            , right <- nub [minimumValue, minimumValue + 1, -1, 0, 1, maximumValue - 1, maximumValue]
            , integerFitsCoreType valueType right
            , operation <- integerOracleOperators
            , let expression =
                    CorePrimitive
                        operation
                        [typedLiteral valueType left, typedLiteral valueType right]
                        (oracleResultType operation valueType)
            , let expected =
                    maybe
                        expression
                        (\literal -> CoreLiteral literal (oracleResultType operation valueType))
                        (oracleFold valueType width operation left right)
            ]
        input =
            CoreModule
                moduleName
                [ CoreFunction
                    (name (1000 + index) "IntegerOracle")
                    []
                    (oracleResultType operation valueType)
                    [ CoreReturn
                        ( CorePrimitive
                            operation
                            [typedLiteral valueType left, typedLiteral valueType right]
                            (oracleResultType operation valueType)
                        )
                    ]
                | (index, (valueType, operation, left, right, _)) <- zip [0 ..] cases
                ]

integerOracleOperators :: [CorePrimitive]
integerOracleOperators =
    [ CoreAdd
    , CoreSubtract
    , CoreMultiply
    , CoreDivide
    , CoreFloorDivide
    , CoreRemainder
    , CorePower
    , CoreShiftLeft
    , CoreShiftRight
    , CoreBitwiseAnd
    , CoreBitwiseXor
    , CoreBitwiseOr
    , CoreLessThan
    , CoreLessEqual
    , CoreGreaterThan
    , CoreGreaterEqual
    , CoreEqual
    , CoreNotEqual
    , CoreLogicalAnd
    , CoreLogicalOr
    ]

integerUnaryBoundaryMatrix :: Bool
integerUnaryBoundaryMatrix = case optimizeCoreWith defaultOptimizerOptions input of
    Left _ -> False
    Right result -> actualExpressions (optimizedCore result) == map fifth cases
    where
        cases =
            [ (valueType, operation, operand, resultType, expected)
            | valueType <- integerTypes
            , width <- maybeToList (coreIntegerBitWidth valueType)
            , isSigned <- maybeToList (coreIntegerIsSigned valueType)
            , let magnitude = 2 ^ (width - if isSigned then 1 else 0)
            , let minimumValue = if isSigned then negate magnitude else 0
            , let maximumValue = magnitude - 1
            , operand <- nub [minimumValue, minimumValue + 1, -1, 0, 1, maximumValue - 1, maximumValue]
            , integerFitsCoreType valueType operand
            , operation <- [CoreNegate, CoreBitwiseNot]
            , let resultType = valueType
            , let expression = CorePrimitive operation [typedLiteral valueType operand] resultType
            , let expected = case operation of
                    CoreNegate ->
                        if integerFitsCoreType resultType (negate operand)
                            then CoreLiteral (CoreInteger (negate operand)) resultType
                            else expression
                    _ ->
                        let complemented = complement operand
                            finiteComplement = if isSigned then complemented else complemented .&. ((1 `shiftL` width) - 1)
                         in CoreLiteral (CoreInteger finiteComplement) resultType
            ]
        input =
            CoreModule
                moduleName
                [ CoreFunction
                    (name (5000 + index) "IntegerUnaryOracle")
                    []
                    resultType
                    [CoreReturn (CorePrimitive operation [typedLiteral valueType operand] resultType)]
                | (index, (valueType, operation, operand, resultType, _)) <- zip [0 ..] cases
                ]
        actualExpressions optimizedModule =
            [ expression
            | function <- coreModuleFunctions optimizedModule
            , [CoreReturn expression] <- [coreFunctionBody function]
            ]
        fifth (_, _, _, _, value) = value

oracleResultType :: CorePrimitive -> Type -> Type
oracleResultType operation operandType
    | operation
        `elem` [CoreLessThan, CoreLessEqual, CoreGreaterThan, CoreGreaterEqual, CoreEqual, CoreNotEqual, CoreLogicalAnd, CoreLogicalOr] =
        boolType
    | otherwise = operandType

oracleFold :: Type -> Int -> CorePrimitive -> Integer -> Integer -> Maybe CoreLiteral
oracleFold valueType width operation left right = case operation of
    CoreAdd -> integerResult (left + right)
    CoreSubtract -> integerResult (left - right)
    CoreMultiply -> integerResult (left * right)
    CoreDivide
        | right /= 0 -> integerResult (left `quot` right)
    CoreFloorDivide
        | right /= 0 -> integerResult (roundedOracleDivision left right)
    CoreRemainder
        | right /= 0 -> integerResult (left `rem` right)
    CorePower
        | right < 0 -> Nothing
        | left == 0 -> integerResult (if right == 0 then 1 else 0)
        | left == 1 -> integerResult 1
        | left == -1 -> integerResult (if even right then 1 else -1)
        | right <= toInteger width -> integerResult (left ^ (fromInteger right :: Int))
    CoreShiftLeft
        | right >= 0 && right < toInteger width -> integerResult (shiftL left (fromInteger right))
    CoreShiftRight
        | right >= 0 && right < toInteger width -> integerResult (shiftR left (fromInteger right))
    CoreBitwiseAnd -> integerResult (left .&. right)
    CoreBitwiseXor -> integerResult (xor left right)
    CoreBitwiseOr -> integerResult (left .|. right)
    CoreLessThan -> booleanResult (left < right)
    CoreLessEqual -> booleanResult (left <= right)
    CoreGreaterThan -> booleanResult (left > right)
    CoreGreaterEqual -> booleanResult (left >= right)
    CoreEqual -> booleanResult (left == right)
    CoreNotEqual -> booleanResult (left /= right)
    CoreLogicalAnd -> booleanResult (left /= 0 && right /= 0)
    CoreLogicalOr -> booleanResult (left /= 0 || right /= 0)
    _ -> Nothing
    where
        integerResult result
            | integerFitsCoreType valueType result = Just (CoreInteger result)
            | otherwise = Nothing
        booleanResult = Just . CoreBoolean

typedLiteral :: Type -> Integer -> CoreExpression
typedLiteral valueType value = CoreLiteral (CoreInteger value) valueType

roundedOracleDivision :: Integer -> Integer -> Integer
roundedOracleDivision dividend divisor =
    let (quotient, remainder) = dividend `quotRem` divisor
        adjustment = signum dividend * signum divisor
     in if 2 * abs remainder >= abs divisor then quotient + adjustment else quotient

maybeToList :: Maybe value -> [value]
maybeToList value = case value of
    Just item -> [item]
    Nothing -> []

appliedIntType :: Type
appliedIntType = NamedType (QualifiedName [Identifier "int"]) [TypeTemplateArgument intType]

integer :: Integer -> CoreExpression
integer value = CoreLiteral (CoreInteger value) intType

byte :: Integer -> CoreExpression
byte value = CoreLiteral (CoreInteger value) byteType

boolean :: Bool -> CoreExpression
boolean value = CoreLiteral (CoreBoolean value) boolType

unit :: CoreExpression
unit = CoreLiteral CoreUnit unitType

variable :: ResolvedName -> Type -> CoreExpression
variable = CoreVariable

primitive :: CorePrimitive -> [CoreExpression] -> Type -> CoreExpression
primitive = CorePrimitive

binding :: ResolvedName -> Type -> Bool -> CoreExpression -> CoreStatement
binding bindingName valueType mutable value = CoreBind (CoreBinding bindingName valueType mutable value)

entry :: Type -> [CoreStatement] -> CoreFunction
entry resultType body = CoreFunction entryName [] resultType body

moduleWith :: [CoreFunction] -> CoreModule
moduleWith = CoreModule moduleName

unitModule :: [CoreStatement] -> CoreModule
unitModule statements = moduleWith [entry unitType (statements ++ [CoreReturn unit])]

intModule :: [CoreStatement] -> CoreModule
intModule statements = moduleWith [entry intType statements]

optimized :: CoreModule -> Maybe OptimizationResult
optimized input = either (const Nothing) Just (optimizeCoreWith defaultOptimizerOptions input)

optimizedWith :: OptimizerOptions -> CoreModule -> Maybe OptimizationResult
optimizedWith options input = either (const Nothing) Just (optimizeCoreWith options input)

optimizedBody :: CoreModule -> Maybe [CoreStatement]
optimizedBody input = do
    result <- optimized input
    function <- case coreModuleFunctions (optimizedCore result) of
        first : _ -> Just first
        [] -> Nothing
    pure (coreFunctionBody function)

returnExpression :: CoreModule -> Maybe CoreExpression
returnExpression input = do
    body <- optimizedBody input
    case body of
        [CoreReturn value] -> Just value
        _ -> Nothing

immutableChain :: Bool
immutableChain =
    returnExpression
        ( intModule
            [ binding valueName intType False (integer 40)
            , binding secondName intType False (primitive CoreAdd [variable valueName intType, integer 2] intType)
            , CoreReturn (variable secondName intType)
            ]
        )
        == Just (integer 42)

mutableInvalidation :: Bool
mutableInvalidation =
    optimizedBody
        ( intModule
            [ binding valueName intType True (integer 1)
            , CoreAssign valueName (integer 2)
            , CoreReturn (variable valueName intType)
            ]
        )
        == Just
            [ binding valueName intType True (integer 1)
            , CoreAssign valueName (integer 2)
            , CoreReturn (variable valueName intType)
            ]

primitiveFolds :: CorePrimitive -> Integer -> Integer -> Integer -> Bool
primitiveFolds operation left right expected =
    returnExpression (intModule [CoreReturn (primitive operation [integer left, integer right] intType)])
        == Just (integer expected)

typedPrimitiveFolds :: CorePrimitive -> Type -> Integer -> Integer -> Integer -> Bool
typedPrimitiveFolds operation valueType left right expected =
    let expression = CorePrimitive operation [literal left, literal right] valueType
     in returnExpression (moduleWith [entry valueType [CoreReturn expression]]) == Just (literal expected)
    where
        literal value = CoreLiteral (CoreInteger value) valueType

typedUnaryPrimitiveFolds :: CorePrimitive -> Type -> Integer -> Integer -> Bool
typedUnaryPrimitiveFolds operation valueType operand expected =
    let expression = CorePrimitive operation [literal operand] valueType
     in returnExpression (moduleWith [entry valueType [CoreReturn expression]]) == Just (literal expected)
    where
        literal value = CoreLiteral (CoreInteger value) valueType

overflowingPower :: Type -> Integer -> Integer -> Bool
overflowingPower valueType base exponentValue =
    let expression = CorePrimitive CorePower [literal base, literal exponentValue] valueType
     in returnExpression (moduleWith [entry valueType [CoreReturn expression]]) == Just expression
    where
        literal value = CoreLiteral (CoreInteger value) valueType

overflowingShift :: Type -> CorePrimitive -> Integer -> Integer -> Bool
overflowingShift valueType operation value amount =
    let expression = CorePrimitive operation [literal value, literal amount] valueType
     in returnExpression (moduleWith [entry valueType [CoreReturn expression]]) == Just expression
    where
        literal number = CoreLiteral (CoreInteger number) valueType

hugePowerRemainsExplicit :: Bool
hugePowerRemainsExplicit = overflowingPower intType 2 (2 ^ (63 :: Int) - 1)

hugeShiftRemainsExplicit :: Bool
hugeShiftRemainsExplicit = overflowingShift ulongintType CoreShiftLeft 1 (2 ^ (128 :: Int) - 1)

unaryFolds :: CorePrimitive -> Integer -> CoreExpression -> Bool
unaryFolds operation operand expected =
    let resultType = expressionType expected
     in returnExpression (moduleWith [entry resultType [CoreReturn (primitive operation [integer operand] resultType)]])
            == Just expected

comparisonFolds :: CorePrimitive -> Integer -> Integer -> Bool -> Bool
comparisonFolds operation left right expected =
    returnExpression
        (moduleWith [entry boolType [CoreReturn (primitive operation [integer left, integer right] boolType)]])
        == Just (boolean expected)

logicalFolds :: CorePrimitive -> Bool -> Bool -> Bool -> Bool
logicalFolds operation left right expected =
    returnExpression
        ( moduleWith
            [entry boolType [CoreReturn (primitive operation [boolean left, boolean right] boolType)]]
        )
        == Just (boolean expected)

divisionByZeroRetained :: CorePrimitive -> Bool
divisionByZeroRetained operation =
    let expression = primitive operation [integer 7, integer 0] intType
     in returnExpression (intModule [CoreReturn expression]) == Just expression

overflowingByteAddition :: Bool
overflowingByteAddition =
    let expression = primitive CoreAdd [byte 127, byte 1] byteType
     in returnExpression (moduleWith [entry byteType [CoreReturn expression]]) == Just expression

identityRewrite :: CorePrimitive -> Integer -> Bool
identityRewrite operation identity =
    let parameter = variable valueName intType
        function =
            CoreFunction
                entryName
                [(valueName, intType)]
                intType
                [CoreReturn (primitive operation [parameter, integer identity] intType)]
     in returnExpression (moduleWith [function]) == Just parameter

remainderIdentity :: Bool
remainderIdentity =
    let function = CoreFunction entryName [(valueName, intType)] intType [CoreReturn expression]
        expression = primitive CoreRemainder [variable valueName intType, integer 1] intType
     in returnExpression (moduleWith [function]) == Just (integer 0)

doubleNegation :: Bool
doubleNegation =
    let parameter = variable valueName intType
        expression = primitive CoreNegate [primitive CoreNegate [parameter] intType] intType
        function = CoreFunction entryName [(valueName, intType)] intType [CoreReturn expression]
     in returnExpression (moduleWith [function]) == Just parameter

doubleLogicalNot :: Bool
doubleLogicalNot =
    let parameter = variable valueName boolType
        expression = primitive CoreLogicalNot [primitive CoreLogicalNot [parameter] boolType] boolType
        function = CoreFunction entryName [(valueName, boolType)] boolType [CoreReturn expression]
     in returnExpression (moduleWith [function]) == Just parameter

numericDoubleLogicalNot :: Bool
numericDoubleLogicalNot =
    let parameter = variable valueName intType
        inner = primitive CoreLogicalNot [parameter] boolType
        expression = primitive CoreLogicalNot [inner] boolType
        function = CoreFunction entryName [(valueName, intType)] boolType [CoreReturn expression]
     in returnExpression (moduleWith [function]) == Just expression

knownBranch :: Bool -> Bool
knownBranch condition =
    returnExpression
        ( intModule
            [ CoreIf
                (boolean condition)
                [CoreReturn (integer 1)]
                [CoreReturn (integer 2)]
            ]
        )
        == Just (integer (if condition then 1 else 2))

numericBranch :: Integer -> Integer -> Bool
numericBranch condition expected =
    returnExpression
        ( intModule
            [ CoreIf
                (integer condition)
                [CoreReturn (integer 1)]
                [CoreReturn (integer 2)]
            ]
        )
        == Just (integer expected)

identicalPureBranches :: Bool
identicalPureBranches =
    let condition = primitive CoreLessThan [integer 1, variable valueName intType] boolType
        function = CoreFunction entryName [(valueName, intType)] intType [CoreIf condition branch branch]
        branch = [CoreReturn (integer 7)]
     in returnExpression (moduleWith [function]) == Just (integer 7)

effectFunction :: CoreFunction
effectFunction =
    CoreFunction
        calleeName
        []
        unitType
        [ CoreEvaluate (closureExpression [] [] unitType [CoreReturn unit])
        , CoreReturn unit
        ]

effectCall :: CoreExpression
effectCall = CoreApply (variable calleeName (FunctionType [] unitType)) [] unitType

predicateFunction :: CoreFunction
predicateFunction =
    CoreFunction
        predicateName
        []
        boolType
        [ CoreEvaluate (closureExpression [] [] unitType [CoreReturn unit])
        , CoreReturn (boolean True)
        ]

predicateCall :: CoreExpression
predicateCall = CoreApply (variable predicateName (FunctionType [] boolType)) [] boolType

identicalEffectfulBranches :: Bool
identicalEffectfulBranches =
    optimizedBody
        ( moduleWith
            [ entry intType [CoreIf predicateCall branch branch]
            , predicateFunction
            ]
        )
        == Just [CoreEvaluate predicateCall, CoreReturn (integer 7)]
    where
        branch = [CoreReturn (integer 7)]

emptyEffectfulBranches :: Bool
emptyEffectfulBranches =
    optimizedBody (moduleWith [entry unitType [CoreIf predicateCall [] [], CoreReturn unit], predicateFunction])
        == Just [CoreEvaluate predicateCall, CoreReturn unit]

unreachableAfterReturn :: Bool
unreachableAfterReturn =
    optimizedBody
        (moduleWith [entry intType [CoreReturn (integer 1), CoreEvaluate effectCall], effectFunction])
        == Just [CoreReturn (integer 1)]

unreachableAfterBranch :: Bool
unreachableAfterBranch =
    let function = CoreFunction entryName [(valueName, boolType)] intType body
        body =
            [ CoreIf
                (variable valueName boolType)
                [CoreReturn (integer 1)]
                [CoreReturn (integer 2)]
            , CoreEvaluate effectCall
            ]
     in optimizedBody (moduleWith [function, effectFunction])
            == Just
                [ CoreIf
                    (variable valueName boolType)
                    [CoreReturn (integer 1)]
                    [CoreReturn (integer 2)]
                ]

deadLiteralBinding :: Bool
deadLiteralBinding =
    optimizedBody (unitModule [binding valueName intType False (integer 42)])
        == Just [CoreReturn unit]

deadPrimitiveEvaluation :: Bool
deadPrimitiveEvaluation =
    optimizedBody (unitModule [CoreEvaluate (primitive CoreAdd [integer 1, integer 2] intType)])
        == Just [CoreReturn unit]

deadCallResultPreserved :: Bool
deadCallResultPreserved =
    optimizedBody
        ( moduleWith
            [ entry unitType [binding valueName unitType False effectCall, CoreReturn unit]
            , effectFunction
            ]
        )
        == Just [CoreEvaluate effectCall, CoreReturn unit]

closureExpression :: [CoreCapture] -> [(ResolvedName, Type)] -> Type -> [CoreStatement] -> CoreExpression
closureExpression captures parameters resultType body =
    CoreClosure captures parameters resultType body (FunctionType (map snd parameters) resultType)

deadClosurePreserved :: Bool
deadClosurePreserved =
    let closure = closureExpression [] [] unitType [CoreReturn unit]
     in optimizedBody (unitModule [binding valueName (expressionType closure) False closure])
            == Just [CoreEvaluate closure, CoreReturn unit]

deadAssignment :: Bool
deadAssignment =
    optimizedBody
        ( unitModule
            [ binding valueName intType True (integer 1)
            , CoreAssign valueName (integer 2)
            ]
        )
        == Just [CoreReturn unit]

liveAssignment :: Bool
liveAssignment =
    optimizedBody
        ( intModule
            [ binding valueName intType True (integer 1)
            , CoreAssign valueName (integer 2)
            , CoreReturn (variable valueName intType)
            ]
        )
        == Just
            [ binding valueName intType True (integer 1)
            , CoreAssign valueName (integer 2)
            , CoreReturn (variable valueName intType)
            ]

overwrittenAssignment :: Bool
overwrittenAssignment =
    optimizedBody
        ( intModule
            [ binding valueName intType True (integer 0)
            , CoreAssign valueName (integer 1)
            , CoreAssign valueName (integer 2)
            , CoreReturn (variable valueName intType)
            ]
        )
        == Just
            [ binding valueName intType True (integer 0)
            , CoreAssign valueName (integer 2)
            , CoreReturn (variable valueName intType)
            ]

branchAssignmentRetainsDeclaration :: Bool
branchAssignmentRetainsDeclaration =
    let function = CoreFunction entryName [(secondName, boolType)] intType body
        body =
            [ binding valueName intType True (integer 0)
            , CoreIf
                (variable secondName boolType)
                [CoreAssign valueName (integer 1)]
                [CoreAssign valueName (integer 2)]
            , CoreReturn (variable valueName intType)
            ]
     in optimizedBody (moduleWith [function]) == Just body

deadBranchAssignment :: Bool
deadBranchAssignment =
    let function = CoreFunction entryName [(secondName, boolType)] unitType body
        body =
            [ binding valueName intType True (integer 0)
            , CoreIf
                (variable secondName boolType)
                [CoreAssign valueName (integer 1)]
                [CoreAssign valueName (integer 2)]
            , CoreReturn unit
            ]
     in optimizedBody (moduleWith [function]) == Just [CoreReturn unit]

effectfulBindingBecomesEvaluation :: Bool
effectfulBindingBecomesEvaluation =
    optimizedBody
        ( moduleWith
            [ entry unitType [binding valueName unitType False effectCall, CoreReturn unit]
            , effectFunction
            ]
        )
        == Just [CoreEvaluate effectCall, CoreReturn unit]

closureBodyOptimized :: Bool
closureBodyOptimized =
    let closure =
            closureExpression
                []
                []
                intType
                [ binding valueName intType False (integer 40)
                , CoreReturn (primitive CoreAdd [variable valueName intType, integer 2] intType)
                , CoreEvaluate effectCall
                ]
        input = moduleWith [entry (expressionType closure) [CoreReturn closure], effectFunction]
     in case returnExpression input of
            Just (CoreClosure _ _ _ body _) -> body == [CoreReturn (integer 42)]
            _ -> False

closureCapturePropagates :: Bool
closureCapturePropagates =
    let capture = CoreCapture StrongCapture capturedValueName intType (integer 40)
        closure =
            closureExpression
                [capture]
                []
                intType
                [CoreReturn (primitive CoreAdd [variable capturedValueName intType, integer 2] intType)]
     in case returnExpression (moduleWith [entry (expressionType closure) [CoreReturn closure]]) of
            Just (CoreClosure _ _ _ body _) -> body == [CoreReturn (integer 42)]
            _ -> False

closureParameterShadowsCapture :: Bool
closureParameterShadowsCapture =
    let capture = CoreCapture StrongCapture closureParameterName intType (integer 40)
        closure =
            closureExpression
                [capture]
                [(closureParameterName, intType)]
                intType
                [CoreReturn (variable closureParameterName intType)]
     in case returnExpression (moduleWith [entry (expressionType closure) [CoreReturn closure]]) of
            Just (CoreClosure _ _ _ body _) -> body == [CoreReturn (variable closureParameterName intType)]
            _ -> False

disabledOptions :: OptimizerOptions
disabledOptions = OptimizerOptions 12 False False False False False 24

disabledPipelineIsIdentity :: Bool
disabledPipelineIsIdentity =
    let input = intModule [CoreReturn (primitive CoreAdd [integer 20, integer 22] intType)]
     in (optimizedCore <$> optimizedWith disabledOptions input) == Just input

constantPassCanBeDisabled :: Bool
constantPassCanBeDisabled =
    let input = intModule [CoreReturn expression]
        expression = primitive CoreAdd [integer 20, integer 22] intType
        options = defaultOptimizerOptions {optimizerConstantPropagation = False}
     in returnFromResult (optimizedWith options input) == Just expression

controlFlowPassCanBeDisabled :: Bool
controlFlowPassCanBeDisabled =
    let branch = CoreIf (boolean True) [CoreReturn (integer 1)] [CoreReturn (integer 2)]
        input = intModule [branch]
        options = defaultOptimizerOptions {optimizerControlFlowSimplification = False}
     in bodyFromResult (optimizedWith options input) == Just [branch]

deadCodePassCanBeDisabled :: Bool
deadCodePassCanBeDisabled =
    let dead = binding valueName intType False (integer 42)
        input = unitModule [dead]
        options = defaultOptimizerOptions {optimizerDeadCodeElimination = False}
     in bodyFromResult (optimizedWith options input) == Just [dead, CoreReturn unit]

bodyFromResult :: Maybe OptimizationResult -> Maybe [CoreStatement]
bodyFromResult maybeResult = do
    result <- maybeResult
    case coreModuleFunctions (optimizedCore result) of
        function : _ -> Just (coreFunctionBody function)
        [] -> Nothing

returnFromResult :: Maybe OptimizationResult -> Maybe CoreExpression
returnFromResult maybeResult = do
    body <- bodyFromResult maybeResult
    case body of
        [CoreReturn value] -> Just value
        _ -> Nothing

pipelineFixture :: CoreModule
pipelineFixture =
    intModule
        [ binding valueName intType False (integer 40)
        , binding secondName intType False (primitive CoreAdd [variable valueName intType, integer 2] intType)
        , CoreIf
            (primitive CoreEqual [variable secondName intType, integer 42] boolType)
            [CoreReturn (variable secondName intType)]
            [CoreReturn (integer 0)]
        ]

reportsConvergence :: Bool
reportsConvergence = maybe False optimizationConverged (optimized pipelineFixture)

reportsIterationLimit :: Bool
reportsIterationLimit =
    case optimizedWith defaultOptimizerOptions {optimizerMaximumIterations = 1} pipelineFixture of
        Just result -> optimizationIterations result == 1 && not (optimizationConverged result)
        Nothing -> False

metricsCountFunctions :: Bool
metricsCountFunctions =
    case optimized (moduleWith [entry unitType [CoreReturn unit], effectFunction]) of
        Just result -> metricFunctions (optimizationBefore result) == 2
        Nothing -> False

metricsReportReduction :: Bool
metricsReportReduction =
    case optimized pipelineFixture of
        Just result ->
            metricStatements (optimizationAfter result) < metricStatements (optimizationBefore result)
                && metricBindings (optimizationAfter result) < metricBindings (optimizationBefore result)
                && metricBranches (optimizationAfter result) < metricBranches (optimizationBefore result)
        Nothing -> False

metricsCountEffects :: Bool
metricsCountEffects =
    let closure = closureExpression [] [] unitType [CoreReturn unit]
        input =
            moduleWith
                [ entry
                    unitType
                    [ CoreEvaluate effectCall
                    , CoreEvaluate closure
                    , CoreReturn unit
                    ]
                , effectFunction
                ]
     in case optimized input of
            Just result ->
                metricCalls (optimizationBefore result) == 1
                    && metricClosures (optimizationBefore result) == 2
                    && metricCalls (optimizationAfter result) == 1
                    && metricClosures (optimizationAfter result) == 2
            Nothing -> False

reportsPreservePassOrder :: Bool
reportsPreservePassOrder =
    case optimized pipelineFixture of
        Just result ->
            take 4 (map passReportPass (optimizationPassReports result))
                == [ InliningPass
                   , ConstantPropagationPass
                   , ControlFlowSimplificationPass
                   , DeadCodeEliminationPass
                   ]
        Nothing -> False

reportsIdentifyChanges :: Bool
reportsIdentifyChanges =
    case optimized pipelineFixture of
        Just result ->
            any
                ( \report ->
                    passReportPass report == ConstantPropagationPass
                        && passReportIteration report == 1
                        && passReportChanged report
                )
                (optimizationPassReports result)
                && any
                    ( \report ->
                        passReportPass report == DeadCodeEliminationPass
                            && passReportIteration report == 1
                            && passReportChanged report
                    )
                    (optimizationPassReports result)
        Nothing -> False

reportsCoverIterations :: Bool
reportsCoverIterations =
    case optimized pipelineFixture of
        Just result ->
            let iterations = map passReportIteration (optimizationPassReports result)
             in not (null iterations)
                    && minimum iterations == 1
                    && maximum iterations == optimizationIterations result
                    && length iterations == optimizationIterations result * 4
        Nothing -> False

reportsOmitDisabledPasses :: Bool
reportsOmitDisabledPasses =
    let options =
            defaultOptimizerOptions
                { optimizerConstantPropagation = False
                , optimizerDeadCodeElimination = False
                , optimizerInlining = False
                }
     in case optimizedWith options pipelineFixture of
            Just result ->
                not (null (optimizationPassReports result))
                    && all
                        ((== ControlFlowSimplificationPass) . passReportPass)
                        (optimizationPassReports result)
            Nothing -> False

reportMetricsAreContinuous :: Bool
reportMetricsAreContinuous =
    case optimized pipelineFixture of
        Just result -> continuous (optimizationPassReports result)
        Nothing -> False
    where
        continuous [] = True
        continuous [_] = True
        continuous (first : second : remaining) =
            passReportAfter first == passReportBefore second
                && continuous (second : remaining)

optimizerIsIdempotent :: Bool
optimizerIsIdempotent = doOptimizeTwice pipelineFixture

doOptimizeTwice :: CoreModule -> Bool
doOptimizeTwice input = case optimized input of
    Nothing -> False
    Just first -> case optimized (optimizedCore first) of
        Nothing -> False
        Just second -> optimizedCore first == optimizedCore second

optimizedOutputVerifies :: Bool
optimizedOutputVerifies = case optimized pipelineFixture of
    Nothing -> False
    Just result -> case verifyCore (optimizedCore result) of
        Right _ -> True
        Left _ -> False

invalidInputRejected :: Bool
invalidInputRejected =
    let invalidName = ResolvedName (SymbolId 0) (Identifier "Invalid")
        invalid = moduleWith [CoreFunction invalidName [] unitType [CoreReturn unit]]
     in case optimizeCoreWith defaultOptimizerOptions invalid of
            Left _ -> True
            Right _ -> False
