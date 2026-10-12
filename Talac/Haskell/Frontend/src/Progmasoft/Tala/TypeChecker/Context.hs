-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | What the type checker carries from place to place, and how a type
written in source becomes a type.

The catalog is read from the whole source set before any body is checked,
so that a use may precede its declaration. The template context is the
catalog seen from one declaration: its template parameters, the type that
owns it, the type a @return@ must carry and the loops around the place
being checked. A type written in source is resolved in that context,
because the same spelling names a template parameter in one declaration and
a declared type in another.
-}
module Progmasoft.Tala.TypeChecker.Context
    ( TypeEnvironment
    , MethodCandidate (..)
    , TypeCatalog (..)
    , TemplateContext (..)
    , emptyTemplateContext
    , templateContext
    , templateParameterAsArgument
    , syntaxTypeIn
    , syntaxTemplateArgumentIn
    , syntaxTemplateValueIn
    , typeTemplateParameter
    , validateTemplateParameters
    , typeSyntaxProblemsIn
    , templateArgumentProblemsIn
    , templateValueProblemsIn
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.TemplateValue
import Progmasoft.Tala.TypeChecker.Enums
import Progmasoft.Tala.TypeChecker.Literals
import Progmasoft.Tala.TypeChecker.Loops

-- | The names in scope: each symbol with its type and whether it may be assigned.
type TypeEnvironment = [(SymbolId, (Type, Bool))]

{- | A method that a call may select, with the type that declares it.

The type checker owns a whole source-set catalog before it checks any body.
That permits calls to later-declared classes without making parsing depend
on declaration order or mutating the Renamer's lexical environment.
-}
data MethodCandidate = MethodCandidate
    { candidateOwner :: SymbolId
    , candidateDeclaration :: Declaration ResolvedName ()
    }

-- | What the checker knows of a whole source set before it checks a body.
data TypeCatalog = TypeCatalog
    { catalogTypes :: [(SymbolId, ResolvedName)]
    , catalogMethods :: [MethodCandidate]
    , catalogEnums :: [EnumInfo]
    -- ^ The classic enums of the source set.
    , catalogInferredReturns :: [((SymbolId, SourceSpan), Type)]
    {- ^ The return types inferred for the methods declared with @auto@, by
    the symbol and the place of the declaration. A method that is absent has
    no return type that is known yet.
    -}
    }

{- | The catalog as one declaration sees it.

Type syntax deliberately keeps source spellings. This side environment is
the bridge from those spellings to the SymbolIds assigned by the renamer.
Type and value parameters are separate because @T@ in a type position and
@N@ in @[T; N]@ have different semantic representations.
-}
data TemplateContext = TemplateContext
    { templateTypeNames :: [(Identifier, ResolvedName)]
    , templateValueNames :: [(Identifier, ResolvedName)]
    , templateCatalog :: TypeCatalog
    , templateCurrentType :: Maybe SymbolId
    , contextReturn :: Type
    {- ^ The type a @return@ must carry at the place being checked, or the
    error type where it is not declared. Statements know it already; it is
    kept here for the statements of a block used as a value, which are
    reached through an expression.
    -}
    , contextLoops :: LoopContext
    -- ^ The loops around the place being checked, for the same reason.
    }

-- | The context of a declaration that has no template parameters.
emptyTemplateContext :: TypeCatalog -> Maybe SymbolId -> TemplateContext
emptyTemplateContext catalog owner = TemplateContext [] [] catalog owner ErrorType outsideLoops

{- | Keep type and value parameters in separate lookup tables.
Identical source spelling in the two categories must not collapse their roles.
-}
templateContext :: TypeCatalog -> Maybe SymbolId -> [TemplateParameter ResolvedName annotation] -> TemplateContext
templateContext catalog owner parameters =
    TemplateContext
        [ (resolvedSpelling name, name)
        | parameter <- parameters
        , case templateParameterKind parameter of
            TemplateTypeParameter -> True
            TemplateTemplateParameter _ -> True
            _ -> False
        , let name = templateParameterName parameter
        ]
        [ (resolvedSpelling name, name)
        | parameter <- parameters
        , case templateParameterKind parameter of TemplateValueParameterKind _ -> True; _ -> False
        , let name = templateParameterName parameter
        ]
        catalog
        owner
        ErrorType
        outsideLoops

-- | A template parameter as the argument that stands for itself.
templateParameterAsArgument :: TemplateParameter ResolvedName annotation -> TemplateArgument
templateParameterAsArgument parameter = case templateParameterKind parameter of
    TemplateValueParameterKind _ -> ValueTemplateArgument (TemplateValueParameter (templateParameterName parameter))
    _ -> TypeTemplateArgument (TypeVariable (templateParameterName parameter))

-- | The type a type written in source denotes in a context.
syntaxTypeIn :: TemplateContext -> TypeSyntax -> Type
syntaxTypeIn _ AutoType = ErrorType
syntaxTypeIn context (QualifiedTypeSyntax name arguments) =
    case name of
        QualifiedName [identifier] | Just resolved <- lookup identifier (templateTypeNames context) -> TypeVariable resolved
        _ -> NamedType name (map (syntaxTemplateArgumentIn context) arguments)
syntaxTypeIn context (BuiltinArrayTypeSyntax element) =
    -- `[]T` is a language type, not a public class invented by the compiler.
    -- Its structural spelling keeps that distinction visible through Core
    -- until ownership-aware lowering assigns the final runtime layout.
    NamedType (QualifiedName [Identifier "[]"]) [TypeTemplateArgument (syntaxTypeIn context element)]
syntaxTypeIn context (ArrayTypeSyntax element) =
    NamedType
        (QualifiedName [Identifier "System", Identifier "Array"])
        [TypeTemplateArgument (syntaxTypeIn context element)]
syntaxTypeIn context (FixedArrayTypeSyntax element size) =
    NamedType
        (QualifiedName [Identifier "System", Identifier "Array"])
        [TypeTemplateArgument (syntaxTypeIn context element), ValueTemplateArgument (syntaxTemplateValueIn context size)]
syntaxTypeIn context (DictionaryTypeSyntax key value) =
    NamedType
        (QualifiedName [Identifier "System", Identifier "Dictionary"])
        [TypeTemplateArgument (syntaxTypeIn context key), TypeTemplateArgument (syntaxTypeIn context value)]
syntaxTypeIn context (CallableTypeSyntax parameters result) = FunctionType (map (syntaxTypeIn context) parameters) (syntaxTypeIn context result)
syntaxTypeIn context (ExplicitType identifier@(Identifier name)) = case lookup identifier (templateTypeNames context) of
    Just resolved -> TypeVariable resolved
    Nothing -> case name of
        "String" -> stringType
        "unit" -> unitType
        "void" -> voidType
        _
            | Just info <- enumBySpelling (catalogEnums (templateCatalog context)) identifier -> enumInfoType info
            | otherwise -> maybe (NamedType (QualifiedName [Identifier name]) []) scalarTypeToType (lookupScalar name)
    where
        lookupScalar spelling = lookup spelling [(scalarTypeName scalar, scalar) | scalar <- scalarTypes]

-- | The template argument a written argument denotes in a context.
syntaxTemplateArgumentIn :: TemplateContext -> TemplateArgumentSyntax -> TemplateArgument
syntaxTemplateArgumentIn context argument = case argument of
    TemplateTypeSyntax valueType -> TypeTemplateArgument (syntaxTypeIn context valueType)
    TemplateValueArgumentSyntax value -> ValueTemplateArgument (syntaxTemplateValueIn context value)

-- Parser construction guarantees the expression tree is side-effect free.
-- Exact evaluation here gives every concrete specialization one canonical
-- identity. Invalid arithmetic becomes a sentinel and is diagnosed by the
-- type-syntax validation pass before Core can be emitted.

{- | Canonicalize a template argument before it contributes to specialization identity.
The fallback value is only a recovery sentinel; validation reports the original
invalid expression before a specialization plan is emitted.
-}
syntaxTemplateValueIn :: TemplateContext -> TemplateValueSyntax -> TemplateValue
syntaxTemplateValueIn context value = case value of
    TemplateNameSyntax _ (QualifiedName [identifier])
        | Just resolved <- lookup identifier (templateValueNames context) -> TemplateValueParameter resolved
    _ -> case evaluateTemplateValue value of
        Right result -> result
        _ -> IntegerTemplateValue 0

-- | A template parameter with the type of its values.
typeTemplateParameter :: TemplateContext -> TemplateParameter ResolvedName () -> TemplateParameter ResolvedName Type
typeTemplateParameter context parameter =
    TemplateParameter
        (templateParameterSpan parameter)
        (templateParameterName parameter)
        annotation
        (templateParameterKind parameter)
        (templateParameterIsPack parameter)
        (templateParameterDefault parameter)
    where
        annotation = case templateParameterKind parameter of
            TemplateValueParameterKind valueType -> syntaxTypeIn context valueType
            _ -> TypeVariable (templateParameterName parameter)

-- | The problems of the template parameters of a declaration.
validateTemplateParameters :: TemplateContext -> [TemplateParameter ResolvedName ()] -> [Diagnostic]
validateTemplateParameters context = concatMap validate
    where
        validate parameter =
            kindProblems parameter
                ++ defaultProblems parameter
                ++ packDefaultProblems parameter
        kindProblems parameter = case templateParameterKind parameter of
            TemplateTypeParameter -> []
            TemplateValueParameterKind valueType -> typeSyntaxProblemsIn context valueType
            TemplateTemplateParameter shapes -> concatMap shapeProblems shapes
        shapeProblems shape = case templateParameterShapeKind shape of
            TemplateTypeParameterShape -> []
            TemplateValueParameterShape valueType -> typeSyntaxProblemsIn context valueType
            TemplateTemplateParameterShape shapes -> concatMap shapeProblems shapes
        defaultProblems parameter = case templateParameterDefault parameter of
            Nothing -> []
            Just (TemplateTypeDefault valueType) -> typeSyntaxProblemsIn context valueType
            Just (TemplateValueDefault value) -> templateValueProblemsIn context "TAT0020" value
        packDefaultProblems parameter
            | templateParameterIsPack parameter
            , Just _ <- templateParameterDefault parameter =
                [problem (templateParameterSpan parameter) "TAT0019" "a template parameter pack cannot have a default"]
            | otherwise = []

-- | The problems of a type written in source.
typeSyntaxProblemsIn :: TemplateContext -> TypeSyntax -> [Diagnostic]
typeSyntaxProblemsIn context syntax = case syntax of
    ExplicitType _ -> []
    AutoType -> []
    BuiltinArrayTypeSyntax element -> typeSyntaxProblemsIn context element
    ArrayTypeSyntax element -> typeSyntaxProblemsIn context element
    DictionaryTypeSyntax key value -> typeSyntaxProblemsIn context key ++ typeSyntaxProblemsIn context value
    CallableTypeSyntax parameters result -> concatMap (typeSyntaxProblemsIn context) parameters ++ typeSyntaxProblemsIn context result
    QualifiedTypeSyntax _ arguments -> concatMap (templateArgumentProblemsIn context) arguments
    FixedArrayTypeSyntax element size ->
        typeSyntaxProblemsIn context element
            ++ case syntaxTemplateValueIn context size of
                TemplateValueParameter _ -> []
                _ -> case evaluateFixedArraySize size of
                    Left issue -> [problem (templateValueSyntaxSpan size) "TAT0016" (renderTemplateValueError issue)]
                    Right _ -> []

-- | The problems of a template argument written in source.
templateArgumentProblemsIn :: TemplateContext -> TemplateArgumentSyntax -> [Diagnostic]
templateArgumentProblemsIn context argument = case argument of
    TemplateTypeSyntax valueType -> typeSyntaxProblemsIn context valueType
    TemplateValueArgumentSyntax value -> templateValueProblemsIn context "TAT0017" value

-- | The problems of a template value written in source, reported with the given code.
templateValueProblemsIn :: TemplateContext -> String -> TemplateValueSyntax -> [Diagnostic]
templateValueProblemsIn context code value = case syntaxTemplateValueIn context value of
    TemplateValueParameter _ -> []
    _ -> case evaluateTemplateValue value of
        Left issue -> [problem (templateValueSyntaxSpan value) code (renderTemplateValueError issue)]
        Right _ -> []
