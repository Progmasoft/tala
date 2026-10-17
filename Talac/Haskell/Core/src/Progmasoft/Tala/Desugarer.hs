-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

-- | Lower the typed source AST into target-independent, source-attributed Core.
module Progmasoft.Tala.Desugarer (Desugarer (..), defaultDesugarer, desugarerWithin, runDesugarer) where

import Control.Monad (forM, zipWithM)
import Control.Monad.State.Strict
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.Completion
import Progmasoft.Tala.Core
import Progmasoft.Tala.Desugarer.Boundary
import Progmasoft.Tala.Desugarer.Branching
import Progmasoft.Tala.Desugarer.Captures
import Progmasoft.Tala.Desugarer.Effects
import Progmasoft.Tala.Desugarer.Handing
import Progmasoft.Tala.Desugarer.Laziness
import Progmasoft.Tala.Desugarer.Sequencing
import Progmasoft.Tala.Desugarer.Symbols
import Progmasoft.Tala.Desugarer.Workers
import Progmasoft.Tala.Diagnostic (Diagnostic (..), DiagnosticSeverity (Error), DiagnosticStage (DesugarerStage))
import Progmasoft.Tala.RuntimeCall (runtimeFunctionIdentity, runtimeFunctionOfName)

-- | Pluggable desugaring pass from typed source semantics into Core IR.
newtype Desugarer = Desugarer
    { desugarTypedAST :: TypedAST -> Either [Diagnostic] CoreModule
    -- ^ Lower a typed tree or return source-level lowering diagnostics.
    }

-- | Run a supplied desugaring implementation.
runDesugarer :: Desugarer -> TypedAST -> Either [Diagnostic] CoreModule
runDesugarer = desugarTypedAST

-- | Default Core lowerer used by the compiler pipeline.
defaultDesugarer :: Desugarer
defaultDesugarer = Desugarer (\typed -> lowerTree [typed] typed)

{- | The lowerer for one tree of a program that is lowered as several: the
methods of ordinary types and the specializations of templates. Which calls
have an effect is decided from all the trees together, because a method of
one may call a method of another.
-}
desugarerWithin :: [TypedAST] -> Desugarer
desugarerWithin program = Desugarer (lowerTree program)

lowerTree :: [TypedAST] -> TypedAST -> Either [Diagnostic] CoreModule
lowerTree program (TypedAST tree@(SyntaxTree namespace declarations)) =
    evalStateT lowerModule initial
    where
        effects = programEffects [programDeclarations | TypedAST (SyntaxTree _ programDeclarations) <- program]
        defaultName = QualifiedName [Identifier "Main"]
        sourceFiles = nub (map portableSourcePath (concatMap declarationSourceFiles declarations))
        methods = methodDeclarations declarations
        initial =
            LowerState
                { lowerNextSymbol = 1 + maximum (0 : syntaxSymbolIds tree)
                , lowerBreakTarget = Nothing
                , lowerContinue = [CoreContinue]
                , lowerLeave = [CoreBreak]
                , lowerSettled = Nothing
                , lowerFollowing = []
                , lowerDeferred = []
                , lowerMethods = methods
                , lowerNeeds = methodNeeds (scalarType . lowerBoundaryType) (expressionActs effects) methods
                , lowerEffects = effects
                , lowerHanded = []
                , lowerSuspended = []
                , lowerWorkers = Map.empty
                , lowerPendingWorkers = []
                }
        lowerModule = do
            functions <- concat <$> mapM lowerTop declarations
            -- The functions that receive suspended computations are lowered
            -- after the methods, once it is known which of them a call asks
            -- for; lowering one may ask for more.
            workers <- lowerWorkersUntilNone
            pure
                ( CoreModuleWithSources
                    (maybe defaultName id namespace)
                    (functions ++ map fst workers)
                    sourceFiles
                    (functionSources declarations ++ map snd workers)
                )

{- | What the lowering carries besides the tree.

The break target and the lowering of @continue@ belong to the statement
being lowered. They are state rather than arguments because a statement is
also reached through an expression: a block used as a value holds statements,
and a @break@ or @continue@ in it must reach the loop around the expression.
-}
data LowerState = LowerState
    { lowerNextSymbol :: Int
    -- ^ The identity of the next compiler-generated local.
    , lowerBreakTarget :: BreakTarget
    -- ^ Where a @break value;@ of the statement being lowered stores.
    , lowerContinue :: [CoreStatement]
    {- ^ What a @continue@ of the statement being lowered becomes: the Core
    @continue@ in a loop body, and a @break@ of the enclosing one-pass loop
    in an update clause, where it ends the update.
    -}
    , lowerLeave :: [CoreStatement]
    {- ^ What a @break@ of the statement being lowered becomes, after the
    store of its value if it carries one: the Core @break@, preceded in an
    update clause that is wrapped in a one-pass loop by the store that makes
    the loop around it leave as well.
    -}
    , lowerSettled :: Maybe [SymbolId]
    {- ^ Whether bindings are evaluated by need, and if so which locals are
    not: those that are assigned after their binding and those a closure
    captures. Without a list every binding is evaluated where it stands.
    -}
    , lowerFollowing :: [Statement ResolvedName Type]
    -- ^ The statements that follow the one being lowered in its block.
    , lowerDeferred :: [(SymbolId, (ResolvedName, Expression ResolvedName Type))]
    {- ^ The bindings whose value is computed by need: for each, the flag
    that says whether it has been computed and the expression that computes
    it.
    -}
    , lowerMethods :: Map SymbolId (Declaration ResolvedName Type)
    -- ^ The methods a call can name directly.
    , lowerNeeds :: MethodNeeds
    -- ^ Which parameters of which methods are passed by need.
    , lowerEffects :: Effects
    -- ^ Which calls of the program do something that can be observed.
    , lowerHanded :: [SymbolId]
    {- ^ The locals of the function being lowered whose values may be handed
    on by need. Such a local is suspended in a callable of its own.
    -}
    , lowerSuspended :: [(SymbolId, (ResolvedName, Type))]
    {- ^ The names whose value is a suspended computation: for each, the
    callable that computes it and remembers it, with its type. A read of
    the name is a call of the callable.
    -}
    , lowerWorkers :: Map SymbolId (ResolvedName, Type)
    {- ^ For each method that a call has handed a suspended computation,
    the function that receives suspended computations in its place, with
    its type.
    -}
    , lowerPendingWorkers :: [SymbolId]
    -- ^ The methods whose such function has been named and is not lowered yet.
    }

type Lower = StateT LowerState (Either [Diagnostic])

{- | Lower with every binding evaluated where it stands. The body of a
function is lowered this way once, to learn which of its locals are assigned
and which a closure captures, and so is the body of a callable.
-}
inPlace :: Lower a -> Lower a
inPlace = evaluatingWith Nothing

{- | Lower with bindings evaluated by need, except those of the given locals,
which are assigned later or captured by a closure.
-}
byNeed :: [SymbolId] -> Lower a -> Lower a
byNeed settled = evaluatingWith (Just settled)

evaluatingWith :: Maybe [SymbolId] -> Lower a -> Lower a
evaluatingWith settled action = do
    previousSettled <- gets lowerSettled
    previousDeferred <- gets lowerDeferred
    previousSuspended <- gets lowerSuspended
    modify (\current -> current {lowerSettled = settled, lowerDeferred = [], lowerSuspended = []})
    result <- action
    modify
        ( \current ->
            current {lowerSettled = previousSettled, lowerDeferred = previousDeferred, lowerSuspended = previousSuspended}
        )
    pure result

-- | Lower with the given locals as the ones that may be handed on by need.
handing :: [SymbolId] -> Lower a -> Lower a
handing handed action = do
    previous <- gets lowerHanded
    modify (\current -> current {lowerHanded = handed})
    result <- action
    modify (\current -> current {lowerHanded = previous})
    pure result

-- | Lower with the given break target, and restore the previous one after.
targeting :: BreakTarget -> Lower a -> Lower a
targeting target action = do
    previous <- gets lowerBreakTarget
    modify (\current -> current {lowerBreakTarget = target})
    result <- action
    modify (\current -> current {lowerBreakTarget = previous})
    pure result

{- | Lower with the given lowerings of @continue@ and of @break@, and restore
the previous ones after.
-}
transferringWith :: [CoreStatement] -> [CoreStatement] -> Lower a -> Lower a
transferringWith continues leaves action = do
    previousContinue <- gets lowerContinue
    previousLeave <- gets lowerLeave
    modify (\current -> current {lowerContinue = continues, lowerLeave = leaves})
    result <- action
    modify (\current -> current {lowerContinue = previousContinue, lowerLeave = previousLeave})
    pure result

{- | Lower a part of a Core loop in which the transfers of the source loop
are the transfers of that Core loop: its body, and its condition.
-}
inCoreLoop :: Lower a -> Lower a
inCoreLoop = transferringWith [CoreContinue] [CoreBreak]

{- | The branching forms as they are lowered at the current place: a
@break value;@ in a block used as a value stores where one in the statement
around it would.
-}
branching :: (BranchLowering Lower -> Lower a) -> Lower a
branching use = gets lowerBreakTarget >>= use . branchLowering

freshPatternSubject :: Lower ResolvedName
freshPatternSubject = freshGenerated "$pattern"

freshCoalesceSubject :: Lower ResolvedName
freshCoalesceSubject = freshGenerated "$coalesce"

freshGenerated :: String -> Lower ResolvedName
freshGenerated prefix = do
    identifier <- gets lowerNextSymbol
    modify (\current -> current {lowerNextSymbol = identifier + 1})
    pure (ResolvedName (SymbolId identifier) (Identifier (prefix ++ show identifier)))

lowerTop :: Declaration ResolvedName Type -> Lower [CoreFunction]
lowerTop TypeDeclaration {typeMembers = members} = mapM lowerDeclaration members
-- Open template bodies are retained in TypedAST until specialization chooses
-- concrete arguments. Lowering them here would leak unresolved type variables
-- into Core and create one fake unspecialized native function.
lowerTop TemplateTypeDeclaration {} = pure []
-- An enum has no code: its members are constants of its underlying type,
-- which the type checker has put where they are used.
lowerTop EnumDeclaration {} = pure []
lowerTop function@FunctionDeclaration {} = (: []) <$> lowerDeclaration function

lowerDeclaration :: Declaration ResolvedName Type -> Lower CoreFunction
lowerDeclaration declaration@FunctionDeclaration {} = do
    -- The body is lowered twice. The first lowering evaluates every binding
    -- where it stands and is kept only for what it shows: the locals that
    -- are assigned after their binding and the locals a closure captures,
    -- which must have their values in place. The second evaluates every
    -- other binding by need.
    inPlaceBody <- inPlace (lowerFunctionBlock returnType (declarationBody declaration))
    needs <- gets lowerNeeds
    acts <- gets (expressionActs . lowerEffects)
    body <-
        handing (handedLocals needs acts (declarationBody declaration)) $
            byNeed
                (assignedSymbols inPlaceBody ++ capturedSymbols inPlaceBody)
                (lowerFunctionBlock returnType (declarationBody declaration))
    pure
        ( CoreFunction
            (declarationName declaration)
            [ (parameterName parameter, lowerBoundaryType (parameterAnnotation parameter))
            | parameter <- declarationParameters declaration
            ]
            returnType
            body
        )
    where
        returnType = lowerBoundaryType $ case declarationAnnotation declaration of FunctionType _ result -> result; value -> value
lowerDeclaration TypeDeclaration {} = error "type declarations are lowered through lowerTop"
lowerDeclaration TemplateTypeDeclaration {} = error "template declarations require specialization before Core lowering"
lowerDeclaration EnumDeclaration {} = error "enum declarations are lowered through lowerTop"

{- | Where a @break value;@ stores its value: the result slot of the loop
expression it leaves. A loop statement has no slot, and its body is lowered
without one, so a value-carrying break can only reach its own loop's slot.
-}
type BreakTarget = Maybe (ResolvedName, Type)

{- | The lowering of this module as the branching forms of
"Progmasoft.Tala.Desugarer.Branching" receive it. The target is where a
@break value;@ among their statements stores its value: the result slot of
the loop expression around them, if there is one.
-}
branchLowering :: BreakTarget -> BranchLowering Lower
branchLowering target =
    BranchLowering
        { branchExpression = lowerExpression
        , branchDiscarded = lowerDiscarded
        , branchStatements = lowerBlockInto target . Block
        , branchOperands = sequenceOperands
        , branchFresh = freshGenerated
        , branchType = lowerBoundaryType
        , branchLiteral = lowerLiteral
        }

lowerBlock :: Block ResolvedName Type -> Lower [CoreStatement]
lowerBlock = lowerBlockInto Nothing

{- | Lower the statements of a block in order.

A statement an expression of which never completes ends the block: it is
lowered as the statements that run until control leaves, without the store,
the binding or the test that would have received the value, and the
statements after it, which are never reached, are not lowered. Nothing is
invented for a value that does not exist.
-}
lowerBlockInto :: BreakTarget -> Block ResolvedName Type -> Lower [CoreStatement]
lowerBlockInto target = lowerBlockBefore target []

{- | Lower the statements of a block that the given statements follow. The
followers are not lowered here; they are what a binding at the end of the
block looks at to learn whether its value is needed at once.
-}
lowerBlockBefore :: BreakTarget -> [Statement ResolvedName Type] -> Block ResolvedName Type -> Lower [CoreStatement]
lowerBlockBefore target followers (Block statements) = go statements
    where
        go [] = pure []
        go (statement : remaining) = case neverCompletingExpression statement of
            Just (before, expression) -> do
                leading <- concat <$> mapM (lowerStatementInto target) before
                (leading ++) <$> lowerNeverCompleting (branchLowering target) expression
            Nothing -> do
                -- Only a statement lowered from here knows what follows it.
                -- Any other lowering of a statement sees no follower, and a
                -- binding there is computed by need.
                modify (\current -> current {lowerFollowing = remaining ++ followers})
                lowered <- lowerStatementInto target statement
                modify (\current -> current {lowerFollowing = []})
                (lowered ++) <$> go remaining

{- | The expression of a statement that is always evaluated and never
completes, with the statements that run before it as part of the same
statement.
-}
neverCompletingExpression ::
    Statement ResolvedName Type -> Maybe ([Statement ResolvedName Type], Expression ResolvedName Type)
neverCompletingExpression statement = case statement of
    BindingStatement _ _ _ _ _ value -> only value
    AssignmentStatement _ _ _ value -> only value
    CompoundAssignmentStatement _ _ _ _ value -> only value
    DiscardStatement _ value -> only value
    ReturnStatement _ (Just value) -> only value
    IfStatement _ condition _ _ -> only condition
    GuardStatement _ condition _ -> only condition
    -- A condition that leaves by a break of its own loop is lowered with
    -- the loop, which that break needs around it.
    WhileStatement _ condition _
        | not (any isBreak (expressionTransfers condition)) -> only condition
    ForStatement _ initializer (Just condition) _ _
        | doesNotComplete condition
        , not (any isBreak (expressionTransfers condition)) ->
            Just (maybe [] (: []) initializer, condition)
    ExpressionStatement _ value _ -> only value
    _ -> Nothing
    where
        only value = if doesNotComplete value then Just ([], value) else Nothing

lowerFunctionBlock :: Type -> Block ResolvedName Type -> Lower [CoreStatement]
lowerFunctionBlock returnType (Block statements) = case statementsFromEnd of
    ExpressionStatement _ expression False : remaining
        | returnType /= unitType
        , not (blockCannotComplete (Block (reverse remaining)))
        , not (doesNotComplete expression) -> do
            -- The final expression is the value the function returns, so
            -- it follows the statements before it as a return would.
            prefix <- lowerBlockBefore Nothing (take 1 statementsFromEnd) (Block (reverse remaining))
            (valuePrefix, value) <- lowerExpression expression
            pure (prefix ++ valuePrefix ++ [CoreReturn value])
    _ -> lowerBlock (Block statements)
    where
        statementsFromEnd = reverse statements

lowerStatement :: Statement ResolvedName Type -> Lower [CoreStatement]
lowerStatement = lowerStatementInto Nothing

lowerStatementInto :: BreakTarget -> Statement ResolvedName Type -> Lower [CoreStatement]
lowerStatementInto target statement = targeting target (lowerStatementWith target statement)

-- The break target is already the current one.
lowerStatementWith :: BreakTarget -> Statement ResolvedName Type -> Lower [CoreStatement]
lowerStatementWith target statement = case statement of
    BindingStatement _ kind _ name valueType value -> do
        settled <- gets lowerSettled
        deferred <- gets lowerDeferred
        following <- gets lowerFollowing
        suspended <- gets lowerSuspended
        handed <- gets lowerHanded
        needs <- gets (argumentNeeds . lowerNeeds)
        acts <- gets (expressionActs . lowerEffects)
        let loweredType = lowerBoundaryType valueType
            -- A binding must compute its value where it stands when it is
            -- assigned later or captured, when its value is not a scalar,
            -- and when its initializer has an effect.
            mustStand inPlaceLocals bound boundType initializer =
                resolvedSymbol bound `elem` inPlaceLocals
                    || not (scalarType (lowerBoundaryType boundType))
                    || not (deferrableExpression initializer)
                    || acts initializer
            -- A binding is certain to be evaluated when it must stand in
            -- place or the statement after it is certain to need it. Only
            -- such a binding makes the values its initializer reads needed.
            certain inPlaceLocals bound boundType initializer later =
                mustStand inPlaceLocals bound boundType initializer
                    || neededNext needs (certain inPlaceLocals) bound later
            -- Nothing can tell where a value is computed that cannot fail
            -- and that reads no value computed by need.
            indifferent initializer =
                not (worthDeferring initializer)
                    && not
                        ( any
                            ((`elem` map fst deferred ++ map fst suspended) . resolvedSymbol . fst)
                            (expressionNames initializer)
                        )
        case settled of
            Just inPlaceLocals
                | not (certain inPlaceLocals name valueType value following)
                , not (indifferent value) ->
                    -- A value that may be handed to another function is
                    -- suspended where that function can reach it.
                    if resolvedSymbol name `elem` handed
                        then suspendBinding name loweredType value
                        else deferBinding inPlaceLocals name loweredType value
            _ -> do
                (prefix, lowered) <- lowerExpression value
                pure (prefix ++ [CoreBind (CoreBinding name loweredType (kind == MutableBinding) lowered)])
    AssignmentStatement _ name _ value -> do
        (prefix, lowered) <- lowerExpression value
        pure (prefix ++ [CoreAssign name lowered])
    ReturnStatement _ Nothing -> pure [CoreReturn (CoreLiteral CoreUnit unitType)]
    ReturnStatement _ (Just value) -> do
        (prefix, lowered) <- lowerExpression value
        pure (prefix ++ [CoreReturn lowered])
    IfStatement _ condition trueBlock falseBlock -> do
        (prefix, loweredCondition) <- lowerExpression condition
        whenTrue <- lowerBlockInto target trueBlock
        whenFalse <- maybe (pure []) (lowerBlockInto target) falseBlock
        pure (prefix ++ [CoreIf loweredCondition whenTrue whenFalse])
    WhileStatement {} -> lowerLoop Nothing statement
    -- A loop statement has no slot for break values, and a continue in its
    -- body or condition is its own.
    DoWhileStatement _ body condition -> do
        loweredBody <- inCoreLoop (lowerBlock body)
        loweredCondition <- inCoreLoop (targeting Nothing (lowerExpression condition))
        if null (fst loweredCondition)
            then pure [CoreDoWhile loweredBody (snd loweredCondition)]
            else do
                first <- freshGenerated "$first"
                pure (doWhileLoop first loweredBody loweredCondition)
    ForStatement {} -> lowerLoop Nothing statement
    ForEachStatement spanValue _ _ _ _ _ _ ->
        lift
            ( Left
                [ Diagnostic
                    DesugarerStage
                    Error
                    "TAD0001"
                    (Just spanValue)
                    "enumerable for loops cannot be lowered without the generator and Enumerable ABI"
                ]
            )
    IncrementStatement _ name valueType ->
        let loweredType = lowerBoundaryType valueType
         in pure [stepStatement name loweredType (CoreVariable name loweredType)]
    CompoundAssignmentStatement _ operator name valueType value -> lowerCompound operator name valueType value
    DiscardStatement _ value -> lowerDiscarded value
    BreakStatement _ Nothing -> gets lowerLeave
    BreakStatement spanValue (Just value) -> case target of
        Just (slot, _) -> do
            (prefix, lowered) <- lowerExpression value
            leave <- gets lowerLeave
            pure (prefix ++ [CoreAssign slot lowered] ++ leave)
        Nothing ->
            lift
                ( Left
                    [ Diagnostic
                        DesugarerStage
                        Error
                        "TAD0002"
                        (Just spanValue)
                        "a value-carrying break reached Core lowering outside a loop expression"
                    ]
                )
    ContinueStatement _ -> gets lowerContinue
    -- The block runs when the condition is false and never completes
    -- normally, so the statements after the guard follow the empty branch.
    GuardStatement _ condition block -> do
        (prefix, loweredCondition) <- lowerExpression condition
        whenFalse <- lowerBlockInto target block
        pure (prefix ++ [CoreIf loweredCondition [] whenFalse])
    -- Core has no block statement. Every local has its own symbol, so the
    -- statements of a nested block join the enclosing sequence unchanged.
    BlockStatement _ block -> lowerBlockInto target block
    -- The arms of a statement match are statements of the enclosing body:
    -- a break in them leaves the enclosing loop and stores into its slot.
    ExpressionStatement _ (MatchExpression _ subjects arms annotation) _
        | annotation == voidType -> fst <$> lowerMatch (branchLowering target) annotation subjects arms
    ExpressionStatement _ value _ -> lowerDiscarded value

{- | Bind a local whose value is computed by need.

The binding computes nothing. It declares the local, a flag that says the
value has not been computed, and a copy of each variable the initializer
reads that is assigned somewhere in the function: the initializer means the
values those variables have here, whenever it is evaluated. The first read
of the local that is reached computes the value and sets the flag, and no
later read computes it again; see the lowering of a name.
-}
deferBinding ::
    [SymbolId] -> ResolvedName -> Type -> Expression ResolvedName Type -> Lower [CoreStatement]
deferBinding inPlaceLocals name loweredType value = do
    let changing =
            nub
                [ (seen, lowerBoundaryType seenType)
                | (seen, seenType) <- expressionNames value
                , resolvedSymbol seen `elem` inPlaceLocals
                ]
    copies <- mapM (const (freshGenerated "$seen")) changing
    known <- freshGenerated "$known"
    let renames = zip (map (resolvedSymbol . fst) changing) copies
        rename seen = maybe seen id (lookup (resolvedSymbol seen) renames)
        false = CoreLiteral (CoreBoolean False) boolType
    modify
        ( \current ->
            current {lowerDeferred = (resolvedSymbol name, (known, renameNames rename value)) : lowerDeferred current}
        )
    pure
        ( [ CoreBind (CoreBinding copy seenType False (CoreVariable seen seenType))
          | ((seen, seenType), copy) <- zip changing copies
          ]
            ++ [ CoreBind (CoreBinding known boolType True false)
               , CoreBind (CoreBinding name loweredType True (neutralValue loweredType))
               ]
        )

{- | Lower a @while@ or @for@ loop whose body and condition store break
values into the given target. Loops nested in the body are statements of
their own and are lowered without a target.

A @break@ in the condition leaves the loop. The statements of a condition
that has any stand at the top of the Core loop body, so the Core @break@
there leaves the right loop without further work.

A @continue@ in the condition abandons the rest of the condition and
evaluates the condition again; in a @for@ loop the update clause does not
run. In a @while@ loop the condition stands at the top of the Core loop
body, where the Core @continue@ does exactly that. In a @for@ loop the Core
@continue@ would run the update, so a condition that holds a @continue@ is
evaluated in a loop of its own, which the @continue@ repeats and which is
left once the condition has a result. A @break@ in such a condition leaves
that inner loop with the result still false, which leaves the @for@.

A @continue@ in the update clause ends the update, and the condition is
tested next. Core has no such transfer inside an update region, so an update
clause that holds one is wrapped in a loop that runs once: its statements,
then a @break@. The @continue@ becomes a @break@ of that loop.

A @break@ in the update clause leaves the loop, which the Core @break@ in an
update region does. In an update clause that is wrapped, it first sets a
flag that is bound before the loop, and the loop is left after the wrapper
when the flag is set.
-}
lowerLoop :: BreakTarget -> Statement ResolvedName Type -> Lower [CoreStatement]
lowerLoop target loop = case loop of
    WhileStatement _ condition body -> do
        loweredCondition <- inLoop (lowerExpression condition)
        loweredBody <- inCoreLoop (lowerBlockInto target body)
        pure [whileLoop loweredCondition loweredBody]
    ForStatement _ initializer condition updates body -> do
        modify (\current -> current {lowerFollowing = []})
        loweredInitializer <- maybe (pure []) lowerStatement initializer
        evaluatedCondition <- maybe (pure ([], alwaysTrue)) (inLoop . lowerExpression) condition
        loweredCondition <-
            if maybe False (any isContinue . expressionTransfers) condition
                then repeatable evaluatedCondition
                else pure evaluatedCondition
        loweredBody <- inCoreLoop (lowerBlockInto target body)
        let updateTransfers = concatMap statementTransfers updates
            inUpdate = lowerBlockInto target (Block updates)
        (bindings, updateRegion) <-
            if any isContinue updateTransfers
                then
                    if any isBreak updateTransfers
                        then do
                            leave <- freshGenerated "$leave"
                            let leaving = CoreVariable leave boolType
                            loweredUpdates <-
                                transferringWith [CoreBreak] [CoreAssign leave alwaysTrue, CoreBreak] inUpdate
                            pure
                                ( [CoreBind (CoreBinding leave boolType True alwaysFalse)]
                                ,
                                    [ CoreWhile alwaysTrue (loweredUpdates ++ [CoreBreak])
                                    , CoreIf leaving [CoreBreak] []
                                    ]
                                )
                        else do
                            loweredUpdates <- transferringWith [CoreBreak] [CoreBreak] inUpdate
                            pure ([], [CoreWhile alwaysTrue (loweredUpdates ++ [CoreBreak])])
                else do
                    loweredUpdates <- inCoreLoop inUpdate
                    pure ([], loweredUpdates)
        pure (loweredInitializer ++ bindings ++ [forLoop loweredCondition loweredBody updateRegion])
    _ -> lowerStatement loop
    where
        inLoop = inCoreLoop . targeting target
        alwaysTrue = CoreLiteral (CoreBoolean True) boolType
        alwaysFalse = CoreLiteral (CoreBoolean False) boolType
        -- The condition in a loop of its own, which a continue repeats. Its
        -- result is a flag, because the condition may be numeric.
        repeatable (prefix, value) = do
            holds <- freshGenerated "$holds"
            pure
                (
                    [ CoreBind (CoreBinding holds boolType True alwaysFalse)
                    , CoreWhile alwaysTrue (prefix ++ [CoreIf value [CoreAssign holds alwaysTrue] [], CoreBreak])
                    ]
                , CoreVariable holds boolType
                )

{- | Lower an expression whose value is dropped.

The expression is still evaluated. When it stored into a local, the stores
are its statements and the remaining value is a plain read with nothing left
to evaluate, so no evaluation statement is emitted for it.
-}
lowerDiscarded :: Expression ResolvedName Type -> Lower [CoreStatement]
lowerDiscarded value = do
    (prefix, lowered) <- lowerExpression value
    pure (prefix ++ [CoreEvaluate lowered | null prefix || not (survives [] lowered)])

-- | @target = operand + 1@, reading the given operand.
stepStatement :: ResolvedName -> Type -> CoreExpression -> CoreStatement
stepStatement name loweredType from =
    CoreAssign name (CorePrimitive CoreAdd [from, CoreLiteral (CoreInteger 1) loweredType] loweredType)

{- | Lower @target op= value@ to the statements that perform it.

The type checker has established that the operator result has the target
type, so the stored primitive needs no conversion. The target is read before
the right operand is evaluated; when the right operand itself assigns the
target, that earlier value is kept in a temporary.
-}
lowerCompound :: BinaryOperator -> ResolvedName -> Type -> Expression ResolvedName Type -> Lower [CoreStatement]
lowerCompound operator name valueType value = do
    (prefix, lowered) <- lowerExpression value
    let loweredType = lowerBoundaryType valueType
        current = CoreVariable name loweredType
        store left = CoreAssign name (CorePrimitive (lowerBinary operator) [left, lowered] loweredType)
    if survives (assignedSymbols prefix) current
        then pure (prefix ++ [store current])
        else do
            previous <- freshGenerated "$target"
            pure
                ( CoreBind (CoreBinding previous loweredType False current)
                    : prefix
                    ++ [store (CoreVariable previous loweredType)]
                )

{- | Make a lowered operand usable after the statements of later operands.

Operands are evaluated left to right. When a later operand has statements,
an earlier operand that would not survive them is bound to a temporary at
the point where the source evaluates it.
-}
holdAcross :: [CoreStatement] -> Lowered -> Lower Lowered
holdAcross later lowered@(prefix, value)
    | null later || survives (assignedSymbols later) value = pure lowered
    | otherwise = do
        name <- freshGenerated "$operand"
        let valueType = expressionType value
        pure (prefix ++ [CoreBind (CoreBinding name valueType False value)], CoreVariable name valueType)

-- | Combine operands that are all evaluated, in order.
sequenceOperands :: [Lowered] -> Lower ([CoreStatement], [CoreExpression])
sequenceOperands [] = pure ([], [])
sequenceOperands (operand : later) = do
    (laterPrefix, laterValues) <- sequenceOperands later
    (prefix, value) <- holdAcross laterPrefix operand
    pure (prefix ++ laterPrefix, value : laterValues)

-- | Combine one operand with the operands evaluated after it.
sequenceAfter :: Lowered -> [Lowered] -> Lower ([CoreStatement], CoreExpression, [CoreExpression])
sequenceAfter first later = do
    (laterPrefix, laterValues) <- sequenceOperands later
    (prefix, value) <- holdAcross laterPrefix first
    pure (prefix ++ laterPrefix, value, laterValues)

{- | Lower an expression to the statements that perform its stores and a
store-free Core expression for its value.

An expression without assignment or increment operands has no statements,
and its Core expression is the direct translation of the source.
-}
lowerExpression :: Expression ResolvedName Type -> Lower Lowered
lowerExpression expression = do
    deferred <- gets lowerDeferred
    needs <- gets (argumentNeeds . lowerNeeds)
    -- Whether the reads of this expression are looked through here; they
    -- are when a value by need exists and the expression may be deferred.
    let searched = not (null deferred) && deferrableExpression expression
    case if searched then neededTwice needs (map fst deferred) expression else [] of
        [] -> lowerOperands searched expression
        shared -> do
            -- Each read of a value by need carries the computation of that
            -- value. An expression that is certain to read one several
            -- times computes it once, ahead of itself, and then reads it as
            -- an ordinary local; otherwise a chain of such values would
            -- grow with a power of its length.
            forced <- concat <$> mapM (fmap fst . lowerOperands False . snd) shared
            modify
                ( \current ->
                    current {lowerDeferred = filter ((`notElem` map (resolvedSymbol . fst) shared) . fst) deferred}
                )
            (prefix, lowered) <- lowerOperands True expression
            modify (\current -> current {lowerDeferred = deferred})
            pure (forced ++ prefix, lowered)

{- | Lower an operand that its expression evaluates whenever it is itself
evaluated: the operand of a unary operator, both operands of an operator
that does not short-circuit, and the left operand of one that does.

When the reads of the expression have been looked through, those of such an
operand need no second look. A value by need that the operand is certain to
read twice is one the expression is certain to read twice, and it has been
computed ahead of the expression. Looking again at every operand would walk
a chain of operators once for each of its operators.
-}
lowerCertainOperand :: Bool -> Expression ResolvedName Type -> Lower Lowered
lowerCertainOperand searched
    | searched = lowerOperands True
    | otherwise = lowerExpression

lowerOperands :: Bool -> Expression ResolvedName Type -> Lower Lowered
lowerOperands searched expression = case expression of
    -- A read of a local whose value is computed by need computes it if no
    -- earlier read has, and reads it.
    NameExpression _ name valueType -> do
        deferred <- gets lowerDeferred
        suspended <- gets lowerSuspended
        let loweredType = lowerBoundaryType valueType
        case lookup (resolvedSymbol name) deferred of
            -- A read of a suspended value calls its callable, which
            -- computes the value if nothing has, here or anywhere else.
            Nothing
                | Just (computation, computationType) <- lookup (resolvedSymbol name) suspended ->
                    pure ([], CoreApply (CoreVariable computation computationType) [] loweredType)
            Nothing -> pure ([], CoreVariable name loweredType)
            Just (known, initializer) -> do
                (prefix, computed) <- lowerExpression initializer
                pure
                    (
                        [ CoreIf
                            (CoreVariable known boolType)
                            []
                            ( prefix
                                ++ [ CoreAssign name computed
                                   , CoreAssign known (CoreLiteral (CoreBoolean True) boolType)
                                   ]
                            )
                        ]
                    , CoreVariable name loweredType
                    )
    LiteralExpression _ literal valueType ->
        let loweredType = lowerBoundaryType valueType
         in pure ([], CoreLiteral (lowerLiteral loweredType literal) loweredType)
    MemberAccessExpression spanValue _ _ _ ->
        lift
            ( Left
                [ Diagnostic
                    DesugarerStage
                    Error
                    "TAD0003"
                    (Just spanValue)
                    "an unresolved member selector reached Core lowering"
                ]
            )
    MethodReferenceExpression spanValue _ _ _ ->
        lift
            ( Left
                [ Diagnostic
                    DesugarerStage
                    Error
                    "TAD0003"
                    (Just spanValue)
                    "an unresolved member selector reached Core lowering"
                ]
            )
    -- A call of a runtime function: its identity, and then its arguments
    -- in order.
    CallExpression _ (NameExpression _ callee _) arguments valueType
        | Just function <- runtimeFunctionOfName callee -> do
            loweredArguments <- mapM lowerExpression arguments
            (prefix, values) <- sequenceOperands loweredArguments
            let identity = CoreLiteral (CoreInteger (runtimeFunctionIdentity function)) intType
            pure (prefix, CorePrimitive CoreRuntimeCall (identity : values) (lowerBoundaryType valueType))
    -- A call that hands a value on by need goes to the function that
    -- receives suspended computations.
    CallExpression _ (NameExpression _ callee _) arguments valueType -> do
        byNeedFlags <- handsOnByNeed callee arguments
        case byNeedFlags of
            Just flags -> lowerHandingCall callee flags arguments (lowerBoundaryType valueType)
            Nothing -> do
                loweredCallee <- lowerExpression (calleeOf expression)
                loweredArguments <- mapM lowerExpression arguments
                (prefix, calleeValue, argumentValues) <- sequenceAfter loweredCallee loweredArguments
                pure (prefix, CoreApply calleeValue argumentValues (lowerBoundaryType valueType))
    CallExpression _ callee arguments valueType -> do
        loweredCallee <- lowerExpression callee
        loweredArguments <- mapM lowerExpression arguments
        (prefix, calleeValue, argumentValues) <- sequenceAfter loweredCallee loweredArguments
        pure (prefix, CoreApply calleeValue argumentValues (lowerBoundaryType valueType))
    UnaryExpression _ UnaryPlus value _ -> lowerCertainOperand searched value
    UnaryExpression _ operator value valueType -> do
        (prefix, lowered) <- lowerCertainOperand searched value
        pure (prefix, CorePrimitive (lowerUnary operator) [lowered] (lowerBoundaryType valueType))
    BinaryExpression _ operator left right valueType
        -- A right operand that never completes leaves when it is
        -- evaluated, so the operator yields a value only on the path that
        -- skips it, and that value is known: false for `&&`, true for `||`.
        | operator `elem` [LogicalAnd, LogicalOr]
        , doesNotComplete right -> do
            (leftPrefix, loweredLeft) <- lowerCertainOperand searched left
            leaving <- branching (`lowerNeverCompleting` right)
            let conjunction = operator == LogicalAnd
                skip = if conjunction then CoreIf loweredLeft leaving [] else CoreIf loweredLeft [] leaving
            pure (leftPrefix ++ [skip], CoreLiteral (CoreBoolean (not conjunction)) boolType)
        | operator `elem` [LogicalAnd, LogicalOr] -> do
            (leftPrefix, loweredLeft) <- lowerCertainOperand searched left
            loweredRight <- lowerExpression right
            if null (fst loweredRight)
                then
                    pure
                        ( leftPrefix
                        , CorePrimitive (lowerBinary operator) [loweredLeft, snd loweredRight] (lowerBoundaryType valueType)
                        )
                else do
                    result <- freshGenerated "$logical"
                    let (statements, value) = decideLogical (operator == LogicalAnd) result loweredLeft loweredRight
                    pure (leftPrefix ++ statements, value)
        | otherwise -> do
            loweredLeft <- lowerCertainOperand searched left
            loweredRight <- lowerCertainOperand searched right
            (prefix, leftValue, rightValues) <- sequenceAfter loweredLeft [loweredRight]
            pure (prefix, CorePrimitive (lowerBinary operator) (leftValue : rightValues) (lowerBoundaryType valueType))
    IsPatternExpression _ subject patternValue _ -> do
        (prefix, loweredSubject) <- lowerExpression subject
        subjectName <- freshPatternSubject
        let subjectType = lowerBoundaryType (expressionAnnotation subject)
            subjectRead = CoreVariable subjectName subjectType
            predicate = lowerPattern subjectRead subjectType patternValue
        pure (prefix, CoreLet subjectName subjectType loweredSubject predicate boolType)
    -- A choice that never yields a value is reached here only where the
    -- place that reads it survives its statements, which is the condition
    -- of a do/while loop; a statement whose expression never completes is
    -- lowered by 'lowerBlockInto' without that place. The condition is
    -- never tested, so the constant is not a value of the program.
    ConditionalExpression _ _ _ _ valueType
        | valueType == voidType -> do
            statements <- branching (`lowerNeverCompleting` expression)
            pure (statements, CoreLiteral (CoreBoolean False) boolType)
    MatchExpression _ _ arms valueType
        | valueType == voidType && not (null arms) -> do
            statements <- branching (`lowerNeverCompleting` expression)
            pure (statements, CoreLiteral (CoreBoolean False) boolType)
    -- A branch that does not complete has no value to lower.
    ConditionalExpression _ condition first second valueType
        | any doesNotComplete [first, second] -> do
            loweredCondition <- lowerExpression condition
            branching (\lowering -> lowerSelection lowering valueType loweredCondition first second)
    ConditionalExpression _ condition first second valueType -> do
        (conditionPrefix, loweredCondition) <- lowerExpression condition
        loweredFirst <- lowerExpression first
        loweredSecond <- lowerExpression second
        let loweredType = lowerBoundaryType valueType
        -- A string is an object that is owned: it is selected into a
        -- variable, which the rules of ownership for an assignment cover,
        -- and not by an expression that would hold two objects at once.
        if null (fst loweredFirst) && null (fst loweredSecond) && loweredType /= stringType
            then
                pure
                    ( conditionPrefix
                    , CoreConditional loweredCondition (snd loweredFirst) (snd loweredSecond) loweredType
                    )
            else do
                result <- freshGenerated "$selected"
                let (statements, value) = selectInto result loweredType loweredCondition loweredFirst loweredSecond
                pure (conditionPrefix ++ statements, value)
    -- The left operand is both the test and the first result. Binding it once
    -- keeps its effects single even though it is read twice.
    -- A fallback that never completes leaves when the left value is false
    -- in Boolean context, so the operator yields the left value or nothing.
    CoalesceExpression _ left fallback valueType
        | doesNotComplete fallback -> do
            (leftPrefix, loweredLeft) <- lowerExpression left
            leaving <- branching (`lowerNeverCompleting` fallback)
            subjectName <- freshCoalesceSubject
            let loweredType = lowerBoundaryType valueType
                subjectRead = CoreVariable subjectName loweredType
            pure
                ( leftPrefix
                    ++ [ CoreBind (CoreBinding subjectName loweredType False loweredLeft)
                       , CoreIf subjectRead [] leaving
                       ]
                , subjectRead
                )
    CoalesceExpression _ left fallback valueType -> do
        (leftPrefix, loweredLeft) <- lowerExpression left
        loweredFallback <- lowerExpression fallback
        subjectName <- freshCoalesceSubject
        let loweredType = lowerBoundaryType valueType
            subjectRead = CoreVariable subjectName loweredType
        if null (fst loweredFallback)
            then
                pure
                    ( leftPrefix
                    , CoreLet
                        subjectName
                        loweredType
                        loweredLeft
                        (CoreConditional subjectRead subjectRead (snd loweredFallback) loweredType)
                        loweredType
                    )
            else do
                -- The fallback stores into a local, so it runs as statements
                -- and only when the left value is false in Boolean context.
                result <- freshGenerated "$selected"
                let (statements, value) = selectInto result loweredType subjectRead ([], subjectRead) loweredFallback
                pure
                    ( leftPrefix ++ CoreBind (CoreBinding subjectName loweredType False loweredLeft) : statements
                    , value
                    )
    -- A simple assignment stores its right operand and yields the stored
    -- value, which is read back from the target.
    AssignmentExpression _ Nothing name value valueType -> do
        (prefix, lowered) <- lowerExpression value
        pure (prefix ++ [CoreAssign name lowered], CoreVariable name (lowerBoundaryType valueType))
    AssignmentExpression _ (Just operator) name value valueType -> do
        statements <- lowerCompound operator name valueType value
        pure (statements, CoreVariable name (lowerBoundaryType valueType))
    -- A prefix form yields the new value, so the target is read after the
    -- store. A postfix form yields the previous value, kept in a temporary.
    IncrementExpression _ isPrefix name valueType ->
        let loweredType = lowerBoundaryType valueType
            current = CoreVariable name loweredType
         in if isPrefix
                then pure ([stepStatement name loweredType current], current)
                else do
                    previous <- freshGenerated "$previous"
                    let previousRead = CoreVariable previous loweredType
                    pure
                        (
                            [ CoreBind (CoreBinding previous loweredType False current)
                            , stepStatement name loweredType previousRead
                            ]
                        , previousRead
                        )
    -- A loop expression runs its loop as statements. Each break that leaves
    -- it stores its value into the result slot first; the type checker has
    -- established that the loop cannot end any other way.
    -- A loop that no break leaves never yields a value; like a choice
    -- that never does, it is reached here only as the condition of a
    -- do/while loop.
    LoopExpression _ loop valueType
        | valueType == voidType -> do
            statements <- lowerLoop Nothing loop
            pure (statements, CoreLiteral (CoreBoolean False) boolType)
    LoopExpression _ loop valueType -> do
        result <- freshGenerated "$loop"
        let loweredType = lowerBoundaryType valueType
        statements <- lowerLoop (Just (result, loweredType)) loop
        pure
            ( CoreBind (CoreBinding result loweredType True (neutralValue loweredType)) : statements
            , CoreVariable result loweredType
            )
    BlockExpression _ block _ -> branching (`lowerValueBlock` block)
    MatchExpression _ subjects arms valueType -> branching (\lowering -> lowerMatch lowering valueType subjects arms)
    CallableExpression _ explicit captures parameters body valueType -> do
        let loweredParameters =
                [(parameterName parameter, lowerBoundaryType (parameterAnnotation parameter)) | parameter <- parameters]
        -- A callable is a function of its own: no loop of the function
        -- that creates it is around its body.
        -- Its bindings are computed by need like those of a method, from
        -- its own assigned and captured locals. While the function around
        -- it is lowered in place, to learn its locals, so is the callable.
        settled <- gets lowerSettled
        let lowerBody = inCoreLoop (targeting Nothing (lowerCallableBody body))
        loweredBody <- case settled of
            Nothing -> inPlace lowerBody
            Just _ -> do
                inPlaceBody <- inPlace lowerBody
                byNeed (assignedSymbols inPlaceBody ++ capturedSymbols inPlaceBody) lowerBody
        (prefix, loweredCaptures) <- lowerCaptures captures
        let returnType = case valueType of
                FunctionType _ result -> lowerBoundaryType result
                _ -> ErrorType
            closure sourceCaptures =
                CoreClosure sourceCaptures loweredParameters returnType loweredBody (lowerBoundaryType valueType)
        pure $
            if explicit
                then (prefix, closure loweredCaptures)
                else ([], closure (discoverImplicitCaptures loweredParameters loweredBody))

-- | The callee of a call expression.
calleeOf :: Expression ResolvedName Type -> Expression ResolvedName Type
calleeOf expression = case expression of
    CallExpression _ callee _ _ -> callee
    _ -> expression

-- | The type of a suspended computation of a value of the given lowered type.
suspendedType :: Type -> Type
suspendedType = FunctionType []

{- | Whether an argument is handed on by need when its parameter allows it:
computing it later gives what computing it now would give, and it either
may fail or run without end, or reads a value that is itself computed by
need. Any other argument is computed at the call, where it costs least.
-}
handedOn :: Expression ResolvedName Type -> Lower Bool
handedOn argument = do
    deferred <- gets (map fst . lowerDeferred)
    suspended <- gets (map fst . lowerSuspended)
    acts <- gets (expressionActs . lowerEffects)
    pure
        ( deferrableExpression argument
            && not (acts argument)
            && ( worthDeferring argument
                    || any ((`elem` deferred ++ suspended) . resolvedSymbol . fst) (expressionNames argument)
               )
        )

{- | Whether a call hands a value on by need, and if so which parameters of
the method are passed by need.

Only a call lowered for its own sake does: while a body is lowered in place,
to learn its locals, every argument is computed at the call.
-}
handsOnByNeed :: ResolvedName -> [Expression ResolvedName Type] -> Lower (Maybe [Bool])
handsOnByNeed callee arguments = do
    settled <- gets lowerSettled
    needs <- gets lowerNeeds
    case (settled, Map.lookup (resolvedSymbol callee) needs) of
        (Just _, Just flags) | length flags == length arguments -> do
            handed <- mapM handedOn arguments
            pure (if or (zipWith (&&) flags handed) then Just flags else Nothing)
        _ -> pure Nothing

{- | Lower a call of the function that receives suspended computations in
place of a method.

An argument of a parameter that is passed by need becomes a callable. One
that is handed on by need is suspended: nothing of it is computed here. One
that is already a suspended value is passed as it is, so a value handed
through several methods is still computed once. Any other argument is
computed here, as it always was, and its callable returns that value.
-}
lowerHandingCall :: ResolvedName -> [Bool] -> [Expression ResolvedName Type] -> Type -> Lower Lowered
lowerHandingCall callee flags arguments resultType = do
    (worker, workerType) <- workerOf callee flags
    operands <- zipWithM operand flags arguments
    (prefix, values) <- sequenceOperands operands
    pure (prefix, CoreApply (CoreVariable worker workerType) values resultType)
    where
        operand False argument = lowerExpression argument
        operand True argument = do
            suspended <- gets lowerSuspended
            lazily <- handedOn argument
            let loweredType = lowerBoundaryType (expressionAnnotation argument)
                callableType = suspendedType loweredType
            case argument of
                NameExpression _ name _
                    | Just (computation, computationType) <- lookup (resolvedSymbol name) suspended ->
                        pure ([], CoreVariable computation computationType)
                _
                    | lazily -> do
                        (prefix, computation) <- suspend loweredType argument
                        pure (prefix, CoreVariable computation callableType)
                    | otherwise -> do
                        (prefix, value) <- lowerExpression argument
                        kept <- freshGenerated "$value"
                        computation <- freshGenerated "$computed"
                        let keptValue = CoreVariable kept loweredType
                            closure =
                                CoreClosure
                                    [CoreCapture StrongCapture kept loweredType keptValue]
                                    []
                                    loweredType
                                    [CoreReturn keptValue]
                                    callableType
                        pure
                            ( prefix
                                ++ [ CoreBind (CoreBinding kept loweredType False value)
                                   , CoreBind (CoreBinding computation callableType False closure)
                                   ]
                            , CoreVariable computation callableType
                            )

{- | Suspend an expression: bind a callable that computes it when it is first
called and remembers the result, and return the name of the callable.

The callable takes the values of the variables the expression reads when it
is created, so the expression means what its variables hold here, whenever
it is computed. A suspended value the expression reads is taken as its
callable, and computed only if this one is. The functions of the module are
not taken: a callable calls them as any function does.
-}
suspend :: Type -> Expression ResolvedName Type -> Lower ([CoreStatement], ResolvedName)
suspend loweredType value = do
    deferred <- gets lowerDeferred
    -- A value in a flag and a slot of this frame cannot be computed from
    -- another function. The locals an argument reads are suspended instead,
    -- see 'handedLocals'; one that is not is computed before it is read.
    let framed =
            foldr
                (\seen others -> if resolvedSymbol (fst seen) `elem` map (resolvedSymbol . fst) others then others else seen : others)
                []
                [seen | seen <- expressionNames value, resolvedSymbol (fst seen) `elem` map fst deferred]
    forced <-
        concat <$> mapM (\(name, nameType) -> fst <$> lowerOperands False (NameExpression (expressionSourceSpan value) name nameType)) framed
    modify (\current -> current {lowerDeferred = filter ((`notElem` map (resolvedSymbol . fst) framed) . fst) deferred})
    following <- gets lowerFollowing
    modify (\current -> current {lowerFollowing = []})
    (bodyPrefix, result) <- inCoreLoop (targeting Nothing (lowerExpression value))
    modify (\current -> current {lowerDeferred = deferred, lowerFollowing = following})
    methods <- gets (Map.keys . lowerMethods)
    workers <- gets (map (resolvedSymbol . fst) . Map.elems . lowerWorkers)
    computation <- freshGenerated "$suspended"
    let body = bodyPrefix ++ [CoreReturn result]
        callableType = suspendedType loweredType
        captures =
            [ capture
            | capture <- discoverImplicitCaptures [] body
            , resolvedSymbol (coreCaptureName capture) `notElem` methods ++ workers
            ]
        closure = CoreClosure captures [] loweredType body callableType
    pure
        ( forced ++ [CoreBind (CoreBinding computation callableType False (CorePrimitive CoreMemoize [closure] callableType))]
        , computation
        )

{- | Bind a local whose value may be handed to another function by need: its
value is a suspended computation, and every read of the local calls it.
-}
suspendBinding :: ResolvedName -> Type -> Expression ResolvedName Type -> Lower [CoreStatement]
suspendBinding name loweredType value = do
    (prefix, computation) <- suspend loweredType value
    modify
        ( \current ->
            current {lowerSuspended = (resolvedSymbol name, (computation, suspendedType loweredType)) : lowerSuspended current}
        )
    pure prefix

{- | The function that receives suspended computations in place of the given
method, named on the first call that asks for it and lowered later.
-}
workerOf :: ResolvedName -> [Bool] -> Lower (ResolvedName, Type)
workerOf method flags = do
    workers <- gets lowerWorkers
    case Map.lookup (resolvedSymbol method) workers of
        Just worker -> pure worker
        Nothing -> do
            declaration <- gets ((Map.! resolvedSymbol method) . lowerMethods)
            identifier <- gets lowerNextSymbol
            let spelling = identifierText (resolvedSpelling method) ++ "$need" ++ show identifier
                worker = ResolvedName (SymbolId identifier) (Identifier spelling)
                parameterTypes =
                    [ if flag then suspendedType parameterType else parameterType
                    | (flag, parameter) <- zip flags (methodParameters declaration)
                    , let parameterType = lowerBoundaryType (parameterAnnotation parameter)
                    ]
                workerType = FunctionType parameterTypes (declarationResultType declaration)
            modify
                ( \current ->
                    current
                        { lowerNextSymbol = identifier + 1
                        , lowerWorkers = Map.insert (resolvedSymbol method) (worker, workerType) (lowerWorkers current)
                        , lowerPendingWorkers = lowerPendingWorkers current ++ [resolvedSymbol method]
                        }
                )
            pure (worker, workerType)

-- | The lowered result type of a method.
declarationResultType :: Declaration ResolvedName Type -> Type
declarationResultType declaration =
    lowerBoundaryType $ case declarationAnnotation declaration of FunctionType _ result -> result; value -> value

-- | Lower the functions that were asked for until no call asks for another.
lowerWorkersUntilNone :: Lower [(CoreFunction, (Int, FilePath))]
lowerWorkersUntilNone = do
    pending <- gets lowerPendingWorkers
    case pending of
        [] -> pure []
        method : later -> do
            modify (\current -> current {lowerPendingWorkers = later})
            worker <- lowerWorker method
            (worker :) <$> lowerWorkersUntilNone

{- | Lower the function that receives suspended computations in place of a
method.

It is the method's body once more, with the parameters that are passed by
need as suspended values: a read of one calls its callable. A parameter that
a closure of the body captures is computed when the function is entered,
because a closure takes the values of its captures when it is created.
Everything the function defines takes a fresh symbol, since the method has
been lowered from the same statements.
-}
lowerWorker :: SymbolId -> Lower (CoreFunction, (Int, FilePath))
lowerWorker method = do
    declaration <- gets ((Map.! method) . lowerMethods)
    flags <- gets ((Map.! method) . lowerNeeds)
    (worker, _) <- gets ((Map.! method) . lowerWorkers)
    needs <- gets lowerNeeds
    effects <- gets lowerEffects
    let returnType = declarationResultType declaration
        body = methodBody declaration
    inPlaceBody <- inPlace (lowerFunctionBlock returnType body)
    let captured = capturedSymbols inPlaceBody
    received <-
        forM (zip flags (methodParameters declaration)) $ \(flag, parameter) -> do
            let name = parameterName parameter
                parameterType = lowerBoundaryType (parameterAnnotation parameter)
            if flag
                then do
                    computation <- freshGenerated "$argument"
                    pure (name, parameterType, Just computation)
                else pure (name, parameterType, Nothing)
    let entered =
            [ CoreBind (CoreBinding name valueType False (CoreApply (CoreVariable computation (suspendedType valueType)) [] valueType))
            | (name, valueType, Just computation) <- received
            , resolvedSymbol name `elem` captured
            ]
        suspendedParameters =
            [ (resolvedSymbol name, (computation, suspendedType valueType))
            | (name, valueType, Just computation) <- received
            , resolvedSymbol name `notElem` captured
            ]
    lowered <-
        handing (handedLocals needs (expressionActs effects) body) $
            byNeed (assignedSymbols inPlaceBody ++ captured) $ do
                modify (\current -> current {lowerSuspended = suspendedParameters})
                lowerFunctionBlock returnType body
    let statements = entered ++ lowered
        own = nub ([name | (name, _, Nothing) <- received] ++ definedNames statements)
    replacements <- Map.fromList <$> mapM (\name -> (,) (resolvedSymbol name) <$> freshLike name) own
    let parameters =
            [ case suspendedBy of
                Just computation -> (computation, suspendedType valueType)
                Nothing -> (Map.findWithDefault name (resolvedSymbol name) replacements, valueType)
            | (name, valueType, suspendedBy) <- received
            ]
    pure
        ( CoreFunction worker parameters returnType (renameSymbols replacements statements)
        , (symbolIdValue (resolvedSymbol worker), portableSpanSource declaration)
        )
    where
        freshLike name = do
            identifier <- gets lowerNextSymbol
            modify (\current -> current {lowerNextSymbol = identifier + 1})
            pure (ResolvedName (SymbolId identifier) (resolvedSpelling name))

-- Capture initializers are evaluated in order when the closure is created,
-- like the operands of any other expression.
lowerCaptures :: [Capture ResolvedName Type] -> Lower ([CoreStatement], [CoreCapture])
lowerCaptures captures = do
    initializers <- mapM lowerInitializer captures
    (prefix, values) <- sequenceOperands initializers
    pure (prefix, zipWith capture captures values)
    where
        lowerInitializer source =
            maybe
                (pure ([], CoreVariable (captureName source) (lowerBoundaryType (captureAnnotation source))))
                lowerExpression
                (captureInitializer source)
        capture source =
            CoreCapture (captureMode source) (captureName source) (lowerBoundaryType (captureAnnotation source))

lowerCallableBody :: CallableBody ResolvedName Type -> Lower [CoreStatement]
lowerCallableBody body = case body of
    CallableExpressionBody expression
        | doesNotComplete expression -> branching (`lowerNeverCompleting` expression)
        | otherwise -> do
            (prefix, value) <- lowerExpression expression
            pure (prefix ++ [CoreReturn value])
    CallableBlockBody block ->
        let returnType = maybe unitType id (callableFinalType block)
         in lowerFunctionBlock returnType block
