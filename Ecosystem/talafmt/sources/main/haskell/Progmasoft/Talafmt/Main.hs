-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Main (main) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.List (intercalate)
import System.Directory (doesFileExist, findExecutable, getCurrentDirectory, getTemporaryDirectory, removeFile)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hClose, hPutStrLn, openBinaryTempFile, stderr, stdout)
import System.Info (os)
import System.Process (readProcessWithExitCode)
import Progmasoft.Talafmt
import Progmasoft.Talafmt.Encoding
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend

data Mode = Standard | InPlace | DryRun
    deriving (Eq, Show)

data Command = Help | Format Mode [FilePath]

main :: IO ()
main = do
    arguments <- getArgs
    case parseCommand arguments of
        Nothing -> usage >> exitFailure
        Just command -> runCommand command

parseCommand :: [String] -> Maybe Command
parseCommand ["-Help"] = Just Help
parseCommand arguments = finish =<< parseArguments Nothing [] arguments

parseArguments :: Maybe Mode -> [FilePath] -> [String] -> Maybe (Maybe Mode, [FilePath])
parseArguments mode paths arguments = case arguments of
    [] -> Just (mode, reverse paths)
    "-In-Place" : rest | mode == Nothing -> parseArguments (Just InPlace) paths rest
    "-Dry-Run" : rest | mode == Nothing -> parseArguments (Just DryRun) paths rest
    value@(first : _) : rest
        | first /= '-' -> parseArguments mode (value : paths) rest
    _ -> Nothing

finish :: (Maybe Mode, [FilePath]) -> Maybe Command
finish (Nothing, [path]) = Just (Format Standard [path])
finish (Just mode, paths@(_ : _)) = Just (Format mode paths)
finish _ = Nothing

runCommand :: Command -> IO ()
runCommand Help = usage
runCommand (Format mode paths) = do
    configured <- loadEncodingOptions
    case configured of
        Left problem -> hPutStrLn stderr ("TAF0003: " ++ problem) >> exitFailure
        Right encoding -> do
            results <- mapM (formatPath mode encoding) paths
            if and results then pure () else exitFailure

formatPath :: Mode -> EncodingOptions -> FilePath -> IO Bool
formatPath mode encoding path = do
    input <- ByteString.readFile path
    decoded <- decodeSourceBytes (inputEncoding encoding) input
    case decoded of
        Left problem -> hPutStrLn stderr ("TAF0002: cannot decode " ++ path ++ ": " ++ problem) >> pure False
        Right source -> case formatSource defaultFormatOptions (CompilerInput path source) of
            Left problems -> mapM_ printCompilerDiagnostic problems >> pure False
            Right result -> do
                let output = encodeSourceText (outputEncoding encoding) (emitByteOrderMark encoding) (formattedSource result)
                case mode of
                    Standard -> ByteString.hPut stdout output >> pure True
                    InPlace -> ByteString.writeFile path output >> pure True
                    DryRun -> pure (output == input)

-- talafmt.kts remains executable Kotlin rather than a second static
-- manifest. The JVM helper evaluates it once per formatter process and returns
-- only the immutable encoding projection needed by the current Haskell engine.
loadEncodingOptions :: IO (Either String EncodingOptions)
loadEncodingOptions = do
    root <- getCurrentDirectory
    let script = root ++ "/talafmt.kts"
    present <- doesFileExist script
    if not present
        then pure (Right defaultEncodingOptions)
        else withConfigurationFile root

withConfigurationFile :: FilePath -> IO (Either String EncodingOptions)
withConfigurationFile root = do
    temporaryDirectory <- getTemporaryDirectory
    (path, handle) <- openBinaryTempFile temporaryDirectory "talafmt-config"
    hClose handle
    executable <- findExecutable evaluator
    result <- case executable of
        Nothing -> pure (Left ("could not find " ++ evaluator ++ " on PATH"))
        Just executablePath -> do
            evaluated <-
                try (readProcessWithExitCode executablePath [root, path] "") :: IO (Either IOException (ExitCode, String, String))
            case evaluated of
                Left problem -> pure (Left ("could not start " ++ executablePath ++ ": " ++ show problem))
                Right (ExitFailure _, _, message) -> pure (Left (trimDiagnostic message))
                Right (ExitSuccess, _, _) -> parseConfigurationFile path
    _ <- try (removeFile path) :: IO (Either IOException ())
    pure result
    where
        evaluator = if os == "mingw32" then "talafmt-config.bat" else "talafmt-config"

parseConfigurationFile :: FilePath -> IO (Either String EncodingOptions)
parseConfigurationFile path = do
    bytes <- ByteString.readFile path
    let fields = map ByteString.Char8.unpack (dropTrailingEmpty (ByteString.split 0 bytes))
    pure $ case fields of
        ["talafmt-config-v1", inputName, outputName, bomName] -> do
            input <- maybe (Left "invalid formatter input encoding") Right (parseSourceEncoding inputName)
            output <- maybe (Left "invalid formatter output encoding") Right (parseSourceEncoding outputName)
            bom <- case bomName of
                "true" -> Right True
                "false" -> Right False
                _ -> Left "invalid formatter BOM policy"
            Right (EncodingOptions input output bom)
        _ -> Left "configuration evaluator returned an invalid protocol payload"

dropTrailingEmpty :: [ByteString.ByteString] -> [ByteString.ByteString]
dropTrailingEmpty fields = case reverse fields of
    empty : rest | ByteString.null empty -> reverse rest
    _ -> fields

trimDiagnostic :: String -> String
trimDiagnostic message = case lines message of
    [] -> "configuration evaluation failed"
    diagnostics -> intercalate "; " diagnostics

printCompilerDiagnostic :: Diagnostic -> IO ()
printCompilerDiagnostic problem =
    hPutStrLn stderr (diagnosticCode problem ++ ": " ++ diagnosticMessage problem)

usage :: IO ()
usage =
    putStrLn
        "usage: talafmt <file.tala> | talafmt -In-Place <file.tala>... | talafmt -Dry-Run <file.tala>... | talafmt -Help"
