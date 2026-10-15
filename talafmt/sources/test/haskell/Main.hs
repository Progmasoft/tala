-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Main (main) where

import System.Exit (exitFailure)
import CommandLineTests
import Progmasoft.Talafmt
import Progmasoft.Talafmt.Encoding
import Progmasoft.Tala.Diagnostic (diagnosticCode)
import Progmasoft.Tala.Frontend

main :: IO ()
main = do
    mapM_ (uncurry check) commandLineTests
    check "formatter removes trailing whitespace and preserves the first line ending" normalizesLayout
    check "formatter reports an already formatted source as unchanged" unchangedSource
    check "formatter refuses malformed source" rejectsMalformedSource
    check "formatter indents nested declaration and control-flow braces" indentsNestedBlocks
    check "formatter aligns closing braces before else" alignsClosingBrace
    check "formatter ignores braces in normal strings" ignoresStringBraces
    check "formatter ignores braces in character literals" ignoresCharacterBraces
    check "formatter ignores braces in line comments" ignoresLineCommentBraces
    check "formatter preserves multi-line raw string payload indentation" preservesRawStringPayload
    check "formatter preserves multi-line long comment indentation" preservesLongCommentPayload
    check "formatter indents standalone comments with their block" indentsStandaloneComments
    check "formatter emits tabs without changing logical indentation" emitsTabs
    check "formatter honors an explicit LF line ending" emitsLf
    check "formatter honors an explicit CRLF line ending" emitsCrLf
    check "disabled block indentation keeps leading whitespace" disablesReindent
    check "disabled final-newline insertion preserves an existing newline" preservesExistingFinalNewline
    check "disabled final-newline insertion leaves missing newline absent" leavesFinalNewlineAbsent
    check "formatter rejects a non-positive indentation width" rejectsIndentWidth
    check "formatter rejects a non-positive tab width" rejectsTabWidth
    check "block formatting reaches a fixed point" formattingIsIdempotent
    check "pattern combinators remain intact while their block is indented" formatsPatternCombinators
    check "match arms, value blocks and nested blocks are indented by their braces" formatsBranchingForms
    check "method references and names through the namespace are kept as written" formatsMethodReferences
    check "a conditional over strings keeps its strings and its colon" formatsStringConditional
    check "console formats keep their percent signs and their braces" formatsConsoleFormats
    check "a source with the forms of 0.5.0 reaches a fixed point" currentFormsAreIdempotent
    checkIO "encoding conversion follows explicit input and output settings" encodingRoundTrip
    checkIO "UTF-8 input rejects malformed byte sequences" rejectsMalformedUtf8

check :: String -> Bool -> IO ()
check label passed = if passed then putStrLn ("PASS: " ++ label) else putStrLn ("FAIL: " ++ label) >> exitFailure

checkIO :: String -> IO Bool -> IO ()
checkIO label action = action >>= check label

encodingRoundTrip :: IO Bool
encodingRoundTrip = do
    let expected = "class Program {}\n"
        encoded = encodeSourceText Utf16 True expected
    decoded <- decodeSourceBytes Utf16 encoded
    pure (decoded == Right expected)

rejectsMalformedUtf8 :: IO Bool
rejectsMalformedUtf8 = do
    decoded <- decodeSourceBytes Utf8 (encodeSourceText Utf16 False "not UTF-8: \x1f642")
    pure $ case decoded of
        Left _ -> True
        Right _ -> False

formattedProgram :: String
formattedProgram =
    "namespace Example;\r\npublic class Program {\r\n    public static void Main() {\r\n        return;\r\n    }\r\n}\r\n"

normalizesLayout :: Bool
normalizesLayout =
    let source =
            "namespace Example;  \r\npublic class Program {\n    public static void Main() {\t\r\n        return;\r\n    }\r\n}\r\n"
     in case formatSource defaultFormatOptions (CompilerInput "Program.tala" source) of
            Right result -> formattedSource result == formattedProgram && formattingChanged result
            Left _ -> False

unchangedSource :: Bool
unchangedSource = case formatSource defaultFormatOptions (CompilerInput "Program.tala" formattedProgram) of
    Right result -> not (formattingChanged result)
    Left _ -> False

rejectsMalformedSource :: Bool
rejectsMalformedSource = case formatSource defaultFormatOptions (CompilerInput "Broken.tala" "@   ") of
    Left _ -> True
    Right _ -> False

nestedInput :: String
nestedInput =
    unlines
        [ "class Program {"
        , "public static void Main() {"
        , "if (true) {"
        , "return;"
        , "} else {"
        , "return;"
        , "}"
        , "}"
        , "}"
        ]

nestedExpected :: String
nestedExpected =
    unlines
        [ "class Program {"
        , "    public static void Main() {"
        , "        if (true) {"
        , "            return;"
        , "        } else {"
        , "            return;"
        , "        }"
        , "    }"
        , "}"
        ]

indentsNestedBlocks :: Bool
indentsNestedBlocks = formats defaultFormatOptions nestedInput nestedExpected

alignsClosingBrace :: Bool
alignsClosingBrace =
    formats
        defaultFormatOptions
        "class Program {\n        public void Run() {\n }\n}\n"
        "class Program {\n    public void Run() {\n    }\n}\n"

ignoresStringBraces :: Bool
ignoresStringBraces =
    formats
        defaultFormatOptions
        "class Program {\nString Text() {\nreturn \"} {\";\n}\n}\n"
        "class Program {\n    String Text() {\n        return \"} {\";\n    }\n}\n"

ignoresCharacterBraces :: Bool
ignoresCharacterBraces =
    formats
        defaultFormatOptions
        "class Program {\nchar Marker() {\nreturn '}';\n}\n}\n"
        "class Program {\n    char Marker() {\n        return '}';\n    }\n}\n"

ignoresLineCommentBraces :: Bool
ignoresLineCommentBraces =
    formats
        defaultFormatOptions
        "class Program {\n-- } does not close Program\nvoid Run() {\nreturn;\n}\n}\n"
        "class Program {\n    -- } does not close Program\n    void Run() {\n        return;\n    }\n}\n"

preservesRawStringPayload :: Bool
preservesRawStringPayload =
    let source =
            "class Program {\n"
                ++ "    String Text() {\n"
                ++ "        auto value = [=[\n"
                ++ "  raw indentation { is data\n"
                ++ " closing indentation } stays\n"
                ++ "]=];\n"
                ++ "return value;\n"
                ++ "}\n"
                ++ "}\n"
        expected =
            "class Program {\n"
                ++ "    String Text() {\n"
                ++ "        auto value = [=[\n"
                ++ "  raw indentation { is data\n"
                ++ " closing indentation } stays\n"
                ++ "]=];\n"
                ++ "        return value;\n"
                ++ "    }\n"
                ++ "}\n"
     in formats defaultFormatOptions source expected

preservesLongCommentPayload :: Bool
preservesLongCommentPayload =
    let source =
            "class Program {\n"
                ++ "    --[=[ heading\n"
                ++ " raw comment indentation {\n"
                ++ " } remains\n"
                ++ "]=]\n"
                ++ "void Run() { return; }\n"
                ++ "}\n"
        expected =
            "class Program {\n"
                ++ "    --[=[ heading\n"
                ++ " raw comment indentation {\n"
                ++ " } remains\n"
                ++ "]=]\n"
                ++ "    void Run() { return; }\n"
                ++ "}\n"
     in formats defaultFormatOptions source expected

indentsStandaloneComments :: Bool
indentsStandaloneComments =
    formats
        defaultFormatOptions
        "class Program {\n-- member documentation\nvoid Run() { return; }\n}\n"
        "class Program {\n    -- member documentation\n    void Run() { return; }\n}\n"

emitsTabs :: Bool
emitsTabs =
    let options = defaultFormatOptions {formatUseTabs = True, formatIndentWidth = 4, formatTabWidth = 4}
     in formats
            options
            "class Program {\nvoid Run() {\nreturn;\n}\n}\n"
            "class Program {\n\tvoid Run() {\n\t\treturn;\n\t}\n}\n"

emitsLf :: Bool
emitsLf =
    formats
        defaultFormatOptions {formatLineEnding = Lf}
        "class Program {}\r\n"
        "class Program {}\n"

emitsCrLf :: Bool
emitsCrLf =
    formats
        defaultFormatOptions {formatLineEnding = CrLf}
        "class Program {}\n"
        "class Program {}\r\n"

disablesReindent :: Bool
disablesReindent =
    let options = defaultFormatOptions {formatReindentBlocks = False}
     in formats options "class Program {\n void Run() { return; }\n}\n" "class Program {\n void Run() { return; }\n}\n"

preservesExistingFinalNewline :: Bool
preservesExistingFinalNewline =
    let options = defaultFormatOptions {formatInsertFinalNewline = False}
     in formats options "class Program {}\n" "class Program {}\n"

leavesFinalNewlineAbsent :: Bool
leavesFinalNewlineAbsent =
    let options = defaultFormatOptions {formatInsertFinalNewline = False}
     in formats options "class Program {}" "class Program {}"

rejectsIndentWidth :: Bool
rejectsIndentWidth = rejectsOptions defaultFormatOptions {formatIndentWidth = 0}

rejectsTabWidth :: Bool
rejectsTabWidth = rejectsOptions defaultFormatOptions {formatTabWidth = 0}

formattingIsIdempotent :: Bool
formattingIsIdempotent = case formatSource defaultFormatOptions (CompilerInput "Program.tala" nestedInput) of
    Right first -> case formatSource defaultFormatOptions (CompilerInput "Program.tala" (formattedSource first)) of
        Right second -> not (formattingChanged second) && formattedSource second == formattedSource first
        Left _ -> False
    Left _ -> False

formatsPatternCombinators :: Bool
formatsPatternCombinators =
    formats
        defaultFormatOptions
        "class Program {\nbool Match(_ String value) {\nreturn value is null or String and not null;\n}\n}\n"
        "class Program {\n    bool Match(_ String value) {\n        return value is null or String and not null;\n    }\n}\n"

-- The layout follows braces only, so the arms of a match, the blocks of an
-- if expression and of a guard, and a nested block indent like any other
-- block, and an expression arm keeps the depth of its match.
formatsBranchingForms :: Bool
formatsBranchingForms =
    formats
        defaultFormatOptions
        ( concat
            [ "class Program {\n"
            , "int Kind(_ int code) {\n"
            , "guard (code >= 0) else {\n"
            , "return 0;\n"
            , "}\n"
            , "{\n"
            , "int unused = code;\n"
            , "}\n"
            , "int larger = if (code > 5) {\n"
            , "code\n"
            , "} else {\n"
            , "5\n"
            , "};\n"
            , "return match (code) {\n"
            , "0 -> 10,\n"
            , "int other if other > larger -> {\n"
            , "other * 2\n"
            , "},\n"
            , "_ -> 30\n"
            , "};\n"
            , "}\n"
            , "}\n"
            ]
        )
        ( concat
            [ "class Program {\n"
            , "    int Kind(_ int code) {\n"
            , "        guard (code >= 0) else {\n"
            , "            return 0;\n"
            , "        }\n"
            , "        {\n"
            , "            int unused = code;\n"
            , "        }\n"
            , "        int larger = if (code > 5) {\n"
            , "            code\n"
            , "        } else {\n"
            , "            5\n"
            , "        };\n"
            , "        return match (code) {\n"
            , "            0 -> 10,\n"
            , "            int other if other > larger -> {\n"
            , "                other * 2\n"
            , "            },\n"
            , "            _ -> 30\n"
            , "        };\n"
            , "    }\n"
            , "}\n"
            ]
        )

formats :: FormatOptions -> String -> String -> Bool
formats options source expected = case formatSource options (CompilerInput "Program.tala" source) of
    Right result -> formattedSource result == expected
    Left _ -> False

rejectsOptions :: FormatOptions -> Bool
rejectsOptions options = case formatSource options (CompilerInput "Program.tala" "class Program {}") of
    Left [problem] -> diagnosticCode problem == "TAF0001"
    _ -> False

-- `::` is one token of the language; the formatter must neither split it
-- nor take a part of a qualified name for something to lay out.
formatsMethodReferences :: Bool
formatsMethodReferences =
    formats
        defaultFormatOptions
        ( concat
            [ "namespace Demo;\n"
            , "public class Program {\n"
            , "public static int Log(_ int v) { return v; }\n"
            , "public static int Run(_ (int) -> int f) {\n"
            , "return f(3);\n"
            , "}\n"
            , "public static void Main() {\n"
            , "auto held = Program::Log;\n"
            , "int first = Run(Demo.Program::Log);\n"
            , "int second = Demo.Program.Log(1);\n"
            , "}\n"
            , "}\n"
            ]
        )
        ( concat
            [ "namespace Demo;\n"
            , "public class Program {\n"
            , "    public static int Log(_ int v) { return v; }\n"
            , "    public static int Run(_ (int) -> int f) {\n"
            , "        return f(3);\n"
            , "    }\n"
            , "    public static void Main() {\n"
            , "        auto held = Program::Log;\n"
            , "        int first = Run(Demo.Program::Log);\n"
            , "        int second = Demo.Program.Log(1);\n"
            , "    }\n"
            , "}\n"
            ]
        )

formatsStringConditional :: Bool
formatsStringConditional =
    formats
        defaultFormatOptions
        ( concat
            [ "class Program {\n"
            , "static String Kind(_ int count) {\n"
            , "String kind = count > 0 ? \"some { \" : \"none } \";\n"
            , "return count > 9\n"
            , "? kind + \"!\"\n"
            , ": kind;\n"
            , "}\n"
            , "}\n"
            ]
        )
        ( concat
            [ "class Program {\n"
            , "    static String Kind(_ int count) {\n"
            , "        String kind = count > 0 ? \"some { \" : \"none } \";\n"
            , "        return count > 9\n"
            , "        ? kind + \"!\"\n"
            , "        : kind;\n"
            , "    }\n"
            , "}\n"
            ]
        )

formatsConsoleFormats :: Bool
formatsConsoleFormats =
    formats
        defaultFormatOptions
        ( concat
            [ "class Program {\n"
            , "static void Main() {\n"
            , "Console.Printfn(\"{%05d} %'d %-8s| %.2f %%\", 42, 1234567, \"ab\", 3.14159);\n"
            , "String made = Console.Format(\"%*d}\", 5, 42);\n"
            , "Console.Errorln(made + \"{\");\n"
            , "}\n"
            , "}\n"
            ]
        )
        ( concat
            [ "class Program {\n"
            , "    static void Main() {\n"
            , "        Console.Printfn(\"{%05d} %'d %-8s| %.2f %%\", 42, 1234567, \"ab\", 3.14159);\n"
            , "        String made = Console.Format(\"%*d}\", 5, 42);\n"
            , "        Console.Errorln(made + \"{\");\n"
            , "    }\n"
            , "}\n"
            ]
        )

currentFormsAreIdempotent :: Bool
currentFormsAreIdempotent =
    case formatSource defaultFormatOptions (CompilerInput "Program.tala" source) of
        Right first -> case formatSource defaultFormatOptions (CompilerInput "Program.tala" (formattedSource first)) of
            Right second -> formattingChanged first && not (formattingChanged second)
            Left _ -> False
        Left _ -> False
    where
        source =
            concat
                [ "namespace Demo;\n"
                , "enum Color { Red, Green }\n"
                , "public class Program {\n"
                , "public static int Log(_ int v) { Console.Println(v); return v; }\n"
                , "public static void Main() {\n"
                , "auto held = Demo.Program::Log;\n"
                , "String kind = held(1) > 0 ? \"some\" : \"none\";\n"
                , "Color chosen = match (held(2)) {\n"
                , "0 -> Demo.Color.Red,\n"
                , "_ -> .Green\n"
                , "};\n"
                , "Console.Printfn(\"%s %b\", kind, chosen == Color.Green);\n"
                , "}\n"
                , "}\n"
                ]
