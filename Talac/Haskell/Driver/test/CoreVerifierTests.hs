-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module CoreVerifierTests (coreVerifierTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Diagnostic

-- The optimizer is guarded by the same verifier before and after rewriting.
-- These focused malformed-tree cases make that boundary explicit and ensure
-- diagnostics continue to identify the invariant that was violated.
coreVerifierTests :: [(String, Bool)]
coreVerifierTests =
    [ ("Core verifier accepts the minimal unit module", accepted minimalUnitModule)
    , ("Core verifier rejects an empty module name", rejectedWith "TAC1001" emptyModuleName)
    , ("Core verifier rejects an empty module-name segment", rejectedWith "TAC1001" emptyModuleSegment)
    , ("Core verifier rejects duplicate function symbols", rejectedWith "TAC1002" duplicateFunctions)
    , ("Core verifier rejects an unresolved function result", rejectedWith "TAC1003" unresolvedFunctionResult)
    , ("Core verifier rejects duplicate parameter symbols", rejectedWith "TAC1004" duplicateParameters)
    , ("Core verifier rejects a missing value return", rejectedWith "TAC1005" missingValueReturn)
    , -- A loop that cannot be left never falls through to the end.
      ("Core verifier accepts a body that ends in a loop that cannot be left", accepted (endsInLoop (CoreWhile trueValue [])))
    , ("Core verifier accepts an endless do/while at the end of a body", accepted (endsInLoop (CoreDoWhile [] trueValue)))
    , ("Core verifier accepts an endless for at the end of a body", accepted (endsInLoop (CoreFor trueValue [] [])))
    ,
        ( "Core verifier rejects a body that ends in a loop a break leaves"
        , rejectedWith "TAC1005" (endsInLoop (CoreWhile trueValue [CoreIf trueValue [CoreBreak] []]))
        )
    ,
        ( "Core verifier rejects a body that ends in a for loop whose update breaks"
        , rejectedWith "TAC1005" (endsInLoop (CoreFor trueValue [] [CoreBreak]))
        )
    ,
        ( "Core verifier rejects a body that ends in a loop with a condition"
        , rejectedWith "TAC1005" (endsInLoop (CoreWhile (CoreLiteral (CoreBoolean False) boolType) []))
        )
    ,
        ( "a break of a nested loop does not leave the loop around it"
        , accepted (endsInLoop (CoreWhile trueValue [CoreWhile trueValue [CoreBreak]]))
        )
    , ("Core verifier rejects a zero function symbol", rejectedWith "TAC1006" zeroFunctionSymbol)
    , ("Core verifier rejects a negative parameter symbol", rejectedWith "TAC1006" negativeParameterSymbol)
    , ("Core verifier rejects an unresolved parameter type", rejectedWith "TAC1007" unresolvedParameterType)
    , ("Core verifier rejects a zero binding symbol", rejectedWith "TAC1008" zeroBindingSymbol)
    , ("Core verifier rejects an unresolved binding type", rejectedWith "TAC1009" unresolvedBindingType)
    , ("Core verifier rejects a redefined local symbol", rejectedWith "TAC1010" duplicateBinding)
    , ("Core verifier rejects a binding value type mismatch", rejectedWith "TAC1011" bindingTypeMismatch)
    , ("Core verifier rejects assignment to an undefined symbol", rejectedWith "TAC1012" undefinedAssignment)
    , ("Core verifier rejects assignment to immutable storage", rejectedWith "TAC1013" immutableAssignment)
    , ("Core verifier rejects assignment with the wrong value type", rejectedWith "TAC1014" assignmentTypeMismatch)
    , ("Core verifier rejects a zero assignment symbol", rejectedWith "TAC1015" zeroAssignmentSymbol)
    , ("Core verifier rejects a return value type mismatch", rejectedWith "TAC1016" returnTypeMismatch)
    , ("Core verifier rejects a String condition", rejectedWith "TAC1017" stringCondition)
    , ("Core verifier rejects an unresolved expression type", rejectedWith "TAC1018" unresolvedExpression)
    , ("Core verifier rejects a zero variable symbol", rejectedWith "TAC1019" zeroVariableSymbol)
    , ("Core verifier rejects an undefined variable", rejectedWith "TAC1020" undefinedVariable)
    , ("Core verifier rejects variable type disagreement", rejectedWith "TAC1021" variableTypeMismatch)
    , ("Core verifier rejects a call with too few arguments", rejectedWith "TAC1022" callArityMismatch)
    , ("Core verifier rejects a call argument type mismatch", rejectedWith "TAC1023" callArgumentMismatch)
    , ("Core verifier rejects a call result type mismatch", rejectedWith "TAC1024" callResultMismatch)
    , ("Core verifier rejects a non-callable target", rejectedWith "TAC1025" nonCallableTarget)
    , ("Core verifier rejects a primitive arity mismatch", rejectedWith "TAC1026" primitiveArityMismatch)
    , ("Core verifier rejects String arithmetic", rejectedWith "TAC1027" stringArithmetic)
    , ("Core verifier rejects mixed numeric operand types", rejectedWith "TAC1027" mixedArithmetic)
    , ("Core verifier rejects a primitive result mismatch", rejectedWith "TAC1028" primitiveResultMismatch)
    , ("Core verifier rejects an overflowing byte literal", rejectedWith "TAC1029" overflowingByteLiteral)
    , ("Core verifier rejects a floating payload on int", rejectedWith "TAC1029" floatingPayloadOnInt)
    , ("Core verifier rejects malformed floating spelling", rejectedWith "TAC1029" malformedFloatingSpelling)
    , ("Core verifier rejects duplicate closure captures", rejectedWith "TAC1030" duplicateCaptures)
    , ("Core verifier rejects duplicate closure parameters", rejectedWith "TAC1031" duplicateClosureParameters)
    , ("Core verifier rejects a closure missing a return", rejectedWith "TAC1032" closureMissingReturn)
    , ("Core verifier rejects closure parameter disagreement", rejectedWith "TAC1033" closureParameterMismatch)
    , ("Core verifier rejects closure callable arity mismatch", rejectedWith "TAC1034" closureArityMismatch)
    , ("Core verifier rejects closure result disagreement", rejectedWith "TAC1035" closureResultMismatch)
    , ("Core verifier rejects a non-callable closure type", rejectedWith "TAC1036" closureNotCallable)
    , ("Core verifier rejects a zero capture symbol", rejectedWith "TAC1037" zeroCaptureSymbol)
    , ("Core verifier rejects an unresolved capture type", rejectedWith "TAC1038" unresolvedCaptureType)
    , ("Core verifier rejects a capture initializer mismatch", rejectedWith "TAC1039" captureInitializerMismatch)
    , ("Core verifier accepts numeric conditions", accepted numericCondition)
    , ("Core verifier accepts boolean conditions", accepted booleanCondition)
    , ("Core verifier accepts Boolean equality", accepted (primitiveModule CoreEqual [boolValue, boolValue] boolType))
    , ("Core verifier accepts Boolean inequality", accepted (primitiveModule CoreNotEqual [boolValue, boolValue] boolType))
    ,
        ( "Core verifier rejects mixed Boolean equality"
        , rejectedWith "TAC1027" (primitiveModule CoreEqual [boolValue, intValue] boolType)
        )
    ,
        ( "Core verifier rejects Boolean ordering"
        , rejectedWith "TAC1027" (primitiveModule CoreLessThan [boolValue, boolValue] boolType)
        )
    ,
        ( "Core verifier rejects numeric Boolean equality result"
        , rejectedWith "TAC1028" (primitiveModule CoreEqual [boolValue, boolValue] intType)
        )
    , ("Core verifier accepts all-returning branches", accepted allReturningBranch)
    , ("Core verifier rejects break outside a loop", rejectedWith "TAC1045" (loopModule [CoreBreak]))
    , ("Core verifier rejects continue outside a loop", rejectedWith "TAC1046" (loopModule [CoreContinue]))
    , ("Core verifier accepts continue in a for body", accepted (forModule [CoreContinue] []))
    , ("Core verifier accepts break in a for update region", accepted (forModule [] [CoreBreak]))
    , ("Core verifier rejects continue in a for update region", rejectedWith "TAC1066" (forModule [] [CoreContinue]))
    ,
        ( "Core verifier rejects continue nested in a branch of a for update region"
        , rejectedWith "TAC1066" (forModule [] [CoreIf boolValue [CoreContinue] []])
        )
    ,
        ( "Core verifier accepts continue in a loop nested in a for update region"
        , accepted (forModule [] [CoreWhile boolValue [CoreContinue]])
        )
    ,
        ( "Core verifier does not report an outside-loop continue as an update continue"
        , not (rejectedWith "TAC1066" (loopModule [CoreContinue]))
        )
    , ("Core verifier accepts a well-typed direct call", accepted validDirectCall)
    , ("Core verifier accepts a well-typed closure", accepted validClosure)
    ]

resolved :: Int -> String -> ResolvedName
resolved symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

primitiveModule :: CorePrimitive -> [CoreExpression] -> Type -> CoreModule
primitiveModule primitive arguments result =
    coreModule [function mainName [] result [CoreReturn (CorePrimitive primitive arguments result)]]

moduleName :: QualifiedName
moduleName = QualifiedName [Identifier "Verifier", Identifier "Tests"]

mainName, helperName, valueName, captureValueName :: ResolvedName
mainName = resolved 1 "Main"
helperName = resolved 2 "Helper"
valueName = resolved 10 "value"
captureValueName = resolved 12 "captured"

unitValue, intValue, boolValue, stringValue :: CoreExpression
unitValue = CoreLiteral CoreUnit unitType
intValue = CoreLiteral (CoreInteger 1) intType
boolValue = CoreLiteral (CoreBoolean True) boolType
stringValue = CoreLiteral (CoreString "value") stringType

function :: ResolvedName -> [(ResolvedName, Type)] -> Type -> [CoreStatement] -> CoreFunction
function = CoreFunction

unitFunction :: ResolvedName -> [CoreStatement] -> CoreFunction
unitFunction functionName body = function functionName [] unitType (body ++ [CoreReturn unitValue])

coreModule :: [CoreFunction] -> CoreModule
coreModule = CoreModule moduleName

accepted :: CoreModule -> Bool
accepted moduleValue = verifyCore moduleValue == Right moduleValue

rejectedWith :: String -> CoreModule -> Bool
rejectedWith code moduleValue = case verifyCore moduleValue of
    Left diagnostics -> any ((== code) . diagnosticCode) diagnostics
    Right _ -> False

minimalUnitModule :: CoreModule
minimalUnitModule = coreModule [unitFunction mainName []]

emptyModuleName :: CoreModule
emptyModuleName = CoreModuleWithSources (QualifiedName []) [unitFunction mainName []] [] []

emptyModuleSegment :: CoreModule
emptyModuleSegment = CoreModuleWithSources (QualifiedName [Identifier "Verifier", Identifier ""]) [unitFunction mainName []] [] []

duplicateFunctions :: CoreModule
duplicateFunctions = coreModule [unitFunction mainName [], unitFunction mainName []]

unresolvedFunctionResult :: CoreModule
unresolvedFunctionResult = coreModule [function mainName [] ErrorType [CoreReturn unitValue]]

duplicateParameters :: CoreModule
duplicateParameters =
    coreModule [function mainName [(valueName, intType), (valueName, intType)] unitType [CoreReturn unitValue]]

missingValueReturn :: CoreModule
missingValueReturn = coreModule [function mainName [] intType []]

-- | A function that returns a value and whose body is the given loop alone.
endsInLoop :: CoreStatement -> CoreModule
endsInLoop loop = coreModule [function mainName [] intType [loop]]

trueValue :: CoreExpression
trueValue = CoreLiteral (CoreBoolean True) boolType

zeroFunctionSymbol :: CoreModule
zeroFunctionSymbol = coreModule [unitFunction (resolved 0 "Main") []]

negativeParameterSymbol :: CoreModule
negativeParameterSymbol =
    coreModule [function mainName [(resolved (-1) "value", intType)] unitType [CoreReturn unitValue]]

unresolvedParameterType :: CoreModule
unresolvedParameterType = coreModule [function mainName [(valueName, ErrorType)] unitType [CoreReturn unitValue]]

zeroBindingSymbol :: CoreModule
zeroBindingSymbol =
    coreModule [unitFunction mainName [CoreBind (CoreBinding (resolved 0 "value") intType False intValue)]]

unresolvedBindingType :: CoreModule
unresolvedBindingType =
    coreModule [unitFunction mainName [CoreBind (CoreBinding valueName ErrorType False intValue)]]

duplicateBinding :: CoreModule
duplicateBinding =
    coreModule
        [ unitFunction
            mainName
            [ CoreBind (CoreBinding valueName intType False intValue)
            , CoreBind (CoreBinding valueName intType False intValue)
            ]
        ]

bindingTypeMismatch :: CoreModule
bindingTypeMismatch =
    coreModule [unitFunction mainName [CoreBind (CoreBinding valueName boolType False intValue)]]

undefinedAssignment :: CoreModule
undefinedAssignment = coreModule [unitFunction mainName [CoreAssign valueName intValue]]

immutableAssignment :: CoreModule
immutableAssignment =
    coreModule
        [ unitFunction
            mainName
            [ CoreBind (CoreBinding valueName intType False intValue)
            , CoreAssign valueName intValue
            ]
        ]

assignmentTypeMismatch :: CoreModule
assignmentTypeMismatch =
    coreModule
        [ unitFunction
            mainName
            [ CoreBind (CoreBinding valueName intType True intValue)
            , CoreAssign valueName boolValue
            ]
        ]

zeroAssignmentSymbol :: CoreModule
zeroAssignmentSymbol = coreModule [unitFunction mainName [CoreAssign (resolved 0 "value") intValue]]

returnTypeMismatch :: CoreModule
returnTypeMismatch = coreModule [function mainName [] boolType [CoreReturn intValue]]

stringCondition :: CoreModule
stringCondition = coreModule [unitFunction mainName [CoreIf stringValue [] []]]

unresolvedExpression :: CoreModule
unresolvedExpression =
    coreModule [unitFunction mainName [CoreEvaluate (CoreLiteral (CoreInteger 1) ErrorType)]]

zeroVariableSymbol :: CoreModule
zeroVariableSymbol =
    coreModule [unitFunction mainName [CoreEvaluate (CoreVariable (resolved 0 "value") intType)]]

undefinedVariable :: CoreModule
undefinedVariable = coreModule [unitFunction mainName [CoreEvaluate (CoreVariable valueName intType)]]

variableTypeMismatch :: CoreModule
variableTypeMismatch =
    coreModule
        [ function
            mainName
            [(valueName, intType)]
            unitType
            [CoreEvaluate (CoreVariable valueName boolType), CoreReturn unitValue]
        ]

helperFunction :: CoreFunction
helperFunction = function helperName [(valueName, intType)] intType [CoreReturn (CoreVariable valueName intType)]

helperReference :: CoreExpression
helperReference = CoreVariable helperName (FunctionType [intType] intType)

callArityMismatch :: CoreModule
callArityMismatch =
    coreModule [unitFunction mainName [CoreEvaluate (CoreApply helperReference [] intType)], helperFunction]

callArgumentMismatch :: CoreModule
callArgumentMismatch =
    coreModule [unitFunction mainName [CoreEvaluate (CoreApply helperReference [boolValue] intType)], helperFunction]

callResultMismatch :: CoreModule
callResultMismatch =
    coreModule [unitFunction mainName [CoreEvaluate (CoreApply helperReference [intValue] boolType)], helperFunction]

nonCallableTarget :: CoreModule
nonCallableTarget =
    coreModule
        [ function
            mainName
            [(valueName, intType)]
            unitType
            [CoreEvaluate (CoreApply (CoreVariable valueName intType) [] intType), CoreReturn unitValue]
        ]

primitiveArityMismatch :: CoreModule
primitiveArityMismatch =
    coreModule [unitFunction mainName [CoreEvaluate (CorePrimitive CoreAdd [intValue] intType)]]

stringArithmetic :: CoreModule
stringArithmetic =
    coreModule [unitFunction mainName [CoreEvaluate (CorePrimitive CoreAdd [stringValue, stringValue] stringType)]]

mixedArithmetic :: CoreModule
mixedArithmetic =
    let longValue = CoreLiteral (CoreInteger 1) (namedType "long")
     in coreModule [unitFunction mainName [CoreEvaluate (CorePrimitive CoreAdd [intValue, longValue] intType)]]

primitiveResultMismatch :: CoreModule
primitiveResultMismatch =
    coreModule [unitFunction mainName [CoreEvaluate (CorePrimitive CoreAdd [intValue, intValue] boolType)]]

overflowingByteLiteral :: CoreModule
overflowingByteLiteral =
    coreModule [unitFunction mainName [CoreEvaluate (CoreLiteral (CoreInteger 128) (namedType "byte"))]]

floatingPayloadOnInt :: CoreModule
floatingPayloadOnInt =
    coreModule [unitFunction mainName [CoreEvaluate (CoreLiteral (CoreFloating "1.0") intType)]]

malformedFloatingSpelling :: CoreModule
malformedFloatingSpelling =
    coreModule [unitFunction mainName [CoreEvaluate (CoreLiteral (CoreFloating "1e") (namedType "float"))]]

closure :: [CoreCapture] -> [(ResolvedName, Type)] -> Type -> [CoreStatement] -> Type -> CoreExpression
closure = CoreClosure

validClosureValue :: CoreExpression
validClosureValue =
    closure
        []
        [(valueName, intType)]
        intType
        [CoreReturn (CoreVariable valueName intType)]
        (FunctionType [intType] intType)

duplicateCaptures :: CoreModule
duplicateCaptures =
    let capture = CoreCapture StrongCapture captureValueName intType intValue
        value = closure [capture, capture] [] unitType [CoreReturn unitValue] (FunctionType [] unitType)
     in coreModule [unitFunction mainName [CoreEvaluate value]]

duplicateClosureParameters :: CoreModule
duplicateClosureParameters =
    let value =
            closure
                []
                [(valueName, intType), (valueName, intType)]
                intType
                [CoreReturn intValue]
                (FunctionType [intType, intType] intType)
     in coreModule [unitFunction mainName [CoreEvaluate value]]

closureMissingReturn :: CoreModule
closureMissingReturn =
    let value = closure [] [] intType [] (FunctionType [] intType)
     in coreModule [unitFunction mainName [CoreEvaluate value]]

closureParameterMismatch :: CoreModule
closureParameterMismatch =
    let value = closure [] [(valueName, boolType)] unitType [CoreReturn unitValue] (FunctionType [intType] unitType)
     in coreModule [unitFunction mainName [CoreEvaluate value]]

closureArityMismatch :: CoreModule
closureArityMismatch =
    let value = closure [] [(valueName, intType)] unitType [CoreReturn unitValue] (FunctionType [] unitType)
     in coreModule [unitFunction mainName [CoreEvaluate value]]

closureResultMismatch :: CoreModule
closureResultMismatch =
    let value = closure [] [] unitType [CoreReturn unitValue] (FunctionType [] intType)
     in coreModule [unitFunction mainName [CoreEvaluate value]]

closureNotCallable :: CoreModule
closureNotCallable =
    let value = closure [] [] unitType [CoreReturn unitValue] intType
     in coreModule [unitFunction mainName [CoreEvaluate value]]

zeroCaptureSymbol :: CoreModule
zeroCaptureSymbol =
    let capture = CoreCapture StrongCapture (resolved 0 "captured") intType intValue
        value = closure [capture] [] unitType [CoreReturn unitValue] (FunctionType [] unitType)
     in coreModule [unitFunction mainName [CoreEvaluate value]]

unresolvedCaptureType :: CoreModule
unresolvedCaptureType =
    let capture = CoreCapture StrongCapture captureValueName ErrorType intValue
        value = closure [capture] [] unitType [CoreReturn unitValue] (FunctionType [] unitType)
     in coreModule [unitFunction mainName [CoreEvaluate value]]

captureInitializerMismatch :: CoreModule
captureInitializerMismatch =
    let capture = CoreCapture StrongCapture captureValueName boolType intValue
        value = closure [capture] [] unitType [CoreReturn unitValue] (FunctionType [] unitType)
     in coreModule [unitFunction mainName [CoreEvaluate value]]

numericCondition :: CoreModule
numericCondition = coreModule [unitFunction mainName [CoreIf intValue [] []]]

booleanCondition :: CoreModule
booleanCondition = coreModule [unitFunction mainName [CoreIf boolValue [] []]]

allReturningBranch :: CoreModule
allReturningBranch =
    coreModule
        [ function
            mainName
            [(valueName, boolType)]
            intType
            [ CoreIf
                (CoreVariable valueName boolType)
                [CoreReturn (CoreLiteral (CoreInteger 1) intType)]
                [CoreReturn (CoreLiteral (CoreInteger 2) intType)]
            ]
        ]

validDirectCall :: CoreModule
validDirectCall =
    coreModule
        [ function mainName [] intType [CoreReturn (CoreApply helperReference [intValue] intType)]
        , helperFunction
        ]

validClosure :: CoreModule
validClosure = coreModule [unitFunction mainName [CoreEvaluate validClosureValue]]

loopModule :: [CoreStatement] -> CoreModule
loopModule body = coreModule [unitFunction mainName body]

forModule :: [CoreStatement] -> [CoreStatement] -> CoreModule
forModule body update = loopModule [CoreFor boolValue body update]
