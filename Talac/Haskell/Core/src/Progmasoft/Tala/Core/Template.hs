-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Template specialization identity and substitution.

Core does not instantiate declarations yet, but it must already preserve
exact specialization identity. This module is the single semantic owner for
walking ordered type/value arguments, validating their portable payloads,
and replacing parameters when monomorphization requests a concrete type.
-}
module Progmasoft.Tala.Core.Template
    ( ArrayShape (..)
    , TemplateIssue (..)
    , TemplateIssueKind (..)
    , TemplateMetrics (..)
    , classifyArrayType
    , collectTemplateParameters
    , concreteTemplateType
    , emptyTemplateMetrics
    , measureTemplateType
    , renderTemplateIdentity
    , substituteTemplateType
    , validateTemplateType
    ) where

import Data.List (intercalate, nub, sort)
import Progmasoft.Tala.AST

-- | Recognized form of the language's intrinsic or standard fixed array type.
data ArrayShape
    = -- | Legacy intrinsic array spelling with an element type.
      BuiltinArrayShape Type
    | -- | Dynamic @System.Array<T>@ form.
      DynamicArrayShape Type
    | -- | Fixed @System.Array<T, N>@ form.
      FixedArrayShape Type Integer
    deriving (Eq, Ord, Read, Show)

-- | Category of malformed template identity or unsupported type payload.
data TemplateIssueKind
    = -- | Type nesting exceeds the caller's maximum depth.
      TemplateDepthExceeded
    | -- | A named type has no name components.
      TemplateEmptyQualifiedName
    | -- | A qualified name contains an empty component.
      TemplateEmptyNamePart
    | -- | A template variable has an invalid identity or spelling.
      TemplateInvalidParameter
    | -- | Character value is not a Unicode scalar.
      TemplateInvalidCharacter
    | -- | Fixed array extent is negative.
      TemplateNegativeArraySize
    | -- | Built-in array arity or argument shape is invalid.
      TemplateMalformedArrayFamily
    deriving (Eq, Ord, Read, Show)

-- | One validation issue with the nested argument path that caused it.
data TemplateIssue = TemplateIssue
    { templateIssueKind :: TemplateIssueKind
    -- ^ Stable issue category.
    , templateIssuePath :: [Int]
    -- ^ Zero-based indices through nested type arguments.
    , templateIssueMessage :: String
    -- ^ Human-readable detail.
    }
    deriving (Eq, Ord, Read, Show)

-- | Structural counts used to estimate and bound template type complexity.
data TemplateMetrics = TemplateMetrics
    { templateTypeNodes :: Int
    -- ^ Named, function, or variable type nodes.
    , templateTypeArguments :: Int
    -- ^ Type-valued template arguments.
    , templateValueArguments :: Int
    -- ^ Compile-time value arguments.
    , templateParameterReferences :: Int
    -- ^ References to open type/value parameters.
    , templateMaximumDepth :: Int
    -- ^ Deepest nested node or argument encountered.
    }
    deriving (Eq, Ord, Read, Show)

-- | Zero-valued metric accumulator.
emptyTemplateMetrics :: TemplateMetrics
emptyTemplateMetrics = TemplateMetrics 0 0 0 0 0

-- | Recognize the built-in and System.Array type encodings.
classifyArrayType :: Type -> Maybe ArrayShape
classifyArrayType valueType = case valueType of
    NamedType (QualifiedName [Identifier "[]"]) [TypeTemplateArgument element] ->
        Just (BuiltinArrayShape element)
    NamedType
        (QualifiedName [Identifier "System", Identifier "Array"])
        [TypeTemplateArgument element] ->
            Just (DynamicArrayShape element)
    NamedType
        (QualifiedName [Identifier "System", Identifier "Array"])
        [TypeTemplateArgument element, ValueTemplateArgument (IntegerTemplateValue size)] ->
            Just (FixedArrayShape element size)
    _ -> Nothing

-- | Validate type names, open symbols, array forms, and nesting depth.
validateTemplateType :: Int -> Type -> [TemplateIssue]
validateTemplateType maximumDepth = validateType [] 0
    where
        validateType path depth valueType
            | depth > maximumDepth =
                [TemplateIssue TemplateDepthExceeded path "template type nesting exceeds the configured limit"]
            | otherwise = case valueType of
                NamedType name arguments ->
                    validateName path name
                        ++ concat
                            [ validateArgument (path ++ [index]) (depth + 1) argument
                            | (index, argument) <- zip [0 ..] arguments
                            ]
                        ++ validateArray path name arguments
                FunctionType parameters result ->
                    concat
                        [ validateType (path ++ [index]) (depth + 1) parameter
                        | (index, parameter) <- zip [0 ..] parameters
                        ]
                        ++ validateType (path ++ [length parameters]) (depth + 1) result
                TypeVariable name -> validateParameter path name
                ErrorType -> []

        validateArgument path depth argument = case argument of
            TypeTemplateArgument nested -> validateType path depth nested
            ValueTemplateArgument value -> validateValue path value

validateName :: [Int] -> QualifiedName -> [TemplateIssue]
validateName path (QualifiedName parts)
    | null parts = [TemplateIssue TemplateEmptyQualifiedName path "named type has an empty qualified name"]
    | otherwise =
        [ TemplateIssue TemplateEmptyNamePart (path ++ [index]) "named type contains an empty name component"
        | (index, Identifier part) <- zip [0 ..] parts
        , null part
        ]

validateParameter :: [Int] -> ResolvedName -> [TemplateIssue]
validateParameter path name
    | symbolIdValue (resolvedSymbol name) <= 0 =
        [TemplateIssue TemplateInvalidParameter path "template parameter SymbolId must be positive"]
    | null (identifierText (resolvedSpelling name)) =
        [TemplateIssue TemplateInvalidParameter path "template parameter spelling cannot be empty"]
    | otherwise = []

validateValue :: [Int] -> TemplateValue -> [TemplateIssue]
validateValue path value = case value of
    IntegerTemplateValue _ -> []
    BooleanTemplateValue _ -> []
    CharacterTemplateValue scalar
        | validUnicodeScalar scalar -> []
        | otherwise -> [TemplateIssue TemplateInvalidCharacter path "character template value is not a Unicode scalar"]
    TemplateValueParameter name -> validateParameter path name

validateArray :: [Int] -> QualifiedName -> [TemplateArgument] -> [TemplateIssue]
validateArray path name arguments
    | name == QualifiedName [Identifier "[]"] = case arguments of
        [TypeTemplateArgument _] -> []
        _ -> [TemplateIssue TemplateMalformedArrayFamily path "built-in [] requires exactly one type argument"]
    | name == QualifiedName [Identifier "System", Identifier "Array"] = case arguments of
        [TypeTemplateArgument _] -> []
        [TypeTemplateArgument _, ValueTemplateArgument (IntegerTemplateValue size)]
            | size < 0 -> [TemplateIssue TemplateNegativeArraySize (path ++ [1]) "fixed System.Array size cannot be negative"]
            | otherwise -> []
        [TypeTemplateArgument _, ValueTemplateArgument (TemplateValueParameter _)] -> []
        _ -> [TemplateIssue TemplateMalformedArrayFamily path "System.Array requires <T> or <T, integral size N>"]
    | otherwise = []

validUnicodeScalar :: Integer -> Bool
validUnicodeScalar scalar =
    scalar >= 0
        && scalar <= 0x10ffff
        && not (scalar >= 0xd800 && scalar <= 0xdfff)

-- | Count nested type/value arguments and open-parameter references.
measureTemplateType :: Type -> TemplateMetrics
measureTemplateType = measureType 0
    where
        measureType depth valueType = case valueType of
            NamedType _ arguments ->
                foldl addMetrics (node depth) (map (measureArgument (depth + 1)) arguments)
            FunctionType parameters result ->
                foldl addMetrics (node depth) (map (measureType (depth + 1)) (parameters ++ [result]))
            TypeVariable _ -> (node depth) {templateParameterReferences = 1}
            ErrorType -> node depth

        measureArgument depth argument = case argument of
            TypeTemplateArgument nested ->
                let metrics = measureType depth nested
                 in metrics {templateTypeArguments = templateTypeArguments metrics + 1}
            ValueTemplateArgument value ->
                emptyTemplateMetrics
                    { templateValueArguments = 1
                    , templateParameterReferences = case value of TemplateValueParameter _ -> 1; _ -> 0
                    , templateMaximumDepth = depth
                    }

        node depth = emptyTemplateMetrics {templateTypeNodes = 1, templateMaximumDepth = depth}

addMetrics :: TemplateMetrics -> TemplateMetrics -> TemplateMetrics
addMetrics left right =
    TemplateMetrics
        { templateTypeNodes = templateTypeNodes left + templateTypeNodes right
        , templateTypeArguments = templateTypeArguments left + templateTypeArguments right
        , templateValueArguments = templateValueArguments left + templateValueArguments right
        , templateParameterReferences = templateParameterReferences left + templateParameterReferences right
        , templateMaximumDepth = max (templateMaximumDepth left) (templateMaximumDepth right)
        }

-- | Collect distinct open type and value parameter identities in sorted order.
collectTemplateParameters :: Type -> [SymbolId]
collectTemplateParameters = sort . nub . collectType
    where
        collectType valueType = case valueType of
            NamedType _ arguments -> concatMap collectArgument arguments
            FunctionType parameters result -> concatMap collectType (parameters ++ [result])
            TypeVariable name -> [resolvedSymbol name]
            ErrorType -> []
        collectArgument argument = case argument of
            TypeTemplateArgument nested -> collectType nested
            ValueTemplateArgument (TemplateValueParameter name) -> [resolvedSymbol name]
            ValueTemplateArgument _ -> []

-- | Test whether no type or value parameter remains anywhere in the type.
concreteTemplateType :: Type -> Bool
concreteTemplateType = null . collectTemplateParameters

-- | Replace open type/value parameters recursively using explicit bindings.
substituteTemplateType :: [(SymbolId, Type)] -> [(SymbolId, TemplateValue)] -> Type -> Type
substituteTemplateType typeBindings valueBindings = substituteType
    where
        substituteType valueType = case valueType of
            NamedType name arguments -> NamedType name (map substituteArgument arguments)
            FunctionType parameters result -> FunctionType (map substituteType parameters) (substituteType result)
            TypeVariable name -> maybe valueType id (lookup (resolvedSymbol name) typeBindings)
            ErrorType -> ErrorType
        substituteArgument argument = case argument of
            TypeTemplateArgument nested -> TypeTemplateArgument (substituteType nested)
            ValueTemplateArgument (TemplateValueParameter name) ->
                ValueTemplateArgument (maybe (TemplateValueParameter name) id (lookup (resolvedSymbol name) valueBindings))
            ValueTemplateArgument value -> ValueTemplateArgument value

-- | Render a deterministic, length-delimited identity for a template type.
renderTemplateIdentity :: Type -> String
renderTemplateIdentity valueType = case valueType of
    NamedType name arguments -> renderName name ++ renderArguments arguments
    FunctionType parameters result ->
        "fn(" ++ intercalate "," (map renderTemplateIdentity parameters) ++ ")->" ++ renderTemplateIdentity result
    TypeVariable name -> "type$" ++ renderSymbol name
    ErrorType -> "<error>"

renderArguments :: [TemplateArgument] -> String
renderArguments [] = ""
renderArguments arguments = "<" ++ intercalate "," (map renderArgument arguments) ++ ">"

renderArgument :: TemplateArgument -> String
renderArgument argument = case argument of
    TypeTemplateArgument nested -> "type:" ++ renderTemplateIdentity nested
    ValueTemplateArgument value -> "value:" ++ renderValue value

renderValue :: TemplateValue -> String
renderValue value = case value of
    IntegerTemplateValue integer -> "i:" ++ show integer
    BooleanTemplateValue boolean -> "b:" ++ if boolean then "true" else "false"
    CharacterTemplateValue scalar -> "c:" ++ show scalar
    TemplateValueParameter name -> "parameter$" ++ renderSymbol name

renderName :: QualifiedName -> String
renderName (QualifiedName parts) = intercalate "." (map renderPart parts)
    where
        -- Length-prefixing keeps dots and angle brackets in a future expanded
        -- identifier alphabet from making two structural identities collide.
        renderPart (Identifier part) = show (length part) ++ ":" ++ part

renderSymbol :: ResolvedName -> String
renderSymbol name =
    show (symbolIdValue (resolvedSymbol name))
        ++ ":"
        ++ show (length spelling)
        ++ ":"
        ++ spelling
    where
        spelling = identifierText (resolvedSpelling name)
