-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Tests for evaluation by need.

Tala computes a value when it is first needed and at most once, and
never computes a value that is not needed. The tests observe that through
the only things that tell a computed value from one that was not: a division
by zero, a call that never returns, and the number of steps a program takes.
The reference evaluator of "CoreInterpreter" gives no result for a division
by zero and for a program that exceeds its step budget, so a value computed
without need shows as a missing result.

The effects of a program are not lazy. A store into a variable happens where
it is written, whether or not the value around it is ever read, and a value
means what its variables held where it was bound, however late it is
computed. The tests pin both.

An argument is a value like any other. A method receives it by need: it is
computed when the method first needs it, at most once however often the
method reads it and however many methods it is handed through, and not at
all when no one needs it. The caller and the method share the one
computation when both need the value.

The expected values are written by hand.
-}
module LazyEvaluationTests (lazyEvaluationTests) where

import CoreInterpreter
import Data.List (intercalate, isInfixOf)
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Diagnostic

lazyEvaluationTests :: [(String, Bool)]
lazyEvaluationTests =
    concat
        [ [ ("unoptimized Core computes " ++ label, runs artifactCore statements arguments == Just expected)
          , ("optimized Core computes " ++ label, runs artifactOptimizedCore statements arguments == Just expected)
          ]
        | (statements, runsOfCase) <- evaluationCases
        , (arguments, expected) <- runsOfCase
        , let label = show expected ++ " for " ++ show arguments ++ ": " ++ statements
        ]
        ++ [ ("every lazy program verifies as Core and as CorePrep", all (verifies . fst) evaluationCases)
           , -- A value that is needed and cannot be computed is still a failure.
             ("a needed division by zero has no result", runs artifactCore "int x = left / right; return x;" (1, 0) == Nothing)
           ,
               ( "a needed division by zero has no result on one path"
               , runs artifactCore neededOnOnePath (6, 0) == Just 7 && runs artifactCore neededOnOnePath (6, 3) == Just 2
               )
           , ("a discarded value is evaluated", runs artifactCore "_ = left / right; return 5;" (1, 0) == Nothing)
           , -- A value that is never needed leaves nothing behind in Core.
             ("a value that is never read is not in the lowered Core", not (mentions "CoreDivide" artifactCore "int x = left / right; return 5;"))
           , -- A value that the next statement is certain to need is
             -- computed where it is bound, without a flag.
             ("a value needed at once is computed in place", not (mentions "$known" artifactCore "int x = Half(left); return x + x;"))
           , ("a value needed on one path only keeps its flag", mentions "$known" artifactCore neededOnOnePath)
           , -- A value needed fifty times is computed once: the budget that
             -- suffices for one computation does not suffice for fifty.
             ("a value is computed at most once", runsWithin 2000 neededOften (100, 1) == Just 5000)
           , ("the same work fifty times exceeds that budget", runsWithin 2000 computedOften (100, 1) == Nothing)
           , -- An argument the method reads fifty times is computed once.
             ("an argument is computed at most once", runsWithin 2000 "return Often(right, Step(left));" (100, 1) == Just 5000)
           , -- The caller and the method it calls need the same value:
             -- whoever needs it first computes it for both. The budget that
             -- suffices for one computation does not suffice for two.
             ("a value the caller and the method both need is computed once", runsWithin 800 sharedWithCallee (300, 1) == Just 600)
           , ("the same work in the caller and in the method exceeds that budget", runsWithin 800 computedTwice (300, 1) == Nothing)
           , -- An argument that may fail is handed on as a suspended
             -- computation; one that cannot is passed as the value it is.
             ("an argument that may fail is suspended", mentions "CoreMemoize" artifactCore "return Pick(right, left / right);")
           , ("an argument that cannot fail is passed as a value", not (mentions "CoreMemoize" artifactCore "return Pick(right, left + 1);"))
           , -- The method itself is unchanged: it still takes values, for
             -- every caller that has them.
             ("a method with a parameter by need still takes values", calls "Pick" [1, 5] == Just 5 && calls "Pick" [0, 5] == Just 7)
           , -- Pending, and pinned so that a change shows: a callable
             -- receives its arguments as values, and an argument that a
             -- closure of the method captures is computed when the method
             -- is entered.
             ("an argument of a callable is still computed at the call", runs artifactCore throughCallable (6, 0) == Nothing)
           , ("a captured argument is still computed on entry", runs artifactCore "return Kept(0, left / right);" (1, 0) == Nothing)
           , -- A value that reads another value by need twice does not
             -- carry the computation of that value twice: the Core of a
             -- chain grows with its length, not with a power of it.
             ("a chain of values read twice each grows linearly", coreSize (sharedChain 12) < 3 * coreSize (sharedChain 6))
           ]
    where
        neededOnOnePath = "int x = left / right; if (right > 0) { return x; } return 7;"
        neededOften = "int x = Step(left); int t = 0; for (int i = 0; i < 50; i += 1) { if (right > 0) { t += x; } } return t;"
        computedOften = "int t = 0; for (int i = 0; i < 50; i += 1) { if (right > 0) { t += Step(left); } } return t;"
        sharedWithCallee = "int x = Step(left); int y = Pick(right, x); return right > 0 ? x + y : y;"
        computedTwice = "return Step(left) + Pick(right, Step(left));"
        throughCallable = "auto f = \\(int a, int b) -> a > 0 ? b : 7; return f(right, left / right);"
        calls name arguments = case compileSource (program "return 0;") of
            Right artifacts -> case runFunction (artifactCore artifacts) name (map IntegerValue arguments) of
                Just (IntegerValue value) -> Just value
                _ -> Nothing
            Left _ -> Nothing

-- | A program around the given body of @Evaluate@.
program :: String -> String
program statements =
    unlines
        [ "namespace Test;"
        , "class Program {"
        , "    public static int Never(_ int v) { return Never(v + 1); }"
        , "    public static int Half(_ int v) { return v / 2; }"
        , "    public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) : 0; }"
        , "    public static int Pick(_ int flag, _ int value) { if (flag > 0) { return value; } return 7; }"
        , "    public static int Pass(_ int flag, _ int value) { return Pick(flag, value); }"
        , "    public static int Both(_ int flag, _ int first, _ int second) { if (flag > 0) { return first; } return second; }"
        , "    public static int Kept(_ int flag, _ int value) { auto read = \\(int more) -> value + more; if (flag > 0) { return read(1); } return 3; }"
        , "    public static int Often(_ int flag, _ int value) { int total = 0; for (int i = 0; i < 50; i += 1) { if (flag > 0) { total += value; } } return total; }"
        , "    public static int Down(_ int n, _ int spare) { if (n <= 0) { return 0; } return 1 + Down(n - 1, spare / 0); }"
        , "    public static int Evaluate(_ int left, _ int right) {"
        , "        " ++ statements
        , "    }"
        , "}"
        ]

-- | Bodies of @Evaluate@, the arguments to run them on, and the value each run must return.
evaluationCases :: [(String, [((Integer, Integer), Integer)])]
evaluationCases =
    [ -- A value that is never needed is never computed: not a division by
      -- zero, and not a call that never returns.
      ("int x = left / right; return 5;", [((1, 0), 5)])
    , ("int x = Never(left); return 5;", [((1, 0), 5)])
    , -- A value is computed on the path that needs it and not on the other.
      ("int x = left / right; if (right > 0) { return x; } return 7;", [((6, 0), 7), ((6, 3), 2)])
    , ("int x = left / right; return match (right) { 0 -> 1, _ -> x };", [((6, 0), 1), ((6, 2), 3)])
    , ("int x = left / right; return right > 0 && x > 1 ? 1 : 2;", [((6, 0), 2), ((6, 3), 1), ((1, 3), 2)])
    , ("int x = left / right; int r = if (right > 0) { x + 1 } else { 0 }; return r;", [((6, 0), 0), ((6, 2), 4)])
    , -- A value computed from a value that is not needed is not needed either.
      ("int x = left / right; int y = x + 1; return right > 0 ? y : 9;", [((6, 0), 9), ((6, 3), 3)])
    , ("int x = Never(left); int y = x + 1; int z = y * 2; return right > 0 ? 1 : 2;", [((0, 1), 1), ((0, 0), 2)])
    , -- In a loop, each pass has its own value, computed if that pass needs it.
        ( "int t = 0; for (int i = 0; i <= 3; i += 1) { int x = left / i; if (i > 1) { t += x; } } return t;"
        , [((12, 0), 10)]
        )
    , ("int limit = left / right; int n = 0; while (right > 0 && n < limit) { n += 1; } return n;", [((6, 0), 0), ((6, 2), 3)])
    , -- A value means what its variables held where it was bound.
      ("int a = left; int x = Half(a) + a; a = 100; return x * 1000 + a;", [((8, 0), 12100)])
    ,
        ( "int a = left; int x = Half(a); a = a + 100; if (right > 0) { return x; } return a;"
        , [((8, 1), 4), ((8, 0), 108)]
        )
    , ("int t = 0; for (int i = 1; i <= 3; i += 1) { int x = Half(i * 10); if (i == 2) { t = x; } } return t;", [((0, 0), 10)])
    , -- A store happens where it is written, whether or not the value
      -- around it is ever read.
      ("int n = 0; int x = (n += 1) + left; return n * 10;", [((1, 0), 10)])
    , ("int n = left; int x = n++ + Half(n); return n;", [((4, 0), 5)])
    , -- The body of a callable evaluates by need as the body of a method
      -- does, also when the callable stands inside another.
        ( "auto f = \\(int v, int d) -> { int q = v / d; if (d > 0) { return q; } return 7; }; return f(left, right);"
        , [((6, 0), 7), ((6, 3), 2)]
        )
    , ("auto f = \\(int v) -> { int q = Never(v); return 5; }; return f(left);", [((1, 0), 5)])
    ,
        ( "auto f = \\(int v, int d) -> { auto g = \\(int w) -> { int q = w / d; return d > 0 ? q : 9; }; return g(v); }; return f(left, right);"
        , [((6, 0), 9), ((6, 2), 3)]
        )
    , ("auto f = \\(int v) -> { int a = v; int q = Half(a + 2); a = 100; return q * 1000 + a; }; return f(left);", [((8, 0), 5100)])
    , -- A value that needs another value twice computes it once, also
      -- through a long chain of such values.
      (sharedChain 40, [((6, 0), 7), ((6, 3), 1)])
    , -- The operands of an operator are evaluated whenever it is, so a value
      -- by need that one of them reads twice is computed once, ahead of the
      -- whole expression, however deep in the operands the reads are.
      ("int x = left / right; int y = (x + 1) * (x + 2) - x; if (right > 0) { return y; } return 7;", [((6, 0), 7), ((6, 3), 10)])
    , ("int x = left / right; int y = -(x - -x) + left; if (right > 0) { return y; } return 7;", [((6, 0), 7), ((6, 3), 2)])
    , -- Reads that an operand may skip are still reads of that operand alone.
      ("int x = left / right; int y = 1 + (right > 0 ? x + x : 0) + left; return right > 1 ? y : 9;", [((6, 0), 9), ((6, 1), 9), ((6, 3), 11)])
    , ("int x = left / right; int y = (right > 0 && x + x > 3 ? 1 : 0) + left; return y;", [((6, 0), 6), ((6, 2), 7), ((6, 6), 6)])
    , -- A value by need whose expression is a very long chain of operators
      -- is lowered once for each operator, not once for each pair of them.
      (operatorChain 1500, [((6, 0), 7), ((6, 3), 18002)])
    , ("int x = left / right; int y = right > 0 ? x / 1 + x / 2 : 0; return right > 1 ? y : 9;", [((6, 0), 9), ((6, 1), 9), ((6, 3), 3)])
    , -- A value by need is computed where a loop header or a guard reads it.
        ( "int x = left / right; int t = 0; for (int i = 0; right > 0 && i < 3; i += x) { t += 1; } return t;"
        , [((6, 0), 0), ((6, 3), 2)]
        )
    , ("int x = left / right; int n = 0; do { n += 1; } while (right > 0 && n < x); return n;", [((6, 0), 1), ((6, 2), 3)])
    , ("int x = left / right; return match (right) { 0 -> 1, _ if x > 1 -> 2, _ -> 3 };", [((6, 0), 1), ((6, 3), 2), ((6, 6), 3)])
    , -- An argument that the method never needs is never computed: not a
      -- division by zero, and not a call that never returns.
      ("return Pick(right, left / right);", [((6, 0), 7), ((6, 3), 2)])
    , ("return Pick(right, Never(left));", [((1, 0), 7)])
    , ("return Pick(0, Never(left)) + Pick(1, Half(left));", [((8, 0), 11)])
    , ("return Both(right, Never(left), left + 1);", [((5, 0), 6)])
    , ("return Both(right, left / right, Never(left));", [((6, 3), 2)])
    , -- A value handed through one method to another is computed by the
      -- one that needs it, if any does.
      ("return Pass(right, left / right);", [((6, 0), 7), ((6, 3), 2)])
    , ("return Pick(right, Pick(right, left / right) + 1);", [((6, 0), 7), ((6, 2), 4)])
    , -- A method that calls itself hands a value on at every level; none
      -- of them is ever needed.
      ("return Down(left, right);", [((5, 0), 5), ((0, 0), 0)])
    , -- A local by need is handed on by need, alone and inside a larger
      -- argument, and to several methods.
      ("int x = Never(left); int y = Pick(right, x); return y;", [((1, 0), 7)])
    , ("int x = left / right; return Pick(right, x) + Pick(right, x + 1);", [((6, 0), 14), ((6, 3), 5)])
    , ("int x = Step(left); int y = Pick(right, x); return right > 0 ? x + y : y;", [((30, 1), 60), ((30, 0), 7)])
    , ("int x = left / right; int y = x + 1; return Pass(right, y * 2);", [((6, 0), 7), ((6, 3), 6)])
    , -- An argument means what its variables held at the call.
      ("int a = left; int r = Pick(right, Half(a) + a); a = 100; return r * 1000 + a;", [((8, 1), 12100), ((8, 0), 7100)])
    , -- A store in an argument happens at the call, whether or not the
      -- method ever reads the argument.
      ("int n = 0; int r = Pick(0, (n += 1) + left); return n * 10 + r;", [((1, 0), 17)])
    , -- A method reads an argument often and it is one value.
      ("return Often(right, Half(left));", [((8, 1), 200), ((8, 0), 0)])
    , -- An argument that a closure of the method captures is a value of
      -- the closure.
      ("return Kept(1, left / right);", [((6, 3), 3)])
    , ("return Kept(0, left / right);", [((6, 3), 3)])
    , -- In a loop every pass hands on a value of its own.
        ( "int t = 0; for (int i = 0; i <= 3; i += 1) { t += Pick(i, left / i); } return t;"
        , [((12, 0), 29)]
        )
    , -- An expression written as a statement is evaluated: that is all a
      -- statement can be for.
      ("int n = 0; _ = (n += 1) + left; return n;", [((1, 0), 1)])
    , -- Needed values give what they always gave.
      ("int x = Half(left); return x + x + x;", [((8, 0), 12)])
    , ("int x = Step(left); int y = Step(right); return x * 10 + y;", [((3, 4), 34)])
    ]

{- | A chain of values of which each reads the one before it twice, and of
which only the last is read, on one path.
-}
sharedChain :: Int -> String
sharedChain links =
    "int z0 = left / right; "
        ++ concat
            [ "int z" ++ show link ++ " = z" ++ show (link - 1) ++ " / 1 - z" ++ show (link - 1) ++ " / 2; "
            | link <- [1 .. links]
            ]
        ++ "if (right > 0) { return z"
        ++ show links
        ++ "; } return 7;"

{- | A value by need that adds the given number of terms, a division and
the same number of terms again, and is read on one path only.
-}
operatorChain :: Int -> String
operatorChain terms =
    "int x = "
        ++ intercalate " + " (replicate terms "left" ++ ["left / right"] ++ replicate terms "left")
        ++ "; return match (right) { 0 -> 7, _ -> x };"

-- | The size of the unoptimized Core of @Evaluate@ for the given body.
coreSize :: String -> Int
coreSize statements = case compileSource (program statements) of
    Right artifacts ->
        sum
            [ length (show (coreFunctionBody function))
            | function <- coreModuleFunctions (artifactCore artifacts)
            , "Evaluate" `isInfixOf` show (coreFunctionName function)
            ]
    Left _ -> 0

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "lazy.tala" text)

runs :: (FrontendArtifacts -> CoreModule) -> String -> (Integer, Integer) -> Maybe Integer
runs select statements (left, right) = case compileSource (program statements) of
    Right artifacts -> case runFunction (select artifacts) "Evaluate" [IntegerValue left, IntegerValue right] of
        Just (IntegerValue value) -> Just value
        _ -> Nothing
    Left _ -> Nothing

-- | The result of the unoptimized program within the given number of steps.
runsWithin :: Int -> String -> (Integer, Integer) -> Maybe Integer
runsWithin budget statements (left, right) = case compileSource (program statements) of
    Right artifacts ->
        case runFunctionWithBudget budget (artifactCore artifacts) "Evaluate" [IntegerValue left, IntegerValue right] of
            Just (IntegerValue value) -> Just value
            _ -> Nothing
    Left _ -> Nothing

-- | Whether the Core of @Evaluate@ mentions the given constructor or generated name.
mentions :: String -> (FrontendArtifacts -> CoreModule) -> String -> Bool
mentions needle select statements = case compileSource (program statements) of
    Right artifacts ->
        any
            ((needle `isInfixOf`) . show . coreFunctionBody)
            [ function
            | function <- coreModuleFunctions (select artifacts)
            , "Evaluate" `isInfixOf` show (coreFunctionName function)
            ]
    Left _ -> False

verifies :: String -> Bool
verifies statements = case compileSource (program statements) of
    Right artifacts ->
        verifyCore (artifactCore artifacts) == Right (artifactCore artifacts)
            && verifyCore (artifactOptimizedCore artifacts) == Right (artifactOptimizedCore artifacts)
            && verifyCorePrep (artifactCorePrep artifacts) == Right (artifactCorePrep artifacts)
    Left _ -> False
