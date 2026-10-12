-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Composition of the target-independent Tala frontend stages.

A physical source file is a compilation unit, not a module. Namespace is the
semantic grouping key and does not need to match the directory layout. The
project compiler therefore parses every file independently, merges units by
namespace, runs each namespace through the complete Haskell pipeline, and
selects the configured namespace/class entry only after type checking.
-}
module Progmasoft.Tala.Compiler
    ( CompilerInput (..)
    , FrontendArtifacts (..)
    , NamespaceArtifacts (..)
    , ProjectFrontendArtifacts (..)
    , compileToCorePrep
    , compileEntryToCorePrep
    , compileProjectToCorePrep
    , compileTemplateSpecializations
    , projectEntryCore
    , validateEntryPoint
    ) where

import Data.List (groupBy, sortOn)
import Data.Maybe (mapMaybe)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.Monomorphization
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Desugarer
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Template.Discovery
import Progmasoft.Tala.Template.Specialization
import Progmasoft.Tala.Template.Specialization.Verifier

{- | Artifacts for one semantic namespace after all of its physical source
units have been merged. Keeping every stage visible makes stage ownership and
regression tests explicit; CorePrep remains internal at the process boundary.
-}
data FrontendArtifacts = FrontendArtifacts
    { artifactParsedAST :: ParsedAST
    , artifactRenamedAST :: RenamedAST
    , artifactResolvedAST :: ResolvedAST
    , artifactTypedAST :: TypedAST
    , artifactTemplateDemandDiscovery :: TemplateDemandDiscovery
    , artifactTemplateSpecializations :: TemplateSpecializationPlan
    , artifactCore :: CoreModule
    , artifactMonomorphizationPlan :: MonomorphizationPlan
    , artifactOptimizedCore :: CoreModule
    , artifactCorePrep :: CorePrepModule
    }
    deriving (Eq, Ord, Read, Show)

-- | Frontend stages and source provenance for one merged semantic namespace.
data NamespaceArtifacts = NamespaceArtifacts
    { artifactNamespace :: Maybe QualifiedName
    , artifactSourceFiles :: [FilePath]
    , artifactFrontend :: FrontendArtifacts
    }
    deriving (Eq, Ord, Read, Show)

{- | A project may contain several namespaces, but the current private Core wire
carries one module at a time. All namespaces are still parsed, renamed,
resolved, typed, lowered, optimized, and verified. The selected entry
namespace is the module handed to the native CorePrep/Xpp/Xmm boundary.
-}
data ProjectFrontendArtifacts = ProjectFrontendArtifacts
    { projectEntryName :: QualifiedName
    , projectNamespaces :: [NamespaceArtifacts]
    , projectEntryNamespace :: NamespaceArtifacts
    }
    deriving (Eq, Ord, Read, Show)

-- | Run the source pipeline through verified, optimized CorePrep for one file.
compileToCorePrep :: CompilerInput -> Either [Diagnostic] FrontendArtifacts
compileToCorePrep input = analyzeSemantics input >>= compileSemanticToCorePrep

-- | Compile one source file and validate its namespace-qualified entry class.
compileEntryToCorePrep :: QualifiedName -> CompilerInput -> Either [Diagnostic] FrontendArtifacts
compileEntryToCorePrep entry input = do
    artifacts <- compileToCorePrep input
    validateEntryPoint entry (artifactTypedAST artifacts)
    pure artifacts

{- | Materialize an explicit batch of resolved template demands and lower the
resulting closed declaration view to verified Core. Demand discovery and
constraint ordering stay outside this function: callers must pass demands
produced by semantic resolution rather than asking the driver to infer syntax.
-}
compileTemplateSpecializations ::
    TemplateSpecializationLimits ->
    TypedAST ->
    [TemplateSpecializationDemand] ->
    Either [Diagnostic] (TemplateSpecializationPlan, CoreModule)
compileTemplateSpecializations limits typed demands = do
    plan <-
        mapLeft templateSpecializationDiagnostics (planTemplateSpecializations limits typed demands)
            >>= mapLeft templatePlanDiagnostics . verifyTemplateSpecializationPlan
    core <- runDesugarer defaultDesugarer (specializationTypedAST plan) >>= verifyCore
    pure (plan, core)

{- | Compile a complete discovered source set. Diagnostics from independent
files and namespaces are accumulated in deterministic input order instead of
stopping at the first bad file, which makes project output useful without
weakening any stage boundary.
-}
compileProjectToCorePrep :: QualifiedName -> [CompilerInput] -> Either [Diagnostic] ProjectFrontendArtifacts
compileProjectToCorePrep entry inputs = do
    namespaceName <- entryNamespaceName entry
    parsedUnits <- collectResults (map parseUnit inputs)
    if null parsedUnits
        then Left [compilerProblem "TAE0010" Nothing "project source set is empty"]
        else do
            compiled <- collectResults (map compileNamespace (groupParsedUnits parsedUnits))
            selected <- selectNamespace namespaceName compiled
            validateEntryPoint entry (artifactTypedAST (artifactFrontend selected))
            pure (ProjectFrontendArtifacts entry compiled selected)
    where
        parseUnit input = do
            syntax <- analyzeSyntax input
            pure (compilerSourceFile input, syntaxParsedAST syntax)

-- | Retrieve the selected namespace's optimized Core module for native lowering.
projectEntryCore :: ProjectFrontendArtifacts -> CoreModule
projectEntryCore = artifactOptimizedCore . artifactFrontend . projectEntryNamespace

compileParsedToCorePrep :: ParsedAST -> Either [Diagnostic] FrontendArtifacts
compileParsedToCorePrep parsed = analyzeParsedSemantics parsed >>= compileSemanticToCorePrep

compileSemanticToCorePrep :: SemanticArtifacts -> Either [Diagnostic] FrontendArtifacts
compileSemanticToCorePrep semantic = do
    let parsed = semanticParsedAST semantic
        renamed = semanticRenamedAST semantic
        resolved = semanticResolvedAST semantic
        typed = semanticTypedAST semantic
        templateDiscovery = discoverTemplateDemands typed
    templatePlan <-
        mapLeft
            templateSpecializationDiagnostics
            (planTemplateSpecializations defaultTemplateSpecializationLimits typed (discoveredTemplateDemands templateDiscovery))
            >>= mapLeft templatePlanDiagnostics . verifyTemplateSpecializationPlan
    -- The two trees are one program: which calls have an effect is
    -- decided from both.
    let specializations = specializationTypedAST templatePlan
        desugarer = desugarerWithin [typed, specializations]
    ordinaryCore <- runDesugarer desugarer typed >>= verifyCore
    specializationCore <- runDesugarer desugarer specializations >>= verifyCore
    let core =
            CoreModuleWithSources
                (coreModuleName ordinaryCore)
                (coreModuleFunctions ordinaryCore ++ coreModuleFunctions specializationCore)
                (unique (coreModuleSourceFiles ordinaryCore ++ coreModuleSourceFiles specializationCore))
                (coreModuleFunctionSources ordinaryCore ++ coreModuleFunctionSources specializationCore)
    verifiedCore <- verifyCore core
    -- Demand discovery runs before optimization so dead-code elimination
    -- cannot silently erase a type required by the checked source contract.
    -- The declaration planner consumes this discovery immediately. The later
    -- Core graph remains separate because it describes backend work rather
    -- than source declaration selection.
    specializationPlan <- mapLeft monomorphizationDiagnostic (planCoreMonomorphization verifiedCore)
    optimized <- runCoreOptimizer defaultCoreOptimizer verifiedCore >>= verifyCore
    prepared <- prepareCore optimized >>= verifyCorePrep
    pure
        ( FrontendArtifacts
            parsed
            renamed
            resolved
            typed
            templateDiscovery
            templatePlan
            verifiedCore
            specializationPlan
            optimized
            prepared
        )

mapLeft :: (failure -> mapped) -> Either failure value -> Either mapped value
mapLeft transform result = case result of
    Left failure -> Left (transform failure)
    Right value -> Right value

monomorphizationDiagnostic :: MonomorphizationError -> [Diagnostic]
monomorphizationDiagnostic failure =
    [ Diagnostic
        CoreStage
        Error
        "TAM1001"
        Nothing
        (renderMonomorphizationError failure)
    ]

templateSpecializationDiagnostics :: [TemplateSpecializationError] -> [Diagnostic]
templateSpecializationDiagnostics = zipWith diagnostic [1 :: Int ..]
    where
        diagnostic index failure =
            Diagnostic
                TypeCheckerStage
                Error
                ("TAT2" ++ pad index)
                Nothing
                (renderTemplateSpecializationError failure)
        pad value
            | value < 10 = "00" ++ show value
            | value < 100 = "0" ++ show value
            | otherwise = show value

templatePlanDiagnostics :: [TemplatePlanIssue] -> [Diagnostic]
templatePlanDiagnostics = zipWith diagnostic [1 :: Int ..]
    where
        diagnostic index failure =
            Diagnostic
                TypeCheckerStage
                Error
                ("TAT3" ++ pad index)
                Nothing
                (renderTemplatePlanIssue failure)
        pad value
            | value < 10 = "00" ++ show value
            | value < 100 = "0" ++ show value
            | otherwise = show value

data ParsedNamespace = ParsedNamespace
    { parsedNamespaceName :: Maybe QualifiedName
    , parsedNamespaceFiles :: [FilePath]
    , parsedNamespaceDeclarations :: [Declaration Identifier ()]
    }

groupParsedUnits :: [(FilePath, ParsedAST)] -> [ParsedNamespace]
groupParsedUnits units = map mergeGroup grouped
    where
        keyed = sortOn namespaceSortKey [(syntaxNamespace tree, file, syntaxDeclarations tree) | (file, ParsedAST tree) <- units]
        grouped = groupBy sameNamespace keyed
        sameNamespace (left, _, _) (right, _, _) = left == right
        mergeGroup [] = ParsedNamespace Nothing [] []
        mergeGroup values@((namespaceName, _, _) : _) =
            ParsedNamespace
                namespaceName
                [file | (_, file, _) <- values]
                (concat [declarations | (_, _, declarations) <- values])

namespaceSortKey :: (Maybe QualifiedName, FilePath, declarations) -> (Maybe QualifiedName, FilePath)
namespaceSortKey (namespaceName, file, _) = (namespaceName, file)

compileNamespace :: ParsedNamespace -> Either [Diagnostic] NamespaceArtifacts
compileNamespace parsed = do
    let syntaxTree = SyntaxTree (parsedNamespaceName parsed) (parsedNamespaceDeclarations parsed)
    artifacts <- compileParsedToCorePrep (ParsedAST syntaxTree)
    let frontend = artifacts
        sourceFiles = unique (map portablePath (parsedNamespaceFiles parsed))
        attachSources core = core {coreModuleSourceFiles = unique (sourceFiles ++ coreModuleSourceFiles core)}
        prepared =
            (artifactCorePrep frontend)
                { corePrepModuleSourceFiles = unique (sourceFiles ++ corePrepModuleSourceFiles (artifactCorePrep frontend))
                }
        updatedFrontend =
            frontend
                { artifactCore = attachSources (artifactCore frontend)
                , artifactOptimizedCore = attachSources (artifactOptimizedCore frontend)
                , artifactCorePrep = prepared
                }
    _ <- verifyCore (artifactOptimizedCore updatedFrontend)
    _ <- verifyCorePrep prepared
    pure
        ( NamespaceArtifacts
            (parsedNamespaceName parsed)
            sourceFiles
            updatedFrontend
        )

portablePath :: FilePath -> FilePath
portablePath = map (\character -> if character == '\\' then '/' else character)

selectNamespace :: QualifiedName -> [NamespaceArtifacts] -> Either [Diagnostic] NamespaceArtifacts
selectNamespace namespaceName artifacts =
    case [candidate | candidate <- artifacts, artifactNamespace candidate == Just namespaceName] of
        [selected] -> Right selected
        [] -> Left [compilerProblem "TAE0011" Nothing ("entry namespace was not found: " ++ renderQualifiedName namespaceName)]
        _ ->
            Left
                [ compilerProblem "TAE0012" Nothing ("entry namespace was produced more than once: " ++ renderQualifiedName namespaceName)
                ]

-- | Check that an entry path names a public static parameterless void Main method.
validateEntryPoint :: QualifiedName -> TypedAST -> Either [Diagnostic] ()
validateEntryPoint entry (TypedAST (SyntaxTree namespace declarations)) = do
    expectedNamespace <- entryNamespaceName entry
    className <- entryClassName entry
    if namespace /= Just expectedNamespace
        then Left [entryProblem "TAE0002" Nothing "entry namespace does not match the selected source namespace"]
        else case matchingTypes className declarations of
            [] -> Left [entryProblem "TAE0003" Nothing ("entry class was not found: " ++ identifierText className)]
            [declaration] -> validateEntryMethod declaration
            _ -> Left [entryProblem "TAE0013" Nothing ("entry class is ambiguous: " ++ identifierText className)]

matchingTypes :: Identifier -> [Declaration ResolvedName Type] -> [Declaration ResolvedName Type]
matchingTypes className declarations =
    [ declaration
    | declaration@TypeDeclaration {} <- declarations
    , resolvedSpelling (declarationName declaration) == className
    ]

validateEntryMethod :: Declaration ResolvedName Type -> Either [Diagnostic] ()
validateEntryMethod TypeDeclaration {typeMembers = members} =
    case matchingMethods of
        [] -> Left [entryProblem "TAE0004" Nothing "entry class must declare Main"]
        [ method@FunctionDeclaration
                { declarationAccess = access
                , declarationIsStatic = isStatic
                , declarationParameters = parameters
                , declarationReturnSyntax = returnSyntax
                }
            ]
                | access /= PublicAccess -> failure method "TAE0005" "entry Main must be public"
                | not isStatic -> failure method "TAE0006" "entry Main must be static"
                | not (null parameters) -> failure method "TAE0007" "entry Main must not declare parameters"
                | not (syntaxSpellsVoid returnSyntax) ->
                    failure method "TAE0008" "entry Main must return void"
                | otherwise -> Right ()
        _ -> Left [entryProblem "TAE0014" (declarationSpan <$> firstMethod) "entry class must declare exactly one Main method"]
    where
        matchingMethods =
            [ member
            | member@FunctionDeclaration {} <- members
            , identifierText (resolvedSpelling (declarationName member)) == "Main"
            ]
        firstMethod = case matchingMethods of
            [] -> Nothing
            method : _ -> Just method
        failure method code message = Left [entryProblem code (Just (declarationSpan method)) message]
validateEntryMethod _ = Left [entryProblem "TAE0009" Nothing "entry target is not a class"]

syntaxSpellsVoid :: TypeSyntax -> Bool
syntaxSpellsVoid syntax = case syntax of
    ExplicitType (Identifier "void") -> True
    QualifiedTypeSyntax (QualifiedName [Identifier "void"]) [] -> True
    _ -> False

entryNamespaceName :: QualifiedName -> Either [Diagnostic] QualifiedName
entryNamespaceName (QualifiedName parts)
    | length parts < 2 = Left [entryProblem "TAE0001" Nothing "entry must name a namespace-qualified class"]
    | otherwise = Right (QualifiedName (init parts))

entryClassName :: QualifiedName -> Either [Diagnostic] Identifier
entryClassName (QualifiedName parts) =
    case reverse parts of
        className : _ : _ -> Right className
        _ -> Left [entryProblem "TAE0001" Nothing "entry must name a namespace-qualified class"]

renderQualifiedName :: QualifiedName -> String
renderQualifiedName (QualifiedName parts) = joinWithDot (map identifierText parts)

joinWithDot :: [String] -> String
joinWithDot [] = ""
joinWithDot [value] = value
joinWithDot (value : remaining) = value ++ "." ++ joinWithDot remaining

unique :: (Eq value) => [value] -> [value]
unique = foldl add []
    where
        add values value
            | value `elem` values = values
            | otherwise = values ++ [value]

collectResults :: [Either [Diagnostic] value] -> Either [Diagnostic] [value]
collectResults values =
    case concat [problems | Left problems <- values] of
        [] -> Right (mapMaybe rightValue values)
        problems -> Left problems
    where
        rightValue (Right value) = Just value
        rightValue (Left _) = Nothing

compilerProblem :: String -> Maybe SourceSpan -> String -> Diagnostic
compilerProblem code spanValue message = Diagnostic TypeCheckerStage Error code spanValue message

entryProblem :: String -> Maybe SourceSpan -> String -> Diagnostic
entryProblem = compilerProblem
