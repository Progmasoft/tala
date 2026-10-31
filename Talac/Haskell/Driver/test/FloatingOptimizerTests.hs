-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module FloatingOptimizerTests (floatingOptimizerTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Verifier (verifyCore)

-- These are end-to-end Core tests, not tests of a private arithmetic helper.
-- Every case first passes the Core verifier, executes the real fixed-point
-- optimizer, and observes the resulting verified Core expression.
floatingOptimizerTests :: [(String, Bool)]
floatingOptimizerTests =
    [
        ( "binary64 addition rounds 0.1 plus 0.2 to the IEEE result"
        , resultIs CoreAdd ["0.1", "0.2"] floatType (CoreFloating "3.0000000000000004e-1")
        )
    , ("binary16 addition folds exact finite values", resultIs CoreAdd ["1.5", "2.25"] sfloatType (CoreFloating "3.75e0"))
    ,
        ( "binary32 uses its own precision rather than binary64"
        , resultIs CoreAdd ["0.1", "0.2"] lfloatType (CoreFloating "3.0e-1")
        )
    , ("binary128 preserves precision beyond a host Double", binary128RetainsSmallIncrement)
    ,
        ( "binary16 halfway rounds to the even lower significand"
        , resultIs CoreAdd ["1.0", "4.8828125e-4"] sfloatType (CoreFloating "1.0e0")
        )
    ,
        ( "binary16 halfway rounds to the even upper significand"
        , resultIs CoreAdd ["1.0", "1.46484375e-3"] sfloatType (CoreFloating "1.002e0")
        )
    , ("binary32 halfway rounds to the even lower significand", halfwayRoundsDown lfloatType 24)
    , ("binary64 halfway rounds to the even lower significand", halfwayRoundsDown floatType 53)
    , ("binary128 halfway rounds to the even lower significand", halfwayRoundsDown doubleType 113)
    ,
        ( "binary16 minimum subnormal survives exact addition"
        , resultIs CoreAdd ["5.9604644775390625e-8", "5.9604644775390625e-8"] sfloatType (CoreFloating "1.0e-7")
        )
    ,
        ( "binary16 half-minimum subnormal tie rounds to signed zero"
        , resultIs CoreMultiply ["5.9604644775390625e-8", "0.5"] sfloatType (CoreFloating "0.0")
        )
    ,
        ( "finite arithmetic overflow produces infinity"
        , resultIs CoreMultiply ["65504.0", "2.0"] sfloatType (CoreFloating "inf")
        )
    ,
        ( "negative finite overflow retains its sign"
        , resultIs CoreMultiply ["-65504.0", "2.0"] sfloatType (CoreFloating "-inf")
        )
    , ("addition preserves two negative zero operands", resultIs CoreAdd ["-0.0", "-0.0"] floatType (CoreFloating "-0.0"))
    ,
        ( "opposite signed zero addition produces positive zero"
        , resultIs CoreAdd ["-0.0", "0.0"] floatType (CoreFloating "0.0")
        )
    ,
        ( "exact finite cancellation produces positive zero"
        , resultIs CoreSubtract ["1.0", "1.0"] doubleType (CoreFloating "0.0")
        )
    ,
        ( "negative zero multiplication tracks the sign xor"
        , resultIs CoreMultiply ["-0.0", "3.0"] floatType (CoreFloating "-0.0")
        )
    , ("negative zero division tracks the sign xor", resultIs CoreDivide ["-0.0", "2.0"] floatType (CoreFloating "-0.0"))
    ,
        ( "division by positive zero produces positive infinity"
        , resultIs CoreDivide ["1.0", "0.0"] floatType (CoreFloating "inf")
        )
    ,
        ( "division by negative zero produces negative infinity"
        , resultIs CoreDivide ["1.0", "-0.0"] floatType (CoreFloating "-inf")
        )
    , ("zero divided by zero produces NaN", resultIs CoreDivide ["0.0", "0.0"] floatType (CoreFloating "nan"))
    , ("infinity divided by infinity produces NaN", resultIs CoreDivide ["inf", "inf"] floatType (CoreFloating "nan"))
    ,
        ( "positive infinity plus finite remains positive infinity"
        , resultIs CoreAdd ["inf", "-12.5"] floatType (CoreFloating "inf")
        )
    , ("opposite infinities add to NaN", resultIs CoreAdd ["inf", "-inf"] floatType (CoreFloating "nan"))
    , ("infinity times zero produces NaN", resultIs CoreMultiply ["inf", "0.0"] floatType (CoreFloating "nan"))
    ,
        ( "infinity times a negative finite value flips sign"
        , resultIs CoreMultiply ["inf", "-2.0"] floatType (CoreFloating "-inf")
        )
    ,
        ( "finite value divided by infinity produces signed zero"
        , resultIs CoreDivide ["-1.0", "inf"] floatType (CoreFloating "-0.0")
        )
    , ("infinity divided by zero remains infinity", resultIs CoreDivide ["-inf", "-0.0"] floatType (CoreFloating "inf"))
    ,
        ( "remainder keeps the sign of a negative dividend"
        , resultIs CoreRemainder ["-7.5", "2.0"] floatType (CoreFloating "-1.5e0")
        )
    , ("remainder ignores a negative divisor sign", resultIs CoreRemainder ["7.5", "-2.0"] floatType (CoreFloating "1.5e0"))
    ,
        ( "negative-zero remainder preserves the dividend sign"
        , resultIs CoreRemainder ["-0.0", "3.0"] floatType (CoreFloating "-0.0")
        )
    ,
        ( "finite remainder by infinity preserves the dividend"
        , resultIs CoreRemainder ["-7.5", "inf"] floatType (CoreFloating "-7.5e0")
        )
    , ("infinite remainder remains NaN", resultIs CoreRemainder ["inf", "2.0"] floatType (CoreFloating "nan"))
    ,
        ( "rounded division of floating operands returns int"
        , resultIs CoreFloorDivide ["7.8", "2.0"] integerResultType (CoreInteger 4)
        )
    , ("floating rounded division by one is not an invalid identity", floatingRoundedDivisionByOne)
    ,
        ( "floating rounded division breaks exact halves away from zero"
        , resultIs CoreFloorDivide ["-7.0", "2.0"] integerResultType (CoreInteger (-4))
        )
    , ("out-of-range rounded floating quotient is not narrowed", roundedQuotientRetained)
    , ("NaN equality is false", resultIs CoreEqual ["nan", "nan"] boolType (CoreBoolean False))
    , ("NaN inequality is true under unordered comparison", resultIs CoreNotEqual ["nan", "1.0"] boolType (CoreBoolean True))
    , ("NaN less-than is false", resultIs CoreLessThan ["nan", "1.0"] boolType (CoreBoolean False))
    , ("NaN less-equal is false", resultIs CoreLessEqual ["nan", "1.0"] boolType (CoreBoolean False))
    , ("NaN greater-than is false", resultIs CoreGreaterThan ["nan", "1.0"] boolType (CoreBoolean False))
    , ("NaN greater-equal is false", resultIs CoreGreaterEqual ["nan", "1.0"] boolType (CoreBoolean False))
    , ("positive and negative zero compare equal", resultIs CoreEqual ["-0.0", "0.0"] boolType (CoreBoolean True))
    ,
        ( "positive infinity compares above every finite binary64 value"
        , resultIs CoreGreaterThan ["inf", "1e300"] boolType (CoreBoolean True)
        )
    ,
        ( "negative infinity compares below every finite binary128 value"
        , resultIsFor CoreLessThan ["-inf", "1e4000"] doubleType boolType (CoreBoolean True)
        )
    ,
        ( "finite binary128 value compares above negative infinity"
        , resultIsFor CoreGreaterThan ["-1e4000", "-inf"] doubleType boolType (CoreBoolean True)
        )
    ,
        ( "positive infinity compares above negative infinity"
        , resultIs CoreGreaterThan ["inf", "-inf"] boolType (CoreBoolean True)
        )
    ,
        ( "finite division retains binary16 target precision"
        , resultIs CoreDivide ["1.0", "3.0"] sfloatType (CoreFloating "3.333e-1")
        )
    ,
        ( "finite division retains binary32 target precision"
        , resultIs CoreDivide ["1.0", "3.0"] lfloatType (CoreFloating "3.3333334e-1")
        )
    ,
        ( "finite division retains binary64 target precision"
        , resultIs CoreDivide ["1.0", "3.0"] floatType (CoreFloating "3.333333333333333e-1")
        )
    ,
        ( "finite division retains binary128 target precision"
        , resultIs CoreDivide ["1.0", "3.0"] doubleType (CoreFloating "3.333333333333333333333333333333333e-1")
        )
    , ("logical truthiness treats floating positive zero as false", logicalNot "0.0" (CoreBoolean True))
    , ("logical truthiness treats negative zero as false", logicalNot "-0.0" (CoreBoolean True))
    , ("logical truthiness treats NaN as nonzero", logicalNot "nan" (CoreBoolean False))
    , ("logical truthiness treats infinity as nonzero", logicalNot "inf" (CoreBoolean False))
    , ("unsupported floating power stays explicit", powerRemainsExplicit)
    , ("long runs of insignificant zeroes fold through normalized decimal digits", longZeroRunsFold)
    , ("the significant-digit fold limit is inclusive", maximumSupportedDecimalFolds)
    , ("oversized significant decimal input remains a valid explicit primitive", oversizedDecimalRemainsExplicit)
    , ("oversized exponent text remains a valid explicit primitive", oversizedExponentRemainsExplicit)
    , ("short decimal rendering round-trips through the Core verifier", renderedLiteralVerifies)
    ]

sfloatType, lfloatType, floatType, doubleType, integerResultType :: Type
sfloatType = namedType "sfloat"
lfloatType = namedType "lfloat"
floatType = namedType "float"
doubleType = namedType "double"
integerResultType = namedType "int"

functionName :: ResolvedName
functionName = ResolvedName (SymbolId 1) (Identifier "Evaluate")

testModule :: Type -> CoreExpression -> CoreModule
testModule resultType expression =
    CoreModule
        (QualifiedName [Identifier "Floating", Identifier "Optimizer", Identifier "Tests"])
        [CoreFunction functionName [] resultType [CoreReturn expression]]

expressionResult :: Type -> CoreExpression -> Maybe CoreExpression
expressionResult resultType expression = do
    optimized <- either (const Nothing) Just (runCoreOptimizer defaultCoreOptimizer (testModule resultType expression))
    function <- case coreModuleFunctions optimized of
        [single] -> Just single
        _ -> Nothing
    case coreFunctionBody function of
        [CoreReturn value] -> Just value
        _ -> Nothing

resultIs :: CorePrimitive -> [String] -> Type -> CoreLiteral -> Bool
resultIs primitive spellings resultType expected =
    resultIsFor primitive spellings (operandType spellings resultType) resultType expected

resultIsFor :: CorePrimitive -> [String] -> Type -> Type -> CoreLiteral -> Bool
resultIsFor primitive spellings sourceType resultType expected =
    let operands = map (\spelling -> CoreLiteral (CoreFloating spelling) sourceType) spellings
        expression = CorePrimitive primitive operands resultType
     in expressionResult resultType expression == Just (CoreLiteral expected resultType)

operandType :: [String] -> Type -> Type
operandType _ resultType
    | resultType == boolType = floatType
    | resultType == integerResultType = floatType
    | otherwise = resultType

logicalNot :: String -> CoreLiteral -> Bool
logicalNot spelling expected =
    let expression = CorePrimitive CoreLogicalNot [CoreLiteral (CoreFloating spelling) floatType] boolType
     in expressionResult boolType expression == Just (CoreLiteral expected boolType)

binary128RetainsSmallIncrement :: Bool
binary128RetainsSmallIncrement =
    case resultOf CoreAdd ["1.0", "1e-34"] doubleType doubleType of
        Just (CoreLiteral (CoreFloating spelling) _) -> spelling /= "1.0e0"
        _ -> False

halfwayRoundsDown :: Type -> Int -> Bool
halfwayRoundsDown valueType precision =
    resultIs CoreAdd ["1.0", exactHalfUlp precision] valueType (CoreFloating "1.0e0")

exactHalfUlp :: Int -> String
exactHalfUlp precision = "0." ++ replicate (precision - length digits) '0' ++ digits
    where
        digits = show (5 ^ precision :: Integer)

roundedQuotientRetained :: Bool
roundedQuotientRetained =
    case resultOf CoreFloorDivide ["1e100", "1.0"] floatType integerResultType of
        Just CorePrimitive {} -> True
        _ -> False

floatingRoundedDivisionByOne :: Bool
floatingRoundedDivisionByOne =
    case runCoreOptimizer defaultCoreOptimizer inputModule of
        Right optimized -> case coreModuleFunctions optimized of
            [function] -> case coreFunctionBody function of
                [CoreReturn (CorePrimitive CoreFloorDivide _ resultType)] -> resultType == integerResultType
                _ -> False
            _ -> False
        Left _ -> False
    where
        inputName = ResolvedName (SymbolId 2) (Identifier "value")
        inputModule =
            CoreModule
                (QualifiedName [Identifier "Floating", Identifier "Optimizer", Identifier "Tests"])
                [ CoreFunction
                    functionName
                    [(inputName, floatType)]
                    integerResultType
                    [ CoreReturn
                        ( CorePrimitive
                            CoreFloorDivide
                            [ CoreVariable inputName floatType
                            , CoreLiteral (CoreFloating "1.0") floatType
                            ]
                            integerResultType
                        )
                    ]
                ]

powerRemainsExplicit :: Bool
powerRemainsExplicit =
    case resultOf CorePower ["2.0", "3.0"] floatType floatType of
        Just CorePrimitive {} -> True
        _ -> False

renderedLiteralVerifies :: Bool
renderedLiteralVerifies = case resultOf CoreAdd ["0.1", "0.2"] floatType floatType of
    Just literal@CoreLiteral {} -> either (const False) (const True) (verifyCore (testModule floatType literal))
    _ -> False

longZeroRunsFold :: Bool
longZeroRunsFold =
    case resultOf CoreAdd [spelling, "0.0"] doubleType doubleType of
        Just literal@(CoreLiteral (CoreFloating "1.0e-1001") _) -> either (const False) (const True) (verifyCore (testModule doubleType literal))
        _ -> False
    where
        spelling = "0." ++ replicate 1000 '0' ++ "1" ++ replicate 1000 '0'

maximumSupportedDecimalFolds :: Bool
maximumSupportedDecimalFolds =
    case resultOf CoreAdd ["1" ++ replicate 511 '0', "0.0"] doubleType doubleType of
        Just CoreLiteral {} -> True
        _ -> False

oversizedDecimalRemainsExplicit :: Bool
oversizedDecimalRemainsExplicit =
    case resultOf CoreAdd [replicate 513 '1', "0.0"] doubleType doubleType of
        Just CorePrimitive {} -> True
        _ -> False

oversizedExponentRemainsExplicit :: Bool
oversizedExponentRemainsExplicit =
    case resultOf CoreAdd ["1e" ++ replicate 20 '9', "0.0"] doubleType doubleType of
        Just CorePrimitive {} -> True
        _ -> False

resultOf :: CorePrimitive -> [String] -> Type -> Type -> Maybe CoreExpression
resultOf primitive spellings operand value =
    let operands = map (\spelling -> CoreLiteral (CoreFloating spelling) operand) spellings
     in expressionResult value (CorePrimitive primitive operands value)
