-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

-- | Decoder and u32 packer for Tala character literals.
module Progmasoft.Tala.CharacterLiteral
    ( CharacterLiteralError (..)
    , scanCharacterLiteral
    , parseCharacterLiteral
    , renderCharacterLiteralError
    ) where

import Data.Char (digitToInt, isHexDigit, ord)

-- | Failure reason while scanning or decoding a character literal.
data CharacterLiteralError
    = UnterminatedCharacterLiteral
    | EmptyCharacterLiteral
    | PhysicalLineBreakInCharacterLiteral
    | UnsupportedCharacterEscape Char
    | MissingHexadecimalEscapeDigits
    | WrongUnicodeEscapeWidth Int
    | InvalidUnicodeEscapeDigit Char
    | InvalidUnicodeScalar Integer
    | CharacterLiteralOverflow
    deriving stock (Eq, Ord, Read, Show)

{- | Scan through the closing quote while respecting escaped quotes. The
opening quote is supplied as part of the input and retained in the token.
-}
scanCharacterLiteral :: String -> Either CharacterLiteralError (String, String)
scanCharacterLiteral ('\'' : remaining) = go ['\''] False remaining
    where
        go _ _ [] = Left UnterminatedCharacterLiteral
        go prefix escaped (character : rest)
            | character == '\n' || character == '\r' = Left PhysicalLineBreakInCharacterLiteral
            | character == '\'' && not escaped = Right (reverse ('\'' : prefix), rest)
            | character == '\\' && not escaped = go ('\\' : prefix) True rest
            | otherwise = go (character : prefix) False rest
scanCharacterLiteral _ = Left UnterminatedCharacterLiteral

{- | Decode a complete character token and pack its Unicode scalar values.
The result uses the compiler's stable little-endian u32 character packing.
-}
parseCharacterLiteral :: String -> Either CharacterLiteralError Integer
parseCharacterLiteral spelling = case spelling of
    '\'' : content -> case reverse content of
        '\'' : reversedBody -> do
            values <- decodeCharacters (reverse reversedBody)
            if null values
                then Left EmptyCharacterLiteral
                else pack values
        _ -> Left UnterminatedCharacterLiteral
    _ -> Left UnterminatedCharacterLiteral

decodeCharacters :: String -> Either CharacterLiteralError [Integer]
decodeCharacters [] = Right []
decodeCharacters ('\\' : remaining) = do
    (value, rest) <- decodeEscape remaining
    (value :) <$> decodeCharacters rest
decodeCharacters (character : remaining) =
    (fromIntegral (ord character) :) <$> decodeCharacters remaining

decodeEscape :: String -> Either CharacterLiteralError (Integer, String)
decodeEscape [] = Left UnterminatedCharacterLiteral
decodeEscape (escape : remaining) = case escape of
    '\'' -> simple '\''
    '"' -> simple '"'
    '\\' -> simple '\\'
    '0' -> simple '\0'
    'a' -> simple '\a'
    'b' -> simple '\b'
    'e' -> Right (0x1b, remaining)
    'f' -> simple '\f'
    'n' -> simple '\n'
    'r' -> simple '\r'
    't' -> simple '\t'
    'v' -> simple '\v'
    'x' -> decodeVariableHex remaining
    'u' -> decodeFixedHex 4 remaining
    'U' -> decodeFixedHex 8 remaining
    _ -> Left (UnsupportedCharacterEscape escape)
    where
        simple character = Right (fromIntegral (ord character), remaining)

decodeVariableHex :: String -> Either CharacterLiteralError (Integer, String)
decodeVariableHex input =
    let (digits, remaining) = span isHexDigit input
     in if null digits
            then Left MissingHexadecimalEscapeDigits
            else scalarValue digits remaining

decodeFixedHex :: Int -> String -> Either CharacterLiteralError (Integer, String)
decodeFixedHex width input =
    let (digits, remaining) = splitAt width input
     in if length digits /= width
            then Left (WrongUnicodeEscapeWidth width)
            else case filter (not . isHexDigit) digits of
                invalid : _ -> Left (InvalidUnicodeEscapeDigit invalid)
                [] -> scalarValue digits remaining

scalarValue :: String -> String -> Either CharacterLiteralError (Integer, String)
scalarValue digits remaining =
    let value = foldl' (\total digit -> total * 16 + fromIntegral (digitToInt digit)) 0 digits
     in if value > 0x10ffff || value >= 0xd800 && value <= 0xdfff
            then Left (InvalidUnicodeScalar value)
            else Right (value, remaining)

pack :: [Integer] -> Either CharacterLiteralError Integer
pack = foldl append (Right 0)
    where
        append result next = do
            value <- result
            let width = encodedByteWidth next
                packed = value * (256 ^ width) + next
            if packed > 0xffffffff
                then Left CharacterLiteralOverflow
                else Right packed

encodedByteWidth :: Integer -> Integer
encodedByteWidth value
    | value <= 0xff = 1
    | value <= 0xffff = 2
    | value <= 0xffffff = 3
    | otherwise = 4

-- | Render a character-literal failure for a source diagnostic.
renderCharacterLiteralError :: CharacterLiteralError -> String
renderCharacterLiteralError issue = case issue of
    UnterminatedCharacterLiteral -> "unterminated character literal"
    EmptyCharacterLiteral -> "character literal must contain at least one value"
    PhysicalLineBreakInCharacterLiteral -> "physical line break is not allowed in a character literal"
    UnsupportedCharacterEscape escape -> "unsupported character escape \\" ++ [escape]
    MissingHexadecimalEscapeDigits -> "hexadecimal character escape requires at least one digit"
    WrongUnicodeEscapeWidth width -> "Unicode character escape requires exactly " ++ show width ++ " digits"
    InvalidUnicodeEscapeDigit digit -> show digit ++ " is not a hexadecimal escape digit"
    InvalidUnicodeScalar value -> show value ++ " is not a Unicode scalar value"
    CharacterLiteralOverflow -> "packed character literal does not fit u32"
