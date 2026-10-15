-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Tala language server over standard LSP JSON-RPC.

The Hackage @lsp@ package owns Content-Length framing, initialization,
shutdown, JSON-RPC dispatch, and the versioned virtual file system. This
module deliberately does not implement a second transport or parser. Its
responsibility is to feed the compiler the current document and adapt
compiler diagnostics to LSP's UTF-16 coordinate system.
-}
module Progmasoft.TalaAnalyzer.Server
    ( runAnalyzerServer
    , documentDiagnostics
    , toLspDiagnostic
    ) where

import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Text qualified as Text
import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types qualified as Lsp
import Language.LSP.Server
import Language.LSP.VFS (virtualFileText, virtualFileVersion)
import Progmasoft.TalaAnalyzer
import Progmasoft.TalaAnalyzer.Document (toUtf16Range)
import Progmasoft.TalaAnalyzer.Symbols (documentSymbols)
import Progmasoft.Tala.Diagnostic (DiagnosticSeverity (..))
import Progmasoft.Tala.Frontend (CompilerInput (..))

{- | Start the server on stdin/stdout. All library logging uses stderr, so
stdout remains an unpolluted JSON-RPC stream. The integer is the library's
process exit status and is passed on by the executable entry point.
-}
runAnalyzerServer :: IO Int
runAnalyzerServer = runServer serverDefinition

serverDefinition :: ServerDefinition ()
serverDefinition =
    ServerDefinition
        { defaultConfig = ()
        , configSection = Text.pack "visualAnalyzer"
        , parseConfig = \_ _ -> Right ()
        , onConfigChange = \_ -> pure ()
        , doInitialize = \environment _ -> pure (Right environment)
        , staticHandlers = \_ -> analyzerHandlers
        , interpretHandler = \environment -> Iso (runLspT environment) liftIO
        , options =
            defaultOptions
                { optTextDocumentSync =
                    Just
                        ( Lsp.TextDocumentSyncOptions
                            (Just True)
                            (Just Lsp.TextDocumentSyncKind_Incremental)
                            Nothing
                            Nothing
                            Nothing
                        )
                , optServerInfo =
                    Just (Lsp.ServerInfo (Text.pack "tala-analyzer") (Just (Text.pack "0.3.3")))
                }
        }

{- | The library updates its VFS before invoking these handlers. In
particular, didChange may contain several incremental edits; reading the
VFS rather than manually interpreting contentChanges guarantees that the
compiler sees their combined, ordered result.
-}
analyzerHandlers :: Handlers (LspM ())
analyzerHandlers =
    mconcat
        [ notificationHandler SMethod_TextDocumentDidOpen $ \(TNotificationMessage _ _ params) ->
            case params of
                Lsp.DidOpenTextDocumentParams (Lsp.TextDocumentItem uri _ _ _) ->
                    analyzeOpenDocument uri
        , notificationHandler SMethod_TextDocumentDidChange $ \(TNotificationMessage _ _ params) ->
            case params of
                Lsp.DidChangeTextDocumentParams (Lsp.VersionedTextDocumentIdentifier uri _) _ ->
                    analyzeOpenDocument uri
        , notificationHandler SMethod_TextDocumentDidClose $ \(TNotificationMessage _ _ params) ->
            case params of
                Lsp.DidCloseTextDocumentParams (Lsp.TextDocumentIdentifier uri) ->
                    -- The client may retain diagnostics after closure unless
                    -- the server explicitly publishes an empty list.
                    sendNotification
                        SMethod_TextDocumentPublishDiagnostics
                        (Lsp.PublishDiagnosticsParams uri Nothing [])
        , requestHandler SMethod_TextDocumentDocumentSymbol $ \(TRequestMessage _ _ _ params) respond ->
            case params of
                Lsp.DocumentSymbolParams _ _ (Lsp.TextDocumentIdentifier uri) -> do
                    virtualFile <- getVirtualFile (Lsp.toNormalizedUri uri)
                    let symbols = case virtualFile of
                            Nothing -> []
                            Just file ->
                                let path = maybe (Text.unpack (Lsp.getUri uri)) id (Lsp.uriToFilePath uri)
                                 in documentSymbols path (virtualFileText file)
                    respond (Right (Lsp.InR (Lsp.InL symbols)))
        ]

analyzeOpenDocument :: Lsp.Uri -> LspM () ()
analyzeOpenDocument uri = do
    virtualFile <- getVirtualFile (Lsp.toNormalizedUri uri)
    case virtualFile of
        Nothing -> pure ()
        Just file -> do
            let source = virtualFileText file
                version = virtualFileVersion file
                path = maybe (Text.unpack (Lsp.getUri uri)) id (Lsp.uriToFilePath uri)
                diagnostics = documentDiagnostics path source
            sendNotification
                SMethod_TextDocumentPublishDiagnostics
                (Lsp.PublishDiagnosticsParams uri (Just version) diagnostics)

{- | Compiler analysis is pure and bounded to the document version from the
LSP VFS. A successful analysis must publish [] to clear previous errors.
-}
documentDiagnostics :: FilePath -> Text -> [Lsp.Diagnostic]
documentDiagnostics path source =
    case analyzeDocument Full (CompilerInput path (Text.unpack source)) of
        Left problems -> map (toLspDiagnostic source) problems
        Right _ -> []

{- | The compiler's coordinates count Unicode scalars, not UTF-16 units.
Converting only at this protocol boundary keeps the source model shared
with CLI and compiler tests unchanged.
-}
toLspDiagnostic :: Text -> AnalyzerDiagnostic -> Lsp.Diagnostic
toLspDiagnostic source problem =
    Lsp.Diagnostic
        (toLspRange source (analyzerRange problem))
        (Just (toLspSeverity (analyzerSeverity problem)))
        (Just (Lsp.InR (Text.pack (analyzerCode problem))))
        Nothing
        (Just (Text.pack "Tala"))
        (Text.pack (analyzerMessage problem))
        Nothing
        Nothing
        Nothing

toLspSeverity :: DiagnosticSeverity -> Lsp.DiagnosticSeverity
toLspSeverity Error = Lsp.DiagnosticSeverity_Error
toLspSeverity Warning = Lsp.DiagnosticSeverity_Warning

toLspRange :: Text -> Maybe ProtocolRange -> Lsp.Range
toLspRange source possibleRange =
    case toUtf16Range source <$> possibleRange of
        Nothing -> Lsp.Range (Lsp.Position 0 0) (Lsp.Position 0 0)
        Just (ProtocolRange start end) ->
            Lsp.Range (toLspPosition start) (toLspPosition end)

toLspPosition :: ProtocolPosition -> Lsp.Position
toLspPosition position =
    Lsp.Position
        (fromIntegral (max 0 (protocolLine position)))
        (fromIntegral (max 0 (protocolCharacter position)))
