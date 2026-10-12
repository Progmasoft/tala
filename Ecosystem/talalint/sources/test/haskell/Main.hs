-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Main (main) where

import Data.List (sort)
import System.Exit (exitFailure)
import Progmasoft.Talafmt
import Progmasoft.Talalint
import Progmasoft.Tala.Frontend

main :: IO ()
main = do
    check "linter reports compiler and physical source diagnostics" reportsDiagnostics
    check "safe fixes remove all implemented source hygiene findings" safeFixes
    check "safe fixes reach an idempotent result" safeFixesAreIdempotent
    check "malformed source remains a compiler diagnostic after a failed fix" malformedSourceRemainsVisible
    check "check catalog exposes stable command output" checkCatalog
    check "a source with the forms of 0.5.0 is clean" currentFormsAreClean
    check "a selector with a dot and no call is a compiler diagnostic" dottedSelectorIsReported
    check "a method reference the place does not select is a compiler diagnostic" ambiguousReferenceIsReported
    check "a method reference through a value is a compiler diagnostic" boundReferenceIsReported
    check "a format that does not match its arguments is a compiler diagnostic" formatMismatchIsReported
    check "safe fixes keep a method reference as written" safeFixesKeepReferences

check :: String -> Bool -> IO ()
check label passed = if passed then putStrLn ("PASS: " ++ label) else putStrLn ("FAIL: " ++ label) >> exitFailure

validSource :: String
validSource =
    "namespace Example;\r\npublic class Program {\n    public static void Main() {  \r\n        return;\r\n    }\r\n}"

reportsDiagnostics :: Bool
reportsDiagnostics =
    let sourceProblems = lintSource (CompilerInput "Program.tala" validSource)
        compilerProblems = lintSource (CompilerInput "Broken.tala" "@")
        ruleIds = map lintRuleId sourceProblems
     in sort ruleIds
            == sort
                [ "format.trailingWhitespace"
                , "format.mixedLineEndings"
                , "format.missingFinalNewline"
                ]
            && any ((== "compiler.TAL0001") . lintRuleId) compilerProblems

safeFixes :: Bool
safeFixes = case applySafeFixes (CompilerInput "Program.tala" validSource) of
    Left _ -> False
    Right result -> null (lintSource (CompilerInput "Program.tala" (formattedSource result)))

safeFixesAreIdempotent :: Bool
safeFixesAreIdempotent = case applySafeFixes (CompilerInput "Program.tala" validSource) of
    Left _ -> False
    Right first -> case applySafeFixes (CompilerInput "Program.tala" (formattedSource first)) of
        Left _ -> False
        Right second -> not (formattingChanged second) && formattedSource second == formattedSource first

malformedSourceRemainsVisible :: Bool
malformedSourceRemainsVisible =
    let input = CompilerInput "Broken.tala" "@   "
     in case applySafeFixes input of
            Left _ -> any ((== "compiler.TAL0001") . lintRuleId) (lintSource input)
            Right _ -> False

checkCatalog :: Bool
checkCatalog =
    map fst availableChecks
        == [ "compiler"
           , "format.trailingWhitespace"
           , "format.mixedLineEndings"
           , "format.missingFinalNewline"
           ]

-- The body of @Main@ in a program that declares what the cases below use.
currentProgram :: String -> String
currentProgram body =
    unlines
        [ "namespace Demo;"
        , "enum Color { Red, Green }"
        , "public class Other {"
        , "    public static int Pick(_ int v) { return v + 10; }"
        , "    public static int Pick(_ int v, _ int w) { return v + w; }"
        , "}"
        , "public class Program {"
        , "    public static int Log(_ int v) { Console.Println(v); return v; }"
        , "    public static int Run(_ (int) -> int f) { return f(3); }"
        , "    public static void Main() {"
        , "        " ++ body
        , "    }"
        , "}"
        ]

ruleIdsOf :: String -> [String]
ruleIdsOf body = map lintRuleId (lintSource (CompilerInput "Program.tala" (currentProgram body)))

currentFormsAreClean :: Bool
currentFormsAreClean =
    null
        ( ruleIdsOf
            ( concat
                [ "auto held = Demo.Program::Log; "
                , "int first = Run(Program::Log) + Run(Other::Pick) + Demo.Program.Log(1); "
                , "String kind = held(first) > 0 ? \"some\" : \"none\"; "
                , "Color chosen = Demo.Color.Green; "
                , "Console.Printfn(\"%s %b %05d\", kind, chosen == Color.Green, first);"
                ]
            )
        )

dottedSelectorIsReported :: Bool
dottedSelectorIsReported = "compiler.TAT0034" `elem` ruleIdsOf "auto held = Program.Log;"

ambiguousReferenceIsReported :: Bool
ambiguousReferenceIsReported = "compiler.TAT0080" `elem` ruleIdsOf "auto held = Other::Pick;"

boundReferenceIsReported :: Bool
boundReferenceIsReported = "compiler.TAT0081" `elem` ruleIdsOf "int value = 1; auto held = value::Pick;"

formatMismatchIsReported :: Bool
formatMismatchIsReported = any (`elem` ruleIdsOf "Console.Printf(\"%d\", \"text\");") ["compiler.TAT0077", "compiler.TAT0078"]

safeFixesKeepReferences :: Bool
safeFixesKeepReferences =
    case applySafeFixes (CompilerInput "Program.tala" (currentProgram "auto held = Demo.Program::Log;   ")) of
        Right result ->
            formattingChanged result
                && lines (formattedSource result) !! 10 == "        auto held = Demo.Program::Log;"
                && null (lintSource (CompilerInput "Program.tala" (formattedSource result)))
        Left _ -> False
