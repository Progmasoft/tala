-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module CoreInliningTests (coreInliningTests) where

import Data.List (find)
import Progmasoft.Tala.AST hiding (parameterName)
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Verifier (verifyCore)

-- Core-level fixtures isolate substitution safety from frontend lowering. The
-- integration suite separately proves that source calls reach this pass.
coreInliningTests :: [(String, Bool)]
coreInliningTests =
    [ ("nullary literal return is inlined", nullaryLiteral)
    , ("literal parameter is substituted and folded", literalParameter)
    , ("variable parameter is substituted by SymbolId", variableParameter)
    , ("multiple parameters retain their positions", multipleParameters)
    , ("repeated literal parameters remain safe", repeatedLiteral)
    , ("repeated variable reads remain safe", repeatedVariable)
    , ("unused literal parameter may disappear", unusedLiteral)
    , ("unused variable parameter may disappear", unusedVariable)
    , ("primitive arguments are evaluated once behind a fresh let", primitiveArgumentPreserved)
    , ("a nested pure call becomes a safe inline argument", nestedCallBecomesSafe)
    , ("closure arguments are allocated once behind a fresh let", closureArgumentPreserved)
    , ("allocating functions are not candidates", allocatingCalleeRejected)
    , ("possibly failing functions are not candidates", failingCalleeRejected)
    , ("indirectly calling functions are not candidates", indirectCalleeRejected)
    , ("self recursion is never inlined", selfRecursionRejected)
    , ("mutual recursion is never inlined", mutualRecursionRejected)
    , ("candidate node budget is enforced", candidateBudget)
    , ("expanded node budget is enforced", expansionBudget)
    , ("zero budget normalizes to one node", zeroBudget)
    , ("inlining can be disabled", disabledInlining)
    , ("effect inference disablement disables inlining", disabledEffects)
    , ("inlining precedes constant folding", inlineThenFold)
    , ("pure call chains converge", pureCallChain)
    , ("branch conditions are inlined", branchCondition)
    , ("closure captures are inlined", closureCapture)
    , ("closure bodies are inlined", closureBody)
    , ("typed reports count candidates and rewrites", reportCounts)
    , ("typed reports count budget skips", reportBudgetSkip)
    , ("disabled pass emits no inline report", disabledReport)
    , ("pass reports start with inlining", passOrder)
    , ("function declaration order stays stable", stableFunctionOrder)
    , ("optimized output verifies", outputVerifies)
    , ("optimized output is idempotent", outputIdempotent)
    ]

moduleName :: QualifiedName
moduleName = QualifiedName [Identifier "Inlining"]

entryName, helperName, leafName, parameterName, otherName, callerParameterName :: ResolvedName
entryName = named 1 "Entry"
helperName = named 2 "Helper"
leafName = named 3 "Leaf"
parameterName = named 10 "value"
otherName = named 11 "other"
callerParameterName = named 12 "input"

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

closure :: [CoreCapture] -> Type -> [CoreStatement] -> CoreExpression
closure captures resultType body = CoreClosure captures [] resultType body (FunctionType [] resultType)

returning :: ResolvedName -> [(ResolvedName, Type)] -> Type -> CoreExpression -> CoreFunction
returning name parameters resultType value = CoreFunction name parameters resultType [CoreReturn value]

entry :: [(ResolvedName, Type)] -> Type -> [CoreStatement] -> CoreFunction
entry = CoreFunction entryName

moduleWith :: [CoreFunction] -> CoreModule
moduleWith = CoreModule moduleName

run :: CoreModule -> Maybe OptimizationResult
run value = either (const Nothing) Just (optimizeCoreWith defaultOptimizerOptions value)

runWith :: OptimizerOptions -> CoreModule -> Maybe OptimizationResult
runWith options value = either (const Nothing) Just (optimizeCoreWith options value)

functionBody :: ResolvedName -> OptimizationResult -> Maybe [CoreStatement]
functionBody name result =
    coreFunctionBody
        <$> find ((== resolvedSymbol name) . resolvedSymbol . coreFunctionName) (coreModuleFunctions (optimizedCore result))

returnValue :: OptimizationResult -> Maybe CoreExpression
returnValue result = do
    body <- functionBody entryName result
    case body of
        [CoreReturn value] -> Just value
        _ -> Nothing

optimizedReturn :: CoreModule -> Maybe CoreExpression
optimizedReturn value = run value >>= returnValue

literalCall :: CoreExpression
literalCall = call helperName [] intType []

literalFixture :: CoreModule
literalFixture = moduleWith [entry [] intType [CoreReturn literalCall], returning helperName [] intType (integer 42)]

identityFixture :: CoreExpression -> [(ResolvedName, Type)] -> CoreModule
identityFixture argument callerParameters =
    moduleWith
        [ entry callerParameters intType [CoreReturn invocation]
        , returning helperName [(parameterName, intType)] intType (variable parameterName intType)
        ]
    where
        invocation = call helperName [intType] intType [argument]

nullaryLiteral :: Bool
nullaryLiteral = optimizedReturn literalFixture == Just (integer 42)

literalParameter :: Bool
literalParameter = optimizedReturn (identityFixture (integer 42) []) == Just (integer 42)

variableParameter :: Bool
variableParameter =
    let argument = variable callerParameterName intType
     in optimizedReturn (identityFixture argument [(callerParameterName, intType)]) == Just argument

multipleParameters :: Bool
multipleParameters =
    let result = primitive CoreSubtract [variable parameterName intType, variable otherName intType] intType
        helper = returning helperName [(parameterName, intType), (otherName, intType)] intType result
        invocation = call helperName [intType, intType] intType [integer 50, integer 8]
     in optimizedReturn (moduleWith [entry [] intType [CoreReturn invocation], helper]) == Just (integer 42)

repeatedLiteral :: Bool
repeatedLiteral = repeatedArgument (integer 21) [] (integer 42)

repeatedVariable :: Bool
repeatedVariable =
    let argument = variable callerParameterName intType
        expected = primitive CoreAdd [argument, argument] intType
     in repeatedArgument argument [(callerParameterName, intType)] expected

repeatedArgument :: CoreExpression -> [(ResolvedName, Type)] -> CoreExpression -> Bool
repeatedArgument argument callerParameters expected =
    let result = primitive CoreAdd [variable parameterName intType, variable parameterName intType] intType
        helper = returning helperName [(parameterName, intType)] intType result
        invocation = call helperName [intType] intType [argument]
     in optimizedReturn (moduleWith [entry callerParameters intType [CoreReturn invocation], helper]) == Just expected

unusedLiteral :: Bool
unusedLiteral = unusedArgument (integer 99) []

unusedVariable :: Bool
unusedVariable = unusedArgument (variable callerParameterName intType) [(callerParameterName, intType)]

unusedArgument :: CoreExpression -> [(ResolvedName, Type)] -> Bool
unusedArgument argument callerParameters =
    let helper = returning helperName [(parameterName, intType)] intType (integer 42)
        invocation = call helperName [intType] intType [argument]
     in optimizedReturn (moduleWith [entry callerParameters intType [CoreReturn invocation], helper]) == Just (integer 42)

primitiveArgumentPreserved :: Bool
primitiveArgumentPreserved =
    let argument = primitive CoreAdd [integer 20, integer 22] intType
        options = defaultOptimizerOptions {optimizerConstantPropagation = False}
     in case runWith options (identityFixture argument []) >>= returnValue of
            Just (CoreLet fresh bindingType value (CoreVariable used resultType) letType) ->
                bindingType == intType
                    && value == argument
                    && resolvedSymbol fresh == resolvedSymbol used
                    && resultType == intType
                    && letType == intType
            _ -> False

nestedCallBecomesSafe :: Bool
nestedCallBecomesSafe =
    let argument = call leafName [] intType []
        invocation = call helperName [intType] intType [argument]
        helper = returning helperName [(parameterName, intType)] intType (variable parameterName intType)
        leaf = returning leafName [] intType (integer 42)
        options = defaultOptimizerOptions {optimizerMaximumIterations = 1, optimizerConstantPropagation = False}
     in (runWith options (moduleWith [entry [] intType [CoreReturn invocation], helper, leaf]) >>= returnValue)
            == Just (integer 42)

closureArgumentPreserved :: Bool
closureArgumentPreserved =
    let callableType = FunctionType [] intType
        argument = closure [] intType [CoreReturn (integer 42)]
        invocation = call helperName [callableType] callableType [argument]
        helper = returning helperName [(parameterName, callableType)] callableType (variable parameterName callableType)
        options =
            defaultOptimizerOptions
                { optimizerConstantPropagation = False
                , optimizerDeadCodeElimination = False
                }
     in case runWith options (moduleWith [entry [] callableType [CoreReturn invocation], helper]) >>= returnValue of
            Just (CoreLet fresh bindingType value (CoreVariable used resultType) letType) ->
                bindingType == callableType
                    && value == argument
                    && resolvedSymbol fresh == resolvedSymbol used
                    && resultType == callableType
                    && letType == callableType
            _ -> False

allocatingCalleeRejected :: Bool
allocatingCalleeRejected =
    let callableType = FunctionType [] intType
        helper = returning helperName [] callableType (closure [] intType [CoreReturn (integer 42)])
        invocation = call helperName [] callableType []
     in optimizedReturn (moduleWith [entry [] callableType [CoreReturn invocation], helper]) == Just invocation

failingCalleeRejected :: Bool
failingCalleeRejected =
    let divisor = variable parameterName intType
        result = primitive CoreDivide [integer 42, divisor] intType
        helper = returning helperName [(parameterName, intType)] intType result
        invocation = call helperName [intType] intType [integer 0]
     in optimizedReturn (moduleWith [entry [] intType [CoreReturn invocation], helper]) == Just invocation

indirectCalleeRejected :: Bool
indirectCalleeRejected =
    let callableType = FunctionType [] intType
        indirectName = named 20 "indirect"
        helper =
            returning helperName [(indirectName, callableType)] intType (CoreApply (variable indirectName callableType) [] intType)
        argument = closure [] intType [CoreReturn (integer 42)]
        invocation = call helperName [callableType] intType [argument]
     in optimizedReturn (moduleWith [entry [] intType [CoreReturn invocation], helper]) == Just invocation

selfRecursionRejected :: Bool
selfRecursionRejected =
    let invocation = call helperName [] intType []
        helper = returning helperName [] intType invocation
     in optimizedReturn (moduleWith [entry [] intType [CoreReturn invocation], helper]) == Just invocation

mutualRecursionRejected :: Bool
mutualRecursionRejected =
    let firstCall = call helperName [] intType []
        secondCall = call leafName [] intType []
        first = returning helperName [] intType secondCall
        second = returning leafName [] intType firstCall
     in optimizedReturn (moduleWith [entry [] intType [CoreReturn firstCall], first, second]) == Just firstCall

candidateBudget :: Bool
candidateBudget = budgetResult 2 complexResult == Just complexInvocation

expansionBudget :: Bool
expansionBudget = budgetResult 2 repeatedResult == Just repeatedInvocation

zeroBudget :: Bool
zeroBudget =
    let options = defaultOptimizerOptions {optimizerMaximumInlineExpressionNodes = 0}
     in (runWith options literalFixture >>= returnValue) == Just (integer 42)

complexResult, complexInvocation, repeatedResult, repeatedInvocation :: CoreExpression
complexResult = primitive CoreAdd [primitive CoreAdd [variable parameterName intType, integer 1] intType, integer 2] intType
complexInvocation = call helperName [intType] intType [integer 39]
repeatedResult = primitive CoreAdd [variable parameterName intType, variable parameterName intType] intType
repeatedInvocation = call helperName [intType] intType [integer 21]

budgetResult :: Int -> CoreExpression -> Maybe CoreExpression
budgetResult budget result =
    let invocation = if result == complexResult then complexInvocation else repeatedInvocation
        helper = returning helperName [(parameterName, intType)] intType result
        options = defaultOptimizerOptions {optimizerMaximumInlineExpressionNodes = budget, optimizerConstantPropagation = False}
     in runWith options (moduleWith [entry [] intType [CoreReturn invocation], helper]) >>= returnValue

disabledInlining :: Bool
disabledInlining = optionRetains defaultOptimizerOptions {optimizerInlining = False}

disabledEffects :: Bool
disabledEffects = optionRetains defaultOptimizerOptions {optimizerInterproceduralEffects = False}

optionRetains :: OptimizerOptions -> Bool
optionRetains options = (runWith options literalFixture >>= returnValue) == Just literalCall

inlineThenFold :: Bool
inlineThenFold =
    let result = primitive CoreAdd [variable parameterName intType, integer 1] intType
        helper = returning helperName [(parameterName, intType)] intType result
        invocation = call helperName [intType] intType [integer 41]
     in optimizedReturn (moduleWith [entry [] intType [CoreReturn invocation], helper]) == Just (integer 42)

pureCallChain :: Bool
pureCallChain =
    let helper = returning helperName [] intType (call leafName [] intType [])
        leaf = returning leafName [] intType (integer 42)
     in optimizedReturn (moduleWith [entry [] intType [CoreReturn literalCall], helper, leaf]) == Just (integer 42)

branchCondition :: Bool
branchCondition =
    let invocation = call helperName [] boolType []
        helper = returning helperName [] boolType (boolean True)
        caller = entry [] intType [CoreIf invocation [CoreReturn (integer 42)] [CoreReturn (integer 0)]]
     in optimizedReturn (moduleWith [caller, helper]) == Just (integer 42)

closureCapture :: Bool
closureCapture =
    let captureName = named 30 "captured"
        capture = CoreCapture StrongCapture captureName intType literalCall
        value = closure [capture] intType [CoreReturn (variable captureName intType)]
        helper = returning helperName [] intType (integer 42)
     in case optimizedReturn (moduleWith [entry [] (expressionType value) [CoreReturn value], helper]) of
            Just (CoreClosure [changed] _ _ _ _) -> coreCaptureValue changed == integer 42
            _ -> False

closureBody :: Bool
closureBody =
    let value = closure [] intType [CoreReturn literalCall]
        helper = returning helperName [] intType (integer 42)
     in case optimizedReturn (moduleWith [entry [] (expressionType value) [CoreReturn value], helper]) of
            Just (CoreClosure _ _ _ [CoreReturn result] _) -> result == integer 42
            _ -> False

reportCounts :: Bool
reportCounts = case run literalFixture of
    Just result -> case optimizationInlineReports result of
        report : _ -> inlineCandidateCount report == 2 && inlineRewrittenCalls report == 1
        [] -> False
    Nothing -> False

reportBudgetSkip :: Bool
reportBudgetSkip =
    let helper = returning helperName [(parameterName, intType)] intType complexResult
        options = defaultOptimizerOptions {optimizerMaximumInlineExpressionNodes = 2}
     in case runWith options (moduleWith [entry [] intType [CoreReturn complexInvocation], helper]) of
            Just result -> case optimizationInlineReports result of
                report : _ -> inlineCandidateCount report == 2 && inlineSkippedOversized report == 1
                [] -> False
            Nothing -> False

disabledReport :: Bool
disabledReport =
    let options = defaultOptimizerOptions {optimizerInlining = False}
     in maybe False (null . optimizationInlineReports) (runWith options literalFixture)

passOrder :: Bool
passOrder = case run literalFixture of
    Just result -> case optimizationPassReports result of
        report : _ -> passReportPass report == InliningPass
        [] -> False
    Nothing -> False

stableFunctionOrder :: Bool
stableFunctionOrder =
    let functions = coreModuleFunctions literalFixture
     in case run literalFixture of
            Just result -> map coreFunctionName (coreModuleFunctions (optimizedCore result)) == map coreFunctionName functions
            Nothing -> False

outputVerifies :: Bool
outputVerifies = case run literalFixture of
    Just result -> either (const False) (const True) (verifyCore (optimizedCore result))
    Nothing -> False

outputIdempotent :: Bool
outputIdempotent = case run literalFixture of
    Just first -> (optimizedCore <$> run (optimizedCore first)) == Just (optimizedCore first)
    Nothing -> False
