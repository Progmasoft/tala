-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module TemplatePlanVerifierTests (templatePlanVerifierTests) where

import Data.List (isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Mangling
import Progmasoft.Tala.Template.Specialization
import Progmasoft.Tala.Template.Specialization.Verifier

templatePlanVerifierTests :: [(String, Bool)]
templatePlanVerifierTests =
    [ ("plan verifier accepts planner output", acceptsPlannerOutput)
    , ("plan verifier accepts the empty plan", acceptsEmptyPlan)
    , ("plan verifier rejects a zero specialization id", rejectsZeroId)
    , ("plan verifier rejects a negative specialization id", rejectsNegativeId)
    , ("plan verifier rejects duplicate specialization ids", rejectsDuplicateIds)
    , ("plan verifier rejects an empty canonical identity", rejectsEmptyIdentity)
    , ("plan verifier rejects duplicate canonical identities", rejectsDuplicateIdentities)
    , ("plan verifier rejects an open specialization type", rejectsOpenType)
    , ("plan verifier rejects ErrorType specialization", rejectsErrorType)
    , ("plan verifier requires an ordinary type declaration", rejectsFunctionDeclaration)
    , ("plan verifier checks declaration annotation", rejectsDeclarationMismatch)
    , ("plan verifier rejects an empty origin", rejectsEmptyOrigin)
    , ("plan verifier rejects duplicate origins", rejectsDuplicateOrigins)
    , ("plan verifier rejects a missing dependency", rejectsMissingDependency)
    , ("plan verifier rejects duplicate dependencies", rejectsDuplicateDependencies)
    , ("plan verifier rejects direct self dependency", rejectsSelfDependency)
    , ("plan verifier rejects zero fresh source symbols", rejectsZeroFreshSource)
    , ("plan verifier rejects zero fresh target symbols", rejectsZeroFreshTarget)
    , ("plan verifier rejects identity fresh mappings", rejectsIdentityFreshMap)
    , ("plan verifier rejects duplicate fresh sources", rejectsDuplicateFreshSources)
    , ("plan verifier rejects duplicate fresh targets", rejectsDuplicateFreshTargets)
    , ("plan verifier requires every declaration symbol in the fresh map", rejectsMissingDeclarationSymbol)
    , ("plan verifier rejects layout plans containing members", rejectsLayoutWithMembers)
    , ("plan verifier checks requested member presence", rejectsMissingRequestedMember)
    , ("plan verifier checks unrequested member presence", rejectsUnexpectedMember)
    , ("plan verifier rejects an invalid mangled type", rejectsInvalidMangledType)
    , ("plan verifier checks recomputed mangled types", rejectsIncorrectMangledType)
    , ("plan verifier requires a mangled name per member", rejectsMissingMangledMember)
    , ("plan verifier rejects an invalid mangled member", rejectsInvalidMangledMember)
    , ("plan verifier rejects duplicate mangled members", rejectsDuplicateMangledMember)
    , ("plan verifier rejects an unknown mangled member", rejectsUnexpectedMangledMember)
    , ("plan verifier checks recomputed mangled members", rejectsIncorrectMangledMember)
    , ("plan verifier checks aggregate statistics", rejectsIncorrectStatistics)
    , ("plan verifier detects incomplete emission identity coverage", rejectsIncompleteEmissionCoverage)
    , ("issue rendering names the specialization id", renderingNamesSpecialization)
    , ("issue rendering explains mangled symbol mismatch", renderingExplainsMangledMismatch)
    , ("issue rendering explains fresh symbol ownership", renderingExplainsSharedFreshSymbol)
    ]

qualified :: [String] -> QualifiedName
qualified = QualifiedName . map Identifier

resolved :: Int -> String -> ResolvedName
resolved unique spelling = ResolvedName (SymbolId unique) (Identifier spelling)

typeArgument :: String -> TemplateArgument
typeArgument name = TypeTemplateArgument (namedType name)

request :: TemplateSpecializationDemand
request =
    TemplateSpecializationDemand
        (TemplateApplication (qualified ["Box"]) [typeArgument "String"])
        (TemplateMemberDemand [Identifier "Identity"])
        "verifier-test:request"

source :: String
source =
    unlines
        [ "template<typename T> class Box {"
        , "    T Identity(_ T value) { T copy = value; return copy; }"
        , "    int Size() { return 1; }"
        , "}"
        ]

validPlan :: Maybe TemplateSpecializationPlan
validPlan = case analyzeSemantics (CompilerInput "template-plan-verifier-test.tala" source) of
    Right artifacts -> case planTemplateSpecializations defaultTemplateSpecializationLimits (semanticTypedAST artifacts) [request] of
        Right plan -> Just plan
        Left _ -> Nothing
    Left _ -> Nothing

emptyPlan :: TemplateSpecializationPlan
emptyPlan = TemplateSpecializationPlan Nothing [] (TemplateSpecializationStatistics 0 0 0 0 0 0)

onlySpecialization :: TemplateSpecializationPlan -> Maybe TemplateSpecialization
onlySpecialization plan = case plannedTemplateSpecializations plan of
    [specialization] -> Just specialization
    _ -> Nothing

rewriteOnly ::
    (TemplateSpecialization -> TemplateSpecialization) -> TemplateSpecializationPlan -> TemplateSpecializationPlan
rewriteOnly rewrite plan = plan {plannedTemplateSpecializations = map rewrite (plannedTemplateSpecializations plan)}

issuesAfter :: (TemplateSpecialization -> TemplateSpecialization) -> [TemplatePlanIssue]
issuesAfter rewrite = maybe [] (templateSpecializationPlanIssues . rewriteOnly rewrite) validPlan

hasIssue :: (TemplatePlanIssue -> Bool) -> [TemplatePlanIssue] -> Bool
hasIssue predicate = any predicate

acceptsPlannerOutput :: Bool
acceptsPlannerOutput = case validPlan of
    Just plan -> verifyTemplateSpecializationPlan plan == Right plan
    Nothing -> False

acceptsEmptyPlan :: Bool
acceptsEmptyPlan = verifyTemplateSpecializationPlan emptyPlan == Right emptyPlan

rejectsZeroId :: Bool
rejectsZeroId = hasIssue isInvalid (issuesAfter (\value -> value {templateSpecializationId = TemplateSpecializationId 0}))
    where
        isInvalid (InvalidPlanSpecializationId (TemplateSpecializationId 0)) = True
        isInvalid _ = False

rejectsNegativeId :: Bool
rejectsNegativeId = hasIssue isInvalid (issuesAfter (\value -> value {templateSpecializationId = TemplateSpecializationId (-7)}))
    where
        isInvalid (InvalidPlanSpecializationId (TemplateSpecializationId (-7))) = True
        isInvalid _ = False

rejectsDuplicateIds :: Bool
rejectsDuplicateIds = case validPlan >>= onlySpecialization of
    Just specialization ->
        let plan = maybe emptyPlan id validPlan
            duplicate = specialization {templateSpecializationIdentity = templateSpecializationIdentity specialization ++ ":copy"}
         in hasIssue
                isDuplicate
                (templateSpecializationPlanIssues plan {plannedTemplateSpecializations = [specialization, duplicate]})
    Nothing -> False
    where
        isDuplicate (DuplicatePlanSpecializationId _) = True
        isDuplicate _ = False

rejectsEmptyIdentity :: Bool
rejectsEmptyIdentity = hasIssue isEmpty (issuesAfter (\value -> value {templateSpecializationIdentity = ""}))
    where
        isEmpty (EmptyPlanSpecializationIdentity _) = True
        isEmpty _ = False

rejectsDuplicateIdentities :: Bool
rejectsDuplicateIdentities = case validPlan >>= onlySpecialization of
    Just specialization ->
        let plan = maybe emptyPlan id validPlan
            duplicate = specialization {templateSpecializationId = TemplateSpecializationId 2}
         in hasIssue
                isDuplicate
                (templateSpecializationPlanIssues plan {plannedTemplateSpecializations = [specialization, duplicate]})
    Nothing -> False
    where
        isDuplicate (DuplicatePlanSpecializationIdentity _) = True
        isDuplicate _ = False

rejectsOpenType :: Bool
rejectsOpenType = hasIssue isOpen (issuesAfter rewrite)
    where
        open = TypeVariable (resolved 500 "T")
        rewrite value = value {templateSpecializationType = open}
        isOpen (PlanSpecializationTypeIsOpen _ symbols) = SymbolId 500 `elem` symbols
        isOpen _ = False

rejectsErrorType :: Bool
rejectsErrorType = hasIssue isError (issuesAfter (\value -> value {templateSpecializationType = ErrorType}))
    where
        isError (PlanSpecializationTypeHasError _) = True
        isError _ = False

rejectsFunctionDeclaration :: Bool
rejectsFunctionDeclaration = case validPlan >>= onlySpecialization of
    Just specialization -> case templateSpecializationDeclaration specialization of
        TypeDeclaration {typeMembers = member : _} ->
            hasIssue isWrong (issuesAfter (\value -> value {templateSpecializationDeclaration = member}))
        _ -> False
    Nothing -> False
    where
        isWrong (PlanDeclarationIsNotClosedType _) = True
        isWrong _ = False

rejectsDeclarationMismatch :: Bool
rejectsDeclarationMismatch = hasIssue isMismatch (issuesAfter rewrite)
    where
        rewrite value = value {templateSpecializationDeclaration = setAnnotation intType (templateSpecializationDeclaration value)}
        isMismatch (PlanDeclarationTypeMismatch _ _ _) = True
        isMismatch _ = False

setAnnotation :: Type -> Declaration ResolvedName Type -> Declaration ResolvedName Type
setAnnotation annotation declaration = case declaration of
    TypeDeclaration spanValue name _ members -> TypeDeclaration spanValue name annotation members
    other -> other

rejectsEmptyOrigin :: Bool
rejectsEmptyOrigin = hasIssue isEmpty (issuesAfter (\value -> value {templateSpecializationOrigins = [""]}))
    where
        isEmpty (EmptyPlanOrigin _) = True
        isEmpty _ = False

rejectsDuplicateOrigins :: Bool
rejectsDuplicateOrigins = hasIssue isDuplicate (issuesAfter (\value -> value {templateSpecializationOrigins = ["same", "same"]}))
    where
        isDuplicate (DuplicatePlanOrigin _ "same") = True
        isDuplicate _ = False

rejectsMissingDependency :: Bool
rejectsMissingDependency =
    hasIssue isMissing (issuesAfter (\value -> value {templateSpecializationDependencies = [TemplateSpecializationId 99]}))
    where
        isMissing (MissingPlanDependency _ (TemplateSpecializationId 99)) = True
        isMissing _ = False

rejectsDuplicateDependencies :: Bool
rejectsDuplicateDependencies = hasIssue isDuplicate (issuesAfter rewrite)
    where
        rewrite value = value {templateSpecializationDependencies = [TemplateSpecializationId 99, TemplateSpecializationId 99]}
        isDuplicate (DuplicatePlanDependency _ (TemplateSpecializationId 99)) = True
        isDuplicate _ = False

rejectsSelfDependency :: Bool
rejectsSelfDependency = hasIssue isSelf (issuesAfter rewrite)
    where
        rewrite value = value {templateSpecializationDependencies = [templateSpecializationId value]}
        isSelf (SelfPlanDependency _) = True
        isSelf _ = False

rejectsZeroFreshSource :: Bool
rejectsZeroFreshSource = hasIssue isInvalid (issuesAfter replaceFirst)
    where
        replaceFirst value = value {templateSpecializationSymbolMap = replaceSource (SymbolId 0) (templateSpecializationSymbolMap value)}
        isInvalid (InvalidFreshSymbol _ (SymbolId 0) _) = True
        isInvalid _ = False

rejectsZeroFreshTarget :: Bool
rejectsZeroFreshTarget = hasIssue isInvalid (issuesAfter replaceFirst)
    where
        replaceFirst value = value {templateSpecializationSymbolMap = replaceTarget (SymbolId 0) (templateSpecializationSymbolMap value)}
        isInvalid (InvalidFreshSymbol _ _ (SymbolId 0)) = True
        isInvalid _ = False

rejectsIdentityFreshMap :: Bool
rejectsIdentityFreshMap = hasIssue isInvalid (issuesAfter replaceFirst)
    where
        replaceFirst value = case templateSpecializationSymbolMap value of
            (old, _) : rest -> value {templateSpecializationSymbolMap = (old, old) : rest}
            [] -> value
        isInvalid (InvalidFreshSymbol _ old new) = old == new
        isInvalid _ = False

replaceSource :: SymbolId -> [(SymbolId, SymbolId)] -> [(SymbolId, SymbolId)]
replaceSource replacement mappings = case mappings of
    (_, target) : rest -> (replacement, target) : rest
    [] -> []

replaceTarget :: SymbolId -> [(SymbolId, SymbolId)] -> [(SymbolId, SymbolId)]
replaceTarget replacement mappings = case mappings of
    (sourceSymbol, _) : rest -> (sourceSymbol, replacement) : rest
    [] -> []

rejectsDuplicateFreshSources :: Bool
rejectsDuplicateFreshSources = hasIssue isDuplicate (issuesAfter duplicateFirst)
    where
        duplicateFirst value = case templateSpecializationSymbolMap value of
            first : second : rest -> value {templateSpecializationSymbolMap = first : (fst first, snd second) : rest}
            _ -> value
        isDuplicate (DuplicateFreshSourceSymbol _ _) = True
        isDuplicate _ = False

rejectsDuplicateFreshTargets :: Bool
rejectsDuplicateFreshTargets = hasIssue isDuplicate (issuesAfter duplicateFirst)
    where
        duplicateFirst value = case templateSpecializationSymbolMap value of
            first : second : rest -> value {templateSpecializationSymbolMap = first : (fst second, snd first) : rest}
            _ -> value
        isDuplicate (DuplicateFreshTargetSymbol _ _) = True
        isDuplicate _ = False

rejectsMissingDeclarationSymbol :: Bool
rejectsMissingDeclarationSymbol = hasIssue isMissing (issuesAfter (\value -> value {templateSpecializationSymbolMap = []}))
    where
        isMissing (DeclarationSymbolMissingFromFreshMap _ _) = True
        isMissing _ = False

rejectsLayoutWithMembers :: Bool
rejectsLayoutWithMembers = hasIssue isLayout (issuesAfter (\value -> value {templateSpecializationScope = TemplateLayoutDemand}))
    where
        isLayout (LayoutPlanContainsMembers _ count) = count > 0
        isLayout _ = False

rejectsMissingRequestedMember :: Bool
rejectsMissingRequestedMember = hasIssue isMissing (issuesAfter rewrite)
    where
        rewrite value = value {templateSpecializationScope = TemplateMemberDemand [Identifier "Missing"]}
        isMissing (RequestedPlanMemberMissing _ (Identifier "Missing")) = True
        isMissing _ = False

rejectsUnexpectedMember :: Bool
rejectsUnexpectedMember = hasIssue isUnexpected (issuesAfter rewrite)
    where
        rewrite value = value {templateSpecializationScope = TemplateMemberDemand []}
        isUnexpected (UnexpectedPlanMember _ (Identifier "Identity")) = True
        isUnexpected _ = False

rejectsInvalidMangledType :: Bool
rejectsInvalidMangledType = hasIssue isInvalid (issuesAfter rewrite)
    where
        rewrite value = value {templateSpecializationMangledType = MangledTemplateType "invalid!"}
        isInvalid (InvalidPlanMangledType _ "invalid!") = True
        isInvalid _ = False

rejectsIncorrectMangledType :: Bool
rejectsIncorrectMangledType = hasIssue isIncorrect (issuesAfter rewrite)
    where
        rewrite value = value {templateSpecializationMangledType = MangledTemplateType "_TAT1_wrong"}
        isIncorrect (IncorrectPlanMangledType _ _ "_TAT1_wrong") = True
        isIncorrect _ = False

rejectsMissingMangledMember :: Bool
rejectsMissingMangledMember = hasIssue isMissing (issuesAfter (\value -> value {templateSpecializationMangledMembers = []}))
    where
        isMissing (MissingPlanMangledMember _ _) = True
        isMissing _ = False

rejectsInvalidMangledMember :: Bool
rejectsInvalidMangledMember = hasIssue isInvalid (issuesAfter rewrite)
    where
        rewrite value = value {templateSpecializationMangledMembers = map corrupt (templateSpecializationMangledMembers value)}
        corrupt member = member {mangledMemberText = "invalid!"}
        isInvalid (InvalidPlanMangledMember _ _ "invalid!") = True
        isInvalid _ = False

rejectsDuplicateMangledMember :: Bool
rejectsDuplicateMangledMember = hasIssue isDuplicate (issuesAfter rewrite)
    where
        rewrite value = case templateSpecializationMangledMembers value of
            first : rest -> value {templateSpecializationMangledMembers = first : first : rest}
            [] -> value
        isDuplicate (DuplicatePlanMangledMember _ _) = True
        isDuplicate _ = False

rejectsUnexpectedMangledMember :: Bool
rejectsUnexpectedMangledMember = hasIssue isUnexpected (issuesAfter rewrite)
    where
        rewrite value = case templateSpecializationMangledMembers value of
            first : rest -> value {templateSpecializationMangledMembers = first {mangledMemberSourceSymbol = SymbolId 9999} : rest}
            [] -> value
        isUnexpected (UnexpectedPlanMangledMember _ (SymbolId 9999)) = True
        isUnexpected _ = False

rejectsIncorrectMangledMember :: Bool
rejectsIncorrectMangledMember = hasIssue isInvalid (issuesAfter rewrite)
    where
        rewrite value = case templateSpecializationMangledMembers value of
            first : rest -> value {templateSpecializationMangledMembers = first {mangledMemberText = "_TAT1_wrong"} : rest}
            [] -> value
        isInvalid (InvalidPlanMangledMember _ _ "_TAT1_wrong") = True
        isInvalid _ = False

rejectsIncorrectStatistics :: Bool
rejectsIncorrectStatistics = case validPlan of
    Just plan ->
        hasIssue
            isIncorrect
            (templateSpecializationPlanIssues plan {plannedTemplateStatistics = TemplateSpecializationStatistics 99 98 97 96 95 94})
    Nothing -> False
    where
        isIncorrect (IncorrectPlanStatistics _ _) = True
        isIncorrect _ = False

rejectsIncompleteEmissionCoverage :: Bool
rejectsIncompleteEmissionCoverage = case validPlan >>= onlySpecialization of
    Just specialization ->
        let plan = maybe emptyPlan id validPlan
            duplicate = specialization {templateSpecializationIdentity = templateSpecializationIdentity specialization ++ ":duplicate"}
         in hasIssue
                isIncomplete
                (templateSpecializationPlanIssues plan {plannedTemplateSpecializations = [specialization, duplicate]})
    Nothing -> False
    where
        isIncomplete (IncompletePlanEmissionOrder _ _) = True
        isIncomplete _ = False

renderingNamesSpecialization :: Bool
renderingNamesSpecialization = "specialization 7" `isInfixOf` renderTemplatePlanIssue (InvalidPlanSpecializationId (TemplateSpecializationId 7))

renderingExplainsMangledMismatch :: Bool
renderingExplainsMangledMismatch =
    "mangled type differs"
        `isInfixOf` renderTemplatePlanIssue (IncorrectPlanMangledType (TemplateSpecializationId 1) "expected" "actual")

renderingExplainsSharedFreshSymbol :: Bool
renderingExplainsSharedFreshSymbol =
    "fresh symbol 44 is shared"
        `isInfixOf` renderTemplatePlanIssue (SharedFreshTargetSymbol (SymbolId 44) [TemplateSpecializationId 1, TemplateSpecializationId 2])
