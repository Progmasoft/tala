-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | The command line of @talalint@ as values.

@
talalint Program.tala          report what the linter finds
talalint Program.tala --fix    apply the safe fixes, then report what is left
@

The parser is written by hand. Every accepted line is a 'Command' and every
rejected one a 'CommandLineError': nothing later in the program looks at an
argument string again.
-}
module Progmasoft.Talalint.CommandLine
    ( Command (..)
    , Mode (..)
    , CommandLineError (..)
    , parseCommandLine
    , renderCommandLineError
    , usageText
    ) where

import Data.List (stripPrefix)
import Data.List.NonEmpty (NonEmpty (..))

-- | Whether the linter may change the files it reads.
data Mode
    = -- | Report and change nothing.
      Report
    | -- | Apply the fixes that cannot change what a program does, then report.
      Fix
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

-- | One invocation of the linter.
data Command
    = ShowHelp
    | ShowVersion
    | Lint Mode (NonEmpty FilePath)
    deriving (Eq, Ord, Read, Show)

-- | Why a command line is not a 'Command'.
data CommandLineError
    = -- | An argument that starts with a dash and is not an option.
      UnknownOption String
    | -- | An option that takes no value was given one.
      UnexpectedValue String
    | -- | The same option written twice.
      RepeatedOption String
    | -- | No file was named.
      NoInput
    deriving (Eq, Ord, Read, Show)

{- | Read the arguments of one invocation, the program name excluded.

@--help@ and @--version@ win over everything written after them. After
@--@ every argument is a file, even one that starts with a dash.
-}
parseCommandLine :: [String] -> Either CommandLineError Command
parseCommandLine = go Report False [] False
    where
        go mode _ files _ [] = case reverse files of
            [] -> Left NoInput
            first : others -> Right (Lint mode (first :| others))
        go mode fixSeen files onlyFiles (argument : rest)
            | onlyFiles = go mode fixSeen (argument : files) True rest
            | argument == "--" = go mode fixSeen files True rest
            | Just option <- stripPrefix "--" argument = case break (== '=') option of
                ("help", "") -> Right ShowHelp
                ("version", "") -> Right ShowVersion
                ("fix", "")
                    | fixSeen -> Left (RepeatedOption "--fix")
                    | otherwise -> go Fix True files False rest
                (name, '=' : _)
                    | name `elem` ["help", "version", "fix"] -> Left (UnexpectedValue ("--" ++ name))
                (name, _) -> Left (UnknownOption ("--" ++ name))
            | argument == "-h" = Right ShowHelp
            | argument == "-v" = Right ShowVersion
            | isOption argument = Left (UnknownOption argument)
            | otherwise = go mode fixSeen (argument : files) False rest

-- | A single dash is a file name; anything longer that starts with one is an option.
isOption :: String -> Bool
isOption argument = case argument of
    '-' : _ : _ -> True
    _ -> False

-- | The sentence a user reads for a rejected command line.
renderCommandLineError :: CommandLineError -> String
renderCommandLineError problem = case problem of
    UnknownOption option -> "unknown option '" ++ option ++ "'; use --help for usage"
    UnexpectedValue option -> option ++ " does not take a value"
    RepeatedOption option -> option ++ " may be written only once"
    NoInput -> "a source file is required; use --help for usage"

-- | The help of the linter.
usageText :: String
usageText =
    unlines
        [ "Usage: talalint <file.tala>... [--fix]"
        , ""
        , "talalint reports what it finds in each file and changes none."
        , ""
        , "  --fix          apply the safe fixes, then report what is left"
        , "  --help, -h     print this help"
        , "  --version, -v  print the version of talalint"
        ]
