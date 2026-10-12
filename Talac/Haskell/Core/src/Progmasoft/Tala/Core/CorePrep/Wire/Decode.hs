-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Strict bounded decoder for untrusted CorePrep wire documents.

Every count, scalar, nesting depth, version, and trailing byte is validated
before the decoded module is returned to native compiler code.
-}
module Progmasoft.Tala.Core.CorePrep.Wire.Decode (decodeCorePrep, decodeCorePrepWith) where

import Data.Bits (Bits, shiftL, (.|.))
import Data.Char (chr)
import Data.Word (Word16, Word32, Word64, Word8)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Wire.Format

data DecoderState = DecoderState
    { remainingBytes :: [Word8]
    , consumedBytes :: Int
    , decoderLimits :: WireLimits
    }

newtype Decoder a = Decoder {runDecoder :: DecoderState -> Either WireError (a, DecoderState)}

instance Functor Decoder where
    fmap transform parser = Decoder $ \state -> do
        (value, next) <- runDecoder parser state
        pure (transform value, next)

instance Applicative Decoder where
    pure value = Decoder $ \state -> Right (value, state)
    functionParser <*> valueParser = Decoder $ \state -> do
        (function, afterFunction) <- runDecoder functionParser state
        (value, afterValue) <- runDecoder valueParser afterFunction
        pure (function value, afterValue)

instance Monad Decoder where
    parser >>= nextParser = Decoder $ \state -> do
        (value, afterValue) <- runDecoder parser state
        runDecoder (nextParser value) afterValue

-- | Decode using the standard finite wire limits.
decodeCorePrep :: [Word8] -> Either WireError CorePrepModule
decodeCorePrep = decodeCorePrepWith defaultWireLimits

-- | Decode using caller-selected limits and reject incomplete or trailing data.
decodeCorePrepWith :: WireLimits -> [Word8] -> Either WireError CorePrepModule
decodeCorePrepWith limits bytes
    | length bytes > maximumWireBytes limits =
        Left (wireError LimitExceeded 0 "wire byte length" "input exceeds configured byte limit")
    | otherwise = do
        (moduleValue, finalState) <- runDecoder decodeDocument (DecoderState bytes 0 limits)
        if null (remainingBytes finalState)
            then Right moduleValue
            else Left (wireError TrailingInput (consumedBytes finalState) "document" "bytes remain after CorePrep module")

decodeDocument :: Decoder CorePrepModule
decodeDocument = do
    magic <- takeBytes "magic" 4
    require (magic == wireMagic) InvalidMagic "magic" "input is not a Tala CorePrep wire document"
    version <- readWord16 "version"
    require
        (version == wireVersionNumber currentWireVersion)
        UnsupportedVersion
        "version"
        ("unsupported CorePrep wire version " ++ show version)
    flags <- readWord16 "flags"
    require (flags == 0) InvalidTag "flags" "reserved wire flags must be zero"
    decodeModule

decodeModule :: Decoder CorePrepModule
decodeModule = do
    name <- decodeQualifiedName
    sources <- decodeVector "source file count" maximumFunctions (decodeText "source file")
    functions <- decodeVector "function count" maximumFunctions decodeFunction
    pure (CorePrepModule name functions sources)

decodeFunction :: Decoder CorePrepFunction
decodeFunction =
    CorePrepFunction
        <$> decodeResolvedName "function symbol"
        <*> decodeText "function source file"
        <*> decodeVector "parameter count" maximumParametersPerFunction decodeParameter
        <*> decodeType
        <*> decodeBlockId "entry block"
        <*> decodeVector "block count" maximumBlocksPerFunction decodeBlock

decodeParameter :: Decoder (ResolvedName, Type)
decodeParameter = (,) <$> decodeResolvedName "parameter symbol" <*> decodeType

decodeBlock :: Decoder CorePrepBlock
decodeBlock =
    CorePrepBlock
        <$> decodeBlockId "block id"
        <*> decodeVector "instruction count" maximumInstructionsPerBlock decodeInstruction
        <*> decodeTerminator

decodeInstruction :: Decoder CorePrepInstruction
decodeInstruction = do
    tag <- readWord8 "instruction tag"
    case tag of
        0 ->
            CorePrepBind
                <$> decodeResolvedName "binding symbol"
                <*> decodeType
                <*> decodeBool "binding mutability"
                <*> decodeOperation
        1 -> CorePrepAssign <$> decodeResolvedName "assignment symbol" <*> decodeAtom
        2 -> CorePrepEvaluate <$> decodeOperation
        _ -> invalidTag "instruction tag" tag

decodeOperation :: Decoder CorePrepOperation
decodeOperation = do
    tag <- readWord8 "operation tag"
    case tag of
        18 ->
            CorePrepMakeClosure
                <$> decodeResolvedName "closure function symbol"
                <*> decodeVector "closure capture count" maximumOperandsPerInstruction decodeCapture
        _ -> do
            atoms <- decodeVector "operand count" maximumOperandsPerInstruction decodeAtom
            case tag of
                0 -> case atoms of [atom] -> pure (CorePrepCopy atom); _ -> invalidArity "copy" 1 (length atoms)
                1 -> case atoms of callee : arguments -> pure (CorePrepCall callee arguments); [] -> invalidArity "call" 1 0
                _ -> case tagPrimitive tag of
                    Just primitive -> pure (CorePrepPrimitive primitive atoms)
                    Nothing -> invalidTag "operation tag" tag

decodeCapture :: Decoder CorePrepCapture
decodeCapture = do
    mode <- readWord8 "capture mode" >>= decodeCaptureMode
    name <- decodeResolvedName "capture symbol"
    valueType <- decodeType
    atom <- decodeAtom
    pure (CorePrepCapture mode name valueType atom)

decodeCaptureMode :: Word8 -> Decoder CaptureMode
decodeCaptureMode tag = case tag of
    0 -> pure StrongCapture
    1 -> pure WeakCapture
    2 -> pure UnownedCapture
    _ -> invalidTag "capture mode" tag

decodeAtom :: Decoder CorePrepAtom
decodeAtom = do
    tag <- readWord8 "atom tag"
    valueType <- decodeType
    case tag of
        0 -> CorePrepVariable <$> decodeResolvedName "variable symbol" <*> pure valueType
        1 -> CorePrepLiteral <$> decodeLiteral valueType <*> pure valueType
        _ -> invalidTag "atom tag" tag

decodeLiteral :: Type -> Decoder CoreLiteral
decodeLiteral valueType = do
    tag <- readWord8 "literal tag"
    case tag of
        0 | valueType == unitType -> pure CoreUnit
        1 | valueType == boolType -> CoreBoolean <$> decodeBool "boolean literal"
        2 | typeName valueType == "char" || typeName valueType `elem` integerTypeNames -> CoreInteger <$> decodeInteger
        3 | valueType == stringType -> CoreString <$> decodeText "string literal"
        4 | typeName valueType `elem` floatingTypeNames -> CoreFloating <$> decodeAscii "floating literal"
        5 | referenceLike valueType -> pure CoreNull
        _ -> failAt UnsupportedType "literal" "literal tag does not match its declared type"
    where
        referenceLike value = case value of
            FunctionType _ _ -> True
            NamedType _ _ -> typeName value `notElem` integerTypeNames ++ floatingTypeNames ++ ["char", "bool", "unit"]
            _ -> False

decodeTerminator :: Decoder CorePrepTerminator
decodeTerminator = do
    tag <- readWord8 "terminator tag"
    case tag of
        0 -> CorePrepReturn <$> decodeAtom
        1 -> CorePrepBranch <$> decodeAtom <*> decodeBlockId "true target" <*> decodeBlockId "false target"
        2 -> CorePrepJump <$> decodeBlockId "jump target"
        3 -> pure CorePrepUnreachable
        _ -> invalidTag "terminator tag" tag

decodeResolvedName :: String -> Decoder ResolvedName
decodeResolvedName context = do
    raw <- readWord64 context
    require (raw > 0) InvalidSymbol context "symbol id must be positive"
    require (raw <= fromIntegral (maxBound :: Int)) InvalidSymbol context "symbol id exceeds host Int range"
    spelling <- decodeText (context ++ " spelling")
    pure (ResolvedName (SymbolId (fromIntegral raw)) (Identifier spelling))

decodeQualifiedName :: Decoder QualifiedName
decodeQualifiedName =
    QualifiedName
        <$> decodeVectorWithMaximum
            "qualified name part count"
            65535
            (Identifier <$> decodeText "qualified name part")

decodeType :: Decoder Type
decodeType = decodeTypeAt 0

decodeTypeAt :: Int -> Decoder Type
decodeTypeAt depth = do
    limits <- currentLimits
    require (depth <= maximumTypeDepth limits) LimitExceeded "type" "type nesting exceeds configured limit"
    tag <- readWord8 "type tag"
    case tag of
        0 -> pure unitType
        1 -> pure boolType
        2 -> pure intType
        4 -> pure stringType
        3 -> pure (namedScalar "long")
        5 ->
            FunctionType
                <$> decodeVectorWithMaximum "function type parameter count" 65535 (decodeTypeAt (depth + 1))
                <*> decodeTypeAt (depth + 1)
        6 ->
            NamedType
                <$> decodeQualifiedName
                <*> decodeVectorWithMaximum "template argument count" 65535 (decodeTemplateArgument (depth + 1))
        7 -> TypeVariable <$> decodeResolvedName "type variable symbol"
        8 -> pure (namedScalar "char")
        9 -> pure (namedScalar "byte")
        10 -> pure (namedScalar "short")
        11 -> pure (namedScalar "longint")
        12 -> pure (namedScalar "ubyte")
        13 -> pure (namedScalar "ushort")
        14 -> pure (namedScalar "ulong")
        15 -> pure (namedScalar "uint")
        16 -> pure (namedScalar "ulongint")
        17 -> pure (namedScalar "sfloat")
        18 -> pure (namedScalar "lfloat")
        19 -> pure (namedScalar "float")
        20 -> pure (namedScalar "double")
        _ -> invalidTag "type tag" tag

decodeTemplateArgument :: Int -> Decoder TemplateArgument
decodeTemplateArgument depth = do
    tag <- readWord8 "template argument tag"
    case tag of
        0 -> TypeTemplateArgument <$> decodeTypeAt depth
        1 -> ValueTemplateArgument . IntegerTemplateValue <$> decodeInteger
        2 -> ValueTemplateArgument . BooleanTemplateValue <$> decodeBool "template boolean value"
        3 -> ValueTemplateArgument . CharacterTemplateValue <$> decodeInteger
        4 -> ValueTemplateArgument . TemplateValueParameter <$> decodeResolvedName "template value parameter"
        _ -> invalidTag "template argument tag" tag

namedScalar :: String -> Type
namedScalar name = NamedType (QualifiedName [Identifier name]) []

typeName :: Type -> String
typeName (NamedType (QualifiedName [Identifier name]) []) = name
typeName _ = ""

integerTypeNames :: [String]
integerTypeNames = ["byte", "short", "long", "int", "longint", "ubyte", "ushort", "ulong", "uint", "ulongint"]

floatingTypeNames :: [String]
floatingTypeNames = ["sfloat", "lfloat", "float", "double"]

decodeBlockId :: String -> Decoder Int
decodeBlockId context = fromIntegral <$> readWord32 context

decodeVector :: String -> (WireLimits -> Int) -> Decoder a -> Decoder [a]
decodeVector context selectLimit parser = do
    limits <- currentLimits
    decodeVectorWithMaximum context (selectLimit limits) parser

decodeVectorWithMaximum :: String -> Int -> Decoder a -> Decoder [a]
decodeVectorWithMaximum context maximumCount parser = do
    rawCount <- readWord32 context
    require
        (toInteger rawCount <= toInteger maximumCount)
        LimitExceeded
        context
        ("count " ++ show rawCount ++ " exceeds limit " ++ show maximumCount)
    sequence (replicate (fromIntegral rawCount) parser)

decodeText :: String -> Decoder String
decodeText context = do
    limits <- currentLimits
    count <- readWord32 (context ++ " length")
    require
        (toInteger count <= toInteger (maximumStringCodePoints limits))
        LimitExceeded
        context
        "text exceeds configured code point limit"
    sequence (replicate (fromIntegral count) (decodeCodePoint context))

decodeInteger :: Decoder Integer
decodeInteger = do
    negative <- decodeBool "integer sign"
    limits <- currentLimits
    count <- readWord32 "integer magnitude length"
    require
        (toInteger count <= toInteger (maximumNumericBytes limits))
        LimitExceeded
        "integer magnitude"
        "integer magnitude exceeds configured byte limit"
    magnitude <- takeBytes "integer magnitude" (fromIntegral count)
    require (canonicalMagnitude magnitude) InvalidInteger "integer magnitude" "integer magnitude is not canonical"
    require (not negative || not (null magnitude)) InvalidInteger "integer sign" "zero cannot have a negative sign"
    let value = foldl (\result octet -> result * 256 + fromIntegral octet) 0 magnitude
    pure (if negative then negate value else value)
    where
        canonicalMagnitude [] = True
        canonicalMagnitude (first : _) = first /= 0

decodeAscii :: String -> Decoder String
decodeAscii context = do
    limits <- currentLimits
    count <- readWord32 (context ++ " length")
    require
        (toInteger count <= toInteger (maximumNumericBytes limits))
        LimitExceeded
        context
        "numeric spelling exceeds configured byte limit"
    bytes <- takeBytes context (fromIntegral count)
    require (all (<= 0x7f) bytes) InvalidInteger context "numeric spelling must contain ASCII characters only"
    pure (map (chr . fromIntegral) bytes)

decodeCodePoint :: String -> Decoder Char
decodeCodePoint context = do
    value <- readWord32 context
    require
        (value <= 0x10ffff && not (value >= 0xd800 && value <= 0xdfff))
        InvalidCodePoint
        context
        "wire text contains a non-scalar Unicode code point"
    pure (chr (fromIntegral value))

decodeBool :: String -> Decoder Bool
decodeBool context = do
    value <- readWord8 context
    case value of
        0 -> pure False
        1 -> pure True
        _ -> failAt InvalidBoolean context ("invalid boolean byte " ++ show value)

tagPrimitive :: Word8 -> Maybe CorePrimitive
tagPrimitive tag = case tag of
    2 -> Just CoreAdd
    3 -> Just CoreSubtract
    4 -> Just CoreMultiply
    5 -> Just CoreDivide
    6 -> Just CoreFloorDivide
    7 -> Just CoreRemainder
    8 -> Just CoreLessThan
    9 -> Just CoreLessEqual
    10 -> Just CoreGreaterThan
    11 -> Just CoreGreaterEqual
    12 -> Just CoreEqual
    13 -> Just CoreNotEqual
    14 -> Just CoreLogicalAnd
    15 -> Just CoreLogicalOr
    16 -> Just CoreNegate
    17 -> Just CoreLogicalNot
    19 -> Just CorePower
    20 -> Just CoreShiftLeft
    21 -> Just CoreShiftRight
    22 -> Just CoreBitwiseAnd
    23 -> Just CoreBitwiseXor
    24 -> Just CoreBitwiseOr
    25 -> Just CoreBitwiseNot
    26 -> Just CoreTypeIs
    27 -> Just CoreMemoize
    28 -> Just CoreRuntimeCall
    _ -> Nothing

invalidTag :: String -> Word8 -> Decoder a
invalidTag context tag = failAt InvalidTag context ("unknown tag " ++ show tag)

invalidArity :: String -> Int -> Int -> Decoder a
invalidArity context expected actual =
    failAt
        InvalidCount
        context
        ("expected " ++ show expected ++ " operand(s), found " ++ show actual)

currentLimits :: Decoder WireLimits
currentLimits = Decoder $ \state -> Right (decoderLimits state, state)

require :: Bool -> WireErrorKind -> String -> String -> Decoder ()
require condition kind context message = if condition then pure () else failAt kind context message

failAt :: WireErrorKind -> String -> String -> Decoder a
failAt kind context message = Decoder $ \state -> Left (wireError kind (consumedBytes state) context message)

takeBytes :: String -> Int -> Decoder [Word8]
takeBytes context count = Decoder $ \state ->
    let (prefix, suffix) = splitAt count (remainingBytes state)
     in if length prefix == count
            then Right (prefix, state {remainingBytes = suffix, consumedBytes = consumedBytes state + count})
            else
                Left
                    ( wireError
                        TruncatedInput
                        (consumedBytes state)
                        context
                        ("needed " ++ show count ++ " byte(s), found " ++ show (length prefix))
                    )

readWord8 :: String -> Decoder Word8
readWord8 context = do
    bytes <- takeBytes context 1
    case bytes of
        [value] -> pure value
        _ -> failAt TruncatedInput context "byte reader received an empty result"

readWord16 :: String -> Decoder Word16
readWord16 context = assemble <$> takeBytes context 2

readWord32 :: String -> Decoder Word32
readWord32 context = assemble <$> takeBytes context 4

readWord64 :: String -> Decoder Word64
readWord64 context = assemble <$> takeBytes context 8

assemble :: (Integral a, Bits a) => [Word8] -> a
assemble bytes = foldr combine 0 (zip [0 ..] bytes)
    where
        combine (index, value) result = result .|. (fromIntegral value `shiftL` (index * 8))
