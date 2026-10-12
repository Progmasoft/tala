-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module TemplateDiscoveryTests (templateDiscoveryTests) where

import Data.Functor.Identity (runIdentity)
import Data.List (isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Discovery
import Progmasoft.Tala.Template.Specialization

templateDiscoveryTests :: [(String, Bool)]
templateDiscoveryTests =
    [ ("discovery finds a concrete template parameter type", discoversParameterType)
    , ("discovery emits layout-only demand", discoveryIsLayoutOnly)
    , ("discovery retains concrete type arguments", discoveryRetainsTypeArguments)
    , ("discovery retains concrete value arguments", discoveryRetainsValueArguments)
    , ("discovery resolves a namespace-relative template", resolvesNamespaceRelativeTemplate)
    , ("discovery retains a qualified template target", retainsQualifiedTemplateTarget)
    , ("discovery finds a function result template", discoversFunctionResult)
    , ("discovery finds a local binding template", discoversBindingType)
    , ("discovery finds nested template applications", discoversNestedApplications)
    , ("nested applications are ordered outer before inner", nestedApplicationOrderIsStable)
    , ("discovery records distinct source uses", repeatedUsesRemainDiagnosticEvidence)
    , ("open template declaration bodies are skipped", skipsOpenTemplateBodies)
    , ("ordinary named types do not create demands", ignoresOrdinaryTypes)
    , ("unrelated generic spelling does not create a demand", ignoresUnknownGenericNames)
    , ("discovery records visited type nodes", countsVisitedTypes)
    , ("discovery counts emitted applications", countsApplications)
    , ("discovery counts ordinary named types", countsIgnoredTypes)
    , ("discovery counts skipped open templates", countsSkippedTemplates)
    , ("origins identify the owning class", originNamesOwner)
    , ("origins identify the member", originNamesMember)
    , ("origins identify the parameter site", originNamesParameterSite)
    , ("origins include the source file", originNamesSourceFile)
    , ("origins include positive source coordinates", originHasCoordinates)
    , ("normal compilation stores discovery artifacts", compilerStoresDiscovery)
    , ("normal compilation plans discovered layouts", compilerPlansLayouts)
    , ("automatically planned layout omits template methods", automaticLayoutOmitsMethods)
    , ("automatically planned template type is closed", automaticPlanIsClosed)
    , ("ordinary programs retain an empty template plan", ordinaryProgramHasEmptyPlan)
    , ("default template arguments are materialized by planning", defaultArgumentsAreMaterialized)
    , ("type and value applications become separate plans", mixedApplicationsStaySeparate)
    , ("duplicate uses coalesce in the specialization plan", duplicateUsesCoalesceInPlan)
    , ("duplicate uses retain both discovery origins", duplicateUsesRetainOrigins)
    , ("discovery itself remains independent from coalescing", discoveryDoesNotCoalesce)
    , ("nested layout plans retain dependency order", nestedPlansHaveDependencyOrder)
    , ("template-only source reaches CorePrep with no emitted function", templateOnlyPipelineIsEmpty)
    ]

analyze :: String -> Maybe TypedAST
analyze source = case analyzeSemantics (CompilerInput "template-discovery-test.tala" source) of
    Right artifacts -> Just (semanticTypedAST artifacts)
    Left _ -> Nothing

discover :: String -> Maybe TemplateDemandDiscovery
discover source = discoverTemplateDemands <$> analyze source

compile :: String -> Maybe FrontendArtifacts
compile source = case compileToCorePrep (CompilerInput "template-discovery-test.tala" source) of
    Right artifacts -> Just artifacts
    Left _ -> Nothing

qualified :: [String] -> QualifiedName
qualified = QualifiedName . map Identifier

applicationTarget :: TemplateSpecializationDemand -> QualifiedName
applicationTarget = templateApplicationTarget . specializationDemandApplication

applicationArguments :: TemplateSpecializationDemand -> [TemplateArgument]
applicationArguments = templateApplicationArguments . specializationDemandApplication

targetTexts :: TemplateDemandDiscovery -> [[String]]
targetTexts =
    map (map identifierText . qualifiedNameParts . applicationTarget)
        . discoveredTemplateDemands

onlyDemand :: TemplateDemandDiscovery -> Maybe TemplateSpecializationDemand
onlyDemand discovery = case discoveredTemplateDemands discovery of
    [value] -> Just value
    _ -> Nothing

onlyOrigin :: TemplateDemandDiscovery -> Maybe TemplateDiscoveryOrigin
onlyOrigin discovery = case discoveredTemplateOrigins discovery of
    [value] -> Just value
    _ -> Nothing

onlySpecialization :: FrontendArtifacts -> Maybe TemplateSpecialization
onlySpecialization artifacts = case plannedTemplateSpecializations (artifactTemplateSpecializations artifacts) of
    [value] -> Just value
    _ -> Nothing

boxParameterSource :: String
boxParameterSource =
    unlines
        [ "template<typename T> class Box {"
        , "    T Read(_ T value) { return value; }"
        , "}"
        , "class App {"
        , "    void Use(_ Box<int> value) { return; }"
        , "}"
        ]

bufferParameterSource :: String
bufferParameterSource =
    unlines
        [ "template<typename T, int N> class Buffer {}"
        , "class App {"
        , "    void Use(_ Buffer<int, 64> value) { return; }"
        , "}"
        ]

namespacedSource :: String
namespacedSource =
    unlines
        [ "namespace Example;"
        , "template<typename T> class Box {}"
        , "class App { void Use(_ Box<String> value) { return; } }"
        ]

nestedSource :: String
nestedSource =
    unlines
        [ "template<typename T> class Box {}"
        , "template<typename T> class Holder {}"
        , "class App { void Use(_ Holder<Box<int>> value) { return; } }"
        ]

duplicateSource :: String
duplicateSource =
    unlines
        [ "template<typename T> class Box {}"
        , "class App {"
        , "    void First(_ Box<int> value) { return; }"
        , "    void Second(_ Box<int> value) { return; }"
        , "}"
        ]

discoversParameterType :: Bool
discoversParameterType = case discover boxParameterSource >>= onlyDemand of
    Just demand -> applicationTarget demand == qualified ["Box"]
    Nothing -> False

discoveryIsLayoutOnly :: Bool
discoveryIsLayoutOnly = case discover boxParameterSource >>= onlyDemand of
    Just demand -> specializationDemandScope demand == TemplateLayoutDemand
    Nothing -> False

discoveryRetainsTypeArguments :: Bool
discoveryRetainsTypeArguments = case discover boxParameterSource >>= onlyDemand of
    Just demand -> applicationArguments demand == [TypeTemplateArgument intType]
    Nothing -> False

discoveryRetainsValueArguments :: Bool
discoveryRetainsValueArguments = case discover bufferParameterSource >>= onlyDemand of
    Just demand ->
        applicationArguments demand
            == [TypeTemplateArgument intType, ValueTemplateArgument (IntegerTemplateValue 64)]
    Nothing -> False

resolvesNamespaceRelativeTemplate :: Bool
resolvesNamespaceRelativeTemplate = case discover namespacedSource >>= onlyDemand of
    Just demand -> applicationTarget demand == qualified ["Example", "Box"]
    Nothing -> False

retainsQualifiedTemplateTarget :: Bool
retainsQualifiedTemplateTarget = case discover source >>= onlyDemand of
    Just demand -> applicationTarget demand == qualified ["Example", "Box"]
    Nothing -> False
    where
        source =
            "namespace Example; template<typename T> class Box {} class App { void Use(_ Example.Box<int> value) { return; } }"

discoversFunctionResult :: Bool
discoversFunctionResult = case discover source of
    Just result ->
        any
            (\(demand, origin) -> applicationTarget demand == qualified ["Box"] && FunctionSignatureSite `elem` discoverySites origin)
            (zip (discoveredTemplateDemands result) (discoveredTemplateOrigins result))
    Nothing -> False
    where
        source =
            "template<typename T> class Box {} class App { Box<int> Identity(_ Box<int> value) { return value; } }"

discoversBindingType :: Bool
discoversBindingType = case discover source of
    Just result -> ["Box"] `elem` targetTexts result
    Nothing -> False
    where
        source =
            "template<typename T> class Box {} class App { void Use(_ Box<int> input) { Box<int> copy = input; return; } }"

discoversNestedApplications :: Bool
discoversNestedApplications = case discover nestedSource of
    Just result -> targetTexts result == [["Holder"], ["Box"]]
    Nothing -> False

nestedApplicationOrderIsStable :: Bool
nestedApplicationOrderIsStable = case (discover nestedSource, discover nestedSource) of
    (Just first, Just second) -> discoveredTemplateDemands first == discoveredTemplateDemands second
    _ -> False

repeatedUsesRemainDiagnosticEvidence :: Bool
repeatedUsesRemainDiagnosticEvidence = case discover duplicateSource of
    Just result -> length (discoveredTemplateDemands result) == 2 && length (discoveredTemplateOrigins result) == 2
    Nothing -> False

skipsOpenTemplateBodies :: Bool
skipsOpenTemplateBodies = case discover source of
    Just result -> null (discoveredTemplateDemands result) && skippedOpenTemplateBodies (templateDiscoveryStatistics result) == 1
    Nothing -> False
    where
        source = "template<typename T> class Box { T Read(_ T value) { return value; } }"

ignoresOrdinaryTypes :: Bool
ignoresOrdinaryTypes = case discover "class App { String Name() { return \"x\"; } }" of
    Just result -> null (discoveredTemplateDemands result)
    Nothing -> False

ignoresUnknownGenericNames :: Bool
ignoresUnknownGenericNames = case analyze boxParameterSource of
    Just typed ->
        let result = discoverTemplateDemands (renameBoxApplication "Missing" typed)
         in null (discoveredTemplateDemands result)
    Nothing -> False

renameBoxApplication :: String -> TypedAST -> TypedAST
renameBoxApplication replacement (TypedAST tree) = TypedAST tree {syntaxDeclarations = map rewriteDeclaration (syntaxDeclarations tree)}
    where
        rewriteDeclaration declaration = case declaration of
            TypeDeclaration spanValue name annotation members ->
                TypeDeclaration spanValue name (rewriteType annotation) (map rewriteDeclaration members)
            FunctionDeclaration spanValue name annotation syntax parameters body isStatic access ->
                FunctionDeclaration
                    spanValue
                    name
                    (rewriteType annotation)
                    syntax
                    (map rewriteParameter parameters)
                    (rewriteBlock body)
                    isStatic
                    access
            TemplateTypeDeclaration {} -> declaration
            EnumDeclaration {} -> declaration
        rewriteParameter parameter = parameter {parameterAnnotation = rewriteType (parameterAnnotation parameter)}
        rewriteBlock (Block statements) = Block (map rewriteStatement statements)
        rewriteStatement statement = case statement of
            BindingStatement spanValue kind syntax name annotation value ->
                BindingStatement spanValue kind syntax name (rewriteType annotation) (rewriteExpression value)
            AssignmentStatement spanValue name annotation value ->
                AssignmentStatement spanValue name (rewriteType annotation) (rewriteExpression value)
            ReturnStatement spanValue value -> ReturnStatement spanValue (rewriteExpression <$> value)
            IfStatement spanValue condition yes no ->
                IfStatement spanValue (rewriteExpression condition) (rewriteBlock yes) (rewriteBlock <$> no)
            WhileStatement spanValue condition body ->
                WhileStatement spanValue (rewriteExpression condition) (rewriteBlock body)
            DoWhileStatement spanValue body condition ->
                DoWhileStatement spanValue (rewriteBlock body) (rewriteExpression condition)
            ForStatement spanValue initializer condition updates body ->
                ForStatement
                    spanValue
                    (rewriteStatement <$> initializer)
                    (rewriteExpression <$> condition)
                    (map rewriteStatement updates)
                    (rewriteBlock body)
            ForEachStatement spanValue kind syntax name annotation source body ->
                ForEachStatement
                    spanValue
                    kind
                    syntax
                    name
                    (rewriteType annotation)
                    (rewriteExpression source)
                    (rewriteBlock body)
            IncrementStatement spanValue name annotation ->
                IncrementStatement spanValue name (rewriteType annotation)
            CompoundAssignmentStatement spanValue operator name annotation value ->
                CompoundAssignmentStatement spanValue operator name (rewriteType annotation) (rewriteExpression value)
            DiscardStatement spanValue value -> DiscardStatement spanValue (rewriteExpression value)
            BreakStatement spanValue value -> BreakStatement spanValue (rewriteExpression <$> value)
            ContinueStatement {} -> statement
            GuardStatement spanValue condition block ->
                GuardStatement spanValue (rewriteExpression condition) (rewriteBlock block)
            BlockStatement spanValue block -> BlockStatement spanValue (rewriteBlock block)
            ExpressionStatement spanValue value terminated -> ExpressionStatement spanValue (rewriteExpression value) terminated
        rewriteExpression expression = case expression of
            NameExpression spanValue name annotation -> NameExpression spanValue name (rewriteType annotation)
            LiteralExpression spanValue literal annotation -> LiteralExpression spanValue literal (rewriteType annotation)
            MemberAccessExpression spanValue receiver member annotation ->
                MemberAccessExpression spanValue (rewriteExpression receiver) member (rewriteType annotation)
            MethodReferenceExpression spanValue receiver member annotation ->
                MethodReferenceExpression spanValue (rewriteExpression receiver) member (rewriteType annotation)
            CallExpression spanValue callee arguments annotation ->
                CallExpression spanValue (rewriteExpression callee) (map rewriteExpression arguments) (rewriteType annotation)
            UnaryExpression spanValue operator value annotation ->
                UnaryExpression spanValue operator (rewriteExpression value) (rewriteType annotation)
            BinaryExpression spanValue operator left right annotation ->
                BinaryExpression spanValue operator (rewriteExpression left) (rewriteExpression right) (rewriteType annotation)
            IsPatternExpression spanValue value patternValue annotation ->
                IsPatternExpression
                    spanValue
                    (rewriteExpression value)
                    (rewritePattern patternValue)
                    (rewriteType annotation)
            ConditionalExpression spanValue condition whenTrue whenFalse annotation ->
                ConditionalExpression
                    spanValue
                    (rewriteExpression condition)
                    (rewriteExpression whenTrue)
                    (rewriteExpression whenFalse)
                    (rewriteType annotation)
            CoalesceExpression spanValue left fallback annotation ->
                CoalesceExpression spanValue (rewriteExpression left) (rewriteExpression fallback) (rewriteType annotation)
            AssignmentExpression spanValue operator name value annotation ->
                AssignmentExpression spanValue operator name (rewriteExpression value) (rewriteType annotation)
            IncrementExpression spanValue isPrefix name annotation ->
                IncrementExpression spanValue isPrefix name (rewriteType annotation)
            LoopExpression spanValue loop annotation ->
                LoopExpression spanValue (rewriteStatement loop) (rewriteType annotation)
            BlockExpression spanValue block annotation ->
                BlockExpression spanValue (rewriteBlock block) (rewriteType annotation)
            MatchExpression spanValue subjects arms annotation ->
                MatchExpression
                    spanValue
                    (map rewriteExpression subjects)
                    [ arm
                        { matchArmPatterns =
                            [ runIdentity (traverseMatchPattern pure (pure . rewriteType) patternValue)
                            | patternValue <- matchArmPatterns arm
                            ]
                        , matchArmGuard = rewriteExpression <$> matchArmGuard arm
                        , matchArmBody = rewriteExpression (matchArmBody arm)
                        }
                    | arm <- arms
                    ]
                    (rewriteType annotation)
            CallableExpression spanValue isStatic captures parameters body annotation ->
                CallableExpression spanValue isStatic captures parameters body (rewriteType annotation)
        rewritePattern patternValue = case patternValue of
            WildcardPattern spanValue annotation -> WildcardPattern spanValue (rewriteType annotation)
            NullPattern spanValue annotation -> NullPattern spanValue (rewriteType annotation)
            LiteralPattern spanValue literal annotation -> LiteralPattern spanValue literal (rewriteType annotation)
            TypePattern spanValue syntax annotation -> TypePattern spanValue syntax (rewriteType annotation)
            RelationalPattern spanValue operator literal annotation ->
                RelationalPattern spanValue operator literal (rewriteType annotation)
            NotPattern spanValue nested annotation ->
                NotPattern spanValue (rewritePattern nested) (rewriteType annotation)
            AndPattern spanValue left right annotation ->
                AndPattern spanValue (rewritePattern left) (rewritePattern right) (rewriteType annotation)
            OrPattern spanValue left right annotation ->
                OrPattern spanValue (rewritePattern left) (rewritePattern right) (rewriteType annotation)
        rewriteType valueType = case valueType of
            NamedType (QualifiedName [Identifier "Box"]) arguments -> NamedType (qualified [replacement]) arguments
            NamedType name arguments -> NamedType name (map rewriteArgument arguments)
            FunctionType parameters result -> FunctionType (map rewriteType parameters) (rewriteType result)
            _ -> valueType
        rewriteArgument (TypeTemplateArgument nested) = TypeTemplateArgument (rewriteType nested)
        rewriteArgument value = value

countsVisitedTypes :: Bool
countsVisitedTypes = maybe False ((> 0) . visitedTemplateTypeNodes . templateDiscoveryStatistics) (discover boxParameterSource)

countsApplications :: Bool
countsApplications = maybe False ((== 2) . discoveredTemplateApplications . templateDiscoveryStatistics) (discover duplicateSource)

countsIgnoredTypes :: Bool
countsIgnoredTypes = maybe False ((> 0) . ignoredOrdinaryNamedTypes . templateDiscoveryStatistics) (discover boxParameterSource)

countsSkippedTemplates :: Bool
countsSkippedTemplates = maybe False ((== 2) . skippedOpenTemplateBodies . templateDiscoveryStatistics) (discover nestedSource)

originNamesOwner :: Bool
originNamesOwner = case discover boxParameterSource >>= onlyOrigin of
    Just origin -> resolvedSpelling (discoveryDeclaration origin) == Identifier "App"
    Nothing -> False

originNamesMember :: Bool
originNamesMember = case discover boxParameterSource >>= onlyOrigin of
    Just origin -> fmap resolvedSpelling (discoveryMember origin) == Just (Identifier "Use")
    Nothing -> False

originNamesParameterSite :: Bool
originNamesParameterSite = case discover boxParameterSource >>= onlyOrigin of
    Just origin -> ParameterTypeSite 0 `elem` discoverySites origin
    Nothing -> False

originNamesSourceFile :: Bool
originNamesSourceFile = case discover boxParameterSource >>= onlyOrigin of
    Just origin -> "template-discovery-test.tala" `isInfixOf` renderTemplateDiscoveryOrigin origin
    Nothing -> False

originHasCoordinates :: Bool
originHasCoordinates = case discover boxParameterSource >>= onlyOrigin of
    Just origin -> sourceLine (sourceStart (discoverySpan origin)) > 0 && sourceColumn (sourceStart (discoverySpan origin)) > 0
    Nothing -> False

compilerStoresDiscovery :: Bool
compilerStoresDiscovery = case compile boxParameterSource of
    Just artifacts -> not (null (discoveredTemplateDemands (artifactTemplateDemandDiscovery artifacts)))
    Nothing -> False

compilerPlansLayouts :: Bool
compilerPlansLayouts = case compile boxParameterSource of
    Just artifacts -> length (plannedTemplateSpecializations (artifactTemplateSpecializations artifacts)) == 1
    Nothing -> False

automaticLayoutOmitsMethods :: Bool
automaticLayoutOmitsMethods = case compile boxParameterSource >>= onlySpecialization of
    Just specialization -> case templateSpecializationDeclaration specialization of
        TypeDeclaration {typeMembers = members} -> null members
        _ -> False
    Nothing -> False

automaticPlanIsClosed :: Bool
automaticPlanIsClosed = case compile boxParameterSource >>= onlySpecialization of
    Just specialization -> templateSpecializationType specialization == NamedType (qualified ["Box"]) [TypeTemplateArgument intType]
    Nothing -> False

ordinaryProgramHasEmptyPlan :: Bool
ordinaryProgramHasEmptyPlan = case compile "class App { void Run() { return; } }" of
    Just artifacts -> null (plannedTemplateSpecializations (artifactTemplateSpecializations artifacts))
    Nothing -> False

defaultArgumentsAreMaterialized :: Bool
defaultArgumentsAreMaterialized = case compile source >>= onlySpecialization of
    Just specialization -> templateSpecializationType specialization == NamedType (qualified ["Box"]) [TypeTemplateArgument intType]
    Nothing -> False
    where
        source = "template<typename T = int> class Box {} class App { void Use(_ Box value) { return; } }"

mixedApplicationsStaySeparate :: Bool
mixedApplicationsStaySeparate = case compile source of
    Just artifacts -> length (plannedTemplateSpecializations (artifactTemplateSpecializations artifacts)) == 2
    Nothing -> False
    where
        source =
            "template<typename T, int N> class Buffer {} class App { void A(_ Buffer<int, 8> x) { return; } void B(_ Buffer<int, 16> x) { return; } }"

duplicateUsesCoalesceInPlan :: Bool
duplicateUsesCoalesceInPlan = case compile duplicateSource of
    Just artifacts -> length (plannedTemplateSpecializations (artifactTemplateSpecializations artifacts)) == 1
    Nothing -> False

duplicateUsesRetainOrigins :: Bool
duplicateUsesRetainOrigins = case compile duplicateSource >>= onlySpecialization of
    Just specialization -> length (templateSpecializationOrigins specialization) == 2
    Nothing -> False

discoveryDoesNotCoalesce :: Bool
discoveryDoesNotCoalesce = case compile duplicateSource of
    Just artifacts ->
        length (discoveredTemplateDemands (artifactTemplateDemandDiscovery artifacts)) == 2
            && length (plannedTemplateSpecializations (artifactTemplateSpecializations artifacts)) == 1
    Nothing -> False

nestedPlansHaveDependencyOrder :: Bool
nestedPlansHaveDependencyOrder = case compile nestedSource of
    Just artifacts ->
        let plan = artifactTemplateSpecializations artifacts
         in length (plannedTemplateSpecializations plan) == 2
                && length (specializationEmissionOrder plan) == 2
    Nothing -> False

templateOnlyPipelineIsEmpty :: Bool
templateOnlyPipelineIsEmpty = case compile "template<typename T> class Box { T Read(_ T value) { return value; } }" of
    Just artifacts -> null (plannedTemplateSpecializations (artifactTemplateSpecializations artifacts))
    Nothing -> False
