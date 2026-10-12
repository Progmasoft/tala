-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- |
Declaration-level template specialization planning.

The application binder answers whether arguments fit a declaration and the
instantiator substitutes them. This module joins those operations into an
immutable batch plan suitable for a later demand-driven Core lowering pass.
It deliberately accepts explicit semantic demands.  Resolved calls between
members of the selected declaration are followed by SymbolId so a lazy member
request remains closed under its internal call dependencies.  Constraint
ordering and cross-declaration dispatch remain separate future stages.
-}
module Progmasoft.Tala.Template.Specialization
    ( TemplateDemandScope (..)
    , TemplateSpecializationDemand (..)
    , TemplateSpecializationLimits (..)
    , defaultTemplateSpecializationLimits
    , TemplateSpecializationId (..)
    , TemplateSpecialization (..)
    , TemplateSpecializationStatistics (..)
    , TemplateSpecializationPlan (..)
    , TemplateSpecializationError (..)
    , planTemplateSpecializations
    , findTemplateSpecialization
    , findTemplateSpecializationByIdentity
    , specializationEmissionOrder
    , specializationTypedAST
    , renderTemplateSpecializationError
    ) where

import Data.List (intercalate, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Freshen
import Progmasoft.Tala.Template.Instantiation
import Progmasoft.Tala.Template.Mangling
import Progmasoft.Tala.Template.MemberReachability

{- | Layout-only requests do not instantiate method bodies. Member requests
select every overload carrying one of the requested spellings. Complete is
reserved for an explicit whole-declaration request; it is never inferred.
-}
data TemplateDemandScope
    = -- | Retain layout and signatures without method bodies.
      TemplateLayoutDemand
    | -- | Retain named methods and their call closure.
      TemplateMemberDemand [Identifier]
    | -- | Explicit request for the complete declaration.
      TemplateCompleteDemand
    deriving (Eq, Ord, Read, Show)

-- | One source or compiler request to materialize a template specialization.
data TemplateSpecializationDemand = TemplateSpecializationDemand
    { specializationDemandApplication :: TemplateApplication
    -- ^ Declaration and bound arguments requested.
    , specializationDemandScope :: TemplateDemandScope
    -- ^ Portion of the declaration that must be retained.
    , specializationDemandOrigin :: String
    -- ^ Stable provenance used in diagnostics and deduplication.
    }
    deriving (Eq, Ord, Read, Show)

-- | Resource ceilings preventing specialization requests from exhausting the compiler.
data TemplateSpecializationLimits = TemplateSpecializationLimits
    { maximumTemplateSpecializations :: Int
    -- ^ Maximum unique specializations in one plan.
    , maximumTemplateOrigins :: Int
    -- ^ Maximum recorded request origins.
    , maximumMembersPerSpecialization :: Int
    -- ^ Maximum materialized members per specialization.
    }
    deriving (Eq, Ord, Read, Show)

-- | Finite defaults suitable for normal compiler and project builds.
defaultTemplateSpecializationLimits :: TemplateSpecializationLimits
defaultTemplateSpecializationLimits = TemplateSpecializationLimits 4096 16384 4096

-- | Stable ordinal identity within one specialization plan.
newtype TemplateSpecializationId = TemplateSpecializationId
    { templateSpecializationIdValue :: Int
    }
    deriving (Eq, Ord, Read, Show)

-- | One closed specialization and all identities needed by later lowering.
data TemplateSpecialization = TemplateSpecialization
    { templateSpecializationId :: TemplateSpecializationId
    -- ^ Plan-local stable identity.
    , templateSpecializationIdentity :: String
    -- ^ Canonical concrete-type identity key.
    , templateSpecializationType :: Type
    -- ^ Closed concrete application type.
    , templateSpecializationScope :: TemplateDemandScope
    -- ^ Strongest coalesced materialization scope.
    , templateSpecializationOrigins :: [String]
    -- ^ All deduplicated request provenance strings.
    , templateSpecializationDependencies :: [TemplateSpecializationId]
    -- ^ Specializations referenced by this body.
    , templateSpecializationDeclaration :: Declaration ResolvedName Type
    -- ^ Instantiated and symbol-freshened declaration.
    , templateSpecializationSymbolMap :: [(SymbolId, SymbolId)]
    -- ^ Original-to-fresh definition identities.
    , templateSpecializationMangledType :: MangledTemplateType
    -- ^ Internal stable type symbol.
    , templateSpecializationMangledMembers :: [MangledTemplateMember]
    -- ^ Internal member symbols in declaration order.
    }
    deriving (Eq, Ord, Read, Show)

-- | Demand, coalescing, materialization, and dependency counts.
data TemplateSpecializationStatistics = TemplateSpecializationStatistics
    { requestedTemplateSpecializations :: Int
    -- ^ Number of input demands.
    , uniqueTemplateSpecializations :: Int
    -- ^ Number of retained concrete specializations.
    , coalescedTemplateSpecializations :: Int
    -- ^ Requests merged into existing entries.
    , instantiatedTemplateMembers :: Int
    -- ^ Total members materialized across entries.
    , retainedTemplateOrigins :: Int
    -- ^ Provenance strings retained after merging.
    , templateDependencyEdges :: Int
    -- ^ Number of specialization-to-specialization edges.
    }
    deriving (Eq, Ord, Read, Show)

-- | Immutable batch result consumed by dependency ordering and Core lowering.
data TemplateSpecializationPlan = TemplateSpecializationPlan
    { plannedTemplateNamespace :: Maybe QualifiedName
    -- ^ Namespace shared by source declarations.
    , plannedTemplateSpecializations :: [TemplateSpecialization]
    -- ^ Closed specializations retained in the plan.
    , plannedTemplateStatistics :: TemplateSpecializationStatistics
    -- ^ Aggregate counts for the plan.
    }
    deriving (Eq, Ord, Read, Show)

-- | Planning, binding, closure, resource, or internal-name generation failure.
data TemplateSpecializationError
    = -- | A configured plan limit is invalid.
      InvalidTemplateSpecializationLimits String
    | -- | Binding failed for this demand.
      TemplateApplicationFailed String [TemplateApplicationError]
    | -- | Substitution failed during materialization.
      TemplateInstantiationFailed String TemplateInstantiationError
    | -- | Bound declaration has no matching source.
      TemplateDeclarationSourceMissing QualifiedName SymbolId
    | -- | Requested member spelling is absent.
      TemplateMemberNotFound QualifiedName Identifier
    | -- | Type/value variables remain after binding.
      TemplateSpecializationRemainsOpen String [SymbolId]
    | -- | Unique specialization count exceeded its ceiling.
      TemplateSpecializationLimitExceeded Int String
    | -- | Recorded provenance exceeded its ceiling.
      TemplateOriginLimitExceeded Int String
    | -- | Materialized member count exceeded its ceiling.
      TemplateMemberLimitExceeded QualifiedName Int Int
    | -- | Member call closure could not be computed.
      TemplateMemberReachabilityFailed QualifiedName [TemplateMemberReachabilityError]
    | -- | Concrete identity could not be encoded.
      TemplateMangleFailed String [TemplateMangleError]
    deriving (Eq, Ord, Read, Show)

data PreparedDemand = PreparedDemand
    { preparedBinding :: TemplateBinding
    , preparedType :: Type
    , preparedIdentity :: String
    , preparedScope :: TemplateDemandScope
    , preparedOrigins :: [String]
    }

-- | Bind, coalesce, instantiate, freshen, and dependency-link explicit demands.
planTemplateSpecializations ::
    TemplateSpecializationLimits ->
    TypedAST ->
    [TemplateSpecializationDemand] ->
    Either [TemplateSpecializationError] TemplateSpecializationPlan
planTemplateSpecializations limits typed demands = do
    validateLimits limits
    prepared <- collectResults (map (prepareDemand catalog) demands)
    let coalesced = coalesceDemands prepared
    validateBatchLimits limits coalesced
    materialized <- materializeAll limits typed sources coalesced
    let linked = attachDependencies materialized
        statistics =
            TemplateSpecializationStatistics
                { requestedTemplateSpecializations = length demands
                , uniqueTemplateSpecializations = length linked
                , coalescedTemplateSpecializations = length demands - length linked
                , instantiatedTemplateMembers = sum (map memberCount linked)
                , retainedTemplateOrigins = sum (map (length . templateSpecializationOrigins) linked)
                , templateDependencyEdges = sum (map (length . templateSpecializationDependencies) linked)
                }
    pure (TemplateSpecializationPlan namespace linked statistics)
    where
        TypedAST tree = typed
        namespace = syntaxNamespace tree
        catalog = buildTemplateCatalog typed
        sources = declarationSources (syntaxDeclarations tree)

validateLimits :: TemplateSpecializationLimits -> Either [TemplateSpecializationError] ()
validateLimits limits
    | maximumTemplateSpecializations limits <= 0 = invalid "maximum specialization count must be positive"
    | maximumTemplateOrigins limits <= 0 = invalid "maximum origin count must be positive"
    | maximumMembersPerSpecialization limits < 0 = invalid "maximum member count cannot be negative"
    | otherwise = Right ()
    where
        invalid message = Left [InvalidTemplateSpecializationLimits message]

prepareDemand ::
    TemplateCatalog ->
    TemplateSpecializationDemand ->
    Either [TemplateSpecializationError] PreparedDemand
prepareDemand catalog demand = case bindTemplateApplication catalog application of
    Left failures -> Left [TemplateApplicationFailed origin failures]
    Right binding -> case substituteType binding (templateApplicationType binding) of
        Left failure -> Left [TemplateApplicationFailed origin [failure]]
        Right concrete ->
            let identity = renderSpecializationIdentity concrete
                open = collectOpenSymbols concrete
             in if null open
                    then
                        Right
                            ( PreparedDemand
                                binding
                                concrete
                                identity
                                (normalizeScope (specializationDemandScope demand))
                                [origin]
                            )
                    else Left [TemplateSpecializationRemainsOpen identity open]
    where
        application = specializationDemandApplication demand
        origin = specializationDemandOrigin demand

templateApplicationType :: TemplateBinding -> Type
templateApplicationType binding =
    NamedType
        (templateDeclarationName (templateBindingDeclaration binding))
        (concatMap (map unwrap . snd) (templateBindingArguments binding))
    where
        unwrap (ExplicitTemplateArgument argument) = argument
        unwrap (DefaultTemplateArgument argument) = argument

coalesceDemands :: [PreparedDemand] -> [PreparedDemand]
coalesceDemands = Map.elems . foldl' insert Map.empty
    where
        insert table demand = Map.insertWith merge (preparedIdentity demand) demand table
        -- insertWith supplies the new request first. Keep the old binding so
        -- source-order defaults remain the canonical representative, while
        -- merging scope and unique origins from both requests.
        merge new old =
            old
                { preparedScope = mergeScope (preparedScope old) (preparedScope new)
                , preparedOrigins = unique (preparedOrigins old ++ preparedOrigins new)
                }

normalizeScope :: TemplateDemandScope -> TemplateDemandScope
normalizeScope scope = case scope of
    TemplateMemberDemand names -> TemplateMemberDemand (unique names)
    _ -> scope

mergeScope :: TemplateDemandScope -> TemplateDemandScope -> TemplateDemandScope
mergeScope TemplateCompleteDemand _ = TemplateCompleteDemand
mergeScope _ TemplateCompleteDemand = TemplateCompleteDemand
mergeScope TemplateLayoutDemand right = right
mergeScope left TemplateLayoutDemand = left
mergeScope (TemplateMemberDemand left) (TemplateMemberDemand right) =
    TemplateMemberDemand (unique (left ++ right))

validateBatchLimits ::
    TemplateSpecializationLimits ->
    [PreparedDemand] ->
    Either [TemplateSpecializationError] ()
validateBatchLimits limits prepared
    | length prepared > maximumTemplateSpecializations limits =
        Left
            [ TemplateSpecializationLimitExceeded
                (maximumTemplateSpecializations limits)
                (preparedIdentity (prepared !! maximumTemplateSpecializations limits))
            ]
    | originCount > maximumTemplateOrigins limits =
        Left
            [ TemplateOriginLimitExceeded
                (maximumTemplateOrigins limits)
                (firstOverflowOrigin (maximumTemplateOrigins limits) prepared)
            ]
    | otherwise = Right ()
    where
        originCount = sum (map (length . preparedOrigins) prepared)

firstOverflowOrigin :: Int -> [PreparedDemand] -> String
firstOverflowOrigin limit prepared = case drop limit (concatMap preparedOrigins prepared) of
    origin : _ -> origin
    [] -> "<unknown-origin>"

materializeAll ::
    TemplateSpecializationLimits ->
    TypedAST ->
    Map SymbolId (Declaration ResolvedName Type) ->
    [PreparedDemand] ->
    Either [TemplateSpecializationError] [TemplateSpecialization]
materializeAll limits typed sources prepared = go firstFresh 1 [] ordered
    where
        SymbolId maximumSource = maximumSymbolInTypedAST typed
        firstFresh = SymbolId (maximumSource + 1)
        ordered = sortOn preparedIdentity prepared

        go _ _ output [] = Right (reverse output)
        go next identifier output (demand : remaining) = do
            (selected, selectedScope, memberTotal) <- selectDeclarationMembers limits sources demand
            instantiated <- mapInstantiation demand (instantiateTemplateType (preparedBinding demand) selected)
            -- The source annotation may retain a namespace-relative spelling.
            -- The planner owns the canonical concrete application, so the
            -- cloned declaration crosses into Core with that exact type.
            let canonicalDeclaration = instantiated {declarationAnnotation = preparedType demand}
                freshened = freshenDeclaration next canonicalDeclaration
            mangledType <- mapMangle demand (singleMangle (mangleTemplateType defaultTemplateMangleLimits (preparedType demand)))
            mangledMembers <-
                mapMangle
                    demand
                    (mangleTemplateMembers defaultTemplateMangleLimits (preparedType demand) (freshenedDeclaration freshened))
            let specialization =
                    TemplateSpecialization
                        { templateSpecializationId = TemplateSpecializationId identifier
                        , templateSpecializationIdentity = preparedIdentity demand
                        , templateSpecializationType = preparedType demand
                        , templateSpecializationScope = selectedScope
                        , templateSpecializationOrigins = preparedOrigins demand
                        , templateSpecializationDependencies = []
                        , templateSpecializationDeclaration = freshenedDeclaration freshened
                        , templateSpecializationSymbolMap = freshenedSymbols freshened
                        , templateSpecializationMangledType = mangledType
                        , templateSpecializationMangledMembers = mangledMembers
                        }
            if memberTotal > maximumMembersPerSpecialization limits
                then
                    Left
                        [ TemplateMemberLimitExceeded
                            (templateDeclarationName (templateBindingDeclaration (preparedBinding demand)))
                            (maximumMembersPerSpecialization limits)
                            memberTotal
                        ]
                else go (nextFreshSymbol freshened) (identifier + 1) (specialization : output) remaining

selectDeclarationMembers ::
    TemplateSpecializationLimits ->
    Map SymbolId (Declaration ResolvedName Type) ->
    PreparedDemand ->
    Either [TemplateSpecializationError] (Declaration ResolvedName Type, TemplateDemandScope, Int)
selectDeclarationMembers _ sources demand = do
    source <- case Map.lookup symbol sources of
        Just declaration -> Right declaration
        Nothing -> Left [TemplateDeclarationSourceMissing name symbol]
    case source of
        declaration@TemplateTypeDeclaration {typeMembers = members} -> do
            (selected, selectedScope) <- selectMembers name (preparedScope demand) members
            pure (declaration {typeMembers = selected}, selectedScope, length selected)
        _ -> Left [TemplateDeclarationSourceMissing name symbol]
    where
        descriptor = templateBindingDeclaration (preparedBinding demand)
        name = templateDeclarationName descriptor
        symbol = templateDeclarationSymbol descriptor

selectMembers ::
    QualifiedName ->
    TemplateDemandScope ->
    [Declaration ResolvedName Type] ->
    Either [TemplateSpecializationError] ([Declaration ResolvedName Type], TemplateDemandScope)
selectMembers _ TemplateLayoutDemand _ = Right ([], TemplateLayoutDemand)
selectMembers _ TemplateCompleteDemand members = Right (members, TemplateCompleteDemand)
selectMembers owner (TemplateMemberDemand requested) members =
    case selectReachableMembersByName requested members of
        Left failures -> Left (mapReachabilityFailures owner failures)
        Right reachability ->
            let selected = memberReachabilityMembers reachability
                selectedNames = unique (map memberSpelling selected)
             in Right (selected, TemplateMemberDemand selectedNames)

mapReachabilityFailures ::
    QualifiedName ->
    [TemplateMemberReachabilityError] ->
    [TemplateSpecializationError]
mapReachabilityFailures owner failures =
    case [name | MissingTemplateMemberName name <- failures] of
        [] -> [TemplateMemberReachabilityFailed owner failures]
        names -> map (TemplateMemberNotFound owner) names

memberSpelling :: Declaration ResolvedName Type -> Identifier
memberSpelling = resolvedSpelling . declarationName

mapInstantiation ::
    PreparedDemand ->
    Either TemplateInstantiationError value ->
    Either [TemplateSpecializationError] value
mapInstantiation demand result = case result of
    Left failure -> Left [TemplateInstantiationFailed (preparedIdentity demand) failure]
    Right value -> Right value

singleMangle :: Either TemplateMangleError value -> Either [TemplateMangleError] value
singleMangle result = case result of
    Left failure -> Left [failure]
    Right value -> Right value

mapMangle ::
    PreparedDemand ->
    Either [TemplateMangleError] value ->
    Either [TemplateSpecializationError] value
mapMangle demand result = case result of
    Left failures -> Left [TemplateMangleFailed (preparedIdentity demand) failures]
    Right value -> Right value

declarationSources ::
    [Declaration ResolvedName Type] ->
    Map SymbolId (Declaration ResolvedName Type)
declarationSources = Map.fromList . concatMap collect
    where
        collect declaration@TemplateTypeDeclaration {} =
            (resolvedSymbol (declarationName declaration), declaration) : concatMap collect (typeMembers declaration)
        collect TypeDeclaration {typeMembers = members} = concatMap collect members
        collect FunctionDeclaration {} = []
        collect EnumDeclaration {} = []

attachDependencies :: [TemplateSpecialization] -> [TemplateSpecialization]
attachDependencies specializations = map attach specializations
    where
        identityIds =
            Map.fromList
                [ (templateSpecializationIdentity specialization, templateSpecializationId specialization)
                | specialization <- specializations
                ]
        attach specialization =
            specialization
                { templateSpecializationDependencies =
                    unique
                        [ dependency
                        | valueType <- declarationTypes (templateSpecializationDeclaration specialization)
                        , let identity = renderSpecializationIdentity valueType
                        , identity /= templateSpecializationIdentity specialization
                        , Just dependency <- [Map.lookup identity identityIds]
                        ]
                }

-- | Find a plan entry by its plan-local identity.
findTemplateSpecialization ::
    TemplateSpecializationId ->
    TemplateSpecializationPlan ->
    Maybe TemplateSpecialization
findTemplateSpecialization identifier =
    first ((== identifier) . templateSpecializationId) . plannedTemplateSpecializations

-- | Find a plan entry by its canonical concrete-type identity string.
findTemplateSpecializationByIdentity ::
    String ->
    TemplateSpecializationPlan ->
    Maybe TemplateSpecialization
findTemplateSpecializationByIdentity identity =
    first ((== identity) . templateSpecializationIdentity) . plannedTemplateSpecializations

{- | Produce a stable dependency-first order. Reference-recursive cycles are
legal, so a grey node closes the current DFS edge instead of becoming an
error. Every specialization still appears exactly once.
-}

-- | Return stable dependency-first IDs for specialization emission.
specializationEmissionOrder :: TemplateSpecializationPlan -> [TemplateSpecializationId]
specializationEmissionOrder plan = reverse completed
    where
        table = Map.fromList [(templateSpecializationId value, value) | value <- plannedTemplateSpecializations plan]
        (_, completed) = foldl' visitRoot ([], []) (Map.keys table)
        visitRoot state identifier = visit table state identifier

visit ::
    Map TemplateSpecializationId TemplateSpecialization ->
    ([TemplateSpecializationId], [TemplateSpecializationId]) ->
    TemplateSpecializationId ->
    ([TemplateSpecializationId], [TemplateSpecializationId])
visit table state@(active, completed) identifier
    | identifier `elem` completed = state
    | identifier `elem` active = state
    | otherwise = case Map.lookup identifier table of
        Nothing -> state
        Just specialization ->
            let entered = (identifier : active, completed)
                (afterActive, afterDependencies) =
                    foldl' (visit table) entered (templateSpecializationDependencies specialization)
             in (filter (/= identifier) afterActive, identifier : afterDependencies)

{- | Build the exact closed TypedAST view consumed by declaration lowering.
Open templates remain in the semantic artifacts but are not copied here.
-}

-- | Assemble the exact closed typed AST consumed by declaration lowering.
specializationTypedAST :: TemplateSpecializationPlan -> TypedAST
specializationTypedAST plan =
    TypedAST
        ( SyntaxTree
            (plannedTemplateNamespace plan)
            [ templateSpecializationDeclaration specialization
            | identifier <- specializationEmissionOrder plan
            , Just specialization <- [findTemplateSpecialization identifier plan]
            ]
        )

memberCount :: TemplateSpecialization -> Int
memberCount specialization = case templateSpecializationDeclaration specialization of
    TypeDeclaration {typeMembers = members} -> length members
    _ -> 0

declarationTypes :: Declaration ResolvedName Type -> [Type]
declarationTypes declaration = case declaration of
    TypeDeclaration _ _ annotation members -> annotation : concatMap declarationTypes members
    FunctionDeclaration _ _ annotation _ parameters body _ _ ->
        annotation : concatMap parameterTypes parameters ++ blockTypes body
    TemplateTypeDeclaration {} -> []
    EnumDeclaration {} -> []

parameterTypes :: Parameter ResolvedName Type -> [Type]
parameterTypes parameter = [parameterAnnotation parameter]

blockTypes :: Block ResolvedName Type -> [Type]
blockTypes (Block statements) = concatMap statementTypes statements

statementTypes :: Statement ResolvedName Type -> [Type]
statementTypes statement = case statement of
    BindingStatement _ _ _ _ annotation value -> annotation : expressionTypes value
    AssignmentStatement _ _ annotation value -> annotation : expressionTypes value
    ReturnStatement _ value -> maybe [] expressionTypes value
    IfStatement _ condition trueBlock falseBlock ->
        expressionTypes condition ++ blockTypes trueBlock ++ maybe [] blockTypes falseBlock
    WhileStatement _ condition body -> expressionTypes condition ++ blockTypes body
    DoWhileStatement _ body condition -> blockTypes body ++ expressionTypes condition
    ForStatement _ initializer condition updates body ->
        maybe [] statementTypes initializer
            ++ maybe [] expressionTypes condition
            ++ concatMap statementTypes updates
            ++ blockTypes body
    ForEachStatement _ _ _ _ annotation source body -> annotation : expressionTypes source ++ blockTypes body
    IncrementStatement _ _ annotation -> [annotation]
    CompoundAssignmentStatement _ _ _ annotation value -> annotation : expressionTypes value
    DiscardStatement _ value -> expressionTypes value
    BreakStatement _ value -> maybe [] expressionTypes value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> expressionTypes condition ++ blockTypes block
    BlockStatement _ block -> blockTypes block
    ExpressionStatement _ value _ -> expressionTypes value

expressionTypes :: Expression ResolvedName Type -> [Type]
expressionTypes expression = case expression of
    NameExpression _ _ annotation -> [annotation]
    LiteralExpression _ _ annotation -> [annotation]
    MemberAccessExpression _ receiver _ annotation -> annotation : expressionTypes receiver
    MethodReferenceExpression _ receiver _ annotation -> annotation : expressionTypes receiver
    CallExpression _ callee arguments annotation ->
        annotation : expressionTypes callee ++ concatMap expressionTypes arguments
    UnaryExpression _ _ value annotation -> annotation : expressionTypes value
    BinaryExpression _ _ left right annotation -> annotation : expressionTypes left ++ expressionTypes right
    IsPatternExpression _ subject patternValue annotation ->
        annotation : expressionTypes subject ++ patternTypes patternValue
    ConditionalExpression _ condition whenTrue whenFalse annotation ->
        annotation : concatMap expressionTypes [condition, whenTrue, whenFalse]
    CoalesceExpression _ left fallback annotation ->
        annotation : expressionTypes left ++ expressionTypes fallback
    AssignmentExpression _ _ _ value annotation -> annotation : expressionTypes value
    IncrementExpression _ _ _ annotation -> [annotation]
    LoopExpression _ loop annotation -> annotation : statementTypes loop
    BlockExpression _ block annotation -> annotation : blockTypes block
    MatchExpression _ subjects arms annotation ->
        annotation
            : map matchPatternAnnotation (concatMap matchArmPatterns arms)
            ++ concatMap expressionTypes (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression _ _ captures parameters body annotation ->
        annotation
            : concatMap captureTypes captures
            ++ concatMap parameterTypes parameters
            ++ callableBodyTypes body

patternTypes :: Pattern ResolvedName Type -> [Type]
patternTypes patternValue = case patternValue of
    WildcardPattern _ annotation -> [annotation]
    NullPattern _ annotation -> [annotation]
    LiteralPattern _ _ annotation -> [annotation]
    TypePattern _ _ annotation -> [annotation]
    RelationalPattern _ _ _ annotation -> [annotation]
    NotPattern _ nested annotation -> annotation : patternTypes nested
    AndPattern _ left right annotation -> annotation : patternTypes left ++ patternTypes right
    OrPattern _ left right annotation -> annotation : patternTypes left ++ patternTypes right

captureTypes :: Capture ResolvedName Type -> [Type]
captureTypes capture = captureAnnotation capture : maybe [] expressionTypes (captureInitializer capture)

callableBodyTypes :: CallableBody ResolvedName Type -> [Type]
callableBodyTypes body = case body of
    CallableExpressionBody expression -> expressionTypes expression
    CallableBlockBody block -> blockTypes block

collectOpenSymbols :: Type -> [SymbolId]
collectOpenSymbols valueType = unique (collectType valueType)
    where
        collectType current = case current of
            NamedType _ arguments -> concatMap collectArgument arguments
            FunctionType parameters result -> concatMap collectType (parameters ++ [result])
            TypeVariable name -> [resolvedSymbol name]
            ErrorType -> []
        collectArgument argument = case argument of
            TypeTemplateArgument nested -> collectType nested
            ValueTemplateArgument (TemplateValueParameter name) -> [resolvedSymbol name]
            ValueTemplateArgument _ -> []

renderSpecializationIdentity :: Type -> String
renderSpecializationIdentity valueType = case valueType of
    NamedType name arguments -> renderName name ++ renderArguments arguments
    FunctionType parameters result ->
        "fn(" ++ intercalate "," (map renderSpecializationIdentity parameters) ++ ")->" ++ renderSpecializationIdentity result
    TypeVariable name -> "open$" ++ show (symbolIdValue (resolvedSymbol name))
    ErrorType -> "<error>"
    where
        renderArguments [] = ""
        renderArguments arguments = "<" ++ intercalate "," (map renderArgument arguments) ++ ">"
        renderArgument (TypeTemplateArgument nested) = "type:" ++ renderSpecializationIdentity nested
        renderArgument (ValueTemplateArgument value) = "value:" ++ renderValue value
        renderValue (IntegerTemplateValue value) = "i:" ++ show value
        renderValue (BooleanTemplateValue value) = "b:" ++ if value then "true" else "false"
        renderValue (CharacterTemplateValue value) = "c:" ++ show value
        renderValue (TemplateValueParameter name) = "open$" ++ show (symbolIdValue (resolvedSymbol name))

renderName :: QualifiedName -> String
renderName (QualifiedName parts) = intercalate "." (map renderPart parts)
    where
        renderPart (Identifier value) = show (length value) ++ ":" ++ value

-- | Render a demand, resource, reachability, or mangling failure.
renderTemplateSpecializationError :: TemplateSpecializationError -> String
renderTemplateSpecializationError issue = case issue of
    InvalidTemplateSpecializationLimits message -> "invalid template specialization limits: " ++ message
    TemplateApplicationFailed origin failures ->
        "template demand from " ++ origin ++ " failed: " ++ intercalate "; " (map renderTemplateApplicationError failures)
    TemplateInstantiationFailed identity failure ->
        "template specialization " ++ identity ++ " failed: " ++ renderTemplateInstantiationError failure
    TemplateDeclarationSourceMissing name symbol ->
        "template declaration " ++ renderPlainName name ++ " (symbol " ++ show (symbolIdValue symbol) ++ ") has no typed source"
    TemplateMemberNotFound name member ->
        "template declaration " ++ renderPlainName name ++ " has no member named " ++ identifierText member
    TemplateSpecializationRemainsOpen identity symbols ->
        "template specialization " ++ identity ++ " remains open over symbols " ++ show (map symbolIdValue symbols)
    TemplateSpecializationLimitExceeded limit identity ->
        "template specialization limit " ++ show limit ++ " was exceeded by " ++ identity
    TemplateOriginLimitExceeded limit origin ->
        "template origin limit " ++ show limit ++ " was exceeded by " ++ origin
    TemplateMemberLimitExceeded name limit actual ->
        "template declaration "
            ++ renderPlainName name
            ++ " selected "
            ++ show actual
            ++ " members, exceeding limit "
            ++ show limit
    TemplateMemberReachabilityFailed name failures ->
        "template declaration "
            ++ renderPlainName name
            ++ " has an invalid member call graph: "
            ++ intercalate "; " (map renderTemplateMemberReachabilityError failures)
    TemplateMangleFailed identity failures ->
        "template specialization "
            ++ identity
            ++ " cannot be mangled: "
            ++ intercalate "; " (map renderTemplateMangleError failures)

renderPlainName :: QualifiedName -> String
renderPlainName (QualifiedName parts) = intercalate "." (map identifierText parts)

first :: (value -> Bool) -> [value] -> Maybe value
first _ [] = Nothing
first predicate (value : remaining)
    | predicate value = Just value
    | otherwise = first predicate remaining

unique :: (Eq value) => [value] -> [value]
unique = foldl' append []
    where
        append values value
            | value `elem` values = values
            | otherwise = values ++ [value]

collectResults :: [Either [problem] value] -> Either [problem] [value]
collectResults results = case concat [problems | Left problems <- results] of
    [] -> Right [value | Right value <- results]
    problems -> Left problems
