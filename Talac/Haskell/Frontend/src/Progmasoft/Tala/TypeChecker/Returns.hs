-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | What the typed tree of a body returns and what leaves its loops.

The checker for statements reports the returns it meets, but a @return@ may
also stand in a block used as a value, which is reached through an
expression. The types a body returns are therefore read from its typed tree
here, statements and expressions alike. A nested callable is a function of
its own: its returns are not the returns of the body that creates it.
-}
module Progmasoft.Tala.TypeChecker.Returns
    ( typedExpressionType
    , blockReturnTypes
    , loopBreakTypes
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Completion

-- | The type the checker gave an expression.
typedExpressionType :: Expression name Type -> Type
typedExpressionType expression = case expression of
    NameExpression _ _ valueType -> valueType
    LiteralExpression _ _ valueType -> valueType
    MemberAccessExpression _ _ _ valueType -> valueType
    MethodReferenceExpression _ _ _ valueType -> valueType
    CallExpression _ _ _ valueType -> valueType
    UnaryExpression _ _ _ valueType -> valueType
    BinaryExpression _ _ _ _ valueType -> valueType
    IsPatternExpression _ _ _ valueType -> valueType
    ConditionalExpression _ _ _ _ valueType -> valueType
    CoalesceExpression _ _ _ valueType -> valueType
    AssignmentExpression _ _ _ _ valueType -> valueType
    IncrementExpression _ _ _ valueType -> valueType
    LoopExpression _ _ valueType -> valueType
    BlockExpression _ _ valueType -> valueType
    MatchExpression _ _ _ valueType -> valueType
    CallableExpression _ _ _ _ _ valueType -> valueType

{- | The types of the values every @return@ of a block carries, in source
order. A @return@ without a value carries @void@. A returned expression that
never yields a value carries none; the returns inside it are listed in its
place.
-}
blockReturnTypes :: Block name Type -> [Type]
blockReturnTypes (Block statements) = concatMap statementReturnTypes statements

statementReturnTypes :: Statement name Type -> [Type]
statementReturnTypes statement = case statement of
    ReturnStatement _ Nothing -> [voidType]
    ReturnStatement _ (Just value)
        | doesNotComplete value -> expressionReturnTypes value
        | otherwise -> typedExpressionType value : expressionReturnTypes value
    BindingStatement _ _ _ _ _ value -> expressionReturnTypes value
    AssignmentStatement _ _ _ value -> expressionReturnTypes value
    IfStatement _ condition whenTrue whenFalse ->
        expressionReturnTypes condition ++ blockReturnTypes whenTrue ++ maybe [] blockReturnTypes whenFalse
    WhileStatement _ condition body -> expressionReturnTypes condition ++ blockReturnTypes body
    DoWhileStatement _ body condition -> blockReturnTypes body ++ expressionReturnTypes condition
    ForStatement _ initializer condition updates body ->
        maybe [] statementReturnTypes initializer
            ++ maybe [] expressionReturnTypes condition
            ++ blockReturnTypes body
            ++ concatMap statementReturnTypes updates
    ForEachStatement _ _ _ _ _ source body -> expressionReturnTypes source ++ blockReturnTypes body
    IncrementStatement {} -> []
    CompoundAssignmentStatement _ _ _ _ value -> expressionReturnTypes value
    DiscardStatement _ value -> expressionReturnTypes value
    BreakStatement _ value -> maybe [] expressionReturnTypes value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> expressionReturnTypes condition ++ blockReturnTypes block
    BlockStatement _ block -> blockReturnTypes block
    ExpressionStatement _ value _ -> expressionReturnTypes value

expressionReturnTypes :: Expression name Type -> [Type]
expressionReturnTypes expression = case expression of
    NameExpression {} -> []
    LiteralExpression {} -> []
    MemberAccessExpression _ receiver _ _ -> expressionReturnTypes receiver
    MethodReferenceExpression _ receiver _ _ -> expressionReturnTypes receiver
    CallExpression _ callee arguments _ -> concatMap expressionReturnTypes (callee : arguments)
    UnaryExpression _ _ value _ -> expressionReturnTypes value
    BinaryExpression _ _ left right _ -> expressionReturnTypes left ++ expressionReturnTypes right
    IsPatternExpression _ subject _ _ -> expressionReturnTypes subject
    ConditionalExpression _ condition first second _ -> concatMap expressionReturnTypes [condition, first, second]
    CoalesceExpression _ left fallback _ -> expressionReturnTypes left ++ expressionReturnTypes fallback
    AssignmentExpression _ _ _ value _ -> expressionReturnTypes value
    IncrementExpression {} -> []
    LoopExpression _ loop _ -> statementReturnTypes loop
    BlockExpression _ block _ -> blockReturnTypes block
    MatchExpression _ subjects arms _ ->
        concatMap expressionReturnTypes subjects ++ concatMap armReturnTypes arms
    -- A callable returns from itself.
    CallableExpression {} -> []
    where
        armReturnTypes arm = maybe [] expressionReturnTypes (matchArmGuard arm) ++ expressionReturnTypes (matchArmBody arm)

{- | The types of the values carried by the breaks that leave this loop
itself, from its body, its condition and its update clause, also out of
blocks used as values. Breaks of nested loops leave those loops.
-}
loopBreakTypes :: Statement name Type -> [Type]
loopBreakTypes loop = [typedExpressionType value | BreakStatement _ (Just value) <- transfers]
    where
        transfers = case loop of
            WhileStatement _ condition body -> expressionTransfers condition ++ blockTransfers body
            ForStatement _ _ condition updates body ->
                maybe [] expressionTransfers condition ++ blockTransfers body ++ concatMap statementTransfers updates
            _ -> []
