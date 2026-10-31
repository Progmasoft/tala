-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Exact evaluation for compile-time values embedded in type syntax.

This module intentionally does not reuse runtime numeric coercion. Template
values participate in specialization identity, so host overflow, floating
approximation, and truthy conversions would make artifacts non-portable.
-}
module Progmasoft.Tala.TemplateValue
    ( TemplateValueError (..)
    , evaluateTemplateValue
    , evaluateFixedArraySize
    , renderTemplateValueError
    , templateValueSyntaxSpan
    ) where

import Data.Bits (complement, xor, (.&.), (.|.))
import Progmasoft.Tala.AST
import Progmasoft.Tala.IntegerEvaluation
    ( CompileTimeIntegerError (..)
    , checkCompileTimeInteger
    , evaluateCompileTimePower
    , evaluateCompileTimeShiftLeft
    , evaluateCompileTimeShiftRight
    , multiplyCompileTimeIntegers
    )

-- | Failure while evaluating a template constant or fixed-array extent.
data TemplateValueError
    = -- | Name is not a compile-time constant.
      TemplateValueIsNotConstant QualifiedName
    | -- | Division has a zero divisor.
      TemplateValueDivisionByZero
    | -- | Floor division has a zero divisor.
      TemplateValueFloorDivisionByZero
    | -- | Remainder has a zero divisor.
      TemplateValueRemainderByZero
    | -- | Integer exponent is negative.
      TemplateValueNegativeExponent Integer
    | -- | Exact arithmetic exceeded its resource bound.
      TemplateValueEvaluationLimitExceeded
    | -- | Fixed-array extent is not integral.
      TemplateValueRequiresInteger TemplateValue
    | -- | Fixed-array extent is negative.
      TemplateValueNegativeArraySize Integer
    deriving (Eq, Ord, Read, Show)

data ExactValue
    = ExactInteger Integer
    | ExactBoolean Bool
    | ExactCharacter Integer
    deriving (Eq, Ord, Read, Show)

-- | Evaluate type-syntax constants exactly, preserving their source-level kind.
evaluateTemplateValue :: TemplateValueSyntax -> Either TemplateValueError TemplateValue
evaluateTemplateValue syntax = exactToTemplate <$> evaluateExact syntax

-- | Evaluate a fixed-array extent and reject negative or non-integer values.
evaluateFixedArraySize :: TemplateValueSyntax -> Either TemplateValueError TemplateValue
evaluateFixedArraySize syntax = do
    value <- evaluateTemplateValue syntax
    case value of
        IntegerTemplateValue integer
            | integer < 0 -> Left (TemplateValueNegativeArraySize integer)
            | otherwise -> Right value
        CharacterTemplateValue scalar -> Right (IntegerTemplateValue scalar)
        other -> Left (TemplateValueRequiresInteger other)

evaluateExact :: TemplateValueSyntax -> Either TemplateValueError ExactValue
evaluateExact syntax = case syntax of
    TemplateIntegerSyntax _ value -> ExactInteger <$> checkedTemplateInteger value
    TemplateCharacterSyntax _ value -> ExactCharacter <$> checkedTemplateInteger value
    TemplateBooleanSyntax _ value -> Right (ExactBoolean value)
    TemplateNameSyntax _ name -> Left (TemplateValueIsNotConstant name)
    TemplateUnarySyntax _ operator operand -> do
        value <- evaluateExact operand
        evaluateUnary operator value
    TemplateBinarySyntax _ operator left right -> do
        -- Both operands must be exact values before specialization identity can
        -- be formed; failures are reported here rather than deferred to Core.
        leftValue <- evaluateExact left
        rightValue <- evaluateExact right
        evaluateBinary operator leftValue rightValue

evaluateUnary :: UnaryOperator -> ExactValue -> Either TemplateValueError ExactValue
evaluateUnary operator value = case operator of
    UnaryPlus -> requireInteger value >>= (ExactInteger <$>) . checkedTemplateInteger
    UnaryNegate -> requireInteger value >>= (ExactInteger <$>) . checkedTemplateInteger . negate
    LogicalNot -> ExactBoolean . not <$> requireBooleanContext value
    BitwiseNot -> requireInteger value >>= (ExactInteger <$>) . checkedTemplateInteger . complement

evaluateBinary :: BinaryOperator -> ExactValue -> ExactValue -> Either TemplateValueError ExactValue
evaluateBinary operator left right = case operator of
    Add -> integerBinary (+)
    Subtract -> integerBinary (-)
    Multiply -> integerBinaryEither multiplyCompileTimeIntegers
    Divide -> do
        divisor <- requireInteger right
        if divisor == 0
            then Left TemplateValueDivisionByZero
            else do
                dividend <- requireInteger left
                ExactInteger <$> checkedTemplateInteger (dividend `quot` divisor)
    FloorDivide -> do
        divisor <- requireInteger right
        if divisor == 0
            then Left TemplateValueFloorDivisionByZero
            else do
                dividend <- requireInteger left
                ExactInteger <$> checkedTemplateInteger (roundedIntegerDivision dividend divisor)
    Remainder -> do
        divisor <- requireInteger right
        if divisor == 0
            then Left TemplateValueRemainderByZero
            else do
                dividend <- requireInteger left
                ExactInteger <$> checkedTemplateInteger (dividend `rem` divisor)
    Power -> do
        exponentValue <- requireInteger right
        if exponentValue < 0
            then Left (TemplateValueNegativeExponent exponentValue)
            else do
                base <- requireInteger left
                ExactInteger <$> mapCompileTimeError exponentValue (evaluateCompileTimePower base exponentValue)
    ShiftLeft -> integerBinaryEither evaluateCompileTimeShiftLeft
    ShiftRight -> integerBinaryEither evaluateCompileTimeShiftRight
    BitwiseAnd -> integerBinary (.&.)
    BitwiseXor -> integerBinary xor
    BitwiseOr -> integerBinary (.|.)
    LessThan -> comparison (<)
    LessEqual -> comparison (<=)
    GreaterThan -> comparison (>)
    GreaterEqual -> comparison (>=)
    Equal -> Right (ExactBoolean (left == right))
    NotEqual -> Right (ExactBoolean (left /= right))
    LogicalAnd -> logical (&&)
    LogicalOr -> logical (||)
    where
        integerBinary operation = do
            lhs <- requireInteger left
            rhs <- requireInteger right
            ExactInteger <$> checkedTemplateInteger (operation lhs rhs)
        integerBinaryEither operation = do
            lhs <- requireInteger left
            rhs <- requireInteger right
            ExactInteger <$> mapCompileTimeError rhs (operation lhs rhs)
        comparison operation = do
            lhs <- requireInteger left
            rhs <- requireInteger right
            Right (ExactBoolean (operation lhs rhs))
        logical operation = do
            lhs <- requireBooleanContext left
            rhs <- requireBooleanContext right
            Right (ExactBoolean (operation lhs rhs))

roundedIntegerDivision :: Integer -> Integer -> Integer
roundedIntegerDivision dividend divisor =
    let (quotient, remainder) = dividend `quotRem` divisor
        adjustment = signum dividend * signum divisor
     in if 2 * abs remainder >= abs divisor then quotient + adjustment else quotient

requireInteger :: ExactValue -> Either TemplateValueError Integer
requireInteger value = case value of
    ExactInteger integer -> Right integer
    ExactCharacter scalar -> Right scalar
    ExactBoolean boolean -> Left (TemplateValueRequiresInteger (BooleanTemplateValue boolean))

requireBooleanContext :: ExactValue -> Either TemplateValueError Bool
requireBooleanContext value = case value of
    ExactBoolean boolean -> Right boolean
    ExactInteger integer -> Right (integer /= 0)
    ExactCharacter scalar -> Right (scalar /= 0)

exactToTemplate :: ExactValue -> TemplateValue
exactToTemplate value = case value of
    ExactInteger integer -> IntegerTemplateValue integer
    ExactBoolean boolean -> BooleanTemplateValue boolean
    ExactCharacter scalar -> CharacterTemplateValue scalar

-- | Return the source span enclosing one template-value syntax expression.
templateValueSyntaxSpan :: TemplateValueSyntax -> SourceSpan
templateValueSyntaxSpan syntax = case syntax of
    TemplateIntegerSyntax spanValue _ -> spanValue
    TemplateCharacterSyntax spanValue _ -> spanValue
    TemplateBooleanSyntax spanValue _ -> spanValue
    TemplateNameSyntax spanValue _ -> spanValue
    TemplateUnarySyntax spanValue _ _ -> spanValue
    TemplateBinarySyntax spanValue _ _ _ -> spanValue

-- | Render a constant-evaluation failure for a source diagnostic.
renderTemplateValueError :: TemplateValueError -> String
renderTemplateValueError issue = case issue of
    TemplateValueIsNotConstant (QualifiedName parts) ->
        "template value " ++ joinQualified (map identifierText parts) ++ " is not a resolved compile-time constant"
    TemplateValueDivisionByZero -> "template value performs division by zero"
    TemplateValueFloorDivisionByZero -> "template value performs floor division by zero"
    TemplateValueRemainderByZero -> "template value performs remainder by zero"
    TemplateValueNegativeExponent value -> "template value uses a negative integer exponent: " ++ show value
    TemplateValueEvaluationLimitExceeded -> "template integer expression exceeds the compile-time evaluation limit"
    TemplateValueRequiresInteger _ -> "fixed System.Array size must evaluate to an integer"
    TemplateValueNegativeArraySize value -> "fixed System.Array size cannot be negative: " ++ show value

joinQualified :: [String] -> String
joinQualified [] = "<empty>"
joinQualified [part] = part
joinQualified (part : parts) = part ++ "." ++ joinQualified parts

checkedTemplateInteger :: Integer -> Either TemplateValueError Integer
checkedTemplateInteger = mapCompileTimeError 0 . checkCompileTimeInteger

mapCompileTimeError :: Integer -> Either CompileTimeIntegerError value -> Either TemplateValueError value
mapCompileTimeError exponentValue result = case result of
    Right value -> Right value
    Left CompileTimeNegativeExponent -> Left (TemplateValueNegativeExponent exponentValue)
    Left CompileTimeIntegerLimitExceeded -> Left TemplateValueEvaluationLimitExceeded
