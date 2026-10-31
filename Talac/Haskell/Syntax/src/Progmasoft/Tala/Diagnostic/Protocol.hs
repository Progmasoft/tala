-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Versioned, bounded binary representation of compiler diagnostics.

The wire model is separate from the frontend's current Error/Warning model
so native stages can also report informational messages and editor hints.
-}
module Progmasoft.Tala.Diagnostic.Protocol
    ( DiagnosticDocument (..)
    , DiagnosticRecord (..)
    , ProtocolSeverity (..)
    , DiagnosticArgument (..)
    , DiagnosticLocation (..)
    , DiagnosticRelatedLocation (..)
    , DiagnosticFix (..)
    , DiagnosticTextEdit (..)
    , DiagnosticProtocolLimits (..)
    , DiagnosticProtocolError (..)
    , defaultDiagnosticProtocolLimits
    , diagnosticDocument
    , encodeDiagnosticDocument
    , decodeDiagnosticDocument
    ) where

import Control.Monad (replicateM, unless, when)
import Data.Bits (shiftL, (.|.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiUpper, isDigit, ord)
import Data.List (nub)
import Data.Word (Word16, Word32, Word8)
import Progmasoft.Tala.AST (SourcePosition (..), SourceSpan (..))
import Progmasoft.Tala.Diagnostic

protocolVersion :: Word16
protocolVersion = 1

magic :: [Word8]
magic = map (fromIntegral . ord) "TADG"

-- | Named text value used to format a diagnostic message.
data DiagnosticArgument = DiagnosticArgument
    { argumentName :: String
    , argumentValue :: String
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Wire-level severity shared with native compiler and editor clients.
data ProtocolSeverity
    = ProtocolError
    | ProtocolWarning
    | ProtocolInformation
    | ProtocolHint
    deriving stock (Bounded, Enum, Eq, Ord, Read, Show)

{- | Source path and zero-based scalar coordinates for one diagnostic span.

Columns count Unicode scalar values; clients must not reinterpret them as
byte offsets or UTF-16 code-unit positions.
-}
data DiagnosticLocation = DiagnosticLocation
    { locationSource :: FilePath
    , locationStartLine :: Word32
    , locationStartColumn :: Word32
    , locationEndLine :: Word32
    , locationEndColumn :: Word32
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Secondary location that explains a diagnostic's context.
data DiagnosticRelatedLocation = DiagnosticRelatedLocation
    { relatedLocation :: DiagnosticLocation
    , relatedMessage :: String
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Replacement text for one source range in a code action.
data DiagnosticTextEdit = DiagnosticTextEdit
    { editLocation :: DiagnosticLocation
    , editReplacement :: String
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Atomic editor action containing one or more source edits.
data DiagnosticFix = DiagnosticFix
    { fixTitle :: String
    , fixEdits :: [DiagnosticTextEdit]
    }
    deriving stock (Eq, Ord, Read, Show)

-- | One versioned diagnostic, including related spans and suggested fixes.
data DiagnosticRecord = DiagnosticRecord
    { recordStage :: DiagnosticStage
    , recordSeverity :: ProtocolSeverity
    , recordCode :: String
    , recordMessage :: String
    , recordArguments :: [DiagnosticArgument]
    , recordPrimary :: Maybe DiagnosticLocation
    , recordRelated :: [DiagnosticRelatedLocation]
    , recordFixes :: [DiagnosticFix]
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Ordered diagnostic records returned for a compiler operation.
newtype DiagnosticDocument = DiagnosticDocument
    { documentRecords :: [DiagnosticRecord]
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Resource bounds enforced when encoding and decoding untrusted documents.
data DiagnosticProtocolLimits = DiagnosticProtocolLimits
    { maximumWireBytes :: Int
    , maximumRecords :: Int
    , maximumTextScalars :: Int
    , maximumArguments :: Int
    , maximumRelatedLocations :: Int
    , maximumFixes :: Int
    , maximumEditsPerFix :: Int
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Conservative default allocation and complexity limits for the protocol.
defaultDiagnosticProtocolLimits :: DiagnosticProtocolLimits
defaultDiagnosticProtocolLimits =
    DiagnosticProtocolLimits
        { maximumWireBytes = 16 * 1024 * 1024
        , maximumRecords = 65535
        , maximumTextScalars = 1024 * 1024
        , maximumArguments = 256
        , maximumRelatedLocations = 256
        , maximumFixes = 128
        , maximumEditsPerFix = 4096
        }

-- | Error offset, field path, and explanation for a protocol failure.
data DiagnosticProtocolError = DiagnosticProtocolError
    { protocolErrorOffset :: Int
    , protocolErrorContext :: String
    , protocolErrorMessage :: String
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Convert compiler diagnostics to the richer wire-level document model.
diagnosticDocument :: [Diagnostic] -> Either DiagnosticProtocolError DiagnosticDocument
diagnosticDocument diagnostics = DiagnosticDocument <$> traverse convert diagnostics
    where
        convert value = do
            primary <- traverse sourceLocation (diagnosticSpan value)
            pure
                DiagnosticRecord
                    { recordStage = diagnosticStage value
                    , recordSeverity = protocolSeverity (diagnosticSeverity value)
                    , recordCode = diagnosticCode value
                    , recordMessage = diagnosticMessage value
                    , recordArguments = []
                    , recordPrimary = primary
                    , recordRelated = []
                    , recordFixes = []
                    }

sourceLocation :: SourceSpan -> Either DiagnosticProtocolError DiagnosticLocation
sourceLocation spanValue = do
    startLine <- sourceCoordinate "source start line" (sourceLine (sourceStart spanValue))
    startColumn <- sourceCoordinate "source start column" (sourceColumn (sourceStart spanValue))
    endLine <- sourceCoordinate "source end line" (sourceLine (sourceEnd spanValue))
    endColumn <- sourceCoordinate "source end column" (sourceColumn (sourceEnd spanValue))
    pure
        DiagnosticLocation
            { locationSource = sourceFile spanValue
            , locationStartLine = startLine
            , locationStartColumn = startColumn
            , locationEndLine = endLine
            , locationEndColumn = endColumn
            }
    where
        sourceCoordinate context value
            | value <= 0 = Left (modelError context "compiler source positions must be one-based")
            | toInteger value - 1 > toInteger (maxBound :: Word32) =
                Left (modelError context "compiler source position exceeds the protocol range")
            | otherwise = Right (fromIntegral (value - 1))

-- | Validate and encode a diagnostic document using the supplied limits.
encodeDiagnosticDocument ::
    DiagnosticProtocolLimits ->
    DiagnosticDocument ->
    Either DiagnosticProtocolError ByteString.ByteString
encodeDiagnosticDocument limits document = do
    validateDocument limits document
    encodedRecords <- traverse (encodeRecord limits) (documentRecords document)
    let payload =
            mconcat (map Builder.word8 magic)
                <> Builder.word16LE protocolVersion
                <> Builder.word16LE 0
                <> countBuilder (length (documentRecords document))
                <> mconcat encodedRecords
        bytes = LazyByteString.toStrict (Builder.toLazyByteString payload)
    if ByteString.length bytes > maximumWireBytes limits
        then Left (limitError "wire byte length" "diagnostic document exceeds configured byte limit")
        else Right bytes

encodeRecord :: DiagnosticProtocolLimits -> DiagnosticRecord -> Either DiagnosticProtocolError Builder.Builder
encodeRecord limits record = do
    arguments <- traverse encodeArgument (recordArguments record)
    primary <- traverse encodeLocation (recordPrimary record)
    related <- traverse encodeRelated (recordRelated record)
    fixes <- traverse (encodeFix limits) (recordFixes record)
    pure
        ( Builder.word8 (stageTag (recordStage record))
            <> Builder.word8 (severityTag (recordSeverity record))
            <> textBuilder (recordCode record)
            <> textBuilder (recordMessage record)
            <> countBuilder (length arguments)
            <> mconcat arguments
            <> Builder.word8 (maybe 0 (const 1) primary)
            <> maybe mempty id primary
            <> countBuilder (length related)
            <> mconcat related
            <> countBuilder (length fixes)
            <> mconcat fixes
        )

encodeArgument :: DiagnosticArgument -> Either DiagnosticProtocolError Builder.Builder
encodeArgument argument =
    pure (textBuilder (argumentName argument) <> textBuilder (argumentValue argument))

encodeLocation :: DiagnosticLocation -> Either DiagnosticProtocolError Builder.Builder
encodeLocation location =
    pure
        ( textBuilder (locationSource location)
            <> Builder.word32LE (locationStartLine location)
            <> Builder.word32LE (locationStartColumn location)
            <> Builder.word32LE (locationEndLine location)
            <> Builder.word32LE (locationEndColumn location)
        )

encodeRelated :: DiagnosticRelatedLocation -> Either DiagnosticProtocolError Builder.Builder
encodeRelated related = do
    location <- encodeLocation (relatedLocation related)
    pure (location <> textBuilder (relatedMessage related))

encodeFix :: DiagnosticProtocolLimits -> DiagnosticFix -> Either DiagnosticProtocolError Builder.Builder
encodeFix _ fix = do
    edits <- traverse encodeEdit (fixEdits fix)
    pure (textBuilder (fixTitle fix) <> countBuilder (length edits) <> mconcat edits)

encodeEdit :: DiagnosticTextEdit -> Either DiagnosticProtocolError Builder.Builder
encodeEdit edit = do
    location <- encodeLocation (editLocation edit)
    pure (location <> textBuilder (editReplacement edit))

textBuilder :: String -> Builder.Builder
textBuilder value =
    countBuilder (length value)
        <> mconcat [Builder.word32LE (fromIntegral (ord character)) | character <- value]

countBuilder :: Int -> Builder.Builder
countBuilder = Builder.word32LE . fromIntegral

stageTag :: DiagnosticStage -> Word8
stageTag = fromIntegral . fromEnum

severityTag :: ProtocolSeverity -> Word8
severityTag = fromIntegral . fromEnum

protocolSeverity :: DiagnosticSeverity -> ProtocolSeverity
protocolSeverity severity = case severity of
    Error -> ProtocolError
    Warning -> ProtocolWarning

validateDocument :: DiagnosticProtocolLimits -> DiagnosticDocument -> Either DiagnosticProtocolError ()
validateDocument limits document = do
    validateCount limits "diagnostic count" (maximumRecords limits) (length (documentRecords document))
    mapM_ (validateRecord limits) (documentRecords document)

validateRecord :: DiagnosticProtocolLimits -> DiagnosticRecord -> Either DiagnosticProtocolError ()
validateRecord limits record = do
    unless
        (validCode (recordCode record))
        (Left (modelError "diagnostic code" "diagnostic code must be 1-64 ASCII uppercase, digit, or hyphen scalars"))
    when
        (null (recordMessage record))
        (Left (modelError "diagnostic message" "diagnostic message is empty"))
    validateText limits "diagnostic code" (recordCode record)
    validateText limits "diagnostic message" (recordMessage record)
    validateCount limits "diagnostic argument count" (maximumArguments limits) (length (recordArguments record))
    let names = map argumentName (recordArguments record)
    when
        (any null names)
        (Left (modelError "diagnostic argument name" "diagnostic argument name is empty"))
    when
        (length names /= length (nub names))
        (Left (modelError "diagnostic argument name" "diagnostic argument names must be unique within one record"))
    mapM_ validateArgument (recordArguments record)
    mapM_ (validateLocation limits "primary location") (recordPrimary record)
    validateCount limits "related location count" (maximumRelatedLocations limits) (length (recordRelated record))
    mapM_ validateRelated (recordRelated record)
    validateCount limits "diagnostic fix count" (maximumFixes limits) (length (recordFixes record))
    mapM_ validateFix (recordFixes record)
    where
        validateArgument argument = do
            validateText limits "diagnostic argument name" (argumentName argument)
            validateText limits "diagnostic argument value" (argumentValue argument)
        validateRelated related = do
            validateLocation limits "related location" (relatedLocation related)
            when
                (null (relatedMessage related))
                (Left (modelError "related location message" "related location message is empty"))
            validateText limits "related location message" (relatedMessage related)
        validateFix fix = do
            when
                (null (fixTitle fix))
                (Left (modelError "diagnostic fix title" "diagnostic fix title is empty"))
            when
                (null (fixEdits fix))
                (Left (modelError "diagnostic fix edits" "diagnostic fix must contain at least one edit"))
            validateText limits "diagnostic fix title" (fixTitle fix)
            validateCount limits "diagnostic edit count" (maximumEditsPerFix limits) (length (fixEdits fix))
            mapM_ validateEdit (fixEdits fix)
        validateEdit edit = do
            validateLocation limits "diagnostic edit" (editLocation edit)
            validateText limits "diagnostic edit replacement" (editReplacement edit)

validateLocation :: DiagnosticProtocolLimits -> String -> DiagnosticLocation -> Either DiagnosticProtocolError ()
validateLocation limits context location = do
    when
        (null (locationSource location))
        (Left (modelError context "diagnostic source identity is empty"))
    validateText limits "diagnostic source" (locationSource location)
    unless
        ( positionPrecedes
            (locationStartLine location, locationStartColumn location)
            (locationEndLine location, locationEndColumn location)
        )
        (Left (modelError context "diagnostic range end precedes its start"))

positionPrecedes :: (Word32, Word32) -> (Word32, Word32) -> Bool
positionPrecedes (leftLine, leftColumn) (rightLine, rightColumn) =
    leftLine < rightLine || (leftLine == rightLine && leftColumn <= rightColumn)

validateText :: DiagnosticProtocolLimits -> String -> String -> Either DiagnosticProtocolError ()
validateText limits context value = do
    validateCount limits context (maximumTextScalars limits) (length value)
    unless
        (all isUnicodeScalar value)
        (Left (modelError context "text contains a non-scalar Unicode value"))

validateCount :: DiagnosticProtocolLimits -> String -> Int -> Int -> Either DiagnosticProtocolError ()
validateCount _ context maximumCount value
    | value < 0 || value > maximumCount || toInteger value > toInteger (maxBound :: Word32) =
        Left (limitError context "collection count exceeds configured limit")
    | otherwise = Right ()

validCode :: String -> Bool
validCode code =
    not (null code)
        && length code <= 64
        && all (\character -> isAsciiUpper character || isDigit character || character == '-') code

isUnicodeScalar :: Char -> Bool
isUnicodeScalar character =
    let value = ord character
     in value <= 0x10ffff && not (value >= 0xd800 && value <= 0xdfff)

modelError :: String -> String -> DiagnosticProtocolError
modelError = DiagnosticProtocolError 0

limitError :: String -> String -> DiagnosticProtocolError
limitError = DiagnosticProtocolError 0

data DecodeState = DecodeState
    { decodeBytes :: ByteString.ByteString
    , decodeOffset :: Int
    , decodeLimits :: DiagnosticProtocolLimits
    }

newtype Decoder value = Decoder
    { runDecoder :: DecodeState -> Either DiagnosticProtocolError (value, DecodeState)
    }

instance Functor Decoder where
    fmap transform parser = Decoder $ \state -> do
        (value, next) <- runDecoder parser state
        pure (transform value, next)

instance Applicative Decoder where
    pure value = Decoder (Right . (value,))
    function <*> argument = Decoder $ \state -> do
        (transform, afterFunction) <- runDecoder function state
        (value, afterArgument) <- runDecoder argument afterFunction
        pure (transform value, afterArgument)

instance Monad Decoder where
    parser >>= continuation = Decoder $ \state -> do
        (value, next) <- runDecoder parser state
        runDecoder (continuation value) next

-- | Decode one complete document, rejecting unsupported versions and trailing bytes.
decodeDiagnosticDocument ::
    DiagnosticProtocolLimits ->
    ByteString.ByteString ->
    Either DiagnosticProtocolError DiagnosticDocument
decodeDiagnosticDocument limits bytes
    | ByteString.length bytes > maximumWireBytes limits =
        Left (limitError "wire byte length" "diagnostic document exceeds configured byte limit")
    | otherwise = do
        (document, state) <- runDecoder decodeDocument (DecodeState bytes 0 limits)
        unless
            (decodeOffset state == ByteString.length bytes)
            (Left (DiagnosticProtocolError (decodeOffset state) "document" "bytes remain after diagnostic document"))
        validateDocument limits document
        pure document

decodeDocument :: Decoder DiagnosticDocument
decodeDocument = do
    observedMagic <- replicateM 4 (byte "magic")
    unlessDecoder (observedMagic == magic) "magic" "input is not a Tala diagnostic document"
    version <- word16 "version"
    unlessDecoder (version == protocolVersion) "version" "unsupported diagnostic protocol version"
    flags <- word16 "flags"
    unlessDecoder (flags == 0) "flags" "reserved diagnostic flags must be zero"
    count <- boundedCount "diagnostic count" maximumRecords
    DiagnosticDocument <$> replicateM count decodeRecord

decodeRecord :: Decoder DiagnosticRecord
decodeRecord = do
    stage <- decodeStage
    severity <- decodeSeverity
    code <- text "diagnostic code"
    message <- text "diagnostic message"
    argumentCount <- boundedCount "diagnostic argument count" maximumArguments
    arguments <-
        replicateM argumentCount (DiagnosticArgument <$> text "diagnostic argument name" <*> text "diagnostic argument value")
    hasPrimary <- boolean "primary location presence"
    primary <- if hasPrimary then Just <$> decodeLocation else pure Nothing
    relatedCount <- boundedCount "related location count" maximumRelatedLocations
    related <- replicateM relatedCount (DiagnosticRelatedLocation <$> decodeLocation <*> text "related location message")
    fixCount <- boundedCount "diagnostic fix count" maximumFixes
    fixes <- replicateM fixCount decodeFix
    pure (DiagnosticRecord stage severity code message arguments primary related fixes)

decodeLocation :: Decoder DiagnosticLocation
decodeLocation =
    DiagnosticLocation
        <$> text "diagnostic source"
        <*> word32 "diagnostic start line"
        <*> word32 "diagnostic start column"
        <*> word32 "diagnostic end line"
        <*> word32 "diagnostic end column"

decodeFix :: Decoder DiagnosticFix
decodeFix = do
    title <- text "diagnostic fix title"
    editCount <- boundedCount "diagnostic edit count" maximumEditsPerFix
    edits <- replicateM editCount (DiagnosticTextEdit <$> decodeLocation <*> text "diagnostic edit replacement")
    pure (DiagnosticFix title edits)

decodeStage :: Decoder DiagnosticStage
decodeStage = do
    tag <- byte "diagnostic stage"
    if fromIntegral tag <= fromEnum (maxBound :: DiagnosticStage)
        then pure (toEnum (fromIntegral tag))
        else failDecoder "diagnostic stage" "unknown diagnostic stage tag"

decodeSeverity :: Decoder ProtocolSeverity
decodeSeverity = do
    tag <- byte "diagnostic severity"
    if fromIntegral tag <= fromEnum (maxBound :: ProtocolSeverity)
        then pure (toEnum (fromIntegral tag))
        else failDecoder "diagnostic severity" "unknown diagnostic severity tag"

text :: String -> Decoder String
text context = do
    count <- boundedCount context maximumTextScalars
    values <- replicateM count (word32 context)
    if all validScalar values
        then pure (map (toEnum . fromIntegral) values)
        else failDecoder context "text contains a non-scalar Unicode value"
    where
        validScalar value = value <= 0x10ffff && not (value >= 0xd800 && value <= 0xdfff)

boundedCount :: String -> (DiagnosticProtocolLimits -> Int) -> Decoder Int
boundedCount context selector = do
    value <- word32 context
    limits <- Decoder (\state -> Right (decodeLimits state, state))
    if toInteger value <= toInteger (selector limits)
        then pure (fromIntegral value)
        else failDecoder context "collection count exceeds configured limit"

boolean :: String -> Decoder Bool
boolean context = do
    value <- byte context
    case value of
        0 -> pure False
        1 -> pure True
        _ -> failDecoder context "boolean byte must be zero or one"

byte :: String -> Decoder Word8
byte context = Decoder $ \state ->
    if decodeOffset state >= ByteString.length (decodeBytes state)
        then Left (DiagnosticProtocolError (decodeOffset state) context "input ended before field was complete")
        else
            Right
                ( ByteString.index (decodeBytes state) (decodeOffset state)
                , state {decodeOffset = decodeOffset state + 1}
                )

word16 :: String -> Decoder Word16
word16 context = do
    low <- byte context
    high <- byte context
    pure (fromIntegral low .|. (fromIntegral high `shiftL` 8))

word32 :: String -> Decoder Word32
word32 context = do
    a <- byte context
    b <- byte context
    c <- byte context
    d <- byte context
    pure
        ( fromIntegral a
            .|. (fromIntegral b `shiftL` 8)
            .|. (fromIntegral c `shiftL` 16)
            .|. (fromIntegral d `shiftL` 24)
        )

unlessDecoder :: Bool -> String -> String -> Decoder ()
unlessDecoder condition context message =
    if condition then pure () else failDecoder context message

failDecoder :: String -> String -> Decoder value
failDecoder context message = Decoder $ \state ->
    Left (DiagnosticProtocolError (decodeOffset state) context message)
