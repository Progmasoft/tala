-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Structural closure facts shared by diagnostics, tooling, and lowering.

This module deliberately does not choose a heap layout.  It describes the
semantic facts which survive into CorePrep: source order, ownership mode,
mutation, nesting, and whether a captured value is read by a nested closure.
-}
module Progmasoft.Tala.Closure.Analysis
    ( ClosureId (..)
    , CaptureUse (..)
    , ClosureSummary (..)
    , ClosureCatalog (..)
    , analyzeClosures
    , closureById
    , closuresCapturing
    , stronglyCapturedSymbols
    , nonOwningCapturedSymbols
    ) where

import Data.List (nubBy)
import Progmasoft.Tala.AST

-- | Stable preorder identity of a closure within one analyzed typed AST.
newtype ClosureId = ClosureId {closureIdValue :: Int}
    deriving (Eq, Ord, Read, Show)

-- | Use and ownership facts for one closure capture.
data CaptureUse = CaptureUse
    { captureUseName :: ResolvedName
    -- ^ Resolved symbol captured by the closure.
    , captureUseType :: Type
    -- ^ Type of the captured binding.
    , captureUseMode :: CaptureMode
    -- ^ Explicit or inferred ownership mode.
    , captureUseOrder :: Int
    -- ^ Source-order position in the capture environment.
    , captureUseExplicit :: Bool
    -- ^ Whether source syntax explicitly listed it.
    , captureUseAlias :: Bool
    -- ^ Whether the capture has an explicit alias.
    , captureUseRead :: Bool
    -- ^ Whether this closure reads the captured value.
    , captureUseWritten :: Bool
    -- ^ Whether this closure writes the captured binding.
    , captureUseReadByNestedClosure :: Bool
    -- ^ Whether a descendant closure reads it.
    }
    deriving (Eq, Ord, Read, Show)

-- | Structural properties needed to analyze or lower one closure.
data ClosureSummary = ClosureSummary
    { closureSummaryId :: ClosureId
    -- ^ Unique identity assigned in source traversal order.
    , closureSummaryParent :: Maybe ClosureId
    -- ^ Lexically enclosing closure, if nested.
    , closureSummarySpan :: SourceSpan
    -- ^ Full source span of the closure expression.
    , closureSummaryType :: Type
    -- ^ Resolved callable type.
    , closureSummaryExplicitCaptureMode :: Bool
    -- ^ Whether capture policy was explicit.
    , closureSummaryParameters :: [(ResolvedName, Type)]
    -- ^ Resolved parameter names and types.
    , closureSummaryCaptures :: [CaptureUse]
    -- ^ Captures in source order.
    , closureSummaryChildren :: [ClosureId]
    -- ^ Directly nested closure identities.
    , closureSummaryContainsReturn :: Bool
    -- ^ Whether the body contains a return statement.
    , closureSummaryContainsCall :: Bool
    -- ^ Whether the body contains a call expression.
    }
    deriving (Eq, Ord, Read, Show)

-- | Closure summaries for all closures in one typed syntax tree.
newtype ClosureCatalog = ClosureCatalog {closureSummaries :: [ClosureSummary]}
    deriving (Eq, Ord, Read, Show)

data WalkState = WalkState
    { walkNextId :: Int
    , walkSummaries :: [ClosureSummary]
    }

-- | Walk a typed AST and collect lexical nesting, captures, and use facts.
analyzeClosures :: TypedAST -> ClosureCatalog
analyzeClosures (TypedAST tree) =
    let final = walkTree (WalkState 1 []) tree
     in ClosureCatalog (walkSummaries final)

-- | Look up a closure summary by its traversal-assigned identity.
closureById :: ClosureId -> ClosureCatalog -> Maybe ClosureSummary
closureById identifier (ClosureCatalog summaries) =
    findFirst ((== identifier) . closureSummaryId) summaries

-- | Find closures whose capture environments contain the given symbol.
closuresCapturing :: SymbolId -> ClosureCatalog -> [ClosureSummary]
closuresCapturing symbol (ClosureCatalog summaries) =
    [ summary
    | summary <- summaries
    , any ((== symbol) . resolvedSymbol . captureUseName) (closureSummaryCaptures summary)
    ]

-- | Return unique symbols captured with strong ownership.
stronglyCapturedSymbols :: ClosureCatalog -> [SymbolId]
stronglyCapturedSymbols = capturedSymbolsByMode (== StrongCapture)

-- | Return unique symbols captured without strong ownership.
nonOwningCapturedSymbols :: ClosureCatalog -> [SymbolId]
nonOwningCapturedSymbols = capturedSymbolsByMode (/= StrongCapture)

capturedSymbolsByMode :: (CaptureMode -> Bool) -> ClosureCatalog -> [SymbolId]
capturedSymbolsByMode predicate (ClosureCatalog summaries) =
    unique
        [ resolvedSymbol (captureUseName capture)
        | summary <- summaries
        , capture <- closureSummaryCaptures summary
        , predicate (captureUseMode capture)
        ]

walkTree :: WalkState -> SyntaxTree ResolvedName Type -> WalkState
walkTree state tree = foldDeclarations (syntaxDeclarations tree) state

foldDeclarations :: [Declaration ResolvedName Type] -> WalkState -> WalkState
foldDeclarations declarations initial = foldl walkDeclaration initial declarations

walkDeclaration :: WalkState -> Declaration ResolvedName Type -> WalkState
walkDeclaration state declaration = case declaration of
    TypeDeclaration {typeMembers = members} -> foldl walkDeclaration state members
    -- Open template members can contain closures even though they do not lower
    -- before specialization. Analyze them now so tooling sees the same capture
    -- relationships before and after concrete declaration instantiation.
    TemplateTypeDeclaration {typeMembers = members} -> foldl walkDeclaration state members
    FunctionDeclaration {declarationBody = body} -> walkBlock Nothing state body
    EnumDeclaration {} -> state

walkBlock :: Maybe ClosureId -> WalkState -> Block ResolvedName Type -> WalkState
walkBlock parent state block = foldStatements parent (blockStatements block) state

foldStatements :: Maybe ClosureId -> [Statement ResolvedName Type] -> WalkState -> WalkState
foldStatements parent statements initial = foldl (walkStatement parent) initial statements

walkStatement :: Maybe ClosureId -> WalkState -> Statement ResolvedName Type -> WalkState
walkStatement parent state statement = case statement of
    BindingStatement _ _ _ _ _ value -> walkExpression parent state value
    AssignmentStatement _ _ _ value -> walkExpression parent state value
    ReturnStatement _ value -> maybe state (walkExpression parent state) value
    IfStatement _ condition trueBlock falseBlock ->
        let afterCondition = walkExpression parent state condition
            afterTrue = walkBlock parent afterCondition trueBlock
         in maybe afterTrue (walkBlock parent afterTrue) falseBlock
    WhileStatement _ condition body ->
        walkBlock parent (walkExpression parent state condition) body
    DoWhileStatement _ body condition ->
        walkExpression parent (walkBlock parent state body) condition
    ForStatement _ initializer condition updates body ->
        let afterInitializer = maybe state (walkStatement parent state) initializer
            afterCondition = maybe afterInitializer (walkExpression parent afterInitializer) condition
            afterUpdates = foldl (walkStatement parent) afterCondition updates
         in walkBlock parent afterUpdates body
    ForEachStatement _ _ _ _ _ source body ->
        walkBlock parent (walkExpression parent state source) body
    IncrementStatement {} -> state
    CompoundAssignmentStatement _ _ _ _ value -> walkExpression parent state value
    DiscardStatement _ value -> walkExpression parent state value
    BreakStatement _ value -> maybe state (walkExpression parent state) value
    ContinueStatement {} -> state
    GuardStatement _ condition block -> walkBlock parent (walkExpression parent state condition) block
    BlockStatement _ block -> walkBlock parent state block
    ExpressionStatement _ value _ -> walkExpression parent state value

walkExpression :: Maybe ClosureId -> WalkState -> Expression ResolvedName Type -> WalkState
walkExpression parent state expression = case expression of
    NameExpression {} -> state
    LiteralExpression {} -> state
    MemberAccessExpression _ receiver _ _ -> walkExpression parent state receiver
    MethodReferenceExpression _ receiver _ _ -> walkExpression parent state receiver
    CallExpression _ callee arguments _ ->
        foldl (walkExpression parent) (walkExpression parent state callee) arguments
    UnaryExpression _ _ value _ -> walkExpression parent state value
    BinaryExpression _ _ left right _ ->
        walkExpression parent (walkExpression parent state left) right
    IsPatternExpression _ subject _ _ -> walkExpression parent state subject
    ConditionalExpression _ condition first second _ ->
        foldl (walkExpression parent) state [condition, first, second]
    CoalesceExpression _ left fallback _ ->
        walkExpression parent (walkExpression parent state left) fallback
    AssignmentExpression _ _ _ value _ -> walkExpression parent state value
    IncrementExpression {} -> state
    LoopExpression _ loop _ -> walkStatement parent state loop
    BlockExpression _ block _ -> walkBlock parent state block
    MatchExpression _ subjects arms _ ->
        foldl (walkExpression parent) state (subjects ++ concatMap matchArmExpressions arms)
    callable@CallableExpression {} -> walkCallable parent state callable

walkCallable :: Maybe ClosureId -> WalkState -> Expression ResolvedName Type -> WalkState
walkCallable parent state (CallableExpression spanValue explicit captures parameters body valueType) =
    let identifier = ClosureId (walkNextId state)
        bodyFacts = inspectBody body
        explicitUses = zipWith (captureUse bodyFacts explicit) [0 ..] captures
        implicitUses =
            if explicit
                then []
                else inferImplicitUses parameters bodyFacts
        beforeChildren = state {walkNextId = walkNextId state + 1}
        afterChildren = walkCallableBody (Just identifier) beforeChildren body
        children =
            [ closureSummaryId candidateSummary
            | candidateSummary <- walkSummaries afterChildren
            , closureSummaryParent candidateSummary == Just identifier
            ]
        nestedReads =
            concatMap
                (map (resolvedSymbol . captureUseName) . closureSummaryCaptures)
                [ nestedSummary
                | nestedSummary <- walkSummaries afterChildren
                , closureSummaryId nestedSummary `elem` descendantsOf children (ClosureCatalog (walkSummaries afterChildren))
                ]
        markNested use =
            use {captureUseReadByNestedClosure = resolvedSymbol (captureUseName use) `elem` nestedReads}
        summary =
            ClosureSummary
                { closureSummaryId = identifier
                , closureSummaryParent = parent
                , closureSummarySpan = spanValue
                , closureSummaryType = valueType
                , closureSummaryExplicitCaptureMode = explicit
                , closureSummaryParameters =
                    [(parameterName parameter, parameterAnnotation parameter) | parameter <- parameters]
                , closureSummaryCaptures = map markNested (explicitUses ++ implicitUses)
                , closureSummaryChildren = children
                , closureSummaryContainsReturn = bodyContainsReturn body
                , closureSummaryContainsCall = bodyContainsCall body
                }
     in afterChildren {walkSummaries = walkSummaries afterChildren ++ [summary]}
walkCallable _ state _ = state

walkCallableBody :: Maybe ClosureId -> WalkState -> CallableBody ResolvedName Type -> WalkState
walkCallableBody parent state body = case body of
    CallableExpressionBody expression -> walkExpression parent state expression
    CallableBlockBody block -> walkBlock parent state block

data BodyFacts = BodyFacts
    { factReads :: [(ResolvedName, Type)]
    , factWrites :: [ResolvedName]
    , factLocals :: [ResolvedName]
    }

inspectBody :: CallableBody ResolvedName Type -> BodyFacts
inspectBody body = case body of
    CallableExpressionBody expression -> expressionFacts expression
    CallableBlockBody block -> blockFacts block

emptyFacts :: BodyFacts
emptyFacts = BodyFacts [] [] []

appendFacts :: BodyFacts -> BodyFacts -> BodyFacts
appendFacts left right =
    BodyFacts
        (factReads left ++ factReads right)
        (factWrites left ++ factWrites right)
        (factLocals left ++ factLocals right)

blockFacts :: Block ResolvedName Type -> BodyFacts
blockFacts = foldl appendFacts emptyFacts . map statementFacts . blockStatements

statementFacts :: Statement ResolvedName Type -> BodyFacts
statementFacts statement = case statement of
    BindingStatement _ _ _ name _ value ->
        (expressionFacts value) {factLocals = name : factLocals (expressionFacts value)}
    AssignmentStatement _ name _ value ->
        (expressionFacts value) {factWrites = name : factWrites (expressionFacts value)}
    ReturnStatement _ value -> maybe emptyFacts expressionFacts value
    IfStatement _ condition trueBlock falseBlock ->
        expressionFacts condition
            `appendFacts` blockFacts trueBlock
            `appendFacts` maybe emptyFacts blockFacts falseBlock
    WhileStatement _ condition body -> expressionFacts condition `appendFacts` blockFacts body
    DoWhileStatement _ body condition -> blockFacts body `appendFacts` expressionFacts condition
    ForStatement _ initializer condition updates body ->
        maybe emptyFacts statementFacts initializer
            `appendFacts` maybe emptyFacts expressionFacts condition
            `appendFacts` foldl appendFacts emptyFacts (map statementFacts updates)
            `appendFacts` blockFacts body
    ForEachStatement _ _ _ name _ source body ->
        let nested = expressionFacts source `appendFacts` blockFacts body
         in nested {factLocals = name : factLocals nested, factWrites = name : factWrites nested}
    IncrementStatement _ name annotation -> emptyFacts {factReads = [(name, annotation)], factWrites = [name]}
    -- A compound assignment reads its target before storing the result.
    CompoundAssignmentStatement _ _ name annotation value ->
        let nested = expressionFacts value
         in nested {factReads = (name, annotation) : factReads nested, factWrites = name : factWrites nested}
    DiscardStatement _ value -> expressionFacts value
    BreakStatement _ value -> maybe emptyFacts expressionFacts value
    ContinueStatement {} -> emptyFacts
    GuardStatement _ condition block -> expressionFacts condition `appendFacts` blockFacts block
    BlockStatement _ block -> blockFacts block
    ExpressionStatement _ value _ -> expressionFacts value

expressionFacts :: Expression ResolvedName Type -> BodyFacts
expressionFacts expression = case expression of
    NameExpression _ name valueType -> BodyFacts [(name, valueType)] [] []
    LiteralExpression {} -> emptyFacts
    MemberAccessExpression _ receiver _ _ -> expressionFacts receiver
    MethodReferenceExpression _ receiver _ _ -> expressionFacts receiver
    CallExpression _ callee arguments _ ->
        foldl appendFacts (expressionFacts callee) (map expressionFacts arguments)
    UnaryExpression _ _ value _ -> expressionFacts value
    BinaryExpression _ _ left right _ -> expressionFacts left `appendFacts` expressionFacts right
    IsPatternExpression _ subject _ _ -> expressionFacts subject
    ConditionalExpression _ condition first second _ ->
        foldl appendFacts (expressionFacts condition) (map expressionFacts [first, second])
    CoalesceExpression _ left fallback _ -> expressionFacts left `appendFacts` expressionFacts fallback
    -- A simple assignment only writes its target; a compound one reads it
    -- first, exactly as the statement forms do.
    AssignmentExpression _ operator name value annotation ->
        let nested = expressionFacts value
            targetReads = maybe [] (const [(name, annotation)]) operator
         in nested {factReads = targetReads ++ factReads nested, factWrites = name : factWrites nested}
    IncrementExpression _ _ name annotation -> emptyFacts {factReads = [(name, annotation)], factWrites = [name]}
    LoopExpression _ loop _ -> statementFacts loop
    BlockExpression _ block _ -> blockFacts block
    -- A pattern binding is a local of the match, written once when its arm
    -- is entered.
    MatchExpression _ subjects arms _ ->
        let nested = foldl appendFacts emptyFacts (map expressionFacts (subjects ++ concatMap matchArmExpressions arms))
            bound = [name | arm <- arms, Just name <- map matchPatternBinding (matchArmPatterns arm)]
         in nested {factLocals = bound ++ factLocals nested, factWrites = bound ++ factWrites nested}
    CallableExpression {} -> emptyFacts

captureUse :: BodyFacts -> Bool -> Int -> Capture ResolvedName Type -> CaptureUse
captureUse facts explicit order capture =
    let symbol = resolvedSymbol (captureName capture)
        isRead = any ((== symbol) . resolvedSymbol . fst) (factReads facts)
        writes = any ((== symbol) . resolvedSymbol) (factWrites facts)
     in CaptureUse
            (captureName capture)
            (captureAnnotation capture)
            (captureMode capture)
            order
            explicit
            (captureAlias capture)
            isRead
            writes
            False

captureAlias :: Capture ResolvedName Type -> Bool
captureAlias capture = case captureInitializer capture of
    Just (NameExpression _ source _) -> resolvedSymbol source /= resolvedSymbol (captureName capture)
    Just _ -> True
    Nothing -> False

inferImplicitUses :: [Parameter ResolvedName Type] -> BodyFacts -> [CaptureUse]
inferImplicitUses parameters facts =
    let localSymbols = map (resolvedSymbol . parameterName) parameters ++ map resolvedSymbol (factLocals facts)
        freeReads =
            uniqueBy
                (resolvedSymbol . fst)
                [(name, valueType) | (name, valueType) <- factReads facts, resolvedSymbol name `notElem` localSymbols]
     in [ CaptureUse
            name
            valueType
            StrongCapture
            order
            False
            False
            True
            (any ((== resolvedSymbol name) . resolvedSymbol) (factWrites facts))
            False
        | (order, (name, valueType)) <- zip [0 ..] freeReads
        ]

bodyContainsReturn :: CallableBody name annotation -> Bool
bodyContainsReturn (CallableExpressionBody _) = True
bodyContainsReturn (CallableBlockBody block) = any statementContainsReturn (blockStatements block)

statementContainsReturn :: Statement name annotation -> Bool
statementContainsReturn statement = case statement of
    ReturnStatement {} -> True
    IfStatement _ _ yes no ->
        any statementContainsReturn (blockStatements yes)
            || maybe False (any statementContainsReturn . blockStatements) no
    WhileStatement _ _ body -> any statementContainsReturn (blockStatements body)
    DoWhileStatement _ body _ -> any statementContainsReturn (blockStatements body)
    ForStatement _ initializer _ updates body ->
        maybe False statementContainsReturn initializer
            || any statementContainsReturn updates
            || any statementContainsReturn (blockStatements body)
    ForEachStatement _ _ _ _ _ _ body -> any statementContainsReturn (blockStatements body)
    BreakStatement _ value -> maybe False (const False) value
    GuardStatement _ _ block -> any statementContainsReturn (blockStatements block)
    BlockStatement _ block -> any statementContainsReturn (blockStatements block)
    -- The arms of a statement match are statements, so a return in a block
    -- body returns from the enclosing callable.
    ExpressionStatement _ (MatchExpression _ _ arms _) _ ->
        or
            [ any statementContainsReturn (blockStatements block)
            | BlockExpression _ block _ <- map matchArmBody arms
            ]
    _ -> False

bodyContainsCall :: CallableBody name annotation -> Bool
bodyContainsCall (CallableExpressionBody expression) = expressionContainsCall expression
bodyContainsCall (CallableBlockBody block) = any statementContainsCall (blockStatements block)

statementContainsCall :: Statement name annotation -> Bool
statementContainsCall statement = case statement of
    BindingStatement _ _ _ _ _ value -> expressionContainsCall value
    AssignmentStatement _ _ _ value -> expressionContainsCall value
    ReturnStatement _ value -> maybe False expressionContainsCall value
    IfStatement _ condition yes no ->
        expressionContainsCall condition
            || any statementContainsCall (blockStatements yes)
            || maybe False (any statementContainsCall . blockStatements) no
    WhileStatement _ condition body ->
        expressionContainsCall condition || any statementContainsCall (blockStatements body)
    DoWhileStatement _ body condition ->
        any statementContainsCall (blockStatements body) || expressionContainsCall condition
    ForStatement _ initializer condition updates body ->
        maybe False statementContainsCall initializer
            || maybe False expressionContainsCall condition
            || any statementContainsCall updates
            || any statementContainsCall (blockStatements body)
    ForEachStatement _ _ _ _ _ source body ->
        expressionContainsCall source || any statementContainsCall (blockStatements body)
    IncrementStatement {} -> False
    CompoundAssignmentStatement _ _ _ _ value -> expressionContainsCall value
    DiscardStatement _ value -> expressionContainsCall value
    BreakStatement _ value -> maybe False expressionContainsCall value
    ContinueStatement {} -> False
    GuardStatement _ condition block ->
        expressionContainsCall condition || any statementContainsCall (blockStatements block)
    BlockStatement _ block -> any statementContainsCall (blockStatements block)
    ExpressionStatement _ value _ -> expressionContainsCall value

expressionContainsCall :: Expression name annotation -> Bool
expressionContainsCall expression = case expression of
    CallExpression {} -> True
    MemberAccessExpression _ receiver _ _ -> expressionContainsCall receiver
    MethodReferenceExpression _ receiver _ _ -> expressionContainsCall receiver
    UnaryExpression _ _ value _ -> expressionContainsCall value
    BinaryExpression _ _ left right _ -> expressionContainsCall left || expressionContainsCall right
    IsPatternExpression _ subject _ _ -> expressionContainsCall subject
    ConditionalExpression _ condition first second _ -> any expressionContainsCall [condition, first, second]
    CoalesceExpression _ left fallback _ -> expressionContainsCall left || expressionContainsCall fallback
    AssignmentExpression _ _ _ value _ -> expressionContainsCall value
    IncrementExpression {} -> False
    LoopExpression _ loop _ -> statementContainsCall loop
    BlockExpression _ block _ -> any statementContainsCall (blockStatements block)
    MatchExpression _ subjects arms _ ->
        any expressionContainsCall (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression {} -> False
    NameExpression {} -> False
    LiteralExpression {} -> False

descendantsOf :: [ClosureId] -> ClosureCatalog -> [ClosureId]
descendantsOf roots catalog = roots ++ concatMap children roots
    where
        children identifier = case closureById identifier catalog of
            Nothing -> []
            Just summary -> descendantsOf (closureSummaryChildren summary) catalog

findFirst :: (value -> Bool) -> [value] -> Maybe value
findFirst _ [] = Nothing
findFirst predicate (value : remaining)
    | predicate value = Just value
    | otherwise = findFirst predicate remaining

unique :: (Eq value) => [value] -> [value]
unique = nubBy (==)

uniqueBy :: (Eq key) => (value -> key) -> [value] -> [value]
uniqueBy select = nubBy (\left right -> select left == select right)
