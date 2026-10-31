-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
module ShortCircuitTests (shortCircuitTests) where

import Data.List (isPrefixOf, nub)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier (verifyCorePrep)
import Progmasoft.Tala.Diagnostic (Diagnostic)

shortCircuitTests :: [(String, Bool)]
shortCircuitTests =
    [ ("logical AND lowers to a branch and join", andHasExpectedShape)
    , ("logical OR reverses the short-circuit edge", orHasExpectedShape)
    , ("logical primitives never survive CorePrep", noEagerLogicalPrimitives)
    , ("AND result storage starts as false", andSeedIsFalse)
    , ("OR result storage starts as true", orSeedIsTrue)
    , ("short-circuit result storage is mutable Bool", resultStorageIsMutableBool)
    , ("right operand assigns the short-circuit result", rightOperandAssignsResult)
    , ("numeric left operands become Bool before branching", numericLeftIsBooleanized)
    , ("numeric right operands become Bool before assignment", numericRightIsBooleanized)
    , ("Boolean operands do not acquire redundant comparisons", booleanOperandsAvoidComparisons)
    , ("nested conjunction creates two conditional regions", nestedAndCreatesTwoRegions)
    , ("nested disjunction creates two conditional regions", nestedOrCreatesTwoRegions)
    , ("mixed nested logical expressions create three regions", mixedTreeCreatesThreeRegions)
    , ("logical expressions in bindings resume at their join", bindingContinuesAfterJoin)
    , ("logical expressions in assignments resume at their join", assignmentContinuesAfterJoin)
    , ("logical expressions in returns terminate the join", returnTerminatesJoin)
    , ("logical expressions used as call arguments preserve order", callArgumentContinuesAtJoin)
    , ("logical expressions used as a callee preserve order", calleeContinuesAtJoin)
    , ("logical expressions used as if conditions compose CFG", conditionComposesControlFlow)
    , ("logical expressions used as closure captures compose CFG", captureComposesControlFlow)
    , ("every generated block id is unique", generatedBlockIdsAreUnique)
    , ("every generated branch target exists", generatedTargetsExist)
    , ("every short-circuit result has exactly one seed", eachResultHasOneSeed)
    , ("every short-circuit result has exactly one conditional assignment", eachResultHasOneAssignment)
    , ("temporary symbols remain globally unique", generatedSymbolsAreUnique)
    , ("the CorePrep verifier accepts simple AND", verifierAcceptsAnd)
    , ("the CorePrep verifier accepts simple OR", verifierAcceptsOr)
    , ("the CorePrep verifier accepts nested logical control flow", verifierAcceptsNested)
    , ("false AND keeps its right call behind a branch", andCallIsConditional)
    , ("true OR keeps its right call behind a branch", orCallIsConditional)
    ]

andHasExpectedShape :: Bool
andHasExpectedShape = case preparedFunction (returning (logical CoreLogicalAnd boolTrue boolFalse)) of
    Just function ->
        length (corePrepFunctionBlocks function) == 3
            && branchTargets function == [(1, 2)]
            && jumpTargets function == [2]
    Nothing -> False

orHasExpectedShape :: Bool
orHasExpectedShape = case preparedFunction (returning (logical CoreLogicalOr boolFalse boolTrue)) of
    Just function -> branchTargets function == [(2, 1)] && jumpTargets function == [2]
    Nothing -> False

noEagerLogicalPrimitives :: Bool
noEagerLogicalPrimitives = all (not . containsEagerLogical) (allInstructions mixedPrepared)

andSeedIsFalse :: Bool
andSeedIsFalse = seedValues andPrepared == [False]

orSeedIsTrue :: Bool
orSeedIsTrue = seedValues orPrepared == [True]

resultStorageIsMutableBool :: Bool
resultStorageIsMutableBool = case shortCircuitSeeds andPrepared of
    [CorePrepBind _ valueType mutable _] -> valueType == boolType && mutable
    _ -> False

rightOperandAssignsResult :: Bool
rightOperandAssignsResult = case (shortCircuitNames andPrepared, shortCircuitAssignments andPrepared) of
    ([seed], [assigned]) -> seed == assigned
    _ -> False

numericLeftIsBooleanized :: Bool
numericLeftIsBooleanized =
    hasComparisonToZero intType numericPrepared
        && all ((== boolType) . atomType) (branchConditions numericPrepared)

numericRightIsBooleanized :: Bool
numericRightIsBooleanized =
    hasComparisonToZero floatType numericPrepared
        && all ((== boolType) . atomType) (assignmentValues numericPrepared)

booleanOperandsAvoidComparisons :: Bool
booleanOperandsAvoidComparisons = not (any isNotEqual (allInstructions andPrepared))

nestedAndCreatesTwoRegions :: Bool
nestedAndCreatesTwoRegions = length (branchConditions nestedAndPrepared) == 2

nestedOrCreatesTwoRegions :: Bool
nestedOrCreatesTwoRegions = length (branchConditions nestedOrPrepared) == 2

mixedTreeCreatesThreeRegions :: Bool
mixedTreeCreatesThreeRegions =
    length (branchConditions mixedPrepared) == 3
        && length (shortCircuitSeeds mixedPrepared) == 3
        && length (shortCircuitAssignments mixedPrepared) == 3

bindingContinuesAfterJoin :: Bool
bindingContinuesAfterJoin = case preparedFunction statements of
    Just function -> any joinContainsBinding (corePrepFunctionBlocks function)
    Nothing -> False
    where
        value = name 20 "value"
        statements =
            [ CoreBind (CoreBinding value boolType False (logical CoreLogicalAnd boolTrue boolFalse))
            , CoreReturn unitLiteral
            ]
        joinContainsBinding block = any bindsValue (corePrepBlockInstructions block)
        bindsValue (CorePrepBind bound _ _ _) = bound == value
        bindsValue _ = False

assignmentContinuesAfterJoin :: Bool
assignmentContinuesAfterJoin = case preparedFunction statements of
    Just function -> any joinContainsAssignment (corePrepFunctionBlocks function)
    Nothing -> False
    where
        value = name 20 "value"
        statements =
            [ CoreBind (CoreBinding value boolType True boolFalse)
            , CoreAssign value (logical CoreLogicalOr boolFalse boolTrue)
            , CoreReturn unitLiteral
            ]
        joinContainsAssignment block = any assignsValue (corePrepBlockInstructions block)
        assignsValue (CorePrepAssign assigned _) = assigned == value
        assignsValue _ = False

returnTerminatesJoin :: Bool
returnTerminatesJoin = case preparedFunction (returning (logical CoreLogicalAnd boolTrue boolFalse)) of
    Just function -> case reverse (corePrepFunctionBlocks function) of
        block : _ -> case corePrepBlockTerminator block of
            CorePrepReturn value -> atomType value == boolType
            _ -> False
        [] -> False
    Nothing -> False

callArgumentContinuesAtJoin :: Bool
callArgumentContinuesAtJoin = case preparedFunction (returning call) of
    Just function -> exactlyOneCall function && callBlockIsJoin function
    Nothing -> False
    where
        call = CoreApply functionVariable [logical CoreLogicalAnd boolTrue boolFalse] boolType

calleeContinuesAtJoin :: Bool
calleeContinuesAtJoin = case preparedFunction (returning call) of
    Just function -> exactlyOneCall function && length (branchConditions (Just function)) == 1
    Nothing -> False
    where
        argument = name 51 "argument"
        callableType = FunctionType [boolType] boolType
        callee =
            CoreClosure
                []
                [(argument, boolType)]
                boolType
                [CoreReturn (CoreVariable argument boolType)]
                callableType
        call = CoreApply callee [logical CoreLogicalOr boolFalse boolTrue] boolType

conditionComposesControlFlow :: Bool
conditionComposesControlFlow = case preparedFunction statements of
    Just function ->
        length (branchConditions (Just function)) == 2
            && allTargetsExist function
    Nothing -> False
    where
        statements =
            [ CoreIf
                (logical CoreLogicalAnd boolTrue boolFalse)
                [CoreReturn unitLiteral]
                [CoreReturn unitLiteral]
            ]

captureComposesControlFlow :: Bool
captureComposesControlFlow = case preparedModule statements of
    Right moduleValue ->
        length (corePrepModuleFunctions moduleValue) == 2
            && length (branchConditions (preparedFunctionFromModule moduleValue)) == 1
    Left _ -> False
    where
        capture = CoreCapture StrongCapture (name 40 "enabled") boolType (logical CoreLogicalOr boolFalse boolTrue)
        closure = CoreClosure [capture] [] boolType [CoreReturn (CoreVariable (name 40 "enabled") boolType)] nullaryBoolFunction
        statements = [CoreEvaluate closure, CoreReturn unitLiteral]

generatedBlockIdsAreUnique :: Bool
generatedBlockIdsAreUnique = case mixedPrepared of
    Just function -> unique (map corePrepBlockId (corePrepFunctionBlocks function))
    Nothing -> False

generatedTargetsExist :: Bool
generatedTargetsExist = maybe False allTargetsExist mixedPrepared

eachResultHasOneSeed :: Bool
eachResultHasOneSeed =
    let names = shortCircuitNames mixedPrepared
     in unique names && length names == 3

eachResultHasOneAssignment :: Bool
eachResultHasOneAssignment =
    let seeds = shortCircuitNames mixedPrepared
        assignments = shortCircuitAssignments mixedPrepared
     in all (\seed -> count seed assignments == 1) seeds

generatedSymbolsAreUnique :: Bool
generatedSymbolsAreUnique = unique (generatedBindingSymbols mixedPrepared)

verifierAcceptsAnd :: Bool
verifierAcceptsAnd = maybe False (verifierAccepts . singletonModule) andPrepared

verifierAcceptsOr :: Bool
verifierAcceptsOr = maybe False (verifierAccepts . singletonModule) orPrepared

verifierAcceptsNested :: Bool
verifierAcceptsNested = maybe False (verifierAccepts . singletonModule) mixedPrepared

andCallIsConditional :: Bool
andCallIsConditional = callIsSeparatedFromEntry CoreLogicalAnd boolFalse

orCallIsConditional :: Bool
orCallIsConditional = callIsSeparatedFromEntry CoreLogicalOr boolTrue

andPrepared :: Maybe CorePrepFunction
andPrepared = preparedFunction (returning (logical CoreLogicalAnd boolTrue boolFalse))

orPrepared :: Maybe CorePrepFunction
orPrepared = preparedFunction (returning (logical CoreLogicalOr boolFalse boolTrue))

numericPrepared :: Maybe CorePrepFunction
numericPrepared =
    preparedFunction
        ( returning
            ( logical
                CoreLogicalAnd
                (CoreVariable (name 2 "integer") intType)
                (CoreVariable (name 3 "floating") floatType)
            )
        )

nestedAndPrepared :: Maybe CorePrepFunction
nestedAndPrepared =
    preparedFunction
        (returning (logical CoreLogicalAnd boolTrue (logical CoreLogicalAnd boolFalse boolTrue)))

nestedOrPrepared :: Maybe CorePrepFunction
nestedOrPrepared =
    preparedFunction
        (returning (logical CoreLogicalOr (logical CoreLogicalOr boolFalse boolTrue) boolFalse))

mixedPrepared :: Maybe CorePrepFunction
mixedPrepared =
    preparedFunction
        ( returning
            ( logical
                CoreLogicalAnd
                (logical CoreLogicalOr boolFalse boolTrue)
                (logical CoreLogicalAnd boolTrue boolFalse)
            )
        )

preparedFunction :: [CoreStatement] -> Maybe CorePrepFunction
preparedFunction statements = case preparedModule statements of
    Right moduleValue -> case corePrepModuleFunctions moduleValue of
        function : _ -> Just function
        [] -> Nothing
    Left _ -> Nothing

preparedModule :: [CoreStatement] -> Either [Diagnostic] CorePrepModule
preparedModule statements = case prepareCore moduleValue of
    Right prepared -> Right prepared
    Left _ -> error "prepareCore currently cannot fail after verified Core"
    where
        moduleValue = CoreModuleWithSources (QualifiedName [Identifier "ShortCircuit"]) [testFunction statements] [] []

preparedFunctionFromModule :: CorePrepModule -> Maybe CorePrepFunction
preparedFunctionFromModule moduleValue = case corePrepModuleFunctions moduleValue of
    function : _ -> Just function
    [] -> Nothing

testFunction :: [CoreStatement] -> CoreFunction
testFunction statements = CoreFunction (name 1 "Evaluate") parameters returnType statements
    where
        parameters =
            [ (name 2 "integer", intType)
            , (name 3 "floating", floatType)
            , (name 31 "leftFunction", nullaryBoolFunction)
            , (name 32 "rightFunction", nullaryBoolFunction)
            , (name 50 "Predicate", FunctionType [boolType] boolType)
            ]
        returnType = case reverse statements of
            CoreReturn expression : _ -> expressionType expression
            _ -> unitType

returning :: CoreExpression -> [CoreStatement]
returning expression = [CoreReturn expression]

logical :: CorePrimitive -> CoreExpression -> CoreExpression -> CoreExpression
logical primitive left right = logicalWithType primitive left right boolType

logicalWithType :: CorePrimitive -> CoreExpression -> CoreExpression -> Type -> CoreExpression
logicalWithType primitive left right resultType = CorePrimitive primitive [left, right] resultType

boolTrue :: CoreExpression
boolTrue = CoreLiteral (CoreBoolean True) boolType

boolFalse :: CoreExpression
boolFalse = CoreLiteral (CoreBoolean False) boolType

unitLiteral :: CoreExpression
unitLiteral = CoreLiteral CoreUnit unitType

floatType :: Type
floatType = namedType "float"

nullaryBoolFunction :: Type
nullaryBoolFunction = FunctionType [] boolType

functionVariable :: CoreExpression
functionVariable = CoreVariable (name 50 "Predicate") (FunctionType [boolType] boolType)

name :: Int -> String -> ResolvedName
name symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

allBlocks :: Maybe CorePrepFunction -> [CorePrepBlock]
allBlocks = maybe [] corePrepFunctionBlocks

allInstructions :: Maybe CorePrepFunction -> [CorePrepInstruction]
allInstructions = concatMap corePrepBlockInstructions . allBlocks

branchConditions :: Maybe CorePrepFunction -> [CorePrepAtom]
branchConditions = foldMap condition . allBlocks
    where
        condition block = case corePrepBlockTerminator block of
            CorePrepBranch value _ _ -> [value]
            _ -> []

branchTargets :: CorePrepFunction -> [(Int, Int)]
branchTargets = foldMap targets . corePrepFunctionBlocks
    where
        targets block = case corePrepBlockTerminator block of
            CorePrepBranch _ trueTarget falseTarget -> [(trueTarget, falseTarget)]
            _ -> []

jumpTargets :: CorePrepFunction -> [Int]
jumpTargets = foldMap targets . corePrepFunctionBlocks
    where
        targets block = case corePrepBlockTerminator block of
            CorePrepJump target -> [target]
            _ -> []

shortCircuitSeeds :: Maybe CorePrepFunction -> [CorePrepInstruction]
shortCircuitSeeds = filter isSeed . allInstructions
    where
        isSeed (CorePrepBind bound valueType mutable (CorePrepCopy (CorePrepLiteral (CoreBoolean _) literalType))) =
            isShortCircuitName bound && valueType == boolType && mutable && literalType == boolType
        isSeed _ = False

seedValues :: Maybe CorePrepFunction -> [Bool]
seedValues = foldMap seed . shortCircuitSeeds
    where
        seed (CorePrepBind _ _ _ (CorePrepCopy (CorePrepLiteral (CoreBoolean value) _))) = [value]
        seed _ = []

shortCircuitNames :: Maybe CorePrepFunction -> [ResolvedName]
shortCircuitNames = foldMap bound . shortCircuitSeeds
    where
        bound (CorePrepBind result _ _ _) = [result]
        bound _ = []

shortCircuitAssignments :: Maybe CorePrepFunction -> [ResolvedName]
shortCircuitAssignments = foldMap assigned . allInstructions
    where
        assigned (CorePrepAssign result _) | isShortCircuitName result = [result]
        assigned _ = []

assignmentValues :: Maybe CorePrepFunction -> [CorePrepAtom]
assignmentValues = foldMap assigned . allInstructions
    where
        assigned (CorePrepAssign result value) | isShortCircuitName result = [value]
        assigned _ = []

generatedBindingSymbols :: Maybe CorePrepFunction -> [SymbolId]
generatedBindingSymbols = foldMap symbol . allInstructions
    where
        symbol (CorePrepBind bound _ _ _) | "$" `isPrefixOf` identifierText (resolvedSpelling bound) = [resolvedSymbol bound]
        symbol _ = []

isShortCircuitName :: ResolvedName -> Bool
isShortCircuitName = ("$shortcircuit" `isPrefixOf`) . identifierText . resolvedSpelling

containsEagerLogical :: CorePrepInstruction -> Bool
containsEagerLogical instruction = case instruction of
    CorePrepBind _ _ _ (CorePrepPrimitive primitive _) -> primitive `elem` [CoreLogicalAnd, CoreLogicalOr]
    CorePrepEvaluate (CorePrepPrimitive primitive _) -> primitive `elem` [CoreLogicalAnd, CoreLogicalOr]
    _ -> False

isNotEqual :: CorePrepInstruction -> Bool
isNotEqual (CorePrepBind _ _ _ (CorePrepPrimitive CoreNotEqual _)) = True
isNotEqual _ = False

hasComparisonToZero :: Type -> Maybe CorePrepFunction -> Bool
hasComparisonToZero valueType = any comparison . allInstructions
    where
        comparison (CorePrepBind _ resultType _ (CorePrepPrimitive CoreNotEqual operands)) =
            resultType == boolType
                && any ((== valueType) . atomType) operands
                && any isZero operands
        comparison _ = False
        -- The zero has the literal form of the operand type, as the native
        -- adapter spells it: a floating operand is compared with a floating
        -- zero, never with an integer payload under a floating type.
        isZero (CorePrepLiteral literal literalType) =
            literalType == valueType
                && literal == (if valueType == floatType then CoreFloating "0" else CoreInteger 0)
        isZero _ = False

atomType :: CorePrepAtom -> Type
atomType atom = case atom of
    CorePrepVariable _ valueType -> valueType
    CorePrepLiteral _ valueType -> valueType

allTargetsExist :: CorePrepFunction -> Bool
allTargetsExist function = all (`elem` ids) targets
    where
        blocks = corePrepFunctionBlocks function
        ids = map corePrepBlockId blocks
        targets = foldMap blockTargets blocks
        blockTargets block = case corePrepBlockTerminator block of
            CorePrepBranch _ trueTarget falseTarget -> [trueTarget, falseTarget]
            CorePrepJump target -> [target]
            _ -> []

exactlyOneCall :: CorePrepFunction -> Bool
exactlyOneCall function = count True (map isCall (concatMap corePrepBlockInstructions (corePrepFunctionBlocks function))) == 1
    where
        isCall (CorePrepBind _ _ _ (CorePrepCall _ _)) = True
        isCall (CorePrepEvaluate (CorePrepCall _ _)) = True
        isCall _ = False

callBlockIsJoin :: CorePrepFunction -> Bool
callBlockIsJoin function = case jumpTargets function of
    target : _ ->
        any
            (\block -> corePrepBlockId block == target && any isCall (corePrepBlockInstructions block))
            (corePrepFunctionBlocks function)
    [] -> False
    where
        isCall (CorePrepBind _ _ _ (CorePrepCall _ _)) = True
        isCall (CorePrepEvaluate (CorePrepCall _ _)) = True
        isCall _ = False

callIsSeparatedFromEntry :: CorePrimitive -> CoreExpression -> Bool
callIsSeparatedFromEntry primitive left = case preparedFunction (returning expression) of
    Just function ->
        let entry = corePrepFunctionEntry function
            callBlocks = [corePrepBlockId block | block <- corePrepFunctionBlocks function, any isCall (corePrepBlockInstructions block)]
         in length callBlocks == 1 && callBlocks /= [entry]
    Nothing -> False
    where
        expression = logical primitive left (CoreApply functionVariable [boolTrue] boolType)
        isCall (CorePrepBind _ _ _ (CorePrepCall _ _)) = True
        isCall _ = False

singletonModule :: CorePrepFunction -> CorePrepModule
singletonModule function = CorePrepModule (QualifiedName [Identifier "ShortCircuit"]) [function] []

verifierAccepts :: CorePrepModule -> Bool
verifierAccepts moduleValue = case verifyCorePrep moduleValue of
    Right _ -> True
    Left _ -> False

unique :: (Eq a) => [a] -> Bool
unique values = length values == length (nub values)

count :: (Eq a) => a -> [a] -> Int
count needle = length . filter (== needle)
