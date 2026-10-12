-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | What the formatter says about a file without changing it.

A report is made from the text of a file and the text the formatter would
write. The two are compared line by line; a run of lines that differ is a
'Mismatch'. The reports of @--emit=coverage@, @--emit=checkstyle@ and
@--emit=json@ are three ways of writing the same mismatches.
-}
module Progmasoft.Talafmt.Report
    ( Mismatch (..)
    , FileReport (..)
    , Coverage (..)
    , fileReport
    , mismatches
    , coverage
    , renderCoverage
    , renderCheckstyle
    , renderJson
    ) where

import Data.Char (ord)
import Data.List (intercalate)
import Numeric (showHex)

{- | A run of lines the formatter would replace.

Line numbers start at one. A range whose end is one less than its beginning
is empty: the formatter only adds lines there, or only removes them.
-}
data Mismatch = Mismatch
    { mismatchOriginalBegin :: Int
    , mismatchOriginalEnd :: Int
    , mismatchExpectedBegin :: Int
    , mismatchExpectedEnd :: Int
    , mismatchOriginal :: [String]
    -- ^ The lines as they are in the file.
    , mismatchExpected :: [String]
    -- ^ The lines the formatter would write in their place.
    }
    deriving (Eq, Ord, Read, Show)

-- | The mismatches of one file.
data FileReport = FileReport
    { reportPath :: FilePath
    , reportLineCount :: Int
    -- ^ Lines of the file as it is.
    , reportMismatches :: [Mismatch]
    }
    deriving (Eq, Ord, Read, Show)

-- | How much of a file is already formatted.
data Coverage = Coverage
    { coverageFormatted :: Int
    , coverageTotal :: Int
    }
    deriving (Eq, Ord, Read, Show)

-- | Compare a file with what the formatter would write.
fileReport :: FilePath -> String -> String -> FileReport
fileReport path original expected =
    FileReport path (length (contentLines original)) (mismatches original expected)

{- | The runs of lines that differ.

The formatter changes lines in place far more often than it adds or removes
them, so texts with the same number of lines are compared position by
position, which names each changed run exactly. Texts of different length
are compared after their common beginning and common end are set aside; what
is left between them is one mismatch.
-}
mismatches :: String -> String -> [Mismatch]
mismatches original expected
    | originalLines == expectedLines = []
    | length originalLines == length expectedLines = positional 1 (zip originalLines expectedLines)
    | otherwise = [between]
    where
        originalLines = pieces original
        expectedLines = pieces expected

        positional _ [] = []
        positional line pairs = case span (uncurry (==)) pairs of
            (_, []) -> []
            (same, rest) ->
                let (different, after) = break (uncurry (==)) rest
                    begin = line + length same
                    end = begin + length different - 1
                 in Mismatch begin end begin end (map fst different) (map snd different)
                        : positional (end + 1) after

        prefix = length (takeWhile id (zipWith (==) originalLines expectedLines))
        originalRest = drop prefix originalLines
        expectedRest = drop prefix expectedLines
        suffix = length (takeWhile id (zipWith (==) (reverse originalRest) (reverse expectedRest)))
        originalMiddle = take (length originalRest - suffix) originalRest
        expectedMiddle = take (length expectedRest - suffix) expectedRest
        between =
            Mismatch
                (prefix + 1)
                (prefix + length originalMiddle)
                (prefix + 1)
                (prefix + length expectedMiddle)
                originalMiddle
                expectedMiddle

{- | The text between line feeds. A text that ends with a line feed has an
empty last piece, so that a missing final newline is a difference like any
other.
-}
pieces :: String -> [String]
pieces text = case break (== '\n') text of
    (piece, []) -> [piece]
    (piece, _ : rest) -> piece : pieces rest

-- | The lines of a text as an editor counts them.
contentLines :: String -> [String]
contentLines text = case reverse (pieces text) of
    "" : others -> reverse others
    _ -> pieces text

-- | Lines outside every mismatch count as formatted.
coverage :: FileReport -> Coverage
coverage report = Coverage (max 0 (total - changed)) total
    where
        total = reportLineCount report
        changed =
            sum
                [ min total (mismatchOriginalEnd mismatch) - mismatchOriginalBegin mismatch + 1
                | mismatch <- reportMismatches report
                , mismatchOriginalBegin mismatch <= total
                , mismatchOriginalEnd mismatch >= mismatchOriginalBegin mismatch
                ]

-- | One line per file: how many of its lines are already formatted.
renderCoverage :: [FileReport] -> String
renderCoverage = unlines . map line
    where
        line report =
            let measured = coverage report
             in reportPath report
                    ++ ": "
                    ++ show (coverageFormatted measured)
                    ++ " of "
                    ++ show (coverageTotal measured)
                    ++ " lines formatted ("
                    ++ show (percent measured)
                    ++ "%)"
        percent measured
            | coverageTotal measured == 0 = 100 :: Int
            | otherwise = coverageFormatted measured * 100 `div` coverageTotal measured

{- | The mismatches in the checkstyle format: one @file@ element per file and
one @error@ element per run of lines that would change.
-}
renderCheckstyle :: [FileReport] -> String
renderCheckstyle reports =
    unlines
        ( ["<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<checkstyle version=\"4.3\">"]
            ++ concatMap file reports
            ++ ["</checkstyle>"]
        )
    where
        file report =
            ["  <file name=\"" ++ xmlText (reportPath report) ++ "\">"]
                ++ map problem (reportMismatches report)
                ++ ["  </file>"]
        problem mismatch =
            "    <error line=\""
                ++ show (mismatchOriginalBegin mismatch)
                ++ "\" severity=\"warning\" source=\"talafmt\" message=\""
                ++ xmlText (describe mismatch)
                ++ "\" />"
        describe mismatch = case mismatchExpected mismatch of
            [] -> "these lines should be removed"
            [expected] -> "should be `" ++ expected ++ "`"
            expected@(first : _) ->
                "should be " ++ show (length expected) ++ " lines beginning with `" ++ first ++ "`"

xmlText :: String -> String
xmlText = concatMap escape
    where
        escape character = case character of
            '&' -> "&amp;"
            '<' -> "&lt;"
            '>' -> "&gt;"
            '"' -> "&quot;"
            '\'' -> "&apos;"
            '\r' -> "&#13;"
            '\t' -> "&#9;"
            _ -> [character]

{- | The mismatches as JSON: an array with one object per file that has any,
each with its @name@ and its @mismatches@.
-}
renderJson :: [FileReport] -> String
renderJson reports = "[" ++ intercalate "," (map file (filter (not . null . reportMismatches) reports)) ++ "]\n"
    where
        file report =
            "{\"name\":"
                ++ jsonText (reportPath report)
                ++ ",\"mismatches\":["
                ++ intercalate "," (map mismatch (reportMismatches report))
                ++ "]}"
        mismatch value =
            "{\"original_begin_line\":"
                ++ show (mismatchOriginalBegin value)
                ++ ",\"original_end_line\":"
                ++ show (mismatchOriginalEnd value)
                ++ ",\"expected_begin_line\":"
                ++ show (mismatchExpectedBegin value)
                ++ ",\"expected_end_line\":"
                ++ show (mismatchExpectedEnd value)
                ++ ",\"original\":"
                ++ jsonText (intercalate "\n" (mismatchOriginal value))
                ++ ",\"expected\":"
                ++ jsonText (intercalate "\n" (mismatchExpected value))
                ++ "}"

jsonText :: String -> String
jsonText text = "\"" ++ concatMap escape text ++ "\""
    where
        escape character = case character of
            '"' -> "\\\""
            '\\' -> "\\\\"
            '\n' -> "\\n"
            '\r' -> "\\r"
            '\t' -> "\\t"
            _
                | ord character < 0x20 -> "\\u" ++ pad (showHex (ord character) "")
                | otherwise -> [character]
        pad digits = replicate (4 - length digits) '0' ++ digits
