-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Lossless discovery of concrete template occurrences in Core.

Discovery does not decide whether two occurrences need separate generated
code.  It records every semantic site, while the planning layer canonicalizes
types through @SpecializationCatalog@. Keeping those jobs separate makes the
source-to-Core boundary testable without depending on queue implementation.
-}
module Progmasoft.Tala.Core.Monomorphization.Discovery
    ( TypeOccurrence (..)
    , directTypeDependencies
    , discoverTypeOccurrences
    , specializationCandidate
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Monomorphization.Types

-- | One specialization candidate together with its exact semantic Core path.
data TypeOccurrence = TypeOccurrence
    { occurrenceType :: Type
    , occurrenceLocation :: DemandLocation
    }
    deriving (Eq, Ord, Read, Show)

{- | A named type without arguments is nominal but not a specialization demand.
Function types are containers whose parameter/result types are visited
independently.  This rule avoids manufacturing a runtime generic dictionary
demand for the callable itself.
-}
specializationCandidate :: Type -> Bool
specializationCandidate valueType = case valueType of
    NamedType _ arguments -> not (null arguments)
    FunctionType _ _ -> False
    TypeVariable _ -> False
    ErrorType -> False

-- | Collect specialization candidates from signatures and nested Core nodes.
discoverTypeOccurrences :: CoreModule -> [TypeOccurrence]
discoverTypeOccurrences coreModule = concatMap discoverFunction (coreModuleFunctions coreModule)

discoverFunction :: CoreFunction -> [TypeOccurrence]
discoverFunction function =
    concat
        [ discoverTypeAt
            (location [FunctionParameterPath index])
            parameterType
        | (index, (_, parameterType)) <- zip [0 ..] (coreFunctionParameters function)
        ]
        ++ discoverTypeAt (location [FunctionReturnPath]) (coreFunctionReturnType function)
        ++ discoverStatements (location []) (coreFunctionBody function)
    where
        location path = DemandLocation (coreFunctionName function) path

discoverStatements :: DemandLocation -> [CoreStatement] -> [TypeOccurrence]
discoverStatements parent statements =
    concat
        [ discoverStatement (appendPath parent (StatementPath index)) statement
        | (index, statement) <- zip [0 ..] statements
        ]

discoverStatement :: DemandLocation -> CoreStatement -> [TypeOccurrence]
discoverStatement location statement = case statement of
    CoreBind binding ->
        discoverTypeAt (appendPath location BindingTypePath) (coreBindingType binding)
            ++ discoverExpression (appendPath location BindingValuePath) (coreBindingValue binding)
    CoreAssign _ value -> discoverExpression (appendPath location AssignmentValuePath) value
    CoreReturn value -> discoverExpression (appendPath location ReturnValuePath) value
    CoreIf condition trueBranch falseBranch ->
        discoverExpression (appendPath location ConditionPath) condition
            ++ discoverStatements (appendPath location TrueBranchPath) trueBranch
            ++ discoverStatements (appendPath location FalseBranchPath) falseBranch
    CoreWhile condition body ->
        discoverExpression (appendPath location ConditionPath) condition
            ++ discoverStatements (appendPath location LoopBodyPath) body
    CoreDoWhile body condition ->
        discoverStatements (appendPath location LoopBodyPath) body
            ++ discoverExpression (appendPath location ConditionPath) condition
    CoreFor condition body update ->
        discoverExpression (appendPath location ConditionPath) condition
            ++ discoverStatements (appendPath location LoopBodyPath) body
            ++ discoverStatements (appendPath location LoopUpdatePath) update
    CoreEvaluate value -> discoverExpression (appendPath location EvaluatedValuePath) value
    CoreBreak -> []
    CoreContinue -> []

discoverExpression :: DemandLocation -> CoreExpression -> [TypeOccurrence]
discoverExpression location expression =
    discoverTypeAt (appendPath location ExpressionResultPath) (expressionType expression)
        ++ case expression of
            CoreVariable _ _ -> []
            CoreLiteral _ _ -> []
            CoreApply callee arguments _ ->
                discoverExpression (appendPath location CalleePath) callee
                    ++ concat
                        [ discoverExpression (appendPath location (ArgumentPath index)) argument
                        | (index, argument) <- zip [0 ..] arguments
                        ]
            CorePrimitive _ operands _ ->
                concat
                    [ discoverExpression (appendPath location (PrimitiveOperandPath index)) operand
                    | (index, operand) <- zip [0 ..] operands
                    ]
            CoreLet _ bindingType value body _ ->
                discoverTypeAt (appendPath location BindingTypePath) bindingType
                    ++ discoverExpression (appendPath location BindingValuePath) value
                    ++ discoverExpression (appendPath location EvaluatedValuePath) body
            CoreConditional condition whenTrue whenFalse _ ->
                discoverExpression (appendPath location ConditionPath) condition
                    ++ discoverExpression (appendPath location TrueBranchPath) whenTrue
                    ++ discoverExpression (appendPath location FalseBranchPath) whenFalse
            CoreClosure captures parameters returnType body _ ->
                concat
                    [ discoverCapture (appendPath location (ClosureCapturePath index)) capture
                    | (index, capture) <- zip [0 ..] captures
                    ]
                    ++ concat
                        [ discoverTypeAt
                            (appendPath location (ClosureParameterPath index))
                            parameterType
                        | (index, (_, parameterType)) <- zip [0 ..] parameters
                        ]
                    ++ discoverTypeAt (appendPath location ClosureReturnPath) returnType
                    ++ discoverStatements (appendPath location ClosureBodyPath) body

discoverCapture :: DemandLocation -> CoreCapture -> [TypeOccurrence]
discoverCapture location capture =
    discoverTypeAt (appendPath location ClosureCaptureTypePath) (coreCaptureType capture)
        ++ discoverExpression (appendPath location ClosureCaptureValuePath) (coreCaptureValue capture)

{- | Visit a complete type tree because nested callable signatures may contain
specialization roots even when the outer type is not itself parameterized.
Nested template arguments are not emitted here: they become dependency
demands while processing the parent's queue entry.  This preserves a useful
parent edge instead of flattening every type into unrelated roots.
-}
discoverTypeAt :: DemandLocation -> Type -> [TypeOccurrence]
discoverTypeAt location valueType
    | specializationCandidate valueType = [TypeOccurrence valueType location]
    | otherwise = case valueType of
        FunctionType parameters result ->
            concat
                [ discoverTypeAt
                    (appendPath location (ClosureParameterPath index))
                    parameterType
                | (index, parameterType) <- zip [0 ..] parameters
                ]
                ++ discoverTypeAt (appendPath location ClosureReturnPath) result
        _ -> []

{- | Immediate specialization dependencies retain argument indexes.  Deeper
nodes are discovered when the immediate child is processed, giving traces a
bounded and intelligible chain.
-}
directTypeDependencies :: Type -> [(Int, Type)]
directTypeDependencies valueType = case valueType of
    NamedType _ arguments -> concatMap dependencyAt (zip [0 ..] arguments)
    FunctionType parameters result ->
        concatMap dependencyAtType (zip [0 ..] (parameters ++ [result]))
    TypeVariable _ -> []
    ErrorType -> []
    where
        dependencyAt (index, argument) = case argument of
            TypeTemplateArgument nested ->
                if specializationCandidate nested
                    then [(index, nested)]
                    else [(childIndex, child) | (childIndex, child) <- directTypeDependencies nested]
            ValueTemplateArgument _ -> []
        dependencyAtType (index, nested)
            | specializationCandidate nested = [(index, nested)]
            | otherwise = [(childIndex, child) | (childIndex, child) <- directTypeDependencies nested]

appendPath :: DemandLocation -> DemandPathStep -> DemandLocation
appendPath location step = location {demandLocationPath = demandLocationPath location ++ [step]}
