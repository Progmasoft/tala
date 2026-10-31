-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Tests for return types that are inferred, and for callables that are
called.

A method declared with @auto@ takes its return type from its returns, and a
caller must see that type wherever the method is declared: later in the
class, in another class, or behind a chain of other such methods. A method
all of whose results depend on itself has none. A callable takes its return
type the same way, and may be created inside another callable, whose
captures it reads.

The expected values are written by hand. Every program runs in the reference
evaluator of "CoreInterpreter" on the unoptimized and on the optimized Core,
and is verified as Core and as CorePrep.
-}
module InferredReturnTests (inferredReturnTests) where

import CoreInterpreter
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Diagnostic

inferredReturnTests :: [(String, Bool)]
inferredReturnTests =
    concat
        [ [ ("unoptimized Core computes " ++ label, runs artifactCore source left right expected)
          , ("optimized Core computes " ++ label, runs artifactOptimizedCore source left right expected)
          ]
        | (source, runsOfCase) <- map inMethods methodCases ++ map inMethods closureCases ++ classCases
        , ((left, right), expected) <- runsOfCase
        , let label = show expected ++ " for " ++ show (left, right) ++ ": " ++ lastLine source
        ]
        ++ [ ("every program verifies as Core and as CorePrep", all verifies (map (fst . inMethods) (methodCases ++ closureCases) ++ map fst classCases))
           , ("a method whose only result is a call of itself has no return type", rejectedWith "TAT0063" (methods "return 0;" ++ loops))
           , ("two methods that only return each other have no return type", rejectedWith "TAT0063" (methods "return 0;" ++ cycle2))
           , ("returns of different types in an inferred method are reported", rejectedWith "TAT0062" (methods "return 0;" ++ mixed))
           , ("an inferred return type is checked at the call", rejected (methods "int x = Even(2); return x;"))
           , ("a declared return type is still checked against its returns", rejectedWith "TAT0001" (methods "return 0;" ++ declared))
           , ("a method without a result is inferred as void", accepted (methods "Nothing(); return 0;"))
           ]
    where
        inMethods (statements, runsOfCase) = (methods statements, runsOfCase)
        lastLine = last . lines

-- | A class around the given body of @Evaluate@, closed by the caller.
methods :: String -> String
methods statements =
    unlines
        [ "namespace Test;"
        , "class Helper {"
        , "    public static auto Five() { return Program.Base() + 4; }"
        , "}"
        , "class Program {"
        , "    public static auto Twice(_ int value) { return value + value; }"
        , "    public static auto Factorial(_ int value) { if (value <= 1) { return 1; } return value * Factorial(value - 1); }"
        , "    public static auto First(_ int v) { return Second(v) + 1; }"
        , "    public static auto Second(_ int v) { return Third(v) + 10; }"
        , "    public static auto Third(_ int v) { return v * 2; }"
        , "    public static auto Even(_ int v) { if (v == 0) { return true; } return Odd(v - 1); }"
        , "    public static auto Odd(_ int v) { if (v == 0) { return false; } return Even(v - 1); }"
        , "    public static auto Pick(_ int v) { int q = if (v > 0) { return v * 3; } else { 5 }; return q + 1; }"
        , "    public static auto Scan(_ int v) { int q = while (true) { if (v > 3) { return 7; } break 2; }; return q + v; }"
        , "    public static auto Base() { return 1; }"
        , "    public static auto Nothing() { }"
        , "    public static int Apply(_ (int) -> int f, _ int v) { return f(v); }"
        , "    public static (int) -> int Adder(_ int n) { return \\(int w) -> w + n; }"
        , "    public static (int) -> int Pass(_ (int) -> int f) { return f; }"
        , "    public static (int) -> int Choose(_ bool c, _ (int) -> int a, _ (int) -> int b) { if (c) { return a; } return b; }"
        , "    public static (int) -> int Compose2(_ (int) -> int f) { return \\(int w) -> f(f(w)); }"
        , "    public static int Plain(_ int value) { return value + value; }"
        , "    public static int Evaluate(_ int left, _ int right) {"
        , "        " ++ statements
        , "    }"
        , "}"
        ]

-- Declarations that are appended as further classes.
loops, cycle2, mixed, declared :: String
loops = "class Loops { public static auto Loop() { return Loop(); } }\n"
cycle2 = "class Cycle { public static auto A() { return B(); } public static auto B() { return A(); } }\n"
mixed = "class Mixed { public static auto Pick(_ bool f) { if (f) { return 1; } return true; } }\n"
declared = "class Declared { public static int Wrong() { return true; } }\n"

-- | Bodies of @Evaluate@ that call methods with inferred return types.
methodCases :: [(String, [((Integer, Integer), Integer)])]
methodCases =
    [ ("return Twice(left) + Factorial(right);", [((3, 4), 30), ((0, 1), 1)])
    , -- A chain is inferred from its end, against the order of declaration.
      ("return First(left);", [((4, 0), 19)])
    , -- Mutual recursion is inferred from the base cases.
      ("return (Even(left) ? 10 : 20) + (Odd(left) ? 1 : 2);", [((4, 0), 12), ((3, 0), 21)])
    , -- Returns that stand in a value block and in a loop expression.
      ("return Pick(left) * 10 + Pick(0 - left);", [((2, 0), 66)])
    , ("return Scan(left) * 100 + Scan(left + 3);", [((1, 0), 307)])
    , -- The inferred type is the type of the call.
      ("int x = Twice(left); bool b = Even(x); return b ? x : 0 - x;", [((3, 0), 6)])
    , -- A method of another class, which calls back into this one.
      ("return Helper.Five() * left;", [((3, 0), 15)])
    ]

-- | Bodies of @Evaluate@ that create callables and call them.
closureCases :: [(String, [((Integer, Integer), Integer)])]
closureCases =
    [ -- A callable created inside a callable.
      ("auto outer = \\(int v) -> { auto inner = \\(int w) -> w + 1; return inner(v) * 2; }; return outer(left);", [((3, 0), 8)])
    , -- The inner callable reads a local of the method through the outer one.
        ( "int k = left; auto outer = \\(int v) -> { auto inner = \\(int w) -> w + k + v; return inner(v) * 2; }; return outer(right);"
        , [((3, 3), 18), ((5, 1), 14)]
        )
    , -- The same with the captures written out.
        ( "int k = left; auto outer = [k] \\(int v) -> { auto inner = [k, v] \\(int w) -> w + k + v; return inner(v); }; return outer(right);"
        , [((3, 3), 9)]
        )
    , -- Three levels; every level reads a name of each level around it.
        ( "int k = left; auto a = \\(int v) -> { auto b = \\(int w) -> { auto c = \\(int x) -> x + w * 10 + v * 100 + k * 1000; return c(1); }; return b(2); }; return a(3);"
        , [((4, 0), 4321)]
        )
    , -- A callable outlives the call that created it and keeps its capture.
        ( "auto make = \\(int v) -> { auto inner = \\(int w) -> w + v; return inner; }; auto f = make(left); auto g = make(right); return f(2) * 100 + g(2);"
        , [((5, 7), 709)]
        )
    , -- A capture initializer is evaluated once, where the callable is created.
        ( "int k = left; auto held = [kept = k] \\ -> kept; k += 10; return held() * 100 + k;"
        , [((1, 0), 111)]
        )
    , -- The return type of a callable is inferred through its expressions.
        ( "auto pick = \\(int v) -> { int q = if (v > 0) { return 1; } else { 2 }; return q; }; return pick(left) * 10 + pick(0 - left);"
        , [((3, 0), 12)]
        )
    ,
        ( "auto scan = \\(int v) -> { int q = while (true) { if (v > 3) { return 7; } break 2; }; return q + v; }; return scan(left) * 100 + scan(left + 3);"
        , [((1, 0), 307)]
        )
    , -- A callable passed to a method, made by one and returned by one.
      ("return Apply(\\(int w) -> w * 3, left);", [((4, 0), 12)])
    , ("auto add = Adder(left); auto ten = Adder(10); return add(right) * 100 + ten(1);", [((5, 2), 711)])
    , ("auto f = \\(int w) -> w + 1; auto g = Pass(f); return g(left) + f(left);", [((3, 0), 8)])
    ,
        ( "auto a = \\(int w) -> w + 1; auto b = \\(int w) -> w * 2; auto c = Choose(left > right, a, b); return c(left);"
        , [((5, 1), 6), ((5, 9), 10)]
        )
    , -- A method named where a value is expected.
      ("auto f = Plain; return Apply(f, left) + Apply(Plain, right);", [((3, 4), 14)])
    , -- A callable variable assigned again, in a loop and from itself.
        ( "auto f = Adder(0); for (int i = 1; i <= left; i += 1) { f = Adder(i); } return f(100);"
        , [((3, 0), 103), ((0, 0), 100)]
        )
    , ("auto f = Adder(1); f = Compose2(f); return f(left);", [((5, 0), 7)])
    , -- Callables that exist on one branch only.
        ( "int r = 0; if (left > right) { auto f = Adder(left); r = f(1); } else { auto g = Adder(right); auto h = Compose2(g); r = h(1); } return r;"
        , [((4, 1), 5), ((1, 3), 7)]
        )
    , -- A callable result that nothing receives.
      ("_ = Adder(left); auto f = Adder(2); _ = Adder(3); return f(left);", [((5, 0), 7)])
    , -- A callable kept alive only by the callable that captured it.
      ("auto inner = Adder(left); auto outer = \\(int w) -> inner(w) * 2; return outer(right);", [((5, 1), 12)])
    , -- A callable made in every pass of a loop that returns from its middle.
        ( "for (int i = 0; i < 5; i += 1) { auto f = Adder(i); if (f(left) > 6) { return f(100); } } return 0;"
        , [((4, 0), 103), ((0, 0), 0)]
        )
    , -- Callables alive across the transfers of a loop header.
        ( "int n = 0; int t = 0; while (if (n >= left) { break; } else { true }) { auto step = [by = n] \\ -> by + 1; n = step(); t += n; } return t;"
        , [((3, 0), 6)]
        )
    ,
        ( "int t = 0; for (int i = 0; i < 10; i += if (i == left) { break; } else { 1 }) { auto add = [by = i] \\(int w) -> w + by; t = add(t); } return t;"
        , [((3, 0), 6)]
        )
    ]

-- | Whole sources: an inferred method that only another class declares.
classCases :: [(String, [((Integer, Integer), Integer)])]
classCases =
    [
        ( unlines
            [ "namespace Test;"
            , "class Program {"
            , "    public static int Evaluate(_ int left, _ int right) { return Later.Sum(left, right) + Later.Flag(left); }"
            , "}"
            , "class Later {"
            , "    public static auto Sum(_ int a, _ int b) { return Double(a) + b; }"
            , "    public static auto Flag(_ int a) { return Positive(a) ? 100 : 200; }"
            , "    private static auto Double(_ int a) { return a + a; }"
            , "    private static auto Positive(_ int a) { return a > 0; }"
            , "}"
            ]
        , [((3, 4), 110), ((0, 1), 201)]
        )
    ]

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "inferred.tala" text)

accepted :: String -> Bool
accepted = either (const False) (const True) . compileSource

rejected :: String -> Bool
rejected = not . accepted

rejectedWith :: String -> String -> Bool
rejectedWith code text = case compileSource text of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

runs :: (FrontendArtifacts -> CoreModule) -> String -> Integer -> Integer -> Integer -> Bool
runs select source left right expected = case compileSource source of
    Right artifacts ->
        runFunction (select artifacts) "Evaluate" [IntegerValue left, IntegerValue right] == Just (IntegerValue expected)
    Left _ -> False

verifies :: String -> Bool
verifies source = case compileSource source of
    Right artifacts ->
        verifyCore (artifactCore artifacts) == Right (artifactCore artifacts)
            && verifyCore (artifactOptimizedCore artifacts) == Right (artifactOptimizedCore artifacts)
            && verifyCorePrep (artifactCorePrep artifacts) == Right (artifactCorePrep artifacts)
    Left _ -> False
