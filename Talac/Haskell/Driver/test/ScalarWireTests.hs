-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module ScalarWireTests (scalarWireTests) where

import Data.Word (Word8)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.CorePrep.Wire
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic

scalarWireTests :: [(String, Bool)]
scalarWireTests =
    versionTests
        ++ coreRoundTripTests
        ++ corePrepRoundTripTests
        ++ coreVerifierTests
        ++ corePrepVerifierTests
        ++ malformedWireTests

versionTests :: [(String, Bool)]
versionTests =
    [ ("Core wire current version is 10", currentCoreWireVersion == CoreWireVersion 10)
    , ("CorePrep wire current version is 8", currentWireVersion == WireVersion 8)
    , ("Core numeric payload default is bounded", maximumCoreNumericBytes defaultCoreWireLimits == 4096)
    , ("CorePrep numeric payload default is bounded", maximumNumericBytes defaultWireLimits == 4096)
    ]

scalarTypes :: [(String, Type)]
scalarTypes =
    [ ("char", named "char")
    , ("byte", named "byte")
    , ("short", named "short")
    , ("long", named "long")
    , ("int", intType)
    , ("longint", named "longint")
    , ("ubyte", named "ubyte")
    , ("ushort", named "ushort")
    , ("ulong", named "ulong")
    , ("uint", named "uint")
    , ("ulongint", named "ulongint")
    , ("sfloat", named "sfloat")
    , ("lfloat", named "lfloat")
    , ("float", named "float")
    , ("double", named "double")
    ]

integerTypes :: [(String, Type, Integer, Integer)]
integerTypes =
    [ ("char", named "char", 0, 2 ^ (32 :: Int) - 1)
    , ("byte", named "byte", negate (2 ^ (7 :: Int)), 2 ^ (7 :: Int) - 1)
    , ("short", named "short", negate (2 ^ (15 :: Int)), 2 ^ (15 :: Int) - 1)
    , ("long", named "long", negate (2 ^ (31 :: Int)), 2 ^ (31 :: Int) - 1)
    , ("int", intType, negate (2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)
    , ("longint", named "longint", negate (2 ^ (127 :: Int)), 2 ^ (127 :: Int) - 1)
    , ("ubyte", named "ubyte", 0, 2 ^ (8 :: Int) - 1)
    , ("ushort", named "ushort", 0, 2 ^ (16 :: Int) - 1)
    , ("ulong", named "ulong", 0, 2 ^ (32 :: Int) - 1)
    , ("uint", named "uint", 0, 2 ^ (64 :: Int) - 1)
    , ("ulongint", named "ulongint", 0, 2 ^ (128 :: Int) - 1)
    ]

floatingTypes :: [(String, Type)]
floatingTypes =
    [ ("sfloat", named "sfloat")
    , ("lfloat", named "lfloat")
    , ("float", named "float")
    , ("double", named "double")
    ]

named :: String -> Type
named spelling = NamedType (QualifiedName [Identifier spelling]) []

resolved :: Int -> String -> ResolvedName
resolved identifier spelling = ResolvedName (SymbolId identifier) (Identifier spelling)

literalFor :: Type -> CoreLiteral
literalFor valueType
    | valueType == unitType = CoreUnit
    | valueType == boolType = CoreBoolean True
    | valueType == stringType = CoreString "Tala λ 😀"
    | valueType `elem` map snd floatingTypes = CoreFloating "-12345.625e-2"
    | otherwise = CoreInteger 42

coreModuleFor :: Type -> CoreLiteral -> CoreModule
coreModuleFor valueType literal =
    CoreModule
        (QualifiedName [Identifier "Scalar", Identifier "Core"])
        [CoreFunction (resolved 1 "Value") [] valueType [CoreReturn (CoreLiteral literal valueType)]]

corePrepModuleFor :: Type -> CoreLiteral -> CorePrepModule
corePrepModuleFor valueType literal =
    CorePrepModule
        (QualifiedName [Identifier "Scalar", Identifier "CorePrep"])
        [ CorePrepFunction
            (resolved 1 "Value")
            ""
            []
            valueType
            1
            [CorePrepBlock 1 [] (CorePrepReturn (CorePrepLiteral literal valueType))]
        ]
        []

coreRoundTrip :: Type -> Bool
coreRoundTrip valueType =
    let source = coreModuleFor valueType (literalFor valueType)
     in (encodeCore defaultCoreWireLimits source >>= decodeCore defaultCoreWireLimits) == Right source

corePrepRoundTrip :: Type -> Bool
corePrepRoundTrip valueType =
    let source = corePrepModuleFor valueType (literalFor valueType)
     in (encodeCorePrep source >>= decodeCorePrep) == Right source

coreRoundTripTests :: [(String, Bool)]
coreRoundTripTests =
    [ ("Core wire round-trips unit", coreRoundTrip unitType)
    , ("Core wire round-trips bool", coreRoundTrip boolType)
    , ("Core wire round-trips String", coreRoundTrip stringType)
    ]
        ++ [("Core wire round-trips " ++ name, coreRoundTrip valueType) | (name, valueType) <- scalarTypes]
        ++ concatMap coreIntegerBoundaryRoundTrips integerTypes
        ++ [("Core wire preserves " ++ name ++ " spelling", coreFloatingRoundTrip valueType) | (name, valueType) <- floatingTypes]

corePrepRoundTripTests :: [(String, Bool)]
corePrepRoundTripTests =
    [ ("CorePrep wire round-trips unit", corePrepRoundTrip unitType)
    , ("CorePrep wire round-trips bool", corePrepRoundTrip boolType)
    , ("CorePrep wire round-trips String", corePrepRoundTrip stringType)
    ]
        ++ [("CorePrep wire round-trips " ++ name, corePrepRoundTrip valueType) | (name, valueType) <- scalarTypes]
        ++ concatMap corePrepIntegerBoundaryRoundTrips integerTypes
        ++ [ ("CorePrep wire preserves " ++ name ++ " spelling", corePrepFloatingRoundTrip valueType)
           | (name, valueType) <- floatingTypes
           ]

coreIntegerBoundaryRoundTrips :: (String, Type, Integer, Integer) -> [(String, Bool)]
coreIntegerBoundaryRoundTrips (name, valueType, minimumValue, maximumValue) =
    [ ("Core wire round-trips " ++ name ++ " minimum", roundTrip minimumValue)
    , ("Core wire round-trips " ++ name ++ " maximum", roundTrip maximumValue)
    ]
    where
        roundTrip value =
            let source = coreModuleFor valueType (CoreInteger value)
             in (encodeCore defaultCoreWireLimits source >>= decodeCore defaultCoreWireLimits) == Right source

corePrepIntegerBoundaryRoundTrips :: (String, Type, Integer, Integer) -> [(String, Bool)]
corePrepIntegerBoundaryRoundTrips (name, valueType, minimumValue, maximumValue) =
    [ ("CorePrep wire round-trips " ++ name ++ " minimum", roundTrip minimumValue)
    , ("CorePrep wire round-trips " ++ name ++ " maximum", roundTrip maximumValue)
    ]
    where
        roundTrip value =
            let source = corePrepModuleFor valueType (CoreInteger value)
             in (encodeCorePrep source >>= decodeCorePrep) == Right source

coreFloatingRoundTrip :: Type -> Bool
coreFloatingRoundTrip valueType =
    all
        ( \spelling ->
            let source = coreModuleFor valueType (CoreFloating spelling)
             in (encodeCore defaultCoreWireLimits source >>= decodeCore defaultCoreWireLimits) == Right source
        )
        ["0", "1.0", ".5", "5.", "-1.25", "6.022e23", "1e-9"]

corePrepFloatingRoundTrip :: Type -> Bool
corePrepFloatingRoundTrip valueType =
    all
        ( \spelling ->
            let source = corePrepModuleFor valueType (CoreFloating spelling)
             in (encodeCorePrep source >>= decodeCorePrep) == Right source
        )
        ["0", "1.0", ".5", "5.", "-1.25", "6.022e23", "1e-9"]

hasDiagnostic :: String -> Either [Diagnostic] value -> Bool
hasDiagnostic code result = case result of
    Left issues -> any ((== code) . diagnosticCode) issues
    Right _ -> False

coreVerifierTests :: [(String, Bool)]
coreVerifierTests =
    concatMap verifyIntegerBoundaries integerTypes
        ++ [ ("Core verifier accepts every floating scalar", all validFloating floatingTypes)
           , ("Core verifier rejects floating payload on int", invalidCoreLiteral intType (CoreFloating "1.0"))
           , ("Core verifier rejects integer payload on float", invalidCoreLiteral (named "float") (CoreInteger 1))
           , ("Core verifier rejects invalid floating exponent", invalidCoreLiteral (named "double") (CoreFloating "1e"))
           , ("Core verifier rejects String payload on bool", invalidCoreLiteral boolType (CoreString "wrong"))
           ]
    where
        validFloating (_, valueType) =
            verifyCore (coreModuleFor valueType (CoreFloating "1.25e2")) == Right (coreModuleFor valueType (CoreFloating "1.25e2"))

corePrepVerifierTests :: [(String, Bool)]
corePrepVerifierTests =
    concatMap verifyCorePrepIntegerBoundaries integerTypes
        ++ [ ("CorePrep verifier accepts every floating scalar", all validFloating floatingTypes)
           , ("CorePrep verifier rejects floating payload on int", invalidCorePrepLiteral intType (CoreFloating "1.0"))
           , ("CorePrep verifier rejects integer payload on float", invalidCorePrepLiteral (named "float") (CoreInteger 1))
           , ("CorePrep verifier rejects invalid floating exponent", invalidCorePrepLiteral (named "double") (CoreFloating "1e"))
           , ("CorePrep verifier rejects String payload on bool", invalidCorePrepLiteral boolType (CoreString "wrong"))
           ,
               ( "CorePrep verifier accepts discarded integer rounded division"
               , validDiscardedFloorDivide (named "long") (CoreInteger 7) (CoreInteger 2)
               )
           ,
               ( "CorePrep verifier accepts discarded floating rounded division"
               , validDiscardedFloorDivide (named "float") (CoreFloating "7.8") (CoreFloating "2.0")
               )
           , ("CorePrep verifier rejects mismatched discarded rounded division operands", rejectsMismatchedDiscardedFloorDivide)
           ]
    where
        validFloating (_, valueType) =
            verifyCorePrep (corePrepModuleFor valueType (CoreFloating "1.25e2"))
                == Right (corePrepModuleFor valueType (CoreFloating "1.25e2"))

verifyIntegerBoundaries :: (String, Type, Integer, Integer) -> [(String, Bool)]
verifyIntegerBoundaries (name, valueType, minimumValue, maximumValue) =
    [ ("Core verifier accepts " ++ name ++ " minimum", valid minimumValue)
    , ("Core verifier accepts " ++ name ++ " maximum", valid maximumValue)
    , ("Core verifier rejects " ++ name ++ " below minimum", invalid (minimumValue - 1))
    , ("Core verifier rejects " ++ name ++ " above maximum", invalid (maximumValue + 1))
    ]
    where
        valid value = verifyCore (coreModuleFor valueType (CoreInteger value)) == Right (coreModuleFor valueType (CoreInteger value))
        invalid value = invalidCoreLiteral valueType (CoreInteger value)

verifyCorePrepIntegerBoundaries :: (String, Type, Integer, Integer) -> [(String, Bool)]
verifyCorePrepIntegerBoundaries (name, valueType, minimumValue, maximumValue) =
    [ ("CorePrep verifier accepts " ++ name ++ " minimum", valid minimumValue)
    , ("CorePrep verifier accepts " ++ name ++ " maximum", valid maximumValue)
    , ("CorePrep verifier rejects " ++ name ++ " below minimum", invalid (minimumValue - 1))
    , ("CorePrep verifier rejects " ++ name ++ " above maximum", invalid (maximumValue + 1))
    ]
    where
        valid value =
            verifyCorePrep (corePrepModuleFor valueType (CoreInteger value))
                == Right (corePrepModuleFor valueType (CoreInteger value))
        invalid value = invalidCorePrepLiteral valueType (CoreInteger value)

invalidCoreLiteral :: Type -> CoreLiteral -> Bool
invalidCoreLiteral valueType literal = hasDiagnostic "TAC1029" (verifyCore (coreModuleFor valueType literal))

invalidCorePrepLiteral :: Type -> CoreLiteral -> Bool
invalidCorePrepLiteral valueType literal = hasDiagnostic "TAC0023" (verifyCorePrep (corePrepModuleFor valueType literal))

validDiscardedFloorDivide :: Type -> CoreLiteral -> CoreLiteral -> Bool
validDiscardedFloorDivide valueType left right =
    let moduleValue = discardedFloorDivideModule valueType left valueType right
     in verifyCorePrep moduleValue == Right moduleValue

rejectsMismatchedDiscardedFloorDivide :: Bool
rejectsMismatchedDiscardedFloorDivide =
    hasDiagnostic
        "TAC0019"
        (verifyCorePrep (discardedFloorDivideModule intType (CoreInteger 7) (named "long") (CoreInteger 2)))

discardedFloorDivideModule :: Type -> CoreLiteral -> Type -> CoreLiteral -> CorePrepModule
discardedFloorDivideModule leftType left rightType right =
    CorePrepModule
        (QualifiedName [Identifier "Scalar", Identifier "DiscardedFloorDivide"])
        [ CorePrepFunction
            (resolved 1 "Run")
            ""
            []
            unitType
            1
            [ CorePrepBlock
                1
                [ CorePrepEvaluate
                    ( CorePrepPrimitive
                        CoreFloorDivide
                        [ CorePrepLiteral left leftType
                        , CorePrepLiteral right rightType
                        ]
                    )
                ]
                (CorePrepReturn (CorePrepLiteral CoreUnit unitType))
            ]
        ]
        []

malformedWireTests :: [(String, Bool)]
malformedWireTests =
    [ ("Core wire rejects v2 input", rejectsCoreVersion 2)
    , ("Core wire rejects the previous v9 schema", rejectsCoreVersion 9)
    , ("Core wire rejects future input", rejectsCoreVersion 11)
    , ("CorePrep wire rejects v2 input", rejectsCorePrepVersion 2)
    , ("CorePrep wire rejects the previous v7 schema", rejectsCorePrepVersion 7)
    , ("CorePrep wire rejects future input", rejectsCorePrepVersion 9)
    , ("Core wire enforces numeric byte limit", coreNumericLimit)
    , ("CorePrep wire enforces numeric byte limit", corePrepNumericLimit)
    ]

rejectsCoreVersion :: Word8 -> Bool
rejectsCoreVersion version = case encodeCore defaultCoreWireLimits (coreModuleFor unitType CoreUnit) of
    Left _ -> False
    Right (_ : _ : _ : _ : _ : remaining) -> case decodeCore defaultCoreWireLimits ([0x54, 0x41, 0x43, 0x52, version] ++ remaining) of
        Left issue -> coreWireErrorKind issue == CoreUnsupportedVersion
        Right _ -> False
    Right _ -> False

rejectsCorePrepVersion :: Word8 -> Bool
rejectsCorePrepVersion version = case encodeCorePrep (corePrepModuleFor unitType CoreUnit) of
    Left _ -> False
    Right (_ : _ : _ : _ : _ : remaining) -> case decodeCorePrep ([0x54, 0x41, 0x43, 0x50, version] ++ remaining) of
        Left issue -> wireErrorKind issue == UnsupportedVersion
        Right _ -> False
    Right _ -> False

coreNumericLimit :: Bool
coreNumericLimit =
    let limits = defaultCoreWireLimits {maximumCoreNumericBytes = 1}
        source = coreModuleFor (named "long") (CoreInteger 256)
     in case encodeCore limits source of
            Left issue -> coreWireErrorKind issue == CoreLimitExceeded
            Right _ -> False

corePrepNumericLimit :: Bool
corePrepNumericLimit =
    let limits = defaultWireLimits {maximumNumericBytes = 1}
        source = corePrepModuleFor (named "long") (CoreInteger 256)
     in case encodeCorePrepWith limits source of
            Left issue -> wireErrorKind issue == LimitExceeded
            Right _ -> False
