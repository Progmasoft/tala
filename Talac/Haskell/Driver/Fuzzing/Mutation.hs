-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Bounded deterministic byte mutations. A campaign records its initial state
and saves exact failing bytes, so both mutation sequences and individual failures
are reproducible. Word64 wrapping is intentional for this generator.
-}
module Mutation (mutate, nextState, fingerprint, maximumInput) where

import Data.Bits (xor)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Char8
import Data.Word (Word64)
import Numeric (showHex)

maximumInput :: Int
maximumInput = 8192

nextState :: Word64 -> Word64
nextState state = state * 6364136223846793005 + 1442695040888963407

fingerprint :: BS.ByteString -> String
fingerprint bytes =
    showHex
        (BS.foldl' (\hash byte -> (hash `xor` fromIntegral byte) * 1099511628211) (14695981039346656037 :: Word64) bytes)
        ""

dictionary :: [BS.ByteString]
dictionary =
    map
        Char8.pack
        [ "namespace Fuzz;"
        , "class Program {"
        , "public static int Evaluate() {"
        , "return "
        , "int value = "
        , "while ("
        , "if ("
        , "match (value) {"
        , "match (value), (1) {"
        , "1 -> 2,"
        , "_ -> 0 }"
        , "(1), (_) -> {"
        , "int other if other > 1 ->"
        , "guard (value > 0) else { return 0; }"
        , "= if (value > 1) { 1 } else { 2 };"
        , "} else if ("
        , "->"
        , "for (int i = 0; i < 3; i++) {"
        , "break;"
        , "continue;"
        , "not "
        , "\\="
        , "&&"
        , "||"
        , "**"
        , "-- comment\n"
        , "0"
        , "1"
        , "255"
        , "65536"
        , ";"
        , "}"
        , "("
        , ")"
        , "\""
        , "\0"
        , "\r\n"
        ]

mutate :: Word64 -> BS.ByteString -> BS.ByteString -> BS.ByteString
mutate state input partner = BS.take maximumInput result
    where
        size = BS.length input
        position = fromIntegral (nextState state `mod` fromIntegral (size + 1))
        prefix = BS.take position input
        suffix = BS.drop position input
        byte = fromIntegral (nextState (nextState state) `mod` 256)
        token = dictionary !! fromIntegral (nextState state `mod` fromIntegral (length dictionary))
        result = case state `mod` 6 of
            0 -> prefix <> BS.singleton byte <> BS.drop 1 suffix
            1 -> prefix <> token <> suffix
            2 -> prefix <> BS.drop (1 + fromIntegral (state `mod` 16)) suffix
            3 -> prefix <> BS.take 128 partner <> suffix
            4 -> prefix <> BS.take 64 suffix <> suffix
            _ -> prefix <> BS.singleton byte <> suffix
