-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

-- | The command line of the formatter and the reports it writes.
module CommandLineTests (commandLineTests) where

import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Progmasoft.Talafmt.CommandLine
import Progmasoft.Talafmt.Report

commandLineTests :: [(String, Bool)]
commandLineTests =
    [ ("a file alone is formatted in place", parseCommandLine ["Program.tala"] == Right (Format (Emit EmitFiles) ("Program.tala" :| [])))
    , ("--check reports and writes nothing", parseCommandLine ["Program.tala", "--check"] == Right (Format Check ("Program.tala" :| [])))
    , ("every --emit choice is spelled as documented", everyEmitChoice)
    , ("an option may stand before the file", parseCommandLine ["--emit=stdout", "A.tala"] == Right (Format (Emit EmitStdout) ("A.tala" :| [])))
    , ("several files keep their order", parseCommandLine ["B.tala", "--check", "A.tala"] == Right (Format Check ("B.tala" :| ["A.tala"])))
    , ("help and version are recognized in both forms", helpAndVersion)
    , ("help wins over what follows it", parseCommandLine ["--help", "--no-such"] == Right ShowHelp)
    , ("a file is required", parseCommandLine [] == Left NoInput && parseCommandLine ["--check"] == Left NoInput)
    , ("--emit needs a value after an equals sign", parseCommandLine ["A.tala", "--emit"] == Left (MissingValue "--emit"))
    , ("a value in the next argument is a file, not a value", parseCommandLine ["A.tala", "--emit", "json"] == Left (MissingValue "--emit"))
    , ("a value outside the choices is rejected with the value", parseCommandLine ["A.tala", "--emit=diff"] == Left (InvalidValue "--emit" "diff"))
    , ("choices are case-sensitive", parseCommandLine ["A.tala", "--emit=JSON"] == Left (InvalidValue "--emit" "JSON"))
    , ("an option may be written only once", repeatedOptions)
    , ("--check cannot be combined with --emit", parseCommandLine ["A.tala", "--check", "--emit=json"] == Left CheckWithEmit)
    , ("--check takes no value", parseCommandLine ["A.tala", "--check=true"] == Left (UnexpectedValue "--check"))
    , ("an unknown option is rejected by its name", unknownOptions)
    , ("the options the formatter had before are no longer options", parseCommandLine ["-In-Place", "A.tala"] == Left (UnknownOption "-In-Place"))
    , ("after a double dash everything is a file", parseCommandLine ["--", "--check", "-odd.tala"] == Right (Format (Emit EmitFiles) ("--check" :| ["-odd.tala"])))
    , ("a lone dash is a file name", parseCommandLine ["-"] == Right (Format (Emit EmitFiles) ("-" :| [])))
    , ("every rejection has a sentence that names what was wrong", rejectionsAreExplained)
    , ("the help lists every --emit choice", all (\emit -> ("--emit=" ++ emitName emit) `isInfixOf` usageText) [minBound .. maxBound])
    , ("a formatted text has no mismatch", null (mismatches "a\nb\n" "a\nb\n"))
    , ("changed lines of equal count are named run by run", changedRuns)
    , ("a missing final newline is one mismatch after the last line", missingFinalNewline)
    , ("a removed line is found between the common beginning and end", removedLine)
    , ("coverage counts the lines outside every mismatch", coverageCounts)
    , ("coverage of an empty file is complete", renderCoverage [fileReport "E.tala" "" ""] == "E.tala: 0 of 0 lines formatted (100%)\n")
    , ("checkstyle names the file and the line and escapes its text", checkstyleReport)
    , ("JSON lists only the files that have mismatches", jsonReport)
    , ("JSON escapes quotes, backslashes and control characters", jsonEscapes)
    ]

everyEmitChoice :: Bool
everyEmitChoice =
    and
        [ parseCommandLine ["A.tala", "--emit=" ++ name] == Right (Format (Emit emit) ("A.tala" :| []))
        | (name, emit) <-
            [ ("files", EmitFiles)
            , ("stdout", EmitStdout)
            , ("coverage", EmitCoverage)
            , ("checkstyle", EmitCheckstyle)
            , ("json", EmitJson)
            ]
        ]
        && map emitName [minBound .. maxBound] == ["files", "stdout", "coverage", "checkstyle", "json"]

helpAndVersion :: Bool
helpAndVersion =
    map parseCommandLine [["--help"], ["-h"], ["A.tala", "--help"]] == replicate 3 (Right ShowHelp)
        && map parseCommandLine [["--version"], ["-v"]] == replicate 2 (Right ShowVersion)
        && parseCommandLine ["--help=all"] == Left (UnexpectedValue "--help")

repeatedOptions :: Bool
repeatedOptions =
    parseCommandLine ["A.tala", "--check", "--check"] == Left (RepeatedOption "--check")
        && parseCommandLine ["A.tala", "--emit=json", "--emit=stdout"] == Left (RepeatedOption "--emit")

unknownOptions :: Bool
unknownOptions =
    parseCommandLine ["A.tala", "--write"] == Left (UnknownOption "--write")
        && parseCommandLine ["A.tala", "--write=yes"] == Left (UnknownOption "--write")
        && parseCommandLine ["A.tala", "-c"] == Left (UnknownOption "-c")

rejectionsAreExplained :: Bool
rejectionsAreExplained =
    and
        [ part `isInfixOf` renderCommandLineError problem
        | (problem, part) <-
            [ (UnknownOption "--write", "'--write'")
            , (MissingValue "--emit", "--emit=files|stdout|coverage|checkstyle|json")
            , (UnexpectedValue "--check", "--check does not take a value")
            , (InvalidValue "--emit" "diff", "'diff'")
            , (RepeatedOption "--emit", "only once")
            , (CheckWithEmit, "--emit")
            , (NoInput, "source file")
            ]
        ]

changedRuns :: Bool
changedRuns =
    mismatches "a\n  b\n  c\nd\n e\n" "a\nb\nc\nd\ne\n"
        == [ Mismatch 2 3 2 3 ["  b", "  c"] ["b", "c"]
           , Mismatch 5 5 5 5 [" e"] ["e"]
           ]

missingFinalNewline :: Bool
missingFinalNewline = mismatches "a\nb" "a\nb\n" == [Mismatch 3 2 3 3 [] [""]]

removedLine :: Bool
removedLine = mismatches "a\n\n\nb\n" "a\n\nb\n" == [Mismatch 3 3 3 2 [""] []]

coverageCounts :: Bool
coverageCounts =
    coverage report == Coverage 2 5
        && renderCoverage [report] == "P.tala: 2 of 5 lines formatted (40%)\n"
    where
        report = fileReport "P.tala" "a\n  b\n  c\nd\n e\n" "a\nb\nc\nd\ne\n"

checkstyleReport :: Bool
checkstyleReport =
    all
        (`isInfixOf` rendered)
        [ "<checkstyle version=\"4.3\">"
        , "<file name=\"A&amp;B.tala\">"
        , "<error line=\"2\" severity=\"warning\" source=\"talafmt\" message=\"should be `if (a &lt; b) {`\" />"
        , "</checkstyle>"
        ]
    where
        rendered = renderCheckstyle [fileReport "A&B.tala" "x\n  if (a < b) {\n" "x\nif (a < b) {\n"]

jsonReport :: Bool
jsonReport =
    renderJson [fileReport "Clean.tala" "a\n" "a\n", fileReport "P.tala" "a\n b\n" "a\nb\n"]
        == "[{\"name\":\"P.tala\",\"mismatches\":[{\"original_begin_line\":2,\"original_end_line\":2,"
            ++ "\"expected_begin_line\":2,\"expected_end_line\":2,\"original\":\" b\",\"expected\":\"b\"}]}]\n"
        && renderJson [fileReport "Clean.tala" "a\n" "a\n"] == "[]\n"

jsonEscapes :: Bool
jsonEscapes =
    "\"original\":\"\\t\\\"a\\\\b\\\"\\r\"" `isInfixOf` rendered && "\"expected\":\"\\u0001\"" `isInfixOf` rendered
    where
        rendered = renderJson [fileReport "P.tala" "\t\"a\\b\"\r\n" "\SOH\n"]
