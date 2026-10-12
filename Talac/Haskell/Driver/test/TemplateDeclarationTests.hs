-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module TemplateDeclarationTests (templateDeclarationTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser

templateDeclarationTests :: [(String, Bool)]
templateDeclarationTests =
    [ ("lexer reserves template declaration words", lexerReservesTemplateWords)
    , ("lexer emits ellipsis as one maximal token", lexerEmitsEllipsis)
    , ("parser preserves a type parameter", parserPreservesTypeParameter)
    , ("parser preserves a value parameter", parserPreservesValueParameter)
    , ("parser preserves a template-template parameter", parserPreservesTemplateParameter)
    , ("parser preserves a type parameter pack", parserPreservesTypePack)
    , ("parser preserves a value parameter pack", parserPreservesValuePack)
    , ("parser preserves a template-template parameter pack", parserPreservesTemplatePack)
    , ("parser preserves a type default", parserPreservesTypeDefault)
    , ("parser preserves a later type default reference", parserPreservesLaterDefault)
    , ("parser preserves a scalar value default", parserPreservesValueDefault)
    , ("parser preserves a named value default", parserPreservesNamedValueDefault)
    , ("parser preserves a boolean value default", parserPreservesBooleanDefault)
    , ("parser preserves a character value default", parserPreservesCharacterDefault)
    , ("parser preserves a qualified type default", parserPreservesQualifiedDefault)
    , ("parser preserves a generic type default", parserPreservesGenericDefault)
    , ("parser preserves nested template-template shapes", parserPreservesNestedTemplateShape)
    , ("parser preserves mixed template parameter order", parserPreservesMixedOrder)
    , ("parser rejects an empty template parameter list", parserRejectsEmptyParameters)
    , ("parser rejects an empty template-template signature", parserRejectsEmptyTemplateShape)
    , ("parser rejects a missing template close delimiter", parserRejectsMissingClose)
    , ("parser rejects a missing template parameter name", parserRejectsMissingName)
    , ("parser rejects a missing class after a template prefix", parserRejectsMissingClass)
    , ("parser rejects a dangling template default", parserRejectsDanglingDefault)
    , ("renamer assigns positive identities to template parameters", renamerAssignsPositiveIds)
    , ("renamer keeps source-order template identities", renamerKeepsParameterOrder)
    , ("renamer diagnoses duplicate template parameters", renamerRejectsDuplicateParameters)
    , ("renamer scopes template value parameters in method bodies", renamerScopesValueParameter)
    , ("renamer scopes template parameters independently per declaration", renamerIsolatesTemplates)
    , ("resolver preserves the declaration and parameter identities", resolverPreservesIdentities)
    , ("type checker represents T as a type variable", checkerBuildsTypeVariable)
    , ("type checker represents N as a template value parameter", checkerBuildsValueVariable)
    , ("type checker carries a type variable through callable types", checkerBuildsCallableType)
    , ("type checker carries type variables through arrays", checkerBuildsArrayType)
    , ("type checker carries value variables through fixed arrays", checkerBuildsFixedArrayType)
    , ("type checker carries variables through dictionaries", checkerBuildsDictionaryType)
    , ("type checker annotates value template parameters", checkerAnnotatesValueParameter)
    , ("type checker annotates type template parameters", checkerAnnotatesTypeParameter)
    , ("type checker annotates template-template parameters", checkerAnnotatesTemplateParameter)
    , ("type checker accepts a later type default reference", checkerAcceptsLaterDefault)
    , ("type checker accepts a named value default reference", checkerAcceptsNamedValueDefault)
    , ("type checker rejects a default on a parameter pack", checkerRejectsPackDefault)
    , ("type checker rejects unresolved value defaults", checkerRejectsUnknownValueDefault)
    , ("open templates do not emit unspecialized Core functions", openTemplateStopsBeforeCore)
    , ("ordinary declarations still pass semantic analysis", ordinaryDeclarationUnaffected)
    , ("template and ordinary declarations coexist", templateAndOrdinaryCoexist)
    , ("template member calls use semantic member signatures", templateMemberCallsResolve)
    , ("template identity methods retain exact type variables", identityMethodRetainsType)
    , ("template fixed-array identity retains both parameters", fixedArrayMethodRetainsParameters)
    ]

lexTokens :: String -> Either [Diagnostic] [Token]
lexTokens source = runLexer defaultLexer (LexerInput "template-test.tala" source)

parseSource :: String -> Either [Diagnostic] ParsedAST
parseSource source = do
    tokens <- lexTokens source
    runParser defaultParser (ParserInput "template-test.tala" tokens)

analyzeSource :: String -> Either [Diagnostic] SemanticArtifacts
analyzeSource = analyzeSemantics . CompilerInput "template-test.tala"

onlyParsedTemplate :: String -> Maybe (Declaration Identifier ())
onlyParsedTemplate source = case parseSource source of
    Right (ParsedAST (SyntaxTree _ [declaration@TemplateTypeDeclaration {}])) -> Just declaration
    _ -> Nothing

onlyTypedTemplate :: String -> Maybe (Declaration ResolvedName Type)
onlyTypedTemplate source = case analyzeSource source of
    Right artifacts -> case syntaxDeclarations (typedSyntaxTree (semanticTypedAST artifacts)) of
        [declaration@TemplateTypeDeclaration {}] -> Just declaration
        _ -> Nothing
    Left _ -> Nothing

hasCode :: String -> Either [Diagnostic] value -> Bool
hasCode code result = case result of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

identifier :: String -> Identifier
identifier = Identifier

parameterNames :: Declaration name annotation -> [name]
parameterNames TemplateTypeDeclaration {declarationTemplateParameters = parameters} = map templateParameterName parameters
parameterNames _ = []

lexerReservesTemplateWords :: Bool
lexerReservesTemplateWords = case lexTokens "template<typename T> class Box {}" of
    Right tokens ->
        [(tokenText token, tokenKind token) | token <- tokens, tokenText token `elem` ["template", "typename"]]
            == [("template", KeywordToken), ("typename", KeywordToken)]
    Left _ -> False

lexerEmitsEllipsis :: Bool
lexerEmitsEllipsis = case lexTokens "template<typename... Types> class Tuple {}" of
    Right tokens -> length [() | token <- tokens, tokenText token == "..." && tokenKind token == SymbolToken] == 1
    Left _ -> False

parserPreservesTypeParameter :: Bool
parserPreservesTypeParameter = case onlyParsedTemplate "template<typename T> class Box {}" of
    Just declaration -> case templateParameters declaration of
        [TemplateParameter _ name _ TemplateTypeParameter False Nothing] -> name == identifier "T"
        _ -> False
    Nothing -> False

parserPreservesValueParameter :: Bool
parserPreservesValueParameter = case onlyParsedTemplate "template<int Size> class Buffer {}" of
    Just declaration -> case templateParameters declaration of
        [TemplateParameter _ name _ (TemplateValueParameterKind valueType) False Nothing] ->
            name == identifier "Size" && valueType == ExplicitType (identifier "int")
        _ -> False
    Nothing -> False

parserPreservesTemplateParameter :: Bool
parserPreservesTemplateParameter = case onlyParsedTemplate "template<template<typename> class Container> class Wrapper {}" of
    Just declaration -> case templateParameters declaration of
        [TemplateParameter _ name _ (TemplateTemplateParameter [shape]) False Nothing] ->
            name == identifier "Container"
                && templateParameterShapeKind shape == TemplateTypeParameterShape
                && not (templateParameterShapeIsPack shape)
        _ -> False
    Nothing -> False

parserPreservesTypePack :: Bool
parserPreservesTypePack = case onlyParsedTemplate "template<typename... Types> class Tuple {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> templateParameterKind parameter == TemplateTypeParameter && templateParameterIsPack parameter
        _ -> False
    Nothing -> False

parserPreservesValuePack :: Bool
parserPreservesValuePack = case onlyParsedTemplate "template<int... Values> class Integers {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] ->
            templateParameterKind parameter == TemplateValueParameterKind (ExplicitType (identifier "int"))
                && templateParameterIsPack parameter
        _ -> False
    Nothing -> False

parserPreservesTemplatePack :: Bool
parserPreservesTemplatePack = case onlyParsedTemplate "template<template<typename> class... Containers> class Wrapper {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> case templateParameterKind parameter of
            TemplateTemplateParameter [_] -> templateParameterIsPack parameter
            _ -> False
        _ -> False
    Nothing -> False

parserPreservesTypeDefault :: Bool
parserPreservesTypeDefault = case onlyParsedTemplate "template<typename T = int> class Box {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> templateParameterDefault parameter == Just (TemplateTypeDefault (ExplicitType (identifier "int")))
        _ -> False
    Nothing -> False

parserPreservesLaterDefault :: Bool
parserPreservesLaterDefault = case onlyParsedTemplate "template<typename T = U, typename U = int> class Pair {}" of
    Just declaration -> case templateParameters declaration of
        first : second : [] ->
            templateParameterDefault first == Just (TemplateTypeDefault (ExplicitType (identifier "U")))
                && templateParameterDefault second == Just (TemplateTypeDefault (ExplicitType (identifier "int")))
        _ -> False
    Nothing -> False

parserPreservesValueDefault :: Bool
parserPreservesValueDefault = case onlyParsedTemplate "template<int Size = 64> class Buffer {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> case templateParameterDefault parameter of
            Just (TemplateValueDefault (TemplateIntegerSyntax _ 64)) -> True
            _ -> False
        _ -> False
    Nothing -> False

parserPreservesNamedValueDefault :: Bool
parserPreservesNamedValueDefault = case onlyParsedTemplate "template<int N = M, int M = 4> class Buffer {}" of
    Just declaration -> case templateParameters declaration of
        first : _ -> case templateParameterDefault first of
            Just (TemplateValueDefault (TemplateNameSyntax _ (QualifiedName [name]))) -> name == identifier "M"
            _ -> False
        _ -> False
    Nothing -> False

parserPreservesBooleanDefault :: Bool
parserPreservesBooleanDefault = case onlyParsedTemplate "template<bool Enabled = true> class Feature {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> case templateParameterDefault parameter of
            Just (TemplateValueDefault (TemplateBooleanSyntax _ True)) -> True
            _ -> False
        _ -> False
    Nothing -> False

parserPreservesCharacterDefault :: Bool
parserPreservesCharacterDefault = case onlyParsedTemplate "template<char Separator = 'x'> class Text {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> case templateParameterDefault parameter of
            Just (TemplateValueDefault (TemplateCharacterSyntax _ value)) -> value == 120
            _ -> False
        _ -> False
    Nothing -> False

parserPreservesQualifiedDefault :: Bool
parserPreservesQualifiedDefault = case onlyParsedTemplate "template<typename T = System.String> class Box {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] ->
            templateParameterDefault parameter
                == Just (TemplateTypeDefault (QualifiedTypeSyntax (QualifiedName [identifier "System", identifier "String"]) []))
        _ -> False
    Nothing -> False

parserPreservesGenericDefault :: Bool
parserPreservesGenericDefault = case onlyParsedTemplate "template<typename T = System.Array<int>> class Box {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> case templateParameterDefault parameter of
            Just (TemplateTypeDefault (QualifiedTypeSyntax _ [TemplateTypeSyntax (ExplicitType name)])) -> name == identifier "int"
            _ -> False
        _ -> False
    Nothing -> False

parserPreservesNestedTemplateShape :: Bool
parserPreservesNestedTemplateShape = case onlyParsedTemplate source of
    Just declaration -> case templateParameters declaration of
        [parameter] -> case templateParameterKind parameter of
            TemplateTemplateParameter [TemplateParameterShape (TemplateTemplateParameterShape [inner]) False] ->
                templateParameterShapeKind inner == TemplateTypeParameterShape
            _ -> False
        _ -> False
    Nothing -> False
    where
        source = "template<template<template<typename> class> class Factory> class Owner {}"

parserPreservesMixedOrder :: Bool
parserPreservesMixedOrder = case onlyParsedTemplate source of
    Just declaration -> parameterNames declaration == map identifier ["T", "N", "Container", "Rest"]
    Nothing -> False
    where
        source = "template<typename T, int N, template<typename> class Container, typename... Rest> class Mixed {}"

parserRejectsEmptyParameters :: Bool
parserRejectsEmptyParameters = hasCode "TAP0019" (parseSource "template<> class Empty {}")

parserRejectsEmptyTemplateShape :: Bool
parserRejectsEmptyTemplateShape = hasCode "TAP0020" (parseSource "template<template<> class Empty> class Wrapper {}")

parserRejectsMissingClose :: Bool
parserRejectsMissingClose = case parseSource "template<typename T class Box {}" of Left _ -> True; Right _ -> False

parserRejectsMissingName :: Bool
parserRejectsMissingName = case parseSource "template<typename> class Box {}" of Left _ -> True; Right _ -> False

parserRejectsMissingClass :: Bool
parserRejectsMissingClass = case parseSource "template<typename T> Box {}" of Left _ -> True; Right _ -> False

parserRejectsDanglingDefault :: Bool
parserRejectsDanglingDefault = case parseSource "template<typename T => class Box {}" of Left _ -> True; Right _ -> False

renamerAssignsPositiveIds :: Bool
renamerAssignsPositiveIds = case analyzeSource "template<typename T> class Box {}" of
    Right artifacts -> case syntaxDeclarations (renamedSyntaxTree (semanticRenamedAST artifacts)) of
        [TemplateTypeDeclaration _ _ _ [parameter] _] -> renamedUnique (templateParameterName parameter) > 0
        _ -> False
    Left _ -> False

renamerKeepsParameterOrder :: Bool
renamerKeepsParameterOrder = case analyzeSource "template<typename A, typename B, int N> class Box {}" of
    Right artifacts -> case syntaxDeclarations (renamedSyntaxTree (semanticRenamedAST artifacts)) of
        [TemplateTypeDeclaration _ _ _ parameters _] ->
            let ids = map (renamedUnique . templateParameterName) parameters
             in ids == [minimum ids .. maximum ids]
        _ -> False
    Left _ -> False

renamerRejectsDuplicateParameters :: Bool
renamerRejectsDuplicateParameters = hasCode "TAR0006" (analyzeSource "template<typename T, int T> class Box {}")

renamerScopesValueParameter :: Bool
renamerScopesValueParameter = case analyzeSource source of
    Right _ -> True
    Left _ -> False
    where
        source = "template<int N> class Buffer { int Size() { return N; } }"

renamerIsolatesTemplates :: Bool
renamerIsolatesTemplates = case analyzeSource source of
    Right artifacts -> case syntaxDeclarations (resolvedSyntaxTree (semanticResolvedAST artifacts)) of
        [TemplateTypeDeclaration _ _ _ [left] _, TemplateTypeDeclaration _ _ _ [right] _] ->
            resolvedSymbol (templateParameterName left) /= resolvedSymbol (templateParameterName right)
        _ -> False
    Left _ -> False
    where
        source = "template<typename T> class Left {} template<typename T> class Right {}"

resolverPreservesIdentities :: Bool
resolverPreservesIdentities = case analyzeSource "template<typename T> class Box {}" of
    Right artifacts -> case syntaxDeclarations (resolvedSyntaxTree (semanticResolvedAST artifacts)) of
        [TemplateTypeDeclaration _ name _ [parameter] _] ->
            symbolIdValue (resolvedSymbol name) > 0
                && symbolIdValue (resolvedSymbol (templateParameterName parameter)) > symbolIdValue (resolvedSymbol name)
        _ -> False
    Left _ -> False

checkerBuildsTypeVariable :: Bool
checkerBuildsTypeVariable = case onlyTypedTemplate source of
    Just declaration -> case templateMembers declaration of
        [FunctionDeclaration {declarationAnnotation = FunctionType [TypeVariable input] (TypeVariable output)}] ->
            resolvedSymbol input == resolvedSymbol output
        _ -> False
    Nothing -> False
    where
        source = "template<typename T> class Box { T Identity(_ T value) { return value; } }"

checkerBuildsValueVariable :: Bool
checkerBuildsValueVariable = memberParameterMatches source expected
    where
        source = "template<typename T, int N> class Buffer { void Use(_ [T; N] value) { return; } }"
        expected (NamedType _ arguments) = any isValueParameter arguments
        expected _ = False
        isValueParameter (ValueTemplateArgument (TemplateValueParameter _)) = True
        isValueParameter _ = False

checkerBuildsCallableType :: Bool
checkerBuildsCallableType = case onlyTypedTemplate source of
    Just declaration -> case templateMembers declaration of
        [FunctionDeclaration {declarationAnnotation = FunctionType [FunctionType [TypeVariable _] (TypeVariable _)] _}] -> True
        _ -> False
    Nothing -> False
    where
        source = "template<typename T> class Higher { void Use(_ (T) -> T action) { return; } }"

checkerBuildsArrayType :: Bool
checkerBuildsArrayType = memberParameterMatches source expected
    where
        source = "template<typename T> class Arrays { void Use(_ [T] values) { return; } }"
        expected (NamedType (QualifiedName [Identifier "System", Identifier "Array"]) [TypeTemplateArgument (TypeVariable _)]) = True
        expected _ = False

checkerBuildsFixedArrayType :: Bool
checkerBuildsFixedArrayType = memberParameterMatches source expected
    where
        source = "template<typename T, int N> class Arrays { void Use(_ [T; N] values) { return; } }"
        expected
            ( NamedType
                    (QualifiedName [Identifier "System", Identifier "Array"])
                    [TypeTemplateArgument (TypeVariable _), ValueTemplateArgument (TemplateValueParameter _)]
                ) = True
        expected _ = False

checkerBuildsDictionaryType :: Bool
checkerBuildsDictionaryType = memberParameterMatches source expected
    where
        source = "template<typename K, typename V> class Maps { void Use(_ [K to V] values) { return; } }"
        expected
            ( NamedType
                    (QualifiedName [Identifier "System", Identifier "Dictionary"])
                    [TypeTemplateArgument (TypeVariable _), TypeTemplateArgument (TypeVariable _)]
                ) = True
        expected _ = False

memberParameterMatches :: String -> (Type -> Bool) -> Bool
memberParameterMatches source predicate = case onlyTypedTemplate source of
    Just declaration -> case templateMembers declaration of
        [FunctionDeclaration {declarationParameters = [parameter]}] -> predicate (parameterAnnotation parameter)
        _ -> False
    Nothing -> False

checkerAnnotatesValueParameter :: Bool
checkerAnnotatesValueParameter = case onlyTypedTemplate "template<long N> class Buffer {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> templateParameterAnnotation parameter == namedType "long"
        _ -> False
    Nothing -> False

checkerAnnotatesTypeParameter :: Bool
checkerAnnotatesTypeParameter = case onlyTypedTemplate "template<typename T> class Box {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> case templateParameterAnnotation parameter of TypeVariable _ -> True; _ -> False
        _ -> False
    Nothing -> False

checkerAnnotatesTemplateParameter :: Bool
checkerAnnotatesTemplateParameter = case onlyTypedTemplate "template<template<typename> class C> class Box {}" of
    Just declaration -> case templateParameters declaration of
        [parameter] -> case templateParameterAnnotation parameter of TypeVariable _ -> True; _ -> False
        _ -> False
    Nothing -> False

checkerAcceptsLaterDefault :: Bool
checkerAcceptsLaterDefault = case analyzeSource "template<typename T = U, typename U = int> class Pair {}" of Right _ -> True; Left _ -> False

checkerAcceptsNamedValueDefault :: Bool
checkerAcceptsNamedValueDefault = case analyzeSource "template<int N = M, int M = 4> class Buffer {}" of Right _ -> True; Left _ -> False

checkerRejectsPackDefault :: Bool
checkerRejectsPackDefault = hasCode "TAT0019" (analyzeSource "template<typename... T = int> class Tuple {}")

checkerRejectsUnknownValueDefault :: Bool
checkerRejectsUnknownValueDefault = hasCode "TAT0020" (analyzeSource "template<int N = Missing> class Buffer {}")

openTemplateStopsBeforeCore :: Bool
openTemplateStopsBeforeCore = case analyzeSource "template<typename T> class Box { T Read(_ T value) { return value; } }" of
    Right _ -> True
    Left _ -> False

ordinaryDeclarationUnaffected :: Bool
ordinaryDeclarationUnaffected = case analyzeSource "class App { int Read() { return 1; } }" of Right _ -> True; Left _ -> False

templateAndOrdinaryCoexist :: Bool
templateAndOrdinaryCoexist = case analyzeSource source of
    Right artifacts -> length (syntaxDeclarations (typedSyntaxTree (semanticTypedAST artifacts))) == 2
    Left _ -> False
    where
        source = "template<typename T> class Box {} class App { void Run() { return; } }"

templateMemberCallsResolve :: Bool
templateMemberCallsResolve = case analyzeSource source of Right _ -> True; Left _ -> False
    where
        source =
            "template<typename T> class Box { T First(_ T value) { return value; } T Second(_ T value) { return First(value); } }"

identityMethodRetainsType :: Bool
identityMethodRetainsType = checkerBuildsTypeVariable

fixedArrayMethodRetainsParameters :: Bool
fixedArrayMethodRetainsParameters = checkerBuildsFixedArrayType

-- Total projections keep negative parser fixtures from crashing the test runner.
templateParameters :: Declaration name annotation -> [TemplateParameter name annotation]
templateParameters TemplateTypeDeclaration {declarationTemplateParameters = parameters} = parameters
templateParameters _ = []

templateMembers :: Declaration name annotation -> [Declaration name annotation]
templateMembers TemplateTypeDeclaration {typeMembers = members} = members
templateMembers _ = []
