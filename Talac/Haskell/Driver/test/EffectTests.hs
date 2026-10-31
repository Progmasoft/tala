-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Which expressions the compiler takes to have an effect.

Evaluation is by need and effects are not: an expression that writes to the
console is evaluated where it stands. The source does not say which
expressions write, so the frontend infers it from the bodies of the methods
a program has; see "Progmasoft.Tala.Desugarer.Effects". These cases hold that
inference from both sides:

* it must find every write, however far down the calls it is, or a program
  would write later than it says, or not at all;
* it must not find writes that are not there, or a program without output
  would lose the evaluation by need it had.

Each program is checked twice: for what it writes, in the reference
evaluator before and after optimization, and for the shape of its Core,
where a flag named @$known@ marks a binding that was deferred and
@CoreMemoize@ an argument that was suspended.

Where the inference errs on purpose, the case says so and pins it, so that
making it more exact shows as a change here.
-}
module EffectTests (effectTests) where

import CoreInterpreter
import Data.List (isInfixOf)
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Diagnostic

effectTests :: [(String, Bool)]
effectTests =
    concat
        [ [ ("unoptimized: " ++ label, written artifactCore members body == Just expected)
          , ("optimized: " ++ label, written artifactOptimizedCore members body == Just expected)
          ]
        | (label, members, body, expected) <- orders
        ]
        ++ [ (label, deferred members body == expected) | (label, members, body, expected) <- deferrals
           ]
        ++ [ (label, suspended members body == expected) | (label, members, body, expected) <- suspensions
           ]

-- | A method that writes, and methods that reach it through one and two calls.
chain :: String
chain =
    unlines
        [ "    public static int Log(_ int v) { Console.Println(v); return v; }"
        , "    public static int Once(_ int v) { return Log(v) + 1; }"
        , "    public static int Twice(_ int v) { return Once(v) + 1; }"
        , "    public static int Quiet(_ int v) { return v + 1; }"
        , "    public static int Deep(_ int v) { return Quiet(Quiet(v)); }"
        , "    public static int Zero() { return 0; }"
        ]

-- | Two methods that call each other, one of which writes.
mutual :: String
mutual =
    unlines
        [ "    public static int Ping(_ int n) { if (n <= 0) { return 0; } return Pong(n - 1) + 1; }"
        , "    public static int Pong(_ int n) { Console.Print(n); if (n <= 0) { return 0; } return Ping(n - 1) + 1; }"
        , "    public static int Even(_ int n) { if (n <= 0) { return 1; } return Odd(n - 1); }"
        , "    public static int Odd(_ int n) { if (n <= 0) { return 0; } return Even(n - 1); }"
        , "    public static int Zero() { return 0; }"
        ]

-- | Methods with parameters that are read first, after a write, and never.
parameters :: String
parameters =
    unlines
        [ "    public static int Log(_ int v) { Console.Println(v); return v; }"
        , "    public static int Zero() { return 0; }"
        , "    public static int Pick(_ int flag, _ int value) { if (flag > 0) { return value; } return 7; }"
        , "    public static int Announce(_ int flag, _ int value) { Console.Print(\"a\"); if (flag > 0) { return value; } return 7; }"
        , "    public static int Through(_ int flag, _ int value) { return Announce(flag, value); }"
        ]

-- | Callables that write and callables that do not.
callables :: String
callables =
    unlines
        [ "    public static int Log(_ int v) { Console.Println(v); return v; }"
        , "    public static int Zero() { return 0; }"
        , "    public static int Apply(_ int v) { auto step = \\(int w) -> w + 1; return step(v); }"
        , "    public static int Run(_ (int) -> int f) { return f(3); }"
        , "    public static int Quiet(_ int v) { return v + 1; }"
        ]

{- | What a program writes: the label, the members beside @Main@, the body of
@Main@ and the text. An expression that writes is carried out where it
stands, in order, whether or not anything needs its value.
-}
orders :: [(String, String, String, String)]
orders =
    [ ("a write one call down happens at the binding", chain, "int x = Once(1); Console.Println(9);", "1\n9\n")
    , ("a write two calls down happens at the binding", chain, "int x = Twice(1); Console.Println(9);", "1\n9\n")
    , ("bindings that write keep their order", chain, "int a = Twice(1); int b = Once(2); int c = Log(3); Console.Println(a + b + c);", "1\n2\n3\n9\n")
    , ("a binding that only computes does not move a write", chain, "int a = Deep(1); int b = Log(2); Console.Println(a);", "2\n3\n")
    , ("a value that is never needed is not computed beside writes", chain, "int a = Deep(1) / Zero(); int b = Log(2);", "2\n")
    , ("a write in a method that calls itself through another", mutual, "int x = Ping(4); Console.Println(\"!\");", "31!\n")
    , ("methods that call each other and never write stay quiet", mutual, "int x = Even(5); Console.Println(x);", "0\n")
    , ("a recursion that is never needed does not run", mutual, "int x = Even(4) / Zero(); Console.Println(\"ok\");", "ok\n")
    , ("an argument that writes is carried out at the call", parameters, "Console.Println(Pick(0, Log(5)));", "5\n7\n")
    , ("an argument that writes is carried out before the method writes", parameters, "Console.Println(Announce(0, Log(5)));", "5\na7\n")
    , ("a method that writes may still leave an argument unused", parameters, "Console.Println(Announce(0, 8 / Zero()));", "a7\n")
    , ("an argument handed through a method that writes may stay unused", parameters, "Console.Println(Through(0, 8 / Zero()));", "a7\n")
    , ("an argument handed through is computed when it is needed", parameters, "Console.Println(Through(1, 8 / 2));", "a4\n")
    , ("arguments that write keep the order they are written in", parameters, "Console.Println(Pick(Log(1), Log(2)));", "1\n2\n2\n")
    , ("a callable that writes is called where its call stands", callables, "auto say = \\(int v) -> Log(v); int x = say(1); Console.Println(9);", "1\n9\n")
    , ("a callable that writes directly is called where its call stands", callables, "auto say = \\(int v) -> { Console.Println(v); return v; }; int x = say(1); Console.Println(9);", "1\n9\n")
    , ("creating a callable that writes writes nothing", callables, "auto say = \\(int v) -> Log(v); Console.Println(9);", "9\n")
    , ("a callable is called as often as its call is reached", callables, "auto say = \\(int v) -> Log(v); int t = 0; for (int i = 0; i < 3; i += 1) { t += say(i); } Console.Println(t);", "0\n1\n2\n3\n")
    , -- A method is a callable value too, and no callable expression is
      -- written anywhere in these programs.
      ("a method that writes held as a value is called where its call stands", callables, "auto f = Log; int x = f(1); Console.Println(9);", "1\n9\n")
    , ("a method that writes handed to a method is called where that call stands", callables, "int x = Run(Log); Console.Println(9);", "3\n9\n")
    , ("a quiet method handed to a method is called when its value is needed", callables, "int x = Run(Quiet); Console.Println(x);", "4\n")
    , ("a quiet method handed to a method is not called for a value nothing needs", callables, "int x = Run(Quiet) / Zero(); Console.Println(9);", "9\n")
    , ("a method that writes called through its class writes at the binding", callables, "int x = Program.Log(1); Console.Println(9);", "1\n9\n")
    , ("a method with a quiet callable computes", callables, "Console.Println(Apply(4));", "5\n")
    , ("a write in a condition happens when the condition is evaluated", chain, "if (Log(1) > 0) { Console.Println(\"yes\"); }", "1\nyes\n")
    , ("a write behind a short circuit happens only when it is reached", chain, "bool b = Zero() > 0 && Log(1) > 0; Console.Println(\"end\");", "end\n")
    , ("a write in the taken arm of a conditional happens", chain, "int v = Zero() > 0 ? Log(1) : Log(2); Console.Println(v);", "2\n2\n")
    , ("a write in a loop condition happens on every pass", chain, "int i = 0; while (Log(i) < 2) { i += 1; }", "0\n1\n2\n")
    , ("a discarded value that writes is carried out", chain, "_ = Twice(4);", "4\n")
    , ("a statement that writes is carried out", chain, "Twice(4);", "4\n")
    ]

{- | Whether the Core of @Main@ holds a deferred binding. A binding whose
initializer may write is never deferred; one that only computes still is.
-}
deferrals :: [(String, String, String, Bool)]
deferrals =
    [ ("a binding of a method that writes is not deferred", chain, "int x = Log(1); if (Zero() > 0) { Console.Println(x); }", False)
    , ("a binding one call above a write is not deferred", chain, "int x = Once(1); if (Zero() > 0) { Console.Println(x); }", False)
    , ("a binding two calls above a write is not deferred", chain, "int x = Twice(1); if (Zero() > 0) { Console.Println(x); }", False)
    , ("a binding of a method that only computes is deferred", chain, "int x = Quiet(1); if (Zero() > 0) { Console.Println(x); }", True)
    , ("a binding two calls above nothing is deferred", chain, "int x = Deep(1); if (Zero() > 0) { Console.Println(x); }", True)
    , ("a binding with a write in one operand is not deferred", chain, "int x = Quiet(1) + Log(2); if (Zero() > 0) { Console.Println(x); }", False)
    , ("a binding with a write in a conditional arm is not deferred", chain, "int x = Zero() > 0 ? Log(1) : 2; if (Zero() > 0) { Console.Println(x); }", False)
    , ("a binding of a recursion that writes is not deferred", mutual, "int x = Ping(2); if (Zero() > 0) { Console.Println(x); }", False)
    , ("a binding of a recursion that only computes is deferred", mutual, "int x = Even(2); if (Zero() > 0) { Console.Println(x); }", True)
    , -- No callable of this program writes, so a call through one computes.
      ("a binding of a callable is deferred when no callable writes", callables, "auto step = \\(int w) -> w + 1; int x = step(1); if (Zero() > 0) { Console.Println(x); }", True)
    , ("a binding of a callable is not deferred when a callable writes", callables, "auto say = \\(int v) -> Log(v); int x = say(1); if (Zero() > 0) { Console.Println(x); }", False)
    , ("a binding of a method value that writes is not deferred", callables, "auto f = Log; int x = f(1); if (Zero() > 0) { Console.Println(x); }", False)
    , ("a binding of a call handing on a method that writes is not deferred", callables, "int x = Run(Log); if (Zero() > 0) { Console.Println(x); }", False)
    , ("a binding of a call handing on a quiet method is deferred", callables, "int x = Run(Quiet); if (Zero() > 0) { Console.Println(x); }", True)
    , -- Calling a method by name does not make it a value.
      ("a method that writes and is only called by name leaves callables quiet", callables, "Log(0); auto step = \\(int w) -> w + 1; int x = step(1); if (Zero() > 0) { Console.Println(x); }", True)
    , -- The inference does not follow which callable a value holds: once
      -- any callable of the program writes, a call through any callable
      -- is taken to write. Pinned, so that a more exact answer shows.
      ("a quiet callable is taken to write beside one that does", callables, "auto say = \\(int v) -> Log(v); auto step = \\(int w) -> w + 1; int x = step(1); if (Zero() > 0) { Console.Println(x); }", False)
    ]

{- | Whether the Core of @Main@ suspends an argument. An argument that may
write is computed at the call; one that only computes, and may fail, is
suspended when the method may leave it unused.
-}
suspensions :: [(String, String, String, Bool)]
suspensions =
    [ ("an argument that only computes is suspended", parameters, "Console.Println(Pick(0, 8 / Zero()));", True)
    , ("an argument that writes is not suspended", parameters, "Console.Println(Pick(0, Log(5)));", False)
    , ("an argument with a write in one operand is not suspended", parameters, "Console.Println(Pick(0, 8 / Zero() + Log(5)));", False)
    , -- A method that writes before it reads a parameter is not certain to
      -- need the parameter first, so the argument may stay unused.
      ("an argument of a method that writes first is suspended", parameters, "Console.Println(Announce(0, 8 / Zero()));", True)
    , ("an argument handed through a method is suspended", parameters, "Console.Println(Through(0, 8 / Zero()));", True)
    , ("an argument that cannot fail is passed as a value", parameters, "Console.Println(Pick(0, 8 + 1));", False)
    ]

program :: String -> String -> String
program members body =
    unlines
        [ "namespace Demo;"
        , "public class Program {"
        , members
        , "    public static void Main() {"
        , "        " ++ body
        , "    }"
        , "}"
        ]

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "effects.tala" text)

-- | What @Main@ writes to standard output.
written :: (FrontendArtifacts -> CoreModule) -> String -> String -> Maybe String
written select members body = case compileSource (program members body) of
    Right artifacts -> case runFunctionWriting 200000 (select artifacts) "Main" [] of
        Just (_, Written output "") -> Just output
        _ -> Nothing
    Left _ -> Nothing

-- | Whether the unoptimized Core of @Main@ mentions the given text.
mainMentions :: String -> String -> String -> Bool
mainMentions needle members body = case compileSource (program members body) of
    Right artifacts ->
        any
            ((needle `isInfixOf`) . show . coreFunctionBody)
            [ function
            | function <- coreModuleFunctions (artifactCore artifacts)
            , "Main" `isInfixOf` show (coreFunctionName function)
            ]
    Left _ -> False

deferred :: String -> String -> Bool
deferred = mainMentions "$known"

suspended :: String -> String -> Bool
suspended = mainMentions "CoreMemoize"
