-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Names written through what declares them.

A declaration of a namespace may be named through the namespace:
@Demo.Program@ is @Program@ inside the namespace @Demo@. A static method may
be referred to through its type without being called: @Program::Log@ is the
method as a callable value, like the bare @Log@ inside @Program@. A selector
with a dot is not a reference: @Program.Log@ without a call is rejected.

Each program is run in the reference evaluator, before and after
optimization, and what it writes is compared with text written by hand. The
programs that must be rejected are held with the code of the diagnostic.
-}
module QualifiedNameTests (qualifiedNameTests) where

import CoreInterpreter
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Diagnostic

qualifiedNameTests :: [(String, Bool)]
qualifiedNameTests =
    concat
        [ [ ("unoptimized: " ++ label, written artifactCore (source body) == Just expected)
          , ("optimized: " ++ label, written artifactOptimizedCore (source body) == Just expected)
          ]
        | (label, source, body, expected) <- outputs
        ]
        ++ [ (label ++ " (" ++ code ++ ")", rejectedWith code (source body))
           | (label, source, body, code) <- rejections
           ]

-- | The label, the program around the body of @Main@, the body and the text.
outputs :: [(String, String -> String, String, String)]
outputs =
    [ ("a method is called through its namespace", demo, "Console.Println(Demo.Program.Half(8));", "4\n")
    , ("a method called through its namespace writes where it stands", demo, "int x = Demo.Program.Log(1); Console.Println(9);", "1\n9\n")
    , ("a method of another class is called through the namespace", demo, "Console.Println(Demo.Other.Triple(3));", "9\n")
    , ("an enum member is named through the namespace", demo, "Color c = Demo.Color.Green; Console.Println(c == Color.Green && c \\= Demo.Color.Red);", "true\n")
    , ("the namespace and the bare name are the same declaration", demo, "Console.Println(Demo.Program.Half(8) == Program.Half(8) && Program.Half(8) == Half(8));", "true\n")
    , ("a namespace of several parts is written whole", nested, "Console.Println(Outer.Inner.Program.Half(10));", "5\n")
    , ("a method named through its type is a value", demo, "auto f = Program::Log; int x = f(1); Console.Println(9);", "1\n9\n")
    , ("a method named through its type is handed to a method", demo, "int x = Run(Program::Log); Console.Println(9);", "3\n9\n")
    , ("a method of another class is a value", demo, "Console.Println(Run(Other::Triple));", "9\n")
    , ("a method named through namespace and type is a value", demo, "Console.Println(Run(Demo.Other::Triple));", "9\n")
    , ("a quiet method named through its type is called by need", demo, "int x = Run(Program::Half) / Zero(); Console.Println(9);", "9\n")
    , ("the place selects among the overloads of a method value", demo, "Console.Println(Run(Other::Pick));", "13\n")
    , ("a method value is called as often as its call is reached", demo, "auto f = Other::Triple; int t = 0; for (int i = 0; i < 4; i += 1) { t += f(i); } Console.Println(t);", "18\n")
    , -- A class of the program named like the namespace is the class.
      ("a class named like the namespace hides the namespace", shadowed, "Console.Println(Demo.Seven());", "7\n")
    ]

-- | The label, the program, the body of @Main@ and the code it is rejected with.
rejections :: [(String, String -> String, String, String)]
rejections =
    [ ("a type the namespace does not declare", demo, "Console.Println(Demo.Missing.Half(8));", "TAN0001")
    , ("another namespace is not known", demo, "Console.Println(Elsewhere.Program.Half(8));", "TAN0001")
    , ("a part of a namespace is not the namespace", nested, "Console.Println(Outer.Program.Half(10));", "TAN0001")
    , ("the last part of a namespace is not the namespace", nested, "Console.Println(Inner.Program.Half(10));", "TAN0001")
    , ("a local name hides the namespace", demo, "int Demo = 1; Console.Println(Demo.Program.Half(8));", "TAT0032")
    , ("a selector with a dot is not a method reference", demo, "auto f = Program.Log;", "TAT0034")
    , ("a selector with a dot is not an argument", demo, "Console.Println(Run(Program.Log));", "TAT0009")
    , ("a method reference through a value", demo, "int v = 1; auto f = v::Half;", "TAT0081")
    , ("a method reference through a name that is not declared", demo, "auto f = Missing::Half;", "TAN0001")
    , ("a method value of a name the type does not declare", demo, "auto f = Program::Missing;", "TAT0029")
    , ("a method value of a private method of another class", demo, "auto f = Other::Hidden;", "TAT0033")
    , ("a method value with overloads and no expected type", demo, "auto f = Other::Pick;", "TAT0080")
    , ("a call that expects none of the overloads of a method value", demo, "Console.Println(Wide(Other::Pick));", "TAT0009")
    ]

demo :: String -> String
demo body =
    unlines
        [ "namespace Demo;"
        , "enum Color { Red, Green }"
        , "public class Other {"
        , "    public static int Triple(_ int v) { return v * 3; }"
        , "    public static int Pick(_ int v) { return v + 10; }"
        , "    public static int Pick(_ int v, _ int w) { return v + w; }"
        , "    private static int Hidden(_ int v) { return v; }"
        , "}"
        , "public class Program {"
        , "    public static int Zero() { return 0; }"
        , "    public static int Half(_ int v) { return v / 2; }"
        , "    public static int Log(_ int v) { Console.Println(v); return v; }"
        , "    public static int Run(_ (int) -> int f) { return f(3); }"
        , "    public static int Wide(_ (int, int, int) -> int f) { return f(1, 2, 3); }"
        , "    public static void Main() {"
        , "        " ++ body
        , "    }"
        , "}"
        ]

nested :: String -> String
nested body =
    unlines
        [ "namespace Outer.Inner;"
        , "public class Program {"
        , "    public static int Half(_ int v) { return v / 2; }"
        , "    public static void Main() {"
        , "        " ++ body
        , "    }"
        , "}"
        ]

shadowed :: String -> String
shadowed body =
    unlines
        [ "namespace Demo;"
        , "public class Demo {"
        , "    public static int Seven() { return 7; }"
        , "}"
        , "public class Program {"
        , "    public static void Main() {"
        , "        " ++ body
        , "    }"
        , "}"
        ]

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "qualified.tala" text)

-- | What @Main@ writes to standard output.
written :: (FrontendArtifacts -> CoreModule) -> String -> Maybe String
written select text = case compileSource text of
    Right artifacts -> case runFunctionWriting 200000 (select artifacts) "Main" [] of
        Just (_, Written output "") -> Just output
        _ -> Nothing
    Left _ -> Nothing

rejectedWith :: String -> String -> Bool
rejectedWith code text = case compileSource text of
    Left diagnostics -> any ((== code) . diagnosticCode) diagnostics
    Right _ -> False
