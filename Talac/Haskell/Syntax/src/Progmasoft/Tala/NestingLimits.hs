-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Limits on how deeply a program may nest, checked on the parsed tree.

The stages after Core walk a function body recursively: one level of
recursion for every statement nested in another and for every expression
that is an operand of another. Their stack is finite, so a program nested
deeply enough would end the compiler with a stack overflow instead of a
diagnostic. This module rejects such a program first, at the place where the
nesting becomes too deep.

The limits bound real nesting only. Three shapes nest in the tree as deep as
they are long and are walked in a loop by every stage, so they do not count:
an @else if@ chain, whose links are all at the level of the first @if@; the
arms of a @match@, which lower to such a chain, so that the body of an arm
is one level below its match however many arms the match has; and a chain of
a binary operator, whose left operand is at the level of the operator.

What a level costs is measured, not estimated: the stack every native stage
needs per level of nesting, in an ordinary and in a sanitizer build, is
recorded in @Benchmarks/2026-10-04-Nesting-And-Chains.md@ and can be measured
again with @//Talac/Support/Tests:stack_probe@. At both limits the whole
native pipeline needs a few megabytes of the stack the compiler runs on
(@Tala/Support/CompilerStack.hpp@). The native Core reader and
writer bound both depths at 4096 for Core that does not come from this
frontend.
-}
module Progmasoft.Tala.NestingLimits
    ( maximumStatementNesting
    , maximumExpressionNesting
    , nestingProblems
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic

{- | The deepest a statement may be nested in other statements of one
function body. The statements of the body itself are at level 1.
-}
maximumStatementNesting :: Int
maximumStatementNesting = 256

{- | The deepest an expression may be nested in other expressions of one
function body. An expression that is not an operand is at level 1.
-}
maximumExpressionNesting :: Int
maximumExpressionNesting = 1024

-- | A place where one of the limits is exceeded.
data Excess
    = StatementExcess SourceSpan
    | ExpressionExcess SourceSpan

{- | Diagnostics for every function body that nests too deeply.

Each function reports at most one statement and one expression: the first
of each, in source order, that is one level beyond the limit. Nothing below
a reported node is visited, so the work stays proportional to the size of
the accepted part of the program.
-}
nestingProblems :: ParsedAST -> [Diagnostic]
nestingProblems (ParsedAST (SyntaxTree _ declarations)) = concatMap declarationProblems declarations

declarationProblems :: Declaration name annotation -> [Diagnostic]
declarationProblems declaration = case declaration of
    FunctionDeclaration {declarationBody = body} -> report (blockExcess 1 0 body)
    TypeDeclaration {typeMembers = members} -> concatMap declarationProblems members
    TemplateTypeDeclaration {typeMembers = members} -> concatMap declarationProblems members
    -- The value of a member is an expression of its own, at level 1.
    EnumDeclaration {enumCases = cases} ->
        concat [report (expressionExcess 1 1 value) | EnumCase {enumCaseValue = Just value} <- cases]
    where
        report found =
            take 1 [statementProblem spanValue | StatementExcess spanValue <- found]
                ++ take 1 [expressionProblem spanValue | ExpressionExcess spanValue <- found]

statementProblem :: SourceSpan -> Diagnostic
statementProblem spanValue =
    Diagnostic
        ParserStage
        Error
        "TAP0039"
        (Just spanValue)
        ( "statements are nested more than "
            ++ show maximumStatementNesting
            ++ " levels deep here; move the inner statements into a method of their own"
        )

expressionProblem :: SourceSpan -> Diagnostic
expressionProblem spanValue =
    Diagnostic
        ParserStage
        Error
        "TAP0040"
        (Just spanValue)
        ( "this expression is nested more than "
            ++ show maximumExpressionNesting
            ++ " levels deep; compute part of it in a statement of its own"
        )

{- | The excesses in a block whose statements are at the given statement
level, inside the given number of enclosing expressions.
-}
blockExcess :: Int -> Int -> Block name annotation -> [Excess]
blockExcess level enclosing (Block statements) = concatMap (statementExcess level enclosing) statements

statementExcess :: Int -> Int -> Statement name annotation -> [Excess]
statementExcess level enclosing statement
    | level > maximumStatementNesting = [StatementExcess (statementSourceSpan statement)]
    | otherwise = case statement of
        BindingStatement _ _ _ _ _ value -> operand value
        AssignmentStatement _ _ _ value -> operand value
        ReturnStatement _ value -> maybe [] operand value
        IfStatement _ condition whenTrue whenFalse ->
            operand condition ++ inner whenTrue ++ case whenFalse of
                Nothing -> []
                -- The next link of an else-if chain stays at this level.
                Just (Block [next@IfStatement {}]) -> statementExcess level enclosing next
                Just block -> inner block
        WhileStatement _ condition body -> operand condition ++ inner body
        DoWhileStatement _ body condition -> inner body ++ operand condition
        ForStatement _ initializer condition updates body ->
            maybe [] (statementExcess level enclosing) initializer
                ++ maybe [] operand condition
                ++ concatMap (statementExcess level enclosing) updates
                ++ inner body
        ForEachStatement _ _ _ _ _ source body -> operand source ++ inner body
        IncrementStatement {} -> []
        CompoundAssignmentStatement _ _ _ _ value -> operand value
        DiscardStatement _ value -> operand value
        BreakStatement _ value -> maybe [] operand value
        ContinueStatement {} -> []
        GuardStatement _ condition block -> operand condition ++ inner block
        BlockStatement _ block -> inner block
        ExpressionStatement _ value _ -> operand value
    where
        inner = blockExcess (level + 1) enclosing
        operand = expressionExcess level (enclosing + 1)

{- | The excesses in an expression at the given expression level. Statements
inside it, in a value block, a loop, a match arm or a closure body, are one
statement level below the statement that holds the expression, and
expressions inside those statements keep counting from this one, so the two
levels together bound how deep any walk of the body can recurse.
-}
expressionExcess :: Int -> Int -> Expression name annotation -> [Excess]
expressionExcess level depth expression
    | depth > maximumExpressionNesting = [ExpressionExcess (expressionSourceSpan expression)]
    | otherwise = case expression of
        NameExpression {} -> []
        LiteralExpression {} -> []
        MemberAccessExpression _ receiver _ _ -> operand receiver
        MethodReferenceExpression _ receiver _ _ -> operand receiver
        CallExpression _ callee arguments _ -> concatMap operand (callee : arguments)
        UnaryExpression _ _ value _ -> operand value
        -- The left operand of a binary operator is at the level of the
        -- operator: `a + b + c` nests in it as deep as the chain is long,
        -- and every stage walks that chain in a loop.
        BinaryExpression _ _ left right _ -> expressionExcess level depth left ++ operand right
        IsPatternExpression _ subject _ _ -> operand subject
        ConditionalExpression _ condition first second _ -> concatMap operand [condition, first, second]
        CoalesceExpression _ left fallback _ -> operand left ++ operand fallback
        AssignmentExpression _ _ _ value _ -> operand value
        IncrementExpression {} -> []
        LoopExpression _ loop _ -> statementExcess (level + 1) depth loop
        BlockExpression _ block _ -> blockExcess (level + 1) depth block
        MatchExpression _ subjects arms _ ->
            concatMap operand subjects ++ concatMap (concatMap operand . matchArmExpressions) arms
        CallableExpression _ _ captures _ body _ ->
            concatMap (maybe [] operand . captureInitializer) captures ++ case body of
                CallableExpressionBody value -> operand value
                CallableBlockBody block -> blockExcess (level + 1) depth block
    where
        operand = expressionExcess level (depth + 1)
