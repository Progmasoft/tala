-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Physical source layout built on the compiler's lossless fragment model.

Only braces in code fragments affect indentation. Braces inside comments,
normal strings, character literals, and raw strings are masked by the compiler
before this module sees them. Lines crossed by multi-line protected fragments
are kept byte-for-byte apart from a requested line-ending conversion.
-}
module Progmasoft.Talafmt.Layout (formatLayout) where

import Data.List (intercalate, isPrefixOf)
import Progmasoft.Talafmt.Options
import Progmasoft.Tala.SourceText

formatLayout :: FormatOptions -> String -> [SourceFragment] -> String
formatLayout options source fragments =
    let newline = selectedLineEnding (formatLineEnding options) source
        normalized = normalizeLineEndings source
        normalizedMask = normalizeLineEndings (maskedSource fragments)
        sourceEndsWithNewline = not (null normalized) && last normalized == '\n'
        physicalLines = splitLogicalLines normalized
        maskLines = splitLogicalLines normalizedMask
        bodyLines = withoutTerminalLine sourceEndsWithNewline physicalLines
        bodyMasks = withoutTerminalLine sourceEndsWithNewline maskLines
        protected = protectedLineNumbers fragments
        formattedLines = reindentLines options protected (zip bodyLines bodyMasks)
        keepFinalNewline = not (null source) && (sourceEndsWithNewline || formatInsertFinalNewline options)
     in intercalate newline formattedLines ++ if keepFinalNewline then newline else ""

reindentLines :: FormatOptions -> [Int] -> [(String, String)] -> [String]
reindentLines options protected = go 1 0 protected
    where
        go _ _ _ [] = []
        go lineNumber depth protectedLines ((sourceLine, maskLine) : remaining) =
            let currentProtected = dropWhile (< lineNumber) protectedLines
                protectedLine = case currentProtected of
                    next : _ -> next == lineNumber
                    [] -> False
                remainingProtected = if protectedLine then drop 1 currentProtected else currentProtected
                trimmed = if formatTrimTrailingWhitespace options && not protectedLine then trimHorizontalEnd sourceLine else sourceLine
                code = dropHorizontalStart maskLine
                content = dropHorizontalStart trimmed
                hasCode = any (not . isHorizontalSpace) code
                commentOnly = "--" `isPrefixOf` content
                leadingClosings = length (takeWhile (== '}') code)
                lineDepth = max 0 (depth - leadingClosings)
                mayIndent = formatReindentBlocks options && not protectedLine && (hasCode || commentOnly)
                output = if mayIndent then indentation options lineDepth ++ content else trimmed
                nextDepth = max 0 (depth + braceBalance code)
             in output : go (lineNumber + 1) nextDepth remainingProtected remaining

braceBalance :: String -> Int
braceBalance = foldr count 0
    where
        count '{' total = total + 1
        count '}' total = total - 1
        count _ total = total

indentation :: FormatOptions -> Int -> String
indentation options depth
    | not (formatUseTabs options) = replicate columns ' '
    | otherwise = replicate tabCount '\t' ++ replicate spaceCount ' '
    where
        columns = depth * formatIndentWidth options
        (tabCount, spaceCount) = columns `divMod` formatTabWidth options

selectedLineEnding :: LineEnding -> String -> String
selectedLineEnding CrLf _ = "\r\n"
selectedLineEnding Lf _ = "\n"
selectedLineEnding Auto source = case firstLineEnding source of
    Just value -> value
    Nothing -> "\n"

firstLineEnding :: String -> Maybe String
firstLineEnding [] = Nothing
firstLineEnding ('\r' : '\n' : _) = Just "\r\n"
firstLineEnding ('\r' : _) = Just "\r"
firstLineEnding ('\n' : _) = Just "\n"
firstLineEnding (_ : remaining) = firstLineEnding remaining

normalizeLineEndings :: String -> String
normalizeLineEndings [] = []
normalizeLineEndings ('\r' : '\n' : remaining) = '\n' : normalizeLineEndings remaining
normalizeLineEndings ('\r' : remaining) = '\n' : normalizeLineEndings remaining
normalizeLineEndings (character : remaining) = character : normalizeLineEndings remaining

splitLogicalLines :: String -> [String]
splitLogicalLines source = case break (== '\n') source of
    (line, []) -> [line]
    (line, _ : remaining) -> line : splitLogicalLines remaining

withoutTerminalLine :: Bool -> [value] -> [value]
withoutTerminalLine False values = values
withoutTerminalLine True [] = []
withoutTerminalLine True [_] = []
withoutTerminalLine True (value : remaining) = value : withoutTerminalLine True remaining

dropHorizontalStart :: String -> String
dropHorizontalStart = dropWhile isHorizontalSpace

trimHorizontalEnd :: String -> String
trimHorizontalEnd = reverse . dropWhile isHorizontalSpace . reverse

isHorizontalSpace :: Char -> Bool
isHorizontalSpace character = character == ' ' || character == '\t'
