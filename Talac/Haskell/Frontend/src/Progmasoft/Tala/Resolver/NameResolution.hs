-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Convert renamed identifiers into stable symbol identities and diagnose
unresolved or reserved names before type checking.
-}
module Progmasoft.Tala.Resolver.NameResolution (NameResolution (..), defaultNameResolution, runNameResolution) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.RuntimeCall (builtinConsoleSymbol, builtinSystemSymbol)

-- | Pluggable name-resolution pass over a fully renamed syntax tree.
newtype NameResolution = NameResolution
    { resolveRenamedAST :: RenamedAST -> Either [Diagnostic] ResolvedAST
    -- ^ Resolve every identifier or return all name-resolution diagnostics.
    }

-- | Execute a supplied name-resolution implementation.
runNameResolution :: NameResolution -> RenamedAST -> Either [Diagnostic] ResolvedAST
runNameResolution = resolveRenamedAST

-- | Default compiler name resolver using the AST's assigned symbol identities.
defaultNameResolution :: NameResolution
defaultNameResolution = NameResolution resolveTree

resolveTree :: RenamedAST -> Either [Diagnostic] ResolvedAST
resolveTree (RenamedAST tree) = case traverseTree tree of
    (resolved, []) -> Right (ResolvedAST resolved)
    (_, problems) -> Left problems

traverseTree :: SyntaxTree RenamedName () -> (SyntaxTree ResolvedName (), [Diagnostic])
traverseTree (SyntaxTree namespace declarations) =
    let values = map resolveDeclaration declarations in (SyntaxTree namespace (map fst values), concatMap snd values)

resolveDeclaration :: Declaration RenamedName () -> (Declaration ResolvedName (), [Diagnostic])
resolveDeclaration declaration = case declaration of
    TypeDeclaration spanValue sourceName _ members ->
        let name = resolveName spanValue sourceName; resolvedMembers = map resolveDeclaration members
         in (TypeDeclaration spanValue (fst name) () (map fst resolvedMembers), snd name ++ concatMap snd resolvedMembers)
    TemplateTypeDeclaration spanValue sourceName _ sourceParameters members ->
        let name = resolveName spanValue sourceName
            parameters = map resolveTemplateParameter sourceParameters
            resolvedMembers = map resolveDeclaration members
         in ( TemplateTypeDeclaration
                spanValue
                (fst name)
                ()
                (map fst parameters)
                (map fst resolvedMembers)
            , snd name ++ concatMap snd parameters ++ concatMap snd resolvedMembers
            )
    EnumDeclaration spanValue sourceName _ underlying cases ->
        let name = resolveName spanValue sourceName
         in (EnumDeclaration spanValue (fst name) () underlying cases, snd name)
    FunctionDeclaration spanValue sourceName _ returnSyntax sourceParameters sourceBody isStatic access ->
        let name = resolveName spanValue sourceName
            parameters = map resolveParameter sourceParameters
            (body, bodyProblems) = resolveBlock sourceBody
         in ( FunctionDeclaration spanValue (fst name) () returnSyntax (map fst parameters) body isStatic access
            , snd name ++ concatMap snd parameters ++ bodyProblems
            )

resolveParameter :: Parameter RenamedName () -> (Parameter ResolvedName (), [Diagnostic])
resolveParameter (Parameter spanValue name _ syntax) = let (resolved, problems) = resolveName spanValue name in (Parameter spanValue resolved () syntax, problems)

resolveTemplateParameter ::
    TemplateParameter RenamedName () ->
    (TemplateParameter ResolvedName (), [Diagnostic])
resolveTemplateParameter parameter =
    let (resolved, problems) = resolveName (templateParameterSpan parameter) (templateParameterName parameter)
     in ( TemplateParameter
            (templateParameterSpan parameter)
            resolved
            ()
            (templateParameterKind parameter)
            (templateParameterIsPack parameter)
            (templateParameterDefault parameter)
        , problems
        )

resolveBlock :: Block RenamedName () -> (Block ResolvedName (), [Diagnostic])
resolveBlock (Block statements) = let values = map resolveStatement statements in (Block (map fst values), concatMap snd values)

resolveStatement :: Statement RenamedName () -> (Statement ResolvedName (), [Diagnostic])
resolveStatement statement = case statement of
    BindingStatement spanValue kind syntax name _ value ->
        let (resolvedName, nameProblems) = resolveName spanValue name; (resolvedValue, valueProblems) = resolveExpression value
         in (BindingStatement spanValue kind syntax resolvedName () resolvedValue, nameProblems ++ valueProblems)
    AssignmentStatement spanValue name _ value ->
        let (resolvedName, nameProblems) = resolveName spanValue name; (resolvedValue, valueProblems) = resolveExpression value
         in (AssignmentStatement spanValue resolvedName () resolvedValue, nameProblems ++ valueProblems)
    ReturnStatement spanValue value -> let (resolved, problems) = resolveOptional value in (ReturnStatement spanValue resolved, problems)
    IfStatement spanValue condition trueBlock falseBlock ->
        let (resolvedCondition, conditionProblems) = resolveExpression condition
            (resolvedTrue, trueProblems) = resolveBlock trueBlock
            (resolvedFalse, falseProblems) = case falseBlock of
                Nothing -> (Nothing, [])
                Just value -> let (block, problems) = resolveBlock value in (Just block, problems)
         in (IfStatement spanValue resolvedCondition resolvedTrue resolvedFalse, conditionProblems ++ trueProblems ++ falseProblems)
    WhileStatement spanValue condition body ->
        let (resolvedCondition, conditionProblems) = resolveExpression condition
            (resolvedBody, bodyProblems) = resolveBlock body
         in (WhileStatement spanValue resolvedCondition resolvedBody, conditionProblems ++ bodyProblems)
    DoWhileStatement spanValue body condition ->
        let (resolvedBody, bodyProblems) = resolveBlock body
            (resolvedCondition, conditionProblems) = resolveExpression condition
         in (DoWhileStatement spanValue resolvedBody resolvedCondition, bodyProblems ++ conditionProblems)
    ForStatement spanValue initializer condition updates body ->
        let (resolvedInitializer, initializerProblems) = case initializer of
                Nothing -> (Nothing, [])
                Just value -> let (resolved, problems) = resolveStatement value in (Just resolved, problems)
            (resolvedCondition, conditionProblems) = resolveOptional condition
            resolvedUpdates = map resolveStatement updates
            (resolvedBody, bodyProblems) = resolveBlock body
         in ( ForStatement spanValue resolvedInitializer resolvedCondition (map fst resolvedUpdates) resolvedBody
            , initializerProblems ++ conditionProblems ++ concatMap snd resolvedUpdates ++ bodyProblems
            )
    ForEachStatement spanValue kind syntax name annotation source body ->
        let (resolvedName, nameProblems) = resolveName spanValue name
            (resolvedSource, sourceProblems) = resolveExpression source
            (resolvedBody, bodyProblems) = resolveBlock body
         in ( ForEachStatement spanValue kind syntax resolvedName annotation resolvedSource resolvedBody
            , nameProblems ++ sourceProblems ++ bodyProblems
            )
    IncrementStatement spanValue name annotation ->
        let (resolvedName, problems) = resolveName spanValue name
         in (IncrementStatement spanValue resolvedName annotation, problems)
    CompoundAssignmentStatement spanValue operator name _ value ->
        let (resolvedName, nameProblems) = resolveName spanValue name
            (resolvedValue, valueProblems) = resolveExpression value
         in (CompoundAssignmentStatement spanValue operator resolvedName () resolvedValue, nameProblems ++ valueProblems)
    DiscardStatement spanValue value ->
        let (resolved, problems) = resolveExpression value in (DiscardStatement spanValue resolved, problems)
    BreakStatement spanValue value ->
        let (resolvedValue, problems) = resolveOptional value
         in (BreakStatement spanValue resolvedValue, problems)
    ContinueStatement spanValue -> (ContinueStatement spanValue, [])
    GuardStatement spanValue condition block ->
        let (resolvedCondition, conditionProblems) = resolveExpression condition
            (resolvedBlock, blockProblems) = resolveBlock block
         in (GuardStatement spanValue resolvedCondition resolvedBlock, conditionProblems ++ blockProblems)
    BlockStatement spanValue block ->
        let (resolvedBlock, problems) = resolveBlock block
         in (BlockStatement spanValue resolvedBlock, problems)
    ExpressionStatement spanValue value terminated -> let (resolved, problems) = resolveExpression value in (ExpressionStatement spanValue resolved terminated, problems)

resolveOptional :: Maybe (Expression RenamedName ()) -> (Maybe (Expression ResolvedName ()), [Diagnostic])
resolveOptional Nothing = (Nothing, [])
resolveOptional (Just value) = let (resolved, problems) = resolveExpression value in (Just resolved, problems)

resolveExpression :: Expression RenamedName () -> (Expression ResolvedName (), [Diagnostic])
resolveExpression expression = case expression of
    NameExpression spanValue name _ -> let (resolved, problems) = resolveName spanValue name in (NameExpression spanValue resolved (), problems)
    LiteralExpression spanValue literal _ -> (LiteralExpression spanValue literal (), [])
    MemberAccessExpression spanValue receiver member _ ->
        let (resolvedReceiver, problems) = resolveExpression receiver
         in (MemberAccessExpression spanValue resolvedReceiver member (), problems)
    MethodReferenceExpression spanValue receiver member _ ->
        let (resolvedReceiver, problems) = resolveExpression receiver
         in (MethodReferenceExpression spanValue resolvedReceiver member (), problems)
    CallExpression spanValue callee arguments _ ->
        let (resolvedCallee, firstProblems) = resolveExpression callee; values = map resolveExpression arguments
         in (CallExpression spanValue resolvedCallee (map fst values) (), firstProblems ++ concatMap snd values)
    UnaryExpression spanValue operator value _ -> let (resolved, problems) = resolveExpression value in (UnaryExpression spanValue operator resolved (), problems)
    BinaryExpression spanValue operator left right _ ->
        let (resolvedLeft, leftProblems) = resolveExpression left; (resolvedRight, rightProblems) = resolveExpression right
         in (BinaryExpression spanValue operator resolvedLeft resolvedRight (), leftProblems ++ rightProblems)
    IsPatternExpression spanValue subject patternValue _ ->
        let (resolvedSubject, subjectProblems) = resolveExpression subject
            (resolvedPattern, patternProblems) = resolvePattern patternValue
         in (IsPatternExpression spanValue resolvedSubject resolvedPattern (), subjectProblems ++ patternProblems)
    ConditionalExpression spanValue condition first second _ ->
        let (resolvedCondition, conditionProblems) = resolveExpression condition
            (resolvedFirst, firstProblems) = resolveExpression first
            (resolvedSecond, secondProblems) = resolveExpression second
         in ( ConditionalExpression spanValue resolvedCondition resolvedFirst resolvedSecond ()
            , conditionProblems ++ firstProblems ++ secondProblems
            )
    CoalesceExpression spanValue left fallback _ ->
        let (resolvedLeft, leftProblems) = resolveExpression left
            (resolvedFallback, fallbackProblems) = resolveExpression fallback
         in (CoalesceExpression spanValue resolvedLeft resolvedFallback (), leftProblems ++ fallbackProblems)
    AssignmentExpression spanValue operator name value _ ->
        let (resolvedName, nameProblems) = resolveName spanValue name
            (resolvedValue, valueProblems) = resolveExpression value
         in (AssignmentExpression spanValue operator resolvedName resolvedValue (), nameProblems ++ valueProblems)
    IncrementExpression spanValue isPrefix name _ ->
        let (resolvedName, problems) = resolveName spanValue name
         in (IncrementExpression spanValue isPrefix resolvedName (), problems)
    LoopExpression spanValue loop _ ->
        let (resolvedLoop, problems) = resolveStatement loop
         in (LoopExpression spanValue resolvedLoop (), problems)
    BlockExpression spanValue block _ ->
        let (resolvedBlock, problems) = resolveBlock block
         in (BlockExpression spanValue resolvedBlock (), problems)
    MatchExpression spanValue subjects arms _ ->
        let resolvedSubjects = map resolveExpression subjects
            resolvedArms = map resolveMatchArm arms
         in ( MatchExpression spanValue (map fst resolvedSubjects) (map fst resolvedArms) ()
            , concatMap snd resolvedSubjects ++ concatMap snd resolvedArms
            )
    CallableExpression spanValue explicit captures parameters body _ ->
        let resolvedCaptures = map resolveCapture captures
            resolvedParameters = map resolveParameter parameters
            (resolvedBody, bodyProblems) = resolveCallableBody body
         in ( CallableExpression
                spanValue
                explicit
                (map fst resolvedCaptures)
                (map fst resolvedParameters)
                resolvedBody
                ()
            , concatMap snd resolvedCaptures ++ concatMap snd resolvedParameters ++ bodyProblems
            )

resolveMatchArm :: MatchArm RenamedName () -> (MatchArm ResolvedName (), [Diagnostic])
resolveMatchArm (MatchArm spanValue patterns guard body) =
    let resolvedPatterns = map resolveMatchPattern patterns
        (resolvedGuard, guardProblems) = resolveOptional guard
        (resolvedBody, bodyProblems) = resolveExpression body
     in ( MatchArm spanValue (map fst resolvedPatterns) resolvedGuard resolvedBody
        , concatMap snd resolvedPatterns ++ guardProblems ++ bodyProblems
        )

resolveMatchPattern :: MatchPattern RenamedName () -> (MatchPattern ResolvedName (), [Diagnostic])
resolveMatchPattern patternValue = case patternValue of
    MatchWildcardPattern spanValue _ -> (MatchWildcardPattern spanValue (), [])
    MatchLiteralPattern spanValue literal _ -> (MatchLiteralPattern spanValue literal (), [])
    MatchNullPattern spanValue _ -> (MatchNullPattern spanValue (), [])
    MatchCasePattern spanValue name _ -> (MatchCasePattern spanValue name (), [])
    MatchTypePattern spanValue syntax Nothing _ -> (MatchTypePattern spanValue syntax Nothing (), [])
    MatchTypePattern spanValue syntax (Just name) _ ->
        let (resolvedName, problems) = resolveName spanValue name
         in (MatchTypePattern spanValue syntax (Just resolvedName) (), problems)

resolvePattern :: Pattern RenamedName () -> (Pattern ResolvedName (), [Diagnostic])
resolvePattern patternValue = case patternValue of
    WildcardPattern spanValue _ -> (WildcardPattern spanValue (), [])
    NullPattern spanValue _ -> (NullPattern spanValue (), [])
    LiteralPattern spanValue literal _ -> (LiteralPattern spanValue literal (), [])
    TypePattern spanValue syntax _ -> (TypePattern spanValue syntax (), [])
    RelationalPattern spanValue operator literal _ -> (RelationalPattern spanValue operator literal (), [])
    NotPattern spanValue nested _ ->
        let (resolved, problems) = resolvePattern nested
         in (NotPattern spanValue resolved (), problems)
    AndPattern spanValue left right _ -> resolvePair AndPattern spanValue left right
    OrPattern spanValue left right _ -> resolvePair OrPattern spanValue left right
    where
        resolvePair constructor spanValue left right =
            let (resolvedLeft, leftProblems) = resolvePattern left
                (resolvedRight, rightProblems) = resolvePattern right
             in (constructor spanValue resolvedLeft resolvedRight (), leftProblems ++ rightProblems)

resolveCapture :: Capture RenamedName () -> (Capture ResolvedName (), [Diagnostic])
resolveCapture (Capture spanValue mode name _ initializer) =
    let (resolvedName, nameProblems) = resolveName spanValue name
        (resolvedInitializer, initializerProblems) = resolveOptional initializer
     in ( Capture spanValue mode resolvedName () resolvedInitializer
        , nameProblems ++ initializerProblems
        )

resolveCallableBody ::
    CallableBody RenamedName () ->
    (CallableBody ResolvedName (), [Diagnostic])
resolveCallableBody body = case body of
    CallableExpressionBody expression ->
        let (resolved, problems) = resolveExpression expression
         in (CallableExpressionBody resolved, problems)
    CallableBlockBody block ->
        let (resolved, problems) = resolveBlock block
         in (CallableBlockBody resolved, problems)

resolveName :: SourceSpan -> RenamedName -> (ResolvedName, [Diagnostic])
resolveName spanValue name
    | renamedUnique name > 0 = (ResolvedName (SymbolId (renamedUnique name)) (renamedSpelling name), [])
    -- The names the language declares for every program.
    | SymbolId (renamedUnique name) `elem` [builtinSystemSymbol, builtinConsoleSymbol] =
        (ResolvedName (SymbolId (renamedUnique name)) (renamedSpelling name), [])
    | renamedUnique name == 0 =
        ( ResolvedName (SymbolId 0) (renamedSpelling name)
        ,
            [ Diagnostic
                NameResolutionStage
                Error
                "TAN0002"
                (Just spanValue)
                "reserved symbol id zero reached name resolution"
            ]
        )
    | otherwise =
        ( ResolvedName (SymbolId (-1)) (renamedSpelling name)
        ,
            [ Diagnostic
                NameResolutionStage
                Error
                "TAN0001"
                (Just spanValue)
                ("unknown name " ++ identifierText (renamedSpelling name))
            ]
        )
