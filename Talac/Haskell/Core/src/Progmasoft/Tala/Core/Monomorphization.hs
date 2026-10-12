-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Fixed-point specialization-demand planning over verified Core.

This pass is deliberately earlier than Core optimization and CorePrep.  It
proves that every parameterized type visible in the current Core module is a
valid closed specialization and records the nested demands that declaration
instantiation will consume.  It does not clone declarations yet; callers must
not confuse a successful demand plan with a completed template implementation.
-}
module Progmasoft.Tala.Core.Monomorphization
    ( module Progmasoft.Tala.Core.Monomorphization.Types
    , module Progmasoft.Tala.Core.Monomorphization.Graph
    , TypeOccurrence (..)
    , directTypeDependencies
    , discoverTypeOccurrences
    , findDemand
    , findDemandByType
    , planCoreMonomorphization
    , planCoreMonomorphizationWith
    , specializationCandidate
    ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Monomorphization.Discovery
import Progmasoft.Tala.Core.Monomorphization.Graph
import Progmasoft.Tala.Core.Monomorphization.Types
import Progmasoft.Tala.Core.Specialization
import Progmasoft.Tala.Core.Template

data PendingDemand = PendingDemand
    { pendingType :: Type
    , pendingOrigin :: DemandOrigin
    , pendingDepth :: Int
    }

data PlanningState = PlanningState
    { planningCatalog :: SpecializationCatalog
    , planningDemands :: Map DemandId MonomorphizationDemand
    , planningIdentityIds :: Map String DemandId
    , planningQueue :: [PendingDemand]
    , planningRootOccurrences :: Int
    , planningOriginCount :: Int
    , planningCacheHits :: Int
    }

-- | Plan demands using 'defaultMonomorphizationLimits'.
planCoreMonomorphization :: CoreModule -> Either MonomorphizationError MonomorphizationPlan
planCoreMonomorphization = planCoreMonomorphizationWith defaultMonomorphizationLimits

-- | Plan and verify the full specialization graph under caller-supplied limits.
planCoreMonomorphizationWith ::
    MonomorphizationLimits ->
    CoreModule ->
    Either MonomorphizationError MonomorphizationPlan
planCoreMonomorphizationWith limits coreModule = do
    validateLimits limits
    let occurrences = discoverTypeOccurrences coreModule
        initial =
            PlanningState
                emptyCatalog
                Map.empty
                Map.empty
                [PendingDemand (occurrenceType item) (RootDemand (occurrenceLocation item)) 0 | item <- occurrences]
                (length occurrences)
                0
                0
    completed <- drainQueue limits initial
    let plan = finishPlan completed
        graphIssues = validateDemandGraph plan
    if null graphIssues
        then Right plan
        else Left (InvalidCompletedDemandGraph (map show graphIssues))

drainQueue :: MonomorphizationLimits -> PlanningState -> Either MonomorphizationError PlanningState
drainQueue limits state = case planningQueue state of
    [] -> Right state
    pending : remaining -> do
        let withoutHead = state {planningQueue = remaining}
        updated <- acceptDemand limits pending withoutHead
        drainQueue limits updated

acceptDemand ::
    MonomorphizationLimits ->
    PendingDemand ->
    PlanningState ->
    Either MonomorphizationError PlanningState
acceptDemand limits pending state
    | pendingDepth pending > maximumDemandDepth limits =
        Left (DemandDepthExceeded (maximumDemandDepth limits) (pendingOrigin pending) (pendingType pending))
    | otherwise = do
        concrete <- mapSpecializationError pending (prepareSpecialization [] [] (pendingType pending))
        let identity = renderTemplateIdentity concrete
        case Map.lookup identity (planningIdentityIds state) of
            Just demandId -> attachExistingOrigin limits demandId pending state
            Nothing -> createDemand limits identity concrete pending state

createDemand ::
    MonomorphizationLimits ->
    String ->
    Type ->
    PendingDemand ->
    PlanningState ->
    Either MonomorphizationError PlanningState
createDemand limits identity concrete pending state
    | Map.size (planningDemands state) >= maximumSpecializationDemands limits =
        Left (SpecializationLimitExceeded (maximumSpecializationDemands limits) (pendingOrigin pending) concrete)
    | planningOriginCount state >= maximumDemandOrigins limits =
        Left (DemandOriginLimitExceeded (maximumDemandOrigins limits) (pendingOrigin pending) concrete)
    | otherwise = do
        (specialization, inserted, catalog) <-
            mapSpecializationError pending (internSpecialization concrete (planningCatalog state))
        if not inserted
            then Left (InternalMissingDemand identity)
            else do
                let demandId = DemandId (specializationIdValue (specializationId specialization))
                    dependencies = directTypeDependencies concrete
                    queued =
                        [ PendingDemand dependency (DependencyDemand demandId argumentIndex) (pendingDepth pending + 1)
                        | (argumentIndex, dependency) <- dependencies
                        ]
                    demand =
                        MonomorphizationDemand
                            demandId
                            specialization
                            [pendingOrigin pending]
                            []
                            (pendingDepth pending)
                            DemandQueued
                    withDemand =
                        state
                            { planningCatalog = catalog
                            , planningDemands = Map.insert demandId demand (planningDemands state)
                            , planningIdentityIds = Map.insert identity demandId (planningIdentityIds state)
                            , planningQueue = planningQueue state ++ queued
                            , planningOriginCount = planningOriginCount state + 1
                            }
                pure (completeDemandDependencies demandId dependencies withDemand)

attachExistingOrigin ::
    MonomorphizationLimits ->
    DemandId ->
    PendingDemand ->
    PlanningState ->
    Either MonomorphizationError PlanningState
attachExistingOrigin limits demandId pending state = case Map.lookup demandId (planningDemands state) of
    Nothing -> Left (InternalMissingDemand (renderTemplateIdentity (pendingType pending)))
    Just demand
        | pendingOrigin pending `elem` monomorphizationOrigins demand ->
            Right state {planningCacheHits = planningCacheHits state + 1}
        | planningOriginCount state >= maximumDemandOrigins limits ->
            Left
                ( DemandOriginLimitExceeded
                    (maximumDemandOrigins limits)
                    (pendingOrigin pending)
                    (pendingType pending)
                )
        | otherwise ->
            let updatedDemand =
                    demand
                        { monomorphizationOrigins = monomorphizationOrigins demand ++ [pendingOrigin pending]
                        , monomorphizationDepth = min (monomorphizationDepth demand) (pendingDepth pending)
                        }
             in Right
                    state
                        { planningDemands = Map.insert demandId updatedDemand (planningDemands state)
                        , planningOriginCount = planningOriginCount state + 1
                        , planningCacheHits = planningCacheHits state + 1
                        }

-- Dependency IDs may not exist when a parent is first accepted.  The final
-- edge set is therefore reconstructed from canonical identities after the
-- queue reaches a fixed point.  This helper only marks the parent complete
-- once its immediate children have been enqueued.
completeDemandDependencies :: DemandId -> [(Int, Type)] -> PlanningState -> PlanningState
completeDemandDependencies demandId _ state =
    state
        { planningDemands =
            Map.adjust
                (\demand -> demand {monomorphizationState = DemandComplete})
                demandId
                (planningDemands state)
        }

finishPlan :: PlanningState -> MonomorphizationPlan
finishPlan state =
    let demands = map (resolveDependencies state) (Map.elems (planningDemands state))
        edgeCount = sum (map (length . monomorphizationDependencies) demands)
        deepest = foldl' max 0 (map monomorphizationDepth demands)
        statistics =
            MonomorphizationStatistics
                (planningRootOccurrences state)
                (length demands)
                edgeCount
                (planningCacheHits state)
                deepest
     in MonomorphizationPlan demands statistics

resolveDependencies :: PlanningState -> MonomorphizationDemand -> MonomorphizationDemand
resolveDependencies state demand =
    demand
        { monomorphizationDependencies =
            unique
                [ dependencyId
                | (_, dependency) <- directTypeDependencies (specializationType (monomorphizationSpecialization demand))
                , let identity = renderTemplateIdentity dependency
                , Just dependencyId <- [Map.lookup identity (planningIdentityIds state)]
                ]
        }

-- | Look up a planned specialization by its stable demand identifier.
findDemand :: DemandId -> MonomorphizationPlan -> Maybe MonomorphizationDemand
findDemand demandId = lookup demandId . map pair . monomorphizationDemands
    where
        pair demand = (monomorphizationDemandId demand, demand)

-- | Find the canonical planned specialization matching a concrete type.
findDemandByType :: Type -> MonomorphizationPlan -> Maybe MonomorphizationDemand
findDemandByType valueType =
    findByIdentity (renderTemplateIdentity valueType) . monomorphizationDemands
    where
        findByIdentity _ [] = Nothing
        findByIdentity identity (demand : remaining)
            | specializationIdentity (monomorphizationSpecialization demand) == identity = Just demand
            | otherwise = findByIdentity identity remaining

validateLimits :: MonomorphizationLimits -> Either MonomorphizationError ()
validateLimits limits
    | maximumSpecializationDemands limits <= 0 =
        Left (InvalidMonomorphizationLimits "maximum demand count must be positive")
    | maximumDemandDepth limits < 0 = Left (InvalidMonomorphizationLimits "maximum demand depth cannot be negative")
    | maximumDemandOrigins limits <= 0 = Left (InvalidMonomorphizationLimits "maximum origin count must be positive")
    | otherwise = Right ()

mapSpecializationError ::
    PendingDemand ->
    Either SpecializationError value ->
    Either MonomorphizationError value
mapSpecializationError pending result = case result of
    Left failure -> Left (InvalidDemandType (pendingOrigin pending) failure)
    Right value -> Right value

unique :: (Eq value) => [value] -> [value]
unique = foldl' append []
    where
        append values value
            | value `elem` values = values
            | otherwise = values ++ [value]
