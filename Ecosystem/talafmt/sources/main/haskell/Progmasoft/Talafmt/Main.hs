-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Main (main) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.List (intercalate)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Version (showVersion)
import Paths_talafmt (version)
import System.Directory (doesFileExist, findExecutable, getCurrentDirectory, getTemporaryDirectory, removeFile)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hClose, hPutStrLn, openBinaryTempFile, stderr, stdout)
import System.Info (os)
import System.Process (readProcessWithExitCode)
import Progmasoft.Talafmt
import Progmasoft.Talafmt.CommandLine
import Progmasoft.Talafmt.Encoding
import Progmasoft.Talafmt.Report
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend

main :: IO ()
main = do
    arguments <- getArgs
    case parseCommandLine arguments of
        Left problem -> do
            hPutStrLn stderr ("talafmt: " ++ renderCommandLineError problem)
            exitWith (ExitFailure usageError)
        Right ShowHelp -> putStr usageText
        Right ShowVersion -> putStrLn ("talafmt " ++ showVersion version)
        Right (Format action paths) -> runFormat action (NonEmpty.toList paths)

-- | Exit status of a command line that could not be read.
usageError :: Int
usageError = 2

-- | A file read, decoded and formatted, with the bytes it holds now.
data Formatted = Formatted
    { formattedPath :: FilePath
    , formattedInput :: ByteString.ByteString
    , formattedOriginal :: String
    , formattedText :: String
    , formattedOutput :: ByteString.ByteString
    }

runFormat :: Action -> [FilePath] -> IO ()
runFormat action paths = do
    configured <- loadEncodingOptions
    case configured of
        Left problem -> hPutStrLn stderr ("TAF0003: " ++ problem) >> exitFailure
        Right encoding -> do
            formatted <- mapM (formatPath encoding) paths
            let results = [result | Just result <- formatted]
                complete = length results == length paths
            succeeded <- deliver action results
            if complete && succeeded then pure () else exitFailure

{- | Send the formatted files where the action says. The result is False when
the action found something the caller must know through the exit status: a
check that found a file to format.
-}
deliver :: Action -> [Formatted] -> IO Bool
deliver action results = case action of
    Emit EmitFiles -> do
        -- A file that is already formatted is not written again, so that its
        -- modification time tells when it last changed.
        mapM_ (\result -> ByteString.writeFile (formattedPath result) (formattedOutput result)) (filter changed results)
        pure True
    Emit EmitStdout -> mapM_ (ByteString.hPut stdout . formattedOutput) results >> pure True
    Emit EmitCoverage -> putStr (renderCoverage reports) >> pure True
    Emit EmitCheckstyle -> putStr (renderCheckstyle reports) >> pure True
    Emit EmitJson -> putStr (renderJson reports) >> pure True
    Check -> do
        mapM_ (\result -> putStrLn (formattedPath result ++ " needs formatting")) (filter changed results)
        pure (not (any changed results))
    where
        changed result = formattedOutput result /= formattedInput result
        reports = [fileReport (formattedPath result) (formattedOriginal result) (formattedText result) | result <- results]

formatPath :: EncodingOptions -> FilePath -> IO (Maybe Formatted)
formatPath encoding path = do
    opened <- try (ByteString.readFile path) :: IO (Either IOException ByteString.ByteString)
    case opened of
        Left problem -> hPutStrLn stderr ("TAF0001: cannot read " ++ path ++ ": " ++ show problem) >> pure Nothing
        Right input -> do
            decoded <- decodeSourceBytes (inputEncoding encoding) input
            case decoded of
                Left problem -> hPutStrLn stderr ("TAF0002: cannot decode " ++ path ++ ": " ++ problem) >> pure Nothing
                Right source -> case formatSource defaultFormatOptions (CompilerInput path source) of
                    Left problems -> mapM_ printCompilerDiagnostic problems >> pure Nothing
                    Right result ->
                        let text' = formattedSource result
                            output = encodeSourceText (outputEncoding encoding) (emitByteOrderMark encoding) text'
                         in pure (Just (Formatted path input source text' output))

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
