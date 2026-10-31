-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | The output format grammar of @Console.Printf@ and @Console.Format@.

A format is a compile-time string. It is read here, once, into literal text
and conversions, and everything about it that does not depend on the types
of the arguments is decided here: which conversions exist, which flags each
one takes, which flags exclude each other, and where a width or a precision
may stand. A format that is wrong is an error of the program, found when it
is compiled; nothing about a format is left to be discovered while the
program runs.

A conversion is written

> % flags width .precision letter

where the flags are any of @-@, @0@, @+@, a space, @#@ and @'@; the width is
a decimal number or @*@; and the precision is a decimal number or @*@ after a
point. A @*@ takes the width or the precision from an @int@ argument that
stands before the value.

The conversions:

[@%d@] a signed integer in decimal
[@%u@] an unsigned integer in decimal
[@%x@] an integer in hexadecimal; a negative number is a minus sign and its
magnitude, never the bit pattern of its representation
[@%f@] a floating-point number with a fixed number of digits after the point
[@%s@] a string
[@%c@] a character
[@%b@] a Boolean, as @true@ or @false@
[@%n@] the line terminator of the platform; takes no argument
[@%%@] a percent sign; takes no argument

@%A@ and @%O@, the debug and display forms of an object, are part of the
grammar and need the object model; they are recognized and reported as not
implemented.
-}
module Progmasoft.Tala.TypeChecker.Format
    ( FormatPiece (..)
    , Conversion (..)
    , ConversionKind (..)
    , Flag (..)
    , Size (..)
    , FormatProblem (..)
    , parseFormat
    , conversionLetter
    , conversionFlagBits
    , conversionArgumentCount
    ) where

import Data.Char (isDigit)
import Data.List (nub)
import Progmasoft.Tala.RuntimeCall

-- | One part of a format, in the order it is written.
data FormatPiece
    = -- | Text that is written as it stands.
      LiteralPiece String
    | -- | A conversion of one argument.
      ConversionPiece Conversion
    | -- | @%n@.
      NewlinePiece
    deriving (Eq, Ord, Read, Show)

-- | What a conversion writes.
data ConversionKind
    = SignedDecimal
    | UnsignedDecimal
    | Hexadecimal
    | FixedPoint
    | Text
    | Character
    | Truth
    deriving (Eq, Ord, Read, Show)

-- | A flag written between @%@ and the width.
data Flag
    = -- | @-@: the value stands at the left of its field.
      LeftFlag
    | -- | @0@: a number is padded with zeros after its sign.
      ZeroFlag
    | -- | @+@: a number that is not negative is written with a plus sign.
      PlusFlag
    | -- | space: a number that is not negative is written with a leading space.
      SpaceFlag
    | -- | @#@: a hexadecimal number is written with the prefix @0x@.
      AlternateFlag
    | -- | @'@: integer digits are grouped in threes with apostrophes.
      GroupFlag
    deriving (Eq, Ord, Read, Show)

-- | A width or a precision.
data Size
    = -- | Not written.
      NoSize
    | -- | Written as a number in the format.
      FixedSize Integer
    | -- | Written as @*@: taken from an @int@ argument.
      ArgumentSize
    deriving (Eq, Ord, Read, Show)

-- | One conversion with everything written in it.
data Conversion = Conversion
    { conversionKind :: ConversionKind
    , conversionFlags :: [Flag]
    , conversionWidth :: Size
    , conversionPrecision :: Size
    , conversionOffset :: Int
    -- ^ The position of its @%@ in the format, counted from one.
    }
    deriving (Eq, Ord, Read, Show)

{- | What is wrong with a format: the diagnostic code, the position of the
conversion in the format counted from one, and what to say.
-}
data FormatProblem = FormatProblem
    { formatProblemCode :: String
    , formatProblemOffset :: Int
    , formatProblemMessage :: String
    }
    deriving (Eq, Ord, Read, Show)

-- | The letter a conversion is written with.
conversionLetter :: ConversionKind -> Char
conversionLetter kind = case kind of
    SignedDecimal -> 'd'
    UnsignedDecimal -> 'u'
    Hexadecimal -> 'x'
    FixedPoint -> 'f'
    Text -> 's'
    Character -> 'c'
    Truth -> 'b'

{- | The flags of a conversion as the runtime takes them: the sum of the
@TALA_TEXT_FLAG_*@ values of the flags written, and the hexadecimal flag for
@%x@, which the runtime takes as a flag of the integer conversions.
-}
conversionFlagBits :: Conversion -> Integer
conversionFlagBits conversion =
    sum (map bit (conversionFlags conversion)) + (if conversionKind conversion == Hexadecimal then flagHexadecimal else 0)
    where
        bit flag = case flag of
            LeftFlag -> flagLeft
            ZeroFlag -> flagZero
            PlusFlag -> flagPlus
            SpaceFlag -> flagSpace
            AlternateFlag -> flagAlternate
            GroupFlag -> flagGroup

{- | How many arguments a conversion takes: its value, and one more for each
of a width and a precision written as @*@.
-}
conversionArgumentCount :: Conversion -> Int
conversionArgumentCount conversion =
    1 + length (filter (== ArgumentSize) [conversionWidth conversion, conversionPrecision conversion])

{- | Read a format. The result is its pieces in order, with neighbouring
literal text joined, or the first thing wrong with it.
-}
parseFormat :: String -> Either FormatProblem [FormatPiece]
parseFormat = fmap joined . pieces 1
    where
        joined (LiteralPiece first : LiteralPiece second : rest) = joined (LiteralPiece (first ++ second) : rest)
        joined (piece : rest) = piece : joined rest
        joined [] = []

pieces :: Int -> String -> Either FormatProblem [FormatPiece]
pieces _ [] = Right []
pieces offset ('%' : rest) = do
    (piece, used) <- readConversion offset rest
    (piece :) <$> pieces (offset + 1 + used) (drop used rest)
pieces offset text =
    let (literal, rest) = break (== '%') text
     in (LiteralPiece literal :) <$> pieces (offset + length literal) rest

{- | Read what follows a @%@. The result is the piece and the number of
characters after the @%@ that belong to it.
-}
readConversion :: Int -> String -> Either FormatProblem (FormatPiece, Int)
readConversion offset text = do
    let (flagText, afterFlags) = span (`elem` "-0+ #'") text
    flags <- mapM flagOf flagText
    (width, afterWidth) <- sizeOf afterFlags
    (precision, afterPrecision) <- case afterWidth of
        '.' : afterPoint -> do
            (size, rest) <- sizeOf afterPoint
            case size of
                NoSize -> failure "TAT0075" "a precision needs a number or * after its point"
                _ -> Right (size, rest)
        _ -> Right (NoSize, afterWidth)
    let used = length text - length afterPrecision + 1
        plain = null flags && width == NoSize && precision == NoSize
    case afterPrecision of
        [] -> failure "TAT0075" "the format ends inside a conversion"
        letter : _ -> case letter of
            '%'
                | plain -> Right (LiteralPiece "%", used)
                | otherwise -> failure "TAT0076" "%% takes no flag, width or precision"
            'n'
                | plain -> Right (NewlinePiece, used)
                | otherwise -> failure "TAT0076" "%n takes no flag, width or precision"
            _ -> case lookup letter kinds of
                Just kind -> do
                    checked <- validated (Conversion kind flags width precision offset)
                    Right (ConversionPiece checked, used)
                Nothing
                    | letter `elem` "AO" ->
                        failure "TAT0079" ("the conversion %" ++ [letter] ++ " needs the object model and is not implemented yet")
                    | otherwise -> failure "TAT0075" ("%" ++ [letter] ++ " is not a conversion")
    where
        failure :: String -> String -> Either FormatProblem a
        failure code message = Left (FormatProblem code offset message)
        kinds =
            [ ('d', SignedDecimal)
            , ('u', UnsignedDecimal)
            , ('x', Hexadecimal)
            , ('f', FixedPoint)
            , ('s', Text)
            , ('c', Character)
            , ('b', Truth)
            ]
        flagOf character = case character of
            '-' -> Right LeftFlag
            '0' -> Right ZeroFlag
            '+' -> Right PlusFlag
            ' ' -> Right SpaceFlag
            '#' -> Right AlternateFlag
            _ -> Right GroupFlag
        -- A number, a star, or nothing. A number is written without a sign.
        sizeOf value = case value of
            '*' : rest -> Right (ArgumentSize, rest)
            _ ->
                let (digits, rest) = span isDigit value
                 in if null digits
                        then Right (NoSize, rest)
                        else
                            if length digits > 9
                                then failure "TAT0075" "a width or a precision written in a format has at most nine digits"
                                else Right (FixedSize (read digits), rest)
        validated value
            | flags' /= nub flags' = flagFailure "repeats a flag"
            | LeftFlag `elem` flags' && ZeroFlag `elem` flags' = flagFailure "combines - and 0, which exclude each other"
            | PlusFlag `elem` flags' && SpaceFlag `elem` flags' = flagFailure "combines + and a space, which exclude each other"
            | unwanted : _ <- filter (`notElem` allowedFlags kind) flags' =
                flagFailure ("takes no " ++ flagName unwanted ++ " flag")
            | conversionPrecision value /= NoSize && kind `notElem` [FixedPoint, Text] =
                flagFailure "takes no precision"
            | otherwise = Right value
            where
                flags' = conversionFlags value
                kind = conversionKind value
                flagFailure :: String -> Either FormatProblem a
                flagFailure text' = failure "TAT0076" ("the conversion %" ++ [conversionLetter kind] ++ " " ++ text')

-- | The flags each conversion has a meaning for.
allowedFlags :: ConversionKind -> [Flag]
allowedFlags kind = case kind of
    SignedDecimal -> [LeftFlag, ZeroFlag, PlusFlag, SpaceFlag, GroupFlag]
    UnsignedDecimal -> [LeftFlag, ZeroFlag, GroupFlag]
    Hexadecimal -> [LeftFlag, ZeroFlag, AlternateFlag]
    FixedPoint -> [LeftFlag, ZeroFlag, PlusFlag, SpaceFlag, GroupFlag]
    Text -> [LeftFlag]
    Character -> [LeftFlag]
    Truth -> [LeftFlag]

flagName :: Flag -> String
flagName flag = case flag of
    LeftFlag -> "-"
    ZeroFlag -> "0"
    PlusFlag -> "+"
    SpaceFlag -> "space"
    AlternateFlag -> "#"
    GroupFlag -> "'"
