-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Hierarchical document symbols from the compiler's parsed AST.

Only declarations actually represented by the shared parser are reported.
The analyzer does not scan source text with a second grammar. An incomplete
document can still have diagnostics even when its parser cannot build a tree;
in that case the symbol response is empty rather than speculative.
-}
module Progmasoft.TalaAnalyzer.Symbols (documentSymbols) where

import Data.Text (Text)
import Data.Text qualified as Text
import Language.LSP.Protocol.Types qualified as Lsp
import Progmasoft.TalaAnalyzer (ProtocolPosition (..))
import Progmasoft.TalaAnalyzer.Document (toUtf16Position)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Parser (Token (..), TokenKind (..))

{- | Parse once through the compiler's syntax boundary, then expose nested
class and method declarations. The method name's token is used for LSP's
selectionRange; the declaration span encloses the complete symbol.
-}
documentSymbols :: FilePath -> Text -> [Lsp.DocumentSymbol]
documentSymbols path source =
    case analyzeSyntax (CompilerInput path (Text.unpack source)) of
        Left _ -> []
        Right artifacts ->
            let ParsedAST tree = syntaxParsedAST artifacts
             in map (declarationSymbol source (syntaxTokens artifacts) False) (syntaxDeclarations tree)

declarationSymbol :: Text -> [Token] -> Bool -> Declaration Identifier () -> Lsp.DocumentSymbol
declarationSymbol source tokens insideType declaration =
    case declaration of
        TypeDeclaration spanValue name _ members ->
            typeSymbol spanValue name members
        TemplateTypeDeclaration spanValue name _ _ members ->
            typeSymbol spanValue name members
        EnumDeclaration spanValue name _ _ cases ->
            Lsp.DocumentSymbol
                (Text.pack (identifierText name))
                Nothing
                Lsp.SymbolKind_Enum
                Nothing
                Nothing
                (spanRange source spanValue)
                (selectionRange source tokens spanValue name)
                ( Just
                    [ Lsp.DocumentSymbol
                        (Text.pack (identifierText (enumCaseName member)))
                        Nothing
                        Lsp.SymbolKind_EnumMember
                        Nothing
                        Nothing
                        (spanRange source (enumCaseSpan member))
                        (spanRange source (enumCaseSpan member))
                        Nothing
                    | member <- cases
                    ]
                )
        FunctionDeclaration spanValue name _ _ parameters _ isStatic _ ->
            let symbolRange = spanRange source spanValue
                selection = selectionRange source tokens spanValue name
                kind = if insideType then Lsp.SymbolKind_Method else Lsp.SymbolKind_Function
                detail =
                    Text.pack
                        ((if isStatic then "static " else "") ++ show (length parameters) ++ " parameter(s)")
             in Lsp.DocumentSymbol
                    (Text.pack (identifierText name))
                    (Just detail)
                    kind
                    Nothing
                    Nothing
                    symbolRange
                    selection
                    Nothing
    where
        typeSymbol spanValue name members =
            Lsp.DocumentSymbol
                (Text.pack (identifierText name))
                Nothing
                Lsp.SymbolKind_Class
                Nothing
                Nothing
                (spanRange source spanValue)
                (selectionRange source tokens spanValue name)
                (Just (map (declarationSymbol source tokens True) members))

{- | The parser's declaration span includes punctuation and body. Choosing
the identifier token makes the editor select just the visible name. Source
spans are one-based and their end is exclusive.
-}
selectionRange :: Text -> [Token] -> SourceSpan -> Identifier -> Lsp.Range
selectionRange source tokens declaration name =
    maybe (spanRange source declaration) (spanRange source . tokenSpan) match
    where
        match = case filter isNameToken tokens of
            first : _ -> Just first
            [] -> Nothing
        isNameToken token =
            tokenKind token == IdentifierToken
                && tokenText token == identifierText name
                && sourceStart (tokenSpan token) >= sourceStart declaration
                && sourceEnd (tokenSpan token) <= sourceEnd declaration

spanRange :: Text -> SourceSpan -> Lsp.Range
spanRange source spanValue =
    Lsp.Range
        (sourcePosition source (sourceStart spanValue))
        (sourcePosition source (sourceEnd spanValue))

sourcePosition :: Text -> SourcePosition -> Lsp.Position
sourcePosition source position =
    let zeroBased =
            ProtocolPosition
                (max 0 (sourceLine position - 1))
                (max 0 (sourceColumn position - 1))
        utf16 = toUtf16Position source zeroBased
     in Lsp.Position
            (fromIntegral (protocolLine utf16))
            (fromIntegral (protocolCharacter utf16))
