-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- |
Semantic reachability for members of one template declaration.

Template specialization is lazy at member granularity.  A request for one
member must nevertheless retain every same-declaration member reached by a
resolved call from its body.  The call graph is keyed by @SymbolId@, never by
spelling: overloads can share a source name while remaining distinct semantic
definitions.

Calls whose target is not a direct member of the declaration are deliberately
classified as external.  This module does not guess inheritance, extension,
dynamic dispatch, or another declaration's ownership from a name.  Those
decisions belong to name and call resolution before specialization.
-}
module Progmasoft.Tala.Template.MemberReachability
    ( TemplateMemberCall (..)
    , TemplateMemberNode (..)
    , TemplateMemberGraph (..)
    , TemplateMemberReachabilityStatistics (..)
    , TemplateMemberReachability (..)
    , TemplateMemberReachabilityError (..)
    , TemplateMemberReachabilityIssue (..)
    , buildTemplateMemberGraph
    , selectReachableMembersByName
    , selectReachableMembersBySymbol
    , verifyTemplateMemberReachability
    , renderTemplateMemberReachabilityError
    , renderTemplateMemberReachabilityIssue
    ) where

import Data.List (intercalate)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Progmasoft.Tala.AST

{- | One direct call expression.  Repeated calls remain distinct evidence even
when they later collapse to one graph edge.
-}
data TemplateMemberCall = TemplateMemberCall
    { templateCallOwner :: SymbolId
    -- ^ Caller member identity.
    , templateCallTarget :: SymbolId
    -- ^ Resolved direct callee identity.
    , templateCallSpan :: SourceSpan
    -- ^ Source location of the call expression.
    }
    deriving (Eq, Ord, Read, Show)

{- | A node retains source order and declaration identity.  Source order is
used only to make output deterministic; it never chooses an overload.
-}
data TemplateMemberNode = TemplateMemberNode
    { templateMemberIndex :: Int
    -- ^ Source-order index within the declaration.
    , templateMemberSymbol :: SymbolId
    -- ^ Unique resolved identity, not spelling.
    , templateMemberName :: Identifier
    -- ^ Source name; overloads may share it.
    , templateMemberCallable :: Bool
    -- ^ Whether the member has an executable body.
    , templateMemberCalls :: [TemplateMemberCall]
    -- ^ Direct calls found in its body.
    }
    deriving (Eq, Ord, Read, Show)

-- | Direct-member call graph partitioned into internal and external calls.
data TemplateMemberGraph = TemplateMemberGraph
    { templateGraphNodes :: [TemplateMemberNode]
    -- ^ Nodes in declaration source order.
    , templateGraphInternalCalls :: [TemplateMemberCall]
    -- ^ Calls whose target is another direct member.
    , templateGraphExternalCalls :: [TemplateMemberCall]
    -- ^ Calls leaving this declaration's member set.
    }
    deriving (Eq, Ord, Read, Show)

-- | Counts describing graph construction and selected member closure.
data TemplateMemberReachabilityStatistics = TemplateMemberReachabilityStatistics
    { totalTemplateMembers :: Int
    -- ^ All direct members in the declaration.
    , callableTemplateMembers :: Int
    -- ^ Members with callable bodies.
    , requestedTemplateMemberRoots :: Int
    -- ^ Unique selected root symbols.
    , reachableTemplateMembers :: Int
    -- ^ Members retained by transitive closure.
    , observedTemplateMemberCalls :: Int
    -- ^ Internal and external call occurrences.
    , internalTemplateMemberCalls :: Int
    -- ^ Calls with same-declaration targets.
    , externalTemplateMemberCalls :: Int
    -- ^ Calls whose targets are outside the graph.
    , uniqueTemplateMemberEdges :: Int
    -- ^ Distinct internal caller/callee pairs.
    }
    deriving (Eq, Ord, Read, Show)

-- | Root requests, transitively retained members, edges, and graph metrics.
data TemplateMemberReachability = TemplateMemberReachability
    { memberReachabilityRoots :: [SymbolId]
    -- ^ Selected root identities in source order.
    , memberReachabilitySymbols :: [SymbolId]
    -- ^ Roots and all transitively reached members.
    , memberReachabilityMembers :: [Declaration ResolvedName Type]
    -- ^ Original member declarations retained.
    , memberReachabilityEdges :: [(SymbolId, SymbolId)]
    -- ^ Unique internal call edges among selected members.
    , memberReachabilityStatistics :: TemplateMemberReachabilityStatistics
    -- ^ Counts for the analyzed graph.
    }
    deriving (Eq, Ord, Read, Show)

-- | Invalid root graph or request that cannot be resolved to a direct member.
data TemplateMemberReachabilityError
    = -- | Member identity is reserved or invalid.
      InvalidTemplateMemberSymbol Identifier SymbolId
    | -- | Multiple member declarations share an identity.
      DuplicateTemplateMemberSymbol SymbolId [Identifier]
    | -- | Requested spelling has no member.
      MissingTemplateMemberName Identifier
    | -- | Requested semantic identity has no member.
      MissingTemplateMemberSymbol SymbolId
    deriving (Eq, Ord, Read, Show)

-- | Independently checkable inconsistency in a claimed reachability result.
data TemplateMemberReachabilityIssue
    = -- | A requested root is not declared directly.
      ReachabilityRootIsNotMember SymbolId
    | -- | A selected identity is not in the graph.
      ReachabilitySelectionIsNotMember SymbolId
    | -- | The root list repeats a symbol.
      DuplicateReachabilityRoot SymbolId
    | -- | The selection repeats a symbol.
      DuplicateReachabilitySelection SymbolId
    | -- | A root is absent from the closure.
      ReachabilityRootNotSelected SymbolId
    | -- | A selected call omits its in-graph callee.
      ReachabilityDependencyNotSelected SymbolId SymbolId
    | -- | An edge is not supported by a recorded call.
      UnexpectedReachabilityEdge SymbolId SymbolId
    | -- | A recorded internal call has no reported edge.
      MissingReachabilityEdge SymbolId SymbolId
    | -- | Declaration and symbol lists disagree.
      ReachabilityMembersDiffer [SymbolId] [SymbolId]
    | -- | Reported counts differ from recomputation.
      IncorrectReachabilityStatistics TemplateMemberReachabilityStatistics TemplateMemberReachabilityStatistics
    deriving (Eq, Ord, Read, Show)

{- | Construct a declaration-local graph after semantic resolution.  Invalid
or duplicated symbols are rejected here even though the general template
verifier normally diagnoses them earlier; this keeps the API safe for
compiler tests and independently constructed TypedAST values.
-}
buildTemplateMemberGraph ::
    [Declaration ResolvedName Type] ->
    Either [TemplateMemberReachabilityError] TemplateMemberGraph
buildTemplateMemberGraph members = case validationProblems of
    [] -> Right graph
    problems -> Left problems
    where
        nodes = zipWith memberNode [0 ..] members
        memberSymbols = map templateMemberSymbol nodes
        memberSet = Set.fromList memberSymbols
        calls = concatMap templateMemberCalls nodes
        graph =
            TemplateMemberGraph
                nodes
                [call | call <- calls, templateCallTarget call `Set.member` memberSet]
                [call | call <- calls, templateCallTarget call `Set.notMember` memberSet]
        invalid =
            [ InvalidTemplateMemberSymbol (templateMemberName node) (templateMemberSymbol node)
            | node <- nodes
            , symbolIdValue (templateMemberSymbol node) <= 0
            ]
        duplicated =
            [ DuplicateTemplateMemberSymbol symbol [templateMemberName node | node <- nodes, templateMemberSymbol node == symbol]
            | symbol <- duplicates memberSymbols
            ]
        validationProblems = invalid ++ duplicated

-- | Select every overload with a requested spelling and follow internal calls.
selectReachableMembersByName ::
    [Identifier] ->
    [Declaration ResolvedName Type] ->
    Either [TemplateMemberReachabilityError] TemplateMemberReachability
selectReachableMembersByName requested members = do
    graph <- buildTemplateMemberGraph members
    let names = unique requested
        nodes = templateGraphNodes graph
        missing = [name | name <- names, name `notElem` map templateMemberName nodes]
        roots =
            [ templateMemberSymbol node
            | node <- nodes
            , templateMemberName node `elem` names
            ]
    if null missing
        then Right (selectFromGraph roots members graph)
        else Left (map MissingTemplateMemberName missing)

-- | Select exact semantic member identities and follow internal calls.
selectReachableMembersBySymbol ::
    [SymbolId] ->
    [Declaration ResolvedName Type] ->
    Either [TemplateMemberReachabilityError] TemplateMemberReachability
selectReachableMembersBySymbol requested members = do
    graph <- buildTemplateMemberGraph members
    let roots = unique requested
        available = map templateMemberSymbol (templateGraphNodes graph)
        missing = [symbol | symbol <- roots, symbol `notElem` available]
    if null missing
        then Right (selectFromGraph roots members graph)
        else Left (map MissingTemplateMemberSymbol missing)

selectFromGraph ::
    [SymbolId] ->
    [Declaration ResolvedName Type] ->
    TemplateMemberGraph ->
    TemplateMemberReachability
selectFromGraph roots members graph =
    TemplateMemberReachability
        orderedRoots
        selectedSymbols
        [member | member <- members, declarationSymbol member `Set.member` selectedSet]
        selectedEdges
        statistics
    where
        nodes = templateGraphNodes graph
        sourceOrder = map templateMemberSymbol nodes
        orderedRoots = [symbol | symbol <- sourceOrder, symbol `elem` roots]
        adjacency = adjacencyTable (templateGraphInternalCalls graph)
        selectedSet = closeReachability adjacency Set.empty orderedRoots
        selectedSymbols = [symbol | symbol <- sourceOrder, symbol `Set.member` selectedSet]
        selectedEdges =
            unique
                [ (templateCallOwner call, templateCallTarget call)
                | call <- templateGraphInternalCalls graph
                , templateCallOwner call `Set.member` selectedSet
                ]
        calls = templateGraphInternalCalls graph ++ templateGraphExternalCalls graph
        statistics =
            TemplateMemberReachabilityStatistics
                { totalTemplateMembers = length nodes
                , callableTemplateMembers = length [() | node <- nodes, templateMemberCallable node]
                , requestedTemplateMemberRoots = length orderedRoots
                , reachableTemplateMembers = length selectedSymbols
                , observedTemplateMemberCalls = length calls
                , internalTemplateMemberCalls = length (templateGraphInternalCalls graph)
                , externalTemplateMemberCalls = length (templateGraphExternalCalls graph)
                , uniqueTemplateMemberEdges = length (unique (map callEdge (templateGraphInternalCalls graph)))
                }

adjacencyTable :: [TemplateMemberCall] -> Map SymbolId [SymbolId]
adjacencyTable = foldl' insert Map.empty
    where
        insert table call =
            Map.insertWith
                (\new old -> unique (old ++ new))
                (templateCallOwner call)
                [templateCallTarget call]
                table

closeReachability :: Map SymbolId [SymbolId] -> Set SymbolId -> [SymbolId] -> Set SymbolId
closeReachability _ visited [] = visited
closeReachability adjacency visited (symbol : pending)
    | symbol `Set.member` visited = closeReachability adjacency visited pending
    | otherwise =
        let dependencies = Map.findWithDefault [] symbol adjacency
         in closeReachability adjacency (Set.insert symbol visited) (pending ++ dependencies)

{- | Recompute graph facts from declarations and compare them with a retained
result.  The specialization-plan verifier uses the selected declaration for
broader invariants; this verifier protects the reachability object itself.
-}
verifyTemplateMemberReachability ::
    [Declaration ResolvedName Type] ->
    TemplateMemberReachability ->
    Either [TemplateMemberReachabilityError] [TemplateMemberReachabilityIssue]
verifyTemplateMemberReachability members reachability = do
    graph <- buildTemplateMemberGraph members
    let available = map templateMemberSymbol (templateGraphNodes graph)
        roots = memberReachabilityRoots reachability
        selected = memberReachabilitySymbols reachability
        actualMembers = map declarationSymbol (memberReachabilityMembers reachability)
        expected = selectFromGraph roots members graph
        expectedEdges = memberReachabilityEdges expected
        actualEdges = memberReachabilityEdges reachability
        rootProblems =
            [ReachabilityRootIsNotMember symbol | symbol <- roots, symbol `notElem` available]
                ++ [DuplicateReachabilityRoot symbol | symbol <- duplicates roots]
                ++ [ReachabilityRootNotSelected symbol | symbol <- roots, symbol `notElem` selected]
        selectionProblems =
            [ReachabilitySelectionIsNotMember symbol | symbol <- selected, symbol `notElem` available]
                ++ [DuplicateReachabilitySelection symbol | symbol <- duplicates selected]
        closureProblems =
            [ ReachabilityDependencyNotSelected owner target
            | (owner, target) <- expectedEdges
            , owner `elem` selected
            , target `notElem` selected
            ]
        edgeProblems =
            [UnexpectedReachabilityEdge owner target | (owner, target) <- actualEdges, (owner, target) `notElem` expectedEdges]
                ++ [MissingReachabilityEdge owner target | (owner, target) <- expectedEdges, (owner, target) `notElem` actualEdges]
        memberProblems =
            [ReachabilityMembersDiffer selected actualMembers | selected /= actualMembers]
        statisticProblems =
            [ IncorrectReachabilityStatistics
                (memberReachabilityStatistics expected)
                (memberReachabilityStatistics reachability)
            | memberReachabilityStatistics expected /= memberReachabilityStatistics reachability
            ]
    pure (rootProblems ++ selectionProblems ++ closureProblems ++ edgeProblems ++ memberProblems ++ statisticProblems)

memberNode :: Int -> Declaration ResolvedName Type -> TemplateMemberNode
memberNode index member =
    TemplateMemberNode
        index
        (declarationSymbol member)
        (resolvedSpelling (declarationName member))
        (isFunction member)
        (memberCalls (declarationSymbol member) member)

isFunction :: Declaration name annotation -> Bool
isFunction FunctionDeclaration {} = True
isFunction _ = False

memberCalls :: SymbolId -> Declaration ResolvedName Type -> [TemplateMemberCall]
memberCalls owner declaration = case declaration of
    FunctionDeclaration {declarationBody = body} -> blockCalls owner body
    -- Nested types have their own member ownership domain.  Their bodies must
    -- not accidentally pull siblings into the enclosing template closure.
    TypeDeclaration {} -> []
    TemplateTypeDeclaration {} -> []
    EnumDeclaration {} -> []

blockCalls :: SymbolId -> Block ResolvedName Type -> [TemplateMemberCall]
blockCalls owner (Block statements) = concatMap (statementCalls owner) statements

statementCalls :: SymbolId -> Statement ResolvedName Type -> [TemplateMemberCall]
statementCalls owner statement = case statement of
    BindingStatement _ _ _ _ _ value -> expressionCalls owner value
    AssignmentStatement _ _ _ value -> expressionCalls owner value
    ReturnStatement _ value -> maybe [] (expressionCalls owner) value
    IfStatement _ condition trueBlock falseBlock ->
        expressionCalls owner condition
            ++ blockCalls owner trueBlock
            ++ maybe [] (blockCalls owner) falseBlock
    WhileStatement _ condition body -> expressionCalls owner condition ++ blockCalls owner body
    DoWhileStatement _ body condition -> blockCalls owner body ++ expressionCalls owner condition
    ForStatement _ initializer condition updates body ->
        maybe [] (statementCalls owner) initializer
            ++ maybe [] (expressionCalls owner) condition
            ++ concatMap (statementCalls owner) updates
            ++ blockCalls owner body
    ForEachStatement _ _ _ _ _ source body -> expressionCalls owner source ++ blockCalls owner body
    IncrementStatement {} -> []
    CompoundAssignmentStatement _ _ _ _ value -> expressionCalls owner value
    DiscardStatement _ value -> expressionCalls owner value
    BreakStatement _ value -> maybe [] (expressionCalls owner) value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> expressionCalls owner condition ++ blockCalls owner block
    BlockStatement _ block -> blockCalls owner block
    ExpressionStatement _ value _ -> expressionCalls owner value

expressionCalls :: SymbolId -> Expression ResolvedName Type -> [TemplateMemberCall]
expressionCalls owner expression = case expression of
    NameExpression {} -> []
    LiteralExpression {} -> []
    MemberAccessExpression _ receiver _ _ -> expressionCalls owner receiver
    MethodReferenceExpression _ receiver _ _ -> expressionCalls owner receiver
    CallExpression spanValue callee arguments _ ->
        directCall spanValue callee
            ++ expressionCalls owner callee
            ++ concatMap (expressionCalls owner) arguments
    UnaryExpression _ _ value _ -> expressionCalls owner value
    BinaryExpression _ _ left right _ -> expressionCalls owner left ++ expressionCalls owner right
    IsPatternExpression _ subject _ _ -> expressionCalls owner subject
    -- Reachability is path-insensitive: a call in either arm may execute.
    ConditionalExpression _ condition first second _ ->
        concatMap (expressionCalls owner) [condition, first, second]
    CoalesceExpression _ left fallback _ -> expressionCalls owner left ++ expressionCalls owner fallback
    AssignmentExpression _ _ _ value _ -> expressionCalls owner value
    IncrementExpression {} -> []
    LoopExpression _ loop _ -> statementCalls owner loop
    BlockExpression _ block _ -> blockCalls owner block
    -- Reachability is path-insensitive: a call in any arm may execute.
    MatchExpression _ subjects arms _ ->
        concatMap (expressionCalls owner) (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression _ _ captures _ body _ ->
        concatMap (maybe [] (expressionCalls owner) . captureInitializer) captures
            ++ callableBodyCalls owner body
    where
        directCall spanValue callee = case callee of
            NameExpression _ target _ -> [TemplateMemberCall owner (resolvedSymbol target) spanValue]
            _ -> []

callableBodyCalls :: SymbolId -> CallableBody ResolvedName Type -> [TemplateMemberCall]
callableBodyCalls owner body = case body of
    CallableExpressionBody value -> expressionCalls owner value
    CallableBlockBody block -> blockCalls owner block

callEdge :: TemplateMemberCall -> (SymbolId, SymbolId)
callEdge call = (templateCallOwner call, templateCallTarget call)

declarationSymbol :: Declaration ResolvedName annotation -> SymbolId
declarationSymbol = resolvedSymbol . declarationName

-- | Render a graph-construction or root-selection failure.
renderTemplateMemberReachabilityError :: TemplateMemberReachabilityError -> String
renderTemplateMemberReachabilityError problem = case problem of
    InvalidTemplateMemberSymbol name symbol ->
        "template member " ++ identifierText name ++ " has invalid " ++ renderSymbol symbol
    DuplicateTemplateMemberSymbol symbol names ->
        renderSymbol symbol
            ++ " is shared by template members "
            ++ intercalate ", " (map identifierText names)
    MissingTemplateMemberName name -> "template declaration has no member named " ++ identifierText name
    MissingTemplateMemberSymbol symbol -> "template declaration has no member with " ++ renderSymbol symbol

-- | Render a verifier issue from an inconsistent reachability result.
renderTemplateMemberReachabilityIssue :: TemplateMemberReachabilityIssue -> String
renderTemplateMemberReachabilityIssue problem = case problem of
    ReachabilityRootIsNotMember symbol -> "reachability root is not a declaration member: " ++ renderSymbol symbol
    ReachabilitySelectionIsNotMember symbol -> "selected reachability symbol is not a declaration member: " ++ renderSymbol symbol
    DuplicateReachabilityRoot symbol -> "reachability root occurs more than once: " ++ renderSymbol symbol
    DuplicateReachabilitySelection symbol -> "selected reachability symbol occurs more than once: " ++ renderSymbol symbol
    ReachabilityRootNotSelected symbol -> "reachability root is absent from its selection: " ++ renderSymbol symbol
    ReachabilityDependencyNotSelected owner target ->
        "selected " ++ renderSymbol owner ++ " calls unselected " ++ renderSymbol target
    UnexpectedReachabilityEdge owner target ->
        "reachability contains an unobserved edge " ++ renderEdge owner target
    MissingReachabilityEdge owner target ->
        "reachability omits observed edge " ++ renderEdge owner target
    ReachabilityMembersDiffer expected actual ->
        "reachability member declarations differ: expected "
            ++ renderSymbols expected
            ++ ", found "
            ++ renderSymbols actual
    IncorrectReachabilityStatistics expected actual ->
        "reachability statistics differ: expected " ++ show expected ++ ", found " ++ show actual

renderSymbol :: SymbolId -> String
renderSymbol (SymbolId value) = "SymbolId " ++ show value

renderEdge :: SymbolId -> SymbolId -> String
renderEdge owner target = renderSymbol owner ++ " -> " ++ renderSymbol target

renderSymbols :: [SymbolId] -> String
renderSymbols values = "[" ++ intercalate ", " (map renderSymbol values) ++ "]"

duplicates :: (Ord value) => [value] -> [value]
duplicates values = Set.toList (go Set.empty Set.empty values)
    where
        go _ repeated [] = repeated
        go seen repeated (value : remaining)
            | value `Set.member` seen = go seen (Set.insert value repeated) remaining
            | otherwise = go (Set.insert value seen) repeated remaining

unique :: (Ord value) => [value] -> [value]
unique = go Set.empty
    where
        go _ [] = []
        go seen (value : remaining)
            | value `Set.member` seen = go seen remaining
            | otherwise = value : go (Set.insert value seen) remaining
