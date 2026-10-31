-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Tests for the callable that remembers its result, 'CoreMemoize'.

It is the suspended computation of evaluation by need: a callable without
parameters that calls its operand the first time it is called, keeps what
the operand returned, and returns that again from then on, to every holder
of it. The tests here build Core by hand, so that they state what the
primitive is without the lowering that produces it: what the verifiers
accept, that both wire formats carry it, that the optimizer neither removes
a needed computation nor repeats one, and what the reference evaluator
computes and how often.

"LazyEvaluationTests" checks the lowering that uses the primitive.
-}
module MemoizeTests (memoizeTests) where

import CoreInterpreter
import Data.List (isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.CorePrep.Wire
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic

memoizeTests :: [(String, Bool)]
memoizeTests =
    [ -- What the Core verifier accepts.
      ("a remembered callable without parameters verifies", accepted (returning (callOf remembered)))
    , ("a remembered Boolean result verifies", accepted booleanModule)
    , ("remembering a callable with a parameter is refused", rejectedWith "TAC1073" (holding (memoize parameterized)))
    , ("remembering a callable that returns nothing is refused", rejectedWith "TAC1073" (holding (memoize unitCallable)))
    , ("remembering a callable that returns a String is refused", rejectedWith "TAC1073" (holding (memoize stringCallable)))
    , ("remembering a number is refused", rejectedWith "TAC1073" (holding (CorePrimitive CoreMemoize [integer 1] intType)))
    , ("remembering takes one operand", rejectedWith "TAC1026" (holding (CorePrimitive CoreMemoize [stepClosure, stepClosure] intCallable)))
    , ("a remembered callable has the type of its operand", rejectedWith "TAC1028" (holding (CorePrimitive CoreMemoize [stepClosure] boolCallable)))
    , -- Both wire formats carry it, and CorePrep accepts what Core does.
      ("the Core wire format carries a remembered callable", coreRoundTrip sharedModule)
    , ("CorePrep accepts a remembered callable", preparedAndVerified sharedModule)
    , ("the CorePrep wire format carries a remembered callable", corePrepRoundTrip sharedModule)
    , ("CorePrep refuses to remember a number", corePrepRejects "TAC0025" (malformedCorePrep intType))
    , ("CorePrep refuses to remember a callable with a parameter", corePrepRejects "TAC0025" (malformedCorePrep (FunctionType [intType] intType)))
    , -- What it computes, and how often. The budgets are those of one
      -- computation of Step(100): a second one does not fit.
      ("a remembered callable returns what its operand returns", run sharedModule 5 == Just 15)
    , ("three calls of one remembered callable compute once", runWithin 500 sharedModule 100 == Just 300)
    , ("three calls of the callable itself compute three times", runWithin 500 repeatedModule 100 == Nothing)
    , ("the callable itself, called three times, gives the same value", run repeatedModule 5 == Just 15)
    , ("a copy of a remembered callable shares its result", runWithin 500 copiedModule 100 == Just 200)
    , ("two remembered callables each compute their own result", runWithin 500 separateModule 100 == Nothing)
    , ("two remembered callables give two results", run separateModule 5 == Just 10)
    , ("a remembered callable handed to a function is computed once for both", runWithin 500 handedModule 100 == Just 200)
    , ("a remembered callable that is never called computes nothing", run neverCalledModule 5 == Just 7)
    , ("a remembered callable keeps the values it was created with", run capturedModule 5 == Just 506)
    , -- The optimizer keeps the meaning and the count.
      ("the optimizer keeps a remembered callable verified", all optimizedVerifies allModules)
    , ("the optimizer does not repeat a remembered computation", runOptimizedWithin 500 sharedModule 100 == Just 300)
    , ("the optimizer does not compute what is never called", runOptimized neverCalledModule 5 == Just 7)
    , ("the optimizer keeps sharing through a copy", runOptimizedWithin 500 copiedModule 100 == Just 200)
    , ("the optimizer keeps sharing across a call", runOptimizedWithin 500 handedModule 100 == Just 200)
    , ("the optimizer does not turn one remembered callable into two", all (not . memoizesMore) allModules)
    ]
    where
        allModules = [sharedModule, repeatedModule, copiedModule, separateModule, handedModule, neverCalledModule, capturedModule, booleanModule]

-- ---------------------------------------------------------------- fixtures

intCallable :: Type
intCallable = FunctionType [] intType

boolCallable :: Type
boolCallable = FunctionType [] boolType

named :: Int -> String -> ResolvedName
named identifier spelling = ResolvedName (SymbolId identifier) (Identifier spelling)

runName, stepName, takeName, inputName, heldName, otherName, countName, callableParameter :: ResolvedName
runName = named 1 "Run"
stepName = named 2 "Step"
takeName = named 3 "Take"
inputName = named 10 "input"
heldName = named 11 "held"
otherName = named 12 "other"
countName = named 13 "count"
callableParameter = named 14 "computation"

integer :: Integer -> CoreExpression
integer value = CoreLiteral (CoreInteger value) intType

variable :: ResolvedName -> Type -> CoreExpression
variable = CoreVariable

input :: CoreExpression
input = variable inputName intType

-- | @Step(n)@ counts down to zero and returns how far it counted: n steps of work.
stepFunction :: CoreFunction
stepFunction =
    CoreFunction
        stepName
        [(countName, intType)]
        intType
        [ CoreIf
            (CorePrimitive CoreGreaterThan [count, integer 0] boolType)
            [ CoreReturn
                ( CorePrimitive
                    CoreAdd
                    [integer 1, CoreApply stepReference [CorePrimitive CoreSubtract [count, integer 1] intType] intType]
                    intType
                )
            ]
            []
        , CoreReturn (integer 0)
        ]
    where
        count = variable countName intType

stepReference :: CoreExpression
stepReference = variable stepName (FunctionType [intType] intType)

-- | A callable that computes @Step(input)@ from the input it was created with.
stepClosure :: CoreExpression
stepClosure =
    CoreClosure
        [CoreCapture StrongCapture inputName intType input]
        []
        intType
        [CoreReturn (CoreApply stepReference [input] intType)]
        intCallable

memoize :: CoreExpression -> CoreExpression
memoize computation = CorePrimitive CoreMemoize [computation] (expressionType computation)

remembered :: CoreExpression
remembered = memoize stepClosure

callOf :: CoreExpression -> CoreExpression
callOf callable = CoreApply callable [] intType

held, other :: CoreExpression
held = variable heldName intCallable
other = variable otherName intCallable

sumOf :: [CoreExpression] -> CoreExpression
sumOf = foldr1 (\left right -> CorePrimitive CoreAdd [left, right] intType)

-- | A module whose @Run(input)@ has the given body, beside @Step@.
moduleOf :: [CoreFunction] -> [CoreStatement] -> CoreModule
moduleOf others body =
    CoreModule
        (QualifiedName [Identifier "Memo"])
        (CoreFunction runName [(inputName, intType)] intType body : stepFunction : others)

returning :: CoreExpression -> CoreModule
returning value = moduleOf [] [CoreReturn value]

-- | @Run@ binds the value and returns zero; for the cases the verifier refuses.
holding :: CoreExpression -> CoreModule
holding value =
    moduleOf [] [CoreBind (CoreBinding heldName (expressionType value) False value), CoreReturn (integer 0)]

bindHeld :: CoreExpression -> CoreStatement
bindHeld value = CoreBind (CoreBinding heldName intCallable False value)

-- | One remembered callable, called three times.
sharedModule :: CoreModule
sharedModule = moduleOf [] [bindHeld remembered, CoreReturn (sumOf [callOf held, callOf held, callOf held])]

-- | The same callable without remembering, called three times.
repeatedModule :: CoreModule
repeatedModule = moduleOf [] [bindHeld stepClosure, CoreReturn (sumOf [callOf held, callOf held, callOf held])]

-- | A second name for one remembered callable: both names call the same one.
copiedModule :: CoreModule
copiedModule =
    moduleOf
        []
        [ bindHeld remembered
        , CoreBind (CoreBinding otherName intCallable False held)
        , CoreReturn (sumOf [callOf held, callOf other])
        ]

-- | Two remembered callables of the same computation.
separateModule :: CoreModule
separateModule =
    moduleOf
        []
        [ bindHeld remembered
        , CoreBind (CoreBinding otherName intCallable False remembered)
        , CoreReturn (sumOf [callOf held, callOf other])
        ]

-- | @Take(computation)@ calls the callable it is given.
takeFunction :: CoreFunction
takeFunction =
    CoreFunction
        takeName
        [(callableParameter, intCallable)]
        intType
        [CoreReturn (callOf (variable callableParameter intCallable))]

-- | A remembered callable that the function it is handed to and the caller both call.
handedModule :: CoreModule
handedModule =
    moduleOf
        [takeFunction]
        [ bindHeld remembered
        , CoreReturn
            (sumOf [CoreApply (variable takeName (FunctionType [intCallable] intType)) [held] intType, callOf held])
        ]

-- | A remembered callable of a computation that never returns, never called.
neverCalledModule :: CoreModule
neverCalledModule =
    moduleOf
        []
        [ bindHeld
            ( memoize
                ( CoreClosure
                    [CoreCapture StrongCapture inputName intType input]
                    []
                    intType
                    [CoreWhile (CoreLiteral (CoreBoolean True) boolType) [], CoreReturn input]
                    intCallable
                )
            )
        , CoreReturn (integer 7)
        ]

-- | The callable keeps the input it was created with; a later store does not reach it.
capturedModule :: CoreModule
capturedModule =
    moduleOf
        []
        [ CoreBind (CoreBinding countName intType True input)
        , bindHeld
            ( memoize
                ( CoreClosure
                    [CoreCapture StrongCapture countName intType (variable countName intType)]
                    []
                    intType
                    [CoreReturn (CorePrimitive CoreAdd [variable countName intType, integer 1] intType)]
                    intCallable
                )
            )
        , CoreAssign countName (integer 500)
        , CoreReturn (sumOf [callOf held, variable countName intType])
        ]

-- | A remembered Boolean.
booleanModule :: CoreModule
booleanModule =
    moduleOf
        []
        [ CoreBind
            ( CoreBinding
                heldName
                boolCallable
                False
                ( memoize
                    ( CoreClosure
                        [CoreCapture StrongCapture inputName intType input]
                        []
                        boolType
                        [CoreReturn (CorePrimitive CoreGreaterThan [input, integer 0] boolType)]
                        boolCallable
                    )
                )
            )
        , CoreIf (CoreApply (variable heldName boolCallable) [] boolType) [CoreReturn (integer 1)] []
        , CoreReturn (integer 0)
        ]

parameterized, unitCallable, stringCallable :: CoreExpression
parameterized =
    CoreClosure [] [(countName, intType)] intType [CoreReturn (variable countName intType)] (FunctionType [intType] intType)
unitCallable = CoreClosure [] [] unitType [CoreReturn (CoreLiteral CoreUnit unitType)] (FunctionType [] unitType)
stringCallable =
    CoreClosure [] [] stringType [CoreReturn (CoreLiteral (CoreString "text") stringType)] (FunctionType [] stringType)

-- | A CorePrep function that remembers an atom of the given type.
malformedCorePrep :: Type -> CorePrepModule
malformedCorePrep operandType =
    CorePrepModule
        (QualifiedName [Identifier "Memo"])
        [ CorePrepFunction
            runName
            ""
            [(inputName, operandType)]
            intType
            0
            [ CorePrepBlock
                0
                [CorePrepBind heldName operandType False (CorePrepPrimitive CoreMemoize [CorePrepVariable inputName operandType])]
                (CorePrepReturn (CorePrepLiteral (CoreInteger 0) intType))
            ]
        ]
        []

-- ----------------------------------------------------------------- checks

accepted :: CoreModule -> Bool
accepted moduleValue = verifyCore moduleValue == Right moduleValue

rejectedWith :: String -> CoreModule -> Bool
rejectedWith code moduleValue = case verifyCore moduleValue of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

coreRoundTrip :: CoreModule -> Bool
coreRoundTrip moduleValue =
    (encodeCore defaultCoreWireLimits moduleValue >>= decodeCore defaultCoreWireLimits) == Right moduleValue

preparedAndVerified :: CoreModule -> Bool
preparedAndVerified moduleValue = case prepareCore moduleValue of
    Right prepared -> verifyCorePrep prepared == Right prepared && remembers prepared
    Left _ -> False
    where
        remembers prepared = "CoreMemoize" `isInfixOf` show prepared

corePrepRoundTrip :: CoreModule -> Bool
corePrepRoundTrip moduleValue = case prepareCore moduleValue of
    Right prepared -> (encodeCorePrep prepared >>= decodeCorePrep) == Right prepared
    Left _ -> False

corePrepRejects :: String -> CorePrepModule -> Bool
corePrepRejects code moduleValue = case verifyCorePrep moduleValue of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

run :: CoreModule -> Integer -> Maybe Integer
run = runWithin 200000

runWithin :: Int -> CoreModule -> Integer -> Maybe Integer
runWithin budget moduleValue argument = case runFunctionWithBudget budget moduleValue "Run" [IntegerValue argument] of
    Just (IntegerValue value) -> Just value
    _ -> Nothing

optimized :: CoreModule -> Maybe CoreModule
optimized moduleValue = either (const Nothing) Just (runCoreOptimizer defaultCoreOptimizer moduleValue)

optimizedVerifies :: CoreModule -> Bool
optimizedVerifies moduleValue = case optimized moduleValue of
    Just result -> accepted result
    Nothing -> False

runOptimized :: CoreModule -> Integer -> Maybe Integer
runOptimized = runOptimizedWithin 200000

runOptimizedWithin :: Int -> CoreModule -> Integer -> Maybe Integer
runOptimizedWithin budget moduleValue argument = optimized moduleValue >>= \result -> runWithin budget result argument

-- | Whether the optimized module holds more remembering than the module had.
memoizesMore :: CoreModule -> Bool
memoizesMore moduleValue = case optimized moduleValue of
    Just result -> occurrences (show result) > occurrences (show moduleValue)
    Nothing -> True
    where
        occurrences text = length [() | index <- [0 .. length text - 1], "CoreMemoize" `isPrefixOfAt` (index, text)]
        isPrefixOfAt needle (index, text) = take (length needle) (drop index text) == needle
