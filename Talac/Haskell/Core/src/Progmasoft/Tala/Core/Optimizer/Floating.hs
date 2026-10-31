-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Target-independent IEEE-754 folding for the Core optimizer.

The frontend intentionally carries decimal floating spellings all the way to
LLVM.  Constant folding must not take a shortcut through the host's 'Double':
that would silently make binary128 behave like binary64, and it would make
results depend on the machine running the compiler.  This module instead uses
exact integer ratios, rounds once to the Tala destination format, and
prints a short decimal spelling that reads back to the same target value.

Only operations whose result is specified by basic IEEE arithmetic are folded
here.  Transcendentals, power, and implementation-dependent NaN payload
operations remain in the backend.  That boundary is intentionally narrow:
getting fewer folds is preferable to changing a program's floating result.
-}
module Progmasoft.Tala.Core.Optimizer.Floating
    ( foldFloatingPrimitive
    , floatingTruthValue
    ) where

import Data.Bits (countLeadingZeros, shiftR)
import Data.Ratio (denominator, numerator, (%))
import Data.Word (Word64)
import Progmasoft.Tala.AST (Type, boolType)
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Scalar (coreTypeSpelling, integerFitsCoreType)

data BinaryFormat = BinaryFormat
    { formatPrecision :: Int
    , formatMinimumExponent :: Int
    , formatMaximumExponent :: Int
    }
    deriving (Eq, Ord, Read, Show)

-- The bias and exponent-field widths are derived from IEEE-754's four public
-- floating types rather than from the host's platform ABI.
formatFor :: Type -> Maybe BinaryFormat
formatFor valueType = case coreTypeSpelling valueType of
    "sfloat" -> Just (BinaryFormat 11 (-14) 15)
    "lfloat" -> Just (BinaryFormat 24 (-126) 127)
    "float" -> Just (BinaryFormat 53 (-1022) 1023)
    "double" -> Just (BinaryFormat 113 (-16382) 16383)
    _ -> Nothing

data FloatingValue
    = NotANumber
    | Infinity Bool
    | Finite Bool Rational
    deriving (Eq, Ord, Read, Show)

-- The optimizer may decline to fold a legal literal without changing the
-- language's accepted input. This cap keeps exact Rational construction
-- bounded for externally supplied Core while leaving ample headroom over the
-- 36 significant decimal digits needed to round-trip binary128.
maximumFoldedSignificantDigits :: Int
maximumFoldedSignificantDigits = 512

-- The Boolean records the sign bit even when the rational magnitude is zero.
-- Rational itself has no representation for negative zero, so discarding this
-- bit would make `-0.0 + -0.0` observably wrong.
parseFloatingValue :: BinaryFormat -> String -> Maybe FloatingValue
parseFloatingValue format spelling = do
    let (negative, unsigned) = stripLeadingSign spelling
    case unsigned of
        "nan" -> Just NotANumber
        "inf" -> Just (Infinity negative)
        _ -> do
            (coefficient, decimalScale, significantDigits) <- parseDecimal unsigned
            if coefficient == 0
                then Just (Finite negative 0)
                else
                    if decimalOrder significantDigits decimalScale > toInteger (formatMaximumExponent format)
                        then Just (Infinity negative)
                        else
                            if isDefinitelyBelowHalfMinSubnormal format significantDigits decimalScale
                                then Just (Finite negative 0)
                                else do
                                    exact <- decimalRational coefficient decimalScale
                                    Just (roundToFormat format negative exact)

stripLeadingSign :: String -> (Bool, String)
stripLeadingSign ('+' : remaining) = (False, remaining)
stripLeadingSign ('-' : remaining) = (True, remaining)
stripLeadingSign value = (False, value)

-- Return the integer coefficient, its power-of-ten scale, and the count of
-- significant digits. Core verification has already bounded the text payload
-- and checked the decimal grammar before the optimizer reaches this parser.
parseDecimal :: String -> Maybe (Integer, Integer, Int)
parseDecimal spelling = do
    let (mantissa, exponentText) = break (`elem` "eE") spelling
        exponentValue = case exponentText of
            [] -> Just 0
            _ : rest -> readSignedDecimal rest
        (whole, fractionWithPoint) = break (== '.') mantissa
        fraction = case fractionWithPoint of
            [] -> []
            _ : remaining -> remaining
        digits = whole ++ fraction
    decimalExponent <- exponentValue
    if null digits || any (not . isAsciiDigit) digits
        then Nothing
        else
            let leadingZeroesRemoved = dropWhile (== '0') digits
             in if null leadingZeroesRemoved
                    then Just (0, 0, 1)
                    else
                        let trailingZeroes = length (takeWhile (== '0') (reverse leadingZeroesRemoved))
                            significantSpelling = take (length leadingZeroesRemoved - trailingZeroes) leadingZeroesRemoved
                            significantDigits = length significantSpelling
                            scale = decimalExponent - toInteger (length fraction) + toInteger trailingZeroes
                         in if significantDigits > maximumFoldedSignificantDigits
                                then Nothing
                                else Just (read significantSpelling, scale, significantDigits)

readSignedDecimal :: String -> Maybe Integer
readSignedDecimal spelling = case spelling of
    [] -> Nothing
    '+' : digits -> readDigits False digits
    '-' : digits -> readDigits True digits
    digits -> readDigits False digits
    where
        readDigits negative digits
            | null digits || length digits > 19 || any (not . isAsciiDigit) digits = Nothing
            | otherwise =
                let value = read digits
                 in Just (if negative then negate value else value)

isAsciiDigit :: Char -> Bool
isAsciiDigit value = value >= '0' && value <= '9'

decimalOrder :: Int -> Integer -> Integer
decimalOrder significantDigits scale = toInteger significantDigits - 1 + scale

-- These conservative decimal bounds avoid constructing a huge power of ten
-- for hostile artifact literals. They are deliberately outside the rounding
-- boundary, so every value near zero is still handled by exact arithmetic.
isDefinitelyBelowHalfMinSubnormal :: BinaryFormat -> Int -> Integer -> Bool
isDefinitelyBelowHalfMinSubnormal format significantDigits scale =
    decimalOrder significantDigits scale < toInteger (minimumSubnormalExponent format `div` 3 - 2)

decimalRational :: Integer -> Integer -> Maybe Rational
decimalRational coefficient scale
    | scale > 10000 || scale < -10000 = Nothing
    | scale >= 0 = Just (coefficient * (10 ^ (fromInteger scale :: Int)) % 1)
    | otherwise = Just (coefficient % (10 ^ (fromInteger (negate scale) :: Int)))

minimumSubnormalExponent :: BinaryFormat -> Int
minimumSubnormalExponent format = formatMinimumExponent format - (formatPrecision format - 1)

roundToFormat :: BinaryFormat -> Bool -> Rational -> FloatingValue
roundToFormat format negative exact
    | exact == 0 = Finite negative 0
    | binaryExponent < formatMinimumExponent format =
        let quantum = minimumSubnormalExponent format
            subnormalSignificand = roundRatioToEven (scaleByPowerOfTwo exact (negate quantum))
         in if subnormalSignificand == 0
                then Finite negative 0
                else Finite negative (scaleByPowerOfTwo (subnormalSignificand % 1) quantum)
    | otherwise =
        let quantum = binaryExponent - (formatPrecision format - 1)
            roundedSignificand = roundRatioToEven (scaleByPowerOfTwo exact (negate quantum))
            (finalExponent, finalSignificand) =
                if roundedSignificand == 2 ^ formatPrecision format
                    then (binaryExponent + 1, roundedSignificand `quot` 2)
                    else (binaryExponent, roundedSignificand)
         in if finalExponent > formatMaximumExponent format
                then Infinity negative
                else Finite negative (scaleByPowerOfTwo (finalSignificand % 1) (finalExponent - (formatPrecision format - 1)))
    where
        binaryExponent = floorLog2 exact

-- IEEE-754 roundTiesToEven expressed entirely with nonnegative integers.
roundRatioToEven :: Rational -> Integer
roundRatioToEven value =
    let top = numerator value
        bottom = denominator value
        (quotient, remainder) = top `quotRem` bottom
        twiceRemainder = 2 * remainder
     in case compare twiceRemainder bottom of
            LT -> quotient
            GT -> quotient + 1
            EQ -> if even quotient then quotient else quotient + 1

scaleByPowerOfTwo :: Rational -> Int -> Rational
scaleByPowerOfTwo value binaryExponent
    | binaryExponent >= 0 = (numerator value * 2 ^ binaryExponent) % denominator value
    | otherwise = numerator value % (denominator value * 2 ^ negate binaryExponent)

floorLog2 :: Rational -> Int
floorLog2 value =
    let top = numerator value
        bottom = denominator value
        estimate = integerBitLength top - integerBitLength bottom
     in if compareToPowerOfTwo top bottom estimate == LT then estimate - 1 else estimate

compareToPowerOfTwo :: Integer -> Integer -> Int -> Ordering
compareToPowerOfTwo top bottom binaryExponent
    | binaryExponent >= 0 = compare top (bottom * 2 ^ binaryExponent)
    | otherwise = compare (top * 2 ^ negate binaryExponent) bottom

integerBitLength :: Integer -> Int
integerBitLength value
    | value <= 0 = 0
    | value <= toInteger (maxBound :: Word64) =
        64 - countLeadingZeros (fromInteger value :: Word64)
    | otherwise = 64 + integerBitLength (value `shiftR` 64)

-- Find the shortest significant decimal that round-trips to the already
-- rounded target value. The maximum digit formula is the standard conservative
-- bound for a binary format; trying each shorter length keeps common results
-- compact without asking a host floating formatter to choose a value.
renderFloatingValue :: BinaryFormat -> FloatingValue -> String
renderFloatingValue _ NotANumber = "nan"
renderFloatingValue _ (Infinity negative) = signed negative "inf"
renderFloatingValue _ (Finite negative value)
    | value == 0 = signed negative "0.0"
renderFloatingValue format target@(Finite negative value) =
    signed negative (shortest 1)
    where
        maximumDigits = (30103 * formatPrecision format + 99999) `div` 100000 + 1
        shortest digits
            | digits > maximumDigits = renderScientific maximumDigits value
            | otherwise =
                let spelling = renderScientific digits value
                 in case parseDecimal spelling of
                        Just (coefficient, scale, _) ->
                            case decimalRational coefficient scale of
                                Just roundTrip
                                    | roundToFormat format negative roundTrip == target -> spelling
                                _ -> shortest (digits + 1)
                        Nothing -> shortest (digits + 1)
signed :: Bool -> String -> String
signed True value = '-' : value
signed False value = value

renderScientific :: Int -> Rational -> String
renderScientific requestedDigits exact =
    let order = floorLog10 exact
        decimalShift = requestedDigits - 1 - order
        scaled =
            if decimalShift >= 0
                then roundRatioToEven ((numerator exact * 10 ^ decimalShift) % denominator exact)
                else roundRatioToEven (numerator exact % (denominator exact * 10 ^ negate decimalShift))
        limit = 10 ^ requestedDigits
        decimalSignificand = if scaled >= limit then scaled `quot` 10 else scaled
        adjustedOrder = if scaled >= limit then order + 1 else order
        padded = replicate (max 0 (requestedDigits - length (show decimalSignificand))) '0' ++ show decimalSignificand
        leading = take 1 padded
        trailing = drop 1 padded
        compactFraction = reverse (dropWhile (== '0') (reverse trailing))
        fraction = if null compactFraction then "0" else compactFraction
     in leading ++ "." ++ fraction ++ "e" ++ show adjustedOrder

floorLog10 :: Rational -> Int
floorLog10 value =
    let top = numerator value
        bottom = denominator value
        estimate = length (show top) - length (show bottom)
     in if compareToPowerOfTen top bottom estimate == LT then estimate - 1 else estimate

compareToPowerOfTen :: Integer -> Integer -> Int -> Ordering
compareToPowerOfTen top bottom decimalExponent
    | decimalExponent >= 0 = compare top (bottom * 10 ^ decimalExponent)
    | otherwise = compare (top * 10 ^ negate decimalExponent) bottom

foldFloatingPrimitive :: CorePrimitive -> [CoreExpression] -> Type -> Maybe CoreExpression
foldFloatingPrimitive primitive arguments resultType = case primitive of
    CoreAdd -> foldAddition
    CoreSubtract -> foldSubtraction
    CoreMultiply -> foldMultiplication
    CoreDivide -> foldDivision
    CoreRemainder -> foldRemainder
    CoreNegate -> foldNegation
    CoreFloorDivide -> foldRoundedDivision
    CoreLessThan -> foldComparison (== LT)
    CoreLessEqual -> foldComparison (/= GT)
    CoreGreaterThan -> foldComparison (== GT)
    CoreGreaterEqual -> foldComparison (/= LT)
    CoreEqual -> foldComparison (== EQ)
    CoreNotEqual -> foldNotEqual
    _ -> Nothing
    where
        foldAddition = do
            (format, [left, right]) <- floatingOperands arguments
            result <- addFloating format left right
            floatingResult format resultType result

        foldSubtraction = do
            (format, [left, right]) <- floatingOperands arguments
            result <- addFloating format left (negateValue right)
            floatingResult format resultType result

        foldDivision = do
            (format, [left, right]) <- floatingOperands arguments
            result <- divideFloating format left right
            floatingResult format resultType result

        foldMultiplication = do
            (format, [left, right]) <- floatingOperands arguments
            result <- multiplyFloating format left right
            floatingResult format resultType result

        foldRemainder = do
            (format, [left, right]) <- floatingOperands arguments
            result <- remainderFloating format left right
            floatingResult format resultType result

        foldNegation = do
            (format, [value]) <- floatingOperands arguments
            floatingResult format resultType (negateValue value)

        foldRoundedDivision = do
            (format, [left, right]) <- floatingOperands arguments
            roundedQuotient <- divideFloating format left right
            quotient <- finiteValueToRational roundedQuotient
            let rounded = roundRatioAwayFromZero quotient
            if integerFitsCoreType resultType rounded
                then Just (CoreLiteral (CoreInteger rounded) resultType)
                else Nothing

        foldComparison relation = do
            (_, [left, right]) <- floatingOperands arguments
            Just (CoreLiteral (CoreBoolean (maybe False relation (compareFloating left right))) boolType)

        foldNotEqual = do
            (_, [left, right]) <- floatingOperands arguments
            Just (CoreLiteral (CoreBoolean (maybe True (/= EQ) (compareFloating left right))) boolType)

floatingOperands :: [CoreExpression] -> Maybe (BinaryFormat, [FloatingValue])
floatingOperands arguments = case arguments of
    [] -> Nothing
    first : _ -> do
        let valueType = expressionType first
        format <- formatFor valueType
        if all ((== valueType) . expressionType) arguments
            then (format,) <$> traverse (decodeFloating format) arguments
            else Nothing

decodeFloating :: BinaryFormat -> CoreExpression -> Maybe FloatingValue
decodeFloating format expression = case expression of
    CoreLiteral (CoreFloating spelling) _ -> parseFloatingValue format spelling
    _ -> Nothing

floatingResult :: BinaryFormat -> Type -> FloatingValue -> Maybe CoreExpression
floatingResult format resultType value =
    Just (CoreLiteral (CoreFloating (renderFloatingValue format value)) resultType)

addFloating :: BinaryFormat -> FloatingValue -> FloatingValue -> Maybe FloatingValue
addFloating format left right = case (left, right) of
    (NotANumber, _) -> Just NotANumber
    (_, NotANumber) -> Just NotANumber
    (Infinity leftSign, Infinity rightSign)
        | leftSign == rightSign -> Just (Infinity leftSign)
        | otherwise -> Just NotANumber
    (Infinity negative, _) -> Just (Infinity negative)
    (_, Infinity negative) -> Just (Infinity negative)
    (Finite leftSign leftMagnitude, Finite rightSign rightMagnitude) ->
        let exact = signedMagnitude leftSign leftMagnitude + signedMagnitude rightSign rightMagnitude
            zeroSign = exact == 0 && leftMagnitude == 0 && rightMagnitude == 0 && leftSign && rightSign
         in Just (roundToFormat format (if exact == 0 then zeroSign else exact < 0) (abs exact))

multiplyFloating :: BinaryFormat -> FloatingValue -> FloatingValue -> Maybe FloatingValue
multiplyFloating format left right = case (left, right) of
    (NotANumber, _) -> Just NotANumber
    (_, NotANumber) -> Just NotANumber
    (Infinity _, Finite _ 0) -> Just NotANumber
    (Finite _ 0, Infinity _) -> Just NotANumber
    (Infinity leftSign, Infinity rightSign) -> Just (Infinity (leftSign /= rightSign))
    (Infinity leftSign, Finite rightSign _) -> Just (Infinity (leftSign /= rightSign))
    (Finite leftSign _, Infinity rightSign) -> Just (Infinity (leftSign /= rightSign))
    (Finite leftSign leftMagnitude, Finite rightSign rightMagnitude) ->
        Just (roundToFormat format (leftSign /= rightSign) (leftMagnitude * rightMagnitude))

divideFloating :: BinaryFormat -> FloatingValue -> FloatingValue -> Maybe FloatingValue
divideFloating format left right = case (left, right) of
    (NotANumber, _) -> Just NotANumber
    (_, NotANumber) -> Just NotANumber
    (Infinity _, Infinity _) -> Just NotANumber
    (Finite _ 0, Finite _ 0) -> Just NotANumber
    (Infinity leftSign, Finite rightSign _) -> Just (Infinity (leftSign /= rightSign))
    (Finite leftSign _, Infinity rightSign) -> Just (Finite (leftSign /= rightSign) 0)
    (Finite leftSign _, Finite rightSign 0) -> Just (Infinity (leftSign /= rightSign))
    (Finite leftSign 0, Finite rightSign _) -> Just (Finite (leftSign /= rightSign) 0)
    (Finite leftSign leftMagnitude, Finite rightSign rightMagnitude) ->
        Just (roundToFormat format (leftSign /= rightSign) (leftMagnitude / rightMagnitude))

remainderFloating :: BinaryFormat -> FloatingValue -> FloatingValue -> Maybe FloatingValue
remainderFloating format left right = case (left, right) of
    (NotANumber, _) -> Just NotANumber
    (_, NotANumber) -> Just NotANumber
    (Infinity _, _) -> Just NotANumber
    (_, Infinity _) -> preserveLeft
    (_, Finite _ 0) -> Just NotANumber
    (Finite negative 0, _) -> Just (Finite negative 0)
    (Finite negative leftMagnitude, Finite _ rightMagnitude) ->
        let quotient = leftMagnitude / rightMagnitude
            truncated = numerator quotient `quot` denominator quotient
            remainder = leftMagnitude - toRational truncated * rightMagnitude
         in Just (roundToFormat format negative remainder)
    where
        preserveLeft = case left of
            Finite negative magnitude -> Just (roundToFormat format negative magnitude)
            _ -> Just NotANumber

finiteValueToRational :: FloatingValue -> Maybe Rational
finiteValueToRational (Finite negative magnitude) = Just (signedMagnitude negative magnitude)
finiteValueToRational _ = Nothing

roundRatioAwayFromZero :: Rational -> Integer
roundRatioAwayFromZero value =
    let negative = value < 0
        magnitude = abs value
        (whole, remainder) = numerator magnitude `quotRem` denominator magnitude
        rounded = if 2 * remainder >= denominator magnitude then whole + 1 else whole
     in if negative then negate rounded else rounded

compareFloating :: FloatingValue -> FloatingValue -> Maybe Ordering
compareFloating NotANumber _ = Nothing
compareFloating _ NotANumber = Nothing
compareFloating (Infinity left) (Infinity right) = Just (compare right left)
compareFloating (Infinity True) (Finite _ _) = Just LT
compareFloating (Infinity False) (Finite _ _) = Just GT
compareFloating (Finite _ _) (Infinity True) = Just GT
compareFloating (Finite _ _) (Infinity False) = Just LT
compareFloating (Finite leftSign left) (Finite rightSign right) =
    Just (compare (signedMagnitude leftSign left) (signedMagnitude rightSign right))

negateValue :: FloatingValue -> FloatingValue
negateValue NotANumber = NotANumber
negateValue (Infinity negative) = Infinity (not negative)
negateValue (Finite negative value) = Finite (not negative) value

signedMagnitude :: Bool -> Rational -> Rational
signedMagnitude True value = negate value
signedMagnitude False value = value

floatingTruthValue :: CoreExpression -> Maybe Bool
floatingTruthValue expression = do
    format <- formatFor (expressionType expression)
    value <- decodeFloating format expression
    pure $ case value of
        NotANumber -> True
        Infinity _ -> True
        Finite _ magnitude -> magnitude /= 0
