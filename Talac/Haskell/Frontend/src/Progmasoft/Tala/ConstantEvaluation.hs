-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

-- | Side-effect-free constant evaluation used for target-range diagnostics.
module Progmasoft.Tala.ConstantEvaluation
    ( ConstantIntegerError (..)
    , evaluateConstantInteger
    , renderConstantIntegerError
    ) where

import Data.Bits (complement, shiftL, xor, (.&.), (.|.))
import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
    ( ScalarFamily (UnsignedIntegerFamily)
    , scalarTypeFamily
    , scalarTypeWidth
    , typeToScalarType
    )
import Progmasoft.Tala.IntegerEvaluation
    ( CompileTimeIntegerError (..)
    , checkCompileTimeInteger
    , evaluateCompileTimePower
    , evaluateCompileTimeShiftLeft
    , evaluateCompileTimeShiftRight
    , multiplyCompileTimeIntegers
    )

-- | Definite arithmetic failures detected during integer constant evaluation.
data ConstantIntegerError
    = -- | Division used a zero divisor.
      ConstantDivisionByZero
    | -- | Floor division used a zero divisor.
      ConstantFloorDivisionByZero
    | -- | Remainder used a zero divisor.
      ConstantRemainderByZero
    | -- | Integer power used a negative exponent.
      ConstantNegativeExponent
    | -- | Exact evaluation exceeded its resource bound.
      ConstantEvaluationLimitExceeded
    deriving (Eq, Ord, Read, Show)

-- Non-constant expressions return Nothing. A definite arithmetic failure is
-- retained as Left so callers can diagnose it without pretending the entire
-- expression ceased to be constant.
-- The resource error is likewise retained: treating an oversized expression
-- as merely nonconstant would let it bypass the frontend's compile-time bound.

{- | Evaluate a constant integer expression without executing user code.
@Right Nothing@ means non-constant; @Left@ preserves a definite arithmetic
error so callers can report it at the originating expression.
-}
evaluateConstantInteger :: Expression name Type -> Either ConstantIntegerError (Maybe Integer)
evaluateConstantInteger expression = case expression of
    LiteralExpression _ literal _ -> case literal of
        IntegerLiteral value -> checkedValue value
        CharacterLiteral value -> checkedValue value
        BooleanLiteral value -> checkedValue (if value then 1 else 0)
        _ -> pure Nothing
    UnaryExpression _ operator value resultType -> do
        operand <- evaluateConstantInteger value
        case (operator, operand) of
            (UnaryPlus, Just number) -> checkedMaybe number
            (UnaryNegate, Just number) -> checkedMaybe (-number)
            (LogicalNot, Just number) -> checkedMaybe (if number == 0 then 1 else 0)
            (BitwiseNot, Just number) -> checkedMaybe (typedBitwiseComplement resultType number)
            _ -> pure Nothing
    BinaryExpression _ operator left right _ -> do
        leftValue <- evaluateConstantInteger left
        rightValue <- evaluateConstantInteger right
        evaluateBinary operator leftValue rightValue
    -- Only the selected operand is evaluated, so a definite arithmetic error
    -- in the other one is not a property of this expression.
    ConditionalExpression _ condition first second _ -> do
        test <- evaluateConstantInteger condition
        case test of
            Just number -> evaluateConstantInteger (if number /= 0 then first else second)
            Nothing -> pure Nothing
    CoalesceExpression _ left fallback _ -> do
        leftValue <- evaluateConstantInteger left
        case leftValue of
            Just 0 -> evaluateConstantInteger fallback
            other -> pure other
    _ -> pure Nothing

typedBitwiseComplement :: Type -> Integer -> Integer
typedBitwiseComplement resultType value = case typeToScalarType resultType of
    Just scalar
        | scalarTypeFamily scalar == UnsignedIntegerFamily ->
            complement value .&. ((1 `shiftL` scalarTypeWidth scalar) - 1)
    _ -> complement value

checkedValue :: Integer -> Either ConstantIntegerError (Maybe Integer)
checkedValue value = Just <$> mapLimitError (checkCompileTimeInteger value)

checkedMaybe :: Integer -> Either ConstantIntegerError (Maybe Integer)
checkedMaybe value = Just <$> mapLimitError (checkCompileTimeInteger value)

mapLimitError :: Either CompileTimeIntegerError value -> Either ConstantIntegerError value
mapLimitError result = case result of
    Right value -> Right value
    Left CompileTimeNegativeExponent -> Left ConstantNegativeExponent
    Left CompileTimeIntegerLimitExceeded -> Left ConstantEvaluationLimitExceeded

evaluateBinary :: BinaryOperator -> Maybe Integer -> Maybe Integer -> Either ConstantIntegerError (Maybe Integer)
evaluateBinary _ Nothing _ = pure Nothing
evaluateBinary _ _ Nothing = pure Nothing
evaluateBinary operator (Just left) (Just right) = case operator of
    Add -> value (left + right)
    Subtract -> value (left - right)
    Multiply -> Just <$> mapLimitError (multiplyCompileTimeIntegers left right)
    Divide
        | right == 0 -> Left ConstantDivisionByZero
        | otherwise -> value (left `quot` right)
    FloorDivide
        | right == 0 -> Left ConstantFloorDivisionByZero
        | otherwise -> value (roundedIntegerDivision left right)
    Remainder
        | right == 0 -> Left ConstantRemainderByZero
        | otherwise -> value (left `rem` right)
    Power
        | right < 0 -> Left ConstantNegativeExponent
        | otherwise -> Just <$> mapLimitError (evaluateCompileTimePower left right)
    ShiftLeft -> Just <$> mapLimitError (evaluateCompileTimeShiftLeft left right)
    ShiftRight -> Just <$> mapLimitError (evaluateCompileTimeShiftRight left right)
    BitwiseAnd -> value (left .&. right)
    BitwiseXor -> value (xor left right)
    BitwiseOr -> value (left .|. right)
    LessThan -> boolean (left < right)
    LessEqual -> boolean (left <= right)
    GreaterThan -> boolean (left > right)
    GreaterEqual -> boolean (left >= right)
    Equal -> boolean (left == right)
    NotEqual -> boolean (left /= right)
    LogicalAnd -> boolean (left /= 0 && right /= 0)
    LogicalOr -> boolean (left /= 0 || right /= 0)
    where
        value number = Just <$> mapLimitError (checkCompileTimeInteger number)
        boolean result = value (if result then 1 else 0)

-- `//` is nearest-integer division with exact halves moving away from zero.
-- quotRem gives a truncating quotient; comparing twice the remainder magnitude
-- avoids floating conversion and therefore remains exact for arbitrary-width
-- compile-time integers.
roundedIntegerDivision :: Integer -> Integer -> Integer
roundedIntegerDivision dividend divisor =
    let (quotient, remainder) = dividend `quotRem` divisor
        adjustment = signum dividend * signum divisor
     in if 2 * abs remainder >= abs divisor then quotient + adjustment else quotient

-- | Render a constant arithmetic failure for diagnostic presentation.
renderConstantIntegerError :: ConstantIntegerError -> String
renderConstantIntegerError issue = case issue of
    ConstantDivisionByZero -> "constant division by zero"
    ConstantFloorDivisionByZero -> "constant floor division by zero"
    ConstantRemainderByZero -> "constant remainder by zero"
    ConstantNegativeExponent -> "constant integer exponent cannot be negative"
    ConstantEvaluationLimitExceeded -> "constant integer expression exceeds the compile-time evaluation limit"
