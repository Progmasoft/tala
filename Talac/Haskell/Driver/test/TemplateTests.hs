-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
module TemplateTests (templateTests) where

import Data.Bits (shiftL)
import Data.List (isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.CorePrep.Wire
import Progmasoft.Tala.Core.Template
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.TemplateValue

templateTests :: [(String, Bool)]
templateTests =
    parserAndTypeTests
        ++ evaluationTests
        ++ shapeTests
        ++ validationTests
        ++ metricTests
        ++ substitutionTests
        ++ identityTests
        ++ wireTests

parserAndTypeTests :: [(String, Bool)]
parserAndTypeTests =
    [ ("fixed array literal reaches typed AST", typedReturn "[int; 3]" == Just (fixed intType 3))
    , ("fixed array arithmetic is canonicalized", typedReturn "[int; 1 + 2 * 3]" == Just (fixed intType 7))
    , ("fixed array parentheses affect evaluation", typedReturn "[int; (1 + 2) * 3]" == Just (fixed intType 9))
    , ("fixed array hexadecimal size is accepted", typedReturn "[int; 0x10]" == Just (fixed intType 16))
    , ("fixed array binary size is accepted", typedReturn "[int; 0b1000]" == Just (fixed intType 8))
    , ("fixed array digit separators are accepted", typedReturn "[int; 1'024]" == Just (fixed intType 1024))
    , ("zero-sized fixed array is representable", typedReturn "[int; 0]" == Just (fixed intType 0))
    , ("negative fixed array is diagnosed", compileReturn "[int; -1]" `hasCode` "TAT0016")
    , ("Boolean fixed array size is diagnosed", compileReturn "[int; true]" `hasCode` "TAT0016")
    , ("unresolved fixed array size is diagnosed", compileReturn "[int; Size]" `hasCode` "TAT0016")
    , ("division by zero in fixed size is diagnosed", compileReturn "[int; 4 / 0]" `hasCode` "TAT0016")
    , ("floor division by zero in fixed size is diagnosed", compileReturn "[int; 4 // 0]" `hasCode` "TAT0016")
    , ("remainder by zero in fixed size is diagnosed", compileReturn "[int; 4 % 0]" `hasCode` "TAT0016")
    ,
        ( "oversized power in fixed size is rejected without host-sized allocation"
        , compileReturn "[int; 2 ** 9223372036854775807]" `hasCode` "TAT0016"
        )
    ,
        ( "zero power in fixed size bypasses an enormous exponent"
        , typedReturn "[int; 0 ** 9223372036854775807]" == Just (fixed intType 0)
        )
    ,
        ( "unit power in fixed size bypasses an enormous exponent"
        , typedReturn "[int; 1 ** 9223372036854775807]" == Just (fixed intType 1)
        )
    , ("over-limit power in fixed size is diagnosed", compileReturn "[int; 2 ** 65536]" `hasCode` "TAT0016")
    , ("over-limit shift in fixed size is diagnosed", compileReturn "[int; 1 << 65536]" `hasCode` "TAT0016")
    , ("zero shift in fixed size bypasses a huge intermediate", typedReturn "[int; 0 << 65536]" == Just (fixed intType 0))
    , ("huge right shift in fixed size saturates", typedReturn "[int; 5 >> 65536]" == Just (fixed intType 0))
    , ("runtime call cannot be a template value", compileReturn "[int; Size()]" `hasCode` "TAP0018")
    , ("explicit numeric template argument is a value", typedReturn "Buffer<32>" == Just (applied "Buffer" [value 32]))
    ,
        ( "explicit arithmetic template argument is evaluated"
        , typedReturn "Buffer<4 * 8>" == Just (applied "Buffer" [value 32])
        )
    , ("explicit Boolean template argument is retained", typedReturn "Flag<true>" == Just (applied "Flag" [boolean True]))
    , ("explicit character template argument is retained", typedReturn "Code<'A'>" == Just (applied "Code" [character 65]))
    ,
        ( "mixed generic arguments preserve order"
        , typedReturn "Matrix<int, 3>" == Just (applied "Matrix" [typeArg intType, value 3])
        )
    ,
        ( "value before type preserves order"
        , typedReturn "Matrix<3, int>" == Just (applied "Matrix" [value 3, typeArg intType])
        )
    ,
        ( "nested fixed array remains a type argument"
        , typedReturn "Box<[int; 4]>" == Just (applied "Box" [typeArg (fixed intType 4)])
        )
    , -- Adjacent `[[` starts a raw string at the lexical layer. A separating
      -- space keeps nested collection brackets in the type grammar.
      ("fixed array of dynamic arrays preserves both shapes", typedReturn "[ [int]; 2]" == Just (fixed (dynamic intType) 2))
    , ("dynamic array of fixed arrays preserves both shapes", typedReturn "[ [int; 2]]" == Just (dynamic (fixed intType 2)))
    ]

evaluationTests :: [(String, Bool)]
evaluationTests =
    [ ("integer template literal evaluates", evaluateTemplateValue (integerSyntax 42) == Right (IntegerTemplateValue 42))
    ,
        ( "character template literal evaluates"
        , evaluateTemplateValue (characterSyntax 65) == Right (CharacterTemplateValue 65)
        )
    , ("Boolean template literal evaluates", evaluateTemplateValue (booleanSyntax True) == Right (BooleanTemplateValue True))
    ,
        ( "unary plus evaluates exactly"
        , evaluateTemplateValue (unary UnaryPlus (integerSyntax 9)) == Right (IntegerTemplateValue 9)
        )
    ,
        ( "unary negate evaluates exactly"
        , evaluateTemplateValue (unary UnaryNegate (integerSyntax 9)) == Right (IntegerTemplateValue (-9))
        )
    ,
        ( "logical not produces Boolean identity"
        , evaluateTemplateValue (unary LogicalNot (integerSyntax 0)) == Right (BooleanTemplateValue True)
        )
    ,
        ( "bitwise not evaluates exactly"
        , evaluateTemplateValue (unary BitwiseNot (integerSyntax 0)) == Right (IntegerTemplateValue (-1))
        )
    , ("addition evaluates exactly", binaryValue Add 20 22 == Right (IntegerTemplateValue 42))
    , ("subtraction evaluates exactly", binaryValue Subtract 50 8 == Right (IntegerTemplateValue 42))
    , ("multiplication evaluates exactly", binaryValue Multiply 6 7 == Right (IntegerTemplateValue 42))
    , ("division truncates toward zero", binaryValue Divide (-7) 2 == Right (IntegerTemplateValue (-3)))
    , ("rounded division moves positive halves away from zero", binaryValue FloorDivide 7 2 == Right (IntegerTemplateValue 4))
    ,
        ( "rounded division moves negative halves away from zero"
        , binaryValue FloorDivide (-7) 2 == Right (IntegerTemplateValue (-4))
        )
    , ("rounded division chooses the nearest integer", binaryValue FloorDivide 7 3 == Right (IntegerTemplateValue 2))
    , ("remainder follows dividend", binaryValue Remainder (-7) 2 == Right (IntegerTemplateValue (-1)))
    , ("power evaluates exactly", binaryValue Power 3 4 == Right (IntegerTemplateValue 81))
    ,
        ( "compile-time integer limit includes its largest positive value"
        , evaluateTemplateValue (integerSyntax (compileTimeIntegerMagnitude - 1))
            == Right (IntegerTemplateValue (compileTimeIntegerMagnitude - 1))
        )
    ,
        ( "compile-time integer limit rejects its first positive overflow"
        , evaluateTemplateValue (integerSyntax compileTimeIntegerMagnitude) == Left TemplateValueEvaluationLimitExceeded
        )
    ,
        ( "zero power handles a maximum-width exponent directly"
        , binaryValue Power 0 (2 ^ (63 :: Int) - 1) == Right (IntegerTemplateValue 0)
        )
    ,
        ( "one power handles a maximum-width exponent directly"
        , binaryValue Power 1 (2 ^ (63 :: Int) - 1) == Right (IntegerTemplateValue 1)
        )
    ,
        ( "large powers stop at the compile-time integer limit"
        , binaryValue Power 2 (2 ^ (63 :: Int) - 1) == Left TemplateValueEvaluationLimitExceeded
        )
    ,
        ( "power accepts its largest representable intermediate"
        , binaryValue Power 2 65535 == Right (IntegerTemplateValue (2 ^ (65535 :: Int)))
        )
    ,
        ( "power rejects the first over-limit intermediate"
        , binaryValue Power 2 65536 == Left TemplateValueEvaluationLimitExceeded
        )
    , ("shift-left evaluates exactly", binaryValue ShiftLeft 3 4 == Right (IntegerTemplateValue 48))
    , ("shift-right evaluates exactly", binaryValue ShiftRight 48 4 == Right (IntegerTemplateValue 3))
    ,
        ( "left shift accepts its largest representable intermediate"
        , binaryValue ShiftLeft 1 65535 == Right (IntegerTemplateValue (2 ^ (65535 :: Int)))
        )
    ,
        ( "left shift rejects the first over-limit result"
        , binaryValue ShiftLeft 1 65536 == Left TemplateValueEvaluationLimitExceeded
        )
    ,
        ( "zero left shift handles a maximum-width count directly"
        , binaryValue ShiftLeft 0 (2 ^ (63 :: Int) - 1) == Right (IntegerTemplateValue 0)
        )
    ,
        ( "large left shifts stop at the compile-time integer limit"
        , binaryValue ShiftLeft 1 (2 ^ (63 :: Int) - 1) == Left TemplateValueEvaluationLimitExceeded
        )
    ,
        ( "large arithmetic right shift saturates to the sign value"
        , binaryValue ShiftRight (-3) (2 ^ (63 :: Int) - 1) == Right (IntegerTemplateValue (-1))
        )
    , ("bitwise and evaluates exactly", binaryValue BitwiseAnd 14 11 == Right (IntegerTemplateValue 10))
    , ("bitwise xor evaluates exactly", binaryValue BitwiseXor 14 11 == Right (IntegerTemplateValue 5))
    , ("bitwise or evaluates exactly", binaryValue BitwiseOr 8 3 == Right (IntegerTemplateValue 11))
    , ("negative integer power has a precise error", binaryValue Power 2 (-1) == Left (TemplateValueNegativeExponent (-1)))
    , ("less-than produces Boolean", binaryValue LessThan 1 2 == Right (BooleanTemplateValue True))
    , ("less-equal produces Boolean", binaryValue LessEqual 2 2 == Right (BooleanTemplateValue True))
    , ("greater-than produces Boolean", binaryValue GreaterThan 3 2 == Right (BooleanTemplateValue True))
    , ("greater-equal produces Boolean", binaryValue GreaterEqual 3 3 == Right (BooleanTemplateValue True))
    , ("integer equality produces Boolean", binaryValue Equal 3 3 == Right (BooleanTemplateValue True))
    , ("integer inequality produces Boolean", binaryValue NotEqual 3 4 == Right (BooleanTemplateValue True))
    , ("logical and accepts numeric Boolean context", binaryValue LogicalAnd 1 2 == Right (BooleanTemplateValue True))
    , ("logical or accepts numeric Boolean context", binaryValue LogicalOr 0 2 == Right (BooleanTemplateValue True))
    , ("ordinary division by zero has a precise error", binaryValue Divide 1 0 == Left TemplateValueDivisionByZero)
    , ("floor division by zero has a precise error", binaryValue FloorDivide 1 0 == Left TemplateValueFloorDivisionByZero)
    , ("remainder by zero has a precise error", binaryValue Remainder 1 0 == Left TemplateValueRemainderByZero)
    ,
        ( "fixed array accepts character as scalar size"
        , evaluateFixedArraySize (characterSyntax 8) == Right (IntegerTemplateValue 8)
        )
    , ("fixed array rejects Boolean result", isIntegerRequirement (evaluateFixedArraySize (booleanSyntax True)))
    ,
        ( "fixed array rejects negative result"
        , evaluateFixedArraySize (integerSyntax (-2)) == Left (TemplateValueNegativeArraySize (-2))
        )
    , ("qualified unresolved constant keeps its name", unresolvedNameError)
    ]

shapeTests :: [(String, Bool)]
shapeTests =
    [ ("built-in array classifies separately", classifyArrayType (builtin intType) == Just (BuiltinArrayShape intType))
    , ("dynamic System.Array classifies", classifyArrayType (dynamic intType) == Just (DynamicArrayShape intType))
    , ("fixed System.Array classifies", classifyArrayType (fixed intType 4) == Just (FixedArrayShape intType 4))
    , ("user Array spelling is not System.Array", classifyArrayType (applied "Array" [typeArg intType]) == Nothing)
    , ("fixed array requires integer value", classifyArrayType (systemArray [typeArg intType, boolean True]) == Nothing)
    , ("fixed array requires leading type", classifyArrayType (systemArray [value 4, typeArg intType]) == Nothing)
    ,
        ( "three-argument System.Array is malformed"
        , classifyArrayType (systemArray [typeArg intType, value 4, value 5]) == Nothing
        )
    ,
        ( "built-in array cannot carry a size"
        , classifyArrayType (NamedType (QualifiedName [Identifier "[]"]) [typeArg intType, value 4]) == Nothing
        )
    ]

validationTests :: [(String, Bool)]
validationTests =
    [ ("concrete fixed array validates", null (validateTemplateType 128 (fixed intType 16)))
    , ("nested concrete type validates", null (validateTemplateType 128 nestedConcrete))
    , ("empty qualified name is rejected", hasIssue TemplateEmptyQualifiedName (NamedType (QualifiedName []) []))
    ,
        ( "empty qualified part is rejected"
        , hasIssue TemplateEmptyNamePart (NamedType (QualifiedName [Identifier "System", Identifier ""]) [])
        )
    , ("zero type parameter id is rejected", hasIssue TemplateInvalidParameter (TypeVariable (parameter 0 "T")))
    , ("empty type parameter spelling is rejected", hasIssue TemplateInvalidParameter (TypeVariable (parameter 1 "")))
    ,
        ( "zero value parameter id is rejected"
        , hasIssue TemplateInvalidParameter (applied "Buffer" [ValueTemplateArgument (TemplateValueParameter (parameter 0 "N"))])
        )
    , ("surrogate character is rejected", hasIssue TemplateInvalidCharacter (applied "Code" [character 0xd800]))
    , ("scalar above Unicode range is rejected", hasIssue TemplateInvalidCharacter (applied "Code" [character 0x110000]))
    , ("negative character is rejected", hasIssue TemplateInvalidCharacter (applied "Code" [character (-1)]))
    , ("negative fixed size is rejected structurally", hasIssue TemplateNegativeArraySize (fixed intType (-1)))
    , ("System.Array with no arguments is malformed", hasIssue TemplateMalformedArrayFamily (systemArray []))
    ,
        ( "System.Array with two type arguments is malformed"
        , hasIssue TemplateMalformedArrayFamily (systemArray [typeArg intType, typeArg intType])
        )
    ,
        ( "built-in array with no element is malformed"
        , hasIssue TemplateMalformedArrayFamily (NamedType (QualifiedName [Identifier "[]"]) [])
        )
    , ("depth zero admits root scalar", null (validateTemplateType 0 intType))
    ,
        ( "depth zero rejects nested argument"
        , any
            ((== TemplateDepthExceeded) . templateIssueKind)
            (validateTemplateType 0 (applied "Box" [typeArg intType]))
        )
    , ("depth one admits one nested argument", null (validateTemplateType 1 (applied "Box" [typeArg intType])))
    , ("Core verifier rejects malformed specialization keys", coreVerifierRejectsMalformed)
    , ("CorePrep verifier rejects malformed specialization keys", corePrepVerifierRejectsMalformed)
    ]
    where
        hasIssue kind valueType = any ((== kind) . templateIssueKind) (validateTemplateType 128 valueType)

metricTests :: [(String, Bool)]
metricTests =
    [ ("scalar metrics contain one type node", measureTemplateType intType == TemplateMetrics 1 0 0 0 0)
    , ("dynamic array metrics count type argument", measureTemplateType (dynamic intType) == TemplateMetrics 2 1 0 0 1)
    , ("fixed array metrics count type and value", measureTemplateType (fixed intType 4) == TemplateMetrics 2 1 1 0 1)
    , ("type variable increments parameter count", measureTemplateType typeParameter == TemplateMetrics 1 0 0 1 0)
    , ("value parameter increments parameter count", measureTemplateType valueParameter == TemplateMetrics 2 1 1 1 1)
    , ("function metrics include parameters and result", measureTemplateType functionTemplate == TemplateMetrics 5 1 1 0 2)
    , ("nested template records maximum depth", templateMaximumDepth (measureTemplateType nestedConcrete) == 3)
    , ("nested template counts all type arguments", templateTypeArguments (measureTemplateType nestedConcrete) == 3)
    , ("nested template counts its value", templateValueArguments (measureTemplateType nestedConcrete) == 1)
    ]

substitutionTests :: [(String, Bool)]
substitutionTests =
    [ ("type parameter is substituted", substitute [typeBinding] [] typeParameter == stringType)
    , ("value parameter is substituted", substitute [] [valueBinding] valueParameter == fixed intType 32)
    ,
        ( "type and value parameters substitute together"
        , substitute [typeBinding] [valueBinding] genericArray == fixed stringType 32
        )
    , ("missing type binding is preserved", substitute [] [valueBinding] genericArray == fixed typeParameter 32)
    ,
        ( "missing value binding is preserved"
        , substitute [typeBinding] [] genericArray
            == systemArray [typeArg stringType, ValueTemplateArgument (TemplateValueParameter sizeParameter)]
        )
    ,
        ( "substitution descends through function parameters"
        , substitute [typeBinding] [valueBinding] genericFunction == concreteFunction
        )
    , ("substitution does not change unrelated concrete type", substitute [typeBinding] [valueBinding] intType == intType)
    , ("collect finds both parameter kinds", collectTemplateParameters genericArray == [SymbolId 10, SymbolId 20])
    , ("collect deduplicates repeated parameters", collectTemplateParameters repeatedParameters == [SymbolId 10])
    , ("concrete type reports concrete", concreteTemplateType nestedConcrete)
    , ("generic type reports non-concrete", not (concreteTemplateType genericArray))
    ]

identityTests :: [(String, Bool)]
identityTests =
    [ ("identity is deterministic", renderTemplateIdentity nestedConcrete == renderTemplateIdentity nestedConcrete)
    , ("dynamic and fixed arrays have different identity", identityDifferent (dynamic intType) (fixed intType 0))
    , ("fixed sizes have different identity", identityDifferent (fixed intType 4) (fixed intType 5))
    ,
        ( "type and value argument kinds have different identity"
        , identityDifferent (applied "Box" [typeArg intType]) (applied "Box" [value 0])
        )
    ,
        ( "argument order affects identity"
        , identityDifferent (applied "Mix" [typeArg intType, value 4]) (applied "Mix" [value 4, typeArg intType])
        )
    ,
        ( "qualified boundaries affect identity"
        , identityDifferent
            (NamedType (QualifiedName [Identifier "A.B"]) [])
            (NamedType (QualifiedName [Identifier "A", Identifier "B"]) [])
        )
    , ("parameter ids affect identity", identityDifferent (TypeVariable (parameter 1 "T")) (TypeVariable (parameter 2 "T")))
    ,
        ( "parameter spelling affects identity"
        , identityDifferent (TypeVariable (parameter 1 "T")) (TypeVariable (parameter 1 "U"))
        )
    ,
        ( "integer and character identities differ"
        , identityDifferent (applied "Value" [value 65]) (applied "Value" [character 65])
        )
    , ("Boolean values affect identity", identityDifferent (applied "Flag" [boolean False]) (applied "Flag" [boolean True]))
    , ("identity includes function result", identityDifferent (FunctionType [] intType) (FunctionType [] stringType))
    ,
        ( "identity includes every function parameter"
        , identityDifferent (FunctionType [intType] intType) (FunctionType [intType, intType] intType)
        )
    , ("rendered identity exposes value kind", "value:i:4" `isInfixOf` renderTemplateIdentity (fixed intType 4))
    ,
        ( "rendered identity exposes qualified name lengths"
        , "6:System.5:Array" `isInfixOf` renderTemplateIdentity (fixed intType 4)
        )
    ]

wireTests :: [(String, Bool)]
wireTests =
    [ ("Core v10 round-trips fixed array type", coreTypeRoundTrip (fixed intType 4096))
    , ("Core v10 round-trips Boolean template value", coreTypeRoundTrip (applied "Flag" [boolean True]))
    , ("Core v10 round-trips character template value", coreTypeRoundTrip (applied "Code" [character 0x10ffff]))
    , ("Core v10 round-trips template value parameter", coreTypeRoundTrip valueParameter)
    ,
        ( "Core v10 round-trips mixed arguments"
        , coreTypeRoundTrip (applied "Mix" [value (-3), typeArg stringType, boolean False])
        )
    , ("CorePrep v6 round-trips fixed array type", corePrepTypeRoundTrip (fixed intType 4096))
    , ("CorePrep v6 round-trips Boolean template value", corePrepTypeRoundTrip (applied "Flag" [boolean True]))
    , ("CorePrep v6 round-trips character template value", corePrepTypeRoundTrip (applied "Code" [character 0x10ffff]))
    , ("CorePrep v6 round-trips template value parameter", corePrepTypeRoundTrip valueParameter)
    ,
        ( "CorePrep v6 round-trips mixed arguments"
        , corePrepTypeRoundTrip (applied "Mix" [value (-3), typeArg stringType, boolean False])
        )
    ]

typedReturn :: String -> Maybe Type
typedReturn returnType = case compileReturn returnType of
    Right artifacts -> case syntaxDeclarations (typedSyntaxTree (artifactTypedAST artifacts)) of
        [TypeDeclaration {typeMembers = [FunctionDeclaration {declarationParameters = [parameterValue]}]}] ->
            Just (parameterAnnotation parameterValue)
        _ -> Nothing
    Left _ -> Nothing

compileReturn :: String -> Either [Diagnostic] FrontendArtifacts
compileReturn returnType =
    compileToCorePrep
        (CompilerInput "template-test.tala" ("class App { void Use(_ " ++ returnType ++ " value) { return; } }"))

hasCode :: Either [Diagnostic] a -> String -> Bool
hasCode result code = case result of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

spanValue :: SourceSpan
spanValue = SourceSpan "template-test.tala" (SourcePosition 1 1) (SourcePosition 1 2)

compileTimeIntegerMagnitude :: Integer
compileTimeIntegerMagnitude = 1 `shiftL` 65536

integerSyntax :: Integer -> TemplateValueSyntax
integerSyntax = TemplateIntegerSyntax spanValue

characterSyntax :: Integer -> TemplateValueSyntax
characterSyntax = TemplateCharacterSyntax spanValue

booleanSyntax :: Bool -> TemplateValueSyntax
booleanSyntax = TemplateBooleanSyntax spanValue

unary :: UnaryOperator -> TemplateValueSyntax -> TemplateValueSyntax
unary = TemplateUnarySyntax spanValue

binaryValue :: BinaryOperator -> Integer -> Integer -> Either TemplateValueError TemplateValue
binaryValue operator left right = evaluateTemplateValue (TemplateBinarySyntax spanValue operator (integerSyntax left) (integerSyntax right))

isIntegerRequirement :: Either TemplateValueError TemplateValue -> Bool
isIntegerRequirement result = case result of
    Left (TemplateValueRequiresInteger _) -> True
    _ -> False

unresolvedNameError :: Bool
unresolvedNameError = case evaluateTemplateValue (TemplateNameSyntax spanValue (QualifiedName [Identifier "Config", Identifier "Size"])) of
    Left (TemplateValueIsNotConstant (QualifiedName [Identifier "Config", Identifier "Size"])) -> True
    _ -> False

typeArg :: Type -> TemplateArgument
typeArg = TypeTemplateArgument

value :: Integer -> TemplateArgument
value = ValueTemplateArgument . IntegerTemplateValue

boolean :: Bool -> TemplateArgument
boolean = ValueTemplateArgument . BooleanTemplateValue

character :: Integer -> TemplateArgument
character = ValueTemplateArgument . CharacterTemplateValue

applied :: String -> [TemplateArgument] -> Type
applied name = NamedType (QualifiedName [Identifier name])

systemArray :: [TemplateArgument] -> Type
systemArray = NamedType (QualifiedName [Identifier "System", Identifier "Array"])

builtin :: Type -> Type
builtin element = NamedType (QualifiedName [Identifier "[]"]) [typeArg element]

dynamic :: Type -> Type
dynamic element = systemArray [typeArg element]

fixed :: Type -> Integer -> Type
fixed element size = systemArray [typeArg element, value size]

parameter :: Int -> String -> ResolvedName
parameter symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

typeParameter :: Type
typeParameter = TypeVariable (parameter 10 "T")

sizeParameter :: ResolvedName
sizeParameter = parameter 20 "N"

valueParameter :: Type
valueParameter = systemArray [typeArg intType, ValueTemplateArgument (TemplateValueParameter sizeParameter)]

genericArray :: Type
genericArray = systemArray [typeArg typeParameter, ValueTemplateArgument (TemplateValueParameter sizeParameter)]

genericFunction :: Type
genericFunction = FunctionType [genericArray, typeParameter] typeParameter

concreteFunction :: Type
concreteFunction = FunctionType [fixed stringType 32, stringType] stringType

nestedConcrete :: Type
nestedConcrete = applied "Outer" [typeArg (dynamic (fixed intType 4))]

functionTemplate :: Type
functionTemplate = FunctionType [fixed intType 4, stringType] boolType

repeatedParameters :: Type
repeatedParameters = FunctionType [typeParameter, typeParameter] typeParameter

typeBinding :: (SymbolId, Type)
typeBinding = (SymbolId 10, stringType)

valueBinding :: (SymbolId, TemplateValue)
valueBinding = (SymbolId 20, IntegerTemplateValue 32)

substitute :: [(SymbolId, Type)] -> [(SymbolId, TemplateValue)] -> Type -> Type
substitute = substituteTemplateType

identityDifferent :: Type -> Type -> Bool
identityDifferent left right = renderTemplateIdentity left /= renderTemplateIdentity right

coreTypeRoundTrip :: Type -> Bool
coreTypeRoundTrip valueType =
    let function = CoreFunction (parameter 1 "Value") [] valueType []
        moduleValue = CoreModuleWithSources (QualifiedName [Identifier "Template"]) [function] [] []
     in (encodeCore defaultCoreWireLimits moduleValue >>= decodeCore defaultCoreWireLimits) == Right moduleValue

corePrepTypeRoundTrip :: Type -> Bool
corePrepTypeRoundTrip valueType =
    let atom = CorePrepLiteral CoreUnit unitType
        block = CorePrepBlock 0 [] (CorePrepReturn atom)
        function = CorePrepFunction (parameter 1 "Value") "" [] valueType 0 [block]
        moduleValue = CorePrepModule (QualifiedName [Identifier "Template"]) [function] []
     in (encodeCorePrep moduleValue >>= decodeCorePrep) == Right moduleValue

coreVerifierRejectsMalformed :: Bool
coreVerifierRejectsMalformed =
    let function = CoreFunction (parameter 1 "Value") [] (fixed intType (-1)) []
        moduleValue = CoreModuleWithSources (QualifiedName [Identifier "Template"]) [function] [] []
     in hasCode (verifyCore moduleValue) "TAC1040"

corePrepVerifierRejectsMalformed :: Bool
corePrepVerifierRejectsMalformed =
    let atom = CorePrepLiteral CoreUnit unitType
        block = CorePrepBlock 0 [] (CorePrepReturn atom)
        function = CorePrepFunction (parameter 1 "Value") "" [] (fixed intType (-1)) 0 [block]
        moduleValue = CorePrepModule (QualifiedName [Identifier "Template"]) [function] []
     in hasCode (verifyCorePrep moduleValue) "TAC0024"
