-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Bounded, exact integer operations used while evaluating compile-time
expressions. These limits protect compiler availability; they do not narrow the
runtime integer types or the accepted integer-literal grammar.

Every public operation in this module either returns an exact value strictly
inside the magnitude bound or reports the same resource-limit error. Callers
translate that error into a diagnostic appropriate to their source context.
The helpers deliberately accept `Integer` operands so no conversion to a host
word can happen before validation.
-}
module Progmasoft.Tala.IntegerEvaluation
    ( CompileTimeIntegerError (..)
    , checkCompileTimeInteger
    , multiplyCompileTimeIntegers
    , evaluateCompileTimePower
    , evaluateCompileTimeShiftLeft
    , evaluateCompileTimeShiftRight
    ) where

import Data.Bits (countLeadingZeros, shiftL, shiftR)
import Data.Word (Word64)

-- | Failures returned by bounded compile-time integer operations.
data CompileTimeIntegerError
    = -- | The exact result exceeds the 65,536-bit bound.
      CompileTimeIntegerLimitExceeded
    | -- | Integer exponentiation was given a negative exponent.
      CompileTimeNegativeExponent
    deriving (Eq, Ord, Read, Show)

-- This is intentionally much wider than any built-in scalar (128 bits). A
-- fixed ceiling also bounds intermediate products before they can exhaust the
-- host while processing untrusted source or a project artifact. The lower edge
-- is exclusive, matching the positive bound and avoiding an asymmetric domain.
maximumCompileTimeIntegerBits :: Int
maximumCompileTimeIntegerBits = 65536

maximumCompileTimeMagnitude :: Integer
maximumCompileTimeMagnitude = 1 `shiftL` maximumCompileTimeIntegerBits

-- | Accept an integer strictly inside the module's symmetric magnitude bound.
checkCompileTimeInteger :: Integer -> Either CompileTimeIntegerError Integer
checkCompileTimeInteger value
    | value <= negate maximumCompileTimeMagnitude || value >= maximumCompileTimeMagnitude =
        Left CompileTimeIntegerLimitExceeded
    | otherwise = Right value

{- | Reject products that cannot fit before constructing a potentially twice-
as-wide intermediate. The one-bit lower bound is exact for powers of two;
borderline products are still checked after multiplication. Taking absolute
values makes the same proof valid for all four sign combinations. If the lower
bound does not prove overflow, the exact product is constructed once and then
checked against the half-open limit; this keeps the fast rejection conservative.
-}

-- | Multiply exact integers after checking operand and result resource bounds.
multiplyCompileTimeIntegers :: Integer -> Integer -> Either CompileTimeIntegerError Integer
multiplyCompileTimeIntegers left right = do
    boundedLeft <- checkCompileTimeInteger left
    boundedRight <- checkCompileTimeInteger right
    if boundedLeft == 0 || boundedRight == 0
        then Right 0
        else
            if integerBitLength (abs boundedLeft) + integerBitLength (abs boundedRight) - 1 > maximumCompileTimeIntegerBits
                then Left CompileTimeIntegerLimitExceeded
                else checkCompileTimeInteger (boundedLeft * boundedRight)

-- | Compute an exact non-negative integer power by bounded repeated squaring.
evaluateCompileTimePower :: Integer -> Integer -> Either CompileTimeIntegerError Integer
evaluateCompileTimePower base exponentValue
    | exponentValue < 0 = Left CompileTimeNegativeExponent
    | otherwise = do
        boundedBase <- checkCompileTimeInteger base
        case boundedBase of
            0 -> Right (if exponentValue == 0 then 1 else 0)
            1 -> Right 1
            -1 -> Right (if even exponentValue then 1 else -1)
            _ -> powerLoop 1 boundedBase exponentValue
    where
        -- Repeated squaring makes the number of iterations logarithmic in the
        -- exponent. Multiplication itself performs the resource preflight, so
        -- an enormous exponent cannot force construction of its final power.
        powerLoop accumulated factor remaining
            | remaining == 0 = checkCompileTimeInteger accumulated
            | otherwise = do
                nextAccumulated <-
                    if odd remaining
                        then multiplyCompileTimeIntegers accumulated factor
                        else Right accumulated
                let nextRemaining = remaining `quot` 2
                if nextRemaining == 0
                    then checkCompileTimeInteger nextAccumulated
                    else do
                        squaredFactor <- multiplyCompileTimeIntegers factor factor
                        powerLoop nextAccumulated squaredFactor nextRemaining

-- | Shift an exact integer left, interpreting a negative count as right shift.
evaluateCompileTimeShiftLeft :: Integer -> Integer -> Either CompileTimeIntegerError Integer
evaluateCompileTimeShiftLeft value amount = do
    boundedValue <- checkCompileTimeInteger value
    if amount < 0
        then evaluateCompileTimeShiftRight boundedValue (negate amount)
        else
            if boundedValue == 0
                then Right 0
                else do
                    -- Check the resulting bit width before asking the bignum
                    -- backend to allocate the shifted representation.
                    if toInteger (integerBitLength (abs boundedValue)) + amount > toInteger maximumCompileTimeIntegerBits
                        then Left CompileTimeIntegerLimitExceeded
                        else pure ()
                    boundedAmount <- checkedShiftAmount amount
                    checkCompileTimeInteger (shiftL boundedValue boundedAmount)

-- | Arithmetic-shift an exact integer right, interpreting a negative count as left shift.
evaluateCompileTimeShiftRight :: Integer -> Integer -> Either CompileTimeIntegerError Integer
evaluateCompileTimeShiftRight value amount = do
    boundedValue <- checkCompileTimeInteger value
    if amount < 0
        then evaluateCompileTimeShiftLeft boundedValue (negate amount)
        else
            if amount >= toInteger maximumCompileTimeIntegerBits
                -- Past the largest possible magnitude, arithmetic right shift
                -- contains only the sign fill and needs no large temporary.
                then Right (if boundedValue < 0 then -1 else 0)
                else do
                    boundedAmount <- checkedShiftAmount amount
                    checkCompileTimeInteger (shiftR boundedValue boundedAmount)

checkedShiftAmount :: Integer -> Either CompileTimeIntegerError Int
checkedShiftAmount amount
    | amount < 0 || amount > toInteger maximumCompileTimeIntegerBits = Left CompileTimeIntegerLimitExceeded
    | otherwise = Right (fromInteger amount)

-- Callers validate magnitudes before asking for their width, so this recursion
-- visits at most 1,024 fixed-size limbs at the 65,536-bit ceiling. Using
-- Word64 as the limb definition keeps the result independent of host Int width
-- and avoids narrowing the complete arbitrary-precision value in one cast.
integerBitLength :: Integer -> Int
integerBitLength value
    | value <= 0 = 0
    | value <= toInteger (maxBound :: Word64) = 64 - countLeadingZeros (fromInteger value :: Word64)
    | otherwise = 64 + integerBitLength (value `shiftR` 64)
