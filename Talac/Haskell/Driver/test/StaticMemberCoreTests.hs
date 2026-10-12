-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Core-boundary tests for selected static method identities.

Semantic success alone is insufficient: each overload call must become a
CoreApply to the selected function SymbolId, and CorePrep must preserve that
identity when it atomizes the call.
-}
module StaticMemberCoreTests (staticMemberCoreTests) where

import Data.List (sort)
import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Diagnostic

staticMemberCoreTests :: [(String, Bool)]
staticMemberCoreTests =
    [ ("Core keeps every overload as a distinct function", coreKeepsDistinctFunctions)
    , ("Core call target is the selected overload, not the lexical seed", coreTargetIsSelected)
    , ("Core source metadata has one entry per overload identity", coreOwnersAreUnique)
    , ("Core target and source owner share the same function identity", coreCallOwnerIdentityAgrees)
    , ("CorePrep retains the exact overload target", corePrepTargetIsSelected)
    , ("CorePrep retains the selected function declaration", corePrepFunctionIdentityIsStable)
    , ("two calls to one overload preserve target multiplicity", repeatedCoreCallsKeepMultiplicity)
    , ("calls to two overloads retain their distinct target identities", mixedCoreCallsKeepDistinctTargets)
    , ("unqualified overload dispatch lowers to its declaring method", unqualifiedCoreTargetIsSelected)
    , ("core lowering does not encode a selector as a synthesized name", coreTargetIsSourceFunction)
    , ("overload lowering preserves argument order", coreCallArgumentsPreserveOrder)
    , ("CorePrep preserves the argument order of the selected overload", corePrepCallArgumentsPreserveOrder)
    , ("overload lowering preserves the chosen function type", coreCallFunctionTypeIsExact)
    , ("overloaded methods with different owners do not alias", ownerNamesDoNotAlias)
    , ("all Core function ids remain globally unique in the unit", allCoreFunctionIdsAreUnique)
    , ("all CorePrep function ids remain globally unique in the unit", allCorePrepFunctionIdsAreUnique)
    , ("CorePrep output remains verified after overload lowering", corePrepExistsAndIsWellFormed)
    , ("Core retains one method symbol for each static overload", coreOverloadSymbolCountIsExact)
    , ("CorePrep retains the source file for each overload", corePrepOwnerFilesAreRetained)
    , ("overload resolution is independent of body return literals", bodyLiteralDoesNotChangeBinding)
    , ("the selected overload identity survives a branch in its body", branchBodyDoesNotChangeBinding)
    , ("the selected overload identity survives arithmetic around the call", arithmeticCallRetainsBinding)
    , ("the selected overload identity survives a local initializer", initializerCallRetainsBinding)
    , ("the selected overload identity survives a condition", conditionCallRetainsBinding)
    , ("the selected overload identity survives a loop condition", loopCallRetainsBinding)
    ]
        ++ scalarCoreSelectionTests

coreKeepsDistinctFunctions :: Bool
coreKeepsDistinctFunctions = case compiled fixture of
    Right artifacts -> case selectFunctions (artifactCore artifacts) of
        [first, second] -> resolvedSymbol (coreFunctionName first) /= resolvedSymbol (coreFunctionName second)
        _ -> False
    Left _ -> False

coreTargetIsSelected :: Bool
coreTargetIsSelected = case compiled fixture of
    Right artifacts -> matchingTargets intType (artifactCore artifacts) == namedFunctionSymbols "Select" intType (artifactCore artifacts)
    Left _ -> False

coreOwnersAreUnique :: Bool
coreOwnersAreUnique = case compiled fixture of
    Right artifacts ->
        let selectedIds = map (symbolIdValue . resolvedSymbol . coreFunctionName) (selectFunctions (artifactCore artifacts))
            owners = map fst (coreModuleFunctionSources (artifactCore artifacts))
         in all (\identity -> count identity owners == 1) selectedIds
    Left _ -> False

coreCallOwnerIdentityAgrees :: Bool
coreCallOwnerIdentityAgrees = case compiled fixture of
    Right artifacts -> case matchingTargets intType (artifactCore artifacts) of
        [target] ->
            let moduleValue = artifactCore artifacts
                owners = [owner | (identity, owner) <- coreModuleFunctionSources moduleValue, identity == symbolIdValue target]
             in owners == ["overload-core.tala"]
        _ -> False
    Left _ -> False

corePrepTargetIsSelected :: Bool
corePrepTargetIsSelected = case compiled fixture of
    Right artifacts ->
        matchingCorePrepTargets intType (artifactCorePrep artifacts)
            == namedCorePrepFunctionSymbols "Select" intType (artifactCorePrep artifacts)
    Left _ -> False

corePrepFunctionIdentityIsStable :: Bool
corePrepFunctionIdentityIsStable = case compiled fixture of
    Right artifacts ->
        let coreIds = sort (map (resolvedSymbol . coreFunctionName) (selectFunctions (artifactCore artifacts)))
            prepIds = sort (map (resolvedSymbol . corePrepFunctionName) (selectCorePrepFunctions (artifactCorePrep artifacts)))
         in coreIds == prepIds
    Left _ -> False

repeatedCoreCallsKeepMultiplicity :: Bool
repeatedCoreCallsKeepMultiplicity = case compiled repeatedCalls of
    Right artifacts -> case matchingTargets intType (artifactCore artifacts) of
        [first, second] -> first == second
        _ -> False
    Left _ -> False

mixedCoreCallsKeepDistinctTargets :: Bool
mixedCoreCallsKeepDistinctTargets = case compiled mixedCalls of
    Right artifacts ->
        let targets = matchingTargetsAny "Select" (artifactCore artifacts)
         in length targets == 2 && length (unique targets) == 2
    Left _ -> False

unqualifiedCoreTargetIsSelected :: Bool
unqualifiedCoreTargetIsSelected = case compiled unqualifiedCall of
    Right artifacts ->
        let moduleValue = artifactCore artifacts
            targets = matchingTargets intType moduleValue
            selected = namedFunctionSymbols "Select" intType moduleValue
         in targets == selected && not (null targets)
    Left _ -> False

coreTargetIsSourceFunction :: Bool
coreTargetIsSourceFunction = case compiled fixture of
    Right artifacts ->
        let moduleValue = artifactCore artifacts
            targetNames = map resolvedSpelling (matchingTargetsAny "Select" moduleValue)
            declarations = map (resolvedSpelling . coreFunctionName) (coreModuleFunctions moduleValue)
         in not (null targetNames) && all (`elem` declarations) targetNames
    Left _ -> False

coreCallArgumentsPreserveOrder :: Bool
coreCallArgumentsPreserveOrder = case compiled twoArguments of
    Right artifacts -> case callArgumentsFor "Select" (artifactCore artifacts) of
        [[CoreVariable first _, CoreVariable second _]] ->
            resolvedSpelling first == Identifier "left"
                && resolvedSpelling second == Identifier "right"
                && resolvedSymbol first /= resolvedSymbol second
        _ -> False
    Left _ -> False

corePrepCallArgumentsPreserveOrder :: Bool
corePrepCallArgumentsPreserveOrder = case compiled twoArguments of
    Right artifacts -> case corePrepCallArgumentsFor "Select" (artifactCorePrep artifacts) of
        [[CorePrepVariable first _, CorePrepVariable second _]] ->
            resolvedSpelling first == Identifier "left"
                && resolvedSpelling second == Identifier "right"
                && resolvedSymbol first /= resolvedSymbol second
        _ -> False
    Left _ -> False

coreCallFunctionTypeIsExact :: Bool
coreCallFunctionTypeIsExact = case compiled fixture of
    Right artifacts -> case callTypesFor "Select" (artifactCore artifacts) of
        [FunctionType [parameter] result] -> parameter == intType && result == intType
        _ -> False
    Left _ -> False

ownerNamesDoNotAlias :: Bool
ownerNamesDoNotAlias = case compiled twoOwners of
    Right artifacts ->
        let first = namedFunctions "FirstRead" (artifactCore artifacts)
            second = namedFunctions "SecondRead" (artifactCore artifacts)
         in case (first, second) of
                ([left], [right]) -> resolvedSymbol (coreFunctionName left) /= resolvedSymbol (coreFunctionName right)
                _ -> False
    Left _ -> False

allCoreFunctionIdsAreUnique :: Bool
allCoreFunctionIdsAreUnique = case compiled fixture of
    Right artifacts -> uniqueSymbols (map (resolvedSymbol . coreFunctionName) (coreModuleFunctions (artifactCore artifacts)))
    Left _ -> False

allCorePrepFunctionIdsAreUnique :: Bool
allCorePrepFunctionIdsAreUnique = case compiled fixture of
    Right artifacts -> uniqueSymbols (map (resolvedSymbol . corePrepFunctionName) (corePrepModuleFunctions (artifactCorePrep artifacts)))
    Left _ -> False

corePrepExistsAndIsWellFormed :: Bool
corePrepExistsAndIsWellFormed = case compiled fixture of
    Right artifacts ->
        let prepared = artifactCorePrep artifacts
         in not (null (corePrepModuleFunctions prepared))
                && all ((> 0) . symbolIdValue . resolvedSymbol . corePrepFunctionName) (corePrepModuleFunctions prepared)
                && all (not . null . corePrepFunctionBlocks) (corePrepModuleFunctions prepared)
    Left _ -> False

coreOverloadSymbolCountIsExact :: Bool
coreOverloadSymbolCountIsExact = case compiled fixture of
    Right artifacts -> length (selectFunctions (artifactCore artifacts)) == 2
    Left _ -> False

corePrepOwnerFilesAreRetained :: Bool
corePrepOwnerFilesAreRetained = case compiled fixture of
    Right artifacts ->
        let prepared = corePrepModuleFunctions (artifactCorePrep artifacts)
            selected = selectCorePrepFunctions (artifactCorePrep artifacts)
         in length selected == 2
                && all ((== "overload-core.tala") . corePrepFunctionSourceFile) selected
                && all (`elem` prepared) selected
    Left _ -> False

bodyLiteralDoesNotChangeBinding :: Bool
bodyLiteralDoesNotChangeBinding =
    exactTargetFor
        "class Catalog { public static int Select(long value) { if (value > 0) { return 0; } else { return 2; } } public static int Select(int value) { if (value > 0) { return 1; } else { return 3; } } } class Caller { int Invoke(int value) { return Catalog.Select(value); } }"
        intType

branchBodyDoesNotChangeBinding :: Bool
branchBodyDoesNotChangeBinding = exactTargetFor branchFixture intType

arithmeticCallRetainsBinding :: Bool
arithmeticCallRetainsBinding =
    exactTargetFor
        "class Catalog { public static int Select(long value) { if (value > 0) { return 1; } else { return 2; } } public static int Select(int value) { if (value > 0) { return value; } else { return 3; } } } class Caller { int Invoke(int value) { return Catalog.Select(value) + 1; } }"
        intType

initializerCallRetainsBinding :: Bool
initializerCallRetainsBinding =
    exactTargetFor
        "class Catalog { public static int Select(long value) { if (value > 0) { return 1; } else { return 2; } } public static int Select(int value) { if (value > 0) { return value; } else { return 3; } } } class Caller { int Invoke(int value) { int result = Catalog.Select(value); return result; } }"
        intType

conditionCallRetainsBinding :: Bool
conditionCallRetainsBinding =
    exactTargetFor
        "class Catalog { public static bool Select(long value) { if (value > 0) { return true; } else { return false; } } public static bool Select(int value) { if (value > 0) { return false; } else { return true; } } } class Caller { int Invoke(int value) { if (Catalog.Select(value)) { return 1; } else { return 0; } } }"
        intType

loopCallRetainsBinding :: Bool
loopCallRetainsBinding =
    exactTargetFor
        "class Catalog { public static bool Select(long value) { if (value > 0) { return true; } else { return false; } } public static bool Select(int value) { if (value > 0) { return false; } else { return true; } } } class Caller { int Invoke(int value) { while (Catalog.Select(value)) { return 1; } return 0; } }"
        intType

scalarCoreSelectionTests :: [(String, Bool)]
scalarCoreSelectionTests =
    [ ( "Core and CorePrep bind " ++ scalarTypeName selected ++ " instead of " ++ scalarTypeName distractor
      , exactTargetFor (scalarBranchFixture (scalarTypeName selected) (scalarTypeName distractor)) (scalarTypeToType selected)
      )
    | (selected, distractor) <- scalarPairs
    ]

scalarPairs :: [(ScalarType, ScalarType)]
scalarPairs =
    [ (selected, nextScalar selected)
    | selected <- scalarTypes
    ]
    where
        nextScalar value = case dropWhile (/= value) scalarTypes of
            _ : following : _ -> following
            _ -> case scalarTypes of
                first : _ -> first
                [] -> value

exactTargetFor :: String -> Type -> Bool
exactTargetFor source targetType = case compiled source of
    Right artifacts ->
        let core = artifactCore artifacts
            prepared = artifactCorePrep artifacts
            coreTargets = matchingTargets targetType core
            functionSymbols = namedFunctionSymbols "Select" targetType core
            preparedTargets = matchingCorePrepTargets targetType prepared
            preparedFunctions = namedCorePrepFunctionSymbols "Select" targetType prepared
         in singletonAgreement coreTargets functionSymbols
                && singletonAgreement preparedTargets preparedFunctions
                && coreTargets == preparedTargets
    Left _ -> False

singletonAgreement :: (Eq value) => [value] -> [value] -> Bool
singletonAgreement [first] [second] = first == second
singletonAgreement _ _ = False

compiled :: String -> Either [Diagnostic] FrontendArtifacts
compiled = compileToCorePrep . CompilerInput "overload-core.tala"

selectFunctions :: CoreModule -> [CoreFunction]
selectFunctions = namedFunctions "Select"

namedFunctions :: String -> CoreModule -> [CoreFunction]
namedFunctions spelling moduleValue =
    [ function
    | function <- coreModuleFunctions moduleValue
    , resolvedSpelling (coreFunctionName function) == Identifier spelling
    ]

namedFunctionSymbols :: String -> Type -> CoreModule -> [SymbolId]
namedFunctionSymbols spelling parameterType moduleValue =
    [ resolvedSymbol (coreFunctionName function)
    | function <- namedFunctions spelling moduleValue
    , [(_, actualType)] <- [coreFunctionParameters function]
    , actualType == parameterType
    ]

matchingTargets :: Type -> CoreModule -> [SymbolId]
matchingTargets targetType moduleValue =
    [ resolvedSymbol target
    | target <- matchingTargetsAny "Select" moduleValue
    , maybe False (== targetType) (callParameterType target moduleValue)
    ]

matchingTargetsAny :: String -> CoreModule -> [ResolvedName]
matchingTargetsAny spelling moduleValue = filter ((== Identifier spelling) . resolvedSpelling) (coreCallTargets moduleValue)

matchingCorePrepTargets :: Type -> CorePrepModule -> [SymbolId]
matchingCorePrepTargets targetType moduleValue =
    [ resolvedSymbol target
    | target <- corePrepCallTargets moduleValue
    , maybe False (== targetType) (corePrepParameterType target moduleValue)
    ]

namedCorePrepFunctionSymbols :: String -> Type -> CorePrepModule -> [SymbolId]
namedCorePrepFunctionSymbols spelling parameterType moduleValue =
    [ resolvedSymbol (corePrepFunctionName function)
    | function <- corePrepModuleFunctions moduleValue
    , resolvedSpelling (corePrepFunctionName function) == Identifier spelling
    , [(_, actualType)] <- [corePrepFunctionParameters function]
    , actualType == parameterType
    ]

callParameterType :: ResolvedName -> CoreModule -> Maybe Type
callParameterType target moduleValue = do
    function <- findCoreFunction target (coreModuleFunctions moduleValue)
    (_, parameterType) <- exactlyOneValue (coreFunctionParameters function)
    pure parameterType

corePrepParameterType :: ResolvedName -> CorePrepModule -> Maybe Type
corePrepParameterType target moduleValue = do
    function <- findCorePrepFunction target (corePrepModuleFunctions moduleValue)
    (_, parameterType) <- exactlyOneValue (corePrepFunctionParameters function)
    pure parameterType

findCoreFunction :: ResolvedName -> [CoreFunction] -> Maybe CoreFunction
findCoreFunction _ [] = Nothing
findCoreFunction requested (function : remaining)
    | resolvedSymbol requested == resolvedSymbol (coreFunctionName function) = Just function
    | otherwise = findCoreFunction requested remaining

findCorePrepFunction :: ResolvedName -> [CorePrepFunction] -> Maybe CorePrepFunction
findCorePrepFunction _ [] = Nothing
findCorePrepFunction requested (function : remaining)
    | resolvedSymbol requested == resolvedSymbol (corePrepFunctionName function) = Just function
    | otherwise = findCorePrepFunction requested remaining

callArgumentsFor :: String -> CoreModule -> [[CoreExpression]]
callArgumentsFor spelling moduleValue = concatMap (functionCalls . coreFunctionBody) (coreModuleFunctions moduleValue)
    where
        functionCalls = concatMap statementCalls
        statementCalls statement = case statement of
            CoreBind binding -> expressionCalls (coreBindingValue binding)
            CoreAssign _ value -> expressionCalls value
            CoreReturn value -> expressionCalls value
            CoreIf condition yes no -> expressionCalls condition ++ concatMap statementCalls yes ++ concatMap statementCalls no
            CoreEvaluate value -> expressionCalls value
            CoreWhile condition body -> expressionCalls condition ++ concatMap statementCalls body
            CoreDoWhile body condition -> concatMap statementCalls body ++ expressionCalls condition
            CoreFor condition updates body -> expressionCalls condition ++ concatMap statementCalls updates ++ concatMap statementCalls body
            CoreBreak -> []
            CoreContinue -> []
        expressionCalls expression = case expression of
            CoreVariable _ _ -> []
            CoreLiteral _ _ -> []
            CoreApply (CoreVariable target _) arguments _ ->
                (if resolvedSpelling target == Identifier spelling then [arguments] else [])
                    ++ concatMap expressionCalls arguments
            CoreApply callee arguments _ -> expressionCalls callee ++ concatMap expressionCalls arguments
            CorePrimitive _ arguments _ -> concatMap expressionCalls arguments
            CoreLet _ _ value body _ -> expressionCalls value ++ expressionCalls body
            CoreConditional condition whenTrue whenFalse _ -> concatMap expressionCalls [condition, whenTrue, whenFalse]
            CoreClosure _ _ _ statements _ -> concatMap statementCalls statements

callTypesFor :: String -> CoreModule -> [Type]
callTypesFor spelling moduleValue = concatMap (functionCallTypes . coreFunctionBody) (coreModuleFunctions moduleValue)
    where
        functionCallTypes = concatMap statementTypes
        statementTypes statement = case statement of
            CoreBind binding -> expressionTypes (coreBindingValue binding)
            CoreAssign _ value -> expressionTypes value
            CoreReturn value -> expressionTypes value
            CoreIf condition yes no -> expressionTypes condition ++ concatMap statementTypes yes ++ concatMap statementTypes no
            CoreEvaluate value -> expressionTypes value
            CoreWhile condition body -> expressionTypes condition ++ concatMap statementTypes body
            CoreDoWhile body condition -> concatMap statementTypes body ++ expressionTypes condition
            CoreFor condition updates body -> expressionTypes condition ++ concatMap statementTypes updates ++ concatMap statementTypes body
            CoreBreak -> []
            CoreContinue -> []
        expressionTypes expression = case expression of
            CoreVariable _ _ -> []
            CoreLiteral _ _ -> []
            CoreApply (CoreVariable target functionType) arguments _ ->
                (if resolvedSpelling target == Identifier spelling then [functionType] else [])
                    ++ concatMap expressionTypes arguments
            CoreApply callee arguments _ -> expressionTypes callee ++ concatMap expressionTypes arguments
            CorePrimitive _ arguments _ -> concatMap expressionTypes arguments
            CoreLet _ _ value body _ -> expressionTypes value ++ expressionTypes body
            CoreConditional condition whenTrue whenFalse _ -> concatMap expressionTypes [condition, whenTrue, whenFalse]
            CoreClosure _ _ _ statements _ -> concatMap statementTypes statements

coreCallTargets :: CoreModule -> [ResolvedName]
coreCallTargets moduleValue = concatMap (concatMap statementTargets . coreFunctionBody) (coreModuleFunctions moduleValue)

statementTargets :: CoreStatement -> [ResolvedName]
statementTargets statement = case statement of
    CoreBind binding -> expressionTargets (coreBindingValue binding)
    CoreAssign _ value -> expressionTargets value
    CoreReturn value -> expressionTargets value
    CoreIf condition yes no -> expressionTargets condition ++ concatMap statementTargets yes ++ concatMap statementTargets no
    CoreEvaluate value -> expressionTargets value
    CoreWhile condition body -> expressionTargets condition ++ concatMap statementTargets body
    CoreDoWhile body condition -> concatMap statementTargets body ++ expressionTargets condition
    CoreFor condition updates body -> expressionTargets condition ++ concatMap statementTargets updates ++ concatMap statementTargets body
    CoreBreak -> []
    CoreContinue -> []

expressionTargets :: CoreExpression -> [ResolvedName]
expressionTargets expression = case expression of
    CoreVariable {} -> []
    CoreLiteral {} -> []
    CoreApply callee arguments _ -> calledTarget callee ++ expressionTargets callee ++ concatMap expressionTargets arguments
    CorePrimitive _ arguments _ -> concatMap expressionTargets arguments
    CoreLet _ _ value body _ -> expressionTargets value ++ expressionTargets body
    CoreConditional condition whenTrue whenFalse _ -> concatMap expressionTargets [condition, whenTrue, whenFalse]
    CoreClosure _ _ _ body _ -> concatMap statementTargets body
    where
        calledTarget (CoreVariable name _) = [name]
        calledTarget _ = []

corePrepCallTargets :: CorePrepModule -> [ResolvedName]
corePrepCallTargets moduleValue = concatMap (concatMap blockTargets . corePrepFunctionBlocks) (corePrepModuleFunctions moduleValue)
    where
        blockTargets block = concatMap instructionTargets (corePrepBlockInstructions block)
        instructionTargets instruction = case instruction of
            CorePrepBind _ _ _ operation -> operationTargets operation
            CorePrepAssign _ _ -> []
            CorePrepEvaluate operation -> operationTargets operation
        operationTargets operation = case operation of
            CorePrepCall (CorePrepVariable name _) _ -> [name]
            CorePrepCall _ _ -> []
            CorePrepCopy _ -> []
            CorePrepPrimitive _ _ -> []
            CorePrepMakeClosure _ _ -> []

corePrepCallArgumentsFor :: String -> CorePrepModule -> [[CorePrepAtom]]
corePrepCallArgumentsFor spelling moduleValue = concatMap (concatMap blockArguments . corePrepFunctionBlocks) (corePrepModuleFunctions moduleValue)
    where
        blockArguments block = concatMap instructionArguments (corePrepBlockInstructions block)
        instructionArguments instruction = case instruction of
            CorePrepBind _ _ _ operation -> operationArguments operation
            CorePrepAssign _ _ -> []
            CorePrepEvaluate operation -> operationArguments operation
        operationArguments operation = case operation of
            CorePrepCall (CorePrepVariable target _) arguments
                | resolvedSpelling target == Identifier spelling -> [arguments]
            _ -> []

selectCorePrepFunctions :: CorePrepModule -> [CorePrepFunction]
selectCorePrepFunctions moduleValue =
    [ function
    | function <- corePrepModuleFunctions moduleValue
    , resolvedSpelling (corePrepFunctionName function) == Identifier "Select"
    ]

uniqueSymbols :: [SymbolId] -> Bool
uniqueSymbols symbols = length symbols == length (unique symbols)

unique :: (Eq value) => [value] -> [value]
unique [] = []
unique (value : remaining) = value : unique (filter (/= value) remaining)

count :: (Eq value) => value -> [value] -> Int
count requested = length . filter (== requested)

exactlyOneValue :: [value] -> Maybe value
exactlyOneValue values = case values of
    [value] -> Just value
    _ -> Nothing

fixture :: String
fixture =
    "class Catalog { public static int Select(long value) { if (value > 0) { return 1; } else { return 0; } } public static int Select(int value) { if (value > 0) { return value; } else { return 0; } } } class Caller { public static int Invoke(int value) { return Catalog.Select(value); } }"

branchFixture :: String
branchFixture =
    "class Catalog { public static int Select(long value) { if (value > 0) { return 1; } else { return 0; } } public static int Select(int value) { if (value > 0) { return value; } else { return 0; } } } class Caller { int Invoke(int value) { if (value > 0) { return Catalog.Select(value); } else { return 0; } } }"

repeatedCalls :: String
repeatedCalls =
    "class Catalog { public static int Select(long value) { if (value > 0) { return 1; } else { return 0; } } public static int Select(int value) { if (value > 0) { return value; } else { return 0; } } } class Caller { int Invoke(int value) { return Catalog.Select(value) + Catalog.Select(value); } }"

mixedCalls :: String
mixedCalls =
    "class Catalog { public static int Select(long value) { if (value > 0) { return 1; } else { return 0; } } public static int Select(int value) { if (value > 0) { return value; } else { return 0; } } } class Caller { int Invoke(int integer, long wider) { return Catalog.Select(integer) + Catalog.Select(wider); } }"

unqualifiedCall :: String
unqualifiedCall =
    "class Catalog { public static int Select(long value) { if (value > 0) { return 1; } else { return 0; } } public static int Select(int value) { if (value > 0) { return value; } else { return 0; } } int Invoke(int value) { return Select(value); } }"

twoArguments :: String
twoArguments =
    "class Catalog { public static int Select(int first, int second) { if (first > 0) { return second; } else { return 0; } } public static int Select(long first, long second) { if (first > 0) { return 1; } else { return 0; } } } class Caller { int Invoke(int left, int right) { return Catalog.Select(left, right); } }"

twoOwners :: String
twoOwners =
    "class First { public static int FirstRead(int value) { if (value > 0) { return value; } else { return 0; } } } class Second { public static int SecondRead(int value) { if (value > 0) { return value; } else { return 0; } } } class Caller { int Invoke(int value) { return First.FirstRead(value) + Second.SecondRead(value); } }"

scalarBranchFixture :: String -> String -> String
scalarBranchFixture selected distractor =
    "class Catalog { public static int Select("
        ++ distractor
        ++ " other) { "
        ++ distractor
        ++ " copy = other; if (other == copy) { return 1; } else { return 0; } } public static int Select("
        ++ selected
        ++ " value) { "
        ++ selected
        ++ " copy = value; if (value == copy) { return 2; } else { return 0; } } public static int Invoke("
        ++ selected
        ++ " value) { return Select(value); } }"
