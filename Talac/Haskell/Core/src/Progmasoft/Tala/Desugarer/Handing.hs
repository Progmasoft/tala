-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | What the lowering needs to know to hand a value on by need.

An argument is a value like any other: it is computed when the method that
receives it first needs it, at most once, and not at all when the method
never needs it. A value that is computed where it stands needs nothing for
that. A value by need that one function hands to another needs a place both
can reach: the caller may need it too, and whoever needs it first computes
it for both. That place is a callable that remembers its result, a
/suspended computation/; see 'Progmasoft.Tala.Core.CoreMemoize'.

This module holds the two analyses that decide where suspended computations
are used. Both read the typed tree and neither changes it.

* 'methodNeeds' finds the parameters a method may leave unused: those are
  passed by need. A parameter the method is certain to read first of all is
  passed as a value, which costs nothing and can be told apart from passing
  it by need only by which of two failures a caller meets.

* 'handedLocals' finds the locals of a function whose values may be handed
  on by need. Such a local is suspended in a callable of its own instead of
  in a flag and a slot of the frame, because a frame cannot be reached from
  another function.
-}
module Progmasoft.Tala.Desugarer.Handing
    ( MethodNeeds
    , methodNeeds
    , argumentNeeds
    , methodDeclarations
    , methodParameters
    , methodBody
    , handedLocals
    , blockExpressions
    , within
    ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Progmasoft.Tala.AST
import Progmasoft.Tala.Desugarer.Laziness

{- | For each method that has any, which of its parameters are passed by
need, in declaration order. A method all of whose parameters are passed as
values has no entry.
-}
type MethodNeeds = Map SymbolId [Bool]

{- | The methods a call can name directly: the methods of the ordinary types
of a source set, by symbol. The methods of a template are lowered with its
specializations, in a lowering of their own.
-}
methodDeclarations :: [Declaration ResolvedName Type] -> Map SymbolId (Declaration ResolvedName Type)
methodDeclarations declarations =
    Map.fromList
        [ (resolvedSymbol (declarationName member), member)
        | TypeDeclaration {typeMembers = members} <- declarations
        , member@FunctionDeclaration {} <- members
        ]

-- | The parameters of a method; a declaration that is not a method has none.
methodParameters :: Declaration name annotation -> [Parameter name annotation]
methodParameters declaration = case declaration of
    FunctionDeclaration {declarationParameters = parameters} -> parameters
    _ -> []

-- | The body of a method; a declaration that is not a method has an empty one.
methodBody :: Declaration name annotation -> Block name annotation
methodBody declaration = case declaration of
    FunctionDeclaration {declarationBody = body} -> body
    _ -> Block []

{- | Which parameters of which methods are passed by need.

A parameter is passed by need when its type can be suspended, as the given
predicate decides, and the method is not certain to need it before anything
else that can be observed; see 'neededFirst'. Computing such an argument at
the call then differs from computing it where the method needs it in
nothing but the place.

Whether a statement reads a parameter depends on the methods it calls: a
call does not read an argument it passes by need. The answer therefore
starts from every parameter of a suspendable type being passed by need,
under which a call reads the fewest arguments, and is computed again from
its own result until it no longer changes. Each round can only find more
parameters that are certain to be read, so the rounds end.
-}
methodNeeds ::
    (Type -> Bool) ->
    -- | Whether evaluating an expression may do something observable.
    (Expression ResolvedName Type -> Bool) ->
    Map SymbolId (Declaration ResolvedName Type) ->
    MethodNeeds
methodNeeds suspendable acts methods = Map.filter or (settle (Map.map suspendableParameters methods))
    where
        suspendableParameters declaration =
            [suspendable (parameterAnnotation parameter) | parameter <- methodParameters declaration]
        settle current =
            let next = Map.mapWithKey (refine current) current
             in if next == current then current else settle next
        refine current symbol flags = case Map.lookup symbol methods of
            Just declaration@FunctionDeclaration {declarationBody = Block statements} ->
                [ flag && not (neededFirst (argumentNeeds current) acts (parameterName parameter) statements)
                | (flag, parameter) <- zip flags (methodParameters declaration)
                ]
            _ -> flags

{- | Whether the first thing a body does that can be observed needs the given
parameter.

The statements are followed in order for as long as nothing they do can be
observed. A binding whose initializer has no effect computes nothing where
it stands: it is passed over, and when its value always needs the parameter
its name is remembered, because a later need of that name is a need of the
parameter. A statement that evaluates an expression which can neither fail
nor run without end is passed over as well. The answer is found at the
first statement that needs the parameter or one of the remembered names,
and it is no at the first statement that could do anything else: fail,
never return, choose a path or leave.

A parameter this holds for may be computed at the call. A caller can tell
only which of two failures it meets when the argument and the statement
that needs it both fail, and the language leaves that open.
-}
neededFirst ::
    ArgumentNeeds ResolvedName ->
    (Expression ResolvedName Type -> Bool) ->
    ResolvedName ->
    [Statement ResolvedName Type] ->
    Bool
neededFirst needs acts parameter = go [parameter]
    where
        go _ [] = False
        go names (statement : later) = case statement of
            BindingStatement _ _ _ bound _ value
                | deferrable value -> go (if needing names value then bound : names else names) later
                | otherwise -> evaluated names value later
            -- A remembered name that is stored into is a local that is
            -- computed where it is bound, which is where it needed the
            -- parameter.
            AssignmentStatement _ target _ value -> target `elem` names || evaluated names value later
            CompoundAssignmentStatement _ _ target _ value -> target `elem` names || evaluated names value later
            IncrementStatement _ target _ -> target `elem` names || go names later
            DiscardStatement _ value -> evaluated names value later
            ExpressionStatement _ value _ -> evaluated names value later
            ReturnStatement _ (Just value) -> needing names value
            IfStatement _ condition _ _ -> needing names condition
            GuardStatement _ condition _ -> needing names condition
            WhileStatement _ condition _ -> needing names condition
            _ -> False
        evaluated names value later = needing names value || (quiet value && go names later)
        quiet value = deferrable value && not (worthDeferring value)
        -- An expression that acts is evaluated where it stands: what it
        -- does happens before anything after it.
        deferrable value = deferrableExpression value && not (acts value)
        needing names value = any (\name -> alwaysReads needs name value) names

-- | The needs of a method by its name, as the laziness analysis asks for them.
argumentNeeds :: MethodNeeds -> ArgumentNeeds ResolvedName
argumentNeeds needs name = Map.lookup (resolvedSymbol name) needs

{- | The locals of a function body whose values may be handed on by need.

A local is handed on when an argument that may be passed by need reads it,
and when the initializer of a local that is handed on reads it: the
suspended computation of the one reads the other, from wherever it runs.
The result may name locals that turn out to be computed where they stand;
for those it has no consequence.
-}
handedLocals :: MethodNeeds -> (Expression ResolvedName Type -> Bool) -> Block ResolvedName Type -> [SymbolId]
handedLocals needs acts body = Set.toList (close seeds)
    where
        expressions = blockExpressions body
        initializers =
            Map.fromList
                [ (resolvedSymbol name, map (resolvedSymbol . fst) (expressionNames value))
                | (name, value) <- blockBindings body
                , deferrableExpression value
                , not (acts value)
                ]
        seeds =
            Set.fromList
                [ resolvedSymbol name
                | CallExpression _ (NameExpression _ callee _) arguments _ <- expressions
                , Just flags <- [Map.lookup (resolvedSymbol callee) needs]
                , length flags == length arguments
                , (True, argument) <- zip flags arguments
                , deferrableExpression argument
                , not (acts argument)
                , (name, _) <- expressionNames argument
                ]
        close :: Set SymbolId -> Set SymbolId
        close current =
            let reached =
                    Set.fromList
                        [ source
                        | symbol <- Set.toList current
                        , source <- Map.findWithDefault [] symbol initializers
                        ]
                next = Set.union current reached
             in if Set.size next == Set.size current then current else close next

-- | Every binding of a block with its initializer, at any depth.
blockBindings :: Block name annotation -> [(name, Expression name annotation)]
blockBindings block =
    [(name, value) | BindingStatement _ _ _ name _ value <- statementsWithin block]

{- | Every expression of a block: those its statements hold, and every
expression inside those, at any depth.
-}
blockExpressions :: Block name annotation -> [Expression name annotation]
blockExpressions block = concatMap within (concatMap statementExpressions (statementsWithin block))

{- | Every statement of a block, at any depth: the statements of the blocks
its statements hold, and of the blocks, loops and callables its expressions
hold.
-}
statementsWithin :: Block name annotation -> [Statement name annotation]
statementsWithin (Block statements) = concatMap statementsOf statements
    where
        statementsOf statement =
            statement
                : concatMap statementsWithin (statementBlocks statement)
                ++ concatMap statementsOf (statementStatements statement)
                ++ concatMap inExpression (statementExpressions statement)
        inExpression expression = concatMap held (within expression)
        held expression = case expression of
            LoopExpression _ loop _ -> statementsOf loop
            BlockExpression _ block _ -> statementsWithin block
            CallableExpression _ _ _ _ (CallableBlockBody block) _ -> statementsWithin block
            _ -> []

-- | The blocks a statement holds directly.
statementBlocks :: Statement name annotation -> [Block name annotation]
statementBlocks statement = case statement of
    IfStatement _ _ whenTrue whenFalse -> whenTrue : maybe [] (: []) whenFalse
    WhileStatement _ _ body -> [body]
    DoWhileStatement _ body _ -> [body]
    ForStatement _ _ _ _ body -> [body]
    ForEachStatement _ _ _ _ _ _ body -> [body]
    GuardStatement _ _ block -> [block]
    BlockStatement _ block -> [block]
    _ -> []

-- | The statements a statement holds directly, outside its blocks.
statementStatements :: Statement name annotation -> [Statement name annotation]
statementStatements statement = case statement of
    ForStatement _ initializer _ updates _ -> maybe [] (: []) initializer ++ updates
    _ -> []

-- | The expressions a statement holds directly.
statementExpressions :: Statement name annotation -> [Expression name annotation]
statementExpressions statement = case statement of
    BindingStatement _ _ _ _ _ value -> [value]
    AssignmentStatement _ _ _ value -> [value]
    ReturnStatement _ value -> maybe [] (: []) value
    IfStatement _ condition _ _ -> [condition]
    WhileStatement _ condition _ -> [condition]
    DoWhileStatement _ _ condition -> [condition]
    ForStatement _ _ condition _ _ -> maybe [] (: []) condition
    ForEachStatement _ _ _ _ _ source _ -> [source]
    IncrementStatement {} -> []
    CompoundAssignmentStatement _ _ _ _ value -> [value]
    DiscardStatement _ value -> [value]
    BreakStatement _ value -> maybe [] (: []) value
    ContinueStatement _ -> []
    GuardStatement _ condition _ -> [condition]
    BlockStatement {} -> []
    ExpressionStatement _ value _ -> [value]

{- | An expression and every expression inside it that belongs to the same
evaluation: operands, arms, capture initializers and the expression body of
a callable. The statements an expression holds are reached through
'statementsWithin'.

Each expression is put in front of the ones that follow it. Appending the
expressions of one operand to those of another would copy the expressions
of a chain of operators once for each operator of the chain.
-}
within :: Expression name annotation -> [Expression name annotation]
within expression = collect expression []
    where
        collect value following = value : foldr collect following (children value)
        children value = case value of
            NameExpression {} -> []
            LiteralExpression {} -> []
            MemberAccessExpression _ receiver _ _ -> [receiver]
            MethodReferenceExpression _ receiver _ _ -> [receiver]
            CallExpression _ callee arguments _ -> callee : arguments
            UnaryExpression _ _ operand _ -> [operand]
            BinaryExpression _ _ left right _ -> [left, right]
            IsPatternExpression _ subject _ _ -> [subject]
            ConditionalExpression _ condition first second _ -> [condition, first, second]
            CoalesceExpression _ left fallback _ -> [left, fallback]
            AssignmentExpression _ _ _ assigned _ -> [assigned]
            IncrementExpression {} -> []
            LoopExpression {} -> []
            BlockExpression {} -> []
            MatchExpression _ subjects arms _ ->
                subjects ++ concat [maybe [] (: []) (matchArmGuard arm) ++ [matchArmBody arm] | arm <- arms]
            CallableExpression _ _ captures _ body _ ->
                [initializer | Capture {captureInitializer = Just initializer} <- captures]
                    ++ case body of
                        CallableExpressionBody result -> [result]
                        CallableBlockBody _ -> []
