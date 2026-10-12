-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | A reference for the text functions of the runtime, used only by tests.

The runtime library that programs call is written in C++ and works on
machine integers, a buffer of scalars and a bounded natural number. This
module states what each of its functions returns in the most direct way the
language of the tests allows: unbounded integers, exact rationals and lists.
It shares nothing with the library, so a test that runs a program in the
reference evaluator and through the native pipeline compares two
independent answers.

A floating-point value is an exact rational here: the value of the binary
number, not of the decimal literal it was written as. @%f@ rounds that exact
value to the digits asked for, a tie to the even digit.
-}
module RuntimeText
    ( Conversion (..)
    , plain
    , textOfSigned
    , textOfBool
    , formatInteger
    , formatFloating
    , formatText
    , lineTerminator
    ) where

import Data.Bits ((.&.))
import Numeric (showHex)
import Progmasoft.Tala.RuntimeCall

-- | The flags, the width and the precision of one conversion, as the runtime takes them.
data Conversion = Conversion
    { conversionFlags :: Integer
    , conversionWidth :: Integer
    , conversionPrecision :: Integer
    }
    deriving (Eq, Show)

-- | A conversion with nothing written in it.
plain :: Conversion
plain = Conversion 0 absent absent

has :: Conversion -> Integer -> Bool
has conversion flag = conversionFlags conversion .&. flag /= 0

{- | The line terminator the reference writes. The native runtime writes the
terminator of its platform; a test that compares the two reads a carriage
return and line feed as this.
-}
lineTerminator :: String
lineTerminator = "\n"

-- | An integer in decimal, with a minus sign when negative.
textOfSigned :: Integer -> String
textOfSigned = show

textOfBool :: Bool -> String
textOfBool flag = if flag then "true" else "false"

{- | The field of a conversion: what stands before the body, the body, and the
padding that brings the two to the width. Zeros stand between the two.
-}
field :: Conversion -> Bool -> String -> String -> String
field conversion zerosAllowed prefix body
    | has conversion flagLeft = prefix ++ body ++ replicate padding ' '
    | zerosAllowed && has conversion flagZero = prefix ++ replicate padding '0' ++ body
    | otherwise = replicate padding ' ' ++ prefix ++ body
    where
        padding = max 0 (fromInteger (conversionWidth conversion) - length prefix - length body)

sign :: Conversion -> Bool -> String
sign conversion negative
    | negative = "-"
    | has conversion flagPlus = "+"
    | has conversion flagSpace = " "
    | otherwise = ""

-- | Apostrophes between groups of three digits, counted from the right.
grouped :: String -> String
grouped digits = reverse (go (reverse digits))
    where
        go (a : b : c : rest@(_ : _)) = a : b : c : '\'' : go rest
        go remaining = remaining

{- | @%d@, @%u@ and @%x@. A negative number is its sign and its magnitude in
either base.
-}
formatInteger :: Conversion -> Integer -> String
formatInteger conversion value = field conversion True prefix body
    where
        hexadecimal = has conversion flagHexadecimal
        magnitude = abs value
        digits = if hexadecimal then showHex magnitude "" else show magnitude
        body = if not hexadecimal && has conversion flagGroup then grouped digits else digits
        prefix = sign conversion (value < 0) ++ (if hexadecimal && has conversion flagAlternate then "0x" else "")

{- | @%f@ of an exact value. The flag says whether the value is negative zero,
which a rational cannot say for itself.
-}
formatFloating :: Conversion -> Bool -> Rational -> String
formatFloating conversion negativeZero value = field conversion True (sign conversion negative) body
    where
        negative = value < 0 || negativeZero
        precision = if conversionPrecision conversion < 0 then 6 else conversionPrecision conversion
        -- 'round' on a rational rounds a tie to the even integer.
        scaled = round (abs value * 10 ^ precision) :: Integer
        digits = show scaled
        padded = replicate (fromInteger precision + 1 - length digits) '0' ++ digits
        (whole, fraction) = splitAt (length padded - fromInteger precision) padded
        integer = if has conversion flagGroup then grouped whole else whole
        body = if precision > 0 then integer ++ "." ++ fraction else integer

-- | @%s@ and @%c@: at most the precision's number of characters, when there is one.
formatText :: Conversion -> String -> String
formatText conversion value = field conversion False "" kept
    where
        kept = if conversionPrecision conversion >= 0 then take (fromInteger (conversionPrecision conversion)) value else value
