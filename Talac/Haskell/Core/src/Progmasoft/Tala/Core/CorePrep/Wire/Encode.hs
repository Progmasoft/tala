-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Bounded encoder for the private CorePrep interchange document.

The encoder validates collection and byte limits while constructing the
complete document, so callers receive either one valid byte vector or a
structured error without partial output.
-}
module Progmasoft.Tala.Core.CorePrep.Wire.Encode (encodeCorePrep, encodeCorePrepWith) where

import Data.Bits (Bits, shiftR, (.&.))
import Data.Char (ord)
import Data.List (unfoldr)
import Data.Word (Word16, Word32, Word64, Word8)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Wire.Format

type Encoder = Either WireError [Word8]

-- | Encode with the shared default resource bounds.
encodeCorePrep :: CorePrepModule -> Either WireError [Word8]
encodeCorePrep = encodeCorePrepWith defaultWireLimits

-- | Encode under explicit limits, including the final serialized size.
encodeCorePrepWith :: WireLimits -> CorePrepModule -> Either WireError [Word8]
encodeCorePrepWith limits moduleValue = do
    payload <- encodeModule limits moduleValue
    let bytes = wireMagic ++ word16 (wireVersionNumber currentWireVersion) ++ word16 0 ++ payload
    requireLimit limits "wire byte length" (maximumWireBytes limits) (length bytes)
    pure bytes

encodeModule :: WireLimits -> CorePrepModule -> Encoder
encodeModule limits moduleValue = do
    name <- encodeQualifiedName limits (corePrepModuleName moduleValue)
    sources <-
        encodeVector
            limits
            "source file count"
            (maximumFunctions limits)
            (encodeText limits "source file")
            (corePrepModuleSourceFiles moduleValue)
    functions <-
        encodeVector
            limits
            "function count"
            (maximumFunctions limits)
            (encodeFunction limits)
            (corePrepModuleFunctions moduleValue)
    pure (name ++ sources ++ functions)

encodeFunction :: WireLimits -> CorePrepFunction -> Encoder
encodeFunction limits function = do
    name <- encodeResolvedName limits "function symbol" (corePrepFunctionName function)
    source <- encodeText limits "function source file" (corePrepFunctionSourceFile function)
    parameters <-
        encodeVector
            limits
            "parameter count"
            (maximumParametersPerFunction limits)
            (encodeParameter limits)
            (corePrepFunctionParameters function)
    result <- encodeType limits (corePrepFunctionReturnType function)
    entry <- encodeNonNegative32 "entry block" (corePrepFunctionEntry function)
    blocks <-
        encodeVector
            limits
            "block count"
            (maximumBlocksPerFunction limits)
            (encodeBlock limits)
            (corePrepFunctionBlocks function)
    pure (name ++ source ++ parameters ++ result ++ entry ++ blocks)

encodeParameter :: WireLimits -> (ResolvedName, Type) -> Encoder
encodeParameter limits (name, valueType) = do
    encodedName <- encodeResolvedName limits "parameter symbol" name
    encodedType <- encodeType limits valueType
    pure (encodedName ++ encodedType)

encodeBlock :: WireLimits -> CorePrepBlock -> Encoder
encodeBlock limits block = do
    identifier <- encodeNonNegative32 "block id" (corePrepBlockId block)
    instructions <-
        encodeVector
            limits
            "instruction count"
            (maximumInstructionsPerBlock limits)
            (encodeInstruction limits)
            (corePrepBlockInstructions block)
    terminator <- encodeTerminator limits (corePrepBlockTerminator block)
    pure (identifier ++ instructions ++ terminator)

encodeInstruction :: WireLimits -> CorePrepInstruction -> Encoder
encodeInstruction limits instruction = case instruction of
    CorePrepBind name valueType mutable operation -> do
        encodedName <- encodeResolvedName limits "binding symbol" name
        encodedType <- encodeType limits valueType
        encodedOperation <- encodeOperation limits operation
        pure ([0] ++ encodedName ++ encodedType ++ encodeBool mutable ++ encodedOperation)
    CorePrepAssign name atom -> do
        encodedName <- encodeResolvedName limits "assignment symbol" name
        encodedAtom <- encodeAtom limits atom
        pure ([1] ++ encodedName ++ encodedAtom)
    CorePrepEvaluate operation -> do
        encodedOperation <- encodeOperation limits operation
        pure ([2] ++ encodedOperation)

encodeOperation :: WireLimits -> CorePrepOperation -> Encoder
encodeOperation limits operation = case operation of
    CorePrepCopy atom -> encodeTaggedAtoms limits 0 [atom]
    CorePrepCall callee arguments -> encodeTaggedAtoms limits 1 (callee : arguments)
    CorePrepPrimitive primitive arguments -> encodeTaggedAtoms limits (primitiveTag primitive) arguments
    CorePrepMakeClosure function captures -> do
        encodedFunction <- encodeResolvedName limits "closure function symbol" function
        encodedCaptures <-
            encodeVector
                limits
                "closure capture count"
                (maximumOperandsPerInstruction limits)
                (encodeCapture limits)
                captures
        pure ([18] ++ encodedFunction ++ encodedCaptures)

encodeCapture :: WireLimits -> CorePrepCapture -> Encoder
encodeCapture limits (CorePrepCapture mode name valueType atom) = do
    encodedName <- encodeResolvedName limits "capture symbol" name
    encodedType <- encodeType limits valueType
    encodedAtom <- encodeAtom limits atom
    pure (captureModeTag mode : encodedName ++ encodedType ++ encodedAtom)

captureModeTag :: CaptureMode -> Word8
captureModeTag mode = case mode of
    StrongCapture -> 0
    WeakCapture -> 1
    UnownedCapture -> 2

encodeTaggedAtoms :: WireLimits -> Word8 -> [CorePrepAtom] -> Encoder
encodeTaggedAtoms limits tag atoms = do
    encoded <- encodeVector limits "operand count" (maximumOperandsPerInstruction limits) (encodeAtom limits) atoms
    pure (tag : encoded)

encodeAtom :: WireLimits -> CorePrepAtom -> Encoder
encodeAtom limits atom = case atom of
    CorePrepVariable name valueType -> do
        encodedName <- encodeResolvedName limits "variable symbol" name
        encodedType <- encodeType limits valueType
        pure ([0] ++ encodedType ++ encodedName)
    CorePrepLiteral literal valueType -> do
        encodedType <- encodeType limits valueType
        encodedLiteral <- encodeLiteral limits valueType literal
        pure ([1] ++ encodedType ++ encodedLiteral)

encodeLiteral :: WireLimits -> Type -> CoreLiteral -> Encoder
encodeLiteral limits valueType literal = case (primitiveTypeTag valueType, literal) of
    (Just 0, CoreUnit) -> pure [0]
    (Just 1, CoreBoolean value) -> pure (1 : encodeBool value)
    (Just tag, CoreInteger value)
        | integerWireTag tag || tag == 8 -> (2 :) <$> encodeInteger limits value
    (Just tag, CoreFloating spelling)
        | floatingWireTag tag -> (4 :) <$> encodeAscii limits "floating literal" spelling
    (Just 4, CoreString value) -> (3 :) <$> encodeText limits "string literal" value
    (_, CoreNull) -> pure [5]
    _ -> Left (wireError UnsupportedType 0 "literal" "literal payload does not match its declared type")

encodeTerminator :: WireLimits -> CorePrepTerminator -> Encoder
encodeTerminator limits terminator = case terminator of
    CorePrepReturn atom -> do encoded <- encodeAtom limits atom; pure (0 : encoded)
    CorePrepBranch atom trueTarget falseTarget -> do
        encoded <- encodeAtom limits atom
        trueBlock <- encodeNonNegative32 "true target" trueTarget
        falseBlock <- encodeNonNegative32 "false target" falseTarget
        pure ([1] ++ encoded ++ trueBlock ++ falseBlock)
    CorePrepJump target -> do encoded <- encodeNonNegative32 "jump target" target; pure (2 : encoded)
    CorePrepUnreachable -> pure [3]

encodeResolvedName :: WireLimits -> String -> ResolvedName -> Encoder
encodeResolvedName limits context name = do
    symbol <- encodePositive64 context (symbolIdValue (resolvedSymbol name))
    spelling <- encodeText limits (context ++ " spelling") (identifierText (resolvedSpelling name))
    pure (symbol ++ spelling)

encodeQualifiedName :: WireLimits -> QualifiedName -> Encoder
encodeQualifiedName limits (QualifiedName parts) =
    encodeVector
        limits
        "qualified name part count"
        65535
        (encodeText limits "qualified name part" . identifierText)
        parts

encodeType :: WireLimits -> Type -> Encoder
encodeType limits = encodeTypeAt limits 0

encodeTypeAt :: WireLimits -> Int -> Type -> Encoder
encodeTypeAt limits depth valueType
    | depth > maximumTypeDepth limits = Left (wireError LimitExceeded 0 "type" "type nesting exceeds configured limit")
    | Just tag <- primitiveTypeTag valueType = pure [tag]
    | NamedType name arguments <- valueType = do
        encodedName <- encodeQualifiedName limits name
        encodedArguments <-
            encodeVector limits "template argument count" 65535 (encodeTemplateArgument limits (depth + 1)) arguments
        pure ([6] ++ encodedName ++ encodedArguments)
    | FunctionType parameters result <- valueType = do
        encodedParameters <-
            encodeVector
                limits
                "function type parameter count"
                65535
                (encodeTypeAt limits (depth + 1))
                parameters
        encodedResult <- encodeTypeAt limits (depth + 1) result
        pure ([5] ++ encodedParameters ++ encodedResult)
    | TypeVariable name <- valueType = do
        encodedName <- encodeResolvedName limits "type variable symbol" name
        pure ([7] ++ encodedName)
    | ErrorType <- valueType =
        Left (wireError UnsupportedType 0 "type" "unresolved ErrorType cannot cross the CorePrep boundary")

encodeTemplateArgument :: WireLimits -> Int -> TemplateArgument -> Encoder
encodeTemplateArgument limits depth argument = case argument of
    TypeTemplateArgument valueType -> (0 :) <$> encodeTypeAt limits depth valueType
    ValueTemplateArgument value -> encodeTemplateValue limits value

encodeTemplateValue :: WireLimits -> TemplateValue -> Encoder
encodeTemplateValue limits value = case value of
    IntegerTemplateValue integer -> (1 :) <$> encodeInteger limits integer
    BooleanTemplateValue boolean -> pure [2, if boolean then 1 else 0]
    CharacterTemplateValue scalar -> (3 :) <$> encodeInteger limits scalar
    TemplateValueParameter name -> do
        encoded <- encodeResolvedName limits "template value parameter" name
        pure (4 : encoded)

primitiveTypeTag :: Type -> Maybe Word8
primitiveTypeTag valueType
    | valueType == unitType = Just 0
    | valueType == boolType = Just 1
    | valueType == stringType = Just 4
    | Just tag <- scalarTypeTag valueType = Just tag
    | otherwise = Nothing

-- Tags 0-7 preserve the v2 structural layout. New scalar tags are append-only,
-- which keeps corrupted-version diagnostics deterministic and makes wire dumps
-- easier to compare while the compiler remains pre-1.0.
scalarTypeTag :: Type -> Maybe Word8
scalarTypeTag (NamedType (QualifiedName [Identifier name]) []) = lookup name scalarTags
scalarTypeTag _ = Nothing

scalarTags :: [(String, Word8)]
scalarTags =
    [ ("bool", 1)
    , ("int", 2)
    , ("long", 3)
    , ("char", 8)
    , ("byte", 9)
    , ("short", 10)
    , ("longint", 11)
    , ("ubyte", 12)
    , ("ushort", 13)
    , ("ulong", 14)
    , ("uint", 15)
    , ("ulongint", 16)
    , ("sfloat", 17)
    , ("lfloat", 18)
    , ("float", 19)
    , ("double", 20)
    ]

integerWireTag :: Word8 -> Bool
integerWireTag tag = tag `elem` [2, 3, 9, 10, 11, 12, 13, 14, 15, 16]

floatingWireTag :: Word8 -> Bool
floatingWireTag tag = tag `elem` [17, 18, 19, 20]

primitiveTag :: CorePrimitive -> Word8
primitiveTag primitive = case primitive of
    CoreAdd -> 2
    CoreSubtract -> 3
    CoreMultiply -> 4
    CoreDivide -> 5
    CoreFloorDivide -> 6
    CoreRemainder -> 7
    CoreLessThan -> 8
    CoreLessEqual -> 9
    CoreGreaterThan -> 10
    CoreGreaterEqual -> 11
    CoreEqual -> 12
    CoreNotEqual -> 13
    CoreLogicalAnd -> 14
    CoreLogicalOr -> 15
    CoreNegate -> 16
    CoreLogicalNot -> 17
    CorePower -> 19
    CoreShiftLeft -> 20
    CoreShiftRight -> 21
    CoreBitwiseAnd -> 22
    CoreBitwiseXor -> 23
    CoreBitwiseOr -> 24
    CoreBitwiseNot -> 25
    CoreTypeIs -> 26
    CoreMemoize -> 27
    CoreRuntimeCall -> 28

encodeVector :: WireLimits -> String -> Int -> (a -> Encoder) -> [a] -> Encoder
encodeVector limits context maximumCount encode values = do
    requireLimit limits context maximumCount (length values)
    encodedCount <- encodeNonNegative32 context (length values)
    encodedValues <- traverse encode values
    pure (encodedCount ++ concat encodedValues)

encodeText :: WireLimits -> String -> String -> Encoder
encodeText limits context value = do
    requireLimit limits context (maximumStringCodePoints limits) (length value)
    count <- encodeNonNegative32 context (length value)
    codePoints <- traverse encodeCodePoint value
    pure (count ++ concat codePoints)
    where
        encodeCodePoint character
            | code >= 0xD800 && code <= 0xDFFF =
                Left (wireError InvalidCodePoint 0 context "surrogate code point is not a scalar value")
            | code > 0x10FFFF = Left (wireError InvalidCodePoint 0 context "code point exceeds Unicode range")
            | otherwise = Right (word32 (fromIntegral code))
            where
                code = ord character

encodeInteger :: WireLimits -> Integer -> Encoder
encodeInteger limits value = do
    let magnitude = integerMagnitude (abs value)
    requireLimit limits "integer magnitude" (maximumNumericBytes limits) (length magnitude)
    count <- encodeNonNegative32 "integer magnitude length" (length magnitude)
    pure (encodeBool (value < 0) ++ count ++ magnitude)

integerMagnitude :: Integer -> [Word8]
integerMagnitude 0 = []
integerMagnitude value = reverse (unfoldr step value)
    where
        step 0 = Nothing
        step remaining = Just (fromIntegral (remaining `mod` 256), remaining `div` 256)

encodeAscii :: WireLimits -> String -> String -> Encoder
encodeAscii limits context value = do
    requireLimit limits context (maximumNumericBytes limits) (length value)
    count <- encodeNonNegative32 (context ++ " length") (length value)
    bytes <- traverse ascii value
    pure (count ++ bytes)
    where
        ascii character
            | ord character <= 0x7f = Right (fromIntegral (ord character))
            | otherwise = Left (wireError InvalidInteger 0 context "numeric spelling must contain ASCII characters only")

encodePositive64 :: String -> Int -> Encoder
encodePositive64 context value
    | value <= 0 = Left (wireError InvalidSymbol 0 context "symbol id must be positive")
    | otherwise = pure (word64 (fromIntegral value))

encodeNonNegative32 :: String -> Int -> Encoder
encodeNonNegative32 context value
    | value < 0 || toInteger value > toInteger (maxBound :: Word32) =
        Left (wireError InvalidCount 0 context "value does not fit unsigned 32-bit wire field")
    | otherwise = pure (word32 (fromIntegral value))

encodeBool :: Bool -> [Word8]
encodeBool False = [0]
encodeBool True = [1]

requireLimit :: WireLimits -> String -> Int -> Int -> Either WireError ()
requireLimit _ context maximumValue actual
    | actual > maximumValue =
        Left (wireError LimitExceeded 0 context ("count " ++ show actual ++ " exceeds limit " ++ show maximumValue))
    | otherwise = Right ()

word16 :: Word16 -> [Word8]
word16 value = [byte value 0, byte value 8]

word32 :: Word32 -> [Word8]
word32 value = [byte value 0, byte value 8, byte value 16, byte value 24]

word64 :: Word64 -> [Word8]
word64 value =
    [ byte value 0
    , byte value 8
    , byte value 16
    , byte value 24
    , byte value 32
    , byte value 40
    , byte value 48
    , byte value 56
    ]

byte :: (Integral a, Bits a) => a -> Int -> Word8
byte value amount = fromIntegral ((value `shiftR` amount) .&. 0xff)
