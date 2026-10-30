-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

-- | Token types shared between the lexer, parser, and parser cursor.
module Progmasoft.Tala.Parser.Token (TokenKind (..), Token (..)) where

import Progmasoft.Tala.AST (SourceSpan)

-- | Lexical category of one token emitted by the Tala scanner.
data TokenKind
    = IdentifierToken
    | KeywordToken
    | SymbolToken
    | IntegerToken
    | FloatingToken
    | CharacterToken
    | StringToken
    | {- | A compiler directive: @#@ and the word after it, as @#if@ or
      @#expect@. The directive pass consumes the conditional and region
      directives; @#expect@ reaches the parser.
      -}
      DirectiveToken
    | EndOfFileToken
    deriving stock (Bounded, Enum, Eq, Ord, Read, Show)

-- | Token spelling, category, and half-open source range.
data Token = Token
    { tokenKind :: TokenKind
    , tokenText :: String
    , tokenSpan :: SourceSpan
    }
    deriving stock (Eq, Ord, Read, Show)
