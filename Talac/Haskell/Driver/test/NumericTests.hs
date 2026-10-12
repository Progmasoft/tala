-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module NumericTests (numericTests) where

import Data.Bits (shiftL)
import Data.List (isInfixOf, isPrefixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.CharacterLiteral
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.ConstantEvaluation
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.Scalar
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.FloatingLiteral
import Progmasoft.Tala.IntegerEvaluation
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.NumericLiteral
import Progmasoft.Tala.NumericSemantics
import Progmasoft.Tala.Parser
import Progmasoft.Tala.TemplateValue (TemplateValueError (..), evaluateTemplateValue)

numericTests :: [(String, Bool)]
numericTests =
    lexicalAcceptanceTests
        ++ lexicalRejectionTests
        ++ parserValueTests
        ++ characterLiteralTests
        ++ floatingLiteralTests
        ++ scalarMetadataTests
        ++ coreScalarCatalogTests
        ++ targetBoundaryTests
        ++ compileTimeIntegerTests
        ++ evaluatorParityTests
        ++ numericContextTests
        ++ corePropagationTests
        ++ integerPipelineTests
        ++ semanticRuleTests

lexicalAcceptanceTests :: [(String, Bool)]
lexicalAcceptanceTests =
    [ accepts "decimal zero" "0" IntegerToken
    , accepts "decimal digits" "26" IntegerToken
    , accepts "decimal separator" "1'000'000" IntegerToken
    , accepts "hexadecimal lowercase prefix" "0xff" IntegerToken
    , accepts "hexadecimal uppercase prefix" "0XFF" IntegerToken
    , accepts "hexadecimal separator" "0xFF'EE" IntegerToken
    , accepts "binary lowercase prefix" "0b1010" IntegerToken
    , accepts "binary uppercase prefix" "0B1010" IntegerToken
    , accepts "binary separator" "0b1010'1100" IntegerToken
    , accepts "maximum u8 spelling" "255" IntegerToken
    , accepts "maximum i16 spelling" "32'767" IntegerToken
    , accepts "maximum u16 spelling" "65'535" IntegerToken
    , accepts "maximum i32 spelling" "2'147'483'647" IntegerToken
    , accepts "maximum u32 spelling" "4'294'967'295" IntegerToken
    , accepts "maximum i64 spelling" "9'223'372'036'854'775'807" IntegerToken
    , accepts "maximum u64 spelling" "18'446'744'073'709'551'615" IntegerToken
    , accepts "maximum i128 spelling" "170'141'183'460'469'231'731'687'303'715'884'105'727" IntegerToken
    , accepts "maximum u128 spelling" "340'282'366'920'938'463'463'374'607'431'768'211'455" IntegerToken
    ]

lexicalRejectionTests :: [(String, Bool)]
lexicalRejectionTests =
    [ rejectsLexically "octal lowercase prefix" "0o377" "octal"
    , rejectsLexically "octal uppercase prefix" "0O377" "octal"
    , rejectsLexically "hexadecimal without digits" "0x" "at least one digit"
    , rejectsLexically "binary without digits" "0b" "at least one digit"
    , rejectsLexically "binary digit two" "0b2" "not a valid binary digit"
    , rejectsLexically "binary hexadecimal tail" "0bA" "not a valid binary digit"
    , rejectsLexically "hexadecimal letter G" "0xG" "not a valid hexadecimal digit"
    , rejectsLexically "decimal identifier tail" "123abc" "not a valid decimal digit"
    , rejectsLexically "leading radix separator" "0x'FF" "cannot begin"
    , rejectsLexically "trailing radix separator" "0b1010'" "cannot end"
    , rejectsLexically "consecutive decimal separators" "1''000" "consecutive"
    , rejectsLexically "consecutive hexadecimal separators" "0xAB''CD" "consecutive"
    , rejectsLexically "underscore is not a separator" "1_000" "not a valid decimal digit"
    , rejectsLexically "separator before invalid digit" "0b1'2" "between two valid binary digits"
    , rejectsLexically "separator after invalid digit" "0xG'0" "between two valid hexadecimal digits"
    ]

parserValueTests :: [(String, Bool)]
parserValueTests =
    [ parsedValue "decimal parser value" "26" 26
    , parsedValue "separated decimal parser value" "1'000'000" 1000000
    , parsedValue "hexadecimal parser value" "0xFF" 255
    , parsedValue "separated hexadecimal parser value" "0xFF'EE" 65518
    , parsedValue "binary parser value" "0b1010" 10
    , parsedValue "separated binary parser value" "0b1010'1100" 172
    , directParse "direct decimal radix" "12'345" DecimalRadix 12345
    , directParse "direct hexadecimal radix" "0xCA'FE" HexadecimalRadix 51966
    , directParse "direct binary radix" "0b1101'0010" BinaryRadix 210
    ]

characterLiteralTests :: [(String, Bool)]
characterLiteralTests =
    [ characterValue "single ASCII character" "'A'" 0x00000041
    , characterValue "two packed characters" "'AB'" 0x00004142
    , characterValue "three packed characters" "'ABC'" 0x00414243
    , characterValue "four packed characters" "'ABCD'" 0x41424344
    , characterValue "escaped newline participates in packing" "'A\\n'" 0x0000410a
    , characterValue "escaped quote" "'\\\''" 0x27
    , characterValue "escaped double quote" "'\\\"'" 0x22
    , characterValue "escaped backslash" "'\\\\'" 0x5c
    , characterValue "escaped null" "'\\0'" 0x00
    , characterValue "escaped alert" "'\\a'" 0x07
    , characterValue "escaped backspace" "'\\b'" 0x08
    , characterValue "escaped escape" "'\\e'" 0x1b
    , characterValue "escaped form feed" "'\\f'" 0x0c
    , characterValue "escaped carriage return" "'\\r'" 0x0d
    , characterValue "escaped horizontal tab" "'\\t'" 0x09
    , characterValue "escaped vertical tab" "'\\v'" 0x0b
    , characterValue "variable hexadecimal escape" "'\\x41'" 0x41
    , characterValue "four digit Unicode escape" "'\\u0041'" 0x41
    , characterValue "eight digit Unicode escape" "'\\U00000041'" 0x41
    , characterValue "Unicode scalar occupies required bytes" "'λ'" 0x03bb
    , characterFailure "empty character literal" "''" "at least one"
    , characterFailure "five ASCII values overflow u32" "'ABCDE'" "does not fit u32"
    , characterFailure "unsupported escape" "'\\q'" "unsupported character escape"
    , characterFailure "hexadecimal escape requires digits" "'\\x'" "requires at least one digit"
    , characterFailure "short u escape" "'\\u041'" "requires exactly 4 digits"
    , characterFailure "short U escape" "'\\U000041'" "requires exactly 8 digits"
    , characterFailure "surrogate escape" "'\\uD800'" "not a Unicode scalar"
    , characterFailure "out of range scalar" "'\\U00110000'" "not a Unicode scalar"
    , characterLexFailure "unterminated character literal" "'A" "unterminated"
    , characterLexFailure "physical newline character literal" "'A\nB'" "line break"
    , compiles "character literal targets char" "char letter = 'A';"
    , rejectedWith "character literal does not target int" "int letter = 'A';" "TAT0002"
    , ("character literal reaches Core as u32 payload", coreCharacterValue)
    ]

floatingLiteralTests :: [(String, Bool)]
floatingLiteralTests =
    [ floatingValue "decimal fraction" "1.5" "1.5"
    , floatingValue "lowercase scientific notation" "1e3" "1e3"
    , floatingValue "fraction with exponent" "1.5e2" "1.5e2"
    , floatingValue "uppercase signed exponent" "2E-4" "2E-4"
    , floatingValue "positive exponent sign" "2E+4" "2E+4"
    , floatingValue "separated integer and fraction" "1'000.250'000" "1000.250000"
    , floatingFailure "fraction requires right digits" "1." "both sides"
    , floatingFailure "fraction requires left digits" ".5" "both sides"
    , floatingFailure "exponent requires digits" "1e" "requires decimal digits"
    , floatingFailure "signed exponent requires digits" "1e-" "requires decimal digits"
    , floatingFailure "multiple decimal points" "1.2.3" "more than one decimal point"
    , floatingFailure "multiple exponent markers" "1e2e3" "more than one exponent"
    , floatingFailure "separator cannot touch decimal point on left" "1'.5" "between two digits"
    , floatingFailure "separator cannot touch decimal point on right" "1.'5" "between two digits"
    , floatingFailure "separator is forbidden in exponent" "1.5e1'00" "not allowed"
    , floatingFailure "fundamental suffixes are forbidden" "1.5f" "suffixes are not supported"
    , compiles "untargeted floating literal defaults to float" "auto value = 1.5;"
    , compiles "sfloat target selects f16 semantics" "sfloat value = 1.5;"
    , compiles "lfloat target selects f32 semantics" "lfloat value = 1.5;"
    , compiles "float target selects f64 semantics" "float value = 1.5;"
    , compiles "double target selects f128 semantics" "double value = 1.5;"
    , rejectedWith "integer target rejects floating literal" "int value = 1.5;" "TAT0002"
    , ("floating spelling reaches Core without host rounding", coreFloatingSpelling)
    ]

scalarMetadataTests :: [(String, Bool)]
scalarMetadataTests =
    [ scalarMetadata "char is u32 storage" CharacterScalar CharacterFamily 32 False
    , scalarMetadata "bool is u8 storage" BooleanScalar BooleanFamily 8 False
    , scalarMetadata "byte is i8" ByteScalar SignedIntegerFamily 8 True
    , scalarMetadata "short is i16" ShortScalar SignedIntegerFamily 16 True
    , scalarMetadata "long is i32" LongScalar SignedIntegerFamily 32 True
    , scalarMetadata "int is i64" IntScalar SignedIntegerFamily 64 True
    , scalarMetadata "longint is i128" LongIntScalar SignedIntegerFamily 128 True
    , scalarMetadata "ubyte is u8" UByteScalar UnsignedIntegerFamily 8 False
    , scalarMetadata "ushort is u16" UShortScalar UnsignedIntegerFamily 16 False
    , scalarMetadata "ulong is u32" ULongScalar UnsignedIntegerFamily 32 False
    , scalarMetadata "uint is u64" UIntScalar UnsignedIntegerFamily 64 False
    , scalarMetadata "ulongint is u128" ULongIntScalar UnsignedIntegerFamily 128 False
    , scalarMetadata "sfloat is f16" SFloatScalar FloatingFamily 16 False
    , scalarMetadata "lfloat is f32" LFloatScalar FloatingFamily 32 False
    , scalarMetadata "float is f64" FloatScalar FloatingFamily 64 False
    , scalarMetadata "double is f128" DoubleScalar FloatingFamily 128 False
    , ("default integer is int", defaultIntegerScalar == IntScalar)
    , ("default floating point is float", defaultFloatingScalar == FloatScalar)
    , ("every scalar name round-trips through Type", all scalarRoundTrips scalarTypes)
    , ("every wrapper name round-trips to its scalar", all wrapperRoundTrips scalarTypes)
    , ("signed width rank selects int over long", widerScalarType LongScalar IntScalar == Just IntScalar)
    , ("unsigned width rank selects ulongint", widerScalarType UIntScalar ULongIntScalar == Just ULongIntScalar)
    , ("floating width rank selects double", widerScalarType SFloatScalar DoubleScalar == Just DoubleScalar)
    , ("different scalar families have no wider common scalar", widerScalarType IntScalar UIntScalar == Nothing)
    ]

coreScalarCatalogTests :: [(String, Bool)]
coreScalarCatalogTests =
    [
        ( "Core optimizer integer catalog matches frontend scalar order"
        , coreIntegerTypeNames == map scalarTypeName integerCoreScalars
        )
    , ("Core optimizer integer widths match frontend scalar metadata", all widthMatches integerCoreScalars)
    , ("Core optimizer integer signedness matches frontend scalar metadata", all signednessMatches integerCoreScalars)
    ,
        ( "Core optimizer floating catalog matches frontend floating names"
        , coreFloatingTypeNames == map scalarTypeName floatingCoreScalars
        )
    , ("Boolean is not classified as an integer by Core", not (isCoreIntegerType boolType))
    ]
    where
        integerCoreScalars = filter ((`elem` [CharacterFamily, SignedIntegerFamily, UnsignedIntegerFamily]) . scalarTypeFamily) scalarTypes
        floatingCoreScalars = filter ((== FloatingFamily) . scalarTypeFamily) scalarTypes
        widthMatches scalar = coreIntegerBitWidth (scalarTypeToType scalar) == Just (scalarTypeWidth scalar)
        signednessMatches scalar = coreIntegerIsSigned (scalarTypeToType scalar) == Just (scalarTypeSigned scalar)

targetBoundaryTests :: [(String, Bool)]
targetBoundaryTests =
    concat
        [ signedBoundary "byte" ByteScalar (-128) 127
        , signedBoundary "short" ShortScalar (-32768) 32767
        , signedBoundary "long" LongScalar (-2147483648) 2147483647
        , signedBoundary "int" IntScalar (-9223372036854775808) 9223372036854775807
        , signedBoundary
            "longint"
            LongIntScalar
            (-170141183460469231731687303715884105728)
            170141183460469231731687303715884105727
        , unsignedBoundary "ubyte" UByteScalar 255
        , unsignedBoundary "ushort" UShortScalar 65535
        , unsignedBoundary "ulong" ULongScalar 4294967295
        , unsignedBoundary "uint" UIntScalar 18446744073709551615
        , unsignedBoundary "ulongint" ULongIntScalar 340282366920938463463374607431768211455
        ]
        ++ [ compiles "targeted byte literal" "byte value = 127;"
           , rejectedWith "byte overflow diagnostic" "byte value = 128;" "TAT0016"
           , compiles "targeted unsigned literal" "ubyte value = 255;"
           , rejectedWith "unsigned overflow diagnostic" "ubyte value = 256;" "TAT0016"
           , rejectedWith "unsigned negative diagnostic" "ubyte value = -1;" "TAT0011"
           , compiles "targeted longint beyond int" "longint value = 9'223'372'036'854'775'808;"
           , rejectedWith
                "un-targeted literal never widens silently"
                "auto value = 9'223'372'036'854'775'808;"
                "TAT0017"
           , compiles "constant expression fits byte target" "byte value = 100 + 27;"
           , rejectedWith "constant expression overflow is diagnosed" "byte value = 100 + 28;" "TAT0018"
           , rejectedWith "constant division by zero is diagnosed" "int value = 1 / 0;" "TAT0019"
           , rejectedWith "constant floor division by zero is diagnosed" "int value = 1 // 0;" "TAT0019"
           , rejectedWith "constant remainder by zero is diagnosed" "int value = 1 % 0;" "TAT0019"
           , compiles "integer power is accepted" "int value = 2 ** 8;"
           , compiles "integer shift is accepted" "int value = 1 << 8;"
           , rejectedWith "integer power evaluation is bounded" "int value = 2 ** 9223372036854775807;" "TAT0019"
           , rejectedWith "integer left shift evaluation is bounded" "int value = 1 << 9223372036854775807;" "TAT0019"
           , compiles "zero power remains bounded for a huge exponent" "int value = 0 ** 9223372036854775807;"
           , compiles "one power remains bounded for a huge exponent" "int value = 1 ** 9223372036854775807;"
           , compiles "negative unit power uses parity for a huge exponent" "int value = (-1) ** 9223372036854775807;"
           , compiles "zero left shift remains bounded for a huge count" "int value = 0 << 9223372036854775807;"
           , compiles "right shift by a huge count saturates positive values" "int value = 5 >> 9223372036854775807;"
           , compiles "right shift by a huge count sign-extends negative values" "int value = -5 >> 9223372036854775807;"
           , rejectedWith "left shift beyond the compile-time magnitude limit is diagnosed" "int value = 1 << 65536;" "TAT0019"
           , rejectedWith "power beyond the compile-time magnitude limit is diagnosed" "int value = 2 ** 65536;" "TAT0019"
           , compiles "zero left shift avoids constructing an over-limit result" "int value = 0 << 65536;"
           , compiles "large right shift avoids constructing an intermediate" "int value = 1 >> 65536;"
           , compiles "integer bitwise expression is accepted" "int value = !0 & 255 | 4 ^ 1;"
           , compiles "unsigned bitwise complement uses the selected width" "ubyte value = !0;"
           , compiles "16-bit unsigned complement uses its selected width" "ushort value = !0;"
           , compiles "32-bit unsigned complement uses its selected width" "ulong value = !0;"
           , compiles "64-bit unsigned complement uses its selected width" "uint value = !0;"
           , compiles "128-bit unsigned bitwise complement uses the selected width" "ulongint value = !0;"
           , compiles "unsigned complement masks the operand's top bit" "ubyte value = !255;"
           , rejectedWith "bitwise not rejects floating point" "float value = !1.0;" "TAT0011"
           , rejectedWith "bitwise binary rejects floating point" "float value = 1.0 & 2.0;" "TAT0012"
           ]

compileTimeIntegerTests :: [(String, Bool)]
compileTimeIntegerTests =
    integerEvaluationTests
        ++ constantExpressionTests
        ++ sourceRangeMatrix
        ++ sourceShiftRangeMatrix

integerEvaluationTests :: [(String, Bool)]
integerEvaluationTests =
    [
        ( "compile-time integer cap accepts its positive edge"
        , checkCompileTimeInteger (compileTimeMagnitude - 1) == Right (compileTimeMagnitude - 1)
        )
    ,
        ( "compile-time integer cap accepts its negative edge"
        , checkCompileTimeInteger (1 - compileTimeMagnitude) == Right (1 - compileTimeMagnitude)
        )
    ,
        ( "compile-time integer cap rejects positive overflow"
        , checkCompileTimeInteger compileTimeMagnitude == Left CompileTimeIntegerLimitExceeded
        )
    ,
        ( "compile-time integer cap rejects negative overflow"
        , checkCompileTimeInteger (negate compileTimeMagnitude) == Left CompileTimeIntegerLimitExceeded
        )
    , ("zero power bypasses an enormous exponent", evaluateCompileTimePower 0 enormousExponent == Right 0)
    , ("unit power bypasses an enormous exponent", evaluateCompileTimePower 1 enormousExponent == Right 1)
    , ("negative unit power uses exponent parity", evaluateCompileTimePower (-1) enormousExponent == Right (-1))
    ,
        ( "integer power stops at the largest permitted intermediate"
        , evaluateCompileTimePower 2 65535 == Right (compileTimeMagnitude `quot` 2)
        )
    ,
        ( "integer power rejects its first out-of-limit intermediate"
        , evaluateCompileTimePower 2 65536 == Left CompileTimeIntegerLimitExceeded
        )
    ,
        ( "integer power reports a negative exponent distinctly"
        , evaluateCompileTimePower 2 (-1) == Left CompileTimeNegativeExponent
        )
    ,
        ( "bounded multiplication accepts a product below the bit ceiling"
        , multiplyCompileTimeIntegers (2 ^ (32767 :: Int)) (2 ^ (32767 :: Int)) == Right (2 ^ (65534 :: Int))
        )
    ,
        ( "bounded multiplication accepts the largest represented bit position"
        , multiplyCompileTimeIntegers (compileTimeMagnitude `quot` 2) 1 == Right (compileTimeMagnitude `quot` 2)
        )
    ,
        ( "bounded multiplication rejects the first out-of-range exact power"
        , multiplyCompileTimeIntegers (compileTimeMagnitude `quot` 2) 2 == Left CompileTimeIntegerLimitExceeded
        )
    ,
        ( "bounded multiplication rejects products beyond the bit ceiling"
        , multiplyCompileTimeIntegers (compileTimeMagnitude `quot` 2) 3 == Left CompileTimeIntegerLimitExceeded
        )
    ,
        ( "bounded multiplication handles zero without a large product"
        , multiplyCompileTimeIntegers 0 (compileTimeMagnitude - 1) == Right 0
        )
    , ("zero left shift ignores an enormous shift count", evaluateCompileTimeShiftLeft 0 enormousExponent == Right 0)
    ,
        ( "left shift reaches but does not exceed the compile-time width"
        , evaluateCompileTimeShiftLeft 1 65535 == Right (compileTimeMagnitude `quot` 2)
        )
    ,
        ( "left shift rejects a result beyond the compile-time width"
        , evaluateCompileTimeShiftLeft 1 65536 == Left CompileTimeIntegerLimitExceeded
        )
    , ("positive arithmetic right shift saturates to zero", evaluateCompileTimeShiftRight 3 enormousExponent == Right 0)
    ,
        ( "negative arithmetic right shift saturates to minus one"
        , evaluateCompileTimeShiftRight (-3) enormousExponent == Right (-1)
        )
    , ("negative shift count reverses left shift direction", evaluateCompileTimeShiftLeft (-12) (-2) == Right (-3))
    , ("negative shift count reverses right shift direction", evaluateCompileTimeShiftRight (-12) (-2) == Right (-48))
    ,
        ( "reversing a huge right shift is rejected before allocation"
        , evaluateCompileTimeShiftRight 1 (negate enormousExponent) == Left CompileTimeIntegerLimitExceeded
        )
    ]

constantExpressionTests :: [(String, Bool)]
constantExpressionTests =
    [
        ( "unsigned constant complement masks to its annotated width"
        , evaluateConstantInteger unsignedComplement == Right (Just 0)
        )
    ,
        ( "signed constant complement reports its compile-time limit"
        , evaluateConstantInteger signedComplementAtLimit == Left ConstantEvaluationLimitExceeded
        )
    , ("a runtime name remains non-constant", evaluateConstantInteger runtimeName == Right Nothing)
    ,
        ( "a call expression remains non-constant without a pattern-match failure"
        , evaluateConstantInteger runtimeCall == Right Nothing
        )
    ,
        ( "constant arithmetic limit is rendered for diagnostics"
        , renderConstantIntegerError ConstantEvaluationLimitExceeded
            == "constant integer expression exceeds the compile-time evaluation limit"
        )
    ]
    where
        unsignedComplement = UnaryExpression testSpan BitwiseNot (integerExpression 255 (namedType "ubyte")) (namedType "ubyte")
        signedComplementAtLimit = UnaryExpression testSpan BitwiseNot (integerExpression (compileTimeMagnitude - 1) intType) intType
        runtimeName = NameExpression testSpan (ResolvedName (SymbolId 1) (Identifier "runtimeValue")) intType
        runtimeCall = CallExpression testSpan runtimeName [] intType

sourceRangeMatrix :: [(String, Bool)]
sourceRangeMatrix = concatMap scalarRangeCases integerScalars
    where
        integerScalars = filter isRangeChecked scalarTypes
        isRangeChecked scalar = scalarTypeFamily scalar `elem` [SignedIntegerFamily, UnsignedIntegerFamily]
        scalarRangeCases scalar = case (integerMinimum scalar, integerMaximum scalar) of
            (Just minimumValue, Just maximumValue) ->
                let typeName = scalarTypeName scalar
                    literal expression = typeName ++ " value = " ++ expression ++ ";"
                 in [ compiles (typeName ++ " constant lower edge remains in range") (literal (show (minimumValue + 1) ++ " - 1"))
                    , compiles (typeName ++ " constant upper edge remains in range") (literal (show (maximumValue - 1) ++ " + 1"))
                    , compiles (typeName ++ " constant multiplication by one remains in range") (literal (show maximumValue ++ " * 1"))
                    , rejectedWith (typeName ++ " constant lower overflow is diagnosed") (literal (show minimumValue ++ " - 1")) "TAT0018"
                    , rejectedWith (typeName ++ " constant upper overflow is diagnosed") (literal (show maximumValue ++ " + 1")) "TAT0018"
                    , rejectedWith
                        (typeName ++ " constant multiplication overflow is diagnosed")
                        (literal (show maximumValue ++ " * 2"))
                        "TAT0018"
                    ,
                        ( typeName ++ " signed lower multiplication overflow is diagnosed"
                        , scalarTypeFamily scalar /= SignedIntegerFamily
                            || snd (rejectedWith "signed lower multiplication overflow" (literal (show minimumValue ++ " * 2")) "TAT0018")
                        )
                    ]
            _ -> []

-- The frontend's arbitrary-precision evaluator must still hand its exact value
-- to the selected fixed-width type range check. This catches accidental
-- widening or truncation at the source-to-Core boundary for every integer ABI.
sourceShiftRangeMatrix :: [(String, Bool)]
sourceShiftRangeMatrix = concatMap scalarShiftCases integerScalars
    where
        integerScalars = filter isIntegerScalar scalarTypes
        isIntegerScalar scalar = scalarTypeFamily scalar `elem` [SignedIntegerFamily, UnsignedIntegerFamily]
        scalarShiftCases scalar = case (integerMaximum scalar, scalarTypeSigned scalar) of
            (Just _, isSigned) ->
                let typeName = scalarTypeName scalar
                    width = scalarTypeWidth scalar
                    highestInRangeShift = width - if isSigned then 2 else 1
                    firstOutOfRangeShift = width - if isSigned then 1 else 0
                    declaration shiftAmount = typeName ++ " value = 1 << " ++ show shiftAmount ++ ";"
                 in [ compiles
                        (typeName ++ " shift produces its highest in-range positive value")
                        (declaration highestInRangeShift)
                    , rejectedWith
                        (typeName ++ " shift beyond its positive range is diagnosed")
                        (declaration firstOutOfRangeShift)
                        "TAT0018"
                    ]
            _ -> []

compileTimeMagnitude :: Integer
compileTimeMagnitude = 1 `shiftL` 65536

enormousExponent :: Integer
enormousExponent = 2 ^ (63 :: Int) - 1

testSpan :: SourceSpan
testSpan = SourceSpan "numeric-test.tala" (SourcePosition 1 1) (SourcePosition 1 2)

integerExpression :: Integer -> Type -> Expression ResolvedName Type
integerExpression value valueType = LiteralExpression testSpan (IntegerLiteral value) valueType

data EvaluatorOutcome
    = EvaluatedInteger Integer
    | EvaluatedBoolean Bool
    | EvaluatedCharacter Integer
    | EvaluatorDivisionByZero
    | EvaluatorFloorDivisionByZero
    | EvaluatorRemainderByZero
    | EvaluatorNegativeExponent
    | EvaluatorLimitExceeded
    | EvaluatorNonconstant
    | EvaluatorOtherError
    deriving (Eq, Ord, Read, Show)

evaluatorParityTests :: [(String, Bool)]
evaluatorParityTests = binaryParityTests ++ unaryParityTests

binaryParityTests :: [(String, Bool)]
binaryParityTests = map checkOperator binaryOperators
    where
        binaryOperators =
            [ Add
            , Subtract
            , Multiply
            , Divide
            , FloorDivide
            , Remainder
            , Power
            , ShiftLeft
            , ShiftRight
            , BitwiseAnd
            , BitwiseXor
            , BitwiseOr
            , LessThan
            , LessEqual
            , GreaterThan
            , GreaterEqual
            , Equal
            , NotEqual
            , LogicalAnd
            , LogicalOr
            ]
        inputs = [-4 .. 4]
        checkOperator operator =
            ( "constant and template evaluators agree for " ++ show operator ++ " across small signed integer inputs"
            , all (uncurry (sameBinaryOutcome operator)) [(left, right) | left <- inputs, right <- inputs]
            )

unaryParityTests :: [(String, Bool)]
unaryParityTests = map checkOperator [UnaryPlus, UnaryNegate, LogicalNot, BitwiseNot]
    where
        checkOperator operator =
            ( "constant and template evaluators agree for unary " ++ show operator
            , all (sameUnaryOutcome operator) [-8 .. 8]
            )

sameBinaryOutcome :: BinaryOperator -> Integer -> Integer -> Bool
sameBinaryOutcome operator left right = constantOutcome resultType constant == templateOutcome (evaluateTemplateValue template)
    where
        resultType =
            if operator `elem` [LessThan, LessEqual, GreaterThan, GreaterEqual, Equal, NotEqual, LogicalAnd, LogicalOr]
                then boolType
                else intType
        constant =
            evaluateConstantInteger
                (BinaryExpression testSpan operator (integerExpression left intType) (integerExpression right intType) resultType)
        template = TemplateBinarySyntax testSpan operator (TemplateIntegerSyntax testSpan left) (TemplateIntegerSyntax testSpan right)

sameUnaryOutcome :: UnaryOperator -> Integer -> Bool
sameUnaryOutcome operator value = constantOutcome resultType constant == templateOutcome (evaluateTemplateValue template)
    where
        resultType = if operator == LogicalNot then boolType else intType
        constant = evaluateConstantInteger (UnaryExpression testSpan operator (integerExpression value intType) resultType)
        template = TemplateUnarySyntax testSpan operator (TemplateIntegerSyntax testSpan value)

constantOutcome :: Type -> Either ConstantIntegerError (Maybe Integer) -> EvaluatorOutcome
constantOutcome _ (Left issue) = case issue of
    ConstantDivisionByZero -> EvaluatorDivisionByZero
    ConstantFloorDivisionByZero -> EvaluatorFloorDivisionByZero
    ConstantRemainderByZero -> EvaluatorRemainderByZero
    ConstantNegativeExponent -> EvaluatorNegativeExponent
    ConstantEvaluationLimitExceeded -> EvaluatorLimitExceeded
constantOutcome _ (Right Nothing) = EvaluatorNonconstant
constantOutcome resultType (Right (Just value))
    | resultType == boolType = EvaluatedBoolean (value /= 0)
    | otherwise = EvaluatedInteger value

templateOutcome :: Either TemplateValueError TemplateValue -> EvaluatorOutcome
templateOutcome result = case result of
    Right (IntegerTemplateValue value) -> EvaluatedInteger value
    Right (BooleanTemplateValue value) -> EvaluatedBoolean value
    Right (CharacterTemplateValue value) -> EvaluatedCharacter value
    Right _ -> EvaluatorOtherError
    Left TemplateValueDivisionByZero -> EvaluatorDivisionByZero
    Left TemplateValueFloorDivisionByZero -> EvaluatorFloorDivisionByZero
    Left TemplateValueRemainderByZero -> EvaluatorRemainderByZero
    Left (TemplateValueNegativeExponent _) -> EvaluatorNegativeExponent
    Left TemplateValueEvaluationLimitExceeded -> EvaluatorLimitExceeded
    Left _ -> EvaluatorOtherError

numericContextTests :: [(String, Bool)]
numericContextTests =
    [ compiles "numeric zero is a valid condition" "if (0) { return; }"
    , compiles "numeric one is a valid condition" "if (1) { return; }"
    , compiles "numeric negative one is a valid condition" "if (-1) { return; }"
    , compiles "integer literal targets bool" "bool enabled = 1;"
    , compiles "integer zero targets bool" "bool disabled = 0;"
    , rejectedWith "string is not a condition" "if (\"yes\") { return; }" "TAT0006"
    , compiles "same-width long arithmetic" "long value = 2 + 3;"
    , compiles "same-width byte arithmetic" "byte value = 2 + 3;"
    , compiles "floating rounded division returns int" "int value = 7.8 // 2.0;"
    , compiles
        "integer rounded division keeps contextual long type"
        "long left = 7; long right = 2; long value = left // right;"
    , rejectedWith
        "floating rounded division rejects mixed operand widths"
        "float left = 7.8; lfloat right = 2.0; int value = left // right;"
        "TAT0012"
    , rejectedWith
        "mixed computed widths are not implicit conversions"
        "long left = 1; int right = 2; int sum = left + right;"
        "TAT0012"
    ]

corePropagationTests :: [(String, Bool)]
corePropagationTests =
    [ ("targeted long literal reaches Core with long type", coreLiteralHasType "long" 42)
    , ("targeted byte literal reaches Core with byte type", coreLiteralHasType "byte" 42)
    , ("targeted uint literal reaches Core with uint type", coreLiteralHasType "uint" 42)
    , ("numeric bool lowering emits a Core boolean", numericBoolLowers)
    , ("numeric branch reaches CorePrep as a canonical boolean", numericBranchCorePrep)
    , ("mixed numeric logical operands become CorePrep booleans", numericLogicalCorePrep)
    ]

integerPipelineTests :: [(String, Bool)]
integerPipelineTests = case compileToCorePrep compilerInput of
    Left diagnostics -> [("integer pipeline fixture compiles (" ++ show (map diagnosticCode diagnostics) ++ ")", False)]
    Right artifacts ->
        let functions = coreModuleFunctions (artifactOptimizedCore artifacts)
         in if length functions /= length pipelineCases
                then [("integer pipeline retains every test function", False)]
                else zipWith matchesFunction pipelineCases functions
    where
        integerScalars = filter ((`elem` [SignedIntegerFamily, UnsignedIntegerFamily]) . scalarTypeFamily) scalarTypes
        pipelineCases = concatMap casesFor integerScalars
        sourceMethods =
            [ typeName ++ " " ++ functionName ++ "() { return " ++ expression ++ "; }"
            | (functionName, typeName, expression, _) <- pipelineCases
            ]
        compilerInput = CompilerInput "integer-optimizer-pipeline.tala" ("class Numeric { " ++ unwords sourceMethods ++ " }")
        casesFor scalar =
            let typeName = scalarTypeName scalar
                complementZero = if scalarTypeFamily scalar == SignedIntegerFamily then -1 else 2 ^ scalarTypeWidth scalar - 1
             in [ ("IntegerCaseAdd" ++ typeName, typeName, "20 + 22", 42)
                , ("IntegerCaseSubtract" ++ typeName, typeName, "50 - 8", 42)
                , ("IntegerCaseMultiply" ++ typeName, typeName, "6 * 7", 42)
                , ("IntegerCaseDivide" ++ typeName, typeName, "84 / 2", 42)
                , ("IntegerCaseRoundedDivide" ++ typeName, typeName, "7 // 2", 4)
                , ("IntegerCaseRemainder" ++ typeName, typeName, "7 % 3", 1)
                , ("IntegerCasePower" ++ typeName, typeName, "3 ** 4", 81)
                , ("IntegerCaseShiftLeft" ++ typeName, typeName, "3 << 4", 48)
                , ("IntegerCaseShiftRight" ++ typeName, typeName, "48 >> 4", 3)
                , ("IntegerCaseBitwiseAnd" ++ typeName, typeName, "14 & 11", 10)
                , ("IntegerCaseBitwiseXor" ++ typeName, typeName, "14 ^ 11", 5)
                , ("IntegerCaseBitwiseOr" ++ typeName, typeName, "8 | 3", 11)
                , ("IntegerCaseBitwiseNot" ++ typeName, typeName, "!0", complementZero)
                ]
        matchesFunction (functionName, typeName, expression, expected) function =
            let body = coreFunctionBody function
                actualName = identifierText (resolvedSpelling (coreFunctionName function))
                valueMatches = case body of
                    [CoreReturn (CoreLiteral (CoreInteger value) resultType)] ->
                        value == expected && resultType == namedType typeName && coreFunctionReturnType function == resultType
                    _ -> False
             in ( "source constant operator "
                    ++ functionName
                    ++ " folds "
                    ++ expression
                    ++ " to the typed expected value (Core: "
                    ++ show (actualName, body)
                    ++ ")"
                , actualName == functionName && valueMatches
                )

semanticRuleTests :: [(String, Bool)]
semanticRuleTests =
    [ ruleSucceeds "int addition preserves int" intType (binaryNumericRule Add intType intType)
    , ruleSucceeds
        "long addition preserves long"
        (namedType "long")
        (binaryNumericRule Add (namedType "long") (namedType "long"))
    , ruleSucceeds
        "uint multiplication preserves uint"
        (namedType "uint")
        (binaryNumericRule Multiply (namedType "uint") (namedType "uint"))
    , ruleSucceeds
        "floating division preserves float"
        (namedType "float")
        (binaryNumericRule Divide (namedType "float") (namedType "float"))
    , ruleSucceeds
        "floating rounded division returns int"
        intType
        (binaryNumericRule FloorDivide (namedType "float") (namedType "float"))
    , ruleSucceeds
        "integer rounded division preserves its operand width"
        (namedType "long")
        (binaryNumericRule FloorDivide (namedType "long") (namedType "long"))
    , ruleSucceeds "numeric comparison returns bool" boolType (binaryNumericRule LessThan intType intType)
    , ruleSucceeds "integer equality returns bool" boolType (binaryNumericRule Equal intType intType)
    , ruleSucceeds "boolean logical and returns bool" boolType (binaryNumericRule LogicalAnd boolType boolType)
    , ruleSucceeds "numeric logical or returns bool" boolType (binaryNumericRule LogicalOr intType intType)
    , ruleSucceeds "integer power preserves int" intType (binaryNumericRule Power intType intType)
    , ruleSucceeds "integer shift-left preserves int" intType (binaryNumericRule ShiftLeft intType intType)
    , ruleSucceeds "integer shift-right preserves int" intType (binaryNumericRule ShiftRight intType intType)
    , ruleSucceeds "integer bitwise and preserves int" intType (binaryNumericRule BitwiseAnd intType intType)
    , ruleSucceeds "integer bitwise xor preserves int" intType (binaryNumericRule BitwiseXor intType intType)
    , ruleSucceeds "integer bitwise or preserves int" intType (binaryNumericRule BitwiseOr intType intType)
    , ruleFails "floating shift fails" (binaryNumericRule ShiftLeft (namedType "float") (namedType "float"))
    , ruleFails "floating bitwise operation fails" (binaryNumericRule BitwiseAnd (namedType "float") (namedType "float"))
    , ruleFails "mixed signed widths fail" (binaryNumericRule Add (namedType "long") intType)
    , ruleFails "mixed signedness fails" (binaryNumericRule Add intType (namedType "uint"))
    , ruleFails "string arithmetic fails" (binaryNumericRule Add stringType stringType)
    , ruleFails "mismatched equality fails" (binaryNumericRule Equal intType (namedType "long"))
    , ruleSucceeds "unary plus preserves signed integer" intType (unaryNumericRule UnaryPlus intType)
    , ruleSucceeds "unary plus preserves unsigned integer" (namedType "uint") (unaryNumericRule UnaryPlus (namedType "uint"))
    , ruleSucceeds "unary negate preserves float" (namedType "float") (unaryNumericRule UnaryNegate (namedType "float"))
    , ruleFails "unary negate rejects unsigned integer" (unaryNumericRule UnaryNegate (namedType "uint"))
    , ruleSucceeds "logical not accepts integer context" boolType (unaryNumericRule LogicalNot intType)
    , ruleFails "logical not rejects string" (unaryNumericRule LogicalNot stringType)
    , ruleSucceeds "bitwise not preserves integer" intType (unaryNumericRule BitwiseNot intType)
    , ruleFails "bitwise not rejects floating point" (unaryNumericRule BitwiseNot (namedType "float"))
    , ruleSucceeds "untargeted small integer selects int" intType (integerLiteralRule NoNumericContext 42)
    , ruleFails "untargeted oversized integer fails" (integerLiteralRule NoNumericContext 9223372036854775808)
    , ruleSucceeds "boolean integer context selects bool" boolType (integerLiteralRule BooleanNumericContext 99)
    , ruleSucceeds
        "targeted ubyte selects ubyte"
        (namedType "ubyte")
        (integerLiteralRule (TargetNumericType (namedType "ubyte")) 255)
    , ruleFails "targeted ubyte rejects overflow" (integerLiteralRule (TargetNumericType (namedType "ubyte")) 256)
    , ruleSucceeds "untargeted floating selects float" (namedType "float") (floatingLiteralRule NoNumericContext)
    , ruleSucceeds
        "targeted double selects double"
        (namedType "double")
        (floatingLiteralRule (TargetNumericType (namedType "double")))
    , ("bool accepts boolean context", acceptsBooleanContext boolType)
    , ("integer accepts boolean context", acceptsBooleanContext intType)
    , ("floating point accepts boolean context", acceptsBooleanContext (namedType "float"))
    , ("string rejects boolean context", not (acceptsBooleanContext stringType))
    ]

ruleSucceeds :: String -> Type -> NumericRuleResult -> (String, Bool)
ruleSucceeds label expected rule =
    (label, numericRuleType rule == expected && numericRuleError rule == Nothing)

ruleFails :: String -> NumericRuleResult -> (String, Bool)
ruleFails label rule = (label, case numericRuleError rule of Just _ -> True; Nothing -> False)

accepts :: String -> String -> TokenKind -> (String, Bool)
accepts label source expectedKind =
    (label, case lexOne source of Right [token] -> tokenKind token == expectedKind && tokenText token == source; _ -> False)

rejectsLexically :: String -> String -> String -> (String, Bool)
rejectsLexically label source fragment =
    (label, case lexOne source of Left problems -> any (isInfixOf fragment . diagnosticMessage) problems; Right _ -> False)

parsedValue :: String -> String -> Integer -> (String, Bool)
parsedValue label spelling expected =
    ( label
    , case lexWithEof spelling >>= parseExpressionModule of
        Right value -> value == expected
        Left _ -> False
    )

directParse :: String -> String -> IntegerRadix -> Integer -> (String, Bool)
directParse label spelling radix expected =
    ( label
    , case parseIntegerSpelling spelling of
        Right parsed -> parsedIntegerRadix parsed == radix && parsedIntegerValue parsed == expected
        Left _ -> False
    )

characterValue :: String -> String -> Integer -> (String, Bool)
characterValue label spelling expected =
    (label, parseCharacterLiteral spelling == Right expected)

characterFailure :: String -> String -> String -> (String, Bool)
characterFailure label spelling fragment =
    ( label
    , case parseCharacterLiteral spelling of
        Left issue -> fragment `isInfixOf` renderCharacterLiteralError issue
        Right _ -> False
    )

characterLexFailure :: String -> String -> String -> (String, Bool)
characterLexFailure label spelling fragment =
    ( label
    , case lexOne spelling of Left problems -> any (isInfixOf fragment . diagnosticMessage) problems; Right _ -> False
    )

floatingValue :: String -> String -> String -> (String, Bool)
floatingValue label spelling expected =
    (label, validateFloatingSpelling spelling == Right expected)

floatingFailure :: String -> String -> String -> (String, Bool)
floatingFailure label spelling fragment =
    ( label
    , case validateFloatingSpelling spelling of
        Left issue -> fragment `isInfixOf` renderFloatingLiteralError issue
        Right _ -> False
    )

scalarMetadata :: String -> ScalarType -> ScalarFamily -> Int -> Bool -> (String, Bool)
scalarMetadata label scalar family width signed =
    ( label
    , scalarTypeFamily scalar == family
        && scalarTypeWidth scalar == width
        && scalarTypeSigned scalar == signed
    )

scalarRoundTrips :: ScalarType -> Bool
scalarRoundTrips scalar = typeToScalarType (scalarTypeToType scalar) == Just scalar

wrapperRoundTrips :: ScalarType -> Bool
wrapperRoundTrips scalar = wrapperNameToScalarType (scalarWrapperName scalar) == Just scalar

signedBoundary :: String -> ScalarType -> Integer -> Integer -> [(String, Bool)]
signedBoundary name scalar minimumValue maximumValue =
    [ (name ++ " minimum fits", integerFits scalar minimumValue)
    , (name ++ " maximum fits", integerFits scalar maximumValue)
    , (name ++ " below minimum is rejected", not (integerFits scalar (minimumValue - 1)))
    , (name ++ " above maximum is rejected", not (integerFits scalar (maximumValue + 1)))
    , (name ++ " reported minimum is exact", integerMinimum scalar == Just minimumValue)
    , (name ++ " reported maximum is exact", integerMaximum scalar == Just maximumValue)
    ]

unsignedBoundary :: String -> ScalarType -> Integer -> [(String, Bool)]
unsignedBoundary name scalar maximumValue =
    [ (name ++ " zero fits", integerFits scalar 0)
    , (name ++ " maximum fits", integerFits scalar maximumValue)
    , (name ++ " negative one is rejected", not (integerFits scalar (-1)))
    , (name ++ " above maximum is rejected", not (integerFits scalar (maximumValue + 1)))
    , (name ++ " reported minimum is zero", integerMinimum scalar == Just 0)
    , (name ++ " reported maximum is exact", integerMaximum scalar == Just maximumValue)
    ]

compiles :: String -> String -> (String, Bool)
compiles label body = (label, case compileBody body of Right _ -> True; Left _ -> False)

rejectedWith :: String -> String -> String -> (String, Bool)
rejectedWith label body code =
    (label, case compileBody body of Left problems -> any ((== code) . diagnosticCode) problems; Right _ -> False)

compileBody :: String -> Either [Diagnostic] FrontendArtifacts
compileBody body = compile ("class Numeric { void Run() { " ++ body ++ " return; } }")

compile :: String -> Either [Diagnostic] FrontendArtifacts
compile source = compileToCorePrep (CompilerInput "numeric-test.tala" source)

lexOne :: String -> Either [Diagnostic] [Token]
lexOne source = do
    tokens <- runLexer defaultLexer (LexerInput "numeric-test.tala" source)
    pure (filter ((/= EndOfFileToken) . tokenKind) tokens)

lexWithEof :: String -> Either [Diagnostic] [Token]
lexWithEof source = runLexer defaultLexer (LexerInput "numeric-test.tala" ("class N { int V() { " ++ source ++ " } }"))

parseExpressionModule :: [Token] -> Either [Diagnostic] Integer
parseExpressionModule tokens = do
    ParsedAST tree <- runParser defaultParser (ParserInput "numeric-test.tala" tokens)
    case syntaxDeclarations tree of
        [ TypeDeclaration {typeMembers = [FunctionDeclaration {declarationBody = Block [ExpressionStatement _ expression False]}]}
            ] ->
                case expression of
                    LiteralExpression _ (IntegerLiteral value) _ -> Right value
                    _ -> Left []
        _ -> Left []

coreLiteralHasType :: String -> Integer -> Bool
coreLiteralHasType typeName expected = case compileBody (typeName ++ " value = " ++ show expected ++ ";") of
    Right artifacts -> any matches (concatMap coreFunctionBody (coreModuleFunctions (artifactCore artifacts)))
    Left _ -> False
    where
        matches (CoreBind binding) =
            coreBindingType binding == namedType typeName
                && case coreBindingValue binding of
                    CoreLiteral (CoreInteger value) valueType -> value == expected && valueType == namedType typeName
                    _ -> False
        matches _ = False

numericBoolLowers :: Bool
numericBoolLowers = case compileBody "bool enabled = 1;" of
    Right artifacts -> any matches (concatMap coreFunctionBody (coreModuleFunctions (artifactCore artifacts)))
    Left _ -> False
    where
        matches (CoreBind binding) = case coreBindingValue binding of CoreLiteral (CoreBoolean True) valueType -> valueType == boolType; _ -> False
        matches _ = False

numericBranchCorePrep :: Bool
numericBranchCorePrep = case prepareCore source of
    Right prepared -> any branchIsBoolean (concatMap corePrepFunctionBlocks (corePrepModuleFunctions prepared))
    Left _ -> False
    where
        parameter = ResolvedName (SymbolId 2) (Identifier "condition")
        unit = CoreLiteral CoreUnit unitType
        source =
            CoreModule
                (QualifiedName [Identifier "NumericBranch"])
                [ CoreFunction
                    (ResolvedName (SymbolId 1) (Identifier "Run"))
                    [(parameter, intType)]
                    unitType
                    [CoreIf (CoreVariable parameter intType) [CoreReturn unit] [CoreReturn unit]]
                ]
        branchIsBoolean block = case corePrepBlockTerminator block of
            CorePrepBranch condition _ _ -> corePrepAtomTypeForTest condition == boolType
            _ -> False

numericLogicalCorePrep :: Bool
numericLogicalCorePrep = case prepareCore source of
    Right prepared ->
        any hasBooleanSeed instructions
            && any hasConditional blocks
            && any hasBooleanAssignment instructions
            && not (any eagerLogical instructions)
        where
            blocks = concatMap corePrepFunctionBlocks (corePrepModuleFunctions prepared)
            instructions = concatMap corePrepBlockInstructions blocks
    Left _ -> False
    where
        left = ResolvedName (SymbolId 2) (Identifier "left")
        right = ResolvedName (SymbolId 3) (Identifier "right")
        source =
            CoreModule
                (QualifiedName [Identifier "NumericLogical"])
                [ CoreFunction
                    (ResolvedName (SymbolId 1) (Identifier "Evaluate"))
                    [(left, intType), (right, namedType "float")]
                    boolType
                    [ CoreReturn
                        ( CorePrimitive
                            CoreLogicalAnd
                            [CoreVariable left intType, CoreVariable right (namedType "float")]
                            boolType
                        )
                    ]
                ]
        hasBooleanSeed (CorePrepBind name resultType True (CorePrepCopy (CorePrepLiteral (CoreBoolean False) literalType))) =
            "$shortcircuit" `isPrefixOf` identifierText (resolvedSpelling name)
                && resultType == boolType
                && literalType == boolType
        hasBooleanSeed _ = False
        hasConditional block = case corePrepBlockTerminator block of
            CorePrepBranch condition _ _ -> corePrepAtomTypeForTest condition == boolType
            _ -> False
        hasBooleanAssignment (CorePrepAssign name value) =
            "$shortcircuit" `isPrefixOf` identifierText (resolvedSpelling name)
                && corePrepAtomTypeForTest value == boolType
        hasBooleanAssignment _ = False
        eagerLogical (CorePrepBind _ _ _ (CorePrepPrimitive primitive _)) = primitive `elem` [CoreLogicalAnd, CoreLogicalOr]
        eagerLogical (CorePrepEvaluate (CorePrepPrimitive primitive _)) = primitive `elem` [CoreLogicalAnd, CoreLogicalOr]
        eagerLogical _ = False

corePrepAtomTypeForTest :: CorePrepAtom -> Type
corePrepAtomTypeForTest atom = case atom of
    CorePrepVariable _ valueType -> valueType
    CorePrepLiteral _ valueType -> valueType

coreCharacterValue :: Bool
coreCharacterValue = case compileBody "char letter = 'A';" of
    Right artifacts -> any matches (concatMap coreFunctionBody (coreModuleFunctions (artifactCore artifacts)))
    Left _ -> False
    where
        matches (CoreBind binding) = case coreBindingValue binding of
            CoreLiteral (CoreInteger 0x41) valueType -> valueType == namedType "char"
            _ -> False
        matches _ = False

coreFloatingSpelling :: Bool
coreFloatingSpelling = case compileBody "double precise = 1'000.250'000;" of
    Right artifacts -> any matches (concatMap coreFunctionBody (coreModuleFunctions (artifactCore artifacts)))
    Left _ -> False
    where
        matches (CoreBind binding) = case coreBindingValue binding of
            CoreLiteral (CoreFloating "1000.250000") valueType -> valueType == namedType "double"
            _ -> False
        matches _ = False
