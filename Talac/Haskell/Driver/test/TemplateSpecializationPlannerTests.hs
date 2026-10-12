-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module TemplateSpecializationPlannerTests (templateSpecializationPlannerTests) where

import Data.List (isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Freshen
import Progmasoft.Tala.Template.Specialization

templateSpecializationPlannerTests :: [(String, Bool)]
templateSpecializationPlannerTests =
    [ ("planner materializes a concrete ordinary declaration", materializesOrdinaryDeclaration)
    , ("planner preserves the concrete specialization type", preservesConcreteType)
    , ("planner assigns positive stable specialization ids", assignsStableIds)
    , ("planner sorts specialization identities deterministically", sortsIdentities)
    , ("layout demand does not instantiate methods", layoutSkipsMethods)
    , ("member demand instantiates the selected method", memberSelectsMethod)
    , ("member demand selects every overload spelling", memberSelectsOverloads)
    , ("member demand excludes unrelated methods", memberExcludesUnrelated)
    , ("complete demand retains every member", completeRetainsMembers)
    , ("duplicate demands share one specialization", duplicateDemandCoalesces)
    , ("duplicate demands retain unique origins", duplicateOriginsCoalesce)
    , ("duplicate member demands merge their selections", duplicateMembersMerge)
    , ("complete demand dominates member demand", completeDominatesMember)
    , ("member demand dominates layout demand", memberDominatesLayout)
    , ("default and explicit arguments share an identity", defaultAndExplicitCoalesce)
    , ("value arguments create distinct specializations", valueArgumentsStayDistinct)
    , ("freshening replaces declaration symbols", freshensDeclarationSymbol)
    , ("freshening replaces member symbols", freshensMemberSymbol)
    , ("freshening replaces parameter symbols", freshensParameterSymbol)
    , ("freshening keeps parameter references coherent", freshensParameterReference)
    , ("freshening replaces local binding symbols", freshensLocalSymbol)
    , ("freshening keeps local references coherent", freshensLocalReference)
    , ("freshening preserves source spelling", fresheningPreservesSpelling)
    , ("freshening starts above every source symbol", fresheningStartsAboveSource)
    , ("separate specializations receive disjoint symbols", specializationSymbolsAreDisjoint)
    , ("closed TypedAST contains only materialized declarations", typedViewIsClosed)
    , ("closed TypedAST follows emission order", typedViewFollowsOrder)
    , ("dependency edges connect planned member types", dependencyEdgesAreAttached)
    , ("emission order places dependencies first", dependenciesEmitFirst)
    , ("reference-recursive specialization still emits once", recursiveDemandTerminates)
    , ("unknown templates report application failure", unknownTemplateIsRejected)
    , ("ambiguous templates report application failure", ambiguousTemplateIsRejected)
    , ("missing members are rejected", missingMemberIsRejected)
    , ("category mismatches are retained", categoryMismatchIsRejected)
    , ("too few arguments are retained", tooFewArgumentsAreRejected)
    , ("specialization count limit is enforced", specializationLimitIsEnforced)
    , ("origin count limit is enforced", originLimitIsEnforced)
    , ("member count limit is enforced", memberLimitIsEnforced)
    , ("invalid limits fail before planning", invalidLimitsAreRejected)
    , ("statistics count requests and unique entries", statisticsCountDemands)
    , ("statistics count selected members", statisticsCountMembers)
    , ("statistics count dependency edges", statisticsCountDependencies)
    , ("lookup by id returns the planned entry", lookupByIdWorks)
    , ("lookup by identity returns the planned entry", lookupByIdentityWorks)
    , ("missing specialization lookups return Nothing", missingLookupReturnsNothing)
    , ("rendering preserves demand origin", renderingIncludesOrigin)
    , ("rendering names a missing member", renderingNamesMember)
    , ("rendering explains a count limit", renderingExplainsLimit)
    , ("compiler bridge lowers selected members to verified Core", compilerBridgeLowersCore)
    , ("compiler bridge maps planning failures to diagnostics", compilerBridgeMapsDiagnostics)
    ]

data Fixture = Fixture
    { fixtureTyped :: TypedAST
    , fixturePlan :: TemplateSpecializationPlan
    }

qualified :: [String] -> QualifiedName
qualified = QualifiedName . map Identifier

typeArgument :: String -> TemplateArgument
typeArgument name = TypeTemplateArgument (namedType name)

valueArgument :: Integer -> TemplateArgument
valueArgument = ValueTemplateArgument . IntegerTemplateValue

demand :: String -> [TemplateArgument] -> TemplateDemandScope -> String -> TemplateSpecializationDemand
demand target arguments scope origin =
    TemplateSpecializationDemand
        (TemplateApplication (qualified [target]) arguments)
        scope
        origin

memberDemand :: String -> [TemplateArgument] -> [String] -> String -> TemplateSpecializationDemand
memberDemand target arguments names = demand target arguments (TemplateMemberDemand (map Identifier names))

analyze :: String -> Maybe TypedAST
analyze source = case analyzeSemantics (CompilerInput "specialization-planner-test.tala" source) of
    Right artifacts -> Just (semanticTypedAST artifacts)
    Left _ -> Nothing

plan :: String -> [TemplateSpecializationDemand] -> Either [TemplateSpecializationError] TemplateSpecializationPlan
plan source requests = case analyze source of
    Just typed -> planTemplateSpecializations defaultTemplateSpecializationLimits typed requests
    Nothing -> Left []

fixture :: Maybe Fixture
fixture = do
    typed <- analyze boxSource
    specializationPlan <-
        rightValue (planTemplateSpecializations defaultTemplateSpecializationLimits typed [boxIdentityDemand])
    pure (Fixture typed specializationPlan)

boxSource :: String
boxSource =
    "template<typename T> class Box { T Identity(_ T value) { T copy = value; return copy; } int Size() { return 1; } }"

boxIdentityDemand :: TemplateSpecializationDemand
boxIdentityDemand = memberDemand "Box" [typeArgument "String"] ["Identity"] "test:identity"

singleSpecialization :: TemplateSpecializationPlan -> Maybe TemplateSpecialization
singleSpecialization specializationPlan = case plannedTemplateSpecializations specializationPlan of
    [specialization] -> Just specialization
    _ -> Nothing

selectedMembers :: TemplateSpecialization -> [Declaration ResolvedName Type]
selectedMembers specialization = case templateSpecializationDeclaration specialization of
    TypeDeclaration {typeMembers = members} -> members
    _ -> []

selectedSpellings :: TemplateSpecialization -> [String]
selectedSpellings = map (identifierText . resolvedSpelling . declarationName) . selectedMembers

materializesOrdinaryDeclaration :: Bool
materializesOrdinaryDeclaration = case fixture >>= singleSpecialization . fixturePlan of
    Just TemplateSpecialization {templateSpecializationDeclaration = TypeDeclaration {}} -> True
    _ -> False

preservesConcreteType :: Bool
preservesConcreteType = case fixture >>= singleSpecialization . fixturePlan of
    Just specialization ->
        templateSpecializationType specialization
            == NamedType (qualified ["Box"]) [typeArgument "String"]
    Nothing -> False

assignsStableIds :: Bool
assignsStableIds = case plan boxSource requests of
    Right specializationPlan ->
        map (templateSpecializationIdValue . templateSpecializationId) (plannedTemplateSpecializations specializationPlan)
            == [1, 2]
    Left _ -> False
    where
        requests =
            [ memberDemand "Box" [typeArgument "String"] ["Identity"] "string"
            , memberDemand "Box" [typeArgument "int"] ["Identity"] "int"
            ]

sortsIdentities :: Bool
sortsIdentities = case plan boxSource requests of
    Right specializationPlan ->
        let identities = map templateSpecializationIdentity (plannedTemplateSpecializations specializationPlan)
         in identities == ordered identities
    Left _ -> False
    where
        requests =
            [ memberDemand "Box" [typeArgument "String"] ["Identity"] "later"
            , memberDemand "Box" [typeArgument "bool"] ["Identity"] "earlier"
            ]

layoutSkipsMethods :: Bool
layoutSkipsMethods = case plan boxSource [demand "Box" [typeArgument "String"] TemplateLayoutDemand "layout"] of
    Right value -> maybe False (null . selectedMembers) (singleSpecialization value)
    Left _ -> False

memberSelectsMethod :: Bool
memberSelectsMethod = case fixture >>= singleSpecialization . fixturePlan of
    Just specialization -> selectedSpellings specialization == ["Identity"]
    Nothing -> False

memberSelectsOverloads :: Bool
memberSelectsOverloads = case analyze source >>= duplicateReadMember of
    Just typed -> case planTemplateSpecializations defaultTemplateSpecializationLimits typed requests of
        Right value -> maybe False ((== ["Read", "Read"]) . selectedSpellings) (singleSpecialization value)
        Left _ -> False
    Nothing -> False
    where
        source =
            "template<typename T> class Box { T Read(_ T value) { return value; } void Skip() { return; } }"
        requests = [memberDemand "Box" [typeArgument "int"] ["Read"] "overload"]

duplicateReadMember :: TypedAST -> Maybe TypedAST
duplicateReadMember typed@(TypedAST tree) = case syntaxDeclarations tree of
    [declaration@TemplateTypeDeclaration {typeMembers = readMember : remaining}] ->
        let SymbolId maximumSource = maximumSymbolInTypedAST typed
            duplicate =
                readMember
                    { declarationName =
                        ResolvedName (SymbolId (maximumSource + 1)) (resolvedSpelling (declarationName readMember))
                    }
         in Just (TypedAST tree {syntaxDeclarations = [declaration {typeMembers = readMember : duplicate : remaining}]})
    _ -> Nothing

memberExcludesUnrelated :: Bool
memberExcludesUnrelated = case fixture >>= singleSpecialization . fixturePlan of
    Just specialization -> "Size" `notElem` selectedSpellings specialization
    Nothing -> False

completeRetainsMembers :: Bool
completeRetainsMembers = case plan boxSource [demand "Box" [typeArgument "String"] TemplateCompleteDemand "complete"] of
    Right value -> maybe False ((== ["Identity", "Size"]) . selectedSpellings) (singleSpecialization value)
    Left _ -> False

duplicateDemandCoalesces :: Bool
duplicateDemandCoalesces = case plan boxSource [boxIdentityDemand, boxIdentityDemand] of
    Right value -> length (plannedTemplateSpecializations value) == 1
    Left _ -> False

duplicateOriginsCoalesce :: Bool
duplicateOriginsCoalesce = case plan boxSource requests of
    Right value -> case singleSpecialization value of
        Just specialization -> templateSpecializationOrigins specialization == ["first", "second"]
        Nothing -> False
    Left _ -> False
    where
        requests =
            [ memberDemand "Box" [typeArgument "String"] ["Identity"] "first"
            , memberDemand "Box" [typeArgument "String"] ["Identity"] "second"
            , memberDemand "Box" [typeArgument "String"] ["Identity"] "first"
            ]

duplicateMembersMerge :: Bool
duplicateMembersMerge = case plan boxSource requests of
    Right value -> maybe False ((== ["Identity", "Size"]) . selectedSpellings) (singleSpecialization value)
    Left _ -> False
    where
        requests =
            [ memberDemand "Box" [typeArgument "String"] ["Identity"] "identity"
            , memberDemand "Box" [typeArgument "String"] ["Size"] "size"
            ]

completeDominatesMember :: Bool
completeDominatesMember = case plan boxSource requests of
    Right value -> maybe False ((== TemplateCompleteDemand) . templateSpecializationScope) (singleSpecialization value)
    Left _ -> False
    where
        requests =
            [ boxIdentityDemand
            , demand "Box" [typeArgument "String"] TemplateCompleteDemand "complete"
            ]

memberDominatesLayout :: Bool
memberDominatesLayout = case plan boxSource requests of
    Right value -> maybe False ((== ["Identity"]) . selectedSpellings) (singleSpecialization value)
    Left _ -> False
    where
        requests =
            [ demand "Box" [typeArgument "String"] TemplateLayoutDemand "layout"
            , boxIdentityDemand
            ]

defaultAndExplicitCoalesce :: Bool
defaultAndExplicitCoalesce = case plan source requests of
    Right value -> length (plannedTemplateSpecializations value) == 1
    Left _ -> False
    where
        source = "template<typename T = int> class Box { T Read(_ T value) { return value; } }"
        requests =
            [ memberDemand "Box" [] ["Read"] "default"
            , memberDemand "Box" [typeArgument "int"] ["Read"] "explicit"
            ]

valueArgumentsStayDistinct :: Bool
valueArgumentsStayDistinct = case plan source requests of
    Right value -> length (plannedTemplateSpecializations value) == 2
    Left _ -> False
    where
        source = "template<int N> class Buffer { int Size() { return 1; } }"
        requests =
            [ memberDemand "Buffer" [valueArgument 4] ["Size"] "four"
            , memberDemand "Buffer" [valueArgument 8] ["Size"] "eight"
            ]

freshensDeclarationSymbol :: Bool
freshensDeclarationSymbol = case (fixture, fixture >>= singleSpecialization . fixturePlan) of
    (Just value, Just specialization) ->
        sourceDeclarationSymbol (fixtureTyped value) /= declarationSymbol (templateSpecializationDeclaration specialization)
    _ -> False

freshensMemberSymbol :: Bool
freshensMemberSymbol = case (fixture, fixture >>= singleSpecialization . fixturePlan) of
    (Just value, Just specialization) -> case (sourceMemberSymbol (fixtureTyped value), selectedMembers specialization) of
        (Just old, [member]) -> old /= resolvedSymbol (declarationName member)
        _ -> False
    _ -> False

freshensParameterSymbol :: Bool
freshensParameterSymbol = case fixture >>= singleSpecialization . fixturePlan of
    Just specialization -> case selectedMembers specialization of
        [FunctionDeclaration {declarationParameters = [parameter]}] ->
            resolvedSymbol (parameterName parameter) `elem` map snd (templateSpecializationSymbolMap specialization)
        _ -> False
    Nothing -> False

freshensParameterReference :: Bool
freshensParameterReference = case fixture >>= singleSpecialization . fixturePlan of
    Just specialization -> case selectedMembers specialization of
        [ FunctionDeclaration
                { declarationParameters = [parameter]
                , declarationBody = Block (BindingStatement _ _ _ _ _ (NameExpression _ reference _) : _)
                }
            ] ->
                resolvedSymbol (parameterName parameter) == resolvedSymbol reference
        _ -> False
    Nothing -> False

freshensLocalSymbol :: Bool
freshensLocalSymbol = case fixture >>= singleSpecialization . fixturePlan of
    Just specialization -> case selectedMembers specialization of
        [FunctionDeclaration {declarationBody = Block (BindingStatement _ _ _ local _ _ : _)}] ->
            resolvedSymbol local `elem` map snd (templateSpecializationSymbolMap specialization)
        _ -> False
    Nothing -> False

freshensLocalReference :: Bool
freshensLocalReference = case fixture >>= singleSpecialization . fixturePlan of
    Just specialization -> case selectedMembers specialization of
        [ FunctionDeclaration
                { declarationBody = Block [BindingStatement _ _ _ local _ _, ReturnStatement _ (Just (NameExpression _ reference _))]
                }
            ] ->
                resolvedSymbol local == resolvedSymbol reference
        _ -> False
    Nothing -> False

fresheningPreservesSpelling :: Bool
fresheningPreservesSpelling = case fixture >>= singleSpecialization . fixturePlan of
    Just specialization ->
        identifierText (resolvedSpelling (declarationName (templateSpecializationDeclaration specialization))) == "Box"
            && selectedSpellings specialization == ["Identity"]
    Nothing -> False

fresheningStartsAboveSource :: Bool
fresheningStartsAboveSource = case (fixture, fixture >>= singleSpecialization . fixturePlan) of
    (Just value, Just specialization) ->
        let SymbolId maximumSource = maximumSymbolInTypedAST (fixtureTyped value)
            generated = map (symbolIdValue . snd) (templateSpecializationSymbolMap specialization)
         in not (null generated) && all (> maximumSource) generated
    _ -> False

specializationSymbolsAreDisjoint :: Bool
specializationSymbolsAreDisjoint = case plan boxSource requests of
    Right value -> case plannedTemplateSpecializations value of
        [left, right] ->
            let leftSymbols = map snd (templateSpecializationSymbolMap left)
                rightSymbols = map snd (templateSpecializationSymbolMap right)
             in null [symbol | symbol <- leftSymbols, symbol `elem` rightSymbols]
        _ -> False
    Left _ -> False
    where
        requests =
            [ boxIdentityDemand
            , memberDemand "Box" [typeArgument "int"] ["Identity"] "int"
            ]

typedViewIsClosed :: Bool
typedViewIsClosed = case fixture of
    Just value -> case syntaxDeclarations (typedSyntaxTree (specializationTypedAST (fixturePlan value))) of
        [TypeDeclaration {}] -> True
        _ -> False
    Nothing -> False

typedViewFollowsOrder :: Bool
typedViewFollowsOrder = case plan boxSource requests of
    Right value ->
        length (syntaxDeclarations (typedSyntaxTree (specializationTypedAST value)))
            == length (specializationEmissionOrder value)
    Left _ -> False
    where
        requests =
            [ boxIdentityDemand
            , memberDemand "Box" [typeArgument "int"] ["Identity"] "int"
            ]

dependencySource :: String
dependencySource =
    "template<typename T> class Leaf { T Read(_ T value) { return value; } } "
        ++ "template<typename T> class Holder { Leaf<T> Make(_ Leaf<T> value) { return value; } }"

dependencyRequests :: [TemplateSpecializationDemand]
dependencyRequests =
    [ memberDemand "Holder" [typeArgument "String"] ["Make"] "holder"
    , memberDemand "Leaf" [typeArgument "String"] ["Read"] "leaf"
    ]

dependencyEdgesAreAttached :: Bool
dependencyEdgesAreAttached = case plan dependencySource dependencyRequests of
    Right value -> case findByTarget "Holder" value of
        Just specialization -> length (templateSpecializationDependencies specialization) == 1
        Nothing -> False
    Left _ -> False

dependenciesEmitFirst :: Bool
dependenciesEmitFirst = case plan dependencySource dependencyRequests of
    Right value -> case (findByTarget "Holder" value, findByTarget "Leaf" value) of
        (Just holder, Just leaf) ->
            before
                (templateSpecializationId leaf)
                (templateSpecializationId holder)
                (specializationEmissionOrder value)
        _ -> False
    Left _ -> False

recursiveDemandTerminates :: Bool
recursiveDemandTerminates = case plan source requests of
    Right value -> length (specializationEmissionOrder value) == 1
    Left _ -> False
    where
        source = "template<typename T> class Node { Node<T> Next(_ Node<T> value) { return value; } }"
        requests = [memberDemand "Node" [typeArgument "String"] ["Next"] "recursive"]

unknownTemplateIsRejected :: Bool
unknownTemplateIsRejected = case plan boxSource [demand "Missing" [] TemplateLayoutDemand "unknown-site"] of
    Left [TemplateApplicationFailed "unknown-site" [UnknownTemplateDeclaration {}]] -> True
    _ -> False

ambiguousTemplateIsRejected :: Bool
ambiguousTemplateIsRejected = case analyze source >>= duplicateTopTemplate of
    Just typed -> case planTemplateSpecializations defaultTemplateSpecializationLimits typed requests of
        Left [TemplateApplicationFailed _ [AmbiguousTemplateDeclaration {}]] -> True
        _ -> False
    Nothing -> False
    where
        source = "template<typename T> class Box {}"
        requests = [demand "Box" [typeArgument "int"] TemplateLayoutDemand "ambiguous"]

duplicateTopTemplate :: TypedAST -> Maybe TypedAST
duplicateTopTemplate (TypedAST tree) = case syntaxDeclarations tree of
    [declaration@TemplateTypeDeclaration {}] ->
        Just (TypedAST tree {syntaxDeclarations = [declaration, declaration]})
    _ -> Nothing

missingMemberIsRejected :: Bool
missingMemberIsRejected = case plan boxSource [memberDemand "Box" [typeArgument "String"] ["Missing"] "member"] of
    Left [TemplateMemberNotFound _ (Identifier "Missing")] -> True
    _ -> False

categoryMismatchIsRejected :: Bool
categoryMismatchIsRejected = case plan boxSource [demand "Box" [valueArgument 1] TemplateLayoutDemand "category"] of
    Left [TemplateApplicationFailed _ [TemplateArgumentCategoryMismatch {}]] -> True
    _ -> False

tooFewArgumentsAreRejected :: Bool
tooFewArgumentsAreRejected = case plan boxSource [demand "Box" [] TemplateLayoutDemand "arity"] of
    Left [TemplateApplicationFailed _ [TooFewTemplateArguments {}]] -> True
    _ -> False

specializationLimitIsEnforced :: Bool
specializationLimitIsEnforced = case analyze boxSource of
    Just typed -> case planTemplateSpecializations limits typed requests of
        Left [TemplateSpecializationLimitExceeded 1 _] -> True
        _ -> False
    Nothing -> False
    where
        limits = defaultTemplateSpecializationLimits {maximumTemplateSpecializations = 1}
        requests =
            [ memberDemand "Box" [typeArgument "int"] ["Identity"] "one"
            , memberDemand "Box" [typeArgument "String"] ["Identity"] "two"
            ]

originLimitIsEnforced :: Bool
originLimitIsEnforced = case analyze boxSource of
    Just typed -> case planTemplateSpecializations limits typed requests of
        Left [TemplateOriginLimitExceeded 1 "second"] -> True
        _ -> False
    Nothing -> False
    where
        limits = defaultTemplateSpecializationLimits {maximumTemplateOrigins = 1}
        requests =
            [ memberDemand "Box" [typeArgument "String"] ["Identity"] "first"
            , memberDemand "Box" [typeArgument "String"] ["Identity"] "second"
            ]

memberLimitIsEnforced :: Bool
memberLimitIsEnforced = case analyze boxSource of
    Just typed -> case planTemplateSpecializations limits typed requests of
        Left [TemplateMemberLimitExceeded _ 1 2] -> True
        _ -> False
    Nothing -> False
    where
        limits = defaultTemplateSpecializationLimits {maximumMembersPerSpecialization = 1}
        requests = [demand "Box" [typeArgument "String"] TemplateCompleteDemand "complete"]

invalidLimitsAreRejected :: Bool
invalidLimitsAreRejected = case analyze boxSource of
    Just typed -> case planTemplateSpecializations invalid typed [boxIdentityDemand] of
        Left [InvalidTemplateSpecializationLimits _] -> True
        _ -> False
    Nothing -> False
    where
        invalid = defaultTemplateSpecializationLimits {maximumTemplateSpecializations = 0}

statisticsCountDemands :: Bool
statisticsCountDemands = case plan boxSource [boxIdentityDemand, boxIdentityDemand] of
    Right value ->
        let statistics = plannedTemplateStatistics value
         in requestedTemplateSpecializations statistics == 2
                && uniqueTemplateSpecializations statistics == 1
                && coalescedTemplateSpecializations statistics == 1
    Left _ -> False

statisticsCountMembers :: Bool
statisticsCountMembers = case plan boxSource [demand "Box" [typeArgument "String"] TemplateCompleteDemand "complete"] of
    Right value -> instantiatedTemplateMembers (plannedTemplateStatistics value) == 2
    Left _ -> False

statisticsCountDependencies :: Bool
statisticsCountDependencies = case plan dependencySource dependencyRequests of
    Right value -> templateDependencyEdges (plannedTemplateStatistics value) == 1
    Left _ -> False

lookupByIdWorks :: Bool
lookupByIdWorks = case fixture of
    Just value -> case specializationEmissionOrder (fixturePlan value) of
        identifier : _ -> findTemplateSpecialization identifier (fixturePlan value) /= Nothing
        [] -> False
    Nothing -> False

lookupByIdentityWorks :: Bool
lookupByIdentityWorks = case fixture >>= singleSpecialization . fixturePlan of
    Just specialization -> case fixture of
        Just value ->
            findTemplateSpecializationByIdentity (templateSpecializationIdentity specialization) (fixturePlan value)
                == Just specialization
        Nothing -> False
    Nothing -> False

missingLookupReturnsNothing :: Bool
missingLookupReturnsNothing = case fixture of
    Just value ->
        findTemplateSpecialization (TemplateSpecializationId 999) (fixturePlan value) == Nothing
            && findTemplateSpecializationByIdentity "missing" (fixturePlan value) == Nothing
    Nothing -> False

renderingIncludesOrigin :: Bool
renderingIncludesOrigin =
    "source:42"
        `isInfixOf` renderTemplateSpecializationError
            (TemplateApplicationFailed "source:42" [UnknownTemplateDeclaration (qualified ["Missing"])])

renderingNamesMember :: Bool
renderingNamesMember =
    "member named Read"
        `isInfixOf` renderTemplateSpecializationError
            (TemplateMemberNotFound (qualified ["Box"]) (Identifier "Read"))

renderingExplainsLimit :: Bool
renderingExplainsLimit =
    "limit 4"
        `isInfixOf` renderTemplateSpecializationError
            (TemplateSpecializationLimitExceeded 4 "Box<String>")

compilerBridgeLowersCore :: Bool
compilerBridgeLowersCore = case analyze boxSource of
    Just typed -> case compileTemplateSpecializations defaultTemplateSpecializationLimits typed [boxIdentityDemand] of
        Right (_, core) -> case coreModuleFunctions core of
            [function] -> identifierText (resolvedSpelling (coreFunctionName function)) == "Identity"
            _ -> False
        Left _ -> False
    Nothing -> False

compilerBridgeMapsDiagnostics :: Bool
compilerBridgeMapsDiagnostics = case analyze boxSource of
    Just typed -> case compileTemplateSpecializations defaultTemplateSpecializationLimits typed requests of
        Left [problem] ->
            diagnosticStage problem == TypeCheckerStage
                && "unknown template declaration Missing" `isInfixOf` diagnosticMessage problem
        Left _ -> False
        Right _ -> False
    Nothing -> False
    where
        requests = [demand "Missing" [] TemplateLayoutDemand "bridge"]

sourceDeclarationSymbol :: TypedAST -> SymbolId
sourceDeclarationSymbol (TypedAST tree) = case syntaxDeclarations tree of
    declaration : _ -> resolvedSymbol (declarationName declaration)
    [] -> SymbolId 0

sourceMemberSymbol :: TypedAST -> Maybe SymbolId
sourceMemberSymbol (TypedAST tree) = case syntaxDeclarations tree of
    TemplateTypeDeclaration {typeMembers = member : _} : _ -> Just (resolvedSymbol (declarationName member))
    _ -> Nothing

declarationSymbol :: Declaration ResolvedName Type -> SymbolId
declarationSymbol = resolvedSymbol . declarationName

findByTarget :: String -> TemplateSpecializationPlan -> Maybe TemplateSpecialization
findByTarget target specializationPlan =
    first matching (plannedTemplateSpecializations specializationPlan)
    where
        matching specialization = case templateSpecializationType specialization of
            NamedType (QualifiedName parts) _ -> case reverse parts of
                Identifier name : _ -> name == target
                [] -> False
            _ -> False

before :: (Eq value) => value -> value -> [value] -> Bool
before left right values = case (position left values, position right values) of
    (Just leftIndex, Just rightIndex) -> leftIndex < rightIndex
    _ -> False

position :: (Eq value) => value -> [value] -> Maybe Int
position needle = go 0
    where
        go _ [] = Nothing
        go index (value : remaining)
            | value == needle = Just index
            | otherwise = go (index + 1) remaining

ordered :: (Ord value) => [value] -> [value]
ordered [] = []
ordered (value : remaining) =
    ordered [candidate | candidate <- remaining, candidate <= value]
        ++ [value]
        ++ ordered [candidate | candidate <- remaining, candidate > value]

first :: (value -> Bool) -> [value] -> Maybe value
first _ [] = Nothing
first predicate (value : remaining)
    | predicate value = Just value
    | otherwise = first predicate remaining

rightValue :: Either failure value -> Maybe value
rightValue result = case result of
    Right value -> Just value
    Left _ -> Nothing
