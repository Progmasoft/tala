-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
{-# LANGUAGE BangPatterns #-}

module Main (main) where

import Data.Int (Int64)
import System.Environment (getArgs)
import Text.Read (readMaybe)

defaultLimit :: Int64
defaultLimit = 50000000

maximumSafeLimit :: Int64
maximumSafeLimit = 4294967295

sumBaseline :: Int64 -> Int64
sumBaseline limit = go 1 0
    where
        go !value !total
            | value > limit = total
            | otherwise = go (value + 1) (total + value)

-- Four strict sums expose instruction-level independence before final reduction.
sumUnrolled :: Int64 -> Int64
sumUnrolled limit = go 1 0 0 0 0
    where
        go !value !first !second !third !fourth
            | value + 3 <= limit =
                go
                    (value + 4)
                    (first + value)
                    (second + value + 1)
                    (third + value + 2)
                    (fourth + value + 3)
            | otherwise = finish value (first + second + third + fourth)

        finish !value !total
            | value > limit = total
            | otherwise = finish (value + 1) (total + value)

-- Divide the even factor first so the product stays inside Int64's range.
sumFormula :: Int64 -> Int64
sumFormula limit
    | even limit = (limit `div` 2) * (limit + 1)
    | otherwise = limit * ((limit + 1) `div` 2)

main :: IO ()
main = do
    arguments <- getArgs
    let algorithm = case arguments of
            mode : _ -> mode
            [] -> "baseline"
        limit = case arguments of
            _ : text : _ -> maybe 0 id (readMaybe text)
            _ -> defaultLimit
    if (algorithm /= "baseline" && algorithm /= "unrolled" && algorithm /= "formula")
        || limit <= 0
        || limit > maximumSafeLimit
        || length arguments > 2
        then ioError (userError "usage: loop-sum [baseline|unrolled|formula] [count: 1..4294967295]")
        else do
            let checksum = case algorithm of
                    "baseline" -> sumBaseline limit
                    "unrolled" -> sumUnrolled limit
                    _ -> sumFormula limit
            putStrLn ("algorithm=" ++ algorithm ++ " count=" ++ show limit ++ " checksum=" ++ show checksum)
