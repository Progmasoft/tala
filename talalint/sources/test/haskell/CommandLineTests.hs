-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

-- | The command line of the linter.
module CommandLineTests (commandLineTests) where

import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Progmasoft.Talalint.CommandLine

commandLineTests :: [(String, Bool)]
commandLineTests =
    [ ("a file alone is reported on", parseCommandLine ["Program.tala"] == Right (Lint Report ("Program.tala" :| [])))
    , ("--fix applies the safe fixes", parseCommandLine ["Program.tala", "--fix"] == Right (Lint Fix ("Program.tala" :| [])))
    , ("--fix may stand before the file", parseCommandLine ["--fix", "A.tala"] == Right (Lint Fix ("A.tala" :| [])))
    , ("several files keep their order", parseCommandLine ["B.tala", "--fix", "A.tala"] == Right (Lint Fix ("B.tala" :| ["A.tala"])))
    , ("help and version are recognized in both forms", helpAndVersion)
    , ("help wins over what follows it", parseCommandLine ["--help", "--no-such"] == Right ShowHelp)
    , ("a file is required", parseCommandLine [] == Left NoInput && parseCommandLine ["--fix"] == Left NoInput)
    , ("--fix may be written only once", parseCommandLine ["A.tala", "--fix", "--fix"] == Left (RepeatedOption "--fix"))
    , ("--fix takes no value", parseCommandLine ["A.tala", "--fix=all"] == Left (UnexpectedValue "--fix"))
    , ("an unknown option is rejected by its name", unknownOptions)
    , ("the options the linter had before are no longer options", oldOptions)
    , ("after a double dash everything is a file", parseCommandLine ["--", "--fix", "-odd.tala"] == Right (Lint Report ("--fix" :| ["-odd.tala"])))
    , ("a lone dash is a file name", parseCommandLine ["-"] == Right (Lint Report ("-" :| [])))
    , ("every rejection has a sentence that names what was wrong", rejectionsAreExplained)
    , ("the help names the option", "--fix" `isInfixOf` usageText)
    ]

helpAndVersion :: Bool
helpAndVersion =
    map parseCommandLine [["--help"], ["-h"], ["A.tala", "--help"]] == replicate 3 (Right ShowHelp)
        && map parseCommandLine [["--version"], ["-v"]] == replicate 2 (Right ShowVersion)
        && parseCommandLine ["--version=1"] == Left (UnexpectedValue "--version")

unknownOptions :: Bool
unknownOptions =
    parseCommandLine ["A.tala", "--check"] == Left (UnknownOption "--check")
        && parseCommandLine ["A.tala", "--check=yes"] == Left (UnknownOption "--check")
        && parseCommandLine ["A.tala", "-f"] == Left (UnknownOption "-f")

oldOptions :: Bool
oldOptions =
    parseCommandLine ["-Fix", "A.tala"] == Left (UnknownOption "-Fix")
        && parseCommandLine ["-List-Checks"] == Left (UnknownOption "-List-Checks")
        && parseCommandLine ["-Help"] == Left (UnknownOption "-Help")

rejectionsAreExplained :: Bool
rejectionsAreExplained =
    and
        [ part `isInfixOf` renderCommandLineError problem
        | (problem, part) <-
            [ (UnknownOption "--check", "'--check'")
            , (UnexpectedValue "--fix", "--fix does not take a value")
            , (RepeatedOption "--fix", "only once")
            , (NoInput, "source file")
            ]
        ]
