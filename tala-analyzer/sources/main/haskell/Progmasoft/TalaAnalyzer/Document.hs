-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Conversion between compiler source positions and LSP's UTF-16 positions.

The compiler reports one-based line and Unicode scalar columns. The Language
Server Protocol instead counts zero-based UTF-16 code units. In particular,
a non-BMP character occupies one compiler column but two LSP characters.
This module is deliberately independent of JSON-RPC framing: the @lsp@
package owns the transport and document synchronization.
-}
module Progmasoft.TalaAnalyzer.Document
    ( utf16Width
    , utf16Column
    , toUtf16Position
    , toUtf16Range
    , lineAt
    ) where

import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as Text
import Progmasoft.TalaAnalyzer (ProtocolPosition (..), ProtocolRange (..))

-- | A Unicode scalar outside the BMP is encoded as a surrogate pair.
utf16Width :: Char -> Int
utf16Width character
    | ord character > 0xFFFF = 2
    | otherwise = 1

{- | Convert a zero-based scalar column to a zero-based UTF-16 column.
Out-of-range columns are clamped to the end of the line, which ensures a
malformed compiler span cannot point outside the LSP document.
-}
utf16Column :: Text -> Int -> Int
utf16Column line scalarColumn =
    Text.foldl' (\width character -> width + utf16Width character) 0 prefix
    where
        prefix = Text.take (max 0 scalarColumn) line

{- | Get a line without its newline. Text.lines understands LF and CRLF leaves
a trailing CR; strip it so a column at the line end remains valid.
-}
lineAt :: Text -> Int -> Text
lineAt source zeroBasedLine =
    case drop (max 0 zeroBasedLine) (Text.splitOn (Text.pack "\n") source) of
        line : _ -> Text.dropWhileEnd (== '\r') line
        [] -> Text.empty

-- | Adapt the compiler position without changing the compiler's own model.
toUtf16Position :: Text -> ProtocolPosition -> ProtocolPosition
toUtf16Position source position =
    ProtocolPosition line (utf16Column (lineAt source line) (protocolCharacter position))
    where
        line = max 0 (protocolLine position)

-- | Convert both ends of a compiler range. The LSP end remains exclusive.
toUtf16Range :: Text -> ProtocolRange -> ProtocolRange
toUtf16Range source range =
    ProtocolRange
        (toUtf16Position source (protocolStart range))
        (toUtf16Position source (protocolEnd range))
