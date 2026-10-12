-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Warnings about source text that is valid but probably not what its
author meant.

A warning never changes what a program means and never rejects it. The only
warning today concerns the spelling of the removed decrement operator.
Tala has no decrement: @--@ starts a comment wherever it stands outside
a string. Text written for an earlier compiler, or by habit from another
language, may still say @count--;@ or @--count;@. Both are now a comment,
and the statement terminator after them is part of that comment, so the
program can keep compiling with a different meaning. This module points at
those two spellings.
-}
module Progmasoft.Tala.SourceWarnings
    ( sourceWarnings
    , decrementSpellingCode
    ) where

import Data.Char (isAlpha, isAlphaNum, isSpace)
import Progmasoft.Tala.AST (SourcePosition (..), SourceSpan (..))
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.SourceText

-- | Code of the warning for a comment that looks like a decrement.
decrementSpellingCode :: String
decrementSpellingCode = "TAL0009"

{- | Warnings for one source text, in source order.

A text the lossless scanner rejects has no warnings: its lexical error is
reported by the lexer, and a warning about the same text would only repeat
it.
-}
sourceWarnings :: FilePath -> String -> [Diagnostic]
sourceWarnings file text = case scanSourceFragments file text of
    Left _ -> []
    Right fragments -> concat (zipWith decrementSpelling (Nothing : map Just fragments) fragments)

{- | Warn when a line comment has one of the two decrement spellings.

* Attached: the comment starts directly after a name, a closing parenthesis
  or a closing bracket, as in @count--;@.
* Leading: the comment text is a name directly after @--@, followed only by
  a statement terminator, as in @--count;@.

Documentation comments and long comments are never decrement spellings, and
a comment separated from the code by a space is an ordinary comment.
-}
decrementSpelling :: Maybe SourceFragment -> SourceFragment -> [Diagnostic]
decrementSpelling previous fragment
    | sourceFragmentKind fragment /= LineCommentFragment = []
    | otherwise = case sourceFragmentText fragment of
        '-' : '-' : body
            | isDocumentation body -> []
            | attached -> [warning attachedMessage]
            | isLeadingName body -> [warning leadingMessage]
        _ -> []
    where
        attached = case previous of
            Just code
                | sourceFragmentKind code == CodeFragment ->
                    case reverse (sourceFragmentText code) of
                        final : _ -> isAlphaNum final || final `elem` "_)]"
                        [] -> False
            _ -> False
        warning = Diagnostic LexerStage Warning decrementSpellingCode (Just signSpan)
        start = sourceStart (sourceFragmentSpan fragment)
        signSpan =
            SourceSpan
                (sourceFile (sourceFragmentSpan fragment))
                start
                (SourcePosition (sourceLine start) (sourceColumn start + 2))

isDocumentation :: String -> Bool
isDocumentation body = case body of
    '|' : _ -> True
    '!' : _ -> True
    _ -> False

-- | Whether a comment body is exactly a name and a statement terminator.
isLeadingName :: String -> Bool
isLeadingName body = case body of
    first : remaining
        | isAlpha first || first == '_' ->
            let afterName = dropWhile (\character -> isAlphaNum character || character == '_') remaining
             in case dropWhile isSpace afterName of
                    ';' : rest -> all isSpace rest
                    _ -> False
    _ -> False

attachedMessage :: String
attachedMessage =
    "'--' starts a comment here and does not decrement: Tala has no decrement operator. "
        ++ "Write 'name -= 1', or put a space before '--' if a comment is intended"

leadingMessage :: String
leadingMessage =
    "'--' starts a comment here and does not decrement: Tala has no decrement operator. "
        ++ "Write 'name -= 1', or put a space after '--' if a comment is intended"
