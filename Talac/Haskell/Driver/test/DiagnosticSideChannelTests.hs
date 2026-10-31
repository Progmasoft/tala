-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module DiagnosticSideChannelTests (diagnosticSideChannelTests) where

import Control.Exception (finally)
import Data.ByteString qualified as ByteString
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Diagnostic.Protocol
import Progmasoft.Tala.Diagnostic.SideChannel

diagnosticSideChannelTests :: [(String, IO Bool)]
diagnosticSideChannelTests =
    [ ("diagnostic side channel writes the stable empty success document", writesEmptyDocument)
    , ("diagnostic side channel writes an error document", writesErrorDocument)
    , ("diagnostic side channel overwrites stale bytes", overwritesStaleBytes)
    , ("diagnostic side channel rejects an empty path", rejectsEmptyPath)
    , ("diagnostic side channel reports unavailable parent directories", reportsWriteFailure)
    , ("diagnostic side channel rejects invalid source coordinates before I/O", rejectsInvalidModel)
    ]

writesEmptyDocument :: IO Bool
writesEmptyDocument = withDiagnosticPath "empty" $ \path -> do
    written <- writeDiagnosticFile path []
    bytes <- ByteString.readFile path
    pure
        ( written == Right ()
            && decodeDiagnosticDocument defaultDiagnosticProtocolLimits bytes == Right (DiagnosticDocument [])
        )

writesErrorDocument :: IO Bool
writesErrorDocument = withDiagnosticPath "error" $ \path -> do
    written <- writeDiagnosticFile path [sampleDiagnostic]
    bytes <- ByteString.readFile path
    pure $ case (written, decodeDiagnosticDocument defaultDiagnosticProtocolLimits bytes) of
        (Right (), Right (DiagnosticDocument [record])) ->
            recordStage record == ParserStage
                && recordSeverity record == ProtocolError
                && recordCode record == "TAP100"
                && recordMessage record == "expected declaration"
                && recordPrimary record == Just (DiagnosticLocation "Main.tala" 3 8 3 13)
        _ -> False

overwritesStaleBytes :: IO Bool
overwritesStaleBytes = withDiagnosticPath "stale" $ \path -> do
    ByteString.writeFile path (ByteString.replicate 256 0xff)
    written <- writeDiagnosticFile path []
    bytes <- ByteString.readFile path
    pure
        ( written == Right ()
            && ByteString.length bytes == 12
            && decodeDiagnosticDocument defaultDiagnosticProtocolLimits bytes == Right (DiagnosticDocument [])
        )

rejectsEmptyPath :: IO Bool
rejectsEmptyPath = do
    result <- writeDiagnosticFile "" []
    pure $ case result of
        Left (SideChannelWriteError "" _) -> True
        _ -> False

reportsWriteFailure :: IO Bool
reportsWriteFailure = do
    temporary <- getTemporaryDirectory
    let path = temporary </> "xide-side-channel-missing-parent" </> "diagnostics.vxdg"
    result <- writeDiagnosticFile path []
    pure $ case result of
        Left (SideChannelWriteError failedPath _) -> failedPath == path
        _ -> False

rejectsInvalidModel :: IO Bool
rejectsInvalidModel = withDiagnosticPath "invalid" $ \path -> do
    let invalid =
            sampleDiagnostic
                { diagnosticSpan =
                    Just (SourceSpan "Main.tala" (SourcePosition 0 1) (SourcePosition 1 1))
                }
    result <- writeDiagnosticFile path [invalid]
    exists <- doesFileExist path
    pure $ case result of
        Left (SideChannelModelError _) -> not exists
        _ -> False

sampleDiagnostic :: Diagnostic
sampleDiagnostic =
    Diagnostic
        ParserStage
        Error
        "TAP100"
        (Just (SourceSpan "Main.tala" (SourcePosition 4 9) (SourcePosition 4 14)))
        "expected declaration"

withDiagnosticPath :: String -> (FilePath -> IO Bool) -> IO Bool
withDiagnosticPath suffix action = do
    temporary <- getTemporaryDirectory
    let path = temporary </> ("tala-diagnostics-" ++ suffix ++ ".vxdg")
        cleanup = do
            exists <- doesFileExist path
            if exists then removeFile path else pure ()
    cleanup
    action path `finally` cleanup
