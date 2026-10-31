-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Versioned, bounded binary codec for the compiler's private Core IR.

Core artifacts are an internal stage boundary rather than a user-facing
emission format. Decoding applies explicit resource limits before exposing a
module to verification or native compilation.
-}
module Progmasoft.Tala.Core.Wire
    ( encodeCore
    , decodeCore
    , CoreWireVersion (..)
    , currentCoreWireVersion
    , CoreWireLimits (..)
    , defaultCoreWireLimits
    , CoreWireErrorKind (..)
    , CoreWireError (..)
    ) where

import Data.Bits (Bits, shiftL, shiftR, (.&.), (.|.))
import Data.Char (chr, ord)
import Data.Int (Int64)
import Data.List (unfoldr)
import Data.Map.Strict qualified as Map
import Data.Word (Word16, Word32, Word64, Word8)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core

-- | Unsigned schema version stored in a Core wire document header.
newtype CoreWireVersion = CoreWireVersion {coreWireVersionNumber :: Word16}
    deriving (Eq, Ord, Read, Show)

-- | Schema version emitted by the current Core writer.
currentCoreWireVersion :: CoreWireVersion
currentCoreWireVersion = CoreWireVersion 10

-- | Finite bounds for total bytes, recursion, and individual collections.
data CoreWireLimits = CoreWireLimits
    { maximumCoreWireBytes :: Int
    , maximumCoreTextScalars :: Int
    , maximumCoreFunctions :: Int
    , maximumCoreParameters :: Int
    , maximumCoreStatements :: Int
    , maximumCoreOperands :: Int
    , maximumCoreTypeDepth :: Int
    , maximumCoreExpressionDepth :: Int
    , maximumCoreNumericBytes :: Int
    }
    deriving (Eq, Ord, Read, Show)

-- | Default resource bounds shared by normal Core readers and writers.
defaultCoreWireLimits :: CoreWireLimits
defaultCoreWireLimits =
    CoreWireLimits
        { maximumCoreWireBytes = 64 * 1024 * 1024
        , maximumCoreTextScalars = 1024 * 1024
        , maximumCoreFunctions = 65535
        , maximumCoreParameters = 65535
        , maximumCoreStatements = 1048576
        , maximumCoreOperands = 65535
        , maximumCoreTypeDepth = 128
        , maximumCoreExpressionDepth = 4096
        , maximumCoreNumericBytes = 4096
        }

-- | Category of malformed input, unsupported schema data, or exceeded limit.
data CoreWireErrorKind
    = CoreInvalidMagic
    | CoreUnsupportedVersion
    | CoreTruncatedInput
    | CoreTrailingInput
    | CoreInvalidTag
    | CoreInvalidBoolean
    | CoreInvalidScalar
    | CoreInvalidCount
    | CoreInvalidSymbol
    | CoreInvalidInteger
    | CoreUnsupportedType
    | CoreLimitExceeded
    deriving (Eq, Ord, Read, Show)

-- | Structured wire error with byte offset and nested field context.
data CoreWireError = CoreWireError
    { coreWireErrorKind :: CoreWireErrorKind
    , coreWireErrorOffset :: Int
    , coreWireErrorContext :: String
    , coreWireErrorMessage :: String
    }
    deriving (Eq, Ord, Read, Show)

{- | Bytes under construction.

An encoded module is assembled from the encodings of its parts, and a part
may hold nearly all of the module: the body of a deeply nested statement, or
the rest of an @else if@ chain. Appending lists would copy such a part once
for every level around it, which makes encoding quadratic in the nesting
depth. A function that prepends its bytes to whatever follows is composed in
constant time, and the list is produced once, at the end.
-}
newtype Bytes = Bytes ([Word8] -> [Word8])

instance Semigroup Bytes where
    Bytes first <> Bytes second = Bytes (first . second)

instance Monoid Bytes where
    mempty = Bytes id

tagByte :: Word8 -> Bytes
tagByte value = Bytes (value :)

rawBytes :: [Word8] -> Bytes
rawBytes values = Bytes (values ++)

runBytes :: Bytes -> [Word8]
runBytes (Bytes prepend) = prepend []

type Encoder = Either CoreWireError Bytes

-- | Encode one Core module under explicit resource limits.
encodeCore :: CoreWireLimits -> CoreModule -> Either CoreWireError [Word8]
encodeCore limits moduleValue = do
    payload <- encodeModule limits moduleValue
    let output =
            runBytes
                (rawBytes magic <> rawBytes (word16 (coreWireVersionNumber currentCoreWireVersion)) <> rawBytes (word16 0) <> payload)
    requireEncode limits "wire byte length" (maximumCoreWireBytes limits) (length output)
    pure output

encodeModule :: CoreWireLimits -> CoreModule -> Encoder
encodeModule limits moduleValue = do
    name <- encodeQualifiedName limits (coreModuleName moduleValue)
    sources <-
        encodeVector
            limits
            "source file count"
            (maximumCoreFunctions limits)
            (encodeText limits "source file")
            (coreModuleSourceFiles moduleValue)
    let owners = Map.fromList (coreModuleFunctionSources moduleValue)
    functions <-
        encodeVector
            limits
            "function count"
            (maximumCoreFunctions limits)
            (encodeFunction limits owners)
            (coreModuleFunctions moduleValue)
    pure (name <> sources <> functions)

encodeFunction :: CoreWireLimits -> Map.Map Int FilePath -> CoreFunction -> Encoder
encodeFunction limits owners function = do
    name <- encodeResolvedName limits "function symbol" (coreFunctionName function)
    source <-
        encodeText
            limits
            "function source file"
            (Map.findWithDefault "" (symbolIdValue (resolvedSymbol (coreFunctionName function))) owners)
    parameters <-
        encodeVector
            limits
            "parameter count"
            (maximumCoreParameters limits)
            (encodeParameter limits)
            (coreFunctionParameters function)
    result <- encodeType limits 0 (coreFunctionReturnType function)
    body <-
        encodeVector
            limits
            "statement count"
            (maximumCoreStatements limits)
            (encodeStatement limits)
            (coreFunctionBody function)
    pure (name <> source <> parameters <> result <> body)

encodeParameter :: CoreWireLimits -> (ResolvedName, Type) -> Encoder
encodeParameter limits (name, valueType) =
    (<>)
        <$> encodeResolvedName limits "parameter symbol" name
        <*> encodeType limits 0 valueType

encodeStatement :: CoreWireLimits -> CoreStatement -> Encoder
encodeStatement limits statement = case statement of
    CoreBind binding -> do
        name <- encodeResolvedName limits "binding symbol" (coreBindingName binding)
        valueType <- encodeType limits 0 (coreBindingType binding)
        value <- encodeExpression limits 0 (coreBindingValue binding)
        pure (tagByte 0 <> name <> valueType <> rawBytes (encodeBool (coreBindingMutable binding)) <> value)
    CoreAssign name expression ->
        taggedExpression 1
            <$> encodeResolvedName limits "assignment symbol" name
            <*> encodeExpression limits 0 expression
    CoreReturn expression -> (tagByte 2 <>) <$> encodeExpression limits 0 expression
    CoreIf condition trueBranch falseBranch -> do
        encodedCondition <- encodeExpression limits 0 condition
        encodedTrue <-
            encodeVector
                limits
                "true branch statement count"
                (maximumCoreStatements limits)
                (encodeStatement limits)
                trueBranch
        encodedFalse <-
            encodeVector
                limits
                "false branch statement count"
                (maximumCoreStatements limits)
                (encodeStatement limits)
                falseBranch
        pure (tagByte 3 <> encodedCondition <> encodedTrue <> encodedFalse)
    CoreEvaluate expression -> (tagByte 4 <>) <$> encodeExpression limits 0 expression
    CoreWhile condition body -> do
        encodedCondition <- encodeExpression limits 0 condition
        encodedBody <-
            encodeVector
                limits
                "while body statement count"
                (maximumCoreStatements limits)
                (encodeStatement limits)
                body
        pure (tagByte 5 <> encodedCondition <> encodedBody)
    CoreDoWhile body condition -> do
        encodedBody <-
            encodeVector
                limits
                "do/while body statement count"
                (maximumCoreStatements limits)
                (encodeStatement limits)
                body
        encodedCondition <- encodeExpression limits 0 condition
        pure (tagByte 6 <> encodedBody <> encodedCondition)
    CoreFor condition body update -> do
        encodedCondition <- encodeExpression limits 0 condition
        encodedBody <-
            encodeVector
                limits
                "for body statement count"
                (maximumCoreStatements limits)
                (encodeStatement limits)
                body
        encodedUpdate <-
            encodeVector
                limits
                "for update statement count"
                (maximumCoreStatements limits)
                (encodeStatement limits)
                update
        pure (tagByte 7 <> encodedCondition <> encodedBody <> encodedUpdate)
    CoreBreak -> pure (tagByte 8)
    CoreContinue -> pure (tagByte 9)
    where
        taggedExpression tag left right = tagByte tag <> left <> right

encodeExpression :: CoreWireLimits -> Int -> CoreExpression -> Encoder
encodeExpression limits depth expression
    | depth > maximumCoreExpressionDepth limits = failure CoreLimitExceeded "expression" "expression nesting exceeds limit"
    | otherwise = case expression of
        CoreVariable name valueType -> do
            encodedType <- encodeType limits 0 valueType
            encodedName <- encodeResolvedName limits "variable symbol" name
            pure (tagByte 0 <> encodedType <> encodedName)
        CoreLiteral literal valueType -> do
            encodedType <- encodeType limits 0 valueType
            encodedLiteral <- encodeLiteral limits literal
            pure (tagByte 1 <> encodedType <> encodedLiteral)
        CoreApply callee arguments valueType -> do
            encodedType <- encodeType limits 0 valueType
            encodedCallee <- encodeExpression limits (depth + 1) callee
            encodedArguments <-
                encodeVector
                    limits
                    "call argument count"
                    (maximumCoreOperands limits)
                    (encodeExpression limits (depth + 1))
                    arguments
            pure (tagByte 2 <> encodedType <> encodedCallee <> encodedArguments)
        -- The first operand of a primitive is at the depth of the
        -- primitive: a chain of operators nests in it, as deep as the chain
        -- is long, and every stage walks that chain in a loop.
        CorePrimitive primitive arguments valueType -> do
            encodedType <- encodeType limits 0 valueType
            encodedArguments <-
                encodeVector
                    limits
                    "primitive operand count"
                    (maximumCoreOperands limits)
                    (\(position, argument) -> encodeExpression limits (depth + position) argument)
                    (zip (0 : repeat 1) arguments)
            pure (rawBytes [3, primitiveTag primitive] <> encodedType <> encodedArguments)
        CoreClosure captures parameters returnType body valueType -> do
            encodedType <- encodeType limits 0 valueType
            encodedCaptures <-
                encodeVector
                    limits
                    "closure capture count"
                    (maximumCoreOperands limits)
                    (encodeCoreCapture limits depth)
                    captures
            encodedParameters <-
                encodeVector
                    limits
                    "closure parameter count"
                    (maximumCoreParameters limits)
                    (encodeParameter limits)
                    parameters
            encodedReturn <- encodeType limits 0 returnType
            encodedBody <-
                encodeVector
                    limits
                    "closure statement count"
                    (maximumCoreStatements limits)
                    (encodeStatement limits)
                    body
            pure (tagByte 4 <> encodedType <> encodedCaptures <> encodedParameters <> encodedReturn <> encodedBody)
        CoreLet name bindingType value body valueType -> do
            encodedType <- encodeType limits 0 valueType
            encodedName <- encodeResolvedName limits "let symbol" name
            encodedBindingType <- encodeType limits 0 bindingType
            encodedValue <- encodeExpression limits (depth + 1) value
            encodedBody <- encodeExpression limits (depth + 1) body
            pure (tagByte 5 <> encodedType <> encodedName <> encodedBindingType <> encodedValue <> encodedBody)
        CoreConditional condition whenTrue whenFalse valueType -> do
            encodedType <- encodeType limits 0 valueType
            encodedCondition <- encodeExpression limits (depth + 1) condition
            encodedTrue <- encodeExpression limits (depth + 1) whenTrue
            encodedFalse <- encodeExpression limits (depth + 1) whenFalse
            pure (tagByte 6 <> encodedType <> encodedCondition <> encodedTrue <> encodedFalse)

encodeCoreCapture :: CoreWireLimits -> Int -> CoreCapture -> Encoder
encodeCoreCapture limits depth capture = do
    encodedName <- encodeResolvedName limits "closure capture symbol" (coreCaptureName capture)
    encodedType <- encodeType limits 0 (coreCaptureType capture)
    encodedValue <- encodeExpression limits (depth + 1) (coreCaptureValue capture)
    pure (tagByte (captureModeTag (coreCaptureMode capture)) <> encodedName <> encodedType <> encodedValue)

captureModeTag :: CaptureMode -> Word8
captureModeTag mode = case mode of
    StrongCapture -> 0
    WeakCapture -> 1
    UnownedCapture -> 2

encodeLiteral :: CoreWireLimits -> CoreLiteral -> Encoder
encodeLiteral limits literal = case literal of
    CoreUnit -> pure (tagByte 0)
    CoreBoolean value -> pure (tagByte 1 <> rawBytes (encodeBool value))
    CoreInteger value -> (tagByte 4 <>) <$> encodeInteger limits value
    CoreFloating spelling -> (tagByte 5 <>) <$> encodeAscii limits "floating literal" spelling
    CoreString value -> (tagByte 3 <>) <$> encodeText limits "string literal" value
    CoreNull -> pure (tagByte 6)

encodeType :: CoreWireLimits -> Int -> Type -> Encoder
encodeType limits depth valueType
    | depth > maximumCoreTypeDepth limits = failure CoreLimitExceeded "type" "type nesting exceeds limit"
    | valueType == unitType = pure (tagByte 0)
    | valueType == boolType = pure (tagByte 1)
    | valueType == intType = pure (tagByte 2)
    | valueType == stringType = pure (tagByte 3)
    | Just scalarTag <- scalarTypeTag valueType = pure (tagByte scalarTag)
    | NamedType name arguments <- valueType = do
        encodedName <- encodeQualifiedName limits name
        encodedArguments <-
            encodeVector
                limits
                "type argument count"
                (maximumCoreOperands limits)
                (encodeTemplateArgument limits (depth + 1))
                arguments
        pure (tagByte 4 <> encodedName <> encodedArguments)
    | FunctionType parameters result <- valueType = do
        encodedParameters <-
            encodeVector
                limits
                "function type parameter count"
                (maximumCoreParameters limits)
                (encodeType limits (depth + 1))
                parameters
        encodedResult <- encodeType limits (depth + 1) result
        pure (tagByte 5 <> encodedParameters <> encodedResult)
    | TypeVariable name <- valueType = (tagByte 6 <>) <$> encodeResolvedName limits "type variable symbol" name
    | ErrorType <- valueType = failure CoreUnsupportedType "type" "ErrorType cannot cross the Core boundary"

encodeTemplateArgument :: CoreWireLimits -> Int -> TemplateArgument -> Encoder
encodeTemplateArgument limits depth argument = case argument of
    TypeTemplateArgument valueType -> (tagByte 0 <>) <$> encodeType limits depth valueType
    ValueTemplateArgument value -> encodeTemplateValue limits value

encodeTemplateValue :: CoreWireLimits -> TemplateValue -> Encoder
encodeTemplateValue limits value = case value of
    IntegerTemplateValue integer -> (tagByte 1 <>) <$> encodeInteger limits integer
    BooleanTemplateValue boolean -> pure (rawBytes [2, if boolean then 1 else 0])
    CharacterTemplateValue scalar -> (tagByte 3 <>) <$> encodeInteger limits scalar
    TemplateValueParameter name -> (tagByte 4 <>) <$> encodeResolvedName limits "template value parameter" name

encodeResolvedName :: CoreWireLimits -> String -> ResolvedName -> Encoder
encodeResolvedName limits context name
    | symbolIdValue (resolvedSymbol name) <= 0 = failure CoreInvalidSymbol context "symbol id must be positive"
    | otherwise = do
        spelling <- encodeText limits (context ++ " spelling") (identifierText (resolvedSpelling name))
        pure (rawBytes (word64 (fromIntegral (symbolIdValue (resolvedSymbol name)))) <> spelling)

encodeQualifiedName :: CoreWireLimits -> QualifiedName -> Encoder
encodeQualifiedName limits (QualifiedName parts) =
    encodeVector
        limits
        "qualified name parts"
        65535
        (encodeText limits "qualified name part" . identifierText)
        parts

encodeVector :: CoreWireLimits -> String -> Int -> (a -> Encoder) -> [a] -> Encoder
encodeVector limits context maximumValue encode values = do
    requireEncode limits context maximumValue (length values)
    encoded <- traverse encode values
    pure (rawBytes (word32 (fromIntegral (length values))) <> mconcat encoded)

encodeText :: CoreWireLimits -> String -> String -> Encoder
encodeText limits context value = do
    requireEncode limits context (maximumCoreTextScalars limits) (length value)
    codePoints <- traverse encodeScalar value
    pure (rawBytes (word32 (fromIntegral (length value))) <> mconcat codePoints)
    where
        encodeScalar character
            | code >= 0xd800 && code <= 0xdfff = failure CoreInvalidScalar context "surrogate is not a Unicode scalar"
            | code > 0x10ffff = failure CoreInvalidScalar context "code point exceeds Unicode range"
            | otherwise = pure (rawBytes (word32 (fromIntegral code)))
            where
                code = ord character

scalarTypeTag :: Type -> Maybe Word8
scalarTypeTag (NamedType (QualifiedName [Identifier name]) []) = lookup name tags
    where
        tags =
            [ ("char", 7)
            , ("byte", 8)
            , ("short", 9)
            , ("long", 10)
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
scalarTypeTag _ = Nothing

encodeInteger :: CoreWireLimits -> Integer -> Encoder
encodeInteger limits value = do
    let magnitude = integerMagnitude (abs value)
    requireEncode limits "integer magnitude" (maximumCoreNumericBytes limits) (length magnitude)
    pure (rawBytes (encodeBool (value < 0)) <> rawBytes (word32 (fromIntegral (length magnitude))) <> rawBytes magnitude)

integerMagnitude :: Integer -> [Word8]
integerMagnitude 0 = []
integerMagnitude value = reverse (unfoldr step value)
    where
        step 0 = Nothing
        step remaining = Just (fromIntegral (remaining `mod` 256), remaining `div` 256)

encodeAscii :: CoreWireLimits -> String -> String -> Encoder
encodeAscii limits context value = do
    requireEncode limits context (maximumCoreNumericBytes limits) (length value)
    characters <- traverse ascii value
    pure (rawBytes (word32 (fromIntegral (length characters))) <> rawBytes characters)
    where
        ascii character
            | ord character <= 0x7f = Right (fromIntegral (ord character))
            | otherwise = failure CoreInvalidInteger context "numeric spelling must contain ASCII characters only"

requireEncode :: CoreWireLimits -> String -> Int -> Int -> Either CoreWireError ()
requireEncode _ context maximumValue actual
    | actual > maximumValue = failure CoreLimitExceeded context ("count exceeds configured limit: " ++ show actual)
    | otherwise = Right ()

data DecoderState = DecoderState [Word8] Int CoreWireLimits
newtype Decoder a = Decoder {runDecoder :: DecoderState -> Either CoreWireError (a, DecoderState)}

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

-- | Decode and validate one Core document under explicit resource limits.
decodeCore :: CoreWireLimits -> [Word8] -> Either CoreWireError CoreModule
decodeCore limits bytes
    | length bytes > maximumCoreWireBytes limits =
        failure CoreLimitExceeded "wire byte length" "input exceeds configured limit"
    | otherwise = do
        (moduleValue, DecoderState remaining offset _) <- runDecoder decodeDocument (DecoderState bytes 0 limits)
        if null remaining
            then Right moduleValue
            else Left (CoreWireError CoreTrailingInput offset "document" "bytes remain after Core module")

decodeDocument :: Decoder CoreModule
decodeDocument = do
    header <- takeBytes "magic" 4
    requireDecode (header == magic) CoreInvalidMagic "magic" "input is not a Tala Core document"
    version <- readWord16 "version"
    requireDecode
        (version == coreWireVersionNumber currentCoreWireVersion)
        CoreUnsupportedVersion
        "version"
        "unsupported Core wire version"
    flags <- readWord16 "flags"
    requireDecode (flags == 0) CoreInvalidTag "flags" "reserved flags must be zero"
    name <- decodeQualifiedName
    sources <- decodeVector "source file count" maximumCoreFunctions (decodeText "source file")
    functionsWithSources <- decodeVector "function count" maximumCoreFunctions decodeFunction
    let functions = map fst functionsWithSources
        owners =
            [ (symbolIdValue (resolvedSymbol (coreFunctionName function)), source)
            | (function, source) <- functionsWithSources
            , not (null source)
            ]
    pure (CoreModuleWithSources name functions sources owners)

decodeFunction :: Decoder (CoreFunction, FilePath)
decodeFunction = do
    name <- decodeResolvedName "function symbol"
    source <- decodeText "function source file"
    parameters <- decodeVector "parameter count" maximumCoreParameters decodeParameter
    result <- decodeType 0
    body <- decodeVector "statement count" maximumCoreStatements decodeStatement
    pure (CoreFunction name parameters result body, source)

decodeParameter :: Decoder (ResolvedName, Type)
decodeParameter = (,) <$> decodeResolvedName "parameter symbol" <*> decodeType 0

decodeStatement :: Decoder CoreStatement
decodeStatement = do
    tag <- readWord8 "statement tag"
    case tag of
        0 ->
            CoreBind
                <$> ( CoreBinding
                        <$> decodeResolvedName "binding symbol"
                        <*> decodeType 0
                        <*> decodeBool "binding mutability"
                        <*> decodeExpression 0
                    )
        1 -> CoreAssign <$> decodeResolvedName "assignment symbol" <*> decodeExpression 0
        2 -> CoreReturn <$> decodeExpression 0
        3 ->
            CoreIf
                <$> decodeExpression 0
                <*> decodeVector "true branch statement count" maximumCoreStatements decodeStatement
                <*> decodeVector "false branch statement count" maximumCoreStatements decodeStatement
        4 -> CoreEvaluate <$> decodeExpression 0
        5 -> CoreWhile <$> decodeExpression 0 <*> decodeVector "while body statement count" maximumCoreStatements decodeStatement
        6 ->
            CoreDoWhile
                <$> decodeVector "do/while body statement count" maximumCoreStatements decodeStatement
                <*> decodeExpression 0
        7 ->
            CoreFor
                <$> decodeExpression 0
                <*> decodeVector "for body statement count" maximumCoreStatements decodeStatement
                <*> decodeVector "for update statement count" maximumCoreStatements decodeStatement
        8 -> pure CoreBreak
        9 -> pure CoreContinue
        _ -> invalidTag "statement tag" tag

decodeExpression :: Int -> Decoder CoreExpression
decodeExpression depth = do
    limits <- currentLimits
    requireDecode
        (depth <= maximumCoreExpressionDepth limits)
        CoreLimitExceeded
        "expression"
        "expression nesting exceeds limit"
    tag <- readWord8 "expression tag"
    case tag of
        0 -> flip CoreVariable <$> decodeType 0 <*> decodeResolvedName "variable symbol"
        1 -> do valueType <- decodeType 0; literal <- decodeLiteral; pure (CoreLiteral literal valueType)
        2 -> do
            valueType <- decodeType 0
            callee <- decodeExpression (depth + 1)
            arguments <- decodeVector "call argument count" maximumCoreOperands (decodeExpression (depth + 1))
            pure (CoreApply callee arguments valueType)
        3 -> do
            primitive <- readWord8 "primitive tag" >>= decodePrimitive
            valueType <- decodeType 0
            count <- readWord32 "primitive operand count"
            requireDecode
                (toInteger count <= toInteger (maximumCoreOperands limits))
                CoreLimitExceeded
                "primitive operand count"
                "count exceeds configured limit"
            -- The first operand is at the depth of the primitive.
            arguments <-
                sequence
                    [ decodeExpression (depth + position)
                    | position <- take (fromIntegral count) (0 : repeat 1)
                    ]
            pure (CorePrimitive primitive arguments valueType)
        4 -> do
            valueType <- decodeType 0
            captures <- decodeVector "closure capture count" maximumCoreOperands (decodeCoreCapture (depth + 1))
            parameters <- decodeVector "closure parameter count" maximumCoreParameters decodeParameter
            returnType <- decodeType 0
            body <- decodeVector "closure statement count" maximumCoreStatements decodeStatement
            pure (CoreClosure captures parameters returnType body valueType)
        5 -> do
            valueType <- decodeType 0
            name <- decodeResolvedName "let symbol"
            bindingType <- decodeType 0
            value <- decodeExpression (depth + 1)
            body <- decodeExpression (depth + 1)
            pure (CoreLet name bindingType value body valueType)
        6 -> do
            valueType <- decodeType 0
            condition <- decodeExpression (depth + 1)
            whenTrue <- decodeExpression (depth + 1)
            whenFalse <- decodeExpression (depth + 1)
            pure (CoreConditional condition whenTrue whenFalse valueType)
        _ -> invalidTag "expression tag" tag

decodeCoreCapture :: Int -> Decoder CoreCapture
decodeCoreCapture depth = do
    mode <- readWord8 "closure capture mode" >>= decodeCaptureMode
    name <- decodeResolvedName "closure capture symbol"
    valueType <- decodeType 0
    value <- decodeExpression depth
    pure (CoreCapture mode name valueType value)

decodeCaptureMode :: Word8 -> Decoder CaptureMode
decodeCaptureMode tag = case tag of
    0 -> pure StrongCapture
    1 -> pure WeakCapture
    2 -> pure UnownedCapture
    _ -> invalidTag "closure capture mode" tag

decodeLiteral :: Decoder CoreLiteral
decodeLiteral = do
    tag <- readWord8 "literal tag"
    case tag of
        0 -> pure CoreUnit
        1 -> CoreBoolean <$> decodeBool "boolean literal"
        2 -> CoreInteger . fromIntegral . (fromIntegral :: Word64 -> Int64) <$> readWord64 "integer literal"
        3 -> CoreString <$> decodeText "string literal"
        4 -> CoreInteger <$> decodeInteger
        5 -> CoreFloating <$> decodeAscii "floating literal"
        6 -> pure CoreNull
        _ -> invalidTag "literal tag" tag

decodeType :: Int -> Decoder Type
decodeType depth = do
    limits <- currentLimits
    requireDecode (depth <= maximumCoreTypeDepth limits) CoreLimitExceeded "type" "type nesting exceeds limit"
    tag <- readWord8 "type tag"
    case tag of
        0 -> pure unitType
        1 -> pure boolType
        2 -> pure intType
        3 -> pure stringType
        4 ->
            NamedType
                <$> decodeQualifiedName
                <*> decodeVector "template argument count" maximumCoreOperands (decodeTemplateArgument (depth + 1))
        5 ->
            FunctionType
                <$> decodeVector "function type parameter count" maximumCoreParameters (decodeType (depth + 1))
                <*> decodeType (depth + 1)
        6 -> TypeVariable <$> decodeResolvedName "type variable symbol"
        7 -> pure (namedScalar "char")
        8 -> pure (namedScalar "byte")
        9 -> pure (namedScalar "short")
        10 -> pure (namedScalar "long")
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
        0 -> TypeTemplateArgument <$> decodeType depth
        1 -> ValueTemplateArgument . IntegerTemplateValue <$> decodeInteger
        2 -> ValueTemplateArgument . BooleanTemplateValue <$> decodeBool "template boolean value"
        3 -> ValueTemplateArgument . CharacterTemplateValue <$> decodeInteger
        4 -> ValueTemplateArgument . TemplateValueParameter <$> decodeResolvedName "template value parameter"
        _ -> invalidTag "template argument tag" tag

namedScalar :: String -> Type
namedScalar name = NamedType (QualifiedName [Identifier name]) []

decodeResolvedName :: String -> Decoder ResolvedName
decodeResolvedName context = do
    raw <- readWord64 context
    requireDecode (raw > 0 && raw <= fromIntegral (maxBound :: Int)) CoreInvalidSymbol context "invalid symbol id"
    ResolvedName (SymbolId (fromIntegral raw)) . Identifier <$> decodeText (context ++ " spelling")

decodeQualifiedName :: Decoder QualifiedName
decodeQualifiedName = QualifiedName <$> decodeVectorMaximum "qualified name parts" 65535 (Identifier <$> decodeText "qualified name part")

decodeVector :: String -> (CoreWireLimits -> Int) -> Decoder a -> Decoder [a]
decodeVector context selectMaximum parser = currentLimits >>= \limits -> decodeVectorMaximum context (selectMaximum limits) parser

decodeVectorMaximum :: String -> Int -> Decoder a -> Decoder [a]
decodeVectorMaximum context maximumValue parser = do
    count <- readWord32 context
    requireDecode (toInteger count <= toInteger maximumValue) CoreLimitExceeded context "count exceeds configured limit"
    sequence (replicate (fromIntegral count) parser)

decodeText :: String -> Decoder String
decodeText context = do
    limits <- currentLimits
    count <- readWord32 (context ++ " length")
    requireDecode
        (toInteger count <= toInteger (maximumCoreTextScalars limits))
        CoreLimitExceeded
        context
        "text exceeds configured limit"
    sequence (replicate (fromIntegral count) decodeScalar)
    where
        decodeScalar = do
            value <- readWord32 context
            requireDecode
                (value <= 0x10ffff && not (value >= 0xd800 && value <= 0xdfff))
                CoreInvalidScalar
                context
                "invalid Unicode scalar"
            pure (chr (fromIntegral value))

decodeInteger :: Decoder Integer
decodeInteger = do
    negative <- decodeBool "integer sign"
    limits <- currentLimits
    count <- readWord32 "integer magnitude length"
    requireDecode
        (toInteger count <= toInteger (maximumCoreNumericBytes limits))
        CoreLimitExceeded
        "integer magnitude"
        "integer magnitude exceeds configured limit"
    magnitude <- takeBytes "integer magnitude" (fromIntegral count)
    requireDecode
        (canonicalMagnitude magnitude)
        CoreInvalidInteger
        "integer magnitude"
        "integer magnitude is not canonical"
    requireDecode
        (not negative || not (null magnitude))
        CoreInvalidInteger
        "integer sign"
        "zero cannot have a negative sign"
    let value = foldl (\result octet -> result * 256 + fromIntegral octet) 0 magnitude
    pure (if negative then negate value else value)
    where
        canonicalMagnitude [] = True
        canonicalMagnitude (first : _) = first /= 0

decodeAscii :: String -> Decoder String
decodeAscii context = do
    limits <- currentLimits
    count <- readWord32 (context ++ " length")
    requireDecode
        (toInteger count <= toInteger (maximumCoreNumericBytes limits))
        CoreLimitExceeded
        context
        "numeric spelling exceeds configured limit"
    bytes <- takeBytes context (fromIntegral count)
    requireDecode (all (<= 0x7f) bytes) CoreInvalidInteger context "numeric spelling must contain ASCII characters only"
    pure (map (chr . fromIntegral) bytes)

decodeBool :: String -> Decoder Bool
decodeBool context =
    readWord8 context >>= \value -> case value of
        0 -> pure False
        1 -> pure True
        _ -> failDecode CoreInvalidBoolean context "invalid boolean byte"

decodePrimitive :: Word8 -> Decoder CorePrimitive
decodePrimitive tag = case drop (fromIntegral tag) primitives of
    primitive : _ -> pure primitive
    [] -> invalidTag "primitive tag" tag
    where
        primitives =
            [ CoreAdd
            , CoreSubtract
            , CoreMultiply
            , CoreDivide
            , CoreFloorDivide
            , CoreRemainder
            , CoreLessThan
            , CoreLessEqual
            , CoreGreaterThan
            , CoreGreaterEqual
            , CoreEqual
            , CoreNotEqual
            , CoreLogicalAnd
            , CoreLogicalOr
            , CoreNegate
            , CoreLogicalNot
            , CorePower
            , CoreShiftLeft
            , CoreShiftRight
            , CoreBitwiseAnd
            , CoreBitwiseXor
            , CoreBitwiseOr
            , CoreBitwiseNot
            , CoreTypeIs
            , CoreMemoize
            , CoreRuntimeCall
            ]

primitiveTag :: CorePrimitive -> Word8
primitiveTag primitive = fromIntegral (index primitive primitives)
    where
        primitives =
            [ CoreAdd
            , CoreSubtract
            , CoreMultiply
            , CoreDivide
            , CoreFloorDivide
            , CoreRemainder
            , CoreLessThan
            , CoreLessEqual
            , CoreGreaterThan
            , CoreGreaterEqual
            , CoreEqual
            , CoreNotEqual
            , CoreLogicalAnd
            , CoreLogicalOr
            , CoreNegate
            , CoreLogicalNot
            , CorePower
            , CoreShiftLeft
            , CoreShiftRight
            , CoreBitwiseAnd
            , CoreBitwiseXor
            , CoreBitwiseOr
            , CoreBitwiseNot
            , CoreTypeIs
            , CoreMemoize
            , CoreRuntimeCall
            ]
        index :: CorePrimitive -> [CorePrimitive] -> Int
        index value (candidate : remaining) = if value == candidate then 0 else 1 + index value remaining
        index _ [] = error "CorePrimitive enumeration is incomplete"

currentLimits :: Decoder CoreWireLimits
currentLimits = Decoder $ \state@(DecoderState _ _ limits) -> Right (limits, state)

requireDecode :: Bool -> CoreWireErrorKind -> String -> String -> Decoder ()
requireDecode condition kind context message = if condition then pure () else failDecode kind context message

invalidTag :: String -> Word8 -> Decoder a
invalidTag context tag = failDecode CoreInvalidTag context ("unknown tag " ++ show tag)

failDecode :: CoreWireErrorKind -> String -> String -> Decoder a
failDecode kind context message = Decoder $ \(DecoderState _ offset _) -> Left (CoreWireError kind offset context message)

takeBytes :: String -> Int -> Decoder [Word8]
takeBytes context count = Decoder $ \(DecoderState bytes offset limits) ->
    let (prefix, suffix) = splitAt count bytes
     in if length prefix == count
            then Right (prefix, DecoderState suffix (offset + count) limits)
            else Left (CoreWireError CoreTruncatedInput offset context "input ended before field was complete")

readWord8 :: String -> Decoder Word8
readWord8 context = do
    bytes <- takeBytes context 1
    case bytes of
        [value] -> pure value
        _ -> failDecode CoreTruncatedInput context "byte reader returned no value"
readWord16 :: String -> Decoder Word16
readWord16 context = assemble <$> takeBytes context 2
readWord32 :: String -> Decoder Word32
readWord32 context = assemble <$> takeBytes context 4
readWord64 :: String -> Decoder Word64
readWord64 context = assemble <$> takeBytes context 8

magic :: [Word8]
magic = map (fromIntegral . fromEnum) "TACR"

failure :: CoreWireErrorKind -> String -> String -> Either CoreWireError a
failure kind context message = Left (CoreWireError kind 0 context message)

encodeBool :: Bool -> [Word8]
encodeBool False = [0]
encodeBool True = [1]
word16 :: Word16 -> [Word8]
word16 value = [byte value 0, byte value 8]
word32 :: Word32 -> [Word8]
word32 value = [byte value 0, byte value 8, byte value 16, byte value 24]
word64 :: Word64 -> [Word8]
word64 value =
    [byte value 0, byte value 8, byte value 16, byte value 24, byte value 32, byte value 40, byte value 48, byte value 56]
byte :: (Integral a, Bits a) => a -> Int -> Word8
byte value amount = fromIntegral ((value `shiftR` amount) .&. 0xff)
assemble :: (Integral a, Bits a) => [Word8] -> a
assemble bytes = foldr (\(position, value) result -> result .|. (fromIntegral value `shiftL` (position * 8))) 0 (zip [0 ..] bytes)
