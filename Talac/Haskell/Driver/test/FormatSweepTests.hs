-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Every conversion that can be written, against the rules stated a second time.

"RuntimeCallTests" holds formats chosen by hand. This module writes all of
them: every set of flags, with and without a width and a precision, each
written as a number and as a star, for every conversion letter. What the
reader of formats makes of each is compared with a prediction that is
written here from the rules alone and shares nothing with the reader:

* a conversion takes the flags of its row and no other;
* @-@ excludes @0@, and @+@ excludes the space;
* a precision is taken by @%f@ and @%s@;
* @%n@ and @%%@ take nothing at all.

The same sweep is then run through the reference text functions, where the
properties of a field hold whatever the conversion: it is never shorter than
its width, padding is all it adds, and a value at the left is followed by
spaces only.
-}
module FormatSweepTests (formatSweepTests) where

import Data.Char (isDigit)
import Data.List (isPrefixOf, isSuffixOf, subsequences)
import RuntimeText qualified as Reference
import Progmasoft.Tala.RuntimeCall
import Progmasoft.Tala.TypeChecker.Format

formatSweepTests :: [(String, Bool)]
formatSweepTests =
    [ ("every way to write %" ++ [letter] ++ " is read as the rules say", all agrees (written letter))
    | letter <- letters
    ]
        ++ [ ("the sweep writes every combination", length (concatMap written letters) == 9 * 64 * 3 * 3)
           , ("the sweep holds formats that are accepted", any ((== Accepted) . predicted) (concatMap written letters))
           , ("the sweep holds formats that are rejected", any ((== Rejected) . predicted) (concatMap written letters))
           , ("a letter outside the grammar is never a conversion", all (unknown . (: [])) (filter (`notElem` letters ++ "AO") ['a' .. 'z'] ++ ['B' .. 'N']))
           , ("an integer field is never shorter than its width", and [length (integerField value) >= maybe 0 id width | value@(_, width, _) <- integerCases])
           , ("an integer field without a width is the number itself", and [integerField (flags, Nothing, value) == unpadded flags value | (flags, _, value) <- integerCases])
           , ("padding is all a width adds to an integer", all paddingOnly integerCases)
           , ("a value at the left is followed by spaces only", all leftAligned integerCases)
           , ("zeros stand after the sign", all zerosAfterSign integerCases)
           , ("grouping adds apostrophes and nothing else", all groupingOnly [value | (_, _, value) <- integerCases])
           , ("groups have three digits, the first at most three", all groupsOfThree [value | (_, _, value) <- integerCases])
           , ("hexadecimal digits are those of the magnitude", all hexadecimalDigits [value | (_, _, value) <- integerCases])
           , ("a text field is never shorter than its width", and [length (textField width Nothing value) >= width | width <- [0 .. 9], value <- texts])
           , ("a precision is the most characters a text field keeps", and [textField 0 (Just precision) value == take precision value | precision <- [0 .. 9], value <- texts])
           , ("a fixed-point field has its precision's digits after the point", all fractionDigits fixedCases)
           , ("a fixed-point number with no digits after the point has no point", and ['.' `notElem` fixed 0 value | value <- rationals])
           , ("more digits never change the digits before them by more than rounding", all prefixStable rationals)
           ]
    where
        letters = "duxfscbn%"

-- ------------------------------------------------------------ the reader

-- | What the rules say of a format.
data Verdict = Accepted | Rejected
    deriving (Eq, Show)

-- | One conversion as it is written: flags, width, precision and letter.
type Written = (String, String, String, Char)

-- | Every way to write a conversion with the given letter.
written :: Char -> [Written]
written letter =
    [ (flags, width, precision, letter)
    | flags <- subsequences "-0+ #'"
    , width <- ["", "7", "*"]
    , precision <- ["", ".3", ".*"]
    ]

spelled :: Written -> String
spelled (flags, width, precision, letter) = "%" ++ flags ++ width ++ precision ++ [letter]

-- | The rules, from the specification, without the reader.
predicted :: Written -> Verdict
predicted (flags, width, precision, letter)
    | letter `elem` "n%" = if null flags && null width && null precision then Accepted else Rejected
    | any (`notElem` taken) flags = Rejected
    | '-' `elem` flags && '0' `elem` flags = Rejected
    | '+' `elem` flags && ' ' `elem` flags = Rejected
    | not (null precision) && letter `notElem` "fs" = Rejected
    | otherwise = Accepted
    where
        taken = case letter of
            'd' -> "-0+ '"
            'u' -> "-0'"
            'x' -> "-0#"
            'f' -> "-0+ '"
            _ -> "-"

{- | Whether the reader agrees with the rules, and, for an accepted
conversion, reads what was written: the flags as their bits, and one
argument more for each star.
-}
agrees :: Written -> Bool
agrees value@(flags, width, precision, letter) = case (predicted value, parseFormat (spelled value)) of
    (Rejected, Left problem) -> formatProblemCode problem == "TAT0076"
    (Accepted, Right [ConversionPiece conversion]) ->
        letter `notElem` "n%"
            && conversionLetter (conversionKind conversion) == letter
            && conversionFlagBits conversion == sum (map bit flags) + (if letter == 'x' then flagHexadecimal else 0)
            && conversionArgumentCount conversion == 1 + length (filter (== "*") [width, drop 1 precision])
            && conversionWidth conversion == size width
            && conversionPrecision conversion == size (drop 1 precision)
    (Accepted, Right [NewlinePiece]) -> letter == 'n'
    (Accepted, Right [LiteralPiece "%"]) -> letter == '%'
    _ -> False
    where
        bit flag = case flag of
            '-' -> flagLeft
            '0' -> flagZero
            '+' -> flagPlus
            ' ' -> flagSpace
            '#' -> flagAlternate
            _ -> flagGroup
        size text
            | null text = NoSize
            | text == "*" = ArgumentSize
            | otherwise = FixedSize (read text)

unknown :: String -> Bool
unknown letter = case parseFormat ('%' : letter) of
    Left problem -> formatProblemCode problem == "TAT0075"
    Right _ -> False

-- --------------------------------------------------- the reference fields

-- | Flags, a width when there is one, and a value.
type IntegerCase = (Integer, Maybe Int, Integer)

integerCases :: [IntegerCase]
integerCases =
    [ (flags, width, value)
    | flags <- [0, flagLeft, flagZero, flagPlus, flagSpace, flagGroup, flagPlus + flagZero, flagGroup + flagLeft, flagHexadecimal, flagHexadecimal + flagAlternate, flagHexadecimal + flagZero]
    , width <- [Nothing, Just 0, Just 1, Just 5, Just 12, Just 30]
    , value <- values
    ]
    where
        values =
            [0, 1, -1, 9, 10, -10, 99, 100, 999, 1000, -1000, 12345, 123456, 1234567, -1234567]
                ++ [2 ^ (63 :: Int) - 1, negate (2 ^ (63 :: Int)), 2 ^ (64 :: Int) - 1]

fieldOf :: Integer -> Maybe Int -> Reference.Conversion
fieldOf flags width = Reference.Conversion flags (maybe absent toInteger width) absent

integerField :: IntegerCase -> String
integerField (flags, width, value) = Reference.formatInteger (fieldOf flags width) value

unpadded :: Integer -> Integer -> String
unpadded flags = Reference.formatInteger (fieldOf flags Nothing)

has :: Integer -> Integer -> Bool
has flags flag = (flags `div` flag) `mod` 2 == 1

-- | A field is the number without a width, with padding and nothing else.
paddingOnly :: IntegerCase -> Bool
paddingOnly value@(flags, width, number) =
    length field == max (maybe 0 id width) (length plain)
        && filter (`notElem` " 0") plain `isSubsequence` field
        && length field >= maybe 0 id width
    where
        field = integerField value
        plain = unpadded flags number
        isSubsequence [] _ = True
        isSubsequence _ [] = False
        isSubsequence (x : xs) (y : ys)
            | x == y = isSubsequence xs ys
            | otherwise = isSubsequence (x : xs) ys

leftAligned :: IntegerCase -> Bool
leftAligned value@(flags, _, number)
    | has flags flagLeft = plain `isPrefixOf` field && all (== ' ') (drop (length plain) field)
    | otherwise = True
    where
        field = integerField value
        plain = unpadded flags number

-- | With the zero flag the field ends in the digits and begins with the sign.
zerosAfterSign :: IntegerCase -> Bool
zerosAfterSign value@(flags, _, number)
    | has flags flagZero && not (has flags flagLeft) =
        ' ' `notElem` dropWhile (== ' ') (drop (length sign) field)
            && sign `isPrefixOf` field
            && digits `isSuffixOf` field
    | otherwise = True
    where
        field = integerField value
        plain = unpadded flags number
        (sign, digits) = span (`elem` "+- ") plain

groupingOnly :: Integer -> Bool
groupingOnly value = filter (/= '\'') (unpadded flagGroup value) == unpadded 0 value

groupsOfThree :: Integer -> Bool
groupsOfThree value = case groups (dropWhile (== '-') (unpadded flagGroup value)) of
    first : rest -> not (null first) && length first <= 3 && all ((== 3) . length) rest && all (all isDigit) (first : rest)
    [] -> False
    where
        groups text = case break (== '\'') text of
            (group, _ : more) -> group : groups more
            (group, []) -> [group]

hexadecimalDigits :: Integer -> Bool
hexadecimalDigits value =
    all (`elem` "0123456789abcdef") digits
        && foldl (\total digit -> total * 16 + toInteger (position digit)) 0 digits == abs value
        && (value < 0) == ("-" `isPrefixOf` field)
    where
        field = unpadded flagHexadecimal value
        digits = dropWhile (== '-') field
        position digit = length (takeWhile (/= digit) "0123456789abcdef")

texts :: [String]
texts = ["", "a", "abc", "abcdefghij", "\233\8364"]

textField :: Int -> Maybe Int -> String -> String
textField width precision = Reference.formatText (Reference.Conversion 0 (toInteger width) (maybe absent toInteger precision))

rationals :: [Rational]
rationals = [0, 1, 1 / 2, 1 / 4, 1 / 8, 3 / 8, 5 / 2, 7 / 2, 12345 / 8, 1 / 1024, 999999 / 1000, 1234567 / 2]

fixed :: Integer -> Rational -> String
fixed precision = Reference.formatFloating (Reference.Conversion 0 absent precision) False

fixedCases :: [(Integer, Rational)]
fixedCases = [(precision, value) | precision <- [1 .. 12], value <- rationals]

fractionDigits :: (Integer, Rational) -> Bool
fractionDigits (precision, value) = case break (== '.') (fixed precision value) of
    (whole, _ : fraction) -> not (null whole) && all isDigit whole && length fraction == fromInteger precision && all isDigit fraction
    _ -> False

{- | With a precision large enough to hold every digit of the value, a
larger precision only appends zeros. These values are sums of powers of two
with at most ten binary places, or thousandths, so twelve digits hold the
binary ones exactly.
-}
prefixStable :: Rational -> Bool
prefixStable value
    | exact = fixed 20 value == fixed 12 value ++ replicate 8 '0'
    | otherwise = True
    where
        exact = fromRational (value * 1024) == (fromInteger (round (value * 1024)) :: Rational)
