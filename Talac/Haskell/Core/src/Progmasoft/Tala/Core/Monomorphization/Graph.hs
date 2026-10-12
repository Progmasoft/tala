-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Queries and invariants for a completed specialization-demand graph.

Instantiation needs children before parents when concrete layout depends on a
nested specialization.  The discovery queue is intentionally root-first for
good diagnostics, so emission order is derived here instead of overloading the
meaning of demand identifiers.
-}
module Progmasoft.Tala.Core.Monomorphization.Graph
    ( DemandGraphIssue (..)
    , demandLeaves
    , demandRoots
    , dependentDemands
    , reachableDependencies
    , renderDemandTrace
    , specializationEmissionOrder
    , validateDemandGraph
    ) where

import Data.List (intercalate, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Progmasoft.Tala.Core.Monomorphization.Types
import Progmasoft.Tala.Core.Specialization

-- | Structural or accounting invariant violated by a completed demand graph.
data DemandGraphIssue
    = DuplicateDemandIdentifier DemandId
    | NonPositiveDemandIdentifier DemandId
    | MissingDependency DemandId DemandId
    | DuplicateDependency DemandId DemandId
    | SelfDependency DemandId
    | IncompleteDemand DemandId
    | CyclicDemandPath [DemandId]
    | StatisticsDemandCountMismatch Int Int
    | StatisticsEdgeCountMismatch Int Int
    | StatisticsDepthMismatch Int Int
    deriving (Eq, Ord, Read, Show)

-- | Check identifiers, edges, completion state, acyclicity, and statistics.
validateDemandGraph :: MonomorphizationPlan -> [DemandGraphIssue]
validateDemandGraph plan =
    identifierIssues
        ++ dependencyIssues
        ++ stateIssues
        ++ cycleIssues
        ++ statisticsIssues
    where
        demands = monomorphizationDemands plan
        demandIds = map monomorphizationDemandId demands
        known = Set.fromList demandIds
        identifierIssues =
            [ NonPositiveDemandIdentifier demandId
            | demandId@(DemandId value) <- demandIds
            , value <= 0
            ]
                ++ [ DuplicateDemandIdentifier demandId
                   | groupIds@(demandId : _) <- grouped demandIds
                   , length groupIds > 1
                   ]
        dependencyIssues = concatMap (validateDependencies known) demands
        stateIssues =
            [ IncompleteDemand (monomorphizationDemandId demand)
            | demand <- demands
            , monomorphizationState demand /= DemandComplete
            ]
        cycleIssues = case specializationEmissionOrder plan of
            Left cyclePath -> [CyclicDemandPath cyclePath]
            Right _ -> []
        statistics = monomorphizationStatistics plan
        actualCount = length demands
        actualEdges = sum (map (length . monomorphizationDependencies) demands)
        actualDepth = foldl max 0 (map monomorphizationDepth demands)
        statisticsIssues =
            [ StatisticsDemandCountMismatch (uniqueSpecializationDemands statistics) actualCount
            | uniqueSpecializationDemands statistics /= actualCount
            ]
                ++ [ StatisticsEdgeCountMismatch (specializationDependencyEdges statistics) actualEdges
                   | specializationDependencyEdges statistics /= actualEdges
                   ]
                ++ [ StatisticsDepthMismatch (deepestSpecializationDemand statistics) actualDepth
                   | deepestSpecializationDemand statistics /= actualDepth
                   ]

validateDependencies :: Set DemandId -> MonomorphizationDemand -> [DemandGraphIssue]
validateDependencies known demand =
    [ MissingDependency owner dependency
    | dependency <- dependencies
    , dependency `Set.notMember` known
    ]
        ++ [ DuplicateDependency owner dependency
           | duplicate@(dependency : _) <- grouped dependencies
           , length duplicate > 1
           ]
        ++ [SelfDependency owner | owner `elem` dependencies]
    where
        owner = monomorphizationDemandId demand
        dependencies = monomorphizationDependencies demand

-- | Select demands that have at least one source/Core root occurrence.
demandRoots :: MonomorphizationPlan -> [MonomorphizationDemand]
demandRoots = filter hasRootOrigin . monomorphizationDemands
    where
        hasRootOrigin = any isRoot . monomorphizationOrigins
        isRoot (RootDemand _) = True
        isRoot (DependencyDemand _ _) = False

-- | Select demands that introduce no further specialization dependencies.
demandLeaves :: MonomorphizationPlan -> [MonomorphizationDemand]
demandLeaves = filter (null . monomorphizationDependencies) . monomorphizationDemands

-- | Find direct parents whose dependency list contains the requested demand.
dependentDemands :: DemandId -> MonomorphizationPlan -> [MonomorphizationDemand]
dependentDemands dependency =
    filter (elem dependency . monomorphizationDependencies) . monomorphizationDemands

-- | Return the transitive dependencies reachable from one demand, excluding it.
reachableDependencies :: DemandId -> MonomorphizationPlan -> [MonomorphizationDemand]
reachableDependencies root plan =
    let table = demandTable plan
        ids = walk table Set.empty [root]
     in [demand | demandId <- ids, Just demand <- [Map.lookup demandId table], demandId /= root]
    where
        walk _ _ [] = []
        walk table visited (current : remaining)
            | current `Set.member` visited = walk table visited remaining
            | otherwise =
                let dependencies = maybe [] monomorphizationDependencies (Map.lookup current table)
                 in current : walk table (Set.insert current visited) (dependencies ++ remaining)

{- | Produce a stable postorder. Sibling order follows demand identifiers,
which reflect first discovery order within one deterministic compilation.
-}
specializationEmissionOrder :: MonomorphizationPlan -> Either [DemandId] [MonomorphizationDemand]
specializationEmissionOrder plan = do
    let table = demandTable plan
        roots = map monomorphizationDemandId (monomorphizationDemands plan)
    (_, reverseOrder) <- visitMany table Set.empty [] [] roots
    pure [demand | demandId <- reverse reverseOrder, Just demand <- [Map.lookup demandId table]]

visitMany ::
    Map DemandId MonomorphizationDemand ->
    Set DemandId ->
    [DemandId] ->
    [DemandId] ->
    [DemandId] ->
    Either [DemandId] (Set DemandId, [DemandId])
visitMany _ complete _ output [] = Right (complete, output)
visitMany table complete active output (demandId : remaining) = do
    (updatedComplete, updatedOutput) <- visitOne table complete active output demandId
    visitMany table updatedComplete active updatedOutput remaining

visitOne ::
    Map DemandId MonomorphizationDemand ->
    Set DemandId ->
    [DemandId] ->
    [DemandId] ->
    DemandId ->
    Either [DemandId] (Set DemandId, [DemandId])
visitOne table complete active output demandId
    | demandId `Set.member` complete = Right (complete, output)
    | demandId `elem` active = Left (cycleFrom demandId active)
    | otherwise = case Map.lookup demandId table of
        Nothing -> Right (complete, output)
        Just demand -> do
            let nextActive = demandId : active
                dependencies = sort (monomorphizationDependencies demand)
            (childrenComplete, childrenOutput) <- visitMany table complete nextActive output dependencies
            pure (Set.insert demandId childrenComplete, demandId : childrenOutput)

-- | Render one demand with its identity, depth, origins, and outgoing edges.
renderDemandTrace :: MonomorphizationPlan -> DemandId -> String
renderDemandTrace plan demandId = case Map.lookup demandId (demandTable plan) of
    Nothing -> "unknown demand " ++ renderDemandId demandId
    Just demand ->
        renderDemandId demandId
            ++ " "
            ++ specializationIdentity (monomorphizationSpecialization demand)
            ++ " depth="
            ++ show (monomorphizationDepth demand)
            ++ " origins=["
            ++ intercalate ", " (map renderOrigin (monomorphizationOrigins demand))
            ++ "] dependencies=["
            ++ intercalate ", " (map renderDemandId (monomorphizationDependencies demand))
            ++ "]"
    where
        renderOrigin origin = case origin of
            RootDemand location -> renderDemandLocation location
            DependencyDemand parent argumentIndex ->
                renderDemandId parent ++ ".argument[" ++ show argumentIndex ++ "]"

demandTable :: MonomorphizationPlan -> Map DemandId MonomorphizationDemand
demandTable =
    Map.fromList
        . map (\demand -> (monomorphizationDemandId demand, demand))
        . monomorphizationDemands

renderDemandId :: DemandId -> String
renderDemandId (DemandId value) = "demand#" ++ show value

cycleFrom :: DemandId -> [DemandId] -> [DemandId]
cycleFrom repeated active = repeated : reverse (takeThrough repeated active)
    where
        takeThrough _ [] = []
        takeThrough target (value : remaining)
            | value == target = [value]
            | otherwise = value : takeThrough target remaining

grouped :: (Ord value) => [value] -> [[value]]
grouped values = foldr collect [] (sort values)
    where
        collect value [] = [[value]]
        collect value groups@(first@(firstValue : _) : remaining)
            | value == firstValue = (value : first) : remaining
            | otherwise = [value] : groups
        collect value ([] : remaining) = [value] : remaining
