-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Constants and bounded error representation for the CorePrep wire format.
The format version is independent of Core and Xpp wire schemas; every decoder
uses these limits before constructing untrusted compiler data.
-}
module Progmasoft.Tala.Core.CorePrep.Wire.Format
    ( WireVersion (..)
    , currentWireVersion
    , wireMagic
    , WireLimits (..)
    , defaultWireLimits
    , WireErrorKind (..)
    , WireError (..)
    , wireError
    ) where

import Data.Word (Word16, Word8)

-- | Unsigned schema version encoded in a CorePrep document header.
newtype WireVersion
    = -- | Version number compared exactly by decoders.
      WireVersion {wireVersionNumber :: Word16}
    deriving (Eq, Ord, Read, Show)

-- | Schema version emitted by current CorePrep encoders.
currentWireVersion :: WireVersion
currentWireVersion = WireVersion 8

-- | Four-byte ASCII identifier at the start of each CorePrep document.
wireMagic :: [Word8]
wireMagic = map (fromIntegral . fromEnum) "TACP"

-- | Resource bounds used before and during wire encoding/decoding.
data WireLimits = WireLimits
    { maximumWireBytes :: Int
    -- ^ Maximum total document byte size.
    , maximumStringCodePoints :: Int
    -- ^ Maximum Unicode scalar count in one string.
    , maximumFunctions :: Int
    -- ^ Maximum functions in a module.
    , maximumParametersPerFunction :: Int
    -- ^ Maximum arguments or parameters per function.
    , maximumBlocksPerFunction :: Int
    -- ^ Maximum basic blocks in one function.
    , maximumInstructionsPerBlock :: Int
    -- ^ Maximum instructions in one block.
    , maximumOperandsPerInstruction :: Int
    -- ^ Maximum operands on an instruction or terminator.
    , maximumTypeDepth :: Int
    -- ^ Maximum recursive type nesting.
    , maximumNumericBytes :: Int
    -- ^ Maximum bytes in an arbitrary-precision numeric payload.
    }
    deriving (Eq, Ord, Read, Show)

-- | Default finite bounds shared by normal CorePrep readers and writers.
defaultWireLimits :: WireLimits
defaultWireLimits =
    WireLimits
        { maximumWireBytes = 64 * 1024 * 1024
        , maximumStringCodePoints = 1024 * 1024
        , maximumFunctions = 65535
        , maximumParametersPerFunction = 65535
        , maximumBlocksPerFunction = 1048576
        , maximumInstructionsPerBlock = 1048576
        , maximumOperandsPerInstruction = 65535
        , maximumTypeDepth = 128
        , maximumNumericBytes = 4096
        }

-- | Category of a malformed, unsupported, or oversized wire field.
data WireErrorKind
    = -- | Header does not contain the expected format tag.
      InvalidMagic
    | -- | Header version differs from this implementation.
      UnsupportedVersion
    | -- | Input ended before the current field was complete.
      TruncatedInput
    | -- | Bytes remain after one complete document.
      TrailingInput
    | -- | An enum or sum-type tag is not defined by the schema.
      InvalidTag
    | -- | Boolean payload is not a canonical zero or one.
      InvalidBoolean
    | -- | Text contains a non-scalar Unicode value.
      InvalidCodePoint
    | -- | Collection length is malformed or unrepresentable.
      InvalidCount
    | -- | Symbol identity is invalid or reserved.
      InvalidSymbol
    | -- | Arbitrary-precision integer encoding is non-canonical.
      InvalidInteger
    | -- | A CorePrep type has no wire representation.
      UnsupportedType
    | -- | Configured byte, depth, or element ceiling was crossed.
      LimitExceeded
    deriving (Eq, Ord, Read, Show)

-- | Wire failure with byte position, field path, and diagnostic message.
data WireError = WireError
    { wireErrorKind :: WireErrorKind
    -- ^ Programmatically distinguishable failure category.
    , wireErrorOffset :: Int
    -- ^ Byte offset where decoding or encoding failed.
    , wireErrorContext :: String
    -- ^ Nested field path, such as function/block/instruction.
    , wireErrorMessage :: String
    -- ^ Human-readable explanation for diagnostics.
    }
    deriving (Eq, Ord, Read, Show)

-- | Construct a structured wire error without losing source field context.
wireError :: WireErrorKind -> Int -> String -> String -> WireError
wireError = WireError
