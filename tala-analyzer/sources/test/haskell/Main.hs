-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Main (main) where

import Data.Text (pack)
import Language.LSP.Protocol.Types qualified as Lsp
import Language.LSP.Test
    ( changeDoc
    , closeDoc
    , fullLatestClientCaps
    , getDocumentSymbols
    , noDiagnostics
    , openDoc
    , runSession
    , waitForDiagnostics
    )
import Paths_tala_analyzer (getDataFileName)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import Progmasoft.TalaAnalyzer
import Progmasoft.TalaAnalyzer.Document
import Progmasoft.TalaAnalyzer.Server (documentDiagnostics, toLspDiagnostic)
import Progmasoft.TalaAnalyzer.Symbols (documentSymbols)
import Progmasoft.Tala.Diagnostic (DiagnosticSeverity (..), DiagnosticStage (..))
import Progmasoft.Tala.Frontend

main :: IO ()
main = do
    check "syntax analysis returns compiler-owned syntax artifacts" syntaxAnalysis
    check "full analysis reaches CorePrep" fullAnalysis
    check "compiler positions are translated to zero-based protocol positions" protocolPositions
    check "syntax mode does not perform name resolution" syntaxModeStopsAtItsBoundary
    check "ASCII columns preserve width" (utf16Column (pack "alpha") 3 == 3)
    check "non-BMP characters take two UTF-16 units" (utf16Column (pack "a😀b") 2 == 3)
    check "negative compiler columns clamp at zero" (utf16Column (pack "abc") (-2) == 0)
    check "columns beyond end clamp to line width" (utf16Column (pack "abc") 12 == 3)
    check "line lookup strips CR in CRLF source" (lineAt (pack "a\r\nb") 0 == pack "a")
    check "line lookup handles empty final line" (lineAt (pack "a\n") 1 == pack "")
    check "line lookup handles out-of-range line" (lineAt (pack "a") 5 == pack "")
    check "position conversion uses requested line" utf16Position
    check "range conversion preserves end-exclusive semantics" utf16Range
    check "valid document clears old diagnostics" (null (documentDiagnostics "Program.tala" (pack validSource)))
    check "invalid document publishes compiler code" lspDiagnosticCode
    check "invalid document publishes an error severity" lspDiagnosticSeverity
    check "invalid document reports compiler origin" lspDiagnosticOrigin
    check "diagnostic ranges convert scalar columns after non-BMP text" lspDiagnosticUtf16Range
    check "unlocated diagnostics use a zero-width fallback range" unlocatedDiagnosticRange
    check "document symbols include the parsed class" parsedClassSymbol
    check "document symbols nest methods within classes" nestedMethodSymbol
    check "class selection range covers its identifier only" classSelectionRange
    check "method selection range covers its identifier only" methodSelectionRange
    check "invalid syntax does not manufacture document symbols" (null (documentSymbols "Broken.tala" (pack "@")))
    integrationPassed <- lspLifecycle
    check "stdio LSP lifecycle publishes and clears compiler diagnostics" integrationPassed

check :: String -> Bool -> IO ()
check label passed = if passed then putStrLn ("PASS: " ++ label) else putStrLn ("FAIL: " ++ label) >> exitFailure

validSource :: String
validSource =
    unlines
        [ "namespace Example;"
        , "public class Program {"
        , "    public static void Main() {"
        , "        return;"
        , "    }"
        , "}"
        ]

syntaxAnalysis :: Bool
syntaxAnalysis = case analyzeDocument Syntax (CompilerInput "Program.tala" validSource) of
    Right SyntaxResult {} -> True
    _ -> False

fullAnalysis :: Bool
fullAnalysis = case analyzeDocument Full (CompilerInput "Program.tala" validSource) of
    Right FullResult {} -> True
    _ -> False

protocolPositions :: Bool
protocolPositions = case analyzeDocument Syntax (CompilerInput "Broken.tala" "@") of
    Left [problem] -> case analyzerRange problem of
        Just (ProtocolRange (ProtocolPosition 0 0) (ProtocolPosition 0 1)) -> analyzerCode problem == "TAL0001"
        _ -> False
    _ -> False

syntaxModeStopsAtItsBoundary :: Bool
syntaxModeStopsAtItsBoundary =
    let source = "class Program { int Value() { return MissingName; } }"
        input = CompilerInput "Unknown.tala" source
     in case (analyzeDocument Syntax input, analyzeDocument Semantic input) of
            (Right SyntaxResult {}, Left problems) -> any ((== "TAN0001") . analyzerCode) problems
            _ -> False

utf16Position :: Bool
utf16Position =
    toUtf16Position (pack "zero\na😀b\n") (ProtocolPosition 1 2)
        == ProtocolPosition 1 3

utf16Range :: Bool
utf16Range =
    toUtf16Range
        (pack "😀bad")
        (ProtocolRange (ProtocolPosition 0 1) (ProtocolPosition 0 4))
        == ProtocolRange (ProtocolPosition 0 2) (ProtocolPosition 0 5)

lspDiagnosticCode :: Bool
lspDiagnosticCode =
    case documentDiagnostics "Broken.tala" (pack "@") of
        Lsp.Diagnostic _ _ (Just (Lsp.InR code)) _ _ _ _ _ _ : _ -> code == pack "TAL0001"
        _ -> False

lspDiagnosticSeverity :: Bool
lspDiagnosticSeverity =
    case documentDiagnostics "Broken.tala" (pack "@") of
        Lsp.Diagnostic _ (Just Lsp.DiagnosticSeverity_Error) _ _ _ _ _ _ _ : _ -> True
        _ -> False

lspDiagnosticOrigin :: Bool
lspDiagnosticOrigin =
    case documentDiagnostics "Broken.tala" (pack "@") of
        Lsp.Diagnostic _ _ _ _ (Just source) _ _ _ _ : _ -> source == pack "Tala"
        _ -> False

{- | Compiler spans count Unicode scalars while LSP spans count UTF-16 units.
This adapter test checks both endpoints after an astral character, not only
the stand-alone column conversion helper.
-}
lspDiagnosticUtf16Range :: Bool
lspDiagnosticUtf16Range =
    let problem =
            AnalyzerDiagnostic
                "TAL9001"
                Error
                LexerStage
                (Just (ProtocolRange (ProtocolPosition 0 1) (ProtocolPosition 0 6)))
                "invalid token"
        converted = toLspDiagnostic (pack "😀value") problem
     in case converted of
            Lsp.Diagnostic (Lsp.Range (Lsp.Position 0 2) (Lsp.Position 0 7)) _ _ _ _ _ _ _ _ -> True
            _ -> False

{- | A backend diagnostic without a source span still needs a valid protocol
location, so the server maps it to an empty range at the document origin.
-}
unlocatedDiagnosticRange :: Bool
unlocatedDiagnosticRange =
    let problem = AnalyzerDiagnostic "TAB0001" Warning CorePrepStage Nothing "no source range"
     in case toLspDiagnostic (pack "") problem of
            Lsp.Diagnostic (Lsp.Range (Lsp.Position 0 0) (Lsp.Position 0 0)) _ _ _ _ _ _ _ _ -> True
            _ -> False

parsedClassSymbol :: Bool
parsedClassSymbol =
    case documentSymbols "Program.tala" (pack validSource) of
        Lsp.DocumentSymbol name _ Lsp.SymbolKind_Class _ _ _ _ _ : _ -> name == pack "Program"
        _ -> False

nestedMethodSymbol :: Bool
nestedMethodSymbol =
    case documentSymbols "Program.tala" (pack validSource) of
        Lsp.DocumentSymbol _ _ _ _ _ _ _ (Just children) : _ ->
            case children of
                Lsp.DocumentSymbol name _ Lsp.SymbolKind_Method _ _ _ _ _ : _ -> name == pack "Main"
                _ -> False
        _ -> False

classSelectionRange :: Bool
classSelectionRange =
    case documentSymbols "Program.tala" (pack validSource) of
        Lsp.DocumentSymbol _ _ _ _ _ _ selection _ : _ ->
            selection == Lsp.Range (Lsp.Position 1 13) (Lsp.Position 1 20)
        _ -> False

methodSelectionRange :: Bool
methodSelectionRange =
    case documentSymbols "Program.tala" (pack validSource) of
        [Lsp.DocumentSymbol _ _ _ _ _ _ _ (Just children)] ->
            case children of
                Lsp.DocumentSymbol _ _ _ _ _ _ selection _ : _ ->
                    selection == Lsp.Range (Lsp.Position 2 23) (Lsp.Position 2 27)
                _ -> False
        _ -> False

{- | The functional test runs the real executable through lsp-test. The test
client and server share the Hackage LSP protocol stack, so no local JSON-RPC
implementation or ad-hoc Content-Length parser can make this pass.
-}
lspLifecycle :: IO Bool
lspLifecycle = do
    validFile <- getDataFileName "Tests/Data/Valid.tala"
    let root = takeDirectory validFile
    runSession "tala-analyzer" fullLatestClientCaps root $ do
        document <- openDoc "Valid.tala" (Lsp.LanguageKind_Custom (pack "tala"))
        initial <- waitForDiagnostics
        symbolResult <- getDocumentSymbols document
        changeDoc
            document
            [ Lsp.TextDocumentContentChangeEvent
                (Lsp.InR (Lsp.TextDocumentContentChangeWholeDocument (pack "@")))
            ]
        changed <- waitForDiagnostics
        changeDoc
            document
            [ Lsp.TextDocumentContentChangeEvent
                (Lsp.InR (Lsp.TextDocumentContentChangeWholeDocument (pack validSource)))
            ]
        repaired <- waitForDiagnostics
        closeDoc document
        noDiagnostics
        let symbolsCorrect = case symbolResult of
                Right [Lsp.DocumentSymbol name _ _ _ _ _ _ _] -> name == pack "Program"
                _ -> False
        pure (null initial && not (null changed) && null repaired && symbolsCorrect)
