-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Where the diagnostics of @match@, @if@ expressions, @guard@ and nested
blocks point, and that damaged spellings of those forms are always answered.

An editor underlines the range a diagnostic carries, so the tests pin the
start of every range: the arm that can never be selected and not the whole
match, the pattern that binds a duplicate name and not its arm. The
robustness tests feed the frontend every prefix of a program that uses the
new forms, and the same program with each token removed in turn. The parser
has loops of its own for subjects, arms and patterns; a damaged input must
end each of them with a diagnostic or a tree, never with a hang or an
exception. The last group pins how the forms behave in a template body and
on an @else if@ chain far longer than any test above the frontend used
before.
-}
module BranchingDiagnosticTests (branchingDiagnosticTests) where

import CoreInterpreter
import Data.List (intercalate)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser

branchingDiagnosticTests :: [(String, Bool)]
branchingDiagnosticTests = positionTests ++ robustnessTests ++ templateTests ++ chainTests

-- ------------------------------------------------------------- positions

{- | A method whose body starts on line 3, column 1, so the columns in the
expectations below are the columns of the statement text itself.
-}
method :: [String] -> String
method statements =
    unlines
        ( [ "class Program {"
          , "public static int Evaluate(_ bool flag, _ int left, _ int right) {"
          ]
            ++ statements
            ++ ["}", "}"]
        )

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "branching-diagnostic.tala" text)

-- | The one-based line and column at which each diagnostic with the code starts.
startsOf :: String -> String -> [(Int, Int)]
startsOf code text = case compileSource text of
    Right _ -> []
    Left problems ->
        [ (sourceLine start, sourceColumn start)
        | problem <- problems
        , diagnosticCode problem == code
        , Just spanValue <- [diagnosticSpan problem]
        , let start = sourceStart spanValue
        ]

-- | Whether the code is reported exactly once, at the given position.
reportedAt :: String -> (Int, Int) -> [String] -> Bool
reportedAt code position statements = startsOf code (method statements) == [position]

positionTests :: [(String, Bool)]
positionTests =
    [
        ( "an incomplete match expression is reported at the match"
        , reportedAt "TAT0052" (3, 8) ["return match (left) {", "1 -> 10", "};"]
        )
    ,
        ( "an arm that can never be selected is reported at that arm"
        , reportedAt "TAT0053" (5, 1) ["match (left) {", "1 -> { },", "1 -> { },", "_ -> { }", "}", "return 0;"]
        )
    ,
        ( "every arm that can never be selected is reported"
        , startsOf "TAT0053" (method ["match (left) {", "_ -> { },", "1 -> { },", "2 -> { }", "}", "return 0;"])
            == [(5, 1), (6, 1)]
        )
    ,
        ( "a wrong number of patterns is reported at the arm"
        , reportedAt "TAT0048" (4, 1) ["match (left), (right) {", "1 -> { },", "(_), (_) -> { }", "}", "return 0;"]
        )
    ,
        ( "a guard of the wrong type is reported at the guard expression"
        , reportedAt "TAT0049" (4, 6) ["match (left) {", "1 if \"text\" -> { }", "}", "return 0;"]
        )
    ,
        ( "arms of different types are reported at the match"
        , reportedAt "TAT0050" (4, 10) ["long wide = 3;", "long r = match (left) {", "1 -> wide,", "_ -> left", "};", "return 0;"]
        )
    ,
        ( "a literal pattern of the wrong type is reported at the pattern"
        , reportedAt "TAT0054" (4, 1) ["match (left) {", "\"text\" -> { }", "}", "return 0;"]
        )
    , ("a null pattern is reported at the pattern", reportedAt "TAT0055" (4, 1) ["match (left) {", "null -> { }", "}", "return 0;"])
    , ("an enum case pattern is reported at the pattern", reportedAt "TAT0056" (4, 1) ["match (left) {", ".Ready -> { }", "}", "return 0;"])
    ,
        ( "a type pattern of another type is reported at the pattern"
        , reportedAt "TAT0057" (4, 6) ["match (left), (right) {", "(_), (long other) -> { }", "}", "return 0;"]
        )
    ,
        ( "a subject of an unsupported type is reported at the subject"
        , reportedAt "TAT0058" (3, 16) ["match (left), (\\(int v) -> v) {", "(_), (_) -> { }", "}", "return 0;"]
        )
    ,
        ( "a duplicate pattern binding is reported at the second pattern"
        , reportedAt "TAR0008" (4, 14) ["match (left), (right) {", "(int value), (int value) -> { }", "}", "return 0;"]
        )
    ,
        ( "a value block without a value is reported at the block"
        , reportedAt "TAT0046" (3, 19) ["int r = if (flag) { } else { 2 };", "return r;"]
        )
    ,
        ( "a return of the wrong type in a value block is reported at the return"
        , reportedAt "TAT0005" (3, 21) ["int r = if (flag) { return true; } else { 3 };", "return r;"]
        )
    ,
        ( "a break without a loop in a value block is reported at the break"
        , reportedAt "TAT0025" (3, 21) ["int r = if (flag) { break; } else { 2 };", "return r;"]
        )
    ,
        ( "a return of the wrong type in a value block of a loop expression is reported at the return"
        , reportedAt
            "TAT0005"
            (4, 21)
            ["int r = while (true) {", "int q = if (flag) { return true; } else { 2 };", "break q;", "};", "return r;"]
        )
    ,
        ( "a break without a value out of a loop expression is reported at the break"
        , reportedAt
            "TAT0040"
            (4, 21)
            ["int r = while (true) {", "int q = if (flag) { break; } else { 2 };", "break q;", "};", "return r;"]
        )
    ,
        ( "a continue inside a callable in a loop is reported at the continue"
        , reportedAt
            "TAT0027"
            (4, 37)
            ["while (flag) {", "auto f = \\(int v) -> { if (v > 0) { continue; } return v; };", "}", "return 0;"]
        )
    ,
        ( "a value-carrying break in the update of a loop statement is reported at the break"
        , reportedAt "TAT0026" (3, 41) ["for (int i = 0; i < 3; i += if (flag) { break 1; } else { 1 }) { }", "return 0;"]
        )
    ,
        ( "a guard block that does not leave is reported at the guard"
        , reportedAt "TAT0061" (3, 1) ["guard (flag) else {", "int unused = left;", "}", "return 0;"]
        )
    ,
        ( "a guard condition of the wrong type is reported at the guard"
        , reportedAt "TAT0060" (3, 1) ["guard (\"text\") else { return 0; }", "return 1;"]
        )
    ,
        ( "a redeclaration in a nested block is reported at the inner binding"
        , reportedAt "TAR0003" (5, 1) ["int a = left;", "{", "int a = right;", "}", "return a;"]
        )
    ]

-- ------------------------------------------------------------ robustness

-- | A program that uses every new form.
specimen :: String
specimen =
    intercalate
        " "
        [ "class Program { public static int Evaluate(_ bool flag, _ int left, _ int right) {"
        , "guard (left >= 0) else { return 0; }"
        , "{ int scoped = left; }"
        , "int kind = match (left), (flag) { (0), (_) -> 10, (1), (true) -> 20,"
        , "(int low), (_) if low < 5 -> { int doubled = low * 2; doubled } (_), (_) -> 30 };"
        , "int total = 0;"
        , "for (int index = 0; index < right; index++) {"
        , "match (index % 3) { 0 -> { continue; }, 1 -> total += 10, _ -> { total += index; } }"
        , "guard (total < 40) else { break; } }"
        , "return if (kind > total) { kind - total } else { total - kind }; } }"
        ]

-- | Lex and parse; the lexer never fails on these inputs' prefixes it accepts.
parseOutcome :: String -> Either [Diagnostic] ParsedAST
parseOutcome text = do
    tokens <- runLexer defaultLexer (LexerInput "branching-robustness.tala" text)
    runParser defaultParser (ParserInput "branching-robustness.tala" tokens)

-- | Whether the frontend answers: a tree, artifacts, or diagnostics.
answered :: String -> Bool
answered text = case parseOutcome text of
    Left problems -> not (null problems)
    Right _ -> case compileSource text of
        Left problems -> not (null problems)
        Right _ -> True

-- | The specimen with the token at the given index removed.
withoutToken :: [String] -> Int -> String
withoutToken tokens index = unwords (take index tokens ++ drop (index + 1) tokens)

-- | The specimen with the token at the given index written twice.
withRepeatedToken :: [String] -> Int -> String
withRepeatedToken tokens index = unwords (take (index + 1) tokens ++ drop index tokens)

robustnessTests :: [(String, Bool)]
robustnessTests =
    [ ("the specimen itself compiles", either (const False) (const True) (compileSource specimen))
    , ("every prefix of the specimen is answered", all (answered . (`take` specimen)) [0 .. length specimen])
    ,
        ( "no proper prefix of the specimen is accepted as a complete program with a body"
        , all (not . compiles . (`take` specimen)) [length "class Program { " .. length specimen - 1]
        )
    , ("the specimen without any one token is answered", all (answered . withoutToken tokens) [0 .. length tokens - 1])
    , ("the specimen with any one token repeated is answered", all (answered . withRepeatedToken tokens) [0 .. length tokens - 1])
    ]
    where
        tokens = words specimen
        compiles text = either (const False) (const True) (compileSource text)

-- ------------------------------------------------------------- templates

templateTests :: [(String, Bool)]
templateTests =
    [
        ( "a template member may match over values of concrete types"
        , accepted
            [ "template<typename T> class Box {"
            , "public static int Kind(_ T value, _ int code) {"
            , "guard (code >= 0) else { return 0; }"
            , "return match (code) { 1 -> 10, int other if other > 5 -> other, _ -> if (code > 2) { 1 } else { 2 } };"
            , "}"
            , "}"
            ]
        )
    , -- A value of a type parameter has no known representation in the open
      -- template body, so it is rejected like a conditional result of that
      -- type, which reports TAT0039.
        ( "a match result of a type parameter is not lowered yet"
        , rejectedWith
            "TAT0051"
            [ "template<typename T> class Box {"
            , "public static T Same(_ T value, _ int code) {"
            , "return match (code) { 1 -> value, _ -> value };"
            , "}"
            , "}"
            ]
        )
    ,
        ( "a match subject of a type parameter is not lowered yet"
        , rejectedWith
            "TAT0058"
            [ "template<typename T> class Box {"
            , "public static int Kind(_ T value) {"
            , "return match (value) { T other -> 1 };"
            , "}"
            , "}"
            ]
        )
    ,
        ( "a conditional result of a type parameter reports the conditional code"
        , rejectedWith
            "TAT0039"
            [ "template<typename T> class Box {"
            , "public static T Pick(_ bool flag, _ T first, _ T second) {"
            , "return flag ? first : second;"
            , "}"
            , "}"
            ]
        )
    ]
    where
        accepted source = either (const False) (const True) (compileSource (unlines source))
        rejectedWith code source = case compileSource (unlines source) of
            Left problems -> any ((== code) . diagnosticCode) problems
            Right _ -> False

-- ----------------------------------------------------------------- chains

{- | An @else if@ chain of the given length: link @index@ returns
@index * 3 + 1@ and the statement after the chain returns 0.
-}
chainProgram :: Int -> String
chainProgram links =
    unlines
        [ "class Program {"
        , "public static int Evaluate(_ int value) {"
        , concat
            [ (if index == 0 then "if" else " else if")
                ++ " (value == "
                ++ show index
                ++ ") { return "
                ++ show (index * 3 + 1)
                ++ "; }"
            | index <- [0 .. links - 1]
            ]
        , "return 0;"
        , "}"
        , "}"
        ]

chainValue :: (FrontendArtifacts -> CoreModule) -> Int -> Integer -> Maybe Integer
chainValue select links subject = case compileSource (chainProgram links) of
    Right artifacts -> case runFunction (select artifacts) "Evaluate" [IntegerValue subject] of
        Just (IntegerValue value) -> Just value
        _ -> Nothing
    Left _ -> Nothing

-- Core nests one level per link; the frontend and its evaluator walk that
-- depth on the growable Haskell stack, so only the answers are pinned here.
-- The native stages after Core have their own tests for the same chain.
chainTests :: [(String, Bool)]
chainTests =
    [ ( "an else-if chain of " ++ show links ++ " links selects subject " ++ show subject ++ " " ++ mode
      , chainValue select links subject == Just (if subject < toInteger links then subject * 3 + 1 else 0)
      )
    | links <- [150, 400]
    , subject <- [0, toInteger links - 1, toInteger links]
    , (mode, select) <- [("unoptimized", artifactCore), ("optimized", artifactOptimizedCore)]
    ]
