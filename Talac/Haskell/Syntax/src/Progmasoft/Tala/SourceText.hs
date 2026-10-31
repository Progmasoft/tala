-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Lossless lexical structure for source-oriented tools.

The semantic lexer intentionally decodes literals and discards trivia. That is
the correct representation for parsing, but it is unsafe for formatters and
editor tools: rebuilding source from semantic tokens can change escape spelling,
comment delimiters, or raw-string contents. This module provides the parallel
lossless boundary. Every fragment retains its exact source text and half-open
source span, and concatenating the fragments always reconstructs the input.
-}
module Progmasoft.Tala.SourceText
    ( SourceFragmentKind (..)
    , SourceFragment (..)
    , scanSourceFragments
    , reconstructSource
    , maskedSource
    , protectedLineNumbers
    ) where

import Data.List (stripPrefix)
import Progmasoft.Tala.AST (SourcePosition (..), SourceSpan (..))
import Progmasoft.Tala.Diagnostic

-- | Kind of fragment retained by the lossless source scanner.
data SourceFragmentKind
    = CodeFragment
    | LineCommentFragment
    | LongCommentFragment
    | StringLiteralFragment
    | CharacterLiteralFragment
    | RawStringLiteralFragment
    deriving stock (Bounded, Enum, Eq, Ord, Read, Show)

-- | Exact fragment text and its original half-open source span.
data SourceFragment = SourceFragment
    { sourceFragmentKind :: SourceFragmentKind
    , sourceFragmentText :: String
    , sourceFragmentSpan :: SourceSpan
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Split source without normalizing or decoding any character.
scanSourceFragments :: FilePath -> String -> Either [Diagnostic] [SourceFragment]
scanSourceFragments file = go (SourcePosition 1 1) Nothing []
    where
        go _ pending output [] = Right (reverse (flushPending file pending output))
        go position pending output input
            | Just remaining <- stripPrefix "--" input =
                let flushed = flushPending file pending output
                 in case longBracketOpener remaining of
                        Just (level, opener, content) -> do
                            let prefix = "--" ++ opener
                                afterPrefix = advanceText position prefix
                            (text, end, rest) <- consumeLong file LongCommentFragment position afterPrefix prefix level content
                            go end Nothing (fragment file LongCommentFragment position end text : flushed) rest
                        Nothing ->
                            let (body, rest) = break isLineBreak remaining
                                text = "--" ++ body
                                end = advanceText position text
                             in go end Nothing (fragment file LineCommentFragment position end text : flushed) rest
            | Just (level, opener, content) <- longBracketOpener input = do
                let flushed = flushPending file pending output
                    afterPrefix = advanceText position opener
                (text, end, rest) <- consumeLong file RawStringLiteralFragment position afterPrefix opener level content
                go end Nothing (fragment file RawStringLiteralFragment position end text : flushed) rest
            | '"' : remaining <- input = do
                let flushed = flushPending file pending output
                    afterQuote = advanceText position "\""
                (text, end, rest) <- consumeQuoted file StringLiteralFragment '"' position afterQuote "\"" remaining
                go end Nothing (fragment file StringLiteralFragment position end text : flushed) rest
            | '\'' : remaining <- input = do
                let flushed = flushPending file pending output
                    afterQuote = advanceText position "'"
                (text, end, rest) <- consumeQuoted file CharacterLiteralFragment '\'' position afterQuote "'" remaining
                go end Nothing (fragment file CharacterLiteralFragment position end text : flushed) rest
            | otherwise =
                let (unit, rest, end) = consumeSourceUnit position input
                    nextPending = appendPending position unit pending
                 in go end nextPending output rest

appendPending :: SourcePosition -> String -> Maybe (SourcePosition, String) -> Maybe (SourcePosition, String)
appendPending position text Nothing = Just (position, reverse text)
appendPending _ text (Just (start, reversed)) = Just (start, reverse text ++ reversed)

flushPending :: FilePath -> Maybe (SourcePosition, String) -> [SourceFragment] -> [SourceFragment]
flushPending _ Nothing output = output
flushPending file (Just (start, reversed)) output =
    let text = reverse reversed
        end = advanceText start text
     in fragment file CodeFragment start end text : output

fragment :: FilePath -> SourceFragmentKind -> SourcePosition -> SourcePosition -> String -> SourceFragment
fragment file kind start end text = SourceFragment kind text (SourceSpan file start end)

consumeQuoted ::
    FilePath ->
    SourceFragmentKind ->
    Char ->
    SourcePosition ->
    SourcePosition ->
    String ->
    String ->
    Either [Diagnostic] (String, SourcePosition, String)
consumeQuoted file kind delimiter start = loop
    where
        loop position _ [] = Left [unterminated file kind start position]
        loop position reversed input@(character : remaining)
            | character == delimiter =
                let end = advanceText position [delimiter]
                 in Right (reverse (delimiter : reversed), end, remaining)
            | character == '\\' = case remaining of
                [] -> Left [unterminated file kind start position]
                _ ->
                    let slashEnd = advanceText position "\\"
                        (escaped, rest, end) = consumeSourceUnit slashEnd remaining
                     in loop end (reverse escaped ++ '\\' : reversed) rest
            | otherwise =
                let (unit, rest, end) = consumeSourceUnit position input
                 in loop end (reverse unit ++ reversed) rest

consumeLong ::
    FilePath ->
    SourceFragmentKind ->
    SourcePosition ->
    SourcePosition ->
    String ->
    Int ->
    String ->
    Either [Diagnostic] (String, SourcePosition, String)
consumeLong file kind start initialPosition prefix initialLevel initialInput =
    loop initialPosition (reverse prefix) initialLevel initialInput
    where
        closer currentLevel = ']' : replicate currentLevel '=' ++ "]"
        loop currentPosition reversedPrefix currentLevel currentInput
            | Just remaining <- stripPrefix (closer currentLevel) currentInput =
                let closing = closer currentLevel
                    end = advanceText currentPosition closing
                 in Right (reverse reversedPrefix ++ closing, end, remaining)
            | null currentInput = Left [unterminated file kind start currentPosition]
            | otherwise =
                let (unit, rest, end) = consumeSourceUnit currentPosition currentInput
                 in loop end (reverse unit ++ reversedPrefix) currentLevel rest

unterminated :: FilePath -> SourceFragmentKind -> SourcePosition -> SourcePosition -> Diagnostic
unterminated file kind start end =
    Diagnostic
        LexerStage
        Error
        (diagnosticCodeFor kind)
        (Just (SourceSpan file start end))
        ("unterminated " ++ description kind)
    where
        diagnosticCodeFor StringLiteralFragment = "TAL0101"
        diagnosticCodeFor CharacterLiteralFragment = "TAL0102"
        diagnosticCodeFor RawStringLiteralFragment = "TAL0103"
        diagnosticCodeFor LongCommentFragment = "TAL0104"
        diagnosticCodeFor _ = "TAL0105"
        description StringLiteralFragment = "string literal"
        description CharacterLiteralFragment = "character literal"
        description RawStringLiteralFragment = "raw string literal"
        description LongCommentFragment = "long comment"
        description _ = "source fragment"

longBracketOpener :: String -> Maybe (Int, String, String)
longBracketOpener ('[' : remaining) =
    let (equals, suffix) = span (== '=') remaining
     in case suffix of
            '[' : content ->
                let opener = '[' : equals ++ "["
                 in Just (length equals, opener, content)
            _ -> Nothing
longBracketOpener _ = Nothing

consumeSourceUnit :: SourcePosition -> String -> (String, String, SourcePosition)
consumeSourceUnit (SourcePosition line _) ('\r' : '\n' : remaining) =
    ("\r\n", remaining, SourcePosition (line + 1) 1)
consumeSourceUnit (SourcePosition line _) ('\r' : remaining) =
    ("\r", remaining, SourcePosition (line + 1) 1)
consumeSourceUnit (SourcePosition line _) ('\n' : remaining) =
    ("\n", remaining, SourcePosition (line + 1) 1)
consumeSourceUnit (SourcePosition line column) (character : remaining) =
    ([character], remaining, SourcePosition line (column + 1))
consumeSourceUnit position [] = ("", [], position)

advanceText :: SourcePosition -> String -> SourcePosition
advanceText position [] = position
advanceText position input =
    let (_, remaining, next) = consumeSourceUnit position input
     in advanceText next remaining

isLineBreak :: Char -> Bool
isLineBreak character = character == '\r' || character == '\n'

-- | Reassemble the original source by concatenating fragment text.
reconstructSource :: [SourceFragment] -> String
reconstructSource = concatMap sourceFragmentText

{- | Retain code and physical line endings while hiding protected payloads.
The result has the same character count and line structure as the source.
-}
maskedSource :: [SourceFragment] -> String
maskedSource = concatMap mask
    where
        mask value
            | sourceFragmentKind value == CodeFragment = sourceFragmentText value
            | otherwise = map hide (sourceFragmentText value)
        hide character
            | isLineBreak character = character
            | otherwise = ' '

{- | Lines crossed by a multi-line protected fragment cannot be reindented or
trimmed without potentially changing literal/comment payload text.
-}
protectedLineNumbers :: [SourceFragment] -> [Int]
protectedLineNumbers = deduplicate . concatMap coveredLines
    where
        coveredLines value
            | sourceFragmentKind value == CodeFragment = []
            | startLine == endLine = []
            | otherwise = [startLine .. endLine]
            where
                SourcePosition startLine _ = sourceStart (sourceFragmentSpan value)
                SourcePosition endLine _ = sourceEnd (sourceFragmentSpan value)
        -- Fragments are emitted in source order, so covered line ranges are also
        -- ordered and can overlap only at boundaries. Adjacent deduplication keeps
        -- this operation linear even for very large raw literals.
        deduplicate [] = []
        deduplicate (value : remaining) = value : deduplicate (dropWhile (== value) remaining)
