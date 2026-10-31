-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module TemplateVerifierTests (templateVerifierTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Template.Verifier

templateVerifierTests :: [(String, Bool)]
templateVerifierTests =
    [ ("verifier accepts a typed type template", acceptsTypeTemplate)
    , ("verifier accepts a typed value template", acceptsValueTemplate)
    , ("verifier accepts a typed template-template declaration", acceptsTemplateTemplate)
    , ("verifier accepts a parameter pack without a default", acceptsPack)
    , ("verifier accepts multiple constrained-candidate surfaces structurally", acceptsRepeatedSurface)
    , ("verifier rejects a non-positive declaration symbol", rejectsInvalidDeclarationSymbol)
    , ("verifier rejects a non-positive parameter symbol", rejectsInvalidParameterSymbol)
    , ("verifier rejects a duplicated parameter symbol", rejectsDuplicateParameterSymbol)
    , ("verifier rejects a duplicated parameter spelling", rejectsDuplicateParameterSpelling)
    , ("verifier rejects ErrorType parameter annotations", rejectsErrorType)
    , ("verifier rejects defaults attached to packs", rejectsPackDefault)
    , ("verifier rejects a type default on a value parameter", rejectsValueCategoryMismatch)
    , ("verifier rejects a value default on a type parameter", rejectsTypeCategoryMismatch)
    , ("verifier rejects an empty template-template signature", rejectsEmptyTemplateSignature)
    , ("verifier rejects an empty nested template signature", rejectsEmptyNestedSignature)
    , ("verifier rejects a member with a non-positive symbol", rejectsInvalidMemberSymbol)
    , ("verifier ignores ordinary declarations", ignoresOrdinaryDeclaration)
    , ("verifier renders declaration symbol failures", rendersDeclarationFailure)
    , ("verifier renders duplicate spelling failures", rendersDuplicateSpelling)
    , ("verifier renders pack default failures", rendersPackDefault)
    ]

typedTree :: String -> Maybe TypedAST
typedTree source = case analyzeSemantics (CompilerInput "verifier-test.tala" source) of
    Right artifacts -> Just (semanticTypedAST artifacts)
    Left _ -> Nothing

verifySource :: String -> Bool
verifySource source = case typedTree source of Just tree -> verifyTemplateDeclarations tree == Right (); Nothing -> False

acceptsTypeTemplate :: Bool
acceptsTypeTemplate = verifySource "template<typename T> class Box {}"

acceptsValueTemplate :: Bool
acceptsValueTemplate = verifySource "template<int N> class Buffer {}"

acceptsTemplateTemplate :: Bool
acceptsTemplateTemplate = verifySource "template<template<typename> class C> class Wrapper {}"

acceptsPack :: Bool
acceptsPack = verifySource "template<typename... T> class Tuple {}"

acceptsRepeatedSurface :: Bool
acceptsRepeatedSurface =
    let first = templateDeclaration 1 [typeParameter 2 "T"] []
        second = templateDeclaration 3 [typeParameter 4 "U"] []
     in verifyTemplateDeclarations (TypedAST (SyntaxTree Nothing [first, second])) == Right ()

position :: SourcePosition
position = SourcePosition 1 1

spanValue :: SourceSpan
spanValue = SourceSpan "synthetic-template.tala" position position

resolved :: Int -> String -> ResolvedName
resolved value spelling = ResolvedName (SymbolId value) (Identifier spelling)

parameter ::
    Int -> String -> Type -> TemplateParameterKind -> Bool -> Maybe TemplateDefault -> TemplateParameter ResolvedName Type
parameter symbol spelling annotation kind packed defaultValue =
    TemplateParameter spanValue (resolved symbol spelling) annotation kind packed defaultValue

templateDeclaration ::
    Int -> [TemplateParameter ResolvedName Type] -> [Declaration ResolvedName Type] -> Declaration ResolvedName Type
templateDeclaration symbol parameters members =
    TemplateTypeDeclaration spanValue (resolved symbol "Box") (namedType "Box") parameters members

verifySynthetic :: Declaration ResolvedName Type -> Either [TemplateVerificationError] ()
verifySynthetic declaration = verifyTemplateDeclarations (TypedAST (SyntaxTree Nothing [declaration]))

hasProblem :: (TemplateVerificationError -> Bool) -> Either [TemplateVerificationError] () -> Bool
hasProblem predicate result = case result of Left problems -> any predicate problems; Right () -> False

rejectsInvalidDeclarationSymbol :: Bool
rejectsInvalidDeclarationSymbol = hasProblem isExpected (verifySynthetic (templateDeclaration 0 [] []))
    where
        isExpected TemplateDeclarationHasInvalidSymbol {} = True; isExpected _ = False

rejectsInvalidParameterSymbol :: Bool
rejectsInvalidParameterSymbol = hasProblem isExpected (verifySynthetic declaration)
    where
        declaration = templateDeclaration 1 [parameter 0 "T" (TypeVariable (resolved 0 "T")) TemplateTypeParameter False Nothing] []
        isExpected TemplateParameterHasInvalidSymbol {} = True
        isExpected _ = False

rejectsDuplicateParameterSymbol :: Bool
rejectsDuplicateParameterSymbol = hasProblem isExpected (verifySynthetic declaration)
    where
        declaration = templateDeclaration 1 [typeParameter 2 "T", typeParameter 2 "U"] []
        isExpected TemplateParameterSymbolIsDuplicated {} = True
        isExpected _ = False

rejectsDuplicateParameterSpelling :: Bool
rejectsDuplicateParameterSpelling = hasProblem isExpected (verifySynthetic declaration)
    where
        declaration = templateDeclaration 1 [typeParameter 2 "T", typeParameter 3 "T"] []
        isExpected TemplateParameterSpellingIsDuplicated {} = True
        isExpected _ = False

typeParameter :: Int -> String -> TemplateParameter ResolvedName Type
typeParameter symbol spelling = parameter symbol spelling (TypeVariable (resolved symbol spelling)) TemplateTypeParameter False Nothing

rejectsErrorType :: Bool
rejectsErrorType = hasProblem isExpected (verifySynthetic declaration)
    where
        declaration = templateDeclaration 1 [parameter 2 "T" ErrorType TemplateTypeParameter False Nothing] []
        isExpected TemplateParameterHasErrorType {} = True
        isExpected _ = False

rejectsPackDefault :: Bool
rejectsPackDefault = hasProblem isExpected (verifySynthetic declaration)
    where
        declaration =
            templateDeclaration
                1
                [ parameter
                    2
                    "T"
                    (TypeVariable (resolved 2 "T"))
                    TemplateTypeParameter
                    True
                    (Just (TemplateTypeDefault (ExplicitType (Identifier "int"))))
                ]
                []
        isExpected TemplateParameterPackHasDefault {} = True
        isExpected _ = False

rejectsValueCategoryMismatch :: Bool
rejectsValueCategoryMismatch = hasProblem isExpected (verifySynthetic declaration)
    where
        declaration =
            templateDeclaration
                1
                [ parameter
                    2
                    "N"
                    intType
                    (TemplateValueParameterKind (ExplicitType (Identifier "int")))
                    False
                    (Just (TemplateTypeDefault (ExplicitType (Identifier "int"))))
                ]
                []
        isExpected TemplateParameterDefaultCategoryMismatch {} = True
        isExpected _ = False

rejectsTypeCategoryMismatch :: Bool
rejectsTypeCategoryMismatch = hasProblem isExpected (verifySynthetic declaration)
    where
        valueDefault = TemplateValueDefault (TemplateIntegerSyntax spanValue 1)
        declaration =
            templateDeclaration
                1
                [parameter 2 "T" (TypeVariable (resolved 2 "T")) TemplateTypeParameter False (Just valueDefault)]
                []
        isExpected TemplateParameterDefaultCategoryMismatch {} = True
        isExpected _ = False

rejectsEmptyTemplateSignature :: Bool
rejectsEmptyTemplateSignature = hasProblem isExpected (verifySynthetic declaration)
    where
        declaration =
            templateDeclaration 1 [parameter 2 "C" (TypeVariable (resolved 2 "C")) (TemplateTemplateParameter []) False Nothing] []
        isExpected TemplateTemplateSignatureIsEmpty {} = True
        isExpected _ = False

rejectsEmptyNestedSignature :: Bool
rejectsEmptyNestedSignature = hasProblem isExpected (verifySynthetic declaration)
    where
        shape = TemplateParameterShape (TemplateTemplateParameterShape []) False
        declaration =
            templateDeclaration
                1
                [parameter 2 "C" (TypeVariable (resolved 2 "C")) (TemplateTemplateParameter [shape]) False Nothing]
                []
        isExpected TemplateTemplateSignatureIsEmpty {} = True
        isExpected _ = False

rejectsInvalidMemberSymbol :: Bool
rejectsInvalidMemberSymbol = hasProblem isExpected (verifySynthetic declaration)
    where
        member =
            FunctionDeclaration
                spanValue
                (resolved 0 "Read")
                (FunctionType [] intType)
                (ExplicitType (Identifier "int"))
                []
                (Block [ReturnStatement spanValue (Just (LiteralExpression spanValue (IntegerLiteral 1) intType))])
                False
                DefaultAccess
                Nothing
        declaration = templateDeclaration 1 [typeParameter 2 "T"] [member]
        isExpected TemplateMemberHasInvalidSymbol {} = True
        isExpected _ = False

ignoresOrdinaryDeclaration :: Bool
ignoresOrdinaryDeclaration = verifySynthetic (TypeDeclaration spanValue (resolved 0 "Ordinary") ErrorType []) == Right ()

rendersDeclarationFailure :: Bool
rendersDeclarationFailure =
    renderTemplateVerificationError (TemplateDeclarationHasInvalidSymbol (QualifiedName [Identifier "Box"]) (SymbolId 0))
        == "Box has invalid declaration symbol 0"

rendersDuplicateSpelling :: Bool
rendersDuplicateSpelling =
    renderTemplateVerificationError
        (TemplateParameterSpellingIsDuplicated (QualifiedName [Identifier "Box"]) (Identifier "T"))
        == "Box repeats template parameter spelling T"

rendersPackDefault :: Bool
rendersPackDefault =
    renderTemplateVerificationError (TemplateParameterPackHasDefault (QualifiedName [Identifier "Box"]) (resolved 2 "T"))
        == "template parameter T in Box is a pack with a default"
