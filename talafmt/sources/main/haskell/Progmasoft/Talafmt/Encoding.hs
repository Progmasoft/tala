-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Progmasoft.Talafmt.Encoding
    ( SourceEncoding (..)
    , EncodingOptions (..)
    , defaultEncodingOptions
    , decodeSourceBytes
    , encodeSourceText
    , parseSourceEncoding
    ) where

import Control.Exception (SomeException, evaluate, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error (strictDecode)

data SourceEncoding = Utf8 | Utf16 | Utf32
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

data EncodingOptions = EncodingOptions
    { inputEncoding :: SourceEncoding
    , outputEncoding :: SourceEncoding
    , emitByteOrderMark :: Bool
    }
    deriving (Eq, Ord, Read, Show)

defaultEncodingOptions :: EncodingOptions
defaultEncodingOptions = EncodingOptions Utf8 Utf8 False

parseSourceEncoding :: String -> Maybe SourceEncoding
parseSourceEncoding value = case value of
    "utf-8" -> Just Utf8
    "utf-16" -> Just Utf16
    "utf-32" -> Just Utf32
    _ -> Nothing

decodeSourceBytes :: SourceEncoding -> ByteString -> IO (Either String String)
decodeSourceBytes encoding bytes = case encoding of
    Utf8 -> pure $ case Text.decodeUtf8' (stripPrefix utf8Bom bytes) of
        Left problem -> Left (show problem)
        Right value -> Right (Text.unpack value)
    Utf16 -> decodeStrict (decodeUtf16 bytes)
    Utf32 -> decodeStrict (decodeUtf32 bytes)

encodeSourceText :: SourceEncoding -> Bool -> String -> ByteString
encodeSourceText encoding emitBom source = prefix <> payload
    where
        value = Text.pack source
        (prefix, payload) = case encoding of
            Utf8 -> (if emitBom then utf8Bom else ByteString.empty, Text.encodeUtf8 value)
            -- UTF_16 and UTF_32 intentionally use little-endian payloads on every
            -- host. The DSL controls BOM presence independently, so output cannot
            -- inherit Windows/macOS byte order or a library-specific default.
            Utf16 -> (if emitBom then utf16LeBom else ByteString.empty, Text.encodeUtf16LE value)
            Utf32 -> (if emitBom then utf32LeBom else ByteString.empty, Text.encodeUtf32LE value)

decodeStrict :: Text -> IO (Either String String)
decodeStrict value = do
    forced <- try (evaluate (Text.length value)) :: IO (Either SomeException Int)
    pure $ case forced of
        Left problem -> Left (show problem)
        Right _ -> Right (Text.unpack value)

decodeUtf16 :: ByteString -> Text
decodeUtf16 bytes
    | utf16BeBom `ByteString.isPrefixOf` bytes = Text.decodeUtf16BEWith strictDecode (ByteString.drop 2 bytes)
    | utf16LeBom `ByteString.isPrefixOf` bytes = Text.decodeUtf16LEWith strictDecode (ByteString.drop 2 bytes)
    | otherwise = Text.decodeUtf16LEWith strictDecode bytes

decodeUtf32 :: ByteString -> Text
decodeUtf32 bytes
    | utf32BeBom `ByteString.isPrefixOf` bytes = Text.decodeUtf32BEWith strictDecode (ByteString.drop 4 bytes)
    | utf32LeBom `ByteString.isPrefixOf` bytes = Text.decodeUtf32LEWith strictDecode (ByteString.drop 4 bytes)
    | otherwise = Text.decodeUtf32LEWith strictDecode bytes

stripPrefix :: ByteString -> ByteString -> ByteString
stripPrefix prefix bytes
    | prefix `ByteString.isPrefixOf` bytes = ByteString.drop (ByteString.length prefix) bytes
    | otherwise = bytes

utf8Bom, utf16LeBom, utf16BeBom, utf32LeBom, utf32BeBom :: ByteString
utf8Bom = ByteString.pack [0xef, 0xbb, 0xbf]
utf16LeBom = ByteString.pack [0xff, 0xfe]
utf16BeBom = ByteString.pack [0xfe, 0xff]
utf32LeBom = ByteString.pack [0xff, 0xfe, 0x00, 0x00]
utf32BeBom = ByteString.pack [0x00, 0x00, 0xfe, 0xff]
