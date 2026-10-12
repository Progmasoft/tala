-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Lexical rules for Tala integer literals.

This module deliberately owns spelling validation rather than leaving it to
'read'.  The language has radix-sensitive apostrophe separators, rejects
octal notation, and must report malformed literals as one source token.
-}
module Progmasoft.Tala.NumericLiteral
    ( IntegerRadix (..)
    , ParsedInteger (..)
    , IntegerLiteralError (..)
    , scanIntegerSpelling
    , parseIntegerSpelling
    , renderIntegerLiteralError
    ) where

import Data.Char (digitToInt, isAlphaNum, isDigit, isHexDigit)

-- | Radix supported by a Tala integer literal.
data IntegerRadix = BinaryRadix | DecimalRadix | HexadecimalRadix
    deriving stock (Bounded, Enum, Eq, Ord, Read, Show)

-- | Validated radix, mathematical value, and separator-free digit sequence.
data ParsedInteger = ParsedInteger
    { parsedIntegerRadix :: IntegerRadix
    , parsedIntegerValue :: Integer
    , parsedIntegerDigits :: String
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Failure reason for scanning or validating an integer spelling.
data IntegerLiteralError
    = MissingDigits IntegerRadix
    | UnsupportedOctalPrefix
    | InvalidDigit IntegerRadix Char
    | SeparatorAtStart IntegerRadix
    | SeparatorAtEnd IntegerRadix
    | ConsecutiveSeparators IntegerRadix
    | SeparatorTouchesInvalidDigit IntegerRadix
    | IntegerLiteralContinuesWithIdentifier
    deriving stock (Eq, Ord, Read, Show)

{- | Consume the entire source-shaped candidate.  Invalid radix digits and
identifier tails remain attached so the lexer emits one useful diagnostic
instead of an integer followed by a misleading name token.
-}
scanIntegerSpelling :: String -> (String, String)
scanIntegerSpelling = span isCandidate
    where
        isCandidate character = isAlphaNum character || character == '\'' || character == '_'

-- | Parse a complete integer spelling, rejecting octal and malformed separators.
parseIntegerSpelling :: String -> Either IntegerLiteralError ParsedInteger
parseIntegerSpelling spelling
    | hasPrefix "0o" spelling || hasPrefix "0O" spelling = Left UnsupportedOctalPrefix
    | hasPrefix "0x" spelling || hasPrefix "0X" spelling = parseDigits HexadecimalRadix (drop 2 spelling)
    | hasPrefix "0b" spelling || hasPrefix "0B" spelling = parseDigits BinaryRadix (drop 2 spelling)
    | otherwise = parseDigits DecimalRadix spelling

parseDigits :: IntegerRadix -> String -> Either IntegerLiteralError ParsedInteger
parseDigits radix digits
    | null digits = Left (MissingDigits radix)
    | startsWithSeparator digits = Left (SeparatorAtStart radix)
    | endsWithSeparator digits = Left (SeparatorAtEnd radix)
    | "''" `contains` digits = Left (ConsecutiveSeparators radix)
    | otherwise = do
        validateSeparatorNeighbors radix digits
        validateDigits radix digits
        let compact = filter (/= '\'') digits
        pure
            ParsedInteger
                { parsedIntegerRadix = radix
                , parsedIntegerValue = foldl (accumulate radix) 0 compact
                , parsedIntegerDigits = compact
                }

startsWithSeparator :: String -> Bool
startsWithSeparator ('\'' : _) = True
startsWithSeparator _ = False

endsWithSeparator :: String -> Bool
endsWithSeparator = startsWithSeparator . reverse

validateSeparatorNeighbors :: IntegerRadix -> String -> Either IntegerLiteralError ()
validateSeparatorNeighbors radix = go
    where
        go (left : '\'' : right : remaining)
            | validDigit radix left && validDigit radix right = go (right : remaining)
            | otherwise = Left (SeparatorTouchesInvalidDigit radix)
        go (_ : remaining) = go remaining
        go _ = Right ()

validateDigits :: IntegerRadix -> String -> Either IntegerLiteralError ()
validateDigits radix = go
    where
        go [] = Right ()
        go ('\'' : remaining) = go remaining
        go (character : remaining)
            | validDigit radix character = go remaining
            | isAlphaNum character || character == '_' = Left (InvalidDigit radix character)
            | otherwise = Left IntegerLiteralContinuesWithIdentifier

validDigit :: IntegerRadix -> Char -> Bool
validDigit BinaryRadix character = character == '0' || character == '1'
validDigit DecimalRadix character = isDigit character
validDigit HexadecimalRadix character = isHexDigit character

accumulate :: IntegerRadix -> Integer -> Char -> Integer
accumulate radix value digit = value * radixValue radix + fromIntegral (digitToInt digit)

radixValue :: IntegerRadix -> Integer
radixValue BinaryRadix = 2
radixValue DecimalRadix = 10
radixValue HexadecimalRadix = 16

-- | Render an integer-literal failure for a source diagnostic.
renderIntegerLiteralError :: IntegerLiteralError -> String
renderIntegerLiteralError issue = case issue of
    MissingDigits radix -> radixName radix ++ " literal requires at least one digit"
    UnsupportedOctalPrefix -> "octal integer literals do not exist; use decimal, hexadecimal, or binary"
    InvalidDigit radix character -> show character ++ " is not a valid " ++ radixName radix ++ " digit"
    SeparatorAtStart radix -> "apostrophe cannot begin the digits of a " ++ radixName radix ++ " literal"
    SeparatorAtEnd radix -> "apostrophe cannot end a " ++ radixName radix ++ " literal"
    ConsecutiveSeparators radix -> "consecutive apostrophes are invalid in a " ++ radixName radix ++ " literal"
    SeparatorTouchesInvalidDigit radix ->
        "apostrophe must appear between two valid " ++ radixName radix ++ " digits"
    IntegerLiteralContinuesWithIdentifier -> "integer literal cannot continue with identifier characters"

radixName :: IntegerRadix -> String
radixName BinaryRadix = "binary"
radixName DecimalRadix = "decimal"
radixName HexadecimalRadix = "hexadecimal"

hasPrefix :: String -> String -> Bool
hasPrefix prefix value = take (length prefix) value == prefix

contains :: String -> String -> Bool
contains needle haystack
    | length needle > length haystack = False
    | take (length needle) haystack == needle = True
    | otherwise = contains needle (drop 1 haystack)
