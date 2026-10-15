-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | The command line of @talafmt@ as values.

@
talafmt Program.tala                    format the file in place
talafmt Program.tala --check            say whether it needs formatting
talafmt Program.tala --emit=files       write the formatted file over it
talafmt Program.tala --emit=stdout      print the formatted text
talafmt Program.tala --emit=coverage    report how much is formatted
talafmt Program.tala --emit=checkstyle  report in the checkstyle format
talafmt Program.tala --emit=json        report the differences as JSON
@

The parser is written by hand. Every accepted line is a 'Command' and every
rejected one a 'CommandLineError': nothing later in the program looks at an
argument string again.
-}
module Progmasoft.Talafmt.CommandLine
    ( Command (..)
    , Action (..)
    , Emit (..)
    , CommandLineError (..)
    , parseCommandLine
    , renderCommandLineError
    , emitName
    , usageText
    ) where

import Data.List (intercalate, stripPrefix)
import Data.List.NonEmpty (NonEmpty (..))

-- | Where the formatted text, or the report about it, goes.
data Emit
    = -- | Write the formatted text over the file. Nothing is printed.
      EmitFiles
    | -- | Print the formatted text. No file changes.
      EmitStdout
    | -- | Report how many lines are already formatted. No file changes.
      EmitCoverage
    | -- | Report the lines that would change as checkstyle XML.
      EmitCheckstyle
    | -- | Report the differences as JSON. No file changes.
      EmitJson
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

-- | What one invocation does with every file it was given.
data Action
    = -- | Say which files need formatting and touch none of them.
      Check
    | -- | Format and send the result where 'Emit' says.
      Emit Emit
    deriving (Eq, Ord, Read, Show)

-- | One invocation of the formatter.
data Command
    = ShowHelp
    | ShowVersion
    | Format Action (NonEmpty FilePath)
    deriving (Eq, Ord, Read, Show)

-- | Why a command line is not a 'Command'.
data CommandLineError
    = -- | An argument that starts with a dash and is not an option.
      UnknownOption String
    | -- | @--emit@ without @=value@.
      MissingValue String
    | -- | An option that takes no value was given one.
      UnexpectedValue String
    | -- | A value outside the choices of its option.
      InvalidValue String String
    | -- | The same option written twice.
      RepeatedOption String
    | -- | @--check@ together with @--emit@.
      CheckWithEmit
    | -- | No file was named.
      NoInput
    deriving (Eq, Ord, Read, Show)

-- | The spelling of an 'Emit' on the command line.
emitName :: Emit -> String
emitName emit = case emit of
    EmitFiles -> "files"
    EmitStdout -> "stdout"
    EmitCoverage -> "coverage"
    EmitCheckstyle -> "checkstyle"
    EmitJson -> "json"

emitChoices :: String
emitChoices = intercalate "|" (map emitName [minBound .. maxBound])

-- | What was seen so far while the arguments are read from left to right.
data Seen = Seen
    { seenCheck :: Bool
    , seenEmit :: Maybe Emit
    , seenFiles :: [FilePath]
    -- ^ In reverse order.
    , seenOnlyFiles :: Bool
    -- ^ True after @--@: what follows is a file even if it starts with a dash.
    }

{- | Read the arguments of one invocation, the program name excluded.

@--help@ and @--version@ win over everything written after them, so that a
line that is otherwise wrong can still ask what would be right.
-}
parseCommandLine :: [String] -> Either CommandLineError Command
parseCommandLine = go (Seen False Nothing [] False)
    where
        go seen [] = finish seen
        go seen (argument : rest)
            | seenOnlyFiles seen = go (addFile argument seen) rest
            | argument == "--" = go seen {seenOnlyFiles = True} rest
            | Just option <- stripPrefix "--" argument = longOption seen option rest
            | argument == "-h" = Right ShowHelp
            | argument == "-v" = Right ShowVersion
            | isOption argument = Left (UnknownOption argument)
            | otherwise = go (addFile argument seen) rest

        longOption seen option rest = case break (== '=') option of
            ("help", "") -> Right ShowHelp
            ("version", "") -> Right ShowVersion
            ("check", "")
                | seenCheck seen -> Left (RepeatedOption "--check")
                | otherwise -> go seen {seenCheck = True} rest
            ("emit", '=' : value)
                | Just _ <- seenEmit seen -> Left (RepeatedOption "--emit")
                | otherwise -> case lookup value [(emitName emit, emit) | emit <- [minBound .. maxBound]] of
                    Just emit -> go seen {seenEmit = Just emit} rest
                    Nothing -> Left (InvalidValue "--emit" value)
            ("emit", "") -> Left (MissingValue "--emit")
            (name, '=' : _)
                | name `elem` ["help", "version", "check"] -> Left (UnexpectedValue ("--" ++ name))
            (name, _) -> Left (UnknownOption ("--" ++ name))

        finish seen = case (reverse (seenFiles seen), seenCheck seen, seenEmit seen) of
            (_, True, Just _) -> Left CheckWithEmit
            ([], _, _) -> Left NoInput
            (first : others, True, Nothing) -> Right (Format Check (first :| others))
            (first : others, False, emit) -> Right (Format (Emit (maybe EmitFiles id emit)) (first :| others))

        addFile file seen = seen {seenFiles = file : seenFiles seen}

-- | A single dash is a file name; anything longer that starts with one is an option.
isOption :: String -> Bool
isOption argument = case argument of
    '-' : _ : _ -> True
    _ -> False

-- | The sentence a user reads for a rejected command line.
renderCommandLineError :: CommandLineError -> String
renderCommandLineError problem = case problem of
    UnknownOption option -> "unknown option '" ++ option ++ "'; use --help for usage"
    MissingValue option -> option ++ " requires a value: " ++ option ++ "=" ++ emitChoices
    UnexpectedValue option -> option ++ " does not take a value"
    InvalidValue option value -> "invalid value '" ++ value ++ "' for " ++ option ++ "; expected " ++ emitChoices
    RepeatedOption option -> option ++ " may be written only once"
    CheckWithEmit -> "--check reports and writes nothing; it cannot be combined with --emit"
    NoInput -> "a source file is required; use --help for usage"

-- | The help of the formatter.
usageText :: String
usageText =
    unlines
        [ "Usage: talafmt <file.tala>... [--check | --emit=" ++ emitChoices ++ "]"
        , ""
        , "Without an option talafmt formats each file in place and prints nothing."
        , ""
        , "  --check            say which files need formatting and change none"
        , "  --emit=files       write the formatted text over each file (the default)"
        , "  --emit=stdout      print the formatted text and change no file"
        , "  --emit=coverage    report how many lines are already formatted"
        , "  --emit=checkstyle  report the lines that would change as checkstyle XML"
        , "  --emit=json        report the differences as JSON"
        , "  --help, -h         print this help"
        , "  --version, -v      print the version of talafmt"
        ]
