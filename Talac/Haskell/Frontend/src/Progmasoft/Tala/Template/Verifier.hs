-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Structural verification for typed template declarations.

These checks defend the boundary consumed by application binding and future
declaration cloning. They intentionally do not reject multiple declarations
with one public name: constrained specialization permits that surface, and
constraint ordering will disambiguate it in a later pass.
-}
module Progmasoft.Tala.Template.Verifier
    ( TemplateVerificationError (..)
    , verifyTemplateDeclarations
    , verifyTemplateDeclaration
    , renderTemplateVerificationError
    ) where

import Progmasoft.Tala.AST

-- | Invalid declaration, parameter, default, or member invariant.
data TemplateVerificationError
    = -- | Declaration identity is reserved or non-positive.
      TemplateDeclarationHasInvalidSymbol QualifiedName SymbolId
    | -- | Parameter identity is invalid.
      TemplateParameterHasInvalidSymbol QualifiedName Identifier SymbolId
    | -- | Parameters reuse a semantic identity.
      TemplateParameterSymbolIsDuplicated QualifiedName SymbolId
    | -- | Parameters repeat a source spelling.
      TemplateParameterSpellingIsDuplicated QualifiedName Identifier
    | -- | Annotation contains ErrorType.
      TemplateParameterHasErrorType QualifiedName ResolvedName
    | -- | Parameter pack declares an unsupported default.
      TemplateParameterPackHasDefault QualifiedName ResolvedName
    | -- | Default does not match parameter kind.
      TemplateParameterDefaultCategoryMismatch QualifiedName ResolvedName
    | -- | Template-template parameter accepts no shapes.
      TemplateTemplateSignatureIsEmpty QualifiedName ResolvedName
    | -- | Member identity is reserved or non-positive.
      TemplateMemberHasInvalidSymbol QualifiedName ResolvedName
    deriving (Eq, Ord, Read, Show)

-- | Verify every open template declaration in one typed compilation unit.
verifyTemplateDeclarations :: TypedAST -> Either [TemplateVerificationError] ()
verifyTemplateDeclarations (TypedAST (SyntaxTree namespace declarations)) =
    finish (concatMap (verifyTop namespace) declarations)
    where
        verifyTop owner declaration = case declaration of
            TemplateTypeDeclaration {} -> verifyTemplateDeclarationProblems owner declaration
            _ -> []

-- | Verify a single declaration in its already-resolved owner namespace.
verifyTemplateDeclaration ::
    Maybe QualifiedName ->
    Declaration ResolvedName Type ->
    Either [TemplateVerificationError] ()
verifyTemplateDeclaration namespace declaration = case declaration of
    TemplateTypeDeclaration {} -> finish (verifyTemplateDeclarationProblems namespace declaration)
    _ -> Right ()

verifyTemplateDeclarationProblems ::
    Maybe QualifiedName ->
    Declaration ResolvedName Type ->
    [TemplateVerificationError]
verifyTemplateDeclarationProblems namespace declaration@TemplateTypeDeclaration {} =
    declarationSymbolProblems
        ++ concatMap (parameterProblems declarationNameValue) parameters
        ++ duplicateSymbolProblems declarationNameValue parameters
        ++ duplicateSpellingProblems declarationNameValue parameters
        ++ concatMap (memberProblems declarationNameValue) (typeMembers declaration)
    where
        declarationNameValue = qualify namespace (resolvedSpelling (declarationName declaration))
        parameters = declarationTemplateParameters declaration
        declarationSymbolProblems =
            [ TemplateDeclarationHasInvalidSymbol declarationNameValue (resolvedSymbol (declarationName declaration))
            | symbolIdValue (resolvedSymbol (declarationName declaration)) <= 0
            ]
verifyTemplateDeclarationProblems _ _ = []

parameterProblems ::
    QualifiedName ->
    TemplateParameter ResolvedName Type ->
    [TemplateVerificationError]
parameterProblems owner parameter =
    invalidSymbol
        ++ errorType
        ++ packDefault
        ++ categoryDefault
        ++ shapeProblems
    where
        name = templateParameterName parameter
        invalidSymbol =
            [ TemplateParameterHasInvalidSymbol owner (resolvedSpelling name) (resolvedSymbol name)
            | symbolIdValue (resolvedSymbol name) <= 0
            ]
        errorType = [TemplateParameterHasErrorType owner name | templateParameterAnnotation parameter == ErrorType]
        packDefault =
            [ TemplateParameterPackHasDefault owner name
            | templateParameterIsPack parameter && templateParameterDefault parameter /= Nothing
            ]
        categoryDefault =
            [ TemplateParameterDefaultCategoryMismatch owner name
            | not (defaultMatchesKind (templateParameterKind parameter) (templateParameterDefault parameter))
            ]
        shapeProblems = case templateParameterKind parameter of
            TemplateTemplateParameter [] -> [TemplateTemplateSignatureIsEmpty owner name]
            TemplateTemplateParameter shapes -> concatMap (nestedShapeProblems owner name) shapes
            _ -> []

defaultMatchesKind :: TemplateParameterKind -> Maybe TemplateDefault -> Bool
defaultMatchesKind _ Nothing = True
defaultMatchesKind TemplateTypeParameter (Just TemplateTypeDefault {}) = True
defaultMatchesKind TemplateValueParameterKind {} (Just TemplateValueDefault {}) = True
defaultMatchesKind TemplateTemplateParameter {} (Just TemplateTypeDefault {}) = True
defaultMatchesKind _ _ = False

nestedShapeProblems :: QualifiedName -> ResolvedName -> TemplateParameterShape -> [TemplateVerificationError]
nestedShapeProblems owner name shape = case templateParameterShapeKind shape of
    TemplateTemplateParameterShape [] -> [TemplateTemplateSignatureIsEmpty owner name]
    TemplateTemplateParameterShape nested -> concatMap (nestedShapeProblems owner name) nested
    _ -> []

duplicateSymbolProblems ::
    QualifiedName ->
    [TemplateParameter ResolvedName Type] ->
    [TemplateVerificationError]
duplicateSymbolProblems owner parameters =
    [ TemplateParameterSymbolIsDuplicated owner symbol
    | symbol <- duplicates (map (resolvedSymbol . templateParameterName) parameters)
    ]

duplicateSpellingProblems ::
    QualifiedName ->
    [TemplateParameter ResolvedName Type] ->
    [TemplateVerificationError]
duplicateSpellingProblems owner parameters =
    [ TemplateParameterSpellingIsDuplicated owner spelling
    | spelling <- duplicates (map (resolvedSpelling . templateParameterName) parameters)
    ]

memberProblems :: QualifiedName -> Declaration ResolvedName Type -> [TemplateVerificationError]
memberProblems owner member =
    [ TemplateMemberHasInvalidSymbol owner (declarationName member)
    | symbolIdValue (resolvedSymbol (declarationName member)) <= 0
    ]

duplicates :: (Eq value) => [value] -> [value]
duplicates = go [] []
    where
        go _ output [] = reverse output
        go seen output (value : remaining)
            | value `elem` seen && value `notElem` output = go seen (value : output) remaining
            | otherwise = go (value : seen) output remaining

qualify :: Maybe QualifiedName -> Identifier -> QualifiedName
qualify Nothing name = QualifiedName [name]
qualify (Just (QualifiedName owner)) name = QualifiedName (owner ++ [name])

finish :: [problem] -> Either [problem] ()
finish [] = Right ()
finish problems = Left problems

-- | Render one declaration or parameter verification error.
renderTemplateVerificationError :: TemplateVerificationError -> String
renderTemplateVerificationError issue = case issue of
    TemplateDeclarationHasInvalidSymbol name symbol ->
        renderName name ++ " has invalid declaration symbol " ++ show (symbolIdValue symbol)
    TemplateParameterHasInvalidSymbol owner name symbol ->
        parameterPrefix owner name ++ " has invalid symbol " ++ show (symbolIdValue symbol)
    TemplateParameterSymbolIsDuplicated owner symbol ->
        renderName owner ++ " repeats template parameter symbol " ++ show (symbolIdValue symbol)
    TemplateParameterSpellingIsDuplicated owner name ->
        renderName owner ++ " repeats template parameter spelling " ++ identifierText name
    TemplateParameterHasErrorType owner name -> parameterPrefix owner (resolvedSpelling name) ++ " has ErrorType"
    TemplateParameterPackHasDefault owner name -> parameterPrefix owner (resolvedSpelling name) ++ " is a pack with a default"
    TemplateParameterDefaultCategoryMismatch owner name -> parameterPrefix owner (resolvedSpelling name) ++ " has a default of the wrong category"
    TemplateTemplateSignatureIsEmpty owner name -> parameterPrefix owner (resolvedSpelling name) ++ " has an empty template signature"
    TemplateMemberHasInvalidSymbol owner name -> parameterPrefix owner (resolvedSpelling name) ++ " has an invalid member symbol"

parameterPrefix :: QualifiedName -> Identifier -> String
parameterPrefix owner name = "template parameter " ++ identifierText name ++ " in " ++ renderName owner

renderName :: QualifiedName -> String
renderName (QualifiedName parts) = join (map identifierText parts)
    where
        join [] = ""
        join [value] = value
        join (value : remaining) = value ++ "." ++ join remaining
