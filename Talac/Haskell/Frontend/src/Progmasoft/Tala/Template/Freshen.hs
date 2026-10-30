-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- |
Deterministic semantic-name freshening for cloned declarations.

Template specialization copies a typed declaration, but a copy must not keep
the source declaration's SymbolIds.  Core identifies definitions by SymbolId;
sharing those ids would make two otherwise distinct specializations collide.
This module performs the alpha-renaming after substitution and before Core
lowering.  Spelling and source locations remain unchanged for diagnostics.
-}
module Progmasoft.Tala.Template.Freshen
    ( FreshenResult (..)
    , maximumSymbolInTypedAST
    , freshenDeclaration
    ) where

import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST

-- | Freshened declaration and the old-to-new identities allocated for it.
data FreshenResult = FreshenResult
    { freshenedDeclaration :: Declaration ResolvedName Type
    -- ^ Cloned tree with definitions and references updated.
    , freshenedSymbols :: [(SymbolId, SymbolId)]
    -- ^ Identity mapping in ascending old-symbol order.
    , nextFreshSymbol :: SymbolId
    -- ^ First identity available to the next clone.
    }
    deriving (Eq, Ord, Read, Show)

data FreshState = FreshState
    { freshNext :: Int
    , freshMap :: Map SymbolId ResolvedName
    }

-- | Find the greatest symbol identity present anywhere in a typed AST.
maximumSymbolInTypedAST :: TypedAST -> SymbolId
maximumSymbolInTypedAST (TypedAST tree) =
    SymbolId (maximum (0 : concatMap declarationSymbols (syntaxDeclarations tree)))

-- | Alpha-rename one cloned declaration, preserving spelling and source spans.
freshenDeclaration :: SymbolId -> Declaration ResolvedName Type -> FreshenResult
freshenDeclaration (SymbolId first) declaration =
    let (closed, finalState) = runFresh (freshDeclaration declaration) (FreshState (max 1 first) Map.empty)
        pairs = [(old, resolvedSymbol replacement) | (old, replacement) <- Map.toAscList (freshMap finalState)]
     in FreshenResult closed pairs (SymbolId (freshNext finalState))

newtype Fresh a = Fresh {runFresh :: FreshState -> (a, FreshState)}

instance Functor Fresh where
    fmap transform action = Fresh $ \state ->
        let (value, next) = runFresh action state
         in (transform value, next)

instance Applicative Fresh where
    pure value = Fresh (value,)
    functionAction <*> valueAction = Fresh $ \state ->
        let (function, next) = runFresh functionAction state
            (value, final) = runFresh valueAction next
         in (function value, final)

instance Monad Fresh where
    action >>= continuation = Fresh $ \state ->
        let (value, next) = runFresh action state
         in runFresh (continuation value) next

freshDefinition :: ResolvedName -> Fresh ResolvedName
freshDefinition original = Fresh $ \state ->
    case Map.lookup (resolvedSymbol original) (freshMap state) of
        Just existing -> (existing, state)
        Nothing ->
            let replacement = ResolvedName (SymbolId (freshNext state)) (resolvedSpelling original)
                nextState =
                    state
                        { freshNext = freshNext state + 1
                        , freshMap = Map.insert (resolvedSymbol original) replacement (freshMap state)
                        }
             in (replacement, nextState)

freshReference :: ResolvedName -> Fresh ResolvedName
freshReference original = Fresh $ \state ->
    (Map.findWithDefault original (resolvedSymbol original) (freshMap state), state)

freshDeclaration :: Declaration ResolvedName Type -> Fresh (Declaration ResolvedName Type)
freshDeclaration declaration = case declaration of
    TypeDeclaration spanValue name annotation members -> do
        closedName <- freshDefinition name
        closedAnnotation <- freshType annotation
        -- A type scope is recursive: a member body may call a member declared
        -- later in source order. Reserve every immediate member identity before
        -- rewriting any body so forward calls and mutually recursive methods
        -- cannot retain the template declaration's old SymbolIds.
        traverse_ reserveDeclarationName members
        closedMembers <- traverse freshDeclaration members
        pure (TypeDeclaration spanValue closedName closedAnnotation closedMembers)
    FunctionDeclaration spanValue name annotation returnSyntax parameters body isStatic access fact -> do
        closedName <- freshDefinition name
        -- Parameters are definitions and must be allocated before the body is
        -- walked, otherwise references in the body retain the template copy's
        -- old semantic identity.
        closedParameters <- traverse freshParameterDefinition parameters
        closedAnnotation <- freshType annotation
        closedBody <- freshBlock body
        pure
            ( FunctionDeclaration
                spanValue
                closedName
                closedAnnotation
                returnSyntax
                closedParameters
                closedBody
                isStatic
                access
                fact
            )
    TemplateTypeDeclaration {} ->
        -- A nested template introduces a separate substitution/freshening
        -- environment. It will be selected independently when demanded.
        pure declaration
    -- An enum has no body and no template parameter in it.
    EnumDeclaration {} -> pure declaration

reserveDeclarationName :: Declaration ResolvedName Type -> Fresh ()
reserveDeclarationName declaration = case declaration of
    TypeDeclaration _ name _ _ -> freshDefinition name >> pure ()
    FunctionDeclaration _ name _ _ _ _ _ _ _ -> freshDefinition name >> pure ()
    TemplateTypeDeclaration {} ->
        -- Nested templates own a separate specialization environment and must
        -- not leak definitions into the enclosing concrete type's map.
        pure ()
    EnumDeclaration {} -> pure ()

freshParameterDefinition :: Parameter ResolvedName Type -> Fresh (Parameter ResolvedName Type)
freshParameterDefinition parameter = do
    name <- freshDefinition (parameterName parameter)
    annotation <- freshType (parameterAnnotation parameter)
    pure
        ( Parameter
            (parameterSpan parameter)
            name
            annotation
            (parameterTypeSyntax parameter)
        )

freshBlock :: Block ResolvedName Type -> Fresh (Block ResolvedName Type)
freshBlock (Block statements) = Block <$> traverse freshStatement statements

freshStatement :: Statement ResolvedName Type -> Fresh (Statement ResolvedName Type)
freshStatement statement = case statement of
    BindingStatement spanValue kind syntax name annotation value -> do
        -- Initializers are evaluated in the surrounding scope. Allocate the
        -- local only after rewriting its initializer so self-shadowing does
        -- not accidentally rewrite an outer reference.
        closedValue <- freshExpression value
        closedName <- freshDefinition name
        closedAnnotation <- freshType annotation
        pure (BindingStatement spanValue kind syntax closedName closedAnnotation closedValue)
    AssignmentStatement spanValue name annotation value ->
        AssignmentStatement spanValue
            <$> freshReference name
            <*> freshType annotation
            <*> freshExpression value
    ReturnStatement spanValue value -> ReturnStatement spanValue <$> traverse freshExpression value
    IfStatement spanValue condition trueBlock falseBlock ->
        IfStatement spanValue
            <$> freshExpression condition
            <*> freshBlock trueBlock
            <*> traverse freshBlock falseBlock
    WhileStatement spanValue condition body ->
        WhileStatement spanValue <$> freshExpression condition <*> freshBlock body
    DoWhileStatement spanValue body condition ->
        DoWhileStatement spanValue <$> freshBlock body <*> freshExpression condition
    ForStatement spanValue initializer condition updates body -> do
        closedInitializer <- traverse freshStatement initializer
        closedCondition <- traverse freshExpression condition
        closedUpdates <- traverse freshStatement updates
        closedBody <- freshBlock body
        pure (ForStatement spanValue closedInitializer closedCondition closedUpdates closedBody)
    ForEachStatement spanValue kind syntax name annotation source body -> do
        closedSource <- freshExpression source
        closedName <- freshDefinition name
        closedAnnotation <- freshType annotation
        closedBody <- freshBlock body
        pure (ForEachStatement spanValue kind syntax closedName closedAnnotation closedSource closedBody)
    IncrementStatement spanValue name annotation ->
        IncrementStatement spanValue <$> freshReference name <*> freshType annotation
    CompoundAssignmentStatement spanValue operator name annotation value ->
        CompoundAssignmentStatement spanValue operator
            <$> freshReference name
            <*> freshType annotation
            <*> freshExpression value
    DiscardStatement spanValue value -> DiscardStatement spanValue <$> freshExpression value
    BreakStatement spanValue value -> BreakStatement spanValue <$> traverse freshExpression value
    ContinueStatement spanValue -> pure (ContinueStatement spanValue)
    GuardStatement spanValue condition block ->
        GuardStatement spanValue <$> freshExpression condition <*> freshBlock block
    BlockStatement spanValue block -> BlockStatement spanValue <$> freshBlock block
    ExpressionStatement spanValue value terminated ->
        ExpressionStatement spanValue <$> freshExpression value <*> pure terminated

freshExpression :: Expression ResolvedName Type -> Fresh (Expression ResolvedName Type)
freshExpression expression = case expression of
    NameExpression spanValue name annotation ->
        NameExpression spanValue <$> freshReference name <*> freshType annotation
    LiteralExpression spanValue literal annotation ->
        LiteralExpression spanValue literal <$> freshType annotation
    MemberAccessExpression spanValue receiver member annotation ->
        MemberAccessExpression spanValue <$> freshExpression receiver <*> pure member <*> freshType annotation
    MethodReferenceExpression spanValue receiver member annotation ->
        MethodReferenceExpression spanValue <$> freshExpression receiver <*> pure member <*> freshType annotation
    CallExpression spanValue callee arguments annotation ->
        CallExpression spanValue
            <$> freshExpression callee
            <*> traverse freshExpression arguments
            <*> freshType annotation
    UnaryExpression spanValue operator value annotation ->
        UnaryExpression spanValue operator <$> freshExpression value <*> freshType annotation
    BinaryExpression spanValue operator left right annotation ->
        BinaryExpression spanValue operator
            <$> freshExpression left
            <*> freshExpression right
            <*> freshType annotation
    IsPatternExpression spanValue subject patternValue annotation ->
        IsPatternExpression spanValue
            <$> freshExpression subject
            <*> freshPattern patternValue
            <*> freshType annotation
    ConditionalExpression spanValue condition first second annotation ->
        ConditionalExpression spanValue
            <$> freshExpression condition
            <*> freshExpression first
            <*> freshExpression second
            <*> freshType annotation
    CoalesceExpression spanValue left fallback annotation ->
        CoalesceExpression spanValue
            <$> freshExpression left
            <*> freshExpression fallback
            <*> freshType annotation
    AssignmentExpression spanValue operator name value annotation ->
        AssignmentExpression spanValue operator
            <$> freshReference name
            <*> freshExpression value
            <*> freshType annotation
    IncrementExpression spanValue isPrefix name annotation ->
        IncrementExpression spanValue isPrefix <$> freshReference name <*> freshType annotation
    LoopExpression spanValue loop annotation ->
        LoopExpression spanValue <$> freshStatement loop <*> freshType annotation
    BlockExpression spanValue block annotation ->
        BlockExpression spanValue <$> freshBlock block <*> freshType annotation
    -- The subjects are evaluated in the surrounding scope. Each arm then
    -- allocates the locals its patterns bind before its guard and its body
    -- refer to them.
    MatchExpression spanValue subjects arms annotation ->
        MatchExpression spanValue
            <$> traverse freshExpression subjects
            <*> traverse (traverseMatchArm (traverseMatchPattern freshDefinition freshType) freshExpression) arms
            <*> freshType annotation
    CallableExpression spanValue explicit captures parameters body annotation -> do
        closedCaptures <- traverse freshCaptureDefinition captures
        closedParameters <- traverse freshParameterDefinition parameters
        closedBody <- freshCallableBody body
        closedAnnotation <- freshType annotation
        pure (CallableExpression spanValue explicit closedCaptures closedParameters closedBody closedAnnotation)

freshPattern :: Pattern ResolvedName Type -> Fresh (Pattern ResolvedName Type)
freshPattern patternValue = case patternValue of
    WildcardPattern spanValue annotation -> WildcardPattern spanValue <$> freshType annotation
    NullPattern spanValue annotation -> NullPattern spanValue <$> freshType annotation
    LiteralPattern spanValue literal annotation ->
        LiteralPattern spanValue literal <$> freshType annotation
    TypePattern spanValue syntax annotation -> TypePattern spanValue syntax <$> freshType annotation
    RelationalPattern spanValue operator literal annotation ->
        RelationalPattern spanValue operator literal <$> freshType annotation
    NotPattern spanValue nested annotation ->
        NotPattern spanValue <$> freshPattern nested <*> freshType annotation
    AndPattern spanValue left right annotation ->
        AndPattern spanValue <$> freshPattern left <*> freshPattern right <*> freshType annotation
    OrPattern spanValue left right annotation ->
        OrPattern spanValue <$> freshPattern left <*> freshPattern right <*> freshType annotation

freshCaptureDefinition :: Capture ResolvedName Type -> Fresh (Capture ResolvedName Type)
freshCaptureDefinition capture = do
    -- The initializer belongs to the outer scope, just like a local binding
    -- initializer. The capture name becomes visible only in the callable.
    initializer <- traverse freshExpression (captureInitializer capture)
    name <- freshDefinition (captureName capture)
    annotation <- freshType (captureAnnotation capture)
    pure (Capture (captureSpan capture) (captureMode capture) name annotation initializer)

freshCallableBody :: CallableBody ResolvedName Type -> Fresh (CallableBody ResolvedName Type)
freshCallableBody body = case body of
    CallableExpressionBody expression -> CallableExpressionBody <$> freshExpression expression
    CallableBlockBody block -> CallableBlockBody <$> freshBlock block

freshType :: Type -> Fresh Type
freshType valueType = case valueType of
    NamedType name arguments -> NamedType name <$> traverse freshArgument arguments
    FunctionType parameters result -> FunctionType <$> traverse freshType parameters <*> freshType result
    TypeVariable name -> TypeVariable <$> freshReference name
    ErrorType -> pure ErrorType

freshArgument :: TemplateArgument -> Fresh TemplateArgument
freshArgument argument = case argument of
    TypeTemplateArgument valueType -> TypeTemplateArgument <$> freshType valueType
    ValueTemplateArgument value -> ValueTemplateArgument <$> freshValue value

freshValue :: TemplateValue -> Fresh TemplateValue
freshValue value = case value of
    TemplateValueParameter name -> TemplateValueParameter <$> freshReference name
    _ -> pure value

declarationSymbols :: Declaration ResolvedName Type -> [Int]
declarationSymbols declaration = case declaration of
    TypeDeclaration _ name annotation members ->
        nameSymbol name : typeSymbols annotation ++ concatMap declarationSymbols members
    FunctionDeclaration _ name annotation _ parameters body _ _ _ ->
        nameSymbol name
            : typeSymbols annotation
            ++ concatMap parameterSymbols parameters
            ++ blockSymbols body
    TemplateTypeDeclaration _ name annotation parameters members ->
        nameSymbol name
            : typeSymbols annotation
            ++ concatMap templateParameterSymbols parameters
            ++ concatMap declarationSymbols members
    EnumDeclaration _ name annotation _ _ -> nameSymbol name : typeSymbols annotation

templateParameterSymbols :: TemplateParameter ResolvedName Type -> [Int]
templateParameterSymbols parameter =
    nameSymbol (templateParameterName parameter) : typeSymbols (templateParameterAnnotation parameter)

parameterSymbols :: Parameter ResolvedName Type -> [Int]
parameterSymbols parameter = nameSymbol (parameterName parameter) : typeSymbols (parameterAnnotation parameter)

blockSymbols :: Block ResolvedName Type -> [Int]
blockSymbols (Block statements) = concatMap statementSymbols statements

statementSymbols :: Statement ResolvedName Type -> [Int]
statementSymbols statement = case statement of
    BindingStatement _ _ _ name annotation value -> nameSymbol name : typeSymbols annotation ++ expressionSymbols value
    AssignmentStatement _ name annotation value -> nameSymbol name : typeSymbols annotation ++ expressionSymbols value
    ReturnStatement _ value -> maybe [] expressionSymbols value
    IfStatement _ condition trueBlock falseBlock ->
        expressionSymbols condition ++ blockSymbols trueBlock ++ maybe [] blockSymbols falseBlock
    WhileStatement _ condition body -> expressionSymbols condition ++ blockSymbols body
    DoWhileStatement _ body condition -> blockSymbols body ++ expressionSymbols condition
    ForStatement _ initializer condition updates body ->
        maybe [] statementSymbols initializer
            ++ maybe [] expressionSymbols condition
            ++ concatMap statementSymbols updates
            ++ blockSymbols body
    ForEachStatement _ _ _ name annotation source body ->
        nameSymbol name : typeSymbols annotation ++ expressionSymbols source ++ blockSymbols body
    IncrementStatement _ name annotation -> nameSymbol name : typeSymbols annotation
    CompoundAssignmentStatement _ _ name annotation value ->
        nameSymbol name : typeSymbols annotation ++ expressionSymbols value
    DiscardStatement _ value -> expressionSymbols value
    BreakStatement _ value -> maybe [] expressionSymbols value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> expressionSymbols condition ++ blockSymbols block
    BlockStatement _ block -> blockSymbols block
    ExpressionStatement _ value _ -> expressionSymbols value

expressionSymbols :: Expression ResolvedName Type -> [Int]
expressionSymbols expression = case expression of
    NameExpression _ name annotation -> nameSymbol name : typeSymbols annotation
    LiteralExpression _ _ annotation -> typeSymbols annotation
    MemberAccessExpression _ receiver _ annotation -> expressionSymbols receiver ++ typeSymbols annotation
    MethodReferenceExpression _ receiver _ annotation -> expressionSymbols receiver ++ typeSymbols annotation
    CallExpression _ callee arguments annotation ->
        expressionSymbols callee ++ concatMap expressionSymbols arguments ++ typeSymbols annotation
    UnaryExpression _ _ value annotation -> expressionSymbols value ++ typeSymbols annotation
    BinaryExpression _ _ left right annotation ->
        expressionSymbols left ++ expressionSymbols right ++ typeSymbols annotation
    IsPatternExpression _ subject patternValue annotation ->
        expressionSymbols subject ++ patternSymbols patternValue ++ typeSymbols annotation
    ConditionalExpression _ condition first second annotation ->
        concatMap expressionSymbols [condition, first, second] ++ typeSymbols annotation
    CoalesceExpression _ left fallback annotation ->
        expressionSymbols left ++ expressionSymbols fallback ++ typeSymbols annotation
    AssignmentExpression _ _ name value annotation ->
        nameSymbol name : expressionSymbols value ++ typeSymbols annotation
    IncrementExpression _ _ name annotation -> nameSymbol name : typeSymbols annotation
    LoopExpression _ loop annotation -> statementSymbols loop ++ typeSymbols annotation
    BlockExpression _ block annotation -> blockSymbols block ++ typeSymbols annotation
    MatchExpression _ subjects arms annotation ->
        concatMap expressionSymbols (subjects ++ concatMap matchArmExpressions arms)
            ++ concat
                [ maybe [] ((: []) . nameSymbol) (matchPatternBinding patternValue)
                    ++ typeSymbols (matchPatternAnnotation patternValue)
                | arm <- arms
                , patternValue <- matchArmPatterns arm
                ]
            ++ typeSymbols annotation
    CallableExpression _ _ captures parameters body annotation ->
        concatMap captureSymbols captures
            ++ concatMap parameterSymbols parameters
            ++ callableBodySymbols body
            ++ typeSymbols annotation

patternSymbols :: Pattern ResolvedName Type -> [Int]
patternSymbols patternValue = case patternValue of
    WildcardPattern _ annotation -> typeSymbols annotation
    NullPattern _ annotation -> typeSymbols annotation
    LiteralPattern _ _ annotation -> typeSymbols annotation
    TypePattern _ _ annotation -> typeSymbols annotation
    RelationalPattern _ _ _ annotation -> typeSymbols annotation
    NotPattern _ nested annotation -> patternSymbols nested ++ typeSymbols annotation
    AndPattern _ left right annotation ->
        patternSymbols left ++ patternSymbols right ++ typeSymbols annotation
    OrPattern _ left right annotation ->
        patternSymbols left ++ patternSymbols right ++ typeSymbols annotation

captureSymbols :: Capture ResolvedName Type -> [Int]
captureSymbols capture =
    nameSymbol (captureName capture)
        : typeSymbols (captureAnnotation capture)
        ++ maybe [] expressionSymbols (captureInitializer capture)

callableBodySymbols :: CallableBody ResolvedName Type -> [Int]
callableBodySymbols body = case body of
    CallableExpressionBody expression -> expressionSymbols expression
    CallableBlockBody block -> blockSymbols block

typeSymbols :: Type -> [Int]
typeSymbols valueType = case valueType of
    NamedType _ arguments -> concatMap argumentSymbols arguments
    FunctionType parameters result -> concatMap typeSymbols (result : parameters)
    TypeVariable name -> [nameSymbol name]
    ErrorType -> []

argumentSymbols :: TemplateArgument -> [Int]
argumentSymbols argument = case argument of
    TypeTemplateArgument valueType -> typeSymbols valueType
    ValueTemplateArgument (TemplateValueParameter name) -> [nameSymbol name]
    ValueTemplateArgument _ -> []

nameSymbol :: ResolvedName -> Int
nameSymbol = symbolIdValue . resolvedSymbol
