-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Test builds, @#expect@ and the conditional directives.

@Spec\/Language\/Attributes.tala@ specifies @[Fact]@, @#if Fact@ and
@#expect@, and @Spec\/Language\/Decls.tala@ the conditional directives and
regions. A test build is compiled for a target with @Fact@ holding; the
driver adds a runner whose @Main@ calls every fact. The runner is run in the
reference Core evaluator before and after optimization, and what it wrote is
compared with text written by hand. The line terminator of the reference is
a line feed.
-}
module TestBuildTests (testBuildTests) where

import CoreInterpreter
import Progmasoft.Tala.AST (Identifier (..), QualifiedName (..), ResolvedName (..))
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core (CoreFunction (..), CoreModule (..))
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Directives

testBuildTests :: [(String, Bool)]
testBuildTests =
    concat
        [ [ ("unoptimized test build writes the report of " ++ name, ran artifactCoreOf source == Just expected)
          , ("optimized test build writes the report of " ++ name, ran artifactOptimizedCoreOf source == Just expected)
          ]
        | (name, source, expected) <- runs
        ]
        ++ [ ("test build rejects " ++ name ++ " with " ++ code, rejectedWith code (compileTests linux source))
           | (name, source, code) <- testRejections
           ]
        ++ [ ("directives choose " ++ name, chooses environment source)
           | (name, environment, source) <- selections
           ]
        ++ [ ("directives reject " ++ name ++ " with " ++ code, rejectedWith code (compilePlain linux source))
           | (name, source, code) <- directiveRejections
           ]
        ++ [ ("an ordinary build leaves out the branch of #if Fact", rejectedWith "TAN0001" (compilePlain linux helperOnlyInTests))
           ,
               ( "a test build keeps the branch of #if Fact"
               , ran artifactOptimizedCoreOf helperOnlyInTests == Just "PASS Probe.Uses\n1 test, 1 passed, 0 failed\n"
               )
           , ("an ordinary build compiles a [Fact] method as a method", accepted (compilePlain linux ordinaryWithFact))
           ,
               ( "a test build keeps Main for the runner alone"
               , fmap (mains . projectEntryCore) (compileTests linux programWithFact) == Right 1
               )
           ,
               ( "an entry keeps Main for itself alone"
               , fmap
                    (mains . artifactOptimizedCore)
                    ( compileEntryToCorePrepWith
                        linux
                        (QualifiedName [Identifier "Demo", Identifier "Program"])
                        (CompilerInput "Tests.tala" twoMains)
                    )
                    == Right 1
               )
           , ("test build rejects facts in two namespaces with TAE0020", rejectedWith "TAE0020" twoNamespaces)
           ]
    where
        twoNamespaces =
            compileTestsToCorePrep
                linux
                [ CompilerInput "One.tala" "namespace A; class One { [Fact] public static void F() { } }"
                , CompilerInput "Two.tala" "namespace B; class Two { [Fact] public static void G() { } }"
                ]

linux, windows :: DirectiveEnvironment
linux = DirectiveEnvironment Linux False
windows = DirectiveEnvironment Windows False

compileTests :: DirectiveEnvironment -> String -> Either [Diagnostic] ProjectFrontendArtifacts
compileTests environment source = compileTestsToCorePrep environment [CompilerInput "Tests.tala" source]

compilePlain :: DirectiveEnvironment -> String -> Either [Diagnostic] FrontendArtifacts
compilePlain environment source = compileToCorePrepWith environment (CompilerInput "Tests.tala" source)

artifactCoreOf, artifactOptimizedCoreOf :: ProjectFrontendArtifacts -> CoreModule
artifactCoreOf = artifactCore . artifactFrontend . projectEntryNamespace
artifactOptimizedCoreOf = projectEntryCore

-- | What the runner of a test build writes to standard output.
ran :: (ProjectFrontendArtifacts -> CoreModule) -> String -> Maybe String
ran select source = case compileTests linux source of
    Right artifacts -> case runFunctionWriting 200000 (select artifacts) "Main" [] of
        Just (_, Written output "") -> Just output
        _ -> Nothing
    Left _ -> Nothing

rejectedWith :: String -> Either [Diagnostic] value -> Bool
rejectedWith code result = case result of
    Left diagnostics -> any ((== code) . diagnosticCode) diagnostics
    Right _ -> False

accepted :: Either [Diagnostic] value -> Bool
accepted = either (const False) (const True)

-- | Whether the branch the source marks with @Chosen@ is the one compiled.
chooses :: DirectiveEnvironment -> String -> Bool
chooses environment source = case compilePlain environment (wrap source) of
    Right artifacts -> case runFunctionWriting 200000 (artifactOptimizedCore artifacts) "Main" [] of
        Just (_, Written "chosen\n" "") -> True
        _ -> False
    Left _ -> False
    where
        wrap body =
            unlines
                [ "namespace Probe;"
                , "public class Program {"
                , "    public static void Main() {"
                , body
                , "    }"
                , "}"
                ]

suite :: [String] -> String
suite members =
    unlines
        ( [ "namespace Probe;"
          , "public class Checks {"
          , "    public static int Twice(_ int v) { return v + v; }"
          , "    public static int Log(_ int v) { Console.Println(v); return v; }"
          ]
            ++ members
            ++ ["}"]
        )

runs :: [(String, String, String)]
runs =
    [
        ( "a passing fact"
        , suite ["    [Fact] public static void Doubles() { #expect Twice(2) == 4; }"]
        , "PASS Checks.Doubles\n1 test, 1 passed, 0 failed\n"
        )
    ,
        ( "a failing comparison with the value of its operand"
        , suite
            ["    [Fact] public static void Doubles() {", "        int count = Twice(1);", "        #expect count == 3;", "    }"]
        , "Tests.tala:7:9: expectation failed: count == 3\n    count is 2\nFAIL Checks.Doubles (1 failed expectation)\n1 test, 0 passed, 1 failed\n"
        )
    ,
        ( "a failed condition that is not a comparison"
        , suite ["    [Fact] public static void Truth() { #expect not (Twice(1) == 2); }"]
        , "Tests.tala:5:41: expectation failed: not (Twice(1) == 2)\nFAIL Checks.Truth (1 failed expectation)\n1 test, 0 passed, 1 failed\n"
        )
    ,
        ( "every expectation after a false one"
        , suite
            ["    [Fact] public static void Both() {", "        #expect Twice(1) == 1;", "        #expect Twice(2) > 5;", "    }"]
        , concat
            [ "Tests.tala:6:9: expectation failed: Twice(1) == 1\n    Twice(1) is 2\n"
            , "Tests.tala:7:9: expectation failed: Twice(2) > 5\n    Twice(2) is 4\n"
            , "FAIL Checks.Both (2 failed expectations)\n1 test, 0 passed, 1 failed\n"
            ]
        )
    ,
        ( "a named fact and the order of the facts"
        , suite
            [ "    [Fact(\"two and two\")] public static void First() { #expect Twice(2) == 4; }"
            , "    [Fact] public static void Second() { #expect Twice(3) \\= 6; }"
            ]
        , "PASS two and two\nTests.tala:6:42: expectation failed: Twice(3) \\= 6\n    Twice(3) is 6\nFAIL Checks.Second (1 failed expectation)\n2 tests, 1 passed, 1 failed\n"
        )
    ,
        ( "an operand evaluated once, also for the report"
        , suite ["    [Fact] public static void Once() { #expect Log(2) == 3; }"]
        , "2\nTests.tala:5:40: expectation failed: Log(2) == 3\n    Log(2) is 2\nFAIL Checks.Once (1 failed expectation)\n1 test, 0 passed, 1 failed\n"
        )
    ,
        ( "an expectation of a helper under #if Fact, for the fact that called it"
        , suite
            [ "#if Fact"
            , "    public static void Positive(_ int v) { #expect v > 0; }"
            , "#endif"
            , "    [Fact] public static void Calls() { Positive(Twice(0) - 1); }"
            ]
        , "Tests.tala:6:44: expectation failed: v > 0\n    v is -1\nFAIL Checks.Calls (1 failed expectation)\n1 test, 0 passed, 1 failed\n"
        )
    ,
        ( "a string comparison"
        , suite ["    [Fact] public static void Text() { String s = \"a\" + \"b\"; #expect s == \"ab\"; }"]
        , "PASS Checks.Text\n1 test, 1 passed, 0 failed\n"
        )
    ]

testRejections :: [(String, String, String)]
testRejections =
    [ ("an instance fact", suite ["    [Fact] public void Instance() { }"], "TAE0016")
    , ("a fact with a parameter", suite ["    [Fact] public static void Takes(_ int v) { }"], "TAE0017")
    , ("a fact with a result", suite ["    [Fact] public static int Gives() { return 1; }"], "TAE0018")
    , ("sources without a fact", suite [], "TAE0015")
    , ("#expect as an expression", suite ["    [Fact] public static void Value() { bool b = #expect 1 == 1; }"], "TAP0055")
    ]

-- | The body of @Main@ writes @chosen@ in the branch that should be compiled.
selections :: [(String, DirectiveEnvironment, String)]
selections =
    [ ("os(Windows) on Windows", windows, branches "os(Windows)")
    , ("#else on Linux for os(Windows)", linux, unlines ["#if os(Windows)", wrong, "#else", right, "#endif"])
    ,
        ( "the first branch that holds"
        , linux
        , unlines ["#if os(macOS)", wrong, "#elseif family(Unix)", right, "#elseif os(Linux)", wrong, "#endif"]
        )
    , ("not, && and parentheses", linux, branches "family(Unix) && not (os(macOS) || os(FreeBSD))")
    , ("|| on Windows", windows, branches "os(Linux) || family(Windows)")
    , ("no branch of Fact in an ordinary build", linux, unlines [right, "#if Fact", wrong, "#endif"])
    , ("true and false", linux, unlines ["#if false", wrong, "#elseif true", right, "#endif"])
    ,
        ( "nested groups"
        , linux
        , unlines ["#if family(Unix)", "#if os(Linux)", right, "#else", wrong, "#endif", "#else", wrong, "#endif"]
        )
    , ("a region", linux, unlines ["#region Output", right, "#endregion Output"])
    ]
    where
        right = "Console.Println(\"chosen\");"
        wrong = "Console.Println(\"wrong\");"
        branches condition = unlines ["#if " ++ condition, right, "#else", wrong, "#endif"]

directiveRejections :: [(String, String, String)]
directiveRejections =
    [ ("an unknown operating system", unlines ["#if os(ReactOS)", "#endif"], "TAP0046")
    , ("#define", "#define DEBUG true", "TAP0053")
    , ("a diagnostic directive", "#message \"Building\"", "TAP0053")
    , ("an unknown directive", "#pragma once", "TAP0054")
    , ("a directive symbol", unlines ["#if DEBUG", "#endif"], "TAP0047")
    ,
        ( "a split expression"
        , unlines
            [ "namespace A;"
            , "class C { public static void Main() {"
            , "int value ="
            , "#if os(Windows)"
            , "10"
            , "#else"
            , "20"
            , "#endif"
            , "; } }"
            ]
        , "TAP0043"
        )
    , ("#elseif after #else", unlines ["#if os(Windows)", "#else", "#elseif os(Linux)", "#endif"], "TAP0049")
    , ("an #if without #endif", "#if os(Linux)", "TAP0051")
    , ("#endif without #if", "#endif", "TAP0050")
    , ("#else with a condition", unlines ["#if os(Linux)", "#else os(Windows)", "#endif"], "TAP0048")
    , ("a region closed under another name", unlines ["#region Networking", "#endregion networking"], "TAP0052")
    , ("a directive after code on its line", "namespace A; #if os(Linux)\n#endif", "TAP0042")
    ,
        ( "#expect outside test code"
        , unlines ["namespace A;", "class C { public static void Main() { #expect 1 == 1; } }"]
        , "TAP0044"
        )
    ]

helperOnlyInTests :: String
helperOnlyInTests =
    unlines
        [ "namespace Probe;"
        , "class Probe {"
        , "#if Fact"
        , "    public static int Helper() { return 1; }"
        , "#endif"
        , "    [Fact] public static void Uses() { #expect Helper() == 1; }"
        , "}"
        ]

-- | How many functions of a build are spelled @Main@.
mains :: CoreModule -> Int
mains core =
    length
        [ ()
        | function <- coreModuleFunctions core
        , resolvedSpelling (coreFunctionName function) == Identifier "Main"
        ]

programWithFact :: String
programWithFact =
    unlines
        [ "namespace Smoke;"
        , "class Program {"
        , "    public static int Twice(_ int v) { return v + v; }"
        , "    public static void Main() { }"
        , "}"
        , "class Checks {"
        , "    [Fact] public static void Doubles() { Program.Main(); #expect Program.Twice(2) == 4; }"
        , "}"
        ]

twoMains :: String
twoMains =
    unlines
        [ "namespace Demo;"
        , "class Program {"
        , "    public static void Main() { Other.Main(); }"
        , "}"
        , "class Other {"
        , "    public static void Main() { }"
        , "}"
        ]

ordinaryWithFact :: String
ordinaryWithFact =
    unlines
        [ "namespace Probe;"
        , "class Probe {"
        , "    [Fact] public static void Check() { #expect 1 + 1 == 2; }"
        , "    public static void Main() { Check(); }"
        , "}"
        ]
