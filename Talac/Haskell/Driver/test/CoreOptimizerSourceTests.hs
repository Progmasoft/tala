-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module CoreOptimizerSourceTests (coreOptimizerSourceTests) where

import CoreInterpreter
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep (corePrepModuleFunctions)
import Progmasoft.Tala.Core.CorePrep qualified as CorePrep
import Progmasoft.Tala.Core.Scalar (coreIntegerTypeNames)

-- These cases begin as Tala text. The constructor-level optimizer suite
-- can isolate every rewrite, while this group proves that real desugared trees
-- carry the identities and types those rewrites expect.
coreOptimizerSourceTests :: [(String, Bool)]
coreOptimizerSourceTests =
    [ ("source constants fold through immutable locals", immutableSourceChain)
    , ("source mutable assignments remain observable", mutableSourceValue)
    , ("source true conditions select the live branch", sourceTrueBranch)
    , ("source false conditions select the live branch", sourceFalseBranch)
    , ("source numeric zero selects the false branch", sourceNumericFalse)
    , ("source nonzero conditions select the true branch", sourceNumericTrue)
    , ("source dead scalar locals disappear from optimized Core", sourceDeadLocal)
    , ("source pure calls disappear with discarded results", sourceDiscardedCall)
    , ("source code after return disappears", sourceUnreachable)
    , ("source closure allocation survives a dead binding", sourceDeadClosure)
    , ("source closure constants fold inside the body", sourceClosureFold)
    , ("source optimizer output remains accepted by CorePrep", sourceReachesCorePrep)
    , ("source nullary calls inline into returns", sourceInlineNullary)
    , ("source parameters substitute and fold", sourceInlineParameter)
    , ("source multi-parameter calls preserve position", sourceInlineMultiple)
    , ("source pure call chains converge", sourceInlineChain)
    , ("source predicates inline before branch selection", sourceInlinePredicate)
    , ("floating rounded division folds to an int through the source pipeline", sourceFloatingRoundedDivision)
    , ("unsigned source bitwise complement folds at its declared width", sourceUnsignedBitwiseComplement)
    , ("unsigned source bitwise complement masks away the sign extension", sourceUnsignedBitwiseZeroComplement)
    , ("source repeated parameters inline for literals", sourceInlineRepeated)
    , ("source unused literal arguments may disappear", sourceInlineUnused)
    , ("source immutable helper locals inline", sourceInlineLocal)
    , ("source dependent helper locals inline", sourceInlineDependentLocals)
    , ("source primitive arguments remain single evaluations", sourceInlinePrimitiveArgument)
    , ("source failing unused arguments are never computed", sourceUnusedFailingArgument)
    , ("source argument order survives generated lets", sourceInlineArgumentOrder)
    , ("source mutable helper bodies retain calls", sourceRejectsMutableHelper)
    , ("source branching helper bodies retain calls", sourceRejectsBranchHelper)
    , ("source inlined locals receive fresh symbols", sourceInlineFreshSymbols)
    , ("source inlined locals prepare without calls", sourceInlinePrepares)
    , ("source separate call sites use separate symbols", sourceInlineDisjointSites)
    , ("source guard lets a dead division disappear", sourceGuardedDeadDivision)
    , ("source unguarded dead division remains observable", sourceUnguardedDeadDivision)
    , ("source assignment replaces a branch range", sourceAssignmentReplacesGuard)
    , ("source impossible integer branch is removed", sourceImpossibleIntegerBranch)
    , ("source equality transfers range facts between locals", sourceVariableEqualityGuard)
    , ("source ordering derives a positive divisor", sourceVariableOrderingGuard)
    , ("source short-circuit false edge proves nonzero", sourceFalseDisjunctionGuard)
    , ("source arithmetic keeps a bounded product nonzero", sourceProductRangeGuard)
    , ("source arithmetic keeps a bounded difference nonzero", sourceDifferenceRangeGuard)
    , ("source branch join retains common zero exclusion", sourceNonzeroBranchJoin)
    , ("source branch join drops conflicting zero exclusion", sourceConflictingBranchJoin)
    , ("source comparison boundaries match the generated integer oracle", sourceComparisonBoundaryMatrix)
    ]

compiled :: String -> Maybe FrontendArtifacts
compiled body = case compileToCorePrep (CompilerInput "optimizer-source.tala" (source body)) of
    Left _ -> Nothing
    Right artifacts -> Just artifacts

source :: String -> String
source body =
    unlines
        [ "namespace OptimizerSource;"
        , "class Program {"
        , "  int Value() {"
        , body
        , "  }"
        , "}"
        ]

singleBody :: FrontendArtifacts -> Maybe [CoreStatement]
singleBody artifacts = case coreModuleFunctions (artifactOptimizedCore artifacts) of
    [function] -> Just (coreFunctionBody function)
    _ -> Nothing

singleReturn :: FrontendArtifacts -> Maybe CoreExpression
singleReturn artifacts = do
    body <- singleBody artifacts
    case body of
        [CoreReturn value] -> Just value
        _ -> Nothing

integer :: Integer -> CoreExpression
integer value = CoreLiteral (CoreInteger value) intType

immutableSourceChain :: Bool
immutableSourceChain = case compiled "final int base = 40; final int answer = base + 2; return answer;" of
    Just artifacts -> singleReturn artifacts == Just (integer 42)
    Nothing -> False

mutableSourceValue :: Bool
mutableSourceValue = case compiled "int value = 1; value = 2; return value;" of
    Just artifacts -> case singleBody artifacts of
        Just [CoreBind binding, CoreAssign target assigned, CoreReturn returned] ->
            coreBindingMutable binding
                && resolvedSymbol (coreBindingName binding) == resolvedSymbol target
                && assigned == integer 2
                && returned == CoreVariable target intType
        _ -> False
    Nothing -> False

sourceTrueBranch :: Bool
sourceTrueBranch = case compiled "if (true) { return 1; } else { return 2; }" of
    Just artifacts -> singleReturn artifacts == Just (integer 1)
    Nothing -> False

sourceFalseBranch :: Bool
sourceFalseBranch = case compiled "if (false) { return 1; } else { return 2; }" of
    Just artifacts -> singleReturn artifacts == Just (integer 2)
    Nothing -> False

sourceNumericFalse :: Bool
sourceNumericFalse = case compiled "if (0) { return 1; } else { return 2; }" of
    Just artifacts -> singleReturn artifacts == Just (integer 2)
    Nothing -> False

sourceNumericTrue :: Bool
sourceNumericTrue = case compiled "if (-1) { return 1; } else { return 2; }" of
    Just artifacts -> singleReturn artifacts == Just (integer 1)
    Nothing -> False

sourceDeadLocal :: Bool
sourceDeadLocal = case compiled "int unused = 42; return 1;" of
    Just artifacts -> singleReturn artifacts == Just (integer 1)
    Nothing -> False

sourceDiscardedCall :: Bool
sourceDiscardedCall = case compileToCorePrep (CompilerInput "optimizer-call.tala" callSource) of
    Right artifacts -> case coreModuleFunctions (artifactOptimizedCore artifacts) of
        [_helper, caller] -> case coreFunctionBody caller of
            [CoreReturn (CoreLiteral (CoreInteger 1) _)] -> True
            _ -> False
        _ -> False
    Left _ -> False
    where
        callSource =
            unlines
                [ "namespace OptimizerSource;"
                , "class Program {"
                , "  int Helper() { return 42; }"
                , "  int Value() { Helper(); return 1; }"
                , "}"
                ]

sourceUnreachable :: Bool
sourceUnreachable = case compiled "return 1; int unreachable = 2;" of
    Just artifacts -> singleReturn artifacts == Just (integer 1)
    Nothing -> False

sourceDeadClosure :: Bool
sourceDeadClosure = case compiled "auto callable = \\ -> 42; return 1;" of
    Just artifacts -> case singleBody artifacts of
        Just [CoreEvaluate CoreClosure {}, CoreReturn (CoreLiteral (CoreInteger 1) _)] -> True
        _ -> False
    Nothing -> False

sourceClosureFold :: Bool
sourceClosureFold = case compiled "auto callable = \\ -> 40 + 2; return 1;" of
    Just artifacts -> case singleBody artifacts of
        Just [CoreEvaluate (CoreClosure _ _ _ [CoreReturn value] _), CoreReturn _] -> value == integer 42
        _ -> False
    Nothing -> False

sourceReachesCorePrep :: Bool
sourceReachesCorePrep = case compiled "final int left = 20; final int right = 22; return left + right;" of
    Just artifacts ->
        singleReturn artifacts == Just (integer 42)
            && not (null (corePrepModuleFunctions (artifactCorePrep artifacts)))
    Nothing -> False

compiledProgram :: [String] -> Maybe FrontendArtifacts
compiledProgram members = case compileToCorePrep (CompilerInput "optimizer-inline.tala" text) of
    Left _ -> Nothing
    Right artifacts -> Just artifacts
    where
        text =
            unlines
                ( [ "namespace OptimizerSource;"
                  , "class Program {"
                  ]
                    ++ map ("  " ++) members
                    ++ ["}"]
                )

lastReturn :: FrontendArtifacts -> Maybe CoreExpression
lastReturn artifacts = case reverse (coreModuleFunctions (artifactOptimizedCore artifacts)) of
    function : _ -> case coreFunctionBody function of
        [CoreReturn value] -> Just value
        _ -> Nothing
    [] -> Nothing

sourceInlineNullary :: Bool
sourceInlineNullary = case compiledProgram ["int Answer() { return 42; }", "int Value() { return Answer(); }"] of
    Just artifacts -> lastReturn artifacts == Just (integer 42)
    Nothing -> False

sourceInlineParameter :: Bool
sourceInlineParameter = case compiledProgram ["int AddOne(_ int value) { return value + 1; }", "int Value() { return AddOne(41); }"] of
    Just artifacts -> lastReturn artifacts == Just (integer 42)
    Nothing -> False

sourceInlineMultiple :: Bool
sourceInlineMultiple = case compiledProgram
    ["int Difference(_ int left, _ int right) { return left - right; }", "int Value() { return Difference(50, 8); }"] of
    Just artifacts -> lastReturn artifacts == Just (integer 42)
    Nothing -> False

sourceInlineChain :: Bool
sourceInlineChain = case compiledProgram members of
    Just artifacts -> lastReturn artifacts == Just (integer 42)
    Nothing -> False
    where
        members =
            [ "int Answer() { return 42; }"
            , "int Forward() { return Answer(); }"
            , "int Value() { return Forward(); }"
            ]

sourceInlinePredicate :: Bool
sourceInlinePredicate = case compiledProgram members of
    Just artifacts -> lastReturn artifacts == Just (integer 42)
    Nothing -> False
    where
        members =
            [ "bool Enabled() { return true; }"
            , "int Value() { if (Enabled()) { return 42; } else { return 0; } }"
            ]

sourceFloatingRoundedDivision :: Bool
sourceFloatingRoundedDivision = case compiled "return 7.8 // 2.0;" of
    Just artifacts -> singleReturn artifacts == Just (CoreLiteral (CoreInteger 4) intType)
    Nothing -> False

sourceUnsignedBitwiseComplement :: Bool
sourceUnsignedBitwiseComplement = case compiledProgram ["ubyte Value() { return !0; }"] of
    Just artifacts -> lastReturn artifacts == Just (CoreLiteral (CoreInteger 255) (namedType "ubyte"))
    Nothing -> False

sourceUnsignedBitwiseZeroComplement :: Bool
sourceUnsignedBitwiseZeroComplement = case compiledProgram ["ubyte Value() { return !255; }"] of
    Just artifacts -> lastReturn artifacts == Just (CoreLiteral (CoreInteger 0) (namedType "ubyte"))
    Nothing -> False

sourceInlineRepeated :: Bool
sourceInlineRepeated = case compiledProgram ["int Twice(_ int value) { return value + value; }", "int Value() { return Twice(21); }"] of
    Just artifacts -> lastReturn artifacts == Just (integer 42)
    Nothing -> False

sourceInlineUnused :: Bool
sourceInlineUnused = case compiledProgram ["int Answer(_ int ignored) { return 42; }", "int Value() { return Answer(99); }"] of
    Just artifacts -> lastReturn artifacts == Just (integer 42)
    Nothing -> False

sourceInlineLocal :: Bool
sourceInlineLocal = case compiledProgram members of
    Just artifacts -> maybe False (\value -> not (containsCall value) && terminalResult value == integer 42) (lastReturn artifacts)
    Nothing -> False
    where
        members =
            [ "int AddOne(_ int value) { final int result = value + 1; return result; }"
            , "int Value() { return AddOne(41); }"
            ]

sourceInlineDependentLocals :: Bool
sourceInlineDependentLocals = case compiledProgram members of
    Just artifacts -> maybe False (\value -> not (containsCall value) && terminalResult value == integer 42) (lastReturn artifacts)
    Nothing -> False
    where
        members =
            [ "int Transform(_ int value) { final int doubled = value * 2; final int result = doubled + 2; return result; }"
            , "int Value() { return Transform(20); }"
            ]

sourceInlinePrimitiveArgument :: Bool
sourceInlinePrimitiveArgument = case compiledProgram members of
    Just artifacts -> case lastReturn artifacts of
        Just (CoreLet fresh bindingType value body resultType) ->
            bindingType == intType
                && value == integer 42
                && body == integer 42
                && resultType == intType
                && symbolIdValue (resolvedSymbol fresh) > 0
        _ -> False
    Nothing -> False
    where
        members =
            [ "int Identity(_ int value) { return value; }"
            , "int Value() { return Identity(20 + 22); }"
            ]

{- | An argument the method never needs is never computed. The call yields
the method's result, in the Core the Desugarer produced and in the Core the
optimizer left: no division is carried out on the way.
-}
sourceUnusedFailingArgument :: Bool
sourceUnusedFailingArgument = case compiledProgram members of
    Just artifacts ->
        all
            (\core -> runFunction core "Value" [] == Just (IntegerValue 42))
            [artifactCore artifacts, artifactOptimizedCore artifacts]
    Nothing -> False
    where
        members =
            [ "int Answer(_ int ignored) { return 42; }"
            , "int Value() { return Answer(1 / 0); }"
            ]

sourceInlineArgumentOrder :: Bool
sourceInlineArgumentOrder = case compiledProgram members of
    Just artifacts -> case lastReturn artifacts of
        Just (CoreLet first _ firstValue (CoreLet second _ secondValue _ _) _) ->
            firstValue == integer 3
                && secondValue == integer 12
                && resolvedSymbol first /= resolvedSymbol second
        _ -> False
    Nothing -> False
    where
        members =
            [ "int Difference(_ int left, _ int right) { return left - right; }"
            , "int Value() { return Difference(1 + 2, 3 * 4); }"
            ]

sourceRejectsMutableHelper :: Bool
sourceRejectsMutableHelper = case compiledProgram members of
    Just artifacts -> maybe False containsCall (lastReturn artifacts)
    Nothing -> False
    where
        members =
            [ "int Change(_ int value) { int result = value; result = result + 1; return result; }"
            , "int Value() { return Change(41); }"
            ]

sourceRejectsBranchHelper :: Bool
sourceRejectsBranchHelper = case compiledProgram members of
    Just artifacts -> maybe False containsCall (lastReturn artifacts)
    Nothing -> False
    where
        members =
            [ "int Choose(_ int value) { if (value) { return 42; } else { return 0; } }"
            , "int Value() { return Choose(1); }"
            ]

sourceInlineFreshSymbols :: Bool
sourceInlineFreshSymbols = case compiledProgram members of
    Just artifacts -> case lastReturn artifacts of
        Just value ->
            let sourceMaximum = maximumModuleSymbol (artifactCore artifacts)
                generated = expressionLetSymbols value
             in not (null generated) && all ((> sourceMaximum) . symbolIdValue) generated
        Nothing -> False
    Nothing -> False
    where
        members =
            [ "int Transform(_ int value) { final int doubled = value * 2; return doubled + 2; }"
            , "int Value() { return Transform(20 + 0); }"
            ]

sourceInlinePrepares :: Bool
sourceInlinePrepares = case compiledProgram members of
    Just artifacts -> all (not . prepFunctionCalls) (corePrepModuleFunctions (artifactCorePrep artifacts))
    Nothing -> False
    where
        members =
            [ "int Transform(_ int value) { final int doubled = value * 2; return doubled + 2; }"
            , "int Value() { return Transform(20); }"
            ]

sourceInlineDisjointSites :: Bool
sourceInlineDisjointSites = case compiledProgram members of
    Just artifacts -> case reverse (coreModuleFunctions (artifactOptimizedCore artifacts)) of
        caller : _ -> case coreFunctionBody caller of
            [CoreBind first, CoreReturn second] ->
                let firstSymbols = expressionLetSymbols (coreBindingValue first)
                    secondSymbols = expressionLetSymbols second
                 in not (null firstSymbols)
                        && not (null secondSymbols)
                        && null [symbol | symbol <- firstSymbols, symbol `elem` secondSymbols]
            _ -> False
        [] -> False
    Nothing -> False
    where
        members =
            [ "int Transform(_ int value) { final int doubled = value * 2; return doubled + 2; }"
            , "int Value() { final int first = Transform(10); return Transform(first); }"
            ]

containsCall :: CoreExpression -> Bool
containsCall expression = case expression of
    CoreApply {} -> True
    CorePrimitive _ arguments _ -> any containsCall arguments
    CoreLet _ _ value body _ -> containsCall value || containsCall body
    CoreClosure captures _ _ body _ ->
        any (containsCall . coreCaptureValue) captures || any statementContainsCall body
    _ -> False

terminalResult :: CoreExpression -> CoreExpression
terminalResult expression = case expression of
    CoreLet _ _ _ body _ -> terminalResult body
    _ -> expression

statementContainsCall :: CoreStatement -> Bool
statementContainsCall statement = case statement of
    CoreBind value -> containsCall (coreBindingValue value)
    CoreAssign _ value -> containsCall value
    CoreReturn value -> containsCall value
    CoreEvaluate value -> containsCall value
    CoreIf condition yes no -> containsCall condition || any statementContainsCall (yes ++ no)
    CoreWhile condition body -> containsCall condition || any statementContainsCall body
    CoreDoWhile body condition -> any statementContainsCall body || containsCall condition
    CoreFor condition updates body ->
        containsCall condition || any statementContainsCall updates || any statementContainsCall body
    CoreBreak -> False
    CoreContinue -> False

expressionLetSymbols :: CoreExpression -> [SymbolId]
expressionLetSymbols expression = case expression of
    CoreLet name _ value body _ -> resolvedSymbol name : expressionLetSymbols value ++ expressionLetSymbols body
    CoreApply callee arguments _ -> concatMap expressionLetSymbols (callee : arguments)
    CorePrimitive _ arguments _ -> concatMap expressionLetSymbols arguments
    CoreClosure captures _ _ body _ ->
        concatMap (expressionLetSymbols . coreCaptureValue) captures
            ++ concatMap statementLetSymbols body
    _ -> []

statementLetSymbols :: CoreStatement -> [SymbolId]
statementLetSymbols statement = case statement of
    CoreBind value -> expressionLetSymbols (coreBindingValue value)
    CoreAssign _ value -> expressionLetSymbols value
    CoreReturn value -> expressionLetSymbols value
    CoreEvaluate value -> expressionLetSymbols value
    CoreIf condition yes no -> expressionLetSymbols condition ++ concatMap statementLetSymbols (yes ++ no)
    CoreWhile condition body -> expressionLetSymbols condition ++ concatMap statementLetSymbols body
    CoreDoWhile body condition -> concatMap statementLetSymbols body ++ expressionLetSymbols condition
    CoreFor condition updates body ->
        expressionLetSymbols condition ++ concatMap statementLetSymbols updates ++ concatMap statementLetSymbols body
    CoreBreak -> []
    CoreContinue -> []

maximumModuleSymbol :: CoreModule -> Int
maximumModuleSymbol moduleValue = maximum (0 : concatMap functionSymbols (coreModuleFunctions moduleValue))
    where
        functionSymbols value =
            symbolIdValue (resolvedSymbol (coreFunctionName value))
                : map (symbolIdValue . resolvedSymbol . fst) (coreFunctionParameters value)
                ++ concatMap statementSymbols (coreFunctionBody value)
        statementSymbols statement = case statement of
            CoreBind value -> symbolIdValue (resolvedSymbol (coreBindingName value)) : expressionSymbols (coreBindingValue value)
            CoreAssign name value -> symbolIdValue (resolvedSymbol name) : expressionSymbols value
            CoreReturn value -> expressionSymbols value
            CoreEvaluate value -> expressionSymbols value
            CoreIf condition yes no -> expressionSymbols condition ++ concatMap statementSymbols (yes ++ no)
            CoreWhile condition body -> expressionSymbols condition ++ concatMap statementSymbols body
            CoreDoWhile body condition -> concatMap statementSymbols body ++ expressionSymbols condition
            CoreFor condition updates body ->
                expressionSymbols condition ++ concatMap statementSymbols updates ++ concatMap statementSymbols body
            CoreBreak -> []
            CoreContinue -> []
        expressionSymbols expression = map (symbolIdValue . resolvedSymbol) (expressionNames expression)
        expressionNames expression = case expression of
            CoreVariable name _ -> [name]
            CoreLiteral {} -> []
            CoreApply callee arguments _ -> concatMap expressionNames (callee : arguments)
            CorePrimitive _ arguments _ -> concatMap expressionNames arguments
            CoreLet name _ value body _ -> name : expressionNames value ++ expressionNames body
            CoreConditional condition whenTrue whenFalse _ -> concatMap expressionNames [condition, whenTrue, whenFalse]
            CoreClosure captures parameters _ body _ ->
                map coreCaptureName captures
                    ++ map fst parameters
                    ++ concatMap (expressionNames . coreCaptureValue) captures
                    ++ concatMap statementNames body
        statementNames statement = case statement of
            CoreBind value -> coreBindingName value : expressionNames (coreBindingValue value)
            CoreAssign name value -> name : expressionNames value
            CoreReturn value -> expressionNames value
            CoreEvaluate value -> expressionNames value
            CoreIf condition yes no -> expressionNames condition ++ concatMap statementNames (yes ++ no)
            CoreWhile condition body -> expressionNames condition ++ concatMap statementNames body
            CoreDoWhile body condition -> concatMap statementNames body ++ expressionNames condition
            CoreFor condition updates body ->
                expressionNames condition ++ concatMap statementNames updates ++ concatMap statementNames body
            CoreBreak -> []
            CoreContinue -> []

prepFunctionCalls :: CorePrep.CorePrepFunction -> Bool
prepFunctionCalls value = any blockCalls (CorePrep.corePrepFunctionBlocks value)
    where
        blockCalls block = any instructionCalls (CorePrep.corePrepBlockInstructions block)
        instructionCalls instruction = case instruction of
            CorePrep.CorePrepBind _ _ _ (CorePrep.CorePrepCall _ _) -> True
            CorePrep.CorePrepEvaluate (CorePrep.CorePrepCall _ _) -> True
            _ -> False

sourceGuardedDeadDivision :: Bool
sourceGuardedDeadDivision =
    case compiledProgram ["void Guarded(_ int divisor) { if (divisor \\= 0) { int result = 10 / divisor; if (result > 0) { } } }"] of
        Just artifacts ->
            case coreModuleFunctions (artifactOptimizedCore artifacts) of
                [function] -> not (containsIntegerDivision (coreFunctionBody function))
                _ -> False
        Nothing -> False

sourceUnguardedDeadDivision :: Bool
sourceUnguardedDeadDivision =
    case compiledProgram ["void Guarded(_ int divisor) { int result = 10 / divisor; if (result > 0) { } }"] of
        Just artifacts ->
            case coreModuleFunctions (artifactOptimizedCore artifacts) of
                [function] -> containsIntegerDivision (coreFunctionBody function)
                _ -> False
        Nothing -> False

sourceAssignmentReplacesGuard :: Bool
sourceAssignmentReplacesGuard =
    case compiledProgram
        ["void Guarded(_ int input) { int divisor = input; if (divisor \\= 0) { divisor = 0; int result = 10 / divisor; if (result > 0) { } } }"] of
        Just artifacts ->
            case coreModuleFunctions (artifactOptimizedCore artifacts) of
                [function] -> containsIntegerDivision (coreFunctionBody function)
                _ -> False
        Nothing -> False

sourceImpossibleIntegerBranch :: Bool
sourceImpossibleIntegerBranch =
    case compiledProgram ["int Guarded(_ int value) { if (value > 4 && value < 5) { return 24 / value; } else { return 0; } }"] of
        Just artifacts ->
            case coreModuleFunctions (artifactOptimizedCore artifacts) of
                [function] ->
                    not (containsIntegerDivision (coreFunctionBody function))
                        && any isZeroReturn (coreFunctionBody function)
                _ -> False
        Nothing -> False
    where
        isZeroReturn (CoreReturn (CoreLiteral (CoreInteger 0) _)) = True
        isZeroReturn _ = False

sourceVariableEqualityGuard :: Bool
sourceVariableEqualityGuard =
    sourceDivisionExpectation
        False
        ["void Guarded(_ int known, _ int divisor) { if (known \\= 0 && divisor == known) { int probed = 24 / divisor; if (probed > 0) { } } }"]

sourceVariableOrderingGuard :: Bool
sourceVariableOrderingGuard =
    sourceDivisionExpectation
        False
        [ "void Guarded(_ int lowerBound, _ int divisor) { if (lowerBound >= 0 && divisor > lowerBound) { int probed = 24 / divisor; if (probed > 0) { } } }"
        ]

sourceFalseDisjunctionGuard :: Bool
sourceFalseDisjunctionGuard =
    sourceDivisionExpectation
        False
        [ "void Guarded(_ int divisor, _ int other) {"
        , "  if (divisor == 0 || other == 0) { return; }"
        , "  int probed = 24 / divisor; if (probed > 0) { }"
        , "}"
        ]

sourceProductRangeGuard :: Bool
sourceProductRangeGuard =
    sourceDivisionExpectation
        False
        [ "void Guarded(_ int value) {"
        , "  if (value > 0 && value < 5) {"
        , "    int divisor = value * 2;"
        , "    int probed = 24 / divisor; if (probed > 0) { }"
        , "  }"
        , "}"
        ]

sourceDifferenceRangeGuard :: Bool
sourceDifferenceRangeGuard =
    sourceDivisionExpectation
        False
        [ "void Guarded(_ int value) {"
        , "  if (value >= 8) {"
        , "    int divisor = value - 5;"
        , "    int probed = 24 / divisor; if (probed > 0) { }"
        , "  }"
        , "}"
        ]

sourceNonzeroBranchJoin :: Bool
sourceNonzeroBranchJoin =
    sourceDivisionExpectation
        False
        [ "void Guarded(_ int input, _ bool choose) {"
        , "  if (input \\= 0) {"
        , "    int divisor = input;"
        , "    if (choose) { divisor = 7; } else { divisor = -1; }"
        , "    int probed = 24 / divisor; if (probed > 0) { }"
        , "  }"
        , "}"
        ]

sourceConflictingBranchJoin :: Bool
sourceConflictingBranchJoin =
    sourceDivisionExpectation
        True
        [ "void Guarded(_ int input, _ bool choose) {"
        , "  if (input \\= 0) {"
        , "    int divisor = input;"
        , "    if (choose) { divisor = 7; } else { divisor = 0; }"
        , "    int probed = 24 / divisor; if (probed > 0) { }"
        , "  }"
        , "}"
        ]

sourceDivisionExpectation :: Bool -> [String] -> Bool
sourceDivisionExpectation expectedPresent members =
    case compiledProgram members of
        Just artifacts ->
            case coreModuleFunctions (artifactOptimizedCore artifacts) of
                [function] -> containsIntegerDivision (coreFunctionBody function) == expectedPresent
                _ -> False
        Nothing -> False

-- This whole-program matrix checks parser, typing, lowering, fact refinement,
-- and DCE together. Each generated method places a dead divide on one selected
-- comparison edge; the oracle decides whether that edge excludes zero.
sourceComparisonBoundaryMatrix :: Bool
sourceComparisonBoundaryMatrix =
    case compiledProgram (zipWith sourceComparisonCase [0 :: Int ..] comparisons) of
        Just artifacts ->
            let actual =
                    [ containsIntegerDivision (coreFunctionBody function)
                    | function <- coreModuleFunctions (artifactOptimizedCore artifacts)
                    ]
                expected =
                    [ not (sourceComparisonProvesNonzero operator boundary truth reversed)
                    | (operator, boundary, truth, reversed) <- comparisons
                    ]
             in actual == expected
        Nothing -> False
    where
        operators = [CoreEqual, CoreNotEqual, CoreLessThan, CoreLessEqual, CoreGreaterThan, CoreGreaterEqual]
        comparisons =
            [ (operator, boundary, trueEdge, reversed)
            | operator <- operators
            , boundary <- [-3 .. 3]
            , trueEdge <- [False, True]
            , reversed <- [False, True]
            ]

sourceComparisonCase :: Int -> (CorePrimitive, Integer, Bool, Bool) -> String
sourceComparisonCase index (operator, boundary, trueEdge, reversed) =
    "void FlowCase"
        ++ show index
        ++ "(_ int value) { if ("
        ++ leftOperand
        ++ " "
        ++ comparisonToken operator
        ++ " "
        ++ rightOperand
        ++ ") {"
        ++ trueBody
        ++ "} else {"
        ++ falseBody
        ++ "} }"
    where
        (leftOperand, rightOperand) =
            if reversed
                then (show boundary, "value")
                else ("value", show boundary)
        selectedBody = " int probed = 24 / value; if (probed > 0) { } "
        trueBody = if trueEdge then selectedBody else ""
        falseBody = if trueEdge then "" else selectedBody

comparisonToken :: CorePrimitive -> String
comparisonToken operator = case operator of
    CoreEqual -> "=="
    CoreNotEqual -> "\\="
    CoreLessThan -> "<"
    CoreLessEqual -> "<="
    CoreGreaterThan -> ">"
    CoreGreaterEqual -> ">="
    _ -> "?"

sourceComparisonProvesNonzero :: CorePrimitive -> Integer -> Bool -> Bool -> Bool
sourceComparisonProvesNonzero operator boundary trueEdge reversed = case normalized of
    CoreEqual -> (trueEdge && boundary /= 0) || (not trueEdge && boundary == 0)
    CoreNotEqual -> (trueEdge && boundary == 0) || (not trueEdge && boundary /= 0)
    CoreLessThan -> (trueEdge && boundary <= 0) || (not trueEdge && boundary > 0)
    CoreLessEqual -> (trueEdge && boundary < 0) || (not trueEdge && boundary >= 0)
    CoreGreaterThan -> (trueEdge && boundary >= 0) || (not trueEdge && boundary < 0)
    CoreGreaterEqual -> (trueEdge && boundary > 0) || (not trueEdge && boundary <= 0)
    _ -> False
    where
        normalized = if reversed then reverseSourceComparison operator else operator

reverseSourceComparison :: CorePrimitive -> CorePrimitive
reverseSourceComparison operator = case operator of
    CoreLessThan -> CoreGreaterThan
    CoreLessEqual -> CoreGreaterEqual
    CoreGreaterThan -> CoreLessThan
    CoreGreaterEqual -> CoreLessEqual
    _ -> operator

containsIntegerDivision :: [CoreStatement] -> Bool
containsIntegerDivision = any statementHasDivision

statementHasDivision :: CoreStatement -> Bool
statementHasDivision statement = case statement of
    CoreBind binding -> expressionHasDivision (coreBindingValue binding)
    CoreAssign _ expression -> expressionHasDivision expression
    CoreReturn expression -> expressionHasDivision expression
    CoreEvaluate expression -> expressionHasDivision expression
    CoreIf condition whenTrue whenFalse ->
        expressionHasDivision condition || containsIntegerDivision whenTrue || containsIntegerDivision whenFalse
    CoreWhile condition body -> expressionHasDivision condition || containsIntegerDivision body
    CoreDoWhile body condition -> containsIntegerDivision body || expressionHasDivision condition
    CoreFor condition updates body ->
        expressionHasDivision condition || containsIntegerDivision updates || containsIntegerDivision body
    CoreBreak -> False
    CoreContinue -> False

expressionHasDivision :: CoreExpression -> Bool
expressionHasDivision expression = case expression of
    CoreVariable _ _ -> False
    CoreLiteral _ _ -> False
    CoreApply callee arguments _ -> any expressionHasDivision (callee : arguments)
    CorePrimitive operator arguments valueType ->
        (elem operator [CoreDivide, CoreFloorDivide, CoreRemainder] && elem valueType (map namedType coreIntegerTypeNames))
            || any expressionHasDivision arguments
    CoreLet _ _ value body _ -> expressionHasDivision value || expressionHasDivision body
    CoreConditional condition whenTrue whenFalse _ -> any expressionHasDivision [condition, whenTrue, whenFalse]
    CoreClosure captures _ _ body _ ->
        any (expressionHasDivision . coreCaptureValue) captures || containsIntegerDivision body
