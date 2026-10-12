-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module CompileTimeParityTests (compileTimeParityTests) where

import Data.Bits (shiftL)
import Progmasoft.Tala.AST
import Progmasoft.Tala.ConstantEvaluation
import Progmasoft.Tala.TemplateValue

compileTimeParityTests :: [(String, Bool)]
compileTimeParityTests =
    [ ("constant and template evaluators agree across compile-time magnitude boundaries", boundaryBinaryParity)
    , ("constant and template evaluators agree for unary boundary operations", boundaryUnaryParity)
    , ("constant and template evaluators map arithmetic failures consistently", failureParity)
    ]

-- The front-end uses two evaluator entry points for different semantic
-- contexts. This matrix compares their externally visible values and failure
-- classes without requiring either evaluator to call the other.
boundaryBinaryParity :: Bool
boundaryBinaryParity =
    and
        [ normalizeConstant valueResultType (evaluateConstantInteger expression)
            == normalizeTemplate (evaluateTemplateValue template)
        | (operator, _) <- binaryCases
        , left <- boundaryValues
        , right <- boundaryValues
        , let valueResultType = binaryResultType operator
        , let expression = BinaryExpression testSpan operator (integerExpression left) (integerExpression right) valueResultType
        , let template = TemplateBinarySyntax testSpan operator (integerSyntax left) (integerSyntax right)
        ]
        && length binaryCases == 20

boundaryUnaryParity :: Bool
boundaryUnaryParity =
    and
        [ normalizeConstant valueResultType (evaluateConstantInteger expression)
            == normalizeTemplate (evaluateTemplateValue template)
        | (operator, valueResultType) <- unaryCases
        , value <- boundaryValues
        , let expression = UnaryExpression testSpan operator (integerExpression value) valueResultType
        , let template = TemplateUnarySyntax testSpan operator (integerSyntax value)
        ]

failureParity :: Bool
failureParity =
    and
        [ sameBinaryResult Divide 8 0 DivisionByZeroOutcome
        , sameBinaryResult FloorDivide 8 0 FloorDivisionByZeroOutcome
        , sameBinaryResult Remainder 8 0 RemainderByZeroOutcome
        , sameBinaryResult Power 2 (-1) NegativeExponentOutcome
        , sameBinaryResult Add (compileTimeLimit - 1) 1 LimitExceededOutcome
        ]
    where
        sameBinaryResult operator left right expected =
            normalizeConstant (binaryResultType operator) (evaluateConstantInteger (binaryExpression operator left right))
                == expected
                && normalizeTemplate (evaluateTemplateValue (binarySyntax operator left right)) == expected

binaryCases :: [(BinaryOperator, Type)]
binaryCases =
    [ (Add, intType)
    , (Subtract, intType)
    , (Multiply, intType)
    , (Divide, intType)
    , (FloorDivide, intType)
    , (Remainder, intType)
    , (Power, intType)
    , (ShiftLeft, intType)
    , (ShiftRight, intType)
    , (BitwiseAnd, intType)
    , (BitwiseXor, intType)
    , (BitwiseOr, intType)
    , (LessThan, boolType)
    , (LessEqual, boolType)
    , (GreaterThan, boolType)
    , (GreaterEqual, boolType)
    , (Equal, boolType)
    , (NotEqual, boolType)
    , (LogicalAnd, boolType)
    , (LogicalOr, boolType)
    ]

unaryCases :: [(UnaryOperator, Type)]
unaryCases = [(UnaryPlus, intType), (UnaryNegate, intType), (LogicalNot, boolType), (BitwiseNot, intType)]

binaryResultType :: BinaryOperator -> Type
binaryResultType operation = case operation of
    LessThan -> boolType
    LessEqual -> boolType
    GreaterThan -> boolType
    GreaterEqual -> boolType
    Equal -> boolType
    NotEqual -> boolType
    LogicalAnd -> boolType
    LogicalOr -> boolType
    _ -> intType

boundaryValues :: [Integer]
boundaryValues =
    [ negate (compileTimeLimit - 1)
    , negate (compileTimeLimit `quot` 2)
    , -2
    , -1
    , 0
    , 1
    , 2
    , compileTimeLimit `quot` 2
    , compileTimeLimit - 1
    ]

normalizeConstant :: Type -> Either ConstantIntegerError (Maybe Integer) -> NormalizedOutcome
normalizeConstant valueType result = case result of
    Right (Just value)
        | valueType == boolType -> BooleanOutcome (value /= 0)
        | otherwise -> IntegerOutcome value
    Right Nothing -> NonconstantOutcome
    Left ConstantDivisionByZero -> DivisionByZeroOutcome
    Left ConstantFloorDivisionByZero -> FloorDivisionByZeroOutcome
    Left ConstantRemainderByZero -> RemainderByZeroOutcome
    Left ConstantNegativeExponent -> NegativeExponentOutcome
    Left ConstantEvaluationLimitExceeded -> LimitExceededOutcome

normalizeTemplate :: Either TemplateValueError TemplateValue -> NormalizedOutcome
normalizeTemplate result = case result of
    Right (IntegerTemplateValue value) -> IntegerOutcome value
    Right (BooleanTemplateValue value) -> BooleanOutcome value
    Right (CharacterTemplateValue value) -> CharacterOutcome value
    Right _ -> OtherFailureOutcome
    Left TemplateValueDivisionByZero -> DivisionByZeroOutcome
    Left TemplateValueFloorDivisionByZero -> FloorDivisionByZeroOutcome
    Left TemplateValueRemainderByZero -> RemainderByZeroOutcome
    Left (TemplateValueNegativeExponent _) -> NegativeExponentOutcome
    Left TemplateValueEvaluationLimitExceeded -> LimitExceededOutcome
    Left _ -> OtherFailureOutcome

data NormalizedOutcome
    = IntegerOutcome Integer
    | BooleanOutcome Bool
    | CharacterOutcome Integer
    | DivisionByZeroOutcome
    | FloorDivisionByZeroOutcome
    | RemainderByZeroOutcome
    | NegativeExponentOutcome
    | LimitExceededOutcome
    | NonconstantOutcome
    | OtherFailureOutcome
    deriving (Eq, Ord, Read, Show)

integerExpression :: Integer -> Expression name Type
integerExpression value = LiteralExpression testSpan (IntegerLiteral value) intType

binaryExpression :: BinaryOperator -> Integer -> Integer -> Expression name Type
binaryExpression operator left right =
    BinaryExpression testSpan operator (integerExpression left) (integerExpression right) (binaryResultType operator)

integerSyntax :: Integer -> TemplateValueSyntax
integerSyntax = TemplateIntegerSyntax testSpan

binarySyntax :: BinaryOperator -> Integer -> Integer -> TemplateValueSyntax
binarySyntax operator left right = TemplateBinarySyntax testSpan operator (integerSyntax left) (integerSyntax right)

compileTimeLimit :: Integer
compileTimeLimit = 1 `shiftL` 65536

testSpan :: SourceSpan
testSpan = SourceSpan "compile-time-parity.tala" (SourcePosition 1 1) (SourcePosition 1 2)
