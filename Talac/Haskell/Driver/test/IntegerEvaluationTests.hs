-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module IntegerEvaluationTests (integerEvaluationTests) where

import Data.Bits (shiftL, shiftR)
import Progmasoft.Tala.IntegerEvaluation

integerEvaluationTests :: [(String, Bool)]
integerEvaluationTests =
    [ ("bounded integer arithmetic agrees with direct small-value evaluation", smallArithmeticMatrix)
    , ("bounded exponentiation agrees with direct nonnegative powers", smallPowerMatrix)
    , ("bounded signed shifts agree with direction-reversing semantics", smallShiftMatrix)
    , ("multiplication preflight preserves exact results around limb boundaries", multiplicationBoundaryMatrix)
    , ("multiplication distinguishes both exact magnitude edges", multiplicationExactEdges)
    , ("multiplication checks inconclusive bit-length bounds exactly", multiplicationConservativeBoundary)
    , ("power checks non-power-of-two magnitudes at the exact ceiling", nonPowerOfTwoPowerBoundaries)
    , ("power boundary cases reject before exponent-sized work", powerBoundaryMatrix)
    , ("left and right shifts honor magnitude and sign boundaries", shiftBoundaryMatrix)
    , ("left shift accepts the last value below the ceiling and rejects the next", leftShiftExactEdges)
    , ("arbitrarily wide shift counts stay bounded by their result", unboundedShiftCountsRemainSafe)
    , ("very wide exponents use identities or fail at the first unsafe square", veryWideExponentMatrix)
    , ("very wide shift distances do not induce distance-sized work", veryWideShiftMatrix)
    , ("bounded integer predicate agrees with the half-open interval at varied bit lengths", integerMagnitudeMatrix)
    , ("an out-of-limit base is rejected even for zero exponent", invalidPowerBase)
    , ("zero multiplication remains valid at both signed magnitude edges", zeroProductBoundary)
    ]

-- The dense but small matrix acts as an independent oracle: these operations
-- are cheap enough to compute directly, without sharing the production
-- exponentiation or preflight algorithms under test.
-- Boundary inputs are fixed rather than pseudo-random, so any failure is
-- reproducible on every supported development host.
smallArithmeticMatrix :: Bool
smallArithmeticMatrix =
    and
        [ add left right == reference (left + right)
            && subtractInteger left right == reference (left - right)
            && multiplyCompileTimeIntegers left right == reference (left * right)
        | left <- [-64 .. 64]
        , right <- [-64 .. 64]
        ]

smallPowerMatrix :: Bool
smallPowerMatrix =
    and
        [ evaluateCompileTimePower base exponentValue == reference (base ^ exponentValue)
        | base <- [-8 .. 8]
        , exponentValue <- [0 .. 32]
        ]
        && all
            (\exponentValue -> evaluateCompileTimePower 2 (negate exponentValue) == Left CompileTimeNegativeExponent)
            [1 .. 32]

smallShiftMatrix :: Bool
smallShiftMatrix =
    and
        [ evaluateCompileTimeShiftLeft value amount == reference (referenceShiftLeft value amount)
            && evaluateCompileTimeShiftRight value amount == reference (referenceShiftRight value amount)
        | value <- [-32 .. 32]
        , amount <- [-16 .. 16]
        ]

referenceShiftLeft :: Integer -> Integer -> Integer
referenceShiftLeft value amount
    | amount < 0 = shiftR value (fromInteger (negate amount))
    | otherwise = shiftL value (fromInteger amount)

referenceShiftRight :: Integer -> Integer -> Integer
referenceShiftRight value amount
    | amount < 0 = shiftL value (fromInteger (negate amount))
    | otherwise = shiftR value (fromInteger amount)

multiplicationBoundaryMatrix :: Bool
multiplicationBoundaryMatrix = all checkCase cases
    where
        bitPositions = [1, 2, 7, 8, 9, 31, 32, 33, 63, 64, 65, 127, 128, 129, 1023, 32767, 32768, 32769, 65534, 65535, 65536]
        powers = [1 `shiftL` (position - 1) | position <- bitPositions]
        values = concatMap (\power -> [power, negate power]) powers
        factors = [-3 .. 3]
        cases = [(value, factor) | value <- values, factor <- factors]
        checkCase (value, factor) =
            multiplyCompileTimeIntegers value factor == reference (value * factor)

multiplicationExactEdges :: Bool
multiplicationExactEdges =
    and
        [ multiplyCompileTimeIntegers (compileTimeLimit `quot` 2 - 1) 2 == Right (compileTimeLimit - 2)
        , multiplyCompileTimeIntegers (compileTimeLimit `quot` 2) 2 == Left CompileTimeIntegerLimitExceeded
        , multiplyCompileTimeIntegers (negate (compileTimeLimit `quot` 2) + 1) 2 == Right (negate compileTimeLimit + 2)
        , multiplyCompileTimeIntegers (negate (compileTimeLimit `quot` 2)) 2 == Left CompileTimeIntegerLimitExceeded
        , multiplyCompileTimeIntegers (compileTimeLimit - 1) (-1) == Right (1 - compileTimeLimit)
        , multiplyCompileTimeIntegers (1 - compileTimeLimit) (-1) == Right (compileTimeLimit - 1)
        ]

multiplicationConservativeBoundary :: Bool
multiplicationConservativeBoundary =
    let power = 1 `shiftL` 32768
        belowPower = power - 1
        validProduct = power * belowPower
        invalidProduct = power * (power + 1)
     in multiplyCompileTimeIntegers power belowPower == Right validProduct
            && multiplyCompileTimeIntegers (negate power) belowPower == Right (negate validProduct)
            && multiplyCompileTimeIntegers power (power + 1) == Left CompileTimeIntegerLimitExceeded
            && validProduct < compileTimeLimit
            && invalidProduct >= compileTimeLimit

nonPowerOfTwoPowerBoundaries :: Bool
nonPowerOfTwoPowerBoundaries =
    evaluateCompileTimePower 3 40000 == reference (3 ^ (40000 :: Int))
        && evaluateCompileTimePower 3 42000 == Left CompileTimeIntegerLimitExceeded
        && evaluateCompileTimePower (-3) 40001 == reference (negate (3 ^ (40001 :: Int)))
        && evaluateCompileTimePower (-3) 42001 == Left CompileTimeIntegerLimitExceeded

powerBoundaryMatrix :: Bool
powerBoundaryMatrix =
    and
        [ evaluateCompileTimePower 2 exponentValue == expectedPower exponentValue
            && evaluateCompileTimePower (-2) exponentValue == expectedNegativePower exponentValue
        | exponentValue <- [0, 1, 2, 7, 8, 31, 32, 63, 64, 127, 128, 1023, 32767, 32768, 32769, 65534, 65535, 65536]
        ]

expectedPower :: Integer -> Either CompileTimeIntegerError Integer
expectedPower exponentValue
    | exponentValue < 65536 = reference (2 ^ exponentValue)
    | otherwise = Left CompileTimeIntegerLimitExceeded

expectedNegativePower :: Integer -> Either CompileTimeIntegerError Integer
expectedNegativePower exponentValue
    | exponentValue < 65536 = reference ((-2) ^ exponentValue)
    | otherwise = Left CompileTimeIntegerLimitExceeded

shiftBoundaryMatrix :: Bool
shiftBoundaryMatrix = all checkCase cases
    where
        limit = 1 `shiftL` 65536
        cases =
            [ (1, 65534, Just (1 `shiftL` 65534))
            , (1, 65535, Just (limit `quot` 2))
            , (1, 65536, Nothing)
            , (-1, 65535, Just (negate (limit `quot` 2)))
            , (-1, 65536, Nothing)
            , (limit `quot` 2, 1, Nothing)
            , (negate (limit `quot` 2), 0, Just (negate (limit `quot` 2)))
            , (limit - 1, -65535, Just 1)
            , (negate (limit - 1), -65535, Just (-2))
            ]
        checkCase (value, amount, expected) =
            evaluateCompileTimeShiftLeft value amount == maybe (Left CompileTimeIntegerLimitExceeded) Right expected
                && evaluateCompileTimeShiftRight value amount == expectedRight value amount
        expectedRight value amount
            | amount < 0 = expectedShiftLeft value (negate amount)
            | amount >= 65536 = Right (if value < 0 then -1 else 0)
            | otherwise = reference (shiftR value (fromInteger amount))
        expectedShiftLeft value amount
            | amount >= 65536 = if value == 0 then Right 0 else Left CompileTimeIntegerLimitExceeded
            | otherwise = reference (shiftL value (fromInteger amount))

leftShiftExactEdges :: Bool
leftShiftExactEdges =
    evaluateCompileTimeShiftLeft 3 65534 == Right (3 `shiftL` 65534)
        && evaluateCompileTimeShiftLeft 3 65535 == Left CompileTimeIntegerLimitExceeded
        && evaluateCompileTimeShiftLeft (-3) 65534 == Right (negate (3 `shiftL` 65534))
        && evaluateCompileTimeShiftLeft (-3) 65535 == Left CompileTimeIntegerLimitExceeded
        && evaluateCompileTimeShiftRight (compileTimeLimit - 1) 65535 == Right 1
        && evaluateCompileTimeShiftRight (negate (compileTimeLimit - 1)) 65535 == Right (-2)

integerMagnitudeMatrix :: Bool
integerMagnitudeMatrix =
    -- Sign-symmetric neighbors ensure neither exclusive endpoint drifts.
    -- Values immediately below each edge must remain accepted.
    and
        [ checkCompileTimeInteger value == reference value
        | bitPosition <- [0, 1, 2, 7, 8, 9, 31, 32, 33, 63, 64, 65, 127, 128, 129, 1024, 32767, 32768, 32769, 65534, 65535, 65536]
        , signValue <- [-1, 1] :: [Integer]
        , delta <- [-1, 0, 1] :: [Integer]
        , let value = signValue * (1 `shiftL` bitPosition + delta)
        ]
        && checkCompileTimeInteger (compileTimeLimit - 1) == Right (compileTimeLimit - 1)
        && checkCompileTimeInteger (1 - compileTimeLimit) == Right (1 - compileTimeLimit)
        && checkCompileTimeInteger compileTimeLimit == Left CompileTimeIntegerLimitExceeded
        && checkCompileTimeInteger (negate compileTimeLimit) == Left CompileTimeIntegerLimitExceeded

unboundedShiftCountsRemainSafe :: Bool
unboundedShiftCountsRemainSafe =
    evaluateCompileTimeShiftRight 0 compileTimeLimit == Right 0
        && evaluateCompileTimeShiftRight (-5) compileTimeLimit == Right (-1)
        && evaluateCompileTimeShiftRight 0 (negate compileTimeLimit) == Right 0
        && evaluateCompileTimeShiftLeft 1 compileTimeLimit == Left CompileTimeIntegerLimitExceeded
        && evaluateCompileTimeShiftLeft 1 (negate compileTimeLimit) == Right 0
        && evaluateCompileTimeShiftRight 1 (negate compileTimeLimit) == Left CompileTimeIntegerLimitExceeded
        && evaluateCompileTimeShiftRight 5 (compileTimeLimit - 1) == Right 0
        && evaluateCompileTimeShiftRight (-5) (compileTimeLimit - 1) == Right (-1)
        && evaluateCompileTimeShiftLeft 0 (compileTimeLimit - 1) == Right 0

veryWideExponentMatrix :: Bool
veryWideExponentMatrix =
    let exponentValue = 1 `shiftL` 65535
     in evaluateCompileTimePower 0 exponentValue == Right 0
            && evaluateCompileTimePower 1 exponentValue == Right 1
            && evaluateCompileTimePower (-1) exponentValue == Right 1
            && evaluateCompileTimePower (-1) (exponentValue + 1) == Right (-1)
            && evaluateCompileTimePower 2 exponentValue == Left CompileTimeIntegerLimitExceeded
            && evaluateCompileTimePower 2 (negate exponentValue) == Left CompileTimeNegativeExponent

veryWideShiftMatrix :: Bool
veryWideShiftMatrix =
    let distance = 1 `shiftL` 65535
     in evaluateCompileTimeShiftLeft 0 distance == Right 0
            && evaluateCompileTimeShiftLeft 1 distance == Left CompileTimeIntegerLimitExceeded
            && evaluateCompileTimeShiftLeft 1 (negate distance) == Right 0
            && evaluateCompileTimeShiftRight 3 distance == Right 0
            && evaluateCompileTimeShiftRight (-3) distance == Right (-1)
            && evaluateCompileTimeShiftRight 1 (negate distance) == Left CompileTimeIntegerLimitExceeded

invalidPowerBase :: Bool
invalidPowerBase =
    evaluateCompileTimePower compileTimeLimit 0 == Left CompileTimeIntegerLimitExceeded
        && evaluateCompileTimePower (negate compileTimeLimit) 1 == Left CompileTimeIntegerLimitExceeded
        && evaluateCompileTimePower 0 (compileTimeLimit - 1) == Right 0
        && evaluateCompileTimePower 1 (compileTimeLimit - 1) == Right 1
        && evaluateCompileTimePower (-1) (compileTimeLimit - 1) == Right (-1)

zeroProductBoundary :: Bool
zeroProductBoundary =
    multiplyCompileTimeIntegers 0 (compileTimeLimit - 1) == Right 0
        && multiplyCompileTimeIntegers (negate (compileTimeLimit - 1)) 0 == Right 0
        && multiplyCompileTimeIntegers 0 compileTimeLimit == Left CompileTimeIntegerLimitExceeded
        && multiplyCompileTimeIntegers compileTimeLimit 0 == Left CompileTimeIntegerLimitExceeded

reference :: Integer -> Either CompileTimeIntegerError Integer
reference value
    | value <= negate compileTimeLimit || value >= compileTimeLimit = Left CompileTimeIntegerLimitExceeded
    | otherwise = Right value

compileTimeLimit :: Integer
compileTimeLimit = 1 `shiftL` 65536

add :: Integer -> Integer -> Either CompileTimeIntegerError Integer
add left right = reference (left + right)

subtractInteger :: Integer -> Integer -> Either CompileTimeIntegerError Integer
subtractInteger left right = reference (left - right)
