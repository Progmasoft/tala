-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
{-# LANGUAGE BangPatterns #-}

module Main (main) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Monad (forM, unless, when)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word (Word64)
import Feedback
import GHC.Clock (getMonotonicTimeNSec)
import Mutation
import System.Directory
    ( createDirectoryIfMissing
    , doesFileExist
    , getFileSize
    , listDirectory
    , pathIsSymbolicLink
    , renameFile
    )
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath ((</>))
import System.IO (hClose, openBinaryTempFile)
import System.IO.Error (catchIOError, isDoesNotExistError)
import System.Timeout (timeout)
import Text.Read (readMaybe)
import Trace.Hpc.Reflect (clearTix, examineTix)
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Frontend (analyzeSyntax)
import Progmasoft.Tala.Lexer

main :: IO ()
main = do
    arguments <- getArgs
    case arguments of
        [stage, "--replay", path] -> do
            validateStage stage
            input <- BS.readFile path
            when (BS.length input > maximumInput) (die "replay input exceeds the campaign limit")
            execute stage input >>= either die (const (putStrLn "HPC replay completed"))
        [stage, secondsText, corpus, artifacts, seedText]
            | Just seconds <- readMaybe secondsText
            , seconds >= (1 :: Int) && seconds <= 3600
            , Just seed <- readMaybe seedText -> do
                validateStage stage
                campaign stage seconds corpus artifacts seed
        _ -> die "usage: frontend-fuzz STAGE SECONDS CORPUS ARTIFACTS SEED | STAGE --replay FILE"

validateStage :: String -> IO ()
validateStage stage = unless (stage `elem` ["lexer", "parser", "source"]) (die "unknown HPC fuzz stage")

execute :: String -> BS.ByteString -> IO (Either String Coverage)
execute stage input = do
    -- Timeout surrounds exception capture so ordinary lazy failures cannot
    -- escape, and a timed-out input cannot be mistaken for a normal diagnostic.
    clearTix
    attempted <- try (timeout 5000000 action) :: IO (Either SomeException (Maybe Int))
    case attempted of
        Left issue -> pure (Left (displayException issue))
        Right Nothing -> pure (Left "frontend input exceeded five seconds")
        Right (Just _) -> Right . coverageFor <$> examineTix
    where
        action = case Text.decodeUtf8' input of
            Left _ -> pure 0
            Right text -> do
                let source = Text.unpack text
                    compilerInput = CompilerInput "Fuzz.tala" source
                evaluate $ length $ case stage of
                    "lexer" -> show (runLexer defaultLexer (LexerInput "Fuzz.tala" source))
                    "parser" -> show (analyzeSyntax compilerInput)
                    _ -> show (compileToCorePrep compilerInput)

loadSeeds :: FilePath -> IO [BS.ByteString]
loadSeeds corpus = do
    names <- sort <$> listDirectory corpus
    inputs <- forM (take 4096 names) $ \name -> do
        let path = corpus </> name
        regular <- doesFileExist path
        symbolic <- pathIsSymbolicLink path
        if regular && not symbolic
            then do
                size <- getFileSize path
                if size <= fromIntegral maximumInput then Just <$> BS.readFile path else pure Nothing
            else pure Nothing
    pure (BS.empty : [bytes | Just bytes <- inputs])

saveInput :: FilePath -> BS.ByteString -> IO ()
saveInput corpus input = do
    let path = corpus </> ("hpc-" ++ fingerprint input ++ ".seed")
    symbolic <-
        pathIsSymbolicLink path `catchIOError` \issue ->
            if isDoesNotExistError issue then pure False else ioError issue
    when symbolic (die "cached HPC corpus entry is a symbolic link")
    exists <- doesFileExist path
    if exists
        then do
            previous <- BS.readFile path
            unless (previous == input) (die "HPC corpus fingerprint collision; refusing to replace the existing input")
        else do
            -- Rename a newly created regular file instead of opening the final
            -- cached name for writing. A dangling/replaced symlink must never
            -- redirect writes outside the single-writer campaign corpus.
            (temporary, handle) <- openBinaryTempFile corpus ".pending-seed"
            BS.hPut handle input
            hClose handle
            renameFile temporary path

campaign :: String -> Int -> FilePath -> FilePath -> Word64 -> IO ()
campaign stage seconds corpus artifacts initialState = do
    createDirectoryIfMissing True corpus
    createDirectoryIfMissing True artifacts
    seeds <- loadSeeds corpus
    -- Prime registration with an actually valid source before checking HPC.
    -- A coverage-disabled build must fail rather than run unguided mutations.
    let validSource =
            BS.pack (map (fromIntegral . fromEnum) "namespace Fuzz; class Program { public static int Evaluate() { return 1; } }")
    execute stage validSource >>= either die (const (pure ()))
    initialTix <- examineTix
    unless (requiredModulePresent stage initialTix) (die "frontend-fuzz requires HPC-instrumented production modules")
    let tickCount = availableTicks initialTix
    started <- getMonotonicTimeNSec
    let deadline = started + fromIntegral seconds * 1000000000
        report executed coverage additions =
            unlines
                [ "stage=" ++ stage
                , "executed_units=" ++ show executed
                , "covered_ticks=" ++ show (Set.size coverage)
                , "available_ticks=" ++ show tickCount
                , "new_units_added=" ++ show additions
                , "seed=" ++ show initialState
                ]
        finish executed coverage additions = do
            unless (executed > 0 && not (Set.null coverage)) (die "HPC campaign did not execute instrumented production code")
            let summary = report executed coverage additions
            writeFile (artifacts </> "campaign.txt") summary
            putStrLn ("HPC_FUZZ_RESULT\n" ++ summary)
        failInput input problem = do
            BS.writeFile (artifacts </> "failure.seed") input
            writeFile (artifacts </> "failure.txt") (problem ++ "\nReplay: frontend-fuzz " ++ stage ++ " --replay failure.seed\n")
            die ("HPC fuzz failure: " ++ problem)
        addInput input pool coverage additions = do
            checked <- execute stage input
            case checked of
                Left problem -> failInput input problem
                Right observed -> do
                    let novel = not (observed `Set.isSubsetOf` coverage)
                    when novel (saveInput corpus input)
                    let nextPool = if novel && Seq.length pool < 4096 then pool Seq.|> input else pool
                    pure (nextPool, Set.union observed coverage, additions + if novel then 1 else 0)
        warm pool coverage additions [] = pure (pool, coverage, additions)
        warm pool coverage additions (input : remaining) = do
            (nextPool, nextCoverage, nextAdditions) <- addInput input pool coverage additions
            warm nextPool nextCoverage nextAdditions remaining
        loop !state !pool !coverage !executed !additions = do
            now <- getMonotonicTimeNSec
            if now >= deadline
                then finish executed coverage additions
                else do
                    let next = nextState state
                        base = Seq.index pool (fromIntegral (state `mod` fromIntegral (Seq.length pool)))
                        partner = Seq.index pool (fromIntegral (next `mod` fromIntegral (Seq.length pool)))
                        input = mutate next base partner
                    (nextPool, nextCoverage, nextAdditions) <- addInput input pool coverage additions
                    -- Progress checkpoints retain mutation state for resource
                    -- termination; ordinary failures always save exact bytes.
                    when
                        (executed `mod` 256 == 0)
                        ( writeFile
                            (artifacts </> "progress.txt")
                            (report executed nextCoverage nextAdditions ++ "mutation_state=" ++ show next ++ "\n")
                        )
                    loop next nextPool nextCoverage (executed + 1) nextAdditions
    let warmSeeds = validSource : take 4096 seeds
    (pool, coverage, additions) <- warm (Seq.singleton BS.empty) Set.empty (0 :: Int) warmSeeds
    loop initialState pool coverage (length warmSeeds) additions
