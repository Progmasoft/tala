-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
module MonomorphizationTests (monomorphizationTests) where

import Data.List (isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Monomorphization
import Progmasoft.Tala.Core.Specialization

monomorphizationTests :: [(String, Bool)]
monomorphizationTests =
    [ ("plain scalar Core produces an empty specialization plan", plainModuleIsEmpty)
    , ("parameterized function parameters become root demands", parameterRootIsDiscovered)
    , ("parameterized function results become root demands", returnRootIsDiscovered)
    , ("binding declarations become root demands", bindingTypeIsDiscovered)
    , ("binding initializers retain a separate origin", bindingValueIsDiscovered)
    , ("assignment values become root demands", assignmentValueIsDiscovered)
    , ("returned expressions become root demands", returnValueIsDiscovered)
    , ("if conditions preserve their type location", conditionLocationIsDiscovered)
    , ("both if branches are traversed", branchLocationsAreDiscovered)
    , ("evaluated expressions become root demands", evaluatedValueIsDiscovered)
    , ("call result types become demands", callResultIsDiscovered)
    , ("call target types are traversed", callTargetIsDiscovered)
    , ("call arguments are traversed", callArgumentsAreDiscovered)
    , ("primitive result types become demands", primitiveResultIsDiscovered)
    , ("primitive operands are traversed", primitiveOperandsAreDiscovered)
    , ("closure callable types are traversed", closureCallableIsDiscovered)
    , ("closure capture types are traversed", closureCaptureTypeIsDiscovered)
    , ("closure capture values are traversed", closureCaptureValueIsDiscovered)
    , ("closure parameter types are traversed", closureParameterIsDiscovered)
    , ("closure return types are traversed", closureReturnIsDiscovered)
    , ("closure body types are traversed", closureBodyIsDiscovered)
    , ("function type containers expose nested specializations", callableChildrenAreDiscovered)
    , ("nested template types create dependency demands", nestedDependencyIsPlanned)
    , ("deep template trees reach a fixed point", deepFixedPointIsPlanned)
    , ("duplicate root types share one demand", duplicateRootsCoalesce)
    , ("duplicate roots retain distinct origins", duplicateOriginsAreRetained)
    , ("an identical root origin is not duplicated", identicalOriginsCoalesce)
    , ("dependency and root origins may coexist", rootAndDependencyOriginsCoexist)
    , ("dependency edges are unique", dependencyEdgesAreUnique)
    , ("demand identifiers follow insertion order", demandIdsAreOrdered)
    , ("demand lookup by id succeeds", demandLookupByIdWorks)
    , ("demand lookup by structural type succeeds", demandLookupByTypeWorks)
    , ("missing demand id returns Nothing", missingDemandIdIsAbsent)
    , ("missing demand type returns Nothing", missingDemandTypeIsAbsent)
    , ("all completed plan entries are complete", everyDemandCompletes)
    , ("root occurrence statistics count sites", rootOccurrenceStatisticsWork)
    , ("unique demand statistics count canonical types", uniqueDemandStatisticsWork)
    , ("dependency edge statistics count graph edges", edgeStatisticsWork)
    , ("cache hit statistics count repeated requests", cacheHitStatisticsWork)
    , ("depth statistics report the deepest dependency", depthStatisticsWork)
    , ("zero maximum demand count is invalid", zeroDemandLimitIsRejected)
    , ("negative maximum depth is invalid", negativeDepthLimitIsRejected)
    , ("zero maximum origin count is invalid", zeroOriginLimitIsRejected)
    , ("unique demand limits fail deterministically", demandLimitIsEnforced)
    , ("dependency depth limits fail deterministically", depthLimitIsEnforced)
    , ("origin limits fail deterministically", originLimitIsEnforced)
    , ("open type parameters are rejected", openTypeIsRejected)
    , ("open value parameters are rejected", openValueIsRejected)
    , ("malformed fixed arrays are rejected", malformedArrayIsRejected)
    , ("negative fixed array sizes are rejected", negativeArrayIsRejected)
    , ("invalid Unicode template values are rejected", invalidCharacterIsRejected)
    , ("empty qualified names are rejected", emptyNameIsRejected)
    , ("built-in arrays are specialization candidates", builtinArrayIsCandidate)
    , ("dynamic System.Array is a specialization candidate", dynamicArrayIsCandidate)
    , ("fixed System.Array is a specialization candidate", fixedArrayIsCandidate)
    , ("plain names are not specialization candidates", plainNameIsNotCandidate)
    , ("callable types are not standalone specialization candidates", callableIsNotCandidate)
    , ("type variables are not standalone specialization candidates", variableIsNotCandidate)
    , ("direct dependencies preserve argument indexes", dependencyIndexesAreStable)
    , ("value arguments do not manufacture dependencies", valueArgumentsDoNotDepend)
    , ("nested callable arguments expose their concrete children", callableDependencyIsVisible)
    , ("location rendering includes semantic function identity", locationRendersFunction)
    , ("location rendering includes statement and argument indexes", locationRendersPath)
    , ("limit diagnostics explain their boundary", limitDiagnosticIsReadable)
    , ("open-type diagnostics explain the source location", openDiagnosticIsReadable)
    , ("compiler artifacts carry an empty plan for scalar source", scalarPipelineCarriesPlan)
    , ("compiler artifacts carry fixed-array specialization demands", fixedArrayPipelineCarriesPlan)
    , ("compiler artifacts preserve dynamic and fixed array identities", arrayOverloadsStayDistinct)
    , ("discovery order follows function order", functionOrderIsStable)
    , ("discovery order follows statement order", statementOrderIsStable)
    , ("discovery order follows argument order", argumentOrderIsStable)
    , ("Boolean value arguments remain valid demands", booleanValueIsAccepted)
    , ("character value arguments remain valid demands", characterValueIsAccepted)
    , ("integer and character arguments remain distinct", valueKindsStayDistinct)
    , ("fixed array zero length is accepted", zeroLengthArrayIsAccepted)
    , ("large integer template values remain exact", largeIntegerStaysExact)
    , ("plan derivations support deterministic equality", repeatedPlanningIsEqual)
    , ("plan Show output contains concrete identities", planShowContainsIdentity)
    , ("completed planner output passes graph validation", completedGraphIsValid)
    , ("graph validation rejects duplicate demand ids", duplicateDemandIdsAreRejected)
    , ("graph validation rejects non-positive demand ids", nonPositiveDemandIdsAreRejected)
    , ("graph validation rejects missing dependencies", missingDependenciesAreRejected)
    , ("graph validation rejects duplicate dependency edges", duplicateDependenciesAreRejected)
    , ("graph validation rejects self dependencies", selfDependenciesAreRejected)
    , ("graph validation rejects queued output entries", queuedDemandsAreRejected)
    , ("graph validation checks demand statistics", demandStatisticsAreValidated)
    , ("graph validation checks edge statistics", edgeStatisticsAreValidated)
    , ("graph validation checks depth statistics", depthStatisticsAreValidated)
    , ("graph validation detects cycles", cyclesAreRejected)
    , ("graph roots retain directly observed demands", graphRootsAreObserved)
    , ("graph roots include child types also observed directly", observedChildrenAreRoots)
    , ("graph leaves contain dependency-free specializations", graphLeavesAreTerminal)
    , ("reverse graph query returns direct dependents", reverseEdgesAreQueryable)
    , ("reachable dependency query walks transitively", transitiveDependenciesAreQueryable)
    , ("reachable dependency query excludes its root", transitiveDependenciesExcludeRoot)
    , ("missing dependency query is empty", missingDependencyQueryIsEmpty)
    , ("emission order places nested children before parents", childrenEmitBeforeParents)
    , ("emission order remains stable across runs", emissionOrderIsStable)
    , ("demand trace includes identity and depth", traceIncludesIdentityAndDepth)
    , ("demand trace includes origins", traceIncludesOrigins)
    , ("demand trace includes dependencies", traceIncludesDependencies)
    , ("unknown demand trace is explicit", unknownTraceIsExplicit)
    , ("completed graph failures have a readable diagnostic", graphDiagnosticIsReadable)
    ]

plainModuleIsEmpty :: Bool
plainModuleIsEmpty = case planCoreMonomorphization (moduleWith [plainFunction]) of
    Right plan -> null (monomorphizationDemands plan) && monomorphizationStatistics plan == emptyMonomorphizationStatistics
    Left _ -> False

parameterRootIsDiscovered :: Bool
parameterRootIsDiscovered =
    hasRootPath [FunctionParameterPath 0] dynamicArrayPlan

returnRootIsDiscovered :: Bool
returnRootIsDiscovered = case planCoreMonomorphization (moduleWith [functionWith [] dynamicIntArray []]) of
    Right plan -> hasRootPath [FunctionReturnPath] plan
    Left _ -> False

bindingTypeIsDiscovered :: Bool
bindingTypeIsDiscovered =
    hasRootPath [StatementPath 0, BindingTypePath] bindingPlan

bindingValueIsDiscovered :: Bool
bindingValueIsDiscovered =
    hasRootPath [StatementPath 0, BindingValuePath, ExpressionResultPath] bindingPlan

assignmentValueIsDiscovered :: Bool
assignmentValueIsDiscovered = case planCoreMonomorphization (moduleWith [functionWith [] unitType [CoreAssign localName dynamicLiteral]]) of
    Right plan -> hasRootPath [StatementPath 0, AssignmentValuePath, ExpressionResultPath] plan
    Left _ -> False

returnValueIsDiscovered :: Bool
returnValueIsDiscovered = case planCoreMonomorphization (moduleWith [functionWith [] dynamicIntArray [CoreReturn dynamicLiteral]]) of
    Right plan -> hasRootPath [StatementPath 0, ReturnValuePath, ExpressionResultPath] plan
    Left _ -> False

conditionLocationIsDiscovered :: Bool
conditionLocationIsDiscovered = case planCoreMonomorphization conditionModule of
    Right plan -> hasRootPath [StatementPath 0, ConditionPath, ExpressionResultPath] plan
    Left _ -> False

branchLocationsAreDiscovered :: Bool
branchLocationsAreDiscovered = case planCoreMonomorphization branchModule of
    Right plan ->
        hasRootPath [StatementPath 0, TrueBranchPath, StatementPath 0, EvaluatedValuePath, ExpressionResultPath] plan
            && hasRootPath [StatementPath 0, FalseBranchPath, StatementPath 0, EvaluatedValuePath, ExpressionResultPath] plan
    Left _ -> False

evaluatedValueIsDiscovered :: Bool
evaluatedValueIsDiscovered = case planCoreMonomorphization (moduleWith [functionWith [] unitType [CoreEvaluate dynamicLiteral]]) of
    Right plan -> hasRootPath [StatementPath 0, EvaluatedValuePath, ExpressionResultPath] plan
    Left _ -> False

callResultIsDiscovered :: Bool
callResultIsDiscovered = case callPlan of
    Right plan -> hasRootPath [StatementPath 0, EvaluatedValuePath, ExpressionResultPath] plan
    Left _ -> False

callTargetIsDiscovered :: Bool
callTargetIsDiscovered = case callPlan of
    Right plan -> hasRootPath [StatementPath 0, EvaluatedValuePath, CalleePath, ExpressionResultPath, ClosureReturnPath] plan
    Left _ -> False

callArgumentsAreDiscovered :: Bool
callArgumentsAreDiscovered = case callPlan of
    Right plan -> hasRootPath [StatementPath 0, EvaluatedValuePath, ArgumentPath 0, ExpressionResultPath] plan
    Left _ -> False

primitiveResultIsDiscovered :: Bool
primitiveResultIsDiscovered = case primitivePlan of
    Right plan -> hasRootPath [StatementPath 0, EvaluatedValuePath, ExpressionResultPath] plan
    Left _ -> False

primitiveOperandsAreDiscovered :: Bool
primitiveOperandsAreDiscovered = case primitivePlan of
    Right plan ->
        hasRootPath [StatementPath 0, EvaluatedValuePath, PrimitiveOperandPath 0, ExpressionResultPath] plan
            && hasRootPath [StatementPath 0, EvaluatedValuePath, PrimitiveOperandPath 1, ExpressionResultPath] plan
    Left _ -> False

closureCallableIsDiscovered :: Bool
closureCallableIsDiscovered = case closurePlan of
    Right plan ->
        hasRootPath [StatementPath 0, EvaluatedValuePath, ExpressionResultPath, ClosureParameterPath 0] plan
            && hasRootPath [StatementPath 0, EvaluatedValuePath, ExpressionResultPath, ClosureReturnPath] plan
    Left _ -> False

closureCaptureTypeIsDiscovered :: Bool
closureCaptureTypeIsDiscovered = case closurePlan of
    Right plan ->
        hasRootPath
            [StatementPath 0, EvaluatedValuePath, ClosureCapturePath 0, ClosureCaptureTypePath]
            plan
    Left _ -> False

closureCaptureValueIsDiscovered :: Bool
closureCaptureValueIsDiscovered = case closurePlan of
    Right plan ->
        hasRootPath
            [StatementPath 0, EvaluatedValuePath, ClosureCapturePath 0, ClosureCaptureValuePath, ExpressionResultPath]
            plan
    Left _ -> False

closureParameterIsDiscovered :: Bool
closureParameterIsDiscovered = case closurePlan of
    Right plan -> hasRootPath [StatementPath 0, EvaluatedValuePath, ClosureParameterPath 0] plan
    Left _ -> False

closureReturnIsDiscovered :: Bool
closureReturnIsDiscovered = case closurePlan of
    Right plan -> hasRootPath [StatementPath 0, EvaluatedValuePath, ClosureReturnPath] plan
    Left _ -> False

closureBodyIsDiscovered :: Bool
closureBodyIsDiscovered = case closurePlan of
    Right plan ->
        hasRootPath
            [StatementPath 0, EvaluatedValuePath, ClosureBodyPath, StatementPath 0, ReturnValuePath, ExpressionResultPath]
            plan
    Left _ -> False

callableChildrenAreDiscovered :: Bool
callableChildrenAreDiscovered = case planCoreMonomorphization callableModule of
    Right plan -> demandTypes plan == [dynamicIntArray, fixedIntArray 4]
    Left _ -> False

nestedDependencyIsPlanned :: Bool
nestedDependencyIsPlanned = case nestedPlan of
    Right plan -> case monomorphizationDemands plan of
        parent : child : _ -> monomorphizationDependencies parent == [monomorphizationDemandId child]
        _ -> False
    Left _ -> False

deepFixedPointIsPlanned :: Bool
deepFixedPointIsPlanned = case deepPlan of
    Right plan ->
        length (monomorphizationDemands plan) == 4
            && deepestSpecializationDemand (monomorphizationStatistics plan) == 3
    Left _ -> False

duplicateRootsCoalesce :: Bool
duplicateRootsCoalesce = case duplicatePlan of
    Right plan -> length (monomorphizationDemands plan) == 1
    Left _ -> False

duplicateOriginsAreRetained :: Bool
duplicateOriginsAreRetained = case duplicatePlan of
    Right plan -> case monomorphizationDemands plan of
        [demand] -> length (monomorphizationOrigins demand) == 2
        _ -> False
    Left _ -> False

identicalOriginsCoalesce :: Bool
identicalOriginsCoalesce = case planCoreMonomorphization (moduleWith [functionWith [(localName, dynamicIntArray)] unitType []]) of
    Right plan -> case monomorphizationDemands plan of
        [demand] -> length (monomorphizationOrigins demand) == 1
        _ -> False
    Left _ -> False

rootAndDependencyOriginsCoexist :: Bool
rootAndDependencyOriginsCoexist = case rootAndDependencyPlan of
    Right plan -> case findDemandByType dynamicIntArray plan of
        Just demand -> any isRoot (monomorphizationOrigins demand) && any isDependency (monomorphizationOrigins demand)
        Nothing -> False
    Left _ -> False

dependencyEdgesAreUnique :: Bool
dependencyEdgesAreUnique = case repeatedChildPlan of
    Right plan -> case monomorphizationDemands plan of
        parent : _ -> length (monomorphizationDependencies parent) == 1
        [] -> False
    Left _ -> False

demandIdsAreOrdered :: Bool
demandIdsAreOrdered = case multiPlan of
    Right plan -> map (demandIdValue . monomorphizationDemandId) (monomorphizationDemands plan) == [1, 2, 3]
    Left _ -> False

demandLookupByIdWorks :: Bool
demandLookupByIdWorks = case multiPlan of
    Right plan -> case findDemand (DemandId 2) plan of
        Just demand -> specializationType (monomorphizationSpecialization demand) == fixedIntArray 2
        Nothing -> False
    Left _ -> False

demandLookupByTypeWorks :: Bool
demandLookupByTypeWorks = case multiPlan of
    Right plan -> case findDemandByType (fixedIntArray 3) plan of
        Just demand -> monomorphizationDemandId demand == DemandId 3
        Nothing -> False
    Left _ -> False

missingDemandIdIsAbsent :: Bool
missingDemandIdIsAbsent = case multiPlan of
    Right plan -> findDemand (DemandId 99) plan == Nothing
    Left _ -> False

missingDemandTypeIsAbsent :: Bool
missingDemandTypeIsAbsent = case multiPlan of
    Right plan -> findDemandByType (fixedIntArray 99) plan == Nothing
    Left _ -> False

everyDemandCompletes :: Bool
everyDemandCompletes = case deepPlan of
    Right plan -> all ((== DemandComplete) . monomorphizationState) (monomorphizationDemands plan)
    Left _ -> False

rootOccurrenceStatisticsWork :: Bool
rootOccurrenceStatisticsWork = case duplicatePlan of
    Right plan -> discoveredRootOccurrences (monomorphizationStatistics plan) == 2
    Left _ -> False

uniqueDemandStatisticsWork :: Bool
uniqueDemandStatisticsWork = case multiPlan of
    Right plan -> uniqueSpecializationDemands (monomorphizationStatistics plan) == 3
    Left _ -> False

edgeStatisticsWork :: Bool
edgeStatisticsWork = case deepPlan of
    Right plan -> specializationDependencyEdges (monomorphizationStatistics plan) == 3
    Left _ -> False

cacheHitStatisticsWork :: Bool
cacheHitStatisticsWork = case duplicatePlan of
    Right plan -> specializationCacheHits (monomorphizationStatistics plan) == 1
    Left _ -> False

depthStatisticsWork :: Bool
depthStatisticsWork = case deepPlan of
    Right plan -> deepestSpecializationDemand (monomorphizationStatistics plan) == 3
    Left _ -> False

zeroDemandLimitIsRejected :: Bool
zeroDemandLimitIsRejected = case planCoreMonomorphizationWith (MonomorphizationLimits 0 1 1) (moduleWith []) of
    Left (InvalidMonomorphizationLimits _) -> True
    _ -> False

negativeDepthLimitIsRejected :: Bool
negativeDepthLimitIsRejected = case planCoreMonomorphizationWith (MonomorphizationLimits 1 (-1) 1) (moduleWith []) of
    Left (InvalidMonomorphizationLimits _) -> True
    _ -> False

zeroOriginLimitIsRejected :: Bool
zeroOriginLimitIsRejected = case planCoreMonomorphizationWith (MonomorphizationLimits 1 1 0) (moduleWith []) of
    Left (InvalidMonomorphizationLimits _) -> True
    _ -> False

demandLimitIsEnforced :: Bool
demandLimitIsEnforced = case planCoreMonomorphizationWith (MonomorphizationLimits 2 8 8) multiModule of
    Left (SpecializationLimitExceeded 2 _ _) -> True
    _ -> False

depthLimitIsEnforced :: Bool
depthLimitIsEnforced = case planCoreMonomorphizationWith (MonomorphizationLimits 8 1 8) deepModule of
    Left (DemandDepthExceeded 1 _ _) -> True
    _ -> False

originLimitIsEnforced :: Bool
originLimitIsEnforced = case planCoreMonomorphizationWith (MonomorphizationLimits 8 8 1) duplicateModule of
    Left (DemandOriginLimitExceeded 1 _ _) -> True
    _ -> False

openTypeIsRejected :: Bool
openTypeIsRejected = case planCoreMonomorphization (moduleWith [functionWith [(localName, openBox)] unitType []]) of
    Left (InvalidDemandType _ (OpenSpecialization [SymbolId 80])) -> True
    _ -> False

openValueIsRejected :: Bool
openValueIsRejected = case planCoreMonomorphization (moduleWith [functionWith [(localName, openArray)] unitType []]) of
    Left (InvalidDemandType _ (OpenSpecialization [SymbolId 81])) -> True
    _ -> False

malformedArrayIsRejected :: Bool
malformedArrayIsRejected = case planCoreMonomorphization (moduleWith [functionWith [(localName, malformedArray)] unitType []]) of
    Left (InvalidDemandType _ (InvalidSpecialization _)) -> True
    _ -> False

negativeArrayIsRejected :: Bool
negativeArrayIsRejected = case planCoreMonomorphization (moduleWith [functionWith [(localName, fixedIntArray (-1))] unitType []]) of
    Left (InvalidDemandType _ (InvalidSpecialization _)) -> True
    _ -> False

invalidCharacterIsRejected :: Bool
invalidCharacterIsRejected = case planCoreMonomorphization (moduleWith [functionWith [(localName, characterBox 0xd800)] unitType []]) of
    Left (InvalidDemandType _ (InvalidSpecialization _)) -> True
    _ -> False

emptyNameIsRejected :: Bool
emptyNameIsRejected = case planCoreMonomorphization
    (moduleWith [functionWith [(localName, NamedType (QualifiedName []) [typeArgument intType])] unitType []]) of
    Left (InvalidDemandType _ (InvalidSpecialization _)) -> True
    _ -> False

builtinArrayIsCandidate :: Bool
builtinArrayIsCandidate = specializationCandidate builtinIntArray

dynamicArrayIsCandidate :: Bool
dynamicArrayIsCandidate = specializationCandidate dynamicIntArray

fixedArrayIsCandidate :: Bool
fixedArrayIsCandidate = specializationCandidate (fixedIntArray 8)

plainNameIsNotCandidate :: Bool
plainNameIsNotCandidate = not (specializationCandidate intType)

callableIsNotCandidate :: Bool
callableIsNotCandidate = not (specializationCandidate (FunctionType [dynamicIntArray] dynamicIntArray))

variableIsNotCandidate :: Bool
variableIsNotCandidate = not (specializationCandidate (TypeVariable typeParameter))

dependencyIndexesAreStable :: Bool
dependencyIndexesAreStable =
    directTypeDependencies pairType
        == [(0, dynamicIntArray), (1, fixedIntArray 4)]

valueArgumentsDoNotDepend :: Bool
valueArgumentsDoNotDepend = directTypeDependencies (fixedIntArray 4) == []

callableDependencyIsVisible :: Bool
callableDependencyIsVisible =
    directTypeDependencies (FunctionType [dynamicIntArray] (fixedIntArray 4))
        == [(0, dynamicIntArray), (1, fixedIntArray 4)]

locationRendersFunction :: Bool
locationRendersFunction = "Run#1" `isInfixOf` renderDemandLocation (DemandLocation functionName [])

locationRendersPath :: Bool
locationRendersPath =
    ".statement[2].argument[3]"
        `isInfixOf` renderDemandLocation (DemandLocation functionName [StatementPath 2, ArgumentPath 3])

limitDiagnosticIsReadable :: Bool
limitDiagnosticIsReadable = case planCoreMonomorphizationWith (MonomorphizationLimits 1 8 8) multiModule of
    Left failure -> "specialization demand limit 1 exceeded" `isInfixOf` renderMonomorphizationError failure
    Right _ -> False

openDiagnosticIsReadable :: Bool
openDiagnosticIsReadable = case planCoreMonomorphization (moduleWith [functionWith [(localName, openBox)] unitType []]) of
    Left failure ->
        "Run#1.parameter[0]" `isInfixOf` renderMonomorphizationError failure
            && "unbound template parameters [80]" `isInfixOf` renderMonomorphizationError failure
    Right _ -> False

scalarPipelineCarriesPlan :: Bool
scalarPipelineCarriesPlan = case compileToCorePrep (CompilerInput "scalar.tala" scalarSource) of
    Right artifacts -> null (monomorphizationDemands (artifactMonomorphizationPlan artifacts))
    Left _ -> False

fixedArrayPipelineCarriesPlan :: Bool
fixedArrayPipelineCarriesPlan = case compileToCorePrep (CompilerInput "array.tala" fixedArraySource) of
    Right artifacts ->
        any
            ((== fixedIntArray 4) . specializationType . monomorphizationSpecialization)
            (monomorphizationDemands (artifactMonomorphizationPlan artifacts))
    Left _ -> False

arrayOverloadsStayDistinct :: Bool
arrayOverloadsStayDistinct = case compileToCorePrep (CompilerInput "arrays.tala" arrayOverloadSource) of
    Right artifacts ->
        let types = demandTypes (artifactMonomorphizationPlan artifacts)
         in dynamicIntArray `elem` types && fixedIntArray 4 `elem` types
    Left _ -> False

functionOrderIsStable :: Bool
functionOrderIsStable = case planCoreMonomorphization orderedFunctionsModule of
    Right plan -> take 2 (demandTypes plan) == [fixedIntArray 1, fixedIntArray 2]
    Left _ -> False

statementOrderIsStable :: Bool
statementOrderIsStable = case planCoreMonomorphization orderedStatementsModule of
    Right plan -> take 2 (demandTypes plan) == [fixedIntArray 1, fixedIntArray 2]
    Left _ -> False

argumentOrderIsStable :: Bool
argumentOrderIsStable = case planCoreMonomorphization orderedArgumentsModule of
    Right plan -> take 2 (demandTypes plan) == [fixedIntArray 1, fixedIntArray 2]
    Left _ -> False

booleanValueIsAccepted :: Bool
booleanValueIsAccepted = accepts (named "Flagged" [ValueTemplateArgument (BooleanTemplateValue True)])

characterValueIsAccepted :: Bool
characterValueIsAccepted = accepts (characterBox 65)

valueKindsStayDistinct :: Bool
valueKindsStayDistinct = case planCoreMonomorphization valueKindModule of
    Right plan -> length (monomorphizationDemands plan) == 2
    Left _ -> False

zeroLengthArrayIsAccepted :: Bool
zeroLengthArrayIsAccepted = accepts (fixedIntArray 0)

largeIntegerStaysExact :: Bool
largeIntegerStaysExact =
    accepts (named "Wide" [ValueTemplateArgument (IntegerTemplateValue (2 ^ (200 :: Int)))])

repeatedPlanningIsEqual :: Bool
repeatedPlanningIsEqual = planCoreMonomorphization deepModule == planCoreMonomorphization deepModule

planShowContainsIdentity :: Bool
planShowContainsIdentity = case nestedPlan of
    Right plan -> "System" `isInfixOf` show plan && "Array" `isInfixOf` show plan
    Left _ -> False

completedGraphIsValid :: Bool
completedGraphIsValid = maybePlan deepPlan (null . validateDemandGraph)

duplicateDemandIdsAreRejected :: Bool
duplicateDemandIdsAreRejected = case planDemands deepPlan of
    first : second : remaining ->
        let duplicate = second {monomorphizationDemandId = monomorphizationDemandId first}
            plan = replacePlanDemands deepPlan (first : duplicate : remaining)
         in DuplicateDemandIdentifier (monomorphizationDemandId first) `elem` validateDemandGraph plan
    _ -> False

nonPositiveDemandIdsAreRejected :: Bool
nonPositiveDemandIdsAreRejected = case planDemands nestedPlan of
    first : remaining ->
        let invalid = first {monomorphizationDemandId = DemandId 0}
            plan = replacePlanDemands nestedPlan (invalid : remaining)
         in NonPositiveDemandIdentifier (DemandId 0) `elem` validateDemandGraph plan
    _ -> False

missingDependenciesAreRejected :: Bool
missingDependenciesAreRejected = case planDemands nestedPlan of
    first : remaining ->
        let invalid = first {monomorphizationDependencies = [DemandId 99]}
            plan = replacePlanDemands nestedPlan (invalid : remaining)
         in MissingDependency (monomorphizationDemandId first) (DemandId 99) `elem` validateDemandGraph plan
    _ -> False

duplicateDependenciesAreRejected :: Bool
duplicateDependenciesAreRejected = case planDemands nestedPlan of
    first : remaining -> case monomorphizationDependencies first of
        dependency : _ ->
            let invalid = first {monomorphizationDependencies = [dependency, dependency]}
                plan = replacePlanDemands nestedPlan (invalid : remaining)
             in DuplicateDependency (monomorphizationDemandId first) dependency `elem` validateDemandGraph plan
        [] -> False
    _ -> False

selfDependenciesAreRejected :: Bool
selfDependenciesAreRejected = case planDemands nestedPlan of
    first : remaining ->
        let owner = monomorphizationDemandId first
            invalid = first {monomorphizationDependencies = [owner]}
            plan = replacePlanDemands nestedPlan (invalid : remaining)
         in SelfDependency owner `elem` validateDemandGraph plan
    _ -> False

queuedDemandsAreRejected :: Bool
queuedDemandsAreRejected = case planDemands nestedPlan of
    first : remaining ->
        let invalid = first {monomorphizationState = DemandQueued}
            plan = replacePlanDemands nestedPlan (invalid : remaining)
         in IncompleteDemand (monomorphizationDemandId first) `elem` validateDemandGraph plan
    _ -> False

demandStatisticsAreValidated :: Bool
demandStatisticsAreValidated = case nestedPlan of
    Right plan ->
        let statistics = (monomorphizationStatistics plan) {uniqueSpecializationDemands = 77}
            invalid = plan {monomorphizationStatistics = statistics}
         in StatisticsDemandCountMismatch 77 2 `elem` validateDemandGraph invalid
    Left _ -> False

edgeStatisticsAreValidated :: Bool
edgeStatisticsAreValidated = case nestedPlan of
    Right plan ->
        let statistics = (monomorphizationStatistics plan) {specializationDependencyEdges = 77}
            invalid = plan {monomorphizationStatistics = statistics}
         in StatisticsEdgeCountMismatch 77 1 `elem` validateDemandGraph invalid
    Left _ -> False

depthStatisticsAreValidated :: Bool
depthStatisticsAreValidated = case nestedPlan of
    Right plan ->
        let statistics = (monomorphizationStatistics plan) {deepestSpecializationDemand = 77}
            invalid = plan {monomorphizationStatistics = statistics}
         in StatisticsDepthMismatch 77 1 `elem` validateDemandGraph invalid
    Left _ -> False

cyclesAreRejected :: Bool
cyclesAreRejected = case planDemands nestedPlan of
    first : second : remaining ->
        let firstId = monomorphizationDemandId first
            secondId = monomorphizationDemandId second
            left = first {monomorphizationDependencies = [secondId]}
            right = second {monomorphizationDependencies = [firstId]}
            plan = replacePlanDemands nestedPlan (left : right : remaining)
         in any isCycle (validateDemandGraph plan)
    _ -> False
    where
        isCycle (CyclicDemandPath _) = True
        isCycle _ = False

graphRootsAreObserved :: Bool
graphRootsAreObserved = case nestedPlan of
    Right plan -> map demandType (demandRoots plan) == [nestedArray]
    Left _ -> False

observedChildrenAreRoots :: Bool
observedChildrenAreRoots = case rootAndDependencyPlan of
    Right plan -> map demandType (demandRoots plan) == [nestedArray, dynamicIntArray]
    Left _ -> False

graphLeavesAreTerminal :: Bool
graphLeavesAreTerminal = case deepPlan of
    Right plan -> map demandType (demandLeaves plan) == [dynamicIntArray]
    Left _ -> False

reverseEdgesAreQueryable :: Bool
reverseEdgesAreQueryable = case nestedPlan of
    Right plan -> case findDemandByType dynamicIntArray plan of
        Just child -> map demandType (dependentDemands (monomorphizationDemandId child) plan) == [nestedArray]
        Nothing -> False
    Left _ -> False

transitiveDependenciesAreQueryable :: Bool
transitiveDependenciesAreQueryable = case deepPlan of
    Right plan -> case findDemandByType deepArray plan of
        Just root -> length (reachableDependencies (monomorphizationDemandId root) plan) == 3
        Nothing -> False
    Left _ -> False

transitiveDependenciesExcludeRoot :: Bool
transitiveDependenciesExcludeRoot = case deepPlan of
    Right plan -> case findDemandByType deepArray plan of
        Just root -> root `notElem` reachableDependencies (monomorphizationDemandId root) plan
        Nothing -> False
    Left _ -> False

missingDependencyQueryIsEmpty :: Bool
missingDependencyQueryIsEmpty = maybePlan nestedPlan (null . reachableDependencies (DemandId 99))

childrenEmitBeforeParents :: Bool
childrenEmitBeforeParents = case deepPlan >>= mapGraphResult . specializationEmissionOrder of
    Right demands -> map demandType demands == reverse (demandTypes (rightPlan deepPlan))
    Left _ -> False

emissionOrderIsStable :: Bool
emissionOrderIsStable = case deepPlan of
    Right plan -> specializationEmissionOrder plan == specializationEmissionOrder plan
    Left _ -> False

traceIncludesIdentityAndDepth :: Bool
traceIncludesIdentityAndDepth = case nestedPlan of
    Right plan ->
        let trace = renderDemandTrace plan (DemandId 1)
         in "System" `isInfixOf` trace && "depth=0" `isInfixOf` trace
    Left _ -> False

traceIncludesOrigins :: Bool
traceIncludesOrigins = case nestedPlan of
    Right plan -> "Run#1.parameter[0]" `isInfixOf` renderDemandTrace plan (DemandId 1)
    Left _ -> False

traceIncludesDependencies :: Bool
traceIncludesDependencies = case nestedPlan of
    Right plan -> "dependencies=[demand#2]" `isInfixOf` renderDemandTrace plan (DemandId 1)
    Left _ -> False

unknownTraceIsExplicit :: Bool
unknownTraceIsExplicit = case nestedPlan of
    Right plan -> renderDemandTrace plan (DemandId 99) == "unknown demand demand#99"
    Left _ -> False

graphDiagnosticIsReadable :: Bool
graphDiagnosticIsReadable =
    "completed specialization demand graph failed validation"
        `isInfixOf` renderMonomorphizationError (InvalidCompletedDemandGraph ["SelfDependency (DemandId 1)"])

demandType :: MonomorphizationDemand -> Type
demandType = specializationType . monomorphizationSpecialization

planDemands :: Either MonomorphizationError MonomorphizationPlan -> [MonomorphizationDemand]
planDemands = maybe [] monomorphizationDemands . either (const Nothing) Just

replacePlanDemands ::
    Either MonomorphizationError MonomorphizationPlan -> [MonomorphizationDemand] -> MonomorphizationPlan
replacePlanDemands result demands = case result of
    Right plan -> plan {monomorphizationDemands = demands}
    Left _ -> MonomorphizationPlan demands emptyMonomorphizationStatistics

maybePlan :: Either MonomorphizationError MonomorphizationPlan -> (MonomorphizationPlan -> Bool) -> Bool
maybePlan result predicate = case result of
    Right plan -> predicate plan
    Left _ -> False

mapGraphResult :: Either [DemandId] value -> Either MonomorphizationError value
mapGraphResult result = case result of
    Right value -> Right value
    Left _ -> Left (InternalMissingDemand "cycle")

hasRootPath :: [DemandPathStep] -> MonomorphizationPlan -> Bool
hasRootPath path plan =
    any
        (any matches . monomorphizationOrigins)
        (monomorphizationDemands plan)
    where
        matches (RootDemand location) = demandLocationPath location == path
        matches (DependencyDemand _ _) = False

demandTypes :: MonomorphizationPlan -> [Type]
demandTypes = map (specializationType . monomorphizationSpecialization) . monomorphizationDemands

accepts :: Type -> Bool
accepts valueType = case planCoreMonomorphization (moduleWith [functionWith [(localName, valueType)] unitType []]) of
    Right _ -> True
    Left _ -> False

isRoot :: DemandOrigin -> Bool
isRoot (RootDemand _) = True
isRoot _ = False

isDependency :: DemandOrigin -> Bool
isDependency (DependencyDemand _ _) = True
isDependency _ = False

moduleWith :: [CoreFunction] -> CoreModule
moduleWith functions = CoreModuleWithSources (QualifiedName [Identifier "Tests"]) functions [] []

functionWith :: [(ResolvedName, Type)] -> Type -> [CoreStatement] -> CoreFunction
functionWith = CoreFunction functionName

plainFunction :: CoreFunction
plainFunction = functionWith [(localName, intType)] unitType [CoreReturn (CoreLiteral CoreUnit unitType)]

dynamicArrayPlan :: MonomorphizationPlan
dynamicArrayPlan = rightPlan (planCoreMonomorphization (moduleWith [functionWith [(localName, dynamicIntArray)] unitType []]))

bindingPlan :: MonomorphizationPlan
bindingPlan =
    rightPlan
        ( planCoreMonomorphization
            (moduleWith [functionWith [] unitType [CoreBind (CoreBinding localName dynamicIntArray False dynamicLiteral)]])
        )

conditionModule :: CoreModule
conditionModule =
    moduleWith
        [ functionWith
            []
            unitType
            [CoreIf (CoreLiteral (CoreString "condition") dynamicIntArray) [] []]
        ]

branchModule :: CoreModule
branchModule =
    moduleWith
        [ functionWith
            []
            unitType
            [ CoreIf
                (CoreLiteral (CoreBoolean True) boolType)
                [CoreEvaluate dynamicLiteral]
                [CoreEvaluate fixedLiteral]
            ]
        ]

callPlan :: Either MonomorphizationError MonomorphizationPlan
callPlan = planCoreMonomorphization callModule

callModule :: CoreModule
callModule =
    moduleWith
        [ functionWith
            []
            unitType
            [ CoreEvaluate
                ( CoreApply
                    (CoreVariable calleeName (FunctionType [dynamicIntArray] (fixedIntArray 4)))
                    [dynamicLiteral]
                    (fixedIntArray 4)
                )
            ]
        ]

primitivePlan :: Either MonomorphizationError MonomorphizationPlan
primitivePlan =
    planCoreMonomorphization
        ( moduleWith
            [ functionWith
                []
                unitType
                [CoreEvaluate (CorePrimitive CoreAdd [dynamicLiteral, fixedLiteral] dynamicIntArray)]
            ]
        )

closurePlan :: Either MonomorphizationError MonomorphizationPlan
closurePlan = planCoreMonomorphization closureModule

closureModule :: CoreModule
closureModule =
    moduleWith
        [ functionWith
            []
            unitType
            [ CoreEvaluate
                ( CoreClosure
                    [CoreCapture StrongCapture capturedValueName dynamicIntArray dynamicLiteral]
                    [(closureParameterName, fixedIntArray 4)]
                    dynamicIntArray
                    [CoreReturn dynamicLiteral]
                    (FunctionType [fixedIntArray 4] dynamicIntArray)
                )
            ]
        ]

callableModule :: CoreModule
callableModule =
    moduleWith
        [functionWith [(localName, FunctionType [dynamicIntArray] (fixedIntArray 4))] unitType []]

nestedPlan :: Either MonomorphizationError MonomorphizationPlan
nestedPlan = planCoreMonomorphization nestedModule

nestedModule :: CoreModule
nestedModule = moduleWith [functionWith [(localName, nestedArray)] unitType []]

deepPlan :: Either MonomorphizationError MonomorphizationPlan
deepPlan = planCoreMonomorphization deepModule

deepModule :: CoreModule
deepModule = moduleWith [functionWith [(localName, deepArray)] unitType []]

duplicatePlan :: Either MonomorphizationError MonomorphizationPlan
duplicatePlan = planCoreMonomorphization duplicateModule

duplicateModule :: CoreModule
duplicateModule = moduleWith [functionWith [(localName, dynamicIntArray), (secondName, dynamicIntArray)] unitType []]

rootAndDependencyPlan :: Either MonomorphizationError MonomorphizationPlan
rootAndDependencyPlan =
    planCoreMonomorphization
        (moduleWith [functionWith [(localName, nestedArray), (secondName, dynamicIntArray)] unitType []])

repeatedChildPlan :: Either MonomorphizationError MonomorphizationPlan
repeatedChildPlan =
    planCoreMonomorphization
        ( moduleWith
            [functionWith [(localName, named "Pair" [typeArgument dynamicIntArray, typeArgument dynamicIntArray])] unitType []]
        )

multiPlan :: Either MonomorphizationError MonomorphizationPlan
multiPlan = planCoreMonomorphization multiModule

multiModule :: CoreModule
multiModule =
    moduleWith
        [functionWith [(localName, fixedIntArray 1), (secondName, fixedIntArray 2), (thirdName, fixedIntArray 3)] unitType []]

orderedFunctionsModule :: CoreModule
orderedFunctionsModule =
    moduleWith
        [ CoreFunction functionName [(localName, fixedIntArray 1)] unitType []
        , CoreFunction secondFunctionName [(localName, fixedIntArray 2)] unitType []
        ]

orderedStatementsModule :: CoreModule
orderedStatementsModule =
    moduleWith
        [ functionWith
            []
            unitType
            [CoreEvaluate (CoreLiteral CoreUnit (fixedIntArray 1)), CoreEvaluate (CoreLiteral CoreUnit (fixedIntArray 2))]
        ]

orderedArgumentsModule :: CoreModule
orderedArgumentsModule =
    moduleWith
        [ functionWith
            []
            unitType
            [ CoreEvaluate
                ( CoreApply
                    (CoreVariable calleeName (FunctionType [fixedIntArray 1, fixedIntArray 2] unitType))
                    [CoreLiteral CoreUnit (fixedIntArray 1), CoreLiteral CoreUnit (fixedIntArray 2)]
                    unitType
                )
            ]
        ]

valueKindModule :: CoreModule
valueKindModule =
    moduleWith
        [ functionWith
            [(localName, named "Code" [ValueTemplateArgument (IntegerTemplateValue 65)])]
            (named "Code" [ValueTemplateArgument (CharacterTemplateValue 65)])
            []
        ]

dynamicLiteral :: CoreExpression
dynamicLiteral = CoreLiteral (CoreString "dynamic") dynamicIntArray

fixedLiteral :: CoreExpression
fixedLiteral = CoreLiteral (CoreString "fixed") (fixedIntArray 4)

dynamicIntArray :: Type
dynamicIntArray = namedQualified ["System", "Array"] [typeArgument intType]

fixedIntArray :: Integer -> Type
fixedIntArray size =
    namedQualified
        ["System", "Array"]
        [typeArgument intType, ValueTemplateArgument (IntegerTemplateValue size)]

builtinIntArray :: Type
builtinIntArray = named "[]" [typeArgument intType]

nestedArray :: Type
nestedArray = namedQualified ["System", "Array"] [typeArgument dynamicIntArray]

deepArray :: Type
deepArray = foldr (\_ nested -> named "Box" [typeArgument nested]) dynamicIntArray [1 :: Int .. 3]

pairType :: Type
pairType = named "Pair" [typeArgument dynamicIntArray, typeArgument (fixedIntArray 4)]

openBox :: Type
openBox = named "Box" [typeArgument (TypeVariable typeParameter)]

openArray :: Type
openArray =
    namedQualified
        ["System", "Array"]
        [typeArgument intType, ValueTemplateArgument (TemplateValueParameter valueParameter)]

malformedArray :: Type
malformedArray = namedQualified ["System", "Array"] [ValueTemplateArgument (IntegerTemplateValue 4)]

characterBox :: Integer -> Type
characterBox scalar = named "Character" [ValueTemplateArgument (CharacterTemplateValue scalar)]

typeArgument :: Type -> TemplateArgument
typeArgument = TypeTemplateArgument

named :: String -> [TemplateArgument] -> Type
named value = namedQualified [value]

namedQualified :: [String] -> [TemplateArgument] -> Type
namedQualified parts = NamedType (QualifiedName (map Identifier parts))

functionName
    , secondFunctionName
    , localName
    , secondName
    , thirdName
    , calleeName
    , capturedValueName
    , closureParameterName ::
        ResolvedName
functionName = resolved 1 "Run"
secondFunctionName = resolved 2 "Next"
localName = resolved 10 "value"
secondName = resolved 11 "second"
thirdName = resolved 12 "third"
calleeName = resolved 20 "callee"
capturedValueName = resolved 21 "captured"
closureParameterName = resolved 22 "argument"

typeParameter, valueParameter :: ResolvedName
typeParameter = resolved 80 "T"
valueParameter = resolved 81 "N"

resolved :: Int -> String -> ResolvedName
resolved symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

rightPlan :: Either MonomorphizationError MonomorphizationPlan -> MonomorphizationPlan
rightPlan result = case result of
    Right plan -> plan
    Left _ -> MonomorphizationPlan [] emptyMonomorphizationStatistics

scalarSource :: String
scalarSource =
    unlines
        [ "namespace Tests;"
        , "class Program {"
        , "    public static void Main() {"
        , "        return;"
        , "    }"
        , "}"
        ]

fixedArraySource :: String
fixedArraySource =
    unlines
        [ "namespace Tests;"
        , "class Program {"
        , "    public static void Consume(_ [int; 4] values) {"
        , "        return;"
        , "    }"
        , "}"
        ]

arrayOverloadSource :: String
arrayOverloadSource =
    unlines
        [ "namespace Tests;"
        , "class Program {"
        , "    public static void Consume(_ [int] dynamicValues, _ [int; 4] fixedValues) {"
        , "        return;"
        , "    }"
        , "}"
        ]
