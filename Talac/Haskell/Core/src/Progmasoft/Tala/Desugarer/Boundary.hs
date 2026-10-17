-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | What crosses from the Typed AST into Core without the lowering state:
types, literals, patterns, type identities and the source catalog. Each is a
translation of one typed piece into its Core counterpart.
-}
module Progmasoft.Tala.Desugarer.Boundary
    ( callableFinalType
    , canonicalTypeName
    , declarationSourceFiles
    , expressionAnnotation
    , functionSources
    , lowerBoundaryType
    , lowerLiteral
    , lowerPattern
    , lowerRelationalPattern
    , lowerTemplateArgument
    , portableSourcePath
    , portableSpanSource
    , scalarType
    , typeIdentity
    ) where

import Data.Bits (xor)
import Data.Char (ord)
import Data.Word (Word64)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Scalar (isCoreNumericType)
import Progmasoft.Tala.RuntimeCall (RuntimeFunction (TextEquals), runtimeFunctionIdentity)

-- | Whether a lowered type is one whose values are computed by need.
scalarType :: Type -> Bool
scalarType lowered = lowered == boolType || isCoreNumericType lowered

{- | The source files of a declaration and of its members. The physical file
catalog is kept even for a declaration that does not yet lower to executable
code: the driver uses it to produce stable, one-source-per-artifact output
names after optimization has removed dead functions.
-}
declarationSourceFiles :: Declaration name annotation -> [FilePath]
declarationSourceFiles declaration = case declaration of
    FunctionDeclaration {} -> [portableSpanSource declaration]
    TypeDeclaration {typeMembers = members} ->
        portableSpanSource declaration : concatMap declarationSourceFiles members
    TemplateTypeDeclaration {typeMembers = members} ->
        portableSpanSource declaration : concatMap declarationSourceFiles members
    EnumDeclaration {} -> [portableSpanSource declaration]

{- | A source path with portable separators. Artifact paths always use them,
even when discovery ran on Windows, because these names become stable wire
and output identities.
-}
portableSourcePath :: FilePath -> FilePath
portableSourcePath = map (\character -> if character == '\\' then '/' else character)

-- | The portable path of the file a declaration is written in.
portableSpanSource :: Declaration name annotation -> FilePath
portableSpanSource = portableSourcePath . sourceFile . declarationSpan

-- | The symbol of each function of the declarations, with its portable source path.
functionSources :: [Declaration ResolvedName Type] -> [(Int, FilePath)]
functionSources = concatMap declarationFunctionSources
    where
        declarationFunctionSources declaration = case declaration of
            FunctionDeclaration {} -> owner declaration
            TypeDeclaration {typeMembers = members} -> concatMap declarationFunctionSources members
            TemplateTypeDeclaration {typeMembers = members} -> concatMap declarationFunctionSources members
            EnumDeclaration {} -> []
        owner declaration =
            [
                ( symbolIdValue (resolvedSymbol (declarationName declaration))
                , portableSpanSource declaration
                )
            ]

-- | The type of the final expression of a callable body, when it ends in one.
callableFinalType :: Block ResolvedName Type -> Maybe Type
callableFinalType (Block statements) = case reverse statements of
    ExpressionStatement _ expression False : _ -> Just (expressionAnnotation expression)
    _ -> Nothing

-- | The type the checker annotated an expression with.
expressionAnnotation :: Expression name Type -> Type
expressionAnnotation expression = case expression of
    NameExpression _ _ valueType -> valueType
    LiteralExpression _ _ valueType -> valueType
    MemberAccessExpression _ _ _ valueType -> valueType
    MethodReferenceExpression _ _ _ valueType -> valueType
    CallExpression _ _ _ valueType -> valueType
    UnaryExpression _ _ _ valueType -> valueType
    BinaryExpression _ _ _ _ valueType -> valueType
    IsPatternExpression _ _ _ valueType -> valueType
    ConditionalExpression _ _ _ _ valueType -> valueType
    CoalesceExpression _ _ _ valueType -> valueType
    AssignmentExpression _ _ _ _ valueType -> valueType
    IncrementExpression _ _ _ valueType -> valueType
    LoopExpression _ _ valueType -> valueType
    BlockExpression _ _ valueType -> valueType
    MatchExpression _ _ _ valueType -> valueType
    CallableExpression _ _ _ _ _ valueType -> valueType

-- | The Boolean Core test of a pattern against a subject of the given type.
lowerPattern :: CoreExpression -> Type -> Pattern ResolvedName Type -> CoreExpression
lowerPattern subject subjectType patternValue = case patternValue of
    WildcardPattern {} -> CoreLiteral (CoreBoolean True) boolType
    NullPattern {} -> CorePrimitive CoreEqual [subject, CoreLiteral CoreNull subjectType] boolType
    -- A string is compared by the characters it holds, which the runtime
    -- decides. The equality primitive on two strings would compare the
    -- objects, and a literal is never the object of the subject.
    LiteralPattern _ literal literalType
        | literalType == stringType -> textEquals literal
    RelationalPattern _ PatternEqual literal literalType
        | literalType == stringType -> textEquals literal
    RelationalPattern _ PatternNotEqual literal literalType
        | literalType == stringType -> CorePrimitive CoreLogicalNot [textEquals literal] boolType
    LiteralPattern _ literal literalType ->
        CorePrimitive CoreEqual [subject, CoreLiteral (lowerLiteral literalType literal) literalType] boolType
    TypePattern _ _ targetType ->
        CorePrimitive
            CoreTypeIs
            [subject, CoreLiteral (CoreInteger (toInteger (typeIdentity targetType))) (namedType "uint")]
            boolType
    RelationalPattern _ operator literal literalType ->
        CorePrimitive
            (lowerRelationalPattern operator)
            [subject, CoreLiteral (lowerLiteral literalType literal) literalType]
            boolType
    NotPattern _ nested _ -> CorePrimitive CoreLogicalNot [lowerPattern subject subjectType nested] boolType
    AndPattern _ left right _ ->
        CorePrimitive CoreLogicalAnd [lowerPattern subject subjectType left, lowerPattern subject subjectType right] boolType
    OrPattern _ left right _ ->
        CorePrimitive CoreLogicalOr [lowerPattern subject subjectType left, lowerPattern subject subjectType right] boolType
    where
        textEquals literal =
            CorePrimitive
                CoreRuntimeCall
                [ CoreLiteral (CoreInteger (runtimeFunctionIdentity TextEquals)) intType
                , subject
                , CoreLiteral (lowerLiteral stringType literal) stringType
                ]
                boolType

-- | The Core primitive that compares like a relational pattern operator.
lowerRelationalPattern :: RelationalPatternOperator -> CorePrimitive
lowerRelationalPattern operator = case operator of
    PatternLessThan -> CoreLessThan
    PatternLessEqual -> CoreLessEqual
    PatternGreaterThan -> CoreGreaterThan
    PatternGreaterEqual -> CoreGreaterEqual
    PatternEqual -> CoreEqual
    PatternNotEqual -> CoreNotEqual

{- | The identity of a type in a type test. FNV-1a is specified rather than
delegated to a host hash library: native code embeds the same canonical
identity into AARC type metadata, so a pattern test remains stable across
processes and target platforms.
-}
typeIdentity :: Type -> Word64
typeIdentity = foldl step 14695981039346656037 . map (fromIntegral . ord) . canonicalTypeName
    where
        step hashValue byte = (hashValue `xor` byte) * 1099511628211

-- | The canonical spelling of a type that its identity is computed from.
canonicalTypeName :: Type -> String
canonicalTypeName valueType = case valueType of
    NamedType (QualifiedName parts) arguments ->
        joinWith "." (map identifierText parts)
            ++ if null arguments then "" else "<" ++ joinWith "," (map canonicalArgument arguments) ++ ">"
    FunctionType parameters result ->
        "(" ++ joinWith "," (map canonicalTypeName parameters) ++ ")->" ++ canonicalTypeName result
    TypeVariable name -> "$" ++ show (symbolIdValue (resolvedSymbol name))
    ErrorType -> "<error>"
    where
        canonicalArgument argument = case argument of
            TypeTemplateArgument nested -> canonicalTypeName nested
            ValueTemplateArgument value -> show value

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [value] = value
joinWith separator (value : rest) = value ++ separator ++ joinWith separator rest

-- | The Core literal of a source literal of the given type.
lowerLiteral :: Type -> Literal -> CoreLiteral
lowerLiteral valueType literal = case literal of
    IntegerLiteral value
        | valueType == boolType -> CoreBoolean (value /= 0)
        | otherwise -> CoreInteger value
    FloatingLiteral spelling -> CoreFloating spelling
    CharacterLiteral value -> CoreInteger value
    BooleanLiteral value -> CoreBoolean value
    StringLiteral value -> CoreString value
    UnitLiteral -> CoreUnit

{- | A type as it crosses from the Typed AST into Core. The frontend keeps
source @void@ separate from value-producing @unit@; the native Core contract
predates that distinction and represents no result as unit, so the erasure
happens once, here.
-}
lowerBoundaryType :: Type -> Type
lowerBoundaryType valueType
    | valueType == voidType = unitType
    | FunctionType parameters result <- valueType =
        FunctionType (map lowerBoundaryType parameters) (lowerBoundaryType result)
    -- A value of an enum is a value of its underlying integer type. An enum
    -- must not cross into Core as a named type: named types are references
    -- there, and an enum is not one.
    | Just underlying <- enumUnderlyingType valueType = underlying
    | NamedType name arguments <- valueType = NamedType name (map lowerTemplateArgument arguments)
    | otherwise = valueType

-- | A template argument as it crosses into Core.
lowerTemplateArgument :: TemplateArgument -> TemplateArgument
lowerTemplateArgument argument = case argument of
    TypeTemplateArgument valueType -> TypeTemplateArgument (lowerBoundaryType valueType)
    ValueTemplateArgument value -> ValueTemplateArgument value
