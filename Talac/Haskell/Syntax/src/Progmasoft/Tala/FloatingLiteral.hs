-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

-- | Source-accurate floating-point literal scanning and validation.
module Progmasoft.Tala.FloatingLiteral
    ( FloatingLiteralError (..)
    , scanNumericCandidate
    , isFloatingCandidate
    , normalizeFloatingSpelling
    , validateFloatingSpelling
    , renderFloatingLiteralError
    ) where

import Data.Char (isAlphaNum, isDigit)

-- | Reason that a floating-point spelling is not valid in Tala.
data FloatingLiteralError
    = MissingFractionDigits
    | MissingExponentDigits
    | SeparatorOutsideDigitPair
    | SeparatorInsideExponent
    | MultipleDecimalPoints
    | MultipleExponents
    | InvalidFloatingCharacter Char
    | FloatingSuffixNotSupported
    deriving stock (Eq, Ord, Read, Show)

-- The sign is consumed only immediately after e/E. This prevents 1+2 from
-- becoming one malformed literal while retaining 2E-4 as one token.

{- | Consume one source-shaped numeric candidate and return the remaining text.
A sign belongs to the token only immediately after an exponent marker.
-}
scanNumericCandidate :: String -> (String, String)
scanNumericCandidate = go [] False
    where
        go output _ [] = (reverse output, [])
        go output afterExponent (character : remaining)
            | isAlphaNum character || character `elem` ['\'', '_', '.'] =
                go (character : output) (character `elem` ['e', 'E']) remaining
            | afterExponent && character `elem` ['+', '-'] = go (character : output) False remaining
            | otherwise = (reverse output, character : remaining)

{- | Decide whether a numeric candidate has a decimal or exponent marker.
Radix-prefixed integer candidates are deliberately excluded.
-}
isFloatingCandidate :: String -> Bool
isFloatingCandidate spelling
    | take 2 spelling `elem` ["0x", "0X", "0b", "0B", "0o", "0O"] = False
    | otherwise = any (`elem` spelling) ['.', 'e', 'E']

-- | Remove digit separators without otherwise changing the spelling.
normalizeFloatingSpelling :: String -> String
normalizeFloatingSpelling = filter (/= '\'')

-- | Validate a decimal floating spelling and return its normalized form.
validateFloatingSpelling :: String -> Either FloatingLiteralError String
validateFloatingSpelling spelling = do
    validateCharacters spelling
    validateCounts spelling
    validateSeparators spelling
    validateStructure spelling
    pure (normalizeFloatingSpelling spelling)

validateCharacters :: String -> Either FloatingLiteralError ()
validateCharacters = go
    where
        go [] = Right ()
        go (character : remaining)
            | isDigit character || character `elem` ['\'', '.', 'e', 'E', '+', '-'] = go remaining
            | isAlphaNum character || character == '_' = Left FloatingSuffixNotSupported
            | otherwise = Left (InvalidFloatingCharacter character)

validateCounts :: String -> Either FloatingLiteralError ()
validateCounts spelling
    | count '.' spelling > 1 = Left MultipleDecimalPoints
    | count 'e' lower > 1 = Left MultipleExponents
    | otherwise = Right ()
    where
        lower = map lowercaseExponent spelling
        lowercaseExponent 'E' = 'e'
        lowercaseExponent value = value

validateSeparators :: String -> Either FloatingLiteralError ()
validateSeparators spelling = go False spelling
    where
        go _ [] = Right ()
        go _ ('e' : remaining) = go True remaining
        go _ ('E' : remaining) = go True remaining
        go True ('\'' : _) = Left SeparatorInsideExponent
        go False (left : '\'' : right : remaining)
            | isDigit left && isDigit right = go False (right : remaining)
            | otherwise = Left SeparatorOutsideDigitPair
        go _ ('\'' : _) = Left SeparatorOutsideDigitPair
        go inExponent (_ : remaining) = go inExponent remaining

validateStructure :: String -> Either FloatingLiteralError ()
validateStructure spelling =
    let normalized = normalizeFloatingSpelling spelling
        (mantissa, exponentPart) = break (`elem` ['e', 'E']) normalized
     in do
            validateMantissa mantissa
            validateExponent exponentPart

validateMantissa :: String -> Either FloatingLiteralError ()
validateMantissa mantissa = case break (== '.') mantissa of
    (integerPart, [])
        | null integerPart || any (not . isDigit) integerPart -> Left MissingFractionDigits
        | otherwise -> Right ()
    (integerPart, _ : fractionPart)
        | null integerPart || any (not . isDigit) integerPart -> Left MissingFractionDigits
        | null fractionPart || any (not . isDigit) fractionPart -> Left MissingFractionDigits
        | otherwise -> Right ()

validateExponent :: String -> Either FloatingLiteralError ()
validateExponent [] = Right ()
validateExponent (_ : remaining) =
    let digits = case remaining of sign : rest | sign `elem` ['+', '-'] -> rest; _ -> remaining
     in if null digits || any (not . isDigit) digits then Left MissingExponentDigits else Right ()

-- | Render a floating-literal failure for a source diagnostic.
renderFloatingLiteralError :: FloatingLiteralError -> String
renderFloatingLiteralError issue = case issue of
    MissingFractionDigits -> "floating-point literal requires digits on both sides of the decimal point"
    MissingExponentDigits -> "floating-point exponent requires decimal digits"
    SeparatorOutsideDigitPair -> "apostrophe must appear between two digits of the floating-point mantissa"
    SeparatorInsideExponent -> "apostrophe is not allowed in a floating-point exponent"
    MultipleDecimalPoints -> "floating-point literal contains more than one decimal point"
    MultipleExponents -> "floating-point literal contains more than one exponent marker"
    InvalidFloatingCharacter character -> show character ++ " is not valid in a floating-point literal"
    FloatingSuffixNotSupported -> "floating-point literal suffixes are not supported"

count :: (Eq a) => a -> [a] -> Int
count value = length . filter (== value)
