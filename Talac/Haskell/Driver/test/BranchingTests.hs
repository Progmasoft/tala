-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Vertical tests for @match@, for @if@ used as an expression, for
@guard@, and for a block written as a statement.

The parser tests pin the shape of each form and the diagnostics of the
spellings that are recognized but not accepted. The type tests pin every rule
that decides whether a match has a value: one type for all arms, an arm that
always accepts, no arm that can never be selected. The evaluation tests state
the value each program must compute and run the reference evaluator of
"CoreInterpreter" on the unoptimized and on the optimized Core, so a lowering
that selects the wrong arm, evaluates a subject twice, or runs a guard that
should not run is observed as a wrong result.
-}
module BranchingTests (branchingTests) where

import BranchingEvaluationCases (evaluationCases)
import CoreInterpreter
import Data.List (isInfixOf, isPrefixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Specialization

branchingTests :: [(String, Bool)]
branchingTests = parserTests ++ typeTests ++ loweringTests ++ evaluationTests ++ pipelineTests

-- ---------------------------------------------------------------- sources

body :: String -> String
body statements =
    unlines
        [ "class Program {"
        , "    public static int Evaluate(_ bool flag, _ bool other, _ int left, _ int right) {"
        , "        " ++ statements
        , "    }"
        , "    public static int Twice(_ int value) { return value + value; }"
        , "}"
        ]

parseSource :: String -> Either [Diagnostic] ParsedAST
parseSource text = do
    tokens <- runLexer defaultLexer (LexerInput "branching.tala" text)
    runParser defaultParser (ParserInput "branching.tala" tokens)

parses :: String -> Bool
parses text = either (const False) (const True) (parseSource text)

-- | Whether parsing stops with the given diagnostic.
parseFailsWith :: String -> String -> Bool
parseFailsWith code text = case parseSource text of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

firstStatements :: String -> Maybe [Statement Identifier ()]
firstStatements text = case parseSource text of
    Right (ParsedAST (SyntaxTree _ (TypeDeclaration {typeMembers = member : _} : _))) -> case member of
        FunctionDeclaration {declarationBody = Block statements} -> Just statements
        _ -> Nothing
    _ -> Nothing

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "branching.tala" text)

accepted :: String -> Bool
accepted text = either (const False) (const True) (compileSource text)

rejectedWith :: String -> String -> Bool
rejectedWith code text = case compileSource text of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

-- | The codes a source is rejected with, or none when it is accepted.
codesOf :: String -> [String]
codesOf text = either (map diagnosticCode) (const []) (compileSource text)

-- ---------------------------------------------------------------- parser

parserTests :: [(String, Bool)]
parserTests =
    [ ("a match at the start of a statement is a terminated expression statement", matchStatementParses)
    , ("a match in a binding initializer is a match expression", matchExpressionParses)
    , ("every subject of a match has its own parentheses", multipleSubjectsParse)
    , ("an arm has one pattern for each subject", multiplePatternsParse)
    , ("a guard follows the patterns of its arm", guardedArmParses)
    , ("a type pattern binds a name or discards the value", typePatternsParse)
    , ("the null and enum case patterns are recognized", otherPatternsParse)
    , ("a block body is a block expression and any other body is the expression itself", armBodiesParse)
    , ("the comma after a block body is optional", parses (body "match (left) { 1 -> { } 2 -> { } } return 0;"))
    , ("the comma after the last arm is optional", parses (body "return match (left) { 1 -> 10, _ -> 20, };"))
    , ("a match without arms parses", parses (body "match (left) { } return 0;"))
    , ("the comma after an expression body is optional", parses (body "return match (left) { 1 -> 10 2 -> 20 _ -> 30 };"))
    ,
        ( "a parenthesized pattern after an expression body without a comma is read as a call"
        , parseFailsWith "TAP0038" (body "return match (left) { 1 -> Twice (2) -> 20, _ -> 30 };")
        )
    , ("a comma keeps a parenthesized pattern apart from the body before it", parses (body "return match (left) { 1 -> Twice(left), (2) -> 20, _ -> 30 };"))
    , ("an if in last position of a value block is the value of the block", nestedIfIsValue)
    , ("a match in last position of a value block is the value of the block", nestedMatchIsValue)
    , ("an if that is not last in a value block is a statement", ifInsideValueBlockIsStatement)
    , ("a match that is not last in a value block is a statement", matchInsideValueBlockIsStatement)
    ,
        ( "a statement block inside a value block may end with a match"
        , parses (body "int r = if (flag) { if (other) { match (left) { 1 -> { Twice(left); } } } 1 } else { 2 }; return r;")
        )
    ,
        ( "a value in a block that is not used as a value needs its semicolon"
        , parseFailsWith "TAP0006" (body "int r = if (flag) { if (other) { 1 } 2 } else { 3 }; return r;")
        )
    , ("a bare name is not a pattern", parseFailsWith "TAP0036" (body "match (left) { right -> { } } return 0;"))
    , ("a minus sign and a numeric literal are a pattern", parses (body "match (left) { -1 -> { } } return 0;"))
    , ("a negative pattern may stand in parentheses", parses (body "match (left), (right) { (-1), (- 2) -> { } } return 0;"))
    , ("a negative floating literal is a pattern", parses (body "double d = 1.5; return match (d) { -1.5 -> 1, _ -> 0 };"))
    , ("a minus sign before a name is not a pattern", parseFailsWith "TAP0036" (body "match (left) { -right -> { } } return 0;"))
    , ("a minus sign before a Boolean literal is not a pattern", parseFailsWith "TAP0036" (body "match (left) { -true -> { } } return 0;"))
    , ("a minus sign before a parenthesis is not a pattern", parseFailsWith "TAP0036" (body "match (left) { -(1) -> { } } return 0;"))
    , ("two minus signs are not a pattern", parseFailsWith "TAP0036" (body "match (left) { - -1 -> { } } return 0;"))
    , ("an arithmetic expression is not a pattern", not (parses (body "match (left) { 1 + 1 -> { } } return 0;")))
    , ("a plus sign before a literal is not a pattern", not (parses (body "match (left) { +1 -> { } } return 0;")))
    ,
        ( "an if whose first block leaves is the value of a value block it ends"
        , parses (body "int r = match (left) { 0 -> { if (flag) { return 9; } else { 4 } }, _ -> 1 }; return r;")
        )
    , -- The body of a method is not a block used as a value.
        ( "an if in last position of a method body stays a statement"
        , parseFailsWith "TAP0006" (body "if (flag) { 1 } else { 2 }")
        )
    , ("an unterminated match is reported", not (parses (body "match (left) { 1 -> { }")))
    , ("an if in operand position is a conditional over two value blocks", ifExpressionParses)
    , ("an if at the start of a statement stays an if statement", ifStatementKeepsItsNode)
    ,
        ( "an if used as an expression requires an else branch"
        , parseFailsWith "TAP0033" (body "int r = if (flag) { 1 }; return r;")
        )
    ,
        ( "the else branch of an if expression must be a block"
        , parseFailsWith "TAP0034" (body "int r = if (flag) { 1 } else if (other) { 2 } else { 3 }; return r;")
        )
    , ("a guard is a statement with a condition and an else block", guardParses)
    , ("a guard requires an else block", parseFailsWith "TAP0037" (body "guard (flag) { return 0; } return 1;"))
    ,
        ( "a binding condition in an if is recognized and rejected"
        , parseFailsWith "TAP0035" (body "if (auto user = Twice(left)) { return 1; } return 0;")
        )
    ,
        ( "a binding condition in a guard is recognized and rejected"
        , parseFailsWith "TAP0035" (body "guard (int user = Twice(left)) else { return 1; } return 0;")
        )
    ,
        ( "a binding condition in a while is recognized and rejected"
        , parseFailsWith "TAP0035" (body "while (auto user = Twice(left)) { return 1; } return 0;")
        )
    ,
        ( "a binding condition in an if expression is recognized and rejected"
        , parseFailsWith "TAP0035" (body "int r = if (auto user = Twice(left)) { 1 } else { 2 }; return r;")
        )
    , ("an assignment in a condition is still an expression", parses (body "int n = 0; if (n = left) { return 1; } return 0;"))
    , ("a brace at the start of a statement opens a nested block", nestedBlockParses)
    , ("nested blocks nest", parses (body "{ { { return 1; } } }"))
    , ("an empty nested block parses", parses (body "{ } return 0;"))
    ,
        ( "an unterminated nested block is reported"
        , parseFailsWith "TAP0002" "class Program { public static int Evaluate() { { int a = 1;"
        )
    , ("match is reserved and cannot name a local", not (parses (body "int match = 1; return match;")))
    , ("guard is reserved and cannot name a local", not (parses (body "int guard = 1; return guard;")))
    ]

matchStatementParses :: Bool
matchStatementParses = case firstStatements (body "match (left) { 1 -> { return 1; }, _ -> { return 2; } }") of
    Just [ExpressionStatement _ (MatchExpression _ [NameExpression _ (Identifier "left") ()] [first, second] ()) True] ->
        length (matchArmPatterns first) == 1 && length (matchArmPatterns second) == 1
    _ -> False

matchExpressionParses :: Bool
matchExpressionParses = case firstStatements (body "int r = match (left) { 1 -> 10, _ -> 20 }; return r;") of
    Just [BindingStatement _ _ _ (Identifier "r") () (MatchExpression _ [_] [_, _] ()), _] -> True
    _ -> False

multipleSubjectsParse :: Bool
multipleSubjectsParse = case firstStatements (body "match (left), (right + 1), (flag) { } return 0;") of
    Just [ExpressionStatement _ (MatchExpression _ [NameExpression {}, BinaryExpression {}, NameExpression {}] [] ()) _, _] -> True
    _ -> False

multiplePatternsParse :: Bool
multiplePatternsParse = case firstStatements (body "match (left), (right) { (1), (2) -> { }, 3, _ -> { } } return 0;") of
    Just [ExpressionStatement _ (MatchExpression _ _ [first, second] ()) _, _] ->
        case (matchArmPatterns first, matchArmPatterns second) of
            ( [MatchLiteralPattern _ (IntegerLiteral 1) (), MatchLiteralPattern _ (IntegerLiteral 2) ()]
                , [MatchLiteralPattern _ (IntegerLiteral 3) (), MatchWildcardPattern _ ()]
                ) -> True
            _ -> False
    _ -> False

guardedArmParses :: Bool
guardedArmParses = case firstStatements (body "match (left) { 2 if flag -> { }, _ -> { } } return 0;") of
    Just [ExpressionStatement _ (MatchExpression _ _ [first, second] ()) _, _] ->
        case (matchArmGuard first, matchArmGuard second) of
            (Just (NameExpression _ (Identifier "flag") ()), Nothing) -> True
            _ -> False
    _ -> False

typePatternsParse :: Bool
typePatternsParse = case firstStatements (body "match (left) { int value -> { }, int _ -> { } } return 0;") of
    Just [ExpressionStatement _ (MatchExpression _ _ [first, second] ()) _, _] ->
        case (matchArmPatterns first, matchArmPatterns second) of
            ( [MatchTypePattern _ (ExplicitType (Identifier "int")) (Just (Identifier "value")) ()]
                , [MatchTypePattern _ (ExplicitType (Identifier "int")) Nothing ()]
                ) -> True
            _ -> False
    _ -> False

otherPatternsParse :: Bool
otherPatternsParse = case firstStatements (body "match (left) { null -> { }, .Ready -> { }, true -> { }, 'a' -> { } } return 0;") of
    Just [ExpressionStatement _ (MatchExpression _ _ arms ()) _, _] -> case map matchArmPatterns arms of
        [ [MatchNullPattern _ ()]
            , [MatchCasePattern _ (Identifier "Ready") ()]
            , [MatchLiteralPattern _ (BooleanLiteral True) ()]
            , [MatchLiteralPattern _ (CharacterLiteral 97) ()]
            ] -> True
        _ -> False
    _ -> False

armBodiesParse :: Bool
armBodiesParse = case firstStatements (body "int r = match (left) { 1 -> { int t = 2; t }, _ -> left + 1 }; return r;") of
    Just [BindingStatement _ _ _ _ () (MatchExpression _ _ [first, second] ()), _] ->
        case (matchArmBody first, matchArmBody second) of
            (BlockExpression _ (Block [BindingStatement {}, ExpressionStatement _ _ False]) (), BinaryExpression {}) -> True
            _ -> False
    _ -> False

ifExpressionParses :: Bool
ifExpressionParses = case firstStatements (body "int r = if (flag) { 1 } else { int t = 2; t }; return r;") of
    Just
        [ BindingStatement
                _
                _
                _
                _
                ()
                ( ConditionalExpression
                        _
                        (NameExpression _ (Identifier "flag") ())
                        (BlockExpression _ (Block [ExpressionStatement _ _ False]) ())
                        (BlockExpression _ (Block [BindingStatement {}, ExpressionStatement _ _ False]) ())
                        ()
                    )
            , _
            ] ->
        True
    _ -> False

ifStatementKeepsItsNode :: Bool
ifStatementKeepsItsNode = case firstStatements (body "if (flag) { return 1; } else { return 2; }") of
    Just [IfStatement _ _ _ (Just _)] -> True
    _ -> False

nestedBlockParses :: Bool
nestedBlockParses = case firstStatements (body "int a = 1; { int b = 2; a = b; } return a;") of
    Just [BindingStatement {}, BlockStatement _ (Block [BindingStatement {}, AssignmentStatement {}]), ReturnStatement {}] -> True
    _ -> False

-- The statements of the first block of `int r = if (flag) { ... } else { 0 };`.
innerBlock :: String -> Maybe [Statement Identifier ()]
innerBlock inner = case firstStatements (body ("int r = if (flag) { " ++ inner ++ " } else { 0 }; return r;")) of
    Just (BindingStatement _ _ _ _ () (ConditionalExpression _ _ (BlockExpression _ (Block statements) ()) _ ()) : _) ->
        Just statements
    _ -> Nothing

nestedIfIsValue :: Bool
nestedIfIsValue = case innerBlock "if (other) { 1 } else { 2 }" of
    Just [ExpressionStatement _ (ConditionalExpression _ _ (BlockExpression {}) (BlockExpression {}) ()) False] -> True
    _ -> False

nestedMatchIsValue :: Bool
nestedMatchIsValue = case innerBlock "match (left) { 1 -> 10, _ -> 20 }" of
    Just [ExpressionStatement _ (MatchExpression {}) False] -> True
    _ -> False

ifInsideValueBlockIsStatement :: Bool
ifInsideValueBlockIsStatement = case innerBlock "if (other) { Twice(left); } else { Twice(right); } 1" of
    Just [IfStatement _ _ (Block [ExpressionStatement _ _ True]) (Just (Block [ExpressionStatement _ _ True])), ExpressionStatement _ _ False] -> True
    _ -> False

matchInsideValueBlockIsStatement :: Bool
matchInsideValueBlockIsStatement = case innerBlock "match (left) { 1 -> { Twice(left); } } 1" of
    Just [ExpressionStatement _ (MatchExpression {}) True, ExpressionStatement _ _ False] -> True
    _ -> False

guardParses :: Bool
guardParses = case firstStatements (body "guard (left > 0) else { return 0; } return 1;") of
    Just [GuardStatement _ (BinaryExpression _ GreaterThan _ _ ()) (Block [ReturnStatement {}]), _] -> True
    _ -> False

-- ---------------------------------------------------------------- types

typeTests :: [(String, Bool)]
typeTests =
    [ ("a match expression has the type of its arms", accepted (body "int r = match (left) { 1 -> 10, _ -> 20 }; return r;"))
    , ("a match expression types its literals from the receiver", accepted (body "long wide = match (left) { 1 -> 10, _ -> 20 }; return wide > 15 ? 1 : 0;"))
    , ("a literal arm takes its type from an earlier arm", accepted (body "long wide = 3; long r = match (left) { 1 -> wide, _ -> 20 }; return r > 15 ? 1 : 0;"))
    , ("a literal pattern is typed from its subject", accepted (body "long wide = 5; return match (wide) { 5 -> 1, _ -> 0 };"))
    , ("a bool subject is covered by true and false", accepted (body "return match (flag) { true -> 1, false -> 2 };"))
    , ("a type pattern that binds accepts every value", accepted (body "return match (left) { int value -> value + 1 };"))
    , ("a statement match needs no arm that always accepts", accepted (body "match (left) { 1 -> { return 1; } } return 0;"))
    , ("an accepted match reports nothing", codesOf (body "return match (left) { 1 -> 10, _ -> 20 };") == [])
    ,
        ( "a match expression that may accept nothing is rejected"
        , rejectedWith "TAT0052" (body "return match (left) { 1 -> 10, 2 -> 20 };")
        )
    ,
        ( "a guarded catch-all does not make a match expression complete"
        , rejectedWith "TAT0052" (body "return match (left) { _ if flag -> 1 };")
        )
    ,
        ( "one bool literal does not cover a bool subject"
        , rejectedWith "TAT0052" (body "return match (flag) { true -> 1 };")
        )
    ,
        ( "a guarded bool literal does not cover its value"
        , rejectedWith "TAT0052" (body "return match (flag) { true if other -> 1, false -> 2 };")
        )
    , ("a match expression without arms is rejected", rejectedWith "TAT0052" (body "return match (left) { };"))
    ,
        ( "two bool subjects are covered by their four combinations"
        , accepted
            (body "return match (flag), (other) { (true), (true) -> 3, (true), (false) -> 2, (false), (true) -> 1, (false), (false) -> 0 };")
        )
    ,
        ( "a wildcard covers both values of its bool subject"
        , accepted (body "return match (flag), (other) { (true), (_) -> 1, (false), (true) -> 2, (false), (false) -> 3 };")
        )
    ,
        ( "a missing combination of two bool subjects is rejected"
        , rejectedWith
            "TAT0052"
            (body "return match (flag), (other) { (true), (true) -> 3, (true), (false) -> 2, (false), (true) -> 1 };")
        )
    ,
        ( "a guarded combination does not count as covered"
        , rejectedWith
            "TAT0052"
            (body "return match (flag), (other) { (true), (_) -> 1, (false), (true) -> 2, (false), (false) if left > 0 -> 3 };")
        )
    ,
        ( "a bool subject beside an int subject needs a catch-all"
        , rejectedWith "TAT0052" (body "return match (flag), (left) { (true), (_) -> 1, (false), (1) -> 2 };")
        )
    ,
        ( "arms of different types are rejected"
        , rejectedWith "TAT0050" (body "long wide = 3; long r = match (left) { 1 -> wide, _ -> left }; return 0;")
        )
    ,
        ( "a match selects one of several strings"
        , accepted (body "auto text = match (left) { 1 -> \"a\", _ -> \"b\" }; return 0;")
        )
    ,
        ( "a callable match result is not lowered yet"
        , rejectedWith "TAT0051" (body "auto pick = match (left) { 1 -> \\(int v) -> v + 1, _ -> \\(int v) -> v }; return 0;")
        )
    ,
        ( "a string and a number are not arms of one match"
        , rejectedWith "TAT0050" (body "auto text = match (left) { 1 -> \"a\", _ -> 2 }; return 0;")
        )
    ,
        ( "a string is a match subject"
        , accepted (body "match (\"a\") { \"a\" -> { }, _ -> { } } return 0;")
        )
    ,
        ( "a callable subject is not lowered yet"
        , rejectedWith "TAT0058" (body "match (\\(int v) -> v) { _ -> { } } return 0;")
        )
    ,
        ( "a string subject is not matched by a number"
        , rejectedWith "TAT0054" (body "match (\"a\") { 1 -> { }, _ -> { } } return 0;")
        )
    ,
        ( "a numeric subject is not matched by a string"
        , rejectedWith "TAT0054" (body "match (left) { \"a\" -> { }, _ -> { } } return 0;")
        )
    ,
        ( "string patterns alone do not cover every string"
        , rejectedWith "TAT0052" (body "int r = match (\"a\") { \"a\" -> 1, \"b\" -> 2 }; return r;")
        )
    ,
        ( "a string pattern written twice can never be selected"
        , rejectedWith "TAT0053" (body "int r = match (\"a\") { \"a\" -> 1, \"a\" -> 2, _ -> 3 }; return r;")
        )
    ,
        ( "an arm with too few patterns is rejected"
        , rejectedWith "TAT0048" (body "match (left), (right) { 1 -> { } } return 0;")
        )
    ,
        ( "an arm with too many patterns is rejected"
        , rejectedWith "TAT0048" (body "match (left) { 1, 2 -> { } } return 0;")
        )
    ,
        ( "a second arm for the same literal can never be selected"
        , rejectedWith "TAT0053" (body "match (left) { 1 -> { }, 1 -> { } } return 0;")
        )
    ,
        ( "an arm after a catch-all can never be selected"
        , rejectedWith "TAT0053" (body "match (left) { _ -> { }, 1 -> { } } return 0;")
        )
    ,
        ( "an arm after a binding catch-all can never be selected"
        , rejectedWith "TAT0053" (body "match (left) { int value -> { }, _ -> { } } return 0;")
        )
    ,
        ( "an arm shadowed in every position can never be selected"
        , rejectedWith "TAT0053" (body "match (left), (right) { (1), (_) -> { }, (1), (2) -> { } } return 0;")
        )
    ,
        ( "a guarded arm does not shadow a later arm"
        , accepted (body "match (left) { 1 if flag -> { }, 1 -> { } } return 0;")
        )
    ,
        ( "an arm that differs in one position is reachable"
        , accepted (body "match (left), (right) { (1), (2) -> { }, (1), (_) -> { } } return 0;")
        )
    , ("a null pattern needs a reference subject", rejectedWith "TAT0055" (body "match (left) { null -> { } } return 0;"))
    , ("an enum case pattern needs enum declarations", rejectedWith "TAT0056" (body "match (left) { .Ready -> { } } return 0;"))
    ,
        ( "a type pattern must name the type of its subject"
        , rejectedWith "TAT0057" (body "match (left) { long value -> { } } return 0;")
        )
    , -- No numeric conversion is applied to a type pattern.
        ( "a wider scalar type pattern does not make a match complete by conversion"
        , rejectedWith "TAT0057" (body "return match (left) { long value -> 1 };")
        )
    ,
        ( "a narrower scalar type pattern is rejected as well"
        , rejectedWith "TAT0057" (body "return match (left) { short value -> 1, _ -> 0 };")
        )
    , ("a type pattern of the subject's own type accepts every value", accepted (body "return match (left) { int value -> value };"))
    , -- Negative constants are checked against the type of the subject.
      ("the most negative value of a type is a pattern", accepted (body "return match (left) { -9223372036854775808 -> 1, _ -> 0 };"))
    ,
        ( "a negative literal below the range of the subject is rejected"
        , rejectedWith "TAT0016" (body "return match (left) { -9223372036854775809 -> 1, _ -> 0 };")
        )
    ,
        ( "a positive literal above the range of the subject is still rejected"
        , rejectedWith "TAT0016" (body "return match (left) { 9223372036854775808 -> 1, _ -> 0 };")
        )
    , ("the range of a narrow signed subject includes its minimum", accepted (body "byte small = 1; return match (small) { -128 -> 1, 127 -> 2, _ -> 0 };"))
    ,
        ( "a negative literal below the range of a narrow subject is rejected"
        , rejectedWith "TAT0016" (body "byte small = 1; return match (small) { -129 -> 1, _ -> 0 };")
        )
    ,
        ( "a positive literal above the range of a narrow subject is rejected"
        , rejectedWith "TAT0016" (body "byte small = 1; return match (small) { 128 -> 1, _ -> 0 };")
        )
    ,
        ( "a negative literal is outside every unsigned type"
        , rejectedWith "TAT0016" (body "ubyte small = 1; return match (small) { -1 -> 1, _ -> 0 };")
        )
    , ("a second arm for the same negative value is unreachable", rejectedWith "TAT0053" (body "return match (left) { -1 -> 1, -1 -> 2, _ -> 0 };"))
    , ("minus zero is the value zero", rejectedWith "TAT0053" (body "return match (left) { 0 -> 1, -0 -> 2, _ -> 0 };"))
    ,
        ( "a negative literal does not make a match complete"
        , rejectedWith "TAT0052" (body "return match (left) { -1 -> 1, 0 -> 2, 1 -> 3 };")
        )
    , ("a literal pattern of another type is rejected", rejectedWith "TAT0054" (body "match (left) { \"a\" -> { } } return 0;"))
    , ("a guard must be bool or numeric", rejectedWith "TAT0049" (body "match (left) { 1 if \"x\" -> { } } return 0;"))
    , ("a numeric guard is accepted", accepted (body "match (left) { 1 if right -> { } } return 0;"))
    ,
        ( "a pure expression body in a statement match is rejected"
        , rejectedWith "TAT0013" (body "match (left) { 1 -> 5 } return 0;")
        )
    ,
        ( "an effectful expression body in a statement match is accepted"
        , accepted (body "int r = 0; match (left) { 1 -> r = 5, _ -> r = Twice(left) } return r;")
        )
    , ("a pattern binding may be assigned", accepted (body "match (left) { int value -> { value = 5; return value; } } return 0;"))
    ,
        ( "a nested if in last position supplies the value of its block"
        , accepted (body "int r = if (flag) { if (other) { 1 } else { 2 } } else { 3 }; return r;")
        )
    ,
        ( "a match in last position supplies the value of its block"
        , accepted (body "int r = if (flag) { match (left) { 1 -> 10, _ -> 20 } } else { 3 }; return r;")
        )
    ,
        ( "a match in last position of a value block must accept every value"
        , rejectedWith "TAT0052" (body "int r = if (flag) { match (left) { 1 -> 10 } } else { 3 }; return r;")
        )
    ,
        ( "a match in last position of a statement arm is a statement"
        , accepted (body "match (left) { 1 -> { match (right) { 2 -> { return 2; } } } } return 0;")
        )
    ,
        ( "a pattern binding is in scope in its guard"
        , accepted (body "return match (left) { int value if value > 3 -> value, _ -> 0 };")
        )
    ,
        ( "a pattern binding is not in scope after the match"
        , not (accepted (body "match (left) { int value -> { } } return value;"))
        )
    ,
        ( "a pattern binding is not in scope in a later arm"
        , not (accepted (body "return match (left) { int value if flag -> value, _ -> value };"))
        )
    ,
        ( "two arms may bind the same name"
        , accepted (body "return match (left) { int value if flag -> value, int value -> value + 1 };")
        )
    ,
        ( "one arm cannot bind a name twice"
        , rejectedWith "TAR0008" (body "match (left), (right) { (int value), (int value) -> { } } return 0;")
        )
    ,
        ( "a pattern binding cannot reuse a name in scope"
        , rejectedWith "TAR0008" (body "match (left) { int flag -> { } } return 0;")
        )
    , ("an if expression has the type of its blocks", accepted (body "int r = if (flag) { left } else { right }; return r;"))
    , ("an if expression types its literals from the receiver", accepted (body "long wide = if (flag) { 1 } else { 2 }; return wide > 1 ? 1 : 0;"))
    ,
        ( "the blocks of an if expression must have one type"
        , rejectedWith "TAT0037" (body "long wide = 3; long r = if (flag) { wide } else { left }; return 0;")
        )
    , ("the test of an if expression must be bool or numeric", rejectedWith "TAT0036" (body "int r = if (\"s\") { 1 } else { 2 }; return r;"))
    ,
        ( "a value block must end with an expression"
        , rejectedWith "TAT0046" (body "int r = if (flag) { Twice(left); } else { 2 }; return r;")
        )
    , ("an empty value block has no value", rejectedWith "TAT0046" (body "int r = if (flag) { } else { 2 }; return r;"))
    ,
        ( "a value block may return from the method"
        , accepted (body "int r = if (flag) { return 1; } else { 3 }; return r;")
        )
    ,
        ( "a return nested inside a value block is accepted"
        , accepted (body "int r = match (left) { 1 -> { if (flag) { return 1; } 2 }, _ -> 3 }; return r;")
        )
    ,
        ( "a return in a value block must carry the return type of the method"
        , rejectedWith "TAT0005" (body "int r = if (flag) { return true; } else { 3 }; return r;")
        )
    ,
        ( "a value block that leaves gives the if expression the type of the other block"
        , rejectedWith "TAT0002" (body "bool r = if (flag) { return 1; } else { left }; return 0;")
        )
    ,
        ( "an if expression whose blocks both leave is valid"
        , accepted (body "int r = if (flag) { return 1; } else { return 2; }; return r;")
        )
    ,
        ( "a match expression whose arms all leave is valid"
        , accepted (body "int r = match (left) { 1 -> { return 1; }, _ -> { return 2; } }; return r;")
        )
    ,
        ( "an expression that never completes is not held to the type of its receiver"
        , accepted (body "bool r = if (flag) { return 1; } else { return 2; }; return r ? 1 : 0;")
        )
    ,
        ( "an inferred binding may be initialized by an expression that never completes"
        , accepted (body "auto r = if (flag) { return 1; } else { return 2; }; return 0;")
        )
    ,
        ( "the returns of an expression that never completes are still checked"
        , rejectedWith "TAT0005" (body "int r = if (flag) { return true; } else { return 2; }; return r;")
        )
    ,
        ( "the statements after an expression that never completes are still checked"
        , rejectedWith "TAT0012" (body "int r = if (flag) { return 1; } else { return 2; }; int s = r + true; return s;")
        )
    ,
        ( "a match whose arms all leave must still be exhaustive"
        , rejectedWith "TAT0052" (body "int r = match (left) { 1 -> { return 1; } }; return r;")
        )
    ,
        ( "an expression that never completes may be an operand"
        , accepted (body "int r = 1 + (if (flag) { return 1; } else { return 2; }); return r;")
        )
    ,
        ( "an expression that never completes may be a condition"
        , accepted (body "if (if (flag) { return 1; } else { return 2; }) { return 3; } return 4;")
        )
    ,
        ( "a block that ends with an expression that never completes leaves"
        , accepted (body "int r = if (left > 0) { 5 } else { if (flag) { return 1; } else { return 2; } }; return r;")
        )
    ,
        ( "a right operand of && that never completes does not end the statement"
        , rejectedWith "TAT0061" (body "guard (left > 0) else { bool b = flag && (if (other) { return 1; } else { return 2; }); } return 5;")
        )
    ,
        ( "a right operand of || that never completes does not end the statement"
        , rejectedWith "TAT0061" (body "guard (left > 0) else { bool b = flag || (if (other) { return 1; } else { return 2; }); } return 5;")
        )
    ,
        ( "a conditional result that never completes does not end the statement"
        , rejectedWith "TAT0061" (body "guard (left > 0) else { int q = flag ? 1 : (if (other) { return 1; } else { return 2; }); } return 5;")
        )
    ,
        ( "a coalescing fallback that never completes does not end the statement"
        , rejectedWith "TAT0061" (body "guard (left > 0) else { int q = right ?: (if (other) { return 1; } else { return 2; }); } return 5;")
        )
    ,
        ( "a left operand of && that never completes ends the statement"
        , accepted (body "guard (left > 0) else { bool b = (if (other) { return 1; } else { return 2; }) && flag; } return 5;")
        )
    ,
        ( "an argument that never completes ends the statement"
        , accepted (body "guard (left > 0) else { int q = Twice(if (other) { return 1; } else { return 2; }); } return 5;")
        )
    ,
        ( "a match whose only leaving arm is guarded completes"
        , rejectedWith "TAT0061" (body "guard (left > 0) else { match (right) { _ if flag -> { return 1; } } } return 5;")
        )
    ,
        ( "a match with a guarded arm and a catch-all that both leave does not complete"
        , accepted (body "guard (left > 0) else { match (right) { 1 if flag -> { return 1; }, _ -> { return 2; } } } return 5;")
        )
    ,
        ( "an if without an else whose block leaves completes"
        , rejectedWith "TAT0061" (body "guard (left > 0) else { if (flag) { return 1; } } return 5;")
        )
    ,
        ( "a loop with a condition completes even when its body leaves"
        , rejectedWith "TAT0061" (body "guard (left > 0) else { while (flag) { return 1; } } return 5;")
        )
    ,
        ( "a break of an inner loop expression does not leave the endless loop around it"
        , accepted (body "guard (left > 0) else { while (true) { int q = while (true) { break 1; }; } } return 5;")
        )
    ,
        ( "a break in a value block of an inner loop does not leave the endless loop around it"
        , accepted (body "guard (left > 0) else { while (true) { while (flag) { int q = if (other) { break; } else { 1 }; } } } return 5;")
        )
    ,
        ( "a break in a match arm leaves the endless loop it stands in"
        , rejectedWith "TAT0061" (body "guard (left > 0) else { while (true) { match (right) { 1 -> { break; }, _ -> { } } } } return 5;")
        )
    , -- The statements kept and dropped around an operand that never completes.
        ( "the operands before one that never completes keep their effects and the ones after it are dropped"
        , case loweredBody (body "int t = 0; int r = Twice(t += 3) + (if (flag) { return t; } else { return 2; }) + Twice(9); return r;") of
            Just [CoreBind _, CoreAssign _ _, CoreEvaluate (CoreApply _ _ _), CoreIf _ [CoreReturn _] [CoreReturn _]] -> True
            _ -> False
        )
    ,
        ( "a right operand of && that never completes lowers to a conditional without a slot"
        , case loweredBody (body "bool b = flag && (if (other) { return 1; } else { return 2; }); return b ? 3 : 4;") of
            Just (CoreIf _ [CoreIf _ [CoreReturn _] [CoreReturn _]] [] : rest) -> not (any bindsResultSlot rest)
            _ -> False
        )
    ,
        ( "a guard block may leave through an initializer that never completes"
        , accepted (body "guard (left > 0) else { int q = if (flag) { return 1; } else { return 2; }; } return 5;")
        )
    , -- Nothing is stored for a value that does not exist: no slot, no
      -- binding, and none of the statements that are never reached.
        ( "an initializer that never completes lowers to its branches alone"
        , case loweredBody (body "int r = if (flag) { return 1; } else { return 2; }; return r;") of
            Just [CoreIf _ [CoreReturn _] [CoreReturn _]] -> True
            _ -> False
        )
    ,
        ( "a returned expression that never completes lowers to its branches alone"
        , case loweredBody (body "return Twice(if (flag) { return 1; } else { return 2; });") of
            Just [CoreIf _ [CoreReturn _] [CoreReturn _]] -> True
            _ -> False
        )
    ,
        ( "a match that never completes lowers without a result slot"
        , case loweredBody (body "int r = match (left) { 1 -> { return 1; }, _ -> { return 2; } }; return r;") of
            Just statements -> not (any bindsResultSlot statements)
            Nothing -> False
        )
    ,
        ( "a value block that can complete must end with its value"
        , rejectedWith "TAT0046" (body "int r = if (flag) { if (other) { return 1; } } else { 3 }; return r;")
        )
    ,
        ( "an arm that leaves does not make a match complete"
        , rejectedWith "TAT0052" (body "int r = match (left) { 1 -> { return 1; }, 2 -> 5 }; return r;")
        )
    ,
        ( "a value block may break out of the loop around its expression"
        , accepted (body "while (true) { int r = if (flag) { break; } else { 2 }; } return 0;")
        )
    ,
        ( "a value block may continue the loop around its expression"
        , accepted (body "while (flag) { int r = match (left) { 1 -> { continue; }, _ -> 2 }; } return 0;")
        )
    , ("a break in a value block needs a loop", rejectedWith "TAT0025" (body "int r = if (flag) { break; } else { 2 }; return r;"))
    , ("a continue in a value block needs a loop", rejectedWith "TAT0027" (body "int r = if (flag) { continue; } else { 2 }; return r;"))
    ,
        ( "a break in a value block does not leave a loop from inside a closure"
        , not (accepted (body "while (flag) { auto f = \\() -> { int r = if (other) { break; } else { 2 }; return r; }; } return 0;"))
        )
    ,
        ( "a break in the condition of a loop leaves that loop"
        , accepted (body "int n = 0; while (if (n > left) { break; } else { true }) { n += 1; } return n;")
        )
    , ("a break in the condition of a loop needs no loop around it", accepted (body "while (if (flag) { break; } else { true }) { } return 0;"))
    ,
        ( "a continue in the update of a loop is accepted"
        , accepted (body "int t = 0; for (int i = 0; i < 3; i += if (t > 9) { t = 0; continue; } else { 1 }) { t += 5; } return t;")
        )
    ,
        ( "a value block may carry a value out of the loop expression around it"
        , accepted (body "int r = while (true) { int q = if (flag) { break 1; } else { 2 }; break q; }; return r;")
        )
    ,
        ( "a value block may return from a loop expression"
        , accepted (body "int r = while (true) { int q = if (flag) { return 1; } else { 2 }; break q; }; return r;")
        )
    , -- Real misuse of the same forms.
        ( "a break that leaves a statement loop from a value block carries no value"
        , rejectedWith "TAT0026" (body "while (flag) { int q = if (other) { break 1; } else { 2 }; } return 0;")
        )
    ,
        ( "a break that leaves a loop expression from a value block must carry a value"
        , rejectedWith "TAT0040" (body "int r = while (true) { int q = if (flag) { break; } else { 2 }; break q; }; return r;")
        )
    ,
        ( "the values carried out of value blocks must have the type of the other break values"
        , rejectedWith "TAT0043" (body "long wide = 3; int r = while (true) { int q = if (flag) { break wide; } else { 2 }; break q; }; return r;")
        )
    ,
        ( "a break in the condition of a statement loop carries no value"
        , rejectedWith "TAT0026" (body "while (if (flag) { break 1; } else { true }) { } return 0;")
        )
    ,
        ( "a return in a value block of a loop expression carries the return type of the method"
        , rejectedWith "TAT0005" (body "int r = while (true) { int q = if (flag) { return true; } else { 2 }; break q; }; return r;")
        )
    ,
        ( "a break in a value block inside a closure does not reach a loop expression around the closure"
        , not (accepted (body "int r = while (true) { auto f = \\() -> { int q = if (flag) { break 1; } else { 2 }; return q; }; break f(); }; return r;"))
        )
    , -- The condition of a loop expression is the constant true, so a break
      -- cannot stand in it.
        ( "a loop expression whose condition is not the constant true is still rejected"
        , rejectedWith "TAT0041" (body "int t = 0; int r = while (if (t > left) { break t; } else { true }) { t += 1; }; return r;")
        )
    , -- Return types are inferred through expressions, and not across the
      -- edge of a nested callable.
        ( "a callable infers its result from a return in a value block"
        , accepted (body "auto f = \\(int v) -> { int q = if (v > 0) { return 1; } else { 2 }; return q; }; return f(left);")
        )
    ,
        ( "the returns of a callable with an inferred result must agree, also through a value block"
        , rejectedWith "TAT0062" (body "auto f = \\(int v) -> { int q = if (v > 0) { return true; } else { 2 }; return q; }; return 0;")
        )
    ,
        ( "the returns of a callable do not count for the method that creates it"
        , accepted (body "auto g = \\(int w) -> { bool b = if (w > 0) { return true; } else { false }; return b; }; return g(left) ? 1 : 2;")
        )
    ,
        ( "the returns of a nested callable do not count for the callable around it"
        , "TAT0062"
            `notElem` codesOf
                (body "auto f = \\(int v) -> { auto g = \\(int w) -> { return w > 0; }; int q = if (v > 0) { return 1; } else { 2 }; return q; }; return f(left);")
        )
    ,
        ( "a method with an inferred return type infers it from a return in a value block"
        , accepted
            ( unlines
                [ "class Program {"
                , "    public static auto Pick(_ int v) { int q = if (v > 0) { return 1; } else { 2 }; return q; }"
                , "}"
                ]
            )
        )
    , -- Callables are compiled and verified, through Core and CorePrep, but
      -- not run: neither the reference evaluator nor the JIT of the native
      -- smoke program executes closures.
        ( "a callable that returns from a loop expression is accepted"
        , accepted (body "auto f = \\(int v) -> { int q = while (true) { if (v > 3) { return 7; } break 2; }; return q + v; }; return f(left);")
        )
    ,
        ( "a callable every path of which returns from a value block is accepted"
        , accepted (body "auto f = \\(int v) -> { int q = if (v > 0) { return v * 2; } else { return 0 - v; }; return q; }; return f(left);")
        )
    ,
        ( "a break in a value block does not leave a loop from inside a callable in that loop"
        , rejectedWith "TAT0025" (body "while (flag) { auto f = \\(int v) -> { int q = if (v > 0) { break; } else { 2 }; return q; }; } return 0;")
        )
    ,
        ( "a continue in a value block does not reach a loop from inside a callable in that loop"
        , rejectedWith "TAT0027" (body "while (flag) { auto f = \\(int v) -> { int q = if (v > 0) { continue; } else { 2 }; return q; }; } return 0;")
        )
    ,
        ( "a continue in the condition of a loop is accepted"
        , accepted (body "int n = 0; while (if ((n += 1) < left) { continue; } else { n < right }) { } return n;")
        )
    ,
        ( "a break in the update of a loop is accepted"
        , accepted (body "for (int i = 0; i < 3; i += if (flag) { break; } else { 1 }) { } return 0;")
        )
    ,
        ( "a break in the update of a loop statement carries no value"
        , rejectedWith "TAT0026" (body "for (int i = 0; i < 3; i += if (flag) { break 1; } else { 1 }) { } return 0;")
        )
    ,
        ( "a break in the update of a loop expression carries a value"
        , rejectedWith "TAT0040" (body "int r = for (int i = 0; ; i += if (flag) { break; } else { 1 }) { break 2; }; return r;")
        )
    ,
        ( "a continue in the condition of a loop needs that loop and no other"
        , rejectedWith "TAT0027" (body "int q = if (flag) { continue; } else { 2 }; return q;")
        )
    ,
        ( "a loop inside a value block may still be left"
        , accepted (body "int r = if (flag) { int n = 0; while (n < left) { n += 1; if (n > 3) { break; } } n } else { 2 }; return r;")
        )
    , ("a guard that returns is accepted", accepted (body "guard (left > 0) else { return 0; } return left;"))
    , ("a guard condition must be bool or numeric", rejectedWith "TAT0060" (body "guard (\"s\") else { return 0; } return 1;"))
    ,
        ( "the else block of a guard must leave"
        , rejectedWith "TAT0061" (body "guard (flag) else { int unused = Twice(left); } return 0;")
        )
    , ("an empty guard block does not leave", rejectedWith "TAT0061" (body "guard (flag) else { } return 0;"))
    ,
        ( "a guard block that leaves on both branches is accepted"
        , accepted (body "guard (flag) else { if (other) { return 1; } else { return 2; } } return 0;")
        )
    ,
        ( "a guard block that leaves on one branch only is rejected"
        , rejectedWith "TAT0061" (body "guard (flag) else { if (other) { return 1; } } return 0;")
        )
    ,
        ( "a guard may leave a loop"
        , accepted (body "int n = 0; while (true) { guard (n < left) else { break; } n += 1; } return n;")
        )
    , ("a guard cannot break outside a loop", rejectedWith "TAT0025" (body "guard (flag) else { break; } return 0;"))
    , ("a guard block may end with a nested block that leaves", accepted (body "guard (flag) else { { return 1; } } return 0;"))
    , -- The rule is about control flow, not about the last statement.
      ("a guard block may leave before its last statement", accepted (body "int n = left; guard (flag) else { return 1; n += 1; } return n;"))
    , ("a guard block that never ends is accepted", accepted (body "guard (flag) else { while (true) { } } return 0;"))
    , ("a guard block with an endless for loop is accepted", accepted (body "guard (flag) else { for (int i = 0; ; i += 1) { } } return 0;"))
    ,
        ( "a guard block whose loop can be left is rejected"
        , rejectedWith "TAT0061" (body "guard (flag) else { while (true) { if (other) { break; } } } return 0;")
        )
    ,
        ( "a guard block whose loop is left from a value block is rejected"
        , rejectedWith "TAT0061" (body "guard (flag) else { while (true) { int q = if (other) { break; } else { 1 }; } } return 0;")
        )
    ,
        ( "a break of an inner loop does not leave the outer endless loop"
        , accepted (body "guard (flag) else { while (true) { while (other) { break; } } } return 0;")
        )
    ,
        ( "a guard block whose loop has a condition is rejected"
        , rejectedWith "TAT0061" (body "guard (flag) else { while (other) { } } return 0;")
        )
    ,
        ( "a guard block may end with a match all of whose arms leave"
        , accepted (body "guard (flag) else { match (other) { true -> { return 1; }, false -> { return 2; } } } return 0;")
        )
    ,
        ( "a guard block that ends with a match that may select no arm is rejected"
        , rejectedWith "TAT0061" (body "guard (flag) else { match (left) { 1 -> { return 1; } } } return 0;")
        )
    ,
        ( "a guard block that ends with a match one arm of which completes is rejected"
        , rejectedWith "TAT0061" (body "guard (flag) else { match (left) { 1 -> { return 1; }, _ -> { } } } return 0;")
        )
    , ("a guard may continue a loop", accepted (body "int n = 0; while (n < left) { n += 1; guard (n > 1) else { continue; } } return n;"))
    , ("a guard cannot continue outside a loop", rejectedWith "TAT0027" (body "guard (flag) else { continue; } return 0;"))
    , ("a binding in a guard condition is recognized and not implemented", parseFailsWith "TAP0035" (body "guard (auto n = left) else { return 0; } return 1;"))
    , ("a nested block sees the names declared before it", accepted (body "int a = left; { a += 1; } return a;"))
    ,
        ( "a name declared in a nested block ends with the block"
        , not (accepted (body "{ int inner = left; } return inner;"))
        )
    ,
        ( "sibling blocks may declare the same name"
        , accepted (body "int total = 0; { int part = left; total += part; } { int part = right; total += part; } return total;")
        )
    ,
        ( "a nested block cannot redeclare a name that is in scope"
        , rejectedWith "TAR0003" (body "int a = left; { int a = right; } return a;")
        )
    ,
        ( "a return in a nested block is checked against the function type"
        , rejectedWith "TAT0005" (body "{ return flag; } return 0;")
        )
    , ("a break in a nested block needs a loop", rejectedWith "TAT0025" (body "{ break; } return 0;"))
    ,
        ( "a break value in a nested block supplies the loop value"
        , accepted (body "int r = while (true) { { break left; } }; return r;")
        )
    ]

-- ---------------------------------------------------------------- lowering

loweringTests :: [(String, Bool)]
loweringTests =
    [ ("a match expression lowers to a subject, a result slot and nested tests", matchExpressionLowers)
    , ("a statement match lowers without a result slot", matchStatementLowers)
    , ("a catch-all arm ends the chain without a test", catchAllEndsChain)
    , ("patterns for several subjects are tested together", severalSubjectsLower)
    , ("a guard after a literal is the last operand of the arm's test", guardedLiteralLowers)
    , ("a guard that stores is decided in its own slot", storingGuardLowers)
    , ("a guard on a catch-all is the test itself", guardedCatchAllLowers)
    , ("a pattern binding is bound to the subject before its guard", bindingLowers)
    , ("an if expression over pure blocks is one lazy conditional", pureIfExpressionLowers)
    , ("an if expression whose block has statements selects into a slot", ifExpressionWithStatementsLowers)
    , ("a guard runs its block when the condition is false", guardLowers)
    , ("the statements of a nested block join the enclosing sequence", nestedBlockLowers)
    , ("a match of any width is one chain of conditionals", all (isOneChain . wideMatch) [2, 17, 40, 200])
    , ("a chain of arms is as deep as one arm", all ((== 1) . nestingOf . wideMatch) [2, 17, 40, 200])
    , ("the names of all arms are bound before the chain", bindingsPrecedeChain)
    ]

-- | A match expression with the given number of literal arms and a catch-all.
wideMatch :: Int -> String
wideMatch count =
    body
        ( "return match (left) { "
            ++ concat [show index ++ " -> " ++ show (index * 3 + 1) ++ ", " | index <- [0 .. count - 2]]
            ++ "_ -> 0 };"
        )

-- | Whether the body is a subject, a result slot, one chain of conditionals and a return.
isOneChain :: String -> Bool
isOneChain text = case loweredBody text of
    Just [CoreBind _, CoreBind _, chain@CoreIf {}, CoreReturn _] -> linksOnly chain
    _ -> False
    where
        -- Every false branch is the next link until the body of the catch-all.
        linksOnly statement = case statement of
            CoreIf _ [CoreAssign _ _] [next@CoreIf {}] -> linksOnly next
            CoreIf _ [CoreAssign _ _] [CoreAssign _ _] -> True
            _ -> False

{- | The deepest nesting of conditional statements in the lowered body, where
the links of a chain share one level: a false branch that is exactly one
conditional continues the chain, as it does in every stage after Core.
-}
nestingOf :: String -> Int
nestingOf text = maybe 0 depth (loweredBody text)
    where
        depth :: [CoreStatement] -> Int
        depth statements = maximum (0 : map statementDepth statements)
        statementDepth statement = case statement of
            CoreIf _ whenTrue [next@CoreIf {}] -> max (1 + depth whenTrue) (statementDepth next)
            CoreIf _ whenTrue whenFalse -> 1 + max (depth whenTrue) (depth whenFalse)
            _ -> 0

bindingsPrecedeChain :: Bool
bindingsPrecedeChain = case loweredBody (body "return match (left) { int low if low < 3 -> low, int high if high > 9 -> high, _ -> 0 };") of
    Just
        [ CoreBind (CoreBinding subject _ False _)
            , CoreBind (CoreBinding first _ True (CoreVariable firstSource _))
            , CoreBind (CoreBinding second _ True (CoreVariable secondSource _))
            , CoreBind (CoreBinding slot _ True _)
            , CoreIf _ [CoreAssign _ _] [CoreIf _ [CoreAssign _ _] [CoreAssign _ _]]
            , CoreReturn _
            ] ->
        map spelling [first, second] == ["low", "high"]
            && all (== subject) [firstSource, secondSource]
            && generated "$matched" slot
    _ -> False

-- | Whether a statement binds the result slot of a match or of a choice.
bindsResultSlot :: CoreStatement -> Bool
bindsResultSlot statement = case statement of
    CoreBind binding -> any (`isPrefixOf` identifierText (resolvedSpelling (coreBindingName binding))) ["$matched", "$selected"]
    _ -> False

loweredBody :: String -> Maybe [CoreStatement]
loweredBody text = case compileSource text of
    Right artifacts -> functionBody (artifactCore artifacts)
    Left _ -> Nothing

functionBody :: CoreModule -> Maybe [CoreStatement]
functionBody moduleValue =
    case [ coreFunctionBody function
         | function <- coreModuleFunctions moduleValue
         , spelling (coreFunctionName function) == "Evaluate"
         ] of
        statements : _ -> Just statements
        [] -> Nothing

spelling :: ResolvedName -> String
spelling = identifierText . resolvedSpelling

generated :: String -> ResolvedName -> Bool
generated prefix name = prefix `isPrefixOf` spelling name

-- | Whether an expression compares the given local with the given integer.
comparesWith :: ResolvedName -> Integer -> CoreExpression -> Bool
comparesWith subject value expression = case expression of
    CorePrimitive CoreEqual [CoreVariable name _, CoreLiteral (CoreInteger literal) _] _ -> name == subject && literal == value
    _ -> False

matchExpressionLowers :: Bool
matchExpressionLowers = case loweredBody (body "return match (left) { 1 -> 10, 2 -> 20, _ -> 30 };") of
    Just
        [ CoreBind (CoreBinding subject _ False (CoreVariable source _))
            , CoreBind (CoreBinding slot _ True _)
            , CoreIf first [CoreAssign firstStore _] [CoreIf second [CoreAssign secondStore _] [CoreAssign lastStore _]]
            , CoreReturn (CoreVariable result _)
            ] ->
        generated "$subject" subject
            && spelling source == "left"
            && generated "$matched" slot
            && comparesWith subject 1 first
            && comparesWith subject 2 second
            && all (== slot) [firstStore, secondStore, lastStore, result]
    _ -> False

matchStatementLowers :: Bool
matchStatementLowers = case loweredBody (body "match (left) { 1 -> { return 1; }, 2 -> { return 2; } } return 0;") of
    Just [CoreBind (CoreBinding subject _ False _), CoreIf first [CoreReturn _] [CoreIf second [CoreReturn _] []], CoreReturn _] ->
        generated "$subject" subject && comparesWith subject 1 first && comparesWith subject 2 second
    _ -> False

catchAllEndsChain :: Bool
-- The match never completes, so the statement after it is not lowered.
catchAllEndsChain = case loweredBody (body "match (left) { _ -> { return 7; } } return 0;") of
    Just [CoreBind (CoreBinding subject _ False _), CoreReturn _] -> generated "$subject" subject
    _ -> False

severalSubjectsLower :: Bool
severalSubjectsLower = case loweredBody (body "match (left), (right) { (1), (2) -> { return 1; }, (_), (3) -> { return 2; } } return 0;") of
    Just
        [ CoreBind (CoreBinding first _ False _)
            , CoreBind (CoreBinding second _ False _)
            , CoreIf (CorePrimitive CoreLogicalAnd [firstTest, secondTest] _) [CoreReturn _] [CoreIf laterTest [CoreReturn _] []]
            , CoreReturn _
            ] ->
        comparesWith first 1 firstTest && comparesWith second 2 secondTest && comparesWith second 3 laterTest
    _ -> False

-- The guard is the last operand of the arm's test, behind the short-circuit
-- conjunction, so it is evaluated only when the comparison holds.
guardedLiteralLowers :: Bool
guardedLiteralLowers = case loweredBody (body "match (left) { 1 if flag -> { return 1; } } return 0;") of
    Just
        [ CoreBind (CoreBinding subject _ False _)
            , CoreIf (CorePrimitive CoreLogicalAnd [test, CoreVariable guard _] _) [CoreReturn _] []
            , CoreReturn _
            ] ->
        comparesWith subject 1 test && spelling guard == "flag"
    _ -> False

-- A guard that stores into a local runs as statements, and only when the
-- comparison holds: the decision is taken in a slot of its own.
storingGuardLowers :: Bool
storingGuardLowers = case loweredBody (body "int hits = 0; match (left) { 1 if (hits += 1) > 0 -> { return 1; } } return hits;") of
    Just
        [ _
            , CoreBind (CoreBinding subject _ False _)
            , CoreBind (CoreBinding decision _ True (CoreLiteral (CoreBoolean False) _))
            , CoreIf test [CoreAssign stored _, CoreIf _ [CoreAssign decided _] []] []
            , CoreIf (CoreVariable taken _) [CoreReturn _] []
            , CoreReturn _
            ] ->
        generated "$accepted" decision
            && comparesWith subject 1 test
            && spelling stored == "hits"
            && decided == decision
            && taken == decision
    _ -> False

guardedCatchAllLowers :: Bool
guardedCatchAllLowers = case loweredBody (body "match (left) { _ if flag -> { return 1; } } return 0;") of
    Just [CoreBind _, CoreIf (CoreVariable guard _) [CoreReturn _] [], CoreReturn _] -> spelling guard == "flag"
    _ -> False

bindingLowers :: Bool
bindingLowers = case loweredBody (body "match (left) { int value if value > 3 -> { return value; } } return 0;") of
    Just
        [ CoreBind (CoreBinding subject _ False _)
            , CoreBind (CoreBinding bound _ True (CoreVariable source _))
            , CoreIf (CorePrimitive CoreGreaterThan [CoreVariable tested _, _] _) [CoreReturn (CoreVariable returned _)] []
            , CoreReturn _
            ] ->
        spelling bound == "value" && source == subject && tested == bound && returned == bound
    _ -> False

pureIfExpressionLowers :: Bool
pureIfExpressionLowers = case loweredBody (body "return if (flag) { left } else { right };") of
    Just [CoreReturn (CoreConditional (CoreVariable test _) (CoreVariable first _) (CoreVariable second _) _)] ->
        map spelling [test, first, second] == ["flag", "left", "right"]
    _ -> False

ifExpressionWithStatementsLowers :: Bool
ifExpressionWithStatementsLowers = case loweredBody (body "return if (flag) { int doubled = left * 2; doubled } else { right };") of
    Just
        [ CoreBind (CoreBinding slot _ True _)
            , CoreIf _ [CoreBind (CoreBinding local _ _ _), CoreAssign first (CoreVariable stored _)] [CoreAssign second _]
            , CoreReturn (CoreVariable result _)
            ] ->
        generated "$selected" slot && spelling local == "doubled" && stored == local && all (== slot) [first, second, result]
    _ -> False

guardLowers :: Bool
guardLowers = case loweredBody (body "guard (flag) else { return 0; } return 1;") of
    Just [CoreIf (CoreVariable condition _) [] [CoreReturn _], CoreReturn _] -> spelling condition == "flag"
    _ -> False

nestedBlockLowers :: Bool
nestedBlockLowers = case loweredBody (body "int a = left; { int b = a + 1; a = b; } return a;") of
    Just [CoreBind (CoreBinding outer _ _ _), CoreBind (CoreBinding inner _ _ _), CoreAssign stored _, CoreReturn _] ->
        spelling outer == "a" && spelling inner == "b" && stored == outer
    _ -> False

-- ------------------------------------------------------------- evaluation

evaluationTests :: [(String, Bool)]
evaluationTests =
    concat
        [ [ ("unoptimized Core computes " ++ label, runs artifactCore statements arguments expected)
          , ("optimized Core computes " ++ label, runs artifactOptimizedCore statements arguments expected)
          ]
        | (statements, runsOfCase) <- evaluationCases
        , (arguments, expected) <- runsOfCase
        , let label = show expected ++ " for " ++ show arguments ++ ": " ++ statements
        ]

runs :: (FrontendArtifacts -> CoreModule) -> String -> (Bool, Bool, Integer, Integer) -> Integer -> Bool
runs select statements (flag, other, left, right) expected = case compileSource (body statements) of
    Right artifacts ->
        runFunction
            (select artifacts)
            "Evaluate"
            [BooleanValue flag, BooleanValue other, IntegerValue left, IntegerValue right]
            == Just (IntegerValue expected)
    Left _ -> False

-- ---------------------------------------------------------------- pipeline

pipelineTests :: [(String, Bool)]
pipelineTests =
    [ ("every lowered case verifies as Core", all (verifies artifactCore) (map fst evaluationCases))
    , ("every optimized case verifies as Core", all (verifies artifactOptimizedCore) (map fst evaluationCases))
    , ("every case verifies as CorePrep", all corePrepVerifies (map fst evaluationCases))
    , ("Core wire round-trips every lowered case", all wireRoundTrips (map fst evaluationCases))
    , ("a template member keeps its match when instantiated", templateInstantiates)
    , ("a call inside a match arm is reachable from the template member", templateReachesArmCalls)
    , ("a closure body may contain a match and a guard", accepted closureSource)
    ]

verifies :: (FrontendArtifacts -> CoreModule) -> String -> Bool
verifies select statements = case compileSource (body statements) of
    Right artifacts -> verifyCore (select artifacts) == Right (select artifacts)
    Left _ -> False

corePrepVerifies :: String -> Bool
corePrepVerifies statements = case compileSource (body statements) of
    Right artifacts -> verifyCorePrep (artifactCorePrep artifacts) == Right (artifactCorePrep artifacts)
    Left _ -> False

wireRoundTrips :: String -> Bool
wireRoundTrips statements = case compileSource (body statements) of
    Right artifacts ->
        let core = artifactCore artifacts
         in (encodeCore defaultCoreWireLimits core >>= decodeCore defaultCoreWireLimits) == Right core
    Left _ -> False

templateSource :: String
templateSource =
    unwords
        [ "template<typename T> class Box {"
        , "int Entry(_ int seed) {"
        , "guard (seed > 0) else { return Fallback(); }"
        , "return match (seed) { 1 -> Step(seed), int other if other > 9 -> Scale(other), _ -> if (seed > 5) { Step(seed) } else { 0 } };"
        , "}"
        , "int Step(_ int value) { return value + 4; }"
        , "int Scale(_ int value) { return value * 2; }"
        , "int Fallback() { return 0; }"
        , "int Unused() { return 9; }"
        , "}"
        ]

templatePlan :: Maybe TemplateSpecializationPlan
templatePlan = case analyzeSemantics (CompilerInput "branching-template.tala" templateSource) of
    Right artifacts ->
        either
            (const Nothing)
            Just
            ( planTemplateSpecializations
                defaultTemplateSpecializationLimits
                (semanticTypedAST artifacts)
                [ TemplateSpecializationDemand
                    (TemplateApplication (QualifiedName [Identifier "Box"]) [TypeTemplateArgument stringType])
                    (TemplateMemberDemand [Identifier "Entry"])
                    "branching-template"
                ]
            )
    Left _ -> Nothing

specializedMembers :: [Declaration ResolvedName Type]
specializedMembers = case templatePlan of
    Just plan ->
        concat
            [ members
            | TypeDeclaration {typeMembers = members} <-
                map templateSpecializationDeclaration (plannedTemplateSpecializations plan)
            ]
    Nothing -> []

specializedNames :: [String]
specializedNames = map (identifierText . resolvedSpelling . declarationName) specializedMembers

templateInstantiates :: Bool
templateInstantiates =
    all (`isInfixOf` show specializedMembers) ["MatchExpression", "GuardStatement", "BlockExpression"]

templateReachesArmCalls :: Bool
templateReachesArmCalls =
    all (`elem` specializedNames) ["Entry", "Step", "Scale", "Fallback"] && "Unused" `notElem` specializedNames

closureSource :: String
closureSource =
    unlines
        [ "class Program {"
        , "    public static int Run(_ int seed) {"
        , "        auto pick = \\(int value) -> { guard (value > 0) else { return 0; } return match (value) { 1 -> 10, int other -> other * 2 }; };"
        , "        return pick(seed);"
        , "    }"
        , "}"
        ]
