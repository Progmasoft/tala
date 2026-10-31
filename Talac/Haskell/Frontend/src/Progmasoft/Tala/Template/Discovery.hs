-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- |
Typed-AST discovery of concrete template layout demands.

Discovery is intentionally conservative. A concrete template type appearing
in an ordinary checked declaration requests layout, but never requests method
bodies. Open template declarations are definitions, not uses, so this pass
does not walk their parameter-dependent bodies. Member/call resolution will
add narrower body demands through the same planner API in a later stage.
-}
module Progmasoft.Tala.Template.Discovery
    ( TemplateTypeSite (..)
    , TemplateDiscoveryOrigin (..)
    , TemplateDiscoveryStatistics (..)
    , TemplateDemandDiscovery (..)
    , discoverTemplateDemands
    , renderTemplateDiscoveryOrigin
    ) where

import Data.List (intercalate)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Specialization

-- | Syntactic/semantic position at which a concrete template application occurs.
data TemplateTypeSite
    = -- | Type declaration annotation.
      DeclarationTypeSite
    | -- | Function's complete callable signature.
      FunctionSignatureSite
    | -- | Parameter index in a function signature.
      ParameterTypeSite Int
    | -- | Local binding annotation at statement index.
      BindingTypeSite Int
    | -- | Assignment target annotation at statement index.
      AssignmentTypeSite Int
    | -- | Return expression at statement index.
      ReturnTypeSite Int
    | -- | Conditional or loop condition at statement index.
      ConditionTypeSite Int
    | -- | General expression node at traversal index.
      ExpressionTypeSite Int
    | -- | Callable expression type at traversal index.
      CallableTypeSite Int
    | -- | Capture index nested in a callable expression.
      CaptureTypeSite Int Int
    | -- | Type argument nested at the indexed depth.
      NestedTypeArgumentSite Int
    | -- | Type inside a function-type parameter list.
      FunctionParameterTypeSite Int
    | -- | Result type nested inside a function type.
      FunctionResultTypeSite
    deriving (Eq, Ord, Read, Show)

-- | Source provenance explaining why one template application was discovered.
data TemplateDiscoveryOrigin = TemplateDiscoveryOrigin
    { discoveryDeclaration :: ResolvedName
    -- ^ Enclosing declaration that contains the use.
    , discoveryMember :: Maybe ResolvedName
    -- ^ Enclosing member, when the use is within a type.
    , discoverySites :: [TemplateTypeSite]
    -- ^ Nested sites traversed to reach the application.
    , discoverySpan :: SourceSpan
    -- ^ Source location associated with the use.
    }
    deriving (Eq, Ord, Read, Show)

-- | Counters describing conservative demand discovery work.
data TemplateDiscoveryStatistics = TemplateDiscoveryStatistics
    { visitedTemplateTypeNodes :: Int
    -- ^ Type nodes visited during traversal.
    , discoveredTemplateApplications :: Int
    -- ^ Concrete applications converted to demands.
    , ignoredOrdinaryNamedTypes :: Int
    -- ^ Non-template named types skipped.
    , skippedOpenTemplateBodies :: Int
    -- ^ Open declaration bodies deliberately not walked.
    }
    deriving (Eq, Ord, Read, Show)

-- | Explicit specialization demands, their provenance, and work counters.
data TemplateDemandDiscovery = TemplateDemandDiscovery
    { discoveredTemplateDemands :: [TemplateSpecializationDemand]
    -- ^ Layout-only demands found in checked declarations.
    , discoveredTemplateOrigins :: [TemplateDiscoveryOrigin]
    -- ^ Source sites corresponding to discovered uses.
    , templateDiscoveryStatistics :: TemplateDiscoveryStatistics
    -- ^ Aggregate traversal counts.
    }
    deriving (Eq, Ord, Read, Show)

data DiscoveryState = DiscoveryState
    { stateDemands :: [TemplateSpecializationDemand]
    , stateOrigins :: [TemplateDiscoveryOrigin]
    , stateVisitedTypes :: Int
    , stateIgnoredTypes :: Int
    , stateSkippedTemplates :: Int
    }

emptyState :: DiscoveryState
emptyState = DiscoveryState [] [] 0 0 0

-- | Find concrete template type uses without implicitly requesting method bodies.
discoverTemplateDemands :: TypedAST -> TemplateDemandDiscovery
discoverTemplateDemands typed@(TypedAST tree) =
    let catalog = buildTemplateCatalog typed
        final = foldl' (discoverTop catalog (syntaxNamespace tree)) emptyState (syntaxDeclarations tree)
        demands = reverse (stateDemands final)
        origins = reverse (stateOrigins final)
     in TemplateDemandDiscovery
            demands
            origins
            ( TemplateDiscoveryStatistics
                (stateVisitedTypes final)
                (length demands)
                (stateIgnoredTypes final)
                (stateSkippedTemplates final)
            )

discoverTop ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    DiscoveryState ->
    Declaration ResolvedName Type ->
    DiscoveryState
discoverTop catalog namespace state declaration = case declaration of
    TemplateTypeDeclaration {} -> state {stateSkippedTemplates = stateSkippedTemplates state + 1}
    TypeDeclaration spanValue name annotation members ->
        let origin = TemplateDiscoveryOrigin name Nothing [DeclarationTypeSite] spanValue
            afterType = discoverType catalog namespace origin annotation state
         in foldl' (discoverMember catalog namespace name) afterType members
    FunctionDeclaration {} ->
        -- Top-level runtime functions are not part of the renewed source
        -- grammar, but keeping this traversal total makes hand-built TypedAST
        -- fixtures and future declaration categories deterministic.
        discoverFunction catalog namespace (declarationName declaration) Nothing declaration state
    -- An enum uses no template: its underlying type is a scalar.
    EnumDeclaration {} -> state

discoverMember ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    ResolvedName ->
    DiscoveryState ->
    Declaration ResolvedName Type ->
    DiscoveryState
discoverMember catalog namespace owner state member = case member of
    FunctionDeclaration {} -> discoverFunction catalog namespace owner (Just (declarationName member)) member state
    TypeDeclaration spanValue name annotation members ->
        let origin = TemplateDiscoveryOrigin owner (Just name) [DeclarationTypeSite] spanValue
            afterType = discoverType catalog namespace origin annotation state
         in foldl' (discoverMember catalog namespace owner) afterType members
    TemplateTypeDeclaration {} -> state {stateSkippedTemplates = stateSkippedTemplates state + 1}
    EnumDeclaration {} -> state

discoverFunction ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    ResolvedName ->
    Maybe ResolvedName ->
    Declaration ResolvedName Type ->
    DiscoveryState ->
    DiscoveryState
discoverFunction catalog namespace owner member declaration state = case declaration of
    FunctionDeclaration spanValue _ annotation _ parameters body _ _ _ ->
        let root = TemplateDiscoveryOrigin owner member [FunctionSignatureSite] spanValue
            -- Function annotations repeat parameter types in a callable shape.
            -- Walk the result here and the declared parameters below so each
            -- source type use produces exactly one demand and one origin.
            resultType = case annotation of
                FunctionType _ result -> result
                other -> other
            afterSignature = discoverType catalog namespace root resultType state
            afterParameters =
                foldl'
                    ( \current (index, parameter) ->
                        discoverType
                            catalog
                            namespace
                            (root {discoverySites = [ParameterTypeSite index]})
                            (parameterAnnotation parameter)
                            current
                    )
                    afterSignature
                    (zip [0 ..] parameters)
         in discoverBlock catalog namespace root body afterParameters
    _ -> state

discoverBlock ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    TemplateDiscoveryOrigin ->
    Block ResolvedName Type ->
    DiscoveryState ->
    DiscoveryState
discoverBlock catalog namespace root (Block statements) state =
    foldl'
        (\current (index, statement) -> discoverStatement catalog namespace root index statement current)
        state
        (zip [0 ..] statements)

discoverStatement ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    TemplateDiscoveryOrigin ->
    Int ->
    Statement ResolvedName Type ->
    DiscoveryState ->
    DiscoveryState
discoverStatement catalog namespace root index statement state = case statement of
    BindingStatement spanValue _ _ _ annotation value ->
        let origin = root {discoverySites = [BindingTypeSite index], discoverySpan = spanValue}
         in discoverExpression catalog namespace origin value (discoverType catalog namespace origin annotation state)
    AssignmentStatement spanValue _ annotation value ->
        let origin = root {discoverySites = [AssignmentTypeSite index], discoverySpan = spanValue}
         in discoverExpression catalog namespace origin value (discoverType catalog namespace origin annotation state)
    ReturnStatement spanValue value ->
        let origin = root {discoverySites = [ReturnTypeSite index], discoverySpan = spanValue}
         in maybe state (\expression -> discoverExpression catalog namespace origin expression state) value
    IfStatement spanValue condition trueBlock falseBlock ->
        let origin = root {discoverySites = [ConditionTypeSite index], discoverySpan = spanValue}
            afterCondition = discoverExpression catalog namespace origin condition state
            afterTrue = discoverBlock catalog namespace origin trueBlock afterCondition
         in maybe afterTrue (\block -> discoverBlock catalog namespace origin block afterTrue) falseBlock
    WhileStatement spanValue condition body ->
        let origin = root {discoverySites = [ConditionTypeSite index], discoverySpan = spanValue}
         in discoverBlock catalog namespace origin body (discoverExpression catalog namespace origin condition state)
    DoWhileStatement spanValue body condition ->
        let origin = root {discoverySites = [ConditionTypeSite index], discoverySpan = spanValue}
            afterBody = discoverBlock catalog namespace origin body state
         in discoverExpression catalog namespace origin condition afterBody
    ForStatement spanValue initializer condition updates body ->
        let origin = root {discoverySites = [ConditionTypeSite index], discoverySpan = spanValue}
            afterInitializer = maybe state (\value -> discoverStatement catalog namespace origin index value state) initializer
            afterCondition = maybe afterInitializer (\value -> discoverExpression catalog namespace origin value afterInitializer) condition
            afterUpdates = foldl' (\current value -> discoverStatement catalog namespace origin index value current) afterCondition updates
         in discoverBlock catalog namespace origin body afterUpdates
    ForEachStatement spanValue _ _ _ annotation source body ->
        let origin = root {discoverySites = [ConditionTypeSite index], discoverySpan = spanValue}
            afterAnnotation = discoverType catalog namespace origin annotation state
            afterSource = discoverExpression catalog namespace origin source afterAnnotation
         in discoverBlock catalog namespace origin body afterSource
    IncrementStatement _ _ annotation -> discoverType catalog namespace root annotation state
    CompoundAssignmentStatement spanValue _ _ annotation value ->
        let origin = root {discoverySites = [AssignmentTypeSite index], discoverySpan = spanValue}
         in discoverExpression catalog namespace origin value (discoverType catalog namespace origin annotation state)
    DiscardStatement spanValue expression ->
        discoverExpression
            catalog
            namespace
            (root {discoverySites = [ExpressionTypeSite index], discoverySpan = spanValue})
            expression
            state
    BreakStatement _ value -> maybe state (\expression -> discoverExpression catalog namespace root expression state) value
    ContinueStatement {} -> state
    GuardStatement spanValue condition block ->
        let origin = root {discoverySites = [ConditionTypeSite index], discoverySpan = spanValue}
         in discoverBlock catalog namespace origin block (discoverExpression catalog namespace origin condition state)
    BlockStatement spanValue block ->
        discoverBlock
            catalog
            namespace
            (root {discoverySites = [ConditionTypeSite index], discoverySpan = spanValue})
            block
            state
    ExpressionStatement spanValue expression _ ->
        discoverExpression
            catalog
            namespace
            (root {discoverySites = [ExpressionTypeSite index], discoverySpan = spanValue})
            expression
            state

discoverExpression ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    TemplateDiscoveryOrigin ->
    Expression ResolvedName Type ->
    DiscoveryState ->
    DiscoveryState
discoverExpression catalog namespace origin expression state = case expression of
    NameExpression _ _ annotation -> discoverType catalog namespace origin annotation state
    LiteralExpression _ _ annotation -> discoverType catalog namespace origin annotation state
    MemberAccessExpression _ receiver _ annotation ->
        discoverExpression catalog namespace origin receiver (discoverType catalog namespace origin annotation state)
    MethodReferenceExpression _ receiver _ annotation ->
        discoverExpression catalog namespace origin receiver (discoverType catalog namespace origin annotation state)
    CallExpression _ callee arguments annotation ->
        let afterType = discoverType catalog namespace origin annotation state
            afterCallee = discoverExpression catalog namespace origin callee afterType
         in foldl' (\current value -> discoverExpression catalog namespace origin value current) afterCallee arguments
    UnaryExpression _ _ value annotation ->
        discoverExpression catalog namespace origin value (discoverType catalog namespace origin annotation state)
    BinaryExpression _ _ left right annotation ->
        let afterType = discoverType catalog namespace origin annotation state
            afterLeft = discoverExpression catalog namespace origin left afterType
         in discoverExpression catalog namespace origin right afterLeft
    IsPatternExpression _ subject patternValue annotation ->
        let afterType = discoverType catalog namespace origin annotation state
            afterSubject = discoverExpression catalog namespace origin subject afterType
         in discoverPattern catalog namespace origin patternValue afterSubject
    ConditionalExpression _ condition first second annotation ->
        let afterType = discoverType catalog namespace origin annotation state
         in foldl'
                (\current value -> discoverExpression catalog namespace origin value current)
                afterType
                [condition, first, second]
    CoalesceExpression _ left fallback annotation ->
        let afterType = discoverType catalog namespace origin annotation state
            afterLeft = discoverExpression catalog namespace origin left afterType
         in discoverExpression catalog namespace origin fallback afterLeft
    AssignmentExpression _ _ _ value annotation ->
        discoverExpression catalog namespace origin value (discoverType catalog namespace origin annotation state)
    IncrementExpression _ _ _ annotation -> discoverType catalog namespace origin annotation state
    LoopExpression _ loop annotation ->
        discoverStatement catalog namespace origin 0 loop (discoverType catalog namespace origin annotation state)
    BlockExpression _ block annotation ->
        discoverBlock catalog namespace origin block (discoverType catalog namespace origin annotation state)
    MatchExpression _ subjects arms annotation ->
        let afterType = discoverType catalog namespace origin annotation state
            afterPatterns =
                foldl'
                    (\current patternValue -> discoverType catalog namespace origin (matchPatternAnnotation patternValue) current)
                    afterType
                    (concatMap matchArmPatterns arms)
         in foldl'
                (\current value -> discoverExpression catalog namespace origin value current)
                afterPatterns
                (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression spanValue _ captures parameters body annotation ->
        let callableOrigin =
                origin
                    { discoverySites = discoverySites origin ++ [CallableTypeSite (sourceColumn (sourceStart spanValue))]
                    , discoverySpan = spanValue
                    }
            afterType = discoverType catalog namespace callableOrigin annotation state
            afterCaptures =
                foldl'
                    (discoverCapture catalog namespace callableOrigin)
                    afterType
                    (zip [0 ..] captures)
            afterParameters =
                foldl'
                    ( \current (index, parameter) ->
                        discoverType
                            catalog
                            namespace
                            (callableOrigin {discoverySites = discoverySites callableOrigin ++ [ParameterTypeSite index]})
                            (parameterAnnotation parameter)
                            current
                    )
                    afterCaptures
                    (zip [0 ..] parameters)
         in discoverCallableBody catalog namespace callableOrigin body afterParameters

discoverPattern ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    TemplateDiscoveryOrigin ->
    Pattern ResolvedName Type ->
    DiscoveryState ->
    DiscoveryState
discoverPattern catalog namespace origin patternValue state = case patternValue of
    WildcardPattern _ annotation -> discoverAnnotation annotation state
    NullPattern _ annotation -> discoverAnnotation annotation state
    LiteralPattern _ _ annotation -> discoverAnnotation annotation state
    TypePattern _ _ annotation -> discoverAnnotation annotation state
    RelationalPattern _ _ _ annotation -> discoverAnnotation annotation state
    NotPattern _ nested annotation ->
        discoverPattern catalog namespace origin nested (discoverAnnotation annotation state)
    AndPattern _ left right annotation -> discoverPair annotation left right
    OrPattern _ left right annotation -> discoverPair annotation left right
    where
        discoverAnnotation = discoverType catalog namespace origin
        discoverPair annotation left right =
            let afterType = discoverAnnotation annotation state
                afterLeft = discoverPattern catalog namespace origin left afterType
             in discoverPattern catalog namespace origin right afterLeft

discoverCapture ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    TemplateDiscoveryOrigin ->
    DiscoveryState ->
    (Int, Capture ResolvedName Type) ->
    DiscoveryState
discoverCapture catalog namespace root state (index, capture) =
    let origin = root {discoverySites = discoverySites root ++ [CaptureTypeSite index 0], discoverySpan = captureSpan capture}
        afterType = discoverType catalog namespace origin (captureAnnotation capture) state
     in maybe afterType (\value -> discoverExpression catalog namespace origin value afterType) (captureInitializer capture)

discoverCallableBody ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    TemplateDiscoveryOrigin ->
    CallableBody ResolvedName Type ->
    DiscoveryState ->
    DiscoveryState
discoverCallableBody catalog namespace origin body state = case body of
    CallableExpressionBody expression -> discoverExpression catalog namespace origin expression state
    CallableBlockBody block -> discoverBlock catalog namespace origin block state

discoverType ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    TemplateDiscoveryOrigin ->
    Type ->
    DiscoveryState ->
    DiscoveryState
discoverType catalog namespace origin valueType state =
    let visited = state {stateVisitedTypes = stateVisitedTypes state + 1}
     in case valueType of
            NamedType name arguments ->
                let afterRoot = case resolveTemplateTarget namespace name catalog of
                        Just target
                            | isClosedType valueType ->
                                visited
                                    { stateDemands =
                                        TemplateSpecializationDemand
                                            (TemplateApplication target arguments)
                                            TemplateLayoutDemand
                                            (renderTemplateDiscoveryOrigin origin)
                                            : stateDemands visited
                                    , stateOrigins = origin : stateOrigins visited
                                    }
                        _ -> visited {stateIgnoredTypes = stateIgnoredTypes visited + 1}
                 in foldl'
                        (\current (index, argument) -> discoverArgument catalog namespace origin index argument current)
                        afterRoot
                        (zip [0 ..] arguments)
            FunctionType parameters result ->
                let afterParameters =
                        foldl'
                            ( \current (index, parameter) ->
                                discoverType
                                    catalog
                                    namespace
                                    (origin {discoverySites = discoverySites origin ++ [FunctionParameterTypeSite index]})
                                    parameter
                                    current
                            )
                            visited
                            (zip [0 ..] parameters)
                 in discoverType
                        catalog
                        namespace
                        (origin {discoverySites = discoverySites origin ++ [FunctionResultTypeSite]})
                        result
                        afterParameters
            TypeVariable _ -> visited
            ErrorType -> visited

discoverArgument ::
    TemplateCatalog ->
    Maybe QualifiedName ->
    TemplateDiscoveryOrigin ->
    Int ->
    TemplateArgument ->
    DiscoveryState ->
    DiscoveryState
discoverArgument catalog namespace origin index argument state = case argument of
    TypeTemplateArgument nested ->
        discoverType
            catalog
            namespace
            (origin {discoverySites = discoverySites origin ++ [NestedTypeArgumentSite index]})
            nested
            state
    ValueTemplateArgument _ -> state

resolveTemplateTarget :: Maybe QualifiedName -> QualifiedName -> TemplateCatalog -> Maybe QualifiedName
resolveTemplateTarget namespace name (TemplateCatalog declarations)
    | any ((== name) . templateDeclarationName) declarations = Just name
    | otherwise = case (namespace, qualifiedNameParts name) of
        (Just (QualifiedName owner), [_]) ->
            let qualified = QualifiedName (owner ++ qualifiedNameParts name)
             in if any ((== qualified) . templateDeclarationName) declarations then Just qualified else Nothing
        _ -> Nothing

isClosedType :: Type -> Bool
isClosedType valueType = case valueType of
    NamedType _ arguments -> all closedArgument arguments
    FunctionType parameters result -> all isClosedType parameters && isClosedType result
    TypeVariable _ -> False
    ErrorType -> False
    where
        closedArgument (TypeTemplateArgument nested) = isClosedType nested
        closedArgument (ValueTemplateArgument (TemplateValueParameter _)) = False
        closedArgument (ValueTemplateArgument _) = True

-- | Render a stable human-readable provenance path for one discovered demand.
renderTemplateDiscoveryOrigin :: TemplateDiscoveryOrigin -> String
renderTemplateDiscoveryOrigin origin =
    sourceFile (discoverySpan origin)
        ++ ":"
        ++ show (sourceLine (sourceStart (discoverySpan origin)))
        ++ ":"
        ++ show (sourceColumn (sourceStart (discoverySpan origin)))
        ++ " in "
        ++ renderResolved (discoveryDeclaration origin)
        ++ maybe "" (("." ++) . renderResolved) (discoveryMember origin)
        ++ " ["
        ++ intercalate "/" (map renderSite (discoverySites origin))
        ++ "]"

renderResolved :: ResolvedName -> String
renderResolved = identifierText . resolvedSpelling

renderSite :: TemplateTypeSite -> String
renderSite site = case site of
    DeclarationTypeSite -> "declaration"
    FunctionSignatureSite -> "signature"
    ParameterTypeSite index -> "parameter:" ++ show index
    BindingTypeSite index -> "binding:" ++ show index
    AssignmentTypeSite index -> "assignment:" ++ show index
    ReturnTypeSite index -> "return:" ++ show index
    ConditionTypeSite index -> "condition:" ++ show index
    ExpressionTypeSite index -> "expression:" ++ show index
    CallableTypeSite index -> "callable:" ++ show index
    CaptureTypeSite index initializer -> "capture:" ++ show index ++ ":" ++ show initializer
    NestedTypeArgumentSite index -> "argument:" ++ show index
    FunctionParameterTypeSite index -> "function-parameter:" ++ show index
    FunctionResultTypeSite -> "function-result"
