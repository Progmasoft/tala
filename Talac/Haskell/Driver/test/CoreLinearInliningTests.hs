-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module CoreLinearInliningTests (coreLinearInliningTests) where

import Data.List (find, nub)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep (prepareCore)
import Progmasoft.Tala.Core.CorePrep.Verifier (verifyCorePrep)
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Symbols
import Progmasoft.Tala.Core.Verifier (verifyCore)

-- These tests deliberately construct Core directly. Source tests prove that
-- frontend lowering reaches Core; this suite owns the optimizer's identity,
-- evaluation-order, budget, and CorePrep boundary contracts.
coreLinearInliningTests :: [(String, Bool)]
coreLinearInliningTests =
    [ ("linear inliner accepts one immutable local", immutableLocal)
    , ("linear inliner accepts several immutable locals", severalLocals)
    , ("linear inliner preserves local dependency order", localDependencyOrder)
    , ("linear inliner substitutes a literal parameter", literalParameter)
    , ("linear inliner substitutes a variable parameter", variableParameter)
    , ("linear inliner binds a primitive argument once", primitiveArgumentOnce)
    , ("linear inliner binds a direct-call argument once", callArgumentOnce)
    , ("linear inliner preserves a failing argument", failingArgumentOnce)
    , ("linear inliner preserves an allocating argument", allocatingArgumentOnce)
    , ("linear inliner retains left-to-right argument order", argumentOrder)
    , ("linear inliner retains an unused non-trivial argument", unusedArgument)
    , ("linear inliner can discard an unused literal", unusedLiteral)
    , ("linear inliner converts pure evaluation statements", evaluationStep)
    , ("linear inliner keeps multiple evaluations ordered", evaluationOrder)
    , ("linear inliner rejects mutable local state", mutableBodyRejected)
    , ("linear inliner rejects assignment", assignmentBodyRejected)
    , ("linear inliner rejects branches", branchBodyRejected)
    , ("linear inliner rejects early returns", earlyReturnRejected)
    , ("linear inliner rejects missing returns", missingReturnRejectedBeforeOptimization)
    , ("linear inliner starts fresh ids above the entire module", freshFrontier)
    , ("separate call sites receive disjoint local ids", disjointCallSites)
    , ("copied expression lets receive fresh ids", nestedLetFreshened)
    , ("statement candidate accounting is explicit", statementCandidateReport)
    , ("expression candidate accounting remains explicit", expressionCandidateReport)
    , ("non-linear pure bodies are counted", rejectedBodyReport)
    , ("generated let accounting is explicit", generatedLetReport)
    , ("alpha-renaming accounting is explicit", alphaRenameReport)
    , ("expanded body obeys the node budget", expandedBudget)
    , ("candidate estimate obeys the node budget", candidateBudget)
    , ("linear inlining output verifies as Core", outputVerifies)
    , ("linear inlining output prepares successfully", outputPrepares)
    , ("prepared linear-inlining output verifies", preparedOutputVerifies)
    , ("linear inlining is deterministic", deterministicOutput)
    , ("linear inlining reaches an idempotent fixed point", idempotentOutput)
    , ("symbol inventory includes expression lets", inventoryIncludesLets)
    , ("symbol inventory includes closure-owned identities", inventoryIncludesClosure)
    , ("symbol inventory preserves deterministic structural order", inventoryOrder)
    ]

moduleName :: QualifiedName
moduleName = QualifiedName [Identifier "LinearInlining"]

entryName, helperName, leafName :: ResolvedName
entryName = named 1 "Entry"
helperName = named 2 "Helper"
leafName = named 3 "Leaf"

parameterA, parameterB, localA, localB, callerValue :: ResolvedName
parameterA = named 10 "a"
parameterB = named 11 "b"
localA = named 20 "first"
localB = named 21 "second"
callerValue = named 30 "input"

named :: Int -> String -> ResolvedName
named value spelling = ResolvedName (SymbolId value) (Identifier spelling)

integer :: Integer -> CoreExpression
integer value = CoreLiteral (CoreInteger value) intType

boolean :: Bool -> CoreExpression
boolean value = CoreLiteral (CoreBoolean value) boolType

variable :: ResolvedName -> Type -> CoreExpression
variable = CoreVariable

primitive :: CorePrimitive -> [CoreExpression] -> Type -> CoreExpression
primitive = CorePrimitive

call :: ResolvedName -> [Type] -> Type -> [CoreExpression] -> CoreExpression
call name parameterTypes resultType arguments =
    CoreApply (variable name (FunctionType parameterTypes resultType)) arguments resultType

binding :: ResolvedName -> Type -> Bool -> CoreExpression -> CoreStatement
binding name valueType mutable value = CoreBind (CoreBinding name valueType mutable value)

function :: ResolvedName -> [(ResolvedName, Type)] -> Type -> [CoreStatement] -> CoreFunction
function = CoreFunction

entry :: Type -> CoreExpression -> CoreFunction
entry resultType value = function entryName [] resultType [CoreReturn value]

moduleWith :: [CoreFunction] -> CoreModule
moduleWith = CoreModule moduleName

invocation :: [Type] -> Type -> [CoreExpression] -> CoreExpression
invocation = call helperName

inspectionOptions :: OptimizerOptions
inspectionOptions =
    defaultOptimizerOptions
        { optimizerMaximumIterations = 1
        , optimizerConstantPropagation = False
        , optimizerControlFlowSimplification = False
        , optimizerDeadCodeElimination = False
        }

optimize :: CoreModule -> Maybe OptimizationResult
optimize value = either (const Nothing) Just (optimizeCoreWith inspectionOptions value)

optimizeWith :: OptimizerOptions -> CoreModule -> Maybe OptimizationResult
optimizeWith options value = either (const Nothing) Just (optimizeCoreWith options value)

entryReturn :: OptimizationResult -> Maybe CoreExpression
entryReturn result = do
    selected <-
        find ((== resolvedSymbol entryName) . resolvedSymbol . coreFunctionName) (coreModuleFunctions (optimizedCore result))
    case coreFunctionBody selected of
        [CoreReturn value] -> Just value
        _ -> Nothing

optimizedEntry :: CoreModule -> Maybe CoreExpression
optimizedEntry value = optimize value >>= entryReturn

identityHelper :: CoreFunction
identityHelper = function helperName [(parameterA, intType)] intType [CoreReturn (variable parameterA intType)]

oneLocalHelper :: CoreFunction
oneLocalHelper =
    function
        helperName
        [(parameterA, intType)]
        intType
        [ binding localA intType False (primitive CoreAdd [variable parameterA intType, integer 1] intType)
        , CoreReturn (variable localA intType)
        ]

twoLocalHelper :: CoreFunction
twoLocalHelper =
    function
        helperName
        [(parameterA, intType)]
        intType
        [ binding localA intType False (primitive CoreAdd [variable parameterA intType, integer 1] intType)
        , binding localB intType False (primitive CoreMultiply [variable localA intType, integer 2] intType)
        , CoreReturn (variable localB intType)
        ]

immutableLocal :: Bool
immutableLocal = case optimizedEntry fixture of
    Just (CoreLet fresh intBinding value (CoreVariable used intResult) letResult) ->
        symbolIdValue (resolvedSymbol fresh) > maximumCoreSymbolValue fixture
            && resolvedSymbol fresh == resolvedSymbol used
            && intBinding == intType
            && value == primitive CoreAdd [integer 41, integer 1] intType
            && intResult == intType
            && letResult == intType
    _ -> False
    where
        fixture = moduleWith [entry intType (invocation [intType] intType [integer 41]), oneLocalHelper]

severalLocals :: Bool
severalLocals = (countLets <$> optimizedEntry fixture) == Just 2
    where
        fixture = moduleWith [entry intType (invocation [intType] intType [integer 20]), twoLocalHelper]

localDependencyOrder :: Bool
localDependencyOrder = case optimizedEntry fixture of
    Just (CoreLet first _ _ (CoreLet second _ secondValue (CoreVariable returned _) _) _) ->
        resolvedSymbol first /= resolvedSymbol second
            && resolvedSymbol second == resolvedSymbol returned
            && expressionUses (resolvedSymbol first) secondValue
    _ -> False
    where
        fixture = moduleWith [entry intType (invocation [intType] intType [integer 20]), twoLocalHelper]

literalParameter :: Bool
literalParameter = optimizedEntry fixture == Just (integer 42)
    where
        fixture = moduleWith [entry intType (invocation [intType] intType [integer 42]), identityHelper]

variableParameter :: Bool
variableParameter = optimizedEntry fixture == Just (variable callerValue intType)
    where
        caller =
            function
                entryName
                [(callerValue, intType)]
                intType
                [CoreReturn (invocation [intType] intType [variable callerValue intType])]
        fixture = moduleWith [caller, identityHelper]

primitiveArgumentOnce :: Bool
primitiveArgumentOnce = nonTrivialIdentity argument
    where
        argument = primitive CoreAdd [integer 20, integer 22] intType

callArgumentOnce :: Bool
callArgumentOnce = case optimize fixture >>= entryReturn of
    Just (CoreLet fresh bindingType value (CoreVariable used resultType) _) ->
        bindingType == intType
            && value == argument
            && resolvedSymbol fresh == resolvedSymbol used
            && resultType == intType
    _ -> False
    where
        callableName = named 31 "producer"
        callableType = FunctionType [] intType
        argument = CoreApply (variable callableName callableType) [] intType
        caller = function entryName [(callableName, callableType)] intType [CoreReturn (invocation [intType] intType [argument])]
        fixture = moduleWith [caller, identityHelper]

failingArgumentOnce :: Bool
failingArgumentOnce = nonTrivialIdentity argument
    where
        argument = primitive CoreDivide [integer 1, integer 0] intType

allocatingArgumentOnce :: Bool
allocatingArgumentOnce = case optimizedEntry fixture of
    Just (CoreLet fresh bindingType value (CoreVariable used resultType) _) ->
        bindingType == callableType
            && value == closureValue
            && resolvedSymbol fresh == resolvedSymbol used
            && resultType == callableType
    _ -> False
    where
        callableType = FunctionType [] intType
        closureValue = CoreClosure [] [] intType [CoreReturn (integer 42)] callableType
        helper = function helperName [(parameterA, callableType)] callableType [CoreReturn (variable parameterA callableType)]
        fixture = moduleWith [entry callableType (invocation [callableType] callableType [closureValue]), helper]

nonTrivialIdentity :: CoreExpression -> Bool
nonTrivialIdentity argument = case optimizedEntry fixture of
    Just (CoreLet fresh bindingType value (CoreVariable used resultType) _) ->
        bindingType == intType
            && value == argument
            && resolvedSymbol fresh == resolvedSymbol used
            && resultType == intType
            && countExpression argument value == 1
    _ -> False
    where
        fixture = moduleWith [entry intType (invocation [intType] intType [argument]), identityHelper, leaf]
        leaf = function leafName [] intType [CoreReturn (integer 42)]

argumentOrder :: Bool
argumentOrder = case optimizedEntry fixture of
    Just (CoreLet first _ firstValue (CoreLet second _ secondValue _ _) _) ->
        firstValue == firstArgument
            && secondValue == secondArgument
            && resolvedSymbol first /= resolvedSymbol second
    _ -> False
    where
        firstArgument = primitive CoreAdd [integer 1, integer 2] intType
        secondArgument = primitive CoreMultiply [integer 3, integer 4] intType
        result = primitive CoreSubtract [variable parameterA intType, variable parameterB intType] intType
        helper = function helperName [(parameterA, intType), (parameterB, intType)] intType [CoreReturn result]
        fixture = moduleWith [entry intType (invocation [intType, intType] intType [firstArgument, secondArgument]), helper]

unusedArgument :: Bool
unusedArgument = case optimizedEntry fixture of
    Just (CoreLet _ _ value result _) -> value == argument && result == integer 42
    _ -> False
    where
        argument = primitive CoreDivide [integer 1, integer 0] intType
        helper = function helperName [(parameterA, intType)] intType [CoreReturn (integer 42)]
        fixture = moduleWith [entry intType (invocation [intType] intType [argument]), helper]

unusedLiteral :: Bool
unusedLiteral = optimizedEntry fixture == Just (integer 42)
    where
        helper = function helperName [(parameterA, intType)] intType [CoreReturn (integer 42)]
        fixture = moduleWith [entry intType (invocation [intType] intType [integer 99]), helper]

evaluationStep :: Bool
evaluationStep = case optimizedEntry fixture of
    Just (CoreLet _ _ evaluated result _) -> evaluated == integer 1 && result == integer 42
    _ -> False
    where
        helper = function helperName [] intType [CoreEvaluate (integer 1), CoreReturn (integer 42)]
        fixture = moduleWith [entry intType (invocation [] intType []), helper]

evaluationOrder :: Bool
evaluationOrder = case optimizedEntry fixture of
    Just (CoreLet _ _ first (CoreLet _ _ second result _) _) ->
        first == integer 1 && second == integer 2 && result == integer 3
    _ -> False
    where
        helper = function helperName [] intType [CoreEvaluate (integer 1), CoreEvaluate (integer 2), CoreReturn (integer 3)]
        fixture = moduleWith [entry intType (invocation [] intType []), helper]

mutableBodyRejected :: Bool
mutableBodyRejected = optimizedEntry fixture == Just original
    where
        original = invocation [] intType []
        helper = function helperName [] intType [binding localA intType True (integer 1), CoreReturn (variable localA intType)]
        fixture = moduleWith [entry intType original, helper]

assignmentBodyRejected :: Bool
assignmentBodyRejected = optimizedEntry fixture == Just original
    where
        original = invocation [] intType []
        helper =
            function
                helperName
                []
                intType
                [binding localA intType True (integer 1), CoreAssign localA (integer 2), CoreReturn (variable localA intType)]
        fixture = moduleWith [entry intType original, helper]

branchBodyRejected :: Bool
branchBodyRejected = optimizedEntry fixture == Just original
    where
        original = invocation [] intType []
        helper = function helperName [] intType [CoreIf (boolean True) [CoreReturn (integer 1)] [CoreReturn (integer 2)]]
        fixture = moduleWith [entry intType original, helper]

earlyReturnRejected :: Bool
earlyReturnRejected = optimizedEntry fixture == Just original
    where
        original = invocation [] intType []
        helper = function helperName [] intType [CoreReturn (integer 1), CoreReturn (integer 2)]
        fixture = moduleWith [entry intType original, helper]

missingReturnRejectedBeforeOptimization :: Bool
missingReturnRejectedBeforeOptimization = case optimize fixture of
    Nothing -> True
    Just _ -> False
    where
        helper = function helperName [] intType [CoreEvaluate (integer 1)]
        fixture = moduleWith [entry intType (invocation [] intType []), helper]

freshFrontier :: Bool
freshFrontier = case optimizedEntry fixture of
    Just value -> all ((> maximumCoreSymbolValue fixture) . symbolIdValue) (definedExpressionSymbols value)
    Nothing -> False
    where
        highLocal = named 900 "high"
        helper =
            function helperName [] intType [binding highLocal intType False (integer 42), CoreReturn (variable highLocal intType)]
        fixture = moduleWith [entry intType (invocation [] intType []), helper]

disjointCallSites :: Bool
disjointCallSites = case optimize fixture of
    Just result -> case functionBody entryName result of
        Just [CoreBind first, CoreReturn second] ->
            let firstIds = definedExpressionSymbols (coreBindingValue first)
                secondIds = definedExpressionSymbols second
             in not (null firstIds) && not (null secondIds) && null [value | value <- firstIds, value `elem` secondIds]
        _ -> False
    Nothing -> False
    where
        firstResult = invocation [intType] intType [integer 1]
        secondResult = invocation [intType] intType [integer 2]
        caller = function entryName [] intType [binding callerValue intType False firstResult, CoreReturn secondResult]
        fixture = moduleWith [caller, oneLocalHelper]

nestedLetFreshened :: Bool
nestedLetFreshened = case optimizedEntry fixture of
    Just value -> all ((> maximumCoreSymbolValue fixture) . symbolIdValue) (definedExpressionSymbols value)
    Nothing -> False
    where
        nestedName = named 700 "nested"
        result = CoreLet nestedName intType (integer 42) (variable nestedName intType) intType
        helper = function helperName [] intType [CoreReturn result]
        fixture = moduleWith [entry intType (invocation [] intType []), helper]

statementCandidateReport :: Bool
statementCandidateReport = maybe False ((> 0) . sum . map inlineStatementCandidateCount . optimizationInlineReports) (optimize fixture)
    where
        fixture = moduleWith [entry intType (invocation [intType] intType [integer 41]), oneLocalHelper]

expressionCandidateReport :: Bool
expressionCandidateReport = maybe False ((> 0) . sum . map inlineExpressionCandidateCount . optimizationInlineReports) (optimize fixture)
    where
        fixture = moduleWith [entry intType (invocation [intType] intType [integer 42]), identityHelper]

rejectedBodyReport :: Bool
rejectedBodyReport = maybe False ((> 0) . sum . map inlineRejectedNonLinearBodies . optimizationInlineReports) (optimize fixture)
    where
        helper = function helperName [] intType [CoreIf (boolean True) [CoreReturn (integer 1)] [CoreReturn (integer 2)]]
        fixture = moduleWith [entry intType (invocation [] intType []), helper]

generatedLetReport :: Bool
generatedLetReport = case optimize fixture of
    Just result -> case optimizationInlineReports result of
        report : _ ->
            inlineGeneratedParameterLets report == 1
                && inlineGeneratedLocalLets report == 1
                && inlineGeneratedEvaluationLets report == 1
        [] -> False
    Nothing -> False
    where
        argument = primitive CoreAdd [integer 20, integer 21] intType
        helper =
            function
                helperName
                [(parameterA, intType)]
                intType
                [ CoreEvaluate (integer 0)
                , binding localA intType False (variable parameterA intType)
                , CoreReturn (variable localA intType)
                ]
        fixture = moduleWith [entry intType (invocation [intType] intType [argument]), helper]

alphaRenameReport :: Bool
alphaRenameReport = case optimize fixture of
    Just result -> case optimizationInlineReports result of
        report : _ -> inlineAlphaRenamedSymbols report == 3
        [] -> False
    Nothing -> False
    where
        argument = primitive CoreAdd [integer 20, integer 21] intType
        helper =
            function
                helperName
                [(parameterA, intType)]
                intType
                [ CoreEvaluate (integer 0)
                , binding localA intType False (variable parameterA intType)
                , CoreReturn (variable localA intType)
                ]
        fixture = moduleWith [entry intType (invocation [intType] intType [argument]), helper]

expandedBudget :: Bool
expandedBudget = case optimizeWith options fixture >>= entryReturn of
    Just value -> value == original
    Nothing -> False
    where
        argument = primitive CoreAdd [integer 20, integer 22] intType
        original = invocation [intType] intType [argument]
        fixture = moduleWith [entry intType original, identityHelper]
        options = inspectionOptions {optimizerMaximumInlineExpressionNodes = 4}

candidateBudget :: Bool
candidateBudget = case optimizeWith options fixture >>= entryReturn of
    Just value -> value == original
    Nothing -> False
    where
        original = invocation [intType] intType [integer 20]
        fixture = moduleWith [entry intType original, twoLocalHelper]
        options = inspectionOptions {optimizerMaximumInlineExpressionNodes = 4}

outputVerifies :: Bool
outputVerifies = case optimize fixture of
    Just result -> either (const False) (const True) (verifyCore (optimizedCore result))
    Nothing -> False
    where
        fixture =
            moduleWith
                [entry intType (invocation [intType] intType [primitive CoreAdd [integer 20, integer 21] intType]), twoLocalHelper]

outputPrepares :: Bool
outputPrepares = case optimize fixture of
    Just result -> either (const False) (const True) (prepareCore (optimizedCore result))
    Nothing -> False
    where
        fixture =
            moduleWith
                [entry intType (invocation [intType] intType [primitive CoreAdd [integer 20, integer 21] intType]), twoLocalHelper]

preparedOutputVerifies :: Bool
preparedOutputVerifies = case optimize fixture of
    Just result -> case prepareCore (optimizedCore result) of
        Right prepared -> either (const False) (const True) (verifyCorePrep prepared)
        Left _ -> False
    Nothing -> False
    where
        fixture =
            moduleWith
                [entry intType (invocation [intType] intType [primitive CoreAdd [integer 20, integer 21] intType]), twoLocalHelper]

deterministicOutput :: Bool
deterministicOutput = (optimizedCore <$> optimize fixture) == (optimizedCore <$> optimize fixture)
    where
        fixture =
            moduleWith
                [entry intType (invocation [intType] intType [primitive CoreAdd [integer 20, integer 21] intType]), twoLocalHelper]

idempotentOutput :: Bool
idempotentOutput = case optimize fixture of
    Just first -> (optimizedCore <$> optimize (optimizedCore first)) == Just (optimizedCore first)
    Nothing -> False
    where
        fixture =
            moduleWith
                [entry intType (invocation [intType] intType [primitive CoreAdd [integer 20, integer 21] intType]), twoLocalHelper]

inventoryIncludesLets :: Bool
inventoryIncludesLets = map resolvedSymbol (coreExpressionSymbols expression) == [SymbolId 80, SymbolId 80]
    where
        letName = named 80 "inside"
        expression = CoreLet letName intType (integer 1) (variable letName intType) intType

inventoryIncludesClosure :: Bool
inventoryIncludesClosure = all (`elem` symbols) [SymbolId 81, SymbolId 82, SymbolId 83]
    where
        captureName = named 81 "capture"
        parameterName = named 82 "parameter"
        localName = named 83 "local"
        capture = CoreCapture StrongCapture captureName intType (integer 1)
        expression =
            CoreClosure
                [capture]
                [(parameterName, intType)]
                intType
                [binding localName intType False (variable captureName intType), CoreReturn (variable parameterName intType)]
                (FunctionType [intType] intType)
        symbols = map resolvedSymbol (coreExpressionSymbols expression)

inventoryOrder :: Bool
inventoryOrder = map resolvedSymbol (coreModuleSymbols fixture) == expected
    where
        fixture =
            moduleWith
                [ function
                    entryName
                    [(parameterA, intType)]
                    intType
                    [binding localA intType False (variable parameterA intType), CoreReturn (variable localA intType)]
                ]
        expected = [SymbolId 1, SymbolId 10, SymbolId 20, SymbolId 10, SymbolId 20]

functionBody :: ResolvedName -> OptimizationResult -> Maybe [CoreStatement]
functionBody name result =
    coreFunctionBody
        <$> find ((== resolvedSymbol name) . resolvedSymbol . coreFunctionName) (coreModuleFunctions (optimizedCore result))

countLets :: CoreExpression -> Int
countLets expression = case expression of
    CoreLet _ _ value body _ -> 1 + countLets value + countLets body
    CoreApply callee arguments _ -> countLets callee + sum (map countLets arguments)
    CorePrimitive _ arguments _ -> sum (map countLets arguments)
    CoreClosure captures _ _ body _ -> sum (map (countLets . coreCaptureValue) captures) + sum (map countStatementLets body)
    _ -> 0

countStatementLets :: CoreStatement -> Int
countStatementLets statement = case statement of
    CoreBind value -> countLets (coreBindingValue value)
    CoreAssign _ value -> countLets value
    CoreReturn value -> countLets value
    CoreEvaluate value -> countLets value
    CoreIf condition yes no -> countLets condition + sum (map countStatementLets (yes ++ no))
    CoreWhile condition body -> countLets condition + sum (map countStatementLets body)
    CoreDoWhile body condition -> sum (map countStatementLets body) + countLets condition
    CoreFor condition updates body ->
        countLets condition + sum (map countStatementLets updates) + sum (map countStatementLets body)
    CoreBreak -> 0
    CoreContinue -> 0

expressionUses :: SymbolId -> CoreExpression -> Bool
expressionUses symbol = elem symbol . map resolvedSymbol . coreExpressionSymbols

definedExpressionSymbols :: CoreExpression -> [SymbolId]
definedExpressionSymbols expression = nub (go expression)
    where
        go value = case value of
            CoreLet name _ bound body _ -> resolvedSymbol name : go bound ++ go body
            CoreApply callee arguments _ -> go callee ++ concatMap go arguments
            CorePrimitive _ arguments _ -> concatMap go arguments
            CoreClosure captures parameters _ body _ ->
                map (resolvedSymbol . coreCaptureName) captures
                    ++ map (resolvedSymbol . fst) parameters
                    ++ concatMap (go . coreCaptureValue) captures
                    ++ concatMap statementDefinitions body
            _ -> []
        statementDefinitions statement = case statement of
            CoreBind value -> resolvedSymbol (coreBindingName value) : go (coreBindingValue value)
            CoreAssign _ value -> go value
            CoreReturn value -> go value
            CoreEvaluate value -> go value
            CoreIf condition yes no -> go condition ++ concatMap statementDefinitions (yes ++ no)
            CoreWhile condition body -> go condition ++ concatMap statementDefinitions body
            CoreDoWhile body condition -> concatMap statementDefinitions body ++ go condition
            CoreFor condition updates body ->
                go condition ++ concatMap statementDefinitions updates ++ concatMap statementDefinitions body
            CoreBreak -> []
            CoreContinue -> []

countExpression :: CoreExpression -> CoreExpression -> Int
countExpression needle expression =
    (if needle == expression then 1 else 0)
        + case expression of
            CoreApply callee arguments _ -> sum (map (countExpression needle) (callee : arguments))
            CorePrimitive _ arguments _ -> sum (map (countExpression needle) arguments)
            CoreLet _ _ value body _ -> countExpression needle value + countExpression needle body
            CoreClosure captures _ _ body _ ->
                sum (map (countExpression needle . coreCaptureValue) captures)
                    + sum (map countStatement body)
            _ -> 0
    where
        countStatement statement = case statement of
            CoreBind value -> countExpression needle (coreBindingValue value)
            CoreAssign _ value -> countExpression needle value
            CoreReturn value -> countExpression needle value
            CoreEvaluate value -> countExpression needle value
            CoreIf condition yes no -> countExpression needle condition + sum (map countStatement (yes ++ no))
            CoreWhile condition body -> countExpression needle condition + sum (map countStatement body)
            CoreDoWhile body condition -> sum (map countStatement body) + countExpression needle condition
            CoreFor condition updates body ->
                countExpression needle condition + sum (map countStatement updates) + sum (map countStatement body)
            CoreBreak -> 0
            CoreContinue -> 0
