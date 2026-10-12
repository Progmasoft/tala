-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Main (main) where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import System.Environment (getArgs)
import Data.Version (showVersion)
import Paths_talalint (version)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)
import Progmasoft.Talafmt (formattedSource)
import Progmasoft.Talalint
import Progmasoft.Talalint.CommandLine
import Progmasoft.Tala.AST
import Progmasoft.Tala.Frontend

main :: IO ()
main = do
    arguments <- getArgs
    case parseCommandLine arguments of
        Left problem -> do
            hPutStrLn stderr ("talalint: " ++ renderCommandLineError problem)
            exitWith (ExitFailure usageError)
        Right ShowHelp -> putStr usageText
        Right ShowVersion -> putStrLn ("talalint " ++ showVersion version)
        Right (Lint mode paths) -> do
            clean <- mapM (lintPath mode) (NonEmpty.toList paths)
            if and clean then pure () else exitFailure

-- | Exit status of a command line that could not be read.
usageError :: Int
usageError = 2

-- | Lint one file; True when nothing is left to report.
lintPath :: Mode -> FilePath -> IO Bool
lintPath mode path = do
    source <- Text.unpack <$> TextIO.readFile path
    finalSource <- case mode of
        Fix -> applyFixes path source
        Report -> pure source
    let problems = lintSource (CompilerInput path finalSource)
    mapM_ printDiagnostic problems
    pure (null problems)

applyFixes :: FilePath -> String -> IO String
applyFixes path source = case applySafeFixes (CompilerInput path source) of
    Left _ -> pure source
    Right result -> do
        TextIO.writeFile path (Text.pack (formattedSource result))
        pure (formattedSource result)

printDiagnostic :: LintDiagnostic -> IO ()
printDiagnostic problem =
    putStrLn
        ( renderLocation (lintSpan problem)
            ++ renderSeverity (lintSeverity problem)
            ++ " ["
            ++ lintRuleId problem
            ++ "] "
            ++ lintMessage problem
        )

renderLocation :: Maybe SourceSpan -> String
renderLocation Nothing = ""
renderLocation (Just spanValue) =
    sourceFile spanValue
        ++ ":"
        ++ show (sourceLine (sourceStart spanValue))
        ++ ":"
        ++ show (sourceColumn (sourceStart spanValue))
        ++ ": "

renderSeverity :: LintSeverity -> String
renderSeverity severity = case severity of
    LintInfo -> "info"
    LintWarning -> "warning"
    LintError -> "error"
