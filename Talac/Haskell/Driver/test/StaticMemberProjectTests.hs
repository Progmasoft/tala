-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Project-boundary tests for static member binding across physical files.

The project compiler groups physical files by namespace before semantic
analysis. These tests ensure that a caller does not depend on input file order
and that a matching type in an unrelated namespace is not imported by spelling.
-}
module StaticMemberProjectTests (staticMemberProjectTests) where

import Data.List (sort)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Diagnostic

staticMemberProjectTests :: [(String, IO Bool)]
staticMemberProjectTests =
    [ ("later physical file contributes a type to the namespace catalog", laterFileTypeIsVisible)
    , ("static overload binding is stable when project inputs are reversed", reversedInputsKeepSelection)
    , ("the project Core records separate identities for same-spelled overloads", projectOverloadsHaveUniqueIds)
    , ("the selected cross-file call targets the exact parameter type", crossFileCallSelectsExactSignature)
    , ("project Core assigns each overload to its actual source file", overloadSourceOwnersAreDistinct)
    , ("source file path spelling remains portable for overload owners", overloadOwnerPathsArePortable)
    , ("an unrelated namespace does not satisfy a type receiver", namespaceDoesNotLeakTypes)
    , ("an invalid unrelated namespace is still validated", unrelatedNamespaceStillValidated)
    , ("a type with the same simple name in two namespaces has separate identities", namespaceTypeSymbolsAreSeparate)
    , ("project input permutation preserves successful selection", inputPermutationKeepsSelectedSignature)
    , ("each namespace returns its own overloaded Core module", namespaceModulesKeepLocalFunctions)
    , ("the selected namespace exposes only its own source catalog", selectedNamespaceSourcesAreLocal)
    , ("source owner metadata names every overload exactly once", everyOverloadHasOneSourceOwner)
    , ("project compilation rejects a missing type before overload lookup", missingTypeIsNameResolutionError)
    , ("same namespace calls remain case-sensitive across files", crossFileMemberSpellingIsCaseSensitive)
    , ("cross-file wrong arity preserves the overload diagnostic", crossFileArityDiagnostic)
    , ("cross-file wrong type preserves the exact-match diagnostic", crossFileTypeDiagnostic)
    , ("cross-file instance methods are not callable through a type", crossFileInstanceMethodRejected)
    , ("cross-file private methods remain inaccessible", crossFilePrivateMethodRejected)
    , ("cross-file public candidates survive private sibling filtering", crossFilePublicCandidateSurvives)
    , ("source ownership stays stable with a namespace-only source file", namespaceOnlySourceKeepsOwners)
    , ("all project namespaces remain represented after successful compile", everyProjectNamespaceIsRetained)
    ]

laterFileTypeIsVisible :: IO Bool
laterFileTypeIsVisible = pure (projectCompiles [programSource, catalogSource])

reversedInputsKeepSelection :: IO Bool
reversedInputsKeepSelection = pure (projectCompiles [catalogSource, programSource])

projectOverloadsHaveUniqueIds :: IO Bool
projectOverloadsHaveUniqueIds = pure $ case compileProject [programSource, catalogSource] of
    Right project -> case namedFunctions (Identifier "Select") (projectEntryCore project) of
        [first, second] -> resolvedSymbol (coreFunctionName first) /= resolvedSymbol (coreFunctionName second)
        _ -> False
    Left _ -> False

crossFileCallSelectsExactSignature :: IO Bool
crossFileCallSelectsExactSignature = pure $ case compileProject [programSource, catalogSource] of
    Right project ->
        let moduleValue = projectEntryCore project
            expected =
                [ resolvedSymbol (coreFunctionName function)
                | function <- namedFunctionsWithParameter (Identifier "Select") intType moduleValue
                ]
            actual = [resolvedSymbol target | target <- coreCallTargets moduleValue, resolvedSpelling target == Identifier "Select"]
         in exactlyOne expected && exactlyOne actual && actual == expected
    Left _ -> False

overloadSourceOwnersAreDistinct :: IO Bool
overloadSourceOwnersAreDistinct = pure $ case compileProject [programSource, catalogSource] of
    Right project ->
        let moduleValue = projectEntryCore project
            selectedOwners =
                [ owner
                | function <- namedFunctions (Identifier "Select") moduleValue
                , let functionId = symbolIdValue (resolvedSymbol (coreFunctionName function))
                , (identity, owner) <- coreModuleFunctionSources moduleValue
                , identity == functionId
                ]
         in sort selectedOwners == ["Sources/Catalog.tala", "Sources/Catalog.tala"]
                && length selectedOwners == 2
    Left _ -> False

overloadOwnerPathsArePortable :: IO Bool
overloadOwnerPathsArePortable = pure $ case compileProject [programSource, catalogSource] of
    Right project ->
        let owners = [owner | (_, owner) <- coreModuleFunctionSources (projectEntryCore project)]
         in all (not . any (== '\\')) owners && all (not . null) owners
    Left _ -> False

namespaceDoesNotLeakTypes :: IO Bool
namespaceDoesNotLeakTypes = pure $ hasCode "TAN0001" $ compileProjectToCorePrep entry [programSource, libraryCatalogSource]

unrelatedNamespaceStillValidated :: IO Bool
unrelatedNamespaceStillValidated =
    pure $ hasCode "TAN0001" $ compileProjectToCorePrep entry [programSource, applicationCatalogSource, brokenLibrarySource]

namespaceTypeSymbolsAreSeparate :: IO Bool
namespaceTypeSymbolsAreSeparate = pure $ case compileProjectToCorePrep entry [programSource, applicationCatalogSource, libraryCatalogSource] of
    Right project ->
        let typeNames = concatMap namespaceCatalogNames (projectNamespaces project)
         in length (filter (== Identifier "Catalog") typeNames) == 2
    Left _ -> False

inputPermutationKeepsSelectedSignature :: IO Bool
inputPermutationKeepsSelectedSignature = pure (selectionFor [programSource, catalogSource] == selectionFor [catalogSource, programSource])

namespaceModulesKeepLocalFunctions :: IO Bool
namespaceModulesKeepLocalFunctions = pure $ case compileProjectToCorePrep entry [programSource, applicationCatalogSource, libraryCatalogSource] of
    Right project ->
        let modules = map (coreModuleFunctions . artifactCore . artifactFrontend) (projectNamespaces project)
            names = map (sort . map (resolvedSpelling . coreFunctionName)) modules
         in length modules == 2
                && names
                    == [ sort [Identifier "Evaluate", Identifier "Main", Identifier "Select", Identifier "Select"]
                       , [Identifier "Select"]
                       ]
    Left _ -> False

selectedNamespaceSourcesAreLocal :: IO Bool
selectedNamespaceSourcesAreLocal = pure $ case compileProjectToCorePrep entry [programSource, applicationCatalogSource, libraryCatalogSource] of
    Right project ->
        let selected = projectEntryNamespace project
         in sort (artifactSourceFiles selected) == ["Sources/ApplicationCatalog.tala", "Sources/Program.tala"]
                && sort (map snd (coreModuleFunctionSources (projectEntryCore project)))
                    == [ "Sources/ApplicationCatalog.tala"
                       , "Sources/ApplicationCatalog.tala"
                       , "Sources/Program.tala"
                       , "Sources/Program.tala"
                       ]
    Left _ -> False

everyOverloadHasOneSourceOwner :: IO Bool
everyOverloadHasOneSourceOwner = pure $ case compileProject [programSource, catalogSource] of
    Right project ->
        let moduleValue = projectEntryCore project
            overloadIds = map (symbolIdValue . resolvedSymbol . coreFunctionName) (namedFunctions (Identifier "Select") moduleValue)
            ownerIds = map fst (coreModuleFunctionSources moduleValue)
         in length overloadIds == 2
                && all (\identity -> length (filter (== identity) ownerIds) == 1) overloadIds
    Left _ -> False

missingTypeIsNameResolutionError :: IO Bool
missingTypeIsNameResolutionError = pure $ hasCode "TAN0001" $ compileProjectToCorePrep entry [programWithMissingCatalog]

crossFileMemberSpellingIsCaseSensitive :: IO Bool
crossFileMemberSpellingIsCaseSensitive = pure $ hasCode "TAT0029" $ compileProjectToCorePrep entry [programWithMember "select", catalogSource]

crossFileArityDiagnostic :: IO Bool
crossFileArityDiagnostic = pure $ hasCode "TAT0008" $ compileProjectToCorePrep entry [programWithCall "Catalog.Select()", catalogSource]

crossFileTypeDiagnostic :: IO Bool
crossFileTypeDiagnostic =
    pure $ hasCode "TAT0009" $ compileProjectToCorePrep entry [programWithCall "Catalog.Select(\"wrong\")", catalogSource]

crossFileInstanceMethodRejected :: IO Bool
crossFileInstanceMethodRejected = pure $ hasCode "TAT0031" $ compileProjectToCorePrep entry [programSource, instanceCatalogSource]

crossFilePrivateMethodRejected :: IO Bool
crossFilePrivateMethodRejected = pure $ hasCode "TAT0033" $ compileProjectToCorePrep entry [programSource, privateCatalogSource]

crossFilePublicCandidateSurvives :: IO Bool
crossFilePublicCandidateSurvives = pure $ projectCompiles [programSource, mixedAccessCatalogSource]

namespaceOnlySourceKeepsOwners :: IO Bool
namespaceOnlySourceKeepsOwners = pure $ case compileProject [programSource, catalogSource, namespaceOnlySource] of
    Right project ->
        let moduleValue = projectEntryCore project
            ownerPaths = map snd (coreModuleFunctionSources moduleValue)
         in length (filter (== "Sources/OnlyNamespace.tala") (coreModuleSourceFiles moduleValue)) == 1
                && "Sources/OnlyNamespace.tala" `notElem` ownerPaths
    Left _ -> False

everyProjectNamespaceIsRetained :: IO Bool
everyProjectNamespaceIsRetained = pure $ case compileProjectToCorePrep entry [programSource, applicationCatalogSource, libraryCatalogSource] of
    Right project -> sort (map artifactNamespace (projectNamespaces project)) == [Just entryNamespace, Just libraryNamespace]
    Left _ -> False

selectionFor :: [CompilerInput] -> Maybe Type
selectionFor inputs = do
    project <- either (const Nothing) Just (compileProjectToCorePrep entry inputs)
    let targets = [target | target <- coreCallTargets (projectEntryCore project), resolvedSpelling target == Identifier "Select"]
    target <- exactlyOneValue targets
    function <- findFunctionBySymbol target (coreModuleFunctions (projectEntryCore project))
    parameter <- exactlyOneValue (map snd (coreFunctionParameters function))
    pure parameter

projectCompiles :: [CompilerInput] -> Bool
projectCompiles = either (const False) (const True) . compileProjectToCorePrep entry

compileProject :: [CompilerInput] -> Either [Diagnostic] ProjectFrontendArtifacts
compileProject = compileProjectToCorePrep entry

findFunctionBySymbol :: ResolvedName -> [CoreFunction] -> Maybe CoreFunction
findFunctionBySymbol _ [] = Nothing
findFunctionBySymbol requested (function : remaining)
    | resolvedSymbol requested == resolvedSymbol (coreFunctionName function) = Just function
    | otherwise = findFunctionBySymbol requested remaining

namedFunctions :: Identifier -> CoreModule -> [CoreFunction]
namedFunctions spelling moduleValue =
    [ function
    | function <- coreModuleFunctions moduleValue
    , resolvedSpelling (coreFunctionName function) == spelling
    ]

namedFunctionsWithParameter :: Identifier -> Type -> CoreModule -> [CoreFunction]
namedFunctionsWithParameter spelling parameterType moduleValue =
    [ function
    | function <- namedFunctions spelling moduleValue
    , [(_, actualType)] <- [coreFunctionParameters function]
    , actualType == parameterType
    ]

coreCallTargets :: CoreModule -> [ResolvedName]
coreCallTargets moduleValue = concatMap (concatMap statementTargets . coreFunctionBody) (coreModuleFunctions moduleValue)

statementTargets :: CoreStatement -> [ResolvedName]
statementTargets statement = case statement of
    CoreBind binding -> expressionTargets (coreBindingValue binding)
    CoreAssign _ value -> expressionTargets value
    CoreReturn value -> expressionTargets value
    CoreIf condition yes no -> expressionTargets condition ++ concatMap statementTargets yes ++ concatMap statementTargets no
    CoreEvaluate value -> expressionTargets value
    CoreWhile condition body -> expressionTargets condition ++ concatMap statementTargets body
    CoreDoWhile body condition -> concatMap statementTargets body ++ expressionTargets condition
    CoreFor condition updates body -> expressionTargets condition ++ concatMap statementTargets updates ++ concatMap statementTargets body
    CoreBreak -> []
    CoreContinue -> []

expressionTargets :: CoreExpression -> [ResolvedName]
expressionTargets expression = case expression of
    CoreVariable {} -> []
    CoreLiteral {} -> []
    CoreApply callee arguments _ -> target callee ++ expressionTargets callee ++ concatMap expressionTargets arguments
    CorePrimitive _ arguments _ -> concatMap expressionTargets arguments
    CoreLet _ _ value body _ -> expressionTargets value ++ expressionTargets body
    CoreConditional condition whenTrue whenFalse _ -> concatMap expressionTargets [condition, whenTrue, whenFalse]
    CoreClosure _ _ _ body _ -> concatMap statementTargets body
    where
        target (CoreVariable name _) = [name]
        target _ = []

namespaceCatalogNames :: NamespaceArtifacts -> [Identifier]
namespaceCatalogNames artifacts =
    [ resolvedSpelling (declarationName declaration)
    | declaration <- syntaxDeclarations (typedSyntaxTree (artifactTypedAST (artifactFrontend artifacts)))
    , case declaration of TypeDeclaration {} -> True; TemplateTypeDeclaration {} -> True; _ -> False
    ]

programSource :: CompilerInput
programSource = programWithCall "Catalog.Select(value)"

programWithCall :: String -> CompilerInput
programWithCall call =
    CompilerInput
        "Sources/Program.tala"
        ( "namespace Application; class Program { public static int Evaluate(int value) { return "
            ++ call
            ++ "; } public static void Main() { return; } }"
        )

programWithMember :: String -> CompilerInput
programWithMember member = programWithCall ("Catalog." ++ member ++ "(value)")

programWithMissingCatalog :: CompilerInput
programWithMissingCatalog = programWithCall "Catalog.Select(value)"

applicationCatalogSource :: CompilerInput
applicationCatalogSource =
    CompilerInput
        "Sources/ApplicationCatalog.tala"
        "namespace Application; class Catalog { public static int Select(long value) { return 1; } public static int Select(int value) { return value; } }"

catalogSource :: CompilerInput
catalogSource =
    CompilerInput
        "Sources/Catalog.tala"
        "namespace Application; class Catalog { public static int Select(long value) { if (value > 0) { return 1; } else { return 2; } } public static int Select(int value) { if (value > 0) { return value; } else { return 3; } } }"

instanceCatalogSource :: CompilerInput
instanceCatalogSource =
    CompilerInput
        "Sources/Catalog.tala"
        "namespace Application; class Catalog { public int Select(int value) { return value; } }"

privateCatalogSource :: CompilerInput
privateCatalogSource =
    CompilerInput
        "Sources/Catalog.tala"
        "namespace Application; class Catalog { private static int Select(int value) { return value; } }"

mixedAccessCatalogSource :: CompilerInput
mixedAccessCatalogSource =
    CompilerInput
        "Sources/Catalog.tala"
        "namespace Application; class Catalog { private static int Select(String value) { return 1; } public static int Select(int value) { return value; } }"

libraryCatalogSource :: CompilerInput
libraryCatalogSource =
    CompilerInput
        "Sources/LibraryCatalog.tala"
        "namespace Library; class Catalog { public static int Select(int value) { return value; } }"

brokenLibrarySource :: CompilerInput
brokenLibrarySource =
    CompilerInput "Sources/Broken.tala" "namespace Library; class Broken { int Read() { return missing; } }"

namespaceOnlySource :: CompilerInput
namespaceOnlySource = CompilerInput "Sources/OnlyNamespace.tala" "namespace Application;"

entry :: QualifiedName
entry = QualifiedName [Identifier "Application", Identifier "Program"]

entryNamespace :: QualifiedName
entryNamespace = QualifiedName [Identifier "Application"]

libraryNamespace :: QualifiedName
libraryNamespace = QualifiedName [Identifier "Library"]

hasCode :: String -> Either [Diagnostic] value -> Bool
hasCode code result = case result of
    Left diagnostics -> any ((== code) . diagnosticCode) diagnostics
    Right _ -> False

exactlyOne :: [value] -> Bool
exactlyOne values = case values of
    [_] -> True
    _ -> False

exactlyOneValue :: [value] -> Maybe value
exactlyOneValue values = case values of
    [value] -> Just value
    _ -> Nothing
