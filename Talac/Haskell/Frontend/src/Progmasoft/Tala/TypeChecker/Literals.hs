-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | The types of literals and the range of constant expressions.

A literal takes its type from the place that receives it, and a constant
expression must fit the type it is stored in. Both are rules of
"Progmasoft.Tala.NumericSemantics" applied at a source position; the checker
of expressions calls them and adds what they report.
-}
module Progmasoft.Tala.TypeChecker.Literals
    ( literalTypeInContext
    , integerLiteralType
    , floatingLiteralType
    , ruleProblems
    , constantRangeProblems
    , problem
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.ConstantEvaluation
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.NumericSemantics

-- | The type of a literal at a place that expects the given type, if any.
literalTypeInContext :: SourceSpan -> Maybe Type -> Literal -> (Type, [Diagnostic])
literalTypeInContext spanValue expected literal = case literal of
    IntegerLiteral value -> integerLiteralType spanValue expected value
    FloatingLiteral _ -> floatingLiteralType expected
    CharacterLiteral _ -> (scalarTypeToType CharacterScalar, [])
    BooleanLiteral _ -> (boolType, [])
    StringLiteral _ -> (stringType, [])
    UnitLiteral -> (unitType, [])

-- | The type of an integer literal, and the problems of a value its type cannot hold.
integerLiteralType :: SourceSpan -> Maybe Type -> Integer -> (Type, [Diagnostic])
integerLiteralType spanValue expected value =
    let context = maybe NoNumericContext targetContext expected
        rule = integerLiteralRule context value
        code = case numericRuleError rule of Just (UntargetedIntegerOutsideInt _) -> "TAT0017"; _ -> "TAT0016"
     in (numericRuleType rule, ruleProblems spanValue code rule)
    where
        targetContext target | target == boolType = BooleanNumericContext
        targetContext target = TargetNumericType target

-- | The type of a floating literal at a place that expects the given type, if any.
floatingLiteralType :: Maybe Type -> (Type, [Diagnostic])
floatingLiteralType expected =
    let context = maybe NoNumericContext TargetNumericType expected
        rule = floatingLiteralRule context
     in (numericRuleType rule, [])

-- | The diagnostic of a numeric rule that failed, with the given code.
ruleProblems :: SourceSpan -> String -> NumericRuleResult -> [Diagnostic]
ruleProblems spanValue code rule = case numericRuleError rule of
    Nothing -> []
    Just issue -> [problem spanValue code (renderNumericRuleError issue)]

-- | The problems of a constant expression whose value its target type cannot hold.
constantRangeProblems :: SourceSpan -> Type -> Expression ResolvedName Type -> [Diagnostic]
constantRangeProblems spanValue target expression = case evaluateConstantInteger expression of
    Left issue -> [problem spanValue "TAT0019" (renderConstantIntegerError issue)]
    Right (Just value) -> case typeToScalarType target of
        Just scalar
            | scalarTypeFamily scalar `elem` [SignedIntegerFamily, UnsignedIntegerFamily]
            , not (integerFits scalar value) ->
                [ problem
                    spanValue
                    "TAT0018"
                    ("constant expression result " ++ show value ++ " does not fit " ++ scalarTypeName scalar)
                ]
        _ -> []
    Right Nothing -> []

-- | An error of the type checker at a source position.
problem :: SourceSpan -> String -> String -> Diagnostic
problem spanValue code message = Diagnostic TypeCheckerStage Error code (Just spanValue) message
