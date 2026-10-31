-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Central numeric operator and contextual-literal policy.

Lexer and parser establish literal identity. This module answers semantic
questions without constructing diagnostics, which keeps it usable by the
TypeChecker, Analyzer, and future constant evaluator.
-}
module Progmasoft.Tala.NumericSemantics
    ( NumericContext (..)
    , NumericRuleError (..)
    , NumericRuleResult (..)
    , integerLiteralRule
    , floatingLiteralRule
    , unaryNumericRule
    , binaryNumericRule
    , acceptsBooleanContext
    , renderNumericRuleError
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes

-- | Type context available while applying a literal or operator rule.
data NumericContext
    = -- | No destination type constrains the expression.
      NoNumericContext
    | -- | A concrete expected scalar type is available.
      TargetNumericType Type
    | -- | The expression is consumed as a condition.
      BooleanNumericContext
    deriving (Eq, Ord, Read, Show)

-- | Specific reason that a contextual literal or numeric operator is invalid.
data NumericRuleError
    = -- | Integer does not fit its selected scalar type.
      IntegerLiteralOutsideTarget ScalarType Integer
    | -- | Uncontextualized literal exceeds the default @int@ range.
      UntargetedIntegerOutsideInt Integer
    | -- | Expected target is not a floating-point type.
      FloatingLiteralRequiresFloatingTarget Type
    | -- | Unary operator received a non-numeric operand.
      UnaryRequiresNumeric UnaryOperator Type
    | -- | Bitwise operator received a non-integer operand.
      UnaryRequiresInteger UnaryOperator Type
    | -- | Negation received an unsigned or non-numeric operand.
      NegationRequiresSignedNumeric Type
    | -- | Logical negation operand is not condition-compatible.
      LogicalRequiresBooleanContext UnaryOperator Type
    | -- | Binary operands have different types.
      BinaryRequiresMatchingTypes BinaryOperator Type Type
    | -- | Arithmetic operator received a non-numeric type.
      BinaryRequiresNumericType BinaryOperator Type
    | -- | Integer-only operator received a non-integer type.
      BinaryRequiresIntegerType BinaryOperator Type
    | -- | Logical operands are not condition-compatible.
      BinaryRequiresBooleanContext BinaryOperator Type Type
    deriving (Eq, Ord, Read, Show)

-- | Result type and optional validation error produced by a numeric rule.
data NumericRuleResult = NumericRuleResult
    { numericRuleType :: Type
    -- ^ Type to assign even when the rule reports an error.
    , numericRuleError :: Maybe NumericRuleError
    -- ^ Failure details, or @Nothing@ on success.
    }
    deriving (Eq, Ord, Read, Show)

{- | Select and range-check the type of an integer literal from its context.
Boolean conditions retain the language's documented numeric condition rule;
an unconstrained literal defaults to @int@ and must fit that exact range.
-}
integerLiteralRule :: NumericContext -> Integer -> NumericRuleResult
integerLiteralRule context value = case context of
    BooleanNumericContext -> success boolType
    TargetNumericType target -> case typeToScalarType target of
        Just BooleanScalar -> success boolType
        Just scalar
            | scalarTypeFamily scalar `elem` [SignedIntegerFamily, UnsignedIntegerFamily] ->
                if integerFits scalar value
                    then success (scalarTypeToType scalar)
                    else failure (scalarTypeToType scalar) (IntegerLiteralOutsideTarget scalar value)
        _ -> defaultInteger
    NoNumericContext -> defaultInteger
    where
        defaultInteger
            | integerFits defaultIntegerScalar value = success (scalarTypeToType defaultIntegerScalar)
            | otherwise = failure (scalarTypeToType defaultIntegerScalar) (UntargetedIntegerOutsideInt value)

-- | Select a floating literal type, requiring any explicit target to be float.
floatingLiteralRule :: NumericContext -> NumericRuleResult
floatingLiteralRule context = case context of
    TargetNumericType target -> case typeToScalarType target of
        Just scalar | scalarTypeFamily scalar == FloatingFamily -> success (scalarTypeToType scalar)
        _ -> failure (scalarTypeToType defaultFloatingScalar) (FloatingLiteralRequiresFloatingTarget target)
    _ -> success (scalarTypeToType defaultFloatingScalar)

-- | Apply the type rule for a unary numeric or logical operator.
unaryNumericRule :: UnaryOperator -> Type -> NumericRuleResult
unaryNumericRule operator operandType = case operator of
    LogicalNot
        | acceptsBooleanContext operandType -> success boolType
        | otherwise -> failure boolType (LogicalRequiresBooleanContext operator operandType)
    BitwiseNot
        | isIntegerType operandType -> success operandType
        | otherwise -> failure operandType (UnaryRequiresInteger operator operandType)
    UnaryPlus
        | isNumericType operandType -> success operandType
        | otherwise -> failure operandType (UnaryRequiresNumeric operator operandType)
    UnaryNegate
        | isSignedIntegerType operandType || isFloatingType operandType -> success operandType
        | otherwise -> failure operandType (NegationRequiresSignedNumeric operandType)

-- | Apply operand compatibility and result-type rules for a binary operator.
binaryNumericRule :: BinaryOperator -> Type -> Type -> NumericRuleResult
binaryNumericRule operator leftType rightType
    | operator `elem` [LogicalAnd, LogicalOr] =
        if acceptsBooleanContext leftType && acceptsBooleanContext rightType
            then success boolType
            else failure boolType (BinaryRequiresBooleanContext operator leftType rightType)
    | operator `elem` [Equal, NotEqual] =
        if leftType == rightType
            then success boolType
            else failure boolType (BinaryRequiresMatchingTypes operator leftType rightType)
    | leftType /= rightType =
        failure (resultFor operator leftType) (BinaryRequiresMatchingTypes operator leftType rightType)
    | operator `elem` [ShiftLeft, ShiftRight, BitwiseAnd, BitwiseXor, BitwiseOr] && not (isIntegerType leftType) =
        failure leftType (BinaryRequiresIntegerType operator leftType)
    | not (isNumericType leftType) =
        failure (resultFor operator leftType) (BinaryRequiresNumericType operator leftType)
    | otherwise = success (resultFor operator leftType)

-- | Test whether a type is accepted as a condition by the current language rules.
acceptsBooleanContext :: Type -> Bool
acceptsBooleanContext valueType = valueType == boolType || isNumericType valueType

resultFor :: BinaryOperator -> Type -> Type
resultFor operator operandType
    | operator `elem` [LessThan, LessEqual, GreaterThan, GreaterEqual, Equal, NotEqual] = boolType
    | operator == FloorDivide && isFloatingType operandType = intType
    | otherwise = operandType

success :: Type -> NumericRuleResult
success valueType = NumericRuleResult valueType Nothing

failure :: Type -> NumericRuleError -> NumericRuleResult
failure valueType issue = NumericRuleResult valueType (Just issue)

-- | Render a numeric rule failure as concise user-facing diagnostic text.
renderNumericRuleError :: NumericRuleError -> String
renderNumericRuleError issue = case issue of
    IntegerLiteralOutsideTarget scalar value ->
        "integer literal " ++ show value ++ " does not fit target type " ++ scalarTypeName scalar
    UntargetedIntegerOutsideInt value ->
        "un-targeted integer literal " ++ show value ++ " does not fit int; provide an explicit wider target"
    FloatingLiteralRequiresFloatingTarget target ->
        "floating-point literal cannot use non-floating target " ++ show target
    UnaryRequiresNumeric operator operand ->
        show operator ++ " requires a numeric operand, found " ++ show operand
    UnaryRequiresInteger operator operand ->
        show operator ++ " requires an integer operand, found " ++ show operand
    NegationRequiresSignedNumeric operand ->
        "unary negation requires a signed integer or floating-point operand, found " ++ show operand
    LogicalRequiresBooleanContext operator operand ->
        show operator ++ " requires bool or numeric context, found " ++ show operand
    BinaryRequiresMatchingTypes operator left right ->
        show operator ++ " requires matching operand types, found " ++ show left ++ " and " ++ show right
    BinaryRequiresNumericType operator operand ->
        show operator ++ " requires numeric operands, found " ++ show operand
    BinaryRequiresIntegerType operator operand ->
        show operator ++ " requires integer operands, found " ++ show operand
    BinaryRequiresBooleanContext operator left right ->
        show operator ++ " requires bool or numeric operands, found " ++ show left ++ " and " ++ show right
