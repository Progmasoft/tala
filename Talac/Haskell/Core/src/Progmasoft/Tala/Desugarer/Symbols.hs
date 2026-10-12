-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Tables the lowering to Core reads and does not change: the symbols a
typed tree already uses, and the Core primitive each source operator stands
for.
-}
module Progmasoft.Tala.Desugarer.Symbols
    ( syntaxSymbolIds
    , lowerUnary
    , lowerBinary
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Core

{- | Every symbol a typed tree declares or binds.

Generated Core bindings must never collide with source symbols. Gathering
the complete typed tree once is cheaper and more robust than reserving a
magic numeric range or deriving identities from source positions.
-}
syntaxSymbolIds :: SyntaxTree ResolvedName Type -> [Int]
syntaxSymbolIds (SyntaxTree _ declarations) = concatMap declarationSymbolIds declarations

declarationSymbolIds :: Declaration ResolvedName Type -> [Int]
declarationSymbolIds declaration =
    symbolValue (declarationName declaration)
        : case declaration of
            TypeDeclaration {typeMembers = members} -> concatMap declarationSymbolIds members
            TemplateTypeDeclaration {declarationTemplateParameters = parameters, typeMembers = members} ->
                map (symbolValue . templateParameterName) parameters ++ concatMap declarationSymbolIds members
            FunctionDeclaration {declarationParameters = parameters, declarationBody = body} ->
                map (symbolValue . parameterName) parameters ++ blockSymbolIds body
            EnumDeclaration {} -> []

blockSymbolIds :: Block ResolvedName Type -> [Int]
blockSymbolIds (Block statements) = concatMap statementIds statements

statementIds :: Statement ResolvedName Type -> [Int]
statementIds statement = case statement of
    BindingStatement _ _ _ name _ value -> symbolValue name : expressionIds value
    AssignmentStatement _ name _ value -> symbolValue name : expressionIds value
    ReturnStatement _ value -> maybe [] expressionIds value
    IfStatement _ condition yes no -> expressionIds condition ++ blockSymbolIds yes ++ maybe [] blockSymbolIds no
    WhileStatement _ condition body -> expressionIds condition ++ blockSymbolIds body
    DoWhileStatement _ body condition -> blockSymbolIds body ++ expressionIds condition
    ForStatement _ initializer condition updates body ->
        maybe [] statementIds initializer
            ++ maybe [] expressionIds condition
            ++ concatMap statementIds updates
            ++ blockSymbolIds body
    ForEachStatement _ _ _ name _ source body ->
        symbolValue name : expressionIds source ++ blockSymbolIds body
    IncrementStatement _ name _ -> [symbolValue name]
    CompoundAssignmentStatement _ _ name _ value -> symbolValue name : expressionIds value
    DiscardStatement _ value -> expressionIds value
    BreakStatement _ value -> maybe [] expressionIds value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> expressionIds condition ++ blockSymbolIds block
    BlockStatement _ block -> blockSymbolIds block
    ExpressionStatement _ value _ -> expressionIds value

expressionIds :: Expression ResolvedName Type -> [Int]
expressionIds expression = case expression of
    NameExpression _ name _ -> [symbolValue name]
    LiteralExpression {} -> []
    MemberAccessExpression _ receiver _ _ -> expressionIds receiver
    MethodReferenceExpression _ receiver _ _ -> expressionIds receiver
    CallExpression _ callee arguments _ -> expressionIds callee ++ concatMap expressionIds arguments
    UnaryExpression _ _ value _ -> expressionIds value
    BinaryExpression _ _ left right _ -> expressionIds left ++ expressionIds right
    IsPatternExpression _ subject _ _ -> expressionIds subject
    ConditionalExpression _ condition first second _ -> concatMap expressionIds [condition, first, second]
    CoalesceExpression _ left fallback _ -> expressionIds left ++ expressionIds fallback
    AssignmentExpression _ _ name value _ -> symbolValue name : expressionIds value
    IncrementExpression _ _ name _ -> [symbolValue name]
    LoopExpression _ loop _ -> statementIds loop
    BlockExpression _ block _ -> blockSymbolIds block
    MatchExpression _ subjects arms _ ->
        [ symbolValue name
        | arm <- arms
        , Just name <- map matchPatternBinding (matchArmPatterns arm)
        ]
            ++ concatMap expressionIds (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression _ _ captures parameters body _ ->
        map (symbolValue . captureName) captures
            ++ concatMap (maybe [] expressionIds . captureInitializer) captures
            ++ map (symbolValue . parameterName) parameters
            ++ callableBodyIds body

callableBodyIds :: CallableBody ResolvedName Type -> [Int]
callableBodyIds body = case body of
    CallableExpressionBody expression -> expressionIds expression
    CallableBlockBody block -> blockSymbolIds block

symbolValue :: ResolvedName -> Int
symbolValue = symbolIdValue . resolvedSymbol

-- | The Core primitive of a unary operator.
lowerUnary :: UnaryOperator -> CorePrimitive
lowerUnary UnaryNegate = CoreNegate
lowerUnary LogicalNot = CoreLogicalNot
lowerUnary BitwiseNot = CoreBitwiseNot
lowerUnary UnaryPlus = CoreAdd

-- | The Core primitive of a binary operator.
lowerBinary :: BinaryOperator -> CorePrimitive
lowerBinary operator = case operator of
    Add -> CoreAdd
    Subtract -> CoreSubtract
    Multiply -> CoreMultiply
    Divide -> CoreDivide
    FloorDivide -> CoreFloorDivide
    Remainder -> CoreRemainder
    Power -> CorePower
    ShiftLeft -> CoreShiftLeft
    ShiftRight -> CoreShiftRight
    BitwiseAnd -> CoreBitwiseAnd
    BitwiseXor -> CoreBitwiseXor
    BitwiseOr -> CoreBitwiseOr
    LessThan -> CoreLessThan
    LessEqual -> CoreLessEqual
    GreaterThan -> CoreGreaterThan
    GreaterEqual -> CoreGreaterEqual
    Equal -> CoreEqual
    NotEqual -> CoreNotEqual
    LogicalAnd -> CoreLogicalAnd
    LogicalOr -> CoreLogicalOr
