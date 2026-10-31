-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module DiagnosticProtocolTests (diagnosticProtocolTests) where

import Data.ByteString qualified as ByteString
import Data.Word (Word8)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Diagnostic.Protocol

diagnosticProtocolTests :: [(String, Bool)]
diagnosticProtocolTests =
    [ ("diagnostic wire has a stable empty-document header", emptyGolden)
    , ("diagnostic wire round-trips a compiler diagnostic", simpleRoundTrip)
    , ("diagnostic conversion changes source positions to zero-based coordinates", convertsCoordinates)
    , ("diagnostic wire round-trips every stage", everyStageRoundTrips)
    , ("diagnostic wire round-trips both frontend severities", everySeverityRoundTrips)
    , ("diagnostic wire preserves supplementary Unicode scalars", unicodeRoundTrip)
    , ("diagnostic wire preserves arguments, related locations, and fixes", richRoundTrip)
    , ("diagnostic wire rejects bad magic", rejectsMagic)
    , ("diagnostic wire rejects unsupported versions", rejectsVersion)
    , ("diagnostic wire rejects reserved flags", rejectsFlags)
    , ("diagnostic wire rejects trailing bytes", rejectsTrailingBytes)
    , ("diagnostic wire rejects every truncated prefix", rejectsTruncation)
    , ("diagnostic wire rejects unknown stage tags", rejectsUnknownStage)
    , ("diagnostic wire rejects unknown severity tags", rejectsUnknownSeverity)
    , ("diagnostic wire rejects invalid Boolean tags", rejectsInvalidBoolean)
    , ("diagnostic wire rejects malformed codes", rejectsMalformedCode)
    , ("diagnostic wire rejects duplicate argument names", rejectsDuplicateArguments)
    , ("diagnostic wire rejects reversed source ranges", rejectsReversedRange)
    , ("diagnostic wire rejects empty fixes", rejectsEmptyFix)
    , ("diagnostic wire enforces record limits before encoding", encodeRecordLimit)
    , ("diagnostic wire enforces record limits before decoding", decodeRecordLimit)
    , ("diagnostic wire enforces text scalar limits", textLimit)
    , ("diagnostic wire enforces total byte limits", byteLimit)
    , ("diagnostic conversion rejects non-positive source coordinates", rejectsInvalidCoordinate)
    ]

emptyGolden :: Bool
emptyGolden =
    encode emptyDocument
        == Right (ByteString.pack [0x54, 0x41, 0x44, 0x47, 1, 0, 0, 0, 0, 0, 0, 0])

simpleRoundTrip :: Bool
simpleRoundTrip = case diagnosticDocument [sampleDiagnostic] of
    Left _ -> False
    Right document -> decodeEncoded document == Right document

convertsCoordinates :: Bool
convertsCoordinates = case diagnosticDocument [sampleDiagnostic] of
    Right (DiagnosticDocument [record]) ->
        recordPrimary record
            == Just (DiagnosticLocation "Main.tala" 7 12 7 18)
    _ -> False

everyStageRoundTrips :: Bool
everyStageRoundTrips =
    all
        (\stage -> roundTrips (simpleRecord {recordStage = stage}))
        [minBound .. maxBound]

everySeverityRoundTrips :: Bool
everySeverityRoundTrips =
    all
        (\severity -> roundTrips (simpleRecord {recordSeverity = severity}))
        [minBound .. maxBound]

unicodeRoundTrip :: Bool
unicodeRoundTrip =
    roundTrips
        (simpleRecord {recordMessage = "Unicode scalar: \x1f9ea; path: C:/\x03b4/Main.tala"})

richRoundTrip :: Bool
richRoundTrip = roundTrips richRecord

rejectsMagic :: Bool
rejectsMagic = rejected (replace 0 0x42 emptyBytes)

rejectsVersion :: Bool
rejectsVersion = rejected (replace 4 2 emptyBytes)

rejectsFlags :: Bool
rejectsFlags = rejected (replace 6 1 emptyBytes)

rejectsTrailingBytes :: Bool
rejectsTrailingBytes = rejected (ByteString.snoc emptyBytes 0)

rejectsTruncation :: Bool
rejectsTruncation = case encode (DiagnosticDocument [richRecord]) of
    Left _ -> False
    Right bytes ->
        all (rejected . (`ByteString.take` bytes)) [0 .. ByteString.length bytes - 1]
            && decode bytes == Right (DiagnosticDocument [richRecord])

rejectsUnknownStage :: Bool
rejectsUnknownStage = rejected (replace 12 0xff simpleBytes)

rejectsUnknownSeverity :: Bool
rejectsUnknownSeverity = rejected (replace 13 0xff simpleBytes)

rejectsInvalidBoolean :: Bool
rejectsInvalidBoolean = case primaryPresenceOffset of
    Nothing -> False
    Just offset -> rejected (replace offset 2 simpleBytes)

rejectsMalformedCode :: Bool
rejectsMalformedCode =
    left (encode (DiagnosticDocument [simpleRecord {recordCode = "lowercase"}]))
        && left (encode (DiagnosticDocument [simpleRecord {recordCode = ""}]))

rejectsDuplicateArguments :: Bool
rejectsDuplicateArguments =
    left
        ( encode
            ( DiagnosticDocument
                [ simpleRecord
                    { recordArguments =
                        [DiagnosticArgument "name" "first", DiagnosticArgument "name" "second"]
                    }
                ]
            )
        )

rejectsReversedRange :: Bool
rejectsReversedRange =
    left
        ( encode
            ( DiagnosticDocument
                [ simpleRecord
                    { recordPrimary = Just (DiagnosticLocation "Main.tala" 4 1 3 9)
                    }
                ]
            )
        )

rejectsEmptyFix :: Bool
rejectsEmptyFix =
    left
        ( encode
            ( DiagnosticDocument
                [simpleRecord {recordFixes = [DiagnosticFix "Apply correction" []]}]
            )
        )

encodeRecordLimit :: Bool
encodeRecordLimit =
    let limits = defaultDiagnosticProtocolLimits {maximumRecords = 0}
     in left (encodeDiagnosticDocument limits (DiagnosticDocument [simpleRecord]))

decodeRecordLimit :: Bool
decodeRecordLimit =
    let limits = defaultDiagnosticProtocolLimits {maximumRecords = 0}
     in left (decodeDiagnosticDocument limits simpleBytes)

textLimit :: Bool
textLimit =
    let limits = defaultDiagnosticProtocolLimits {maximumTextScalars = 2}
     in left (encodeDiagnosticDocument limits (DiagnosticDocument [simpleRecord]))

byteLimit :: Bool
byteLimit =
    let limits = defaultDiagnosticProtocolLimits {maximumWireBytes = 11}
     in left (decodeDiagnosticDocument limits emptyBytes)
            && left (encodeDiagnosticDocument limits emptyDocument)

rejectsInvalidCoordinate :: Bool
rejectsInvalidCoordinate =
    left
        ( diagnosticDocument
            [ sampleDiagnostic
                { diagnosticSpan =
                    Just (SourceSpan "Main.tala" (SourcePosition 0 1) (SourcePosition 1 1))
                }
            ]
        )

sampleDiagnostic :: Diagnostic
sampleDiagnostic =
    Diagnostic
        TypeCheckerStage
        Error
        "TAT204"
        (Just (SourceSpan "Main.tala" (SourcePosition 8 13) (SourcePosition 8 19)))
        "argument cannot be converted"

simpleRecord :: DiagnosticRecord
simpleRecord =
    DiagnosticRecord
        { recordStage = ParserStage
        , recordSeverity = ProtocolError
        , recordCode = "TAP100"
        , recordMessage = "expected declaration"
        , recordArguments = []
        , recordPrimary = Nothing
        , recordRelated = []
        , recordFixes = []
        }

richRecord :: DiagnosticRecord
richRecord =
    DiagnosticRecord
        { recordStage = TypeCheckerStage
        , recordSeverity = ProtocolWarning
        , recordCode = "TAT204"
        , recordMessage = "argument {actual} cannot be converted to {expected}"
        , recordArguments =
            [ DiagnosticArgument "actual" "String"
            , DiagnosticArgument "expected" "int"
            ]
        , recordPrimary = Just mainLocation
        , recordRelated =
            [ DiagnosticRelatedLocation
                (DiagnosticLocation "Library.tala" 2 4 2 12)
                "parameter is declared here"
            ]
        , recordFixes =
            [ DiagnosticFix
                "Convert the argument"
                [DiagnosticTextEdit mainLocation "value.ToInt()"]
            ]
        }

mainLocation :: DiagnosticLocation
mainLocation = DiagnosticLocation "Main.tala" 7 12 7 18

emptyDocument :: DiagnosticDocument
emptyDocument = DiagnosticDocument []

emptyBytes :: ByteString.ByteString
emptyBytes = either (const ByteString.empty) id (encode emptyDocument)

simpleBytes :: ByteString.ByteString
simpleBytes = either (const ByteString.empty) id (encode (DiagnosticDocument [simpleRecord]))

-- The primary-presence byte follows the fixed header, tags, two counted scalar
-- strings, and the zero argument count. Computing it keeps this test readable
-- while still pinning the exact wire layout.
primaryPresenceOffset :: Maybe Int
primaryPresenceOffset =
    let scalarBytes value = 4 + 4 * length value
        offset = 12 + 2 + scalarBytes (recordCode simpleRecord) + scalarBytes (recordMessage simpleRecord) + 4
     in if offset < ByteString.length simpleBytes then Just offset else Nothing

encode :: DiagnosticDocument -> Either DiagnosticProtocolError ByteString.ByteString
encode = encodeDiagnosticDocument defaultDiagnosticProtocolLimits

decode :: ByteString.ByteString -> Either DiagnosticProtocolError DiagnosticDocument
decode = decodeDiagnosticDocument defaultDiagnosticProtocolLimits

decodeEncoded :: DiagnosticDocument -> Either DiagnosticProtocolError DiagnosticDocument
decodeEncoded document = encode document >>= decode

roundTrips :: DiagnosticRecord -> Bool
roundTrips record = decodeEncoded (DiagnosticDocument [record]) == Right (DiagnosticDocument [record])

rejected :: ByteString.ByteString -> Bool
rejected = left . decode

left :: Either leftValue rightValue -> Bool
left value = case value of
    Left _ -> True
    Right _ -> False

replace :: Int -> Word8 -> ByteString.ByteString -> ByteString.ByteString
replace index value bytes =
    ByteString.take index bytes
        <> ByteString.singleton value
        <> ByteString.drop (index + 1) bytes
