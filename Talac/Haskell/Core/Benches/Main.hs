-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Main (main) where

import Control.DeepSeq (NFData (rnf))
import Criterion.Main
import Data.Word (Word8)
import System.IO (hSetEncoding, stdout, utf8)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.CorePrep.Wire
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire

-- Production IR intentionally does not carry evaluation-strategy instances.
-- Fixture owners force the complete derived representation before Criterion
-- starts sampling without adding benchmark-only instances to compiler types.
newtype CoreModules = CoreModules [(Int, CoreModule)]

newtype CorePrepModules = CorePrepModules [(Int, CorePrepModule)]

instance NFData CoreModules where
    rnf (CoreModules values) = rnf (show values)

instance NFData CorePrepModules where
    rnf (CorePrepModules values) = rnf (show values)

main :: IO ()
main = do
    -- Criterion uses the microsecond symbol in its progress output. Windows can
    -- otherwise inherit a legacy console encoding and abort after a successful
    -- sample, so the harness owns its output encoding explicitly.
    hSetEncoding stdout utf8
    defaultMain
        [ bgroup
            "Core"
            [ env (pure (CoreModules (fixtures sizes))) $ \modules ->
                bgroup "Verify" [benchAt size verifyDigest (coreModuleAt size modules) | size <- sizes]
            , env (pure (CoreModules (fixtures sizes))) $ \modules ->
                bgroup "Encode" [benchAt size encodeDigest (coreModuleAt size modules) | size <- sizes]
            , env (traverse encodedFixture sizes) $ \documents ->
                bgroup "Decode" [benchAt size decodeDigest (documentAt size documents) | size <- sizes]
            , env (pure (CoreModules (inlineFixtures inlineSizes))) $ \modules ->
                bgroup "InlineLinearBody" [benchAt size optimizeDigest (coreModuleAt size modules) | size <- inlineSizes]
            , env (pure (CoreModules (floatingFixtures floatingSizes))) $ \modules ->
                bgroup "ConstantFoldFloating" [benchAt size floatingOptimizeDigest (coreModuleAt size modules) | size <- floatingSizes]
            , env (pure (CoreModules (integerFixtures integerSizes))) $ \modules ->
                bgroup "ConstantFoldInteger" [benchAt size integerOptimizeDigest (coreModuleAt size modules) | size <- integerSizes]
            , env (pure (CoreModules (guardedDivisionFixtures flowSizes))) $ \modules ->
                bgroup "GuardedIntegerEffects" [benchAt size integerOptimizeDigest (coreModuleAt size modules) | size <- flowSizes]
            , env (pure (CoreModules (contradictoryPathFixtures flowSizes))) $ \modules ->
                bgroup "ContradictoryIntegerPaths" [benchAt size integerOptimizeDigest (coreModuleAt size modules) | size <- flowSizes]
            , env (pure (CoreModules (loopFixtures flowSizes))) $ \modules ->
                bgroup "LoopIntegerFacts" [benchAt size integerOptimizeDigest (coreModuleAt size modules) | size <- flowSizes]
            , env (verifiedFixtures makeNestedLoopModule loopDepths) $ \modules ->
                bgroup "NestedLoopIntegerFacts" [benchAt size integerOptimizeDigest (coreModuleAt size modules) | size <- loopDepths]
            , env (verifiedFixtures makeChainModule chainSizes) $ \modules ->
                bgroup "EncodeChain" [benchAt size encodeDigest (coreModuleAt size modules) | size <- chainSizes]
            ]
        , bgroup
            "CorePrep"
            [ env (pure (CoreModules (preparedFixtures sizes))) $ \modules ->
                bgroup "Prepare" [benchAt size prepareDigest (coreModuleAt size modules) | size <- sizes]
            , env (pure (CoreModules (loopFixtures sizes))) $ \modules ->
                bgroup "PrepareLoops" [benchAt size prepareDigest (coreModuleAt size modules) | size <- sizes]
            , env (CorePrepModules <$> traverse preparedFixture sizes) $ \modules ->
                bgroup "Verify" [benchAt size verifyPrepDigest (corePrepModuleAt size modules) | size <- sizes]
            , env (CorePrepModules <$> traverse preparedFixture sizes) $ \modules ->
                bgroup "Encode" [benchAt size encodePrepDigest (corePrepModuleAt size modules) | size <- sizes]
            , env (traverse preparedDocument sizes) $ \documents ->
                bgroup "Decode" [benchAt size decodePrepDigest (documentAt size documents) | size <- sizes]
            , env (verifiedFixtures makeChainModule chainSizes) $ \modules ->
                bgroup "PrepareChain" [benchAt size prepareDigest (coreModuleAt size modules) | size <- chainSizes]
            , env (verifiedFixtures makeSequenceModule chainSizes) $ \modules ->
                bgroup "PrepareSequence" [benchAt size prepareDigest (coreModuleAt size modules) | size <- chainSizes]
            , env (CorePrepModules <$> traverse (preparedFrom makeChainModule) chainSizes) $ \modules ->
                bgroup "VerifyChain" [benchAt size verifyPrepDigest (corePrepModuleAt size modules) | size <- chainSizes]
            , env (CorePrepModules <$> traverse (preparedFrom makeSequenceModule) chainSizes) $ \modules ->
                bgroup "VerifySequence" [benchAt size verifyPrepDigest (corePrepModuleAt size modules) | size <- chainSizes]
            ]
        ]
    where
        sizes = [8, 32, 128, 512]
        inlineSizes = [8, 32, 128, 256]
        floatingSizes = [8, 32, 128, 512]
        integerSizes = [8, 32, 128, 512, 1024, 2048]
        flowSizes = [8, 32, 128, 512, 1024]
        -- Levels of loops nested in each other. The loop analysis once
        -- repeated the analysis of an inner loop for every pass over the
        -- loop around it, so each level multiplied the time.
        loopDepths = [2, 4, 8, 12, 16]
        -- Links of an `else if` chain and statements of a sequence of `if`
        -- statements. Each doubling should double the time.
        chainSizes = [256, 512, 1024, 2048]

benchAt :: Int -> (a -> Int) -> a -> Benchmark
benchAt size measure input = bench (show size) (whnf measure input)

-- The size key selects a stable value owned by one Criterion environment. This
-- keeps fixture construction out of the timed expression without relying on
-- global CAF evaluation order.
moduleAt :: Int -> [(Int, a)] -> a
moduleAt requested values = case lookup requested values of
    Just value -> value
    Nothing -> error "benchmark fixture size was not prepared"

coreModuleAt :: Int -> CoreModules -> CoreModule
coreModuleAt requested (CoreModules values) = moduleAt requested values

corePrepModuleAt :: Int -> CorePrepModules -> CorePrepModule
corePrepModuleAt requested (CorePrepModules values) = moduleAt requested values

documentAt :: Int -> [(Int, [a])] -> [a]
documentAt = moduleAt

fixtures :: [Int] -> [(Int, CoreModule)]
fixtures = map (\size -> (size, makeCoreModule size))

preparedFixtures :: [Int] -> [(Int, CoreModule)]
preparedFixtures = fixtures

{- | This fixture isolates Core-to-CorePrep cost for structured loops, including
nested conditionals and explicit transfers in the loop body.
-}
loopFixtures :: [Int] -> [(Int, CoreModule)]
loopFixtures = map (\size -> (size, makeLoopModule size))

makeLoopModule :: Int -> CoreModule
makeLoopModule count =
    CoreModule (QualifiedName [Identifier "LoopBenchmark"]) (map makeLoopFunction [0 .. count - 1])
    where
        makeLoopFunction index =
            let base = index * 4 + 1
                functionName = name base "LoopFunction"
                valueName = name (base + 1) "value"
                value = CoreVariable valueName intType
                lessThan bound = CorePrimitive CoreLessThan [value, integer bound] boolType
                increment = CorePrimitive CoreAdd [value, integer 1] intType
                skippedValue = CorePrimitive CoreEqual [value, integer 2] boolType
                stoppedValue = CorePrimitive CoreEqual [value, integer 7] boolType
                body =
                    [ CoreBind (CoreBinding valueName intType True (integer 0))
                    , CoreWhile
                        (lessThan 5)
                        [ CoreAssign valueName increment
                        , CoreIf skippedValue [CoreContinue] []
                        ]
                    , CoreDoWhile
                        [ CoreAssign valueName increment
                        , CoreIf stoppedValue [CoreBreak] []
                        ]
                        (lessThan 9)
                    , CoreFor
                        (lessThan 12)
                        [ CoreAssign valueName increment
                        , CoreIf skippedValue [CoreContinue] []
                        ]
                        [CoreAssign valueName increment]
                    , CoreReturn value
                    ]
             in CoreFunction functionName [] intType body

{- | Fixtures that must verify: a benchmark of a rejected module would time
the rejection.
-}
verifiedFixtures :: (Int -> CoreModule) -> [Int] -> IO CoreModules
verifiedFixtures make requested = CoreModules <$> traverse verified requested
    where
        verified size = case verifyCore (make size) of
            Left diagnostics -> fail (show diagnostics)
            Right value -> pure (size, value)

preparedFrom :: (Int -> CoreModule) -> Int -> IO (Int, CorePrepModule)
preparedFrom make size = case prepareCore (make size) of
    Left diagnostics -> fail (show diagnostics)
    Right value -> case verifyCorePrep value of
        Left diagnostics -> fail (show diagnostics)
        Right verified -> pure (size, verified)

{- | Loops nested to the given depth, each counting to a parameter, around
one statement: the workload of the loop fixed point of the integer analysis.
-}
makeNestedLoopModule :: Int -> CoreModule
makeNestedLoopModule depth =
    CoreModule
        (QualifiedName [Identifier "NestedLoopBenchmark"])
        [ CoreFunction
            (name 1 "Count")
            [(limitName, intType)]
            intType
            (CoreBind (CoreBinding totalName intType True (integer 0)) : loopAt 0 ++ [CoreReturn total])
        ]
    where
        limitName = name 2 "limit"
        totalName = name 3 "total"
        total = CoreVariable totalName intType
        counterName level = name (4 + level) "counter"
        counter level = CoreVariable (counterName level) intType
        increment value = CorePrimitive CoreAdd [value, integer 1] intType
        loopAt level
            | level == depth = [CoreAssign totalName (increment total)]
            | otherwise =
                [ CoreBind (CoreBinding (counterName level) intType True (integer 0))
                , CoreWhile
                    (CorePrimitive CoreLessThan [counter level, CoreVariable limitName intType] boolType)
                    (CoreAssign (counterName level) (increment (counter level)) : loopAt (level + 1))
                ]

{- | An `else if` chain: every false branch holds the next link, so the
statements nest as deep as the chain is long.
-}
makeChainModule :: Int -> CoreModule
makeChainModule links =
    CoreModule
        (QualifiedName [Identifier "ChainBenchmark"])
        [CoreFunction (name 1 "Pick") [(valueName, intType)] intType (chainFrom 0)]
    where
        valueName = name 2 "value"
        chainFrom index
            | index == links = [CoreReturn (integer 0)]
            | otherwise =
                [ CoreIf
                    (CorePrimitive CoreEqual [CoreVariable valueName intType, integer (toInteger index)] boolType)
                    [CoreReturn (integer (toInteger index * 3 + 1))]
                    (chainFrom (index + 1))
                ]

-- | The same tests as a sequence of `if` statements, which do not nest.
makeSequenceModule :: Int -> CoreModule
makeSequenceModule count =
    CoreModule
        (QualifiedName [Identifier "SequenceBenchmark"])
        [ CoreFunction
            (name 1 "Sum")
            [(valueName, intType)]
            intType
            (CoreBind (CoreBinding totalName intType True (integer 0)) : map test [0 .. count - 1] ++ [CoreReturn total])
        ]
    where
        valueName = name 2 "value"
        totalName = name 3 "total"
        total = CoreVariable totalName intType
        test index =
            CoreIf
                (CorePrimitive CoreEqual [CoreVariable valueName intType, integer (toInteger index)] boolType)
                [CoreAssign totalName (CorePrimitive CoreAdd [total, integer (toInteger index)] intType)]
                []

inlineFixtures :: [Int] -> [(Int, CoreModule)]
inlineFixtures = map (\size -> (size, makeInlineModule size))

-- The timed optimizer receives a verified nested expression containing only
-- binary64 literals. Fixture construction is kept in Criterion's environment;
-- the varying size measures rational parsing, target rounding, shortest
-- round-trip rendering, and fixed-point stability as one real Core workload.
floatingFixtures :: [Int] -> [(Int, CoreModule)]
floatingFixtures = map (\size -> (size, makeFloatingModule size))

-- This workload keeps construction outside Criterion's sample and drives the
-- real fixed-point optimizer through integer power, shifts, bitwise operations,
-- and addition at a 128-bit destination width.
integerFixtures :: [Int] -> [(Int, CoreModule)]
integerFixtures = map (\size -> (size, makeIntegerModule size))

-- These fixtures target the forward abstract interpreter rather than constant
-- folding: every divide uses a variable, and safety is available only on a
-- condition edge. Keeping construction in Criterion's environment makes the
-- timed region reflect the production optimizer's proof and effect passes.
guardedDivisionFixtures :: [Int] -> [(Int, CoreModule)]
guardedDivisionFixtures = map (\size -> (size, makeGuardedDivisionModule size))

contradictoryPathFixtures :: [Int] -> [(Int, CoreModule)]
contradictoryPathFixtures = map (\size -> (size, makeContradictoryPathModule size))

makeGuardedDivisionModule :: Int -> CoreModule
makeGuardedDivisionModule size =
    CoreModule
        (QualifiedName [Identifier "Core", Identifier "GuardedIntegerFlowBenchmarks"])
        [ CoreFunction
            functionName
            [(divisorName, integerType)]
            integerType
            [ CoreIf
                (CorePrimitive CoreNotEqual [divisor, typedInteger 0] boolType)
                (replicate size (CoreEvaluate division))
                [CoreReturn (typedInteger 0)]
            , CoreReturn (typedInteger 1)
            ]
        ]
    where
        functionName = resolvedName 1 "Evaluate"
        divisorName = resolvedName 2 "divisor"
        divisor = CoreVariable divisorName integerType
        integerType = namedType "int"
        typedInteger value = CoreLiteral (CoreInteger value) integerType
        division = CorePrimitive CoreDivide [typedInteger 42, divisor] integerType

makeContradictoryPathModule :: Int -> CoreModule
makeContradictoryPathModule size =
    CoreModule
        (QualifiedName [Identifier "Core", Identifier "ContradictoryIntegerFlowBenchmarks"])
        [ CoreFunction
            functionName
            [(valueName, integerType)]
            integerType
            [ CoreIf condition (replicate size (CoreEvaluate impossibleDivision)) [CoreReturn (typedInteger 0)]
            , CoreReturn (typedInteger 1)
            ]
        ]
    where
        functionName = resolvedName 1 "Evaluate"
        valueName = resolvedName 2 "value"
        integerType = namedType "int"
        value = CoreVariable valueName integerType
        typedInteger number = CoreLiteral (CoreInteger number) integerType
        condition =
            CorePrimitive
                CoreLogicalAnd
                [ CorePrimitive CoreGreaterThan [value, typedInteger 11] boolType
                , CorePrimitive CoreLessThan [value, typedInteger 12] boolType
                ]
                boolType
        impossibleDivision = CorePrimitive CoreDivide [typedInteger 42, value] integerType

resolvedName :: Int -> String -> ResolvedName
resolvedName symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

makeIntegerModule :: Int -> CoreModule
makeIntegerModule size =
    CoreModule
        (QualifiedName [Identifier "Core", Identifier "IntegerBenchmarks"])
        [ CoreFunction
            (ResolvedName (SymbolId 1) (Identifier "Evaluate"))
            []
            integerType
            [CoreReturn expression]
        ]
    where
        integerType = namedType "ulongint"
        expression = foldl appendIntegerOperations (typedInteger 0) [0 .. size - 1]
        appendIntegerOperations accumulated index =
            let base = toInteger (2 + index `mod` 3)
                power = CorePrimitive CorePower [typedInteger base, typedInteger 7] integerType
                shifted = CorePrimitive CoreShiftLeft [power, typedInteger (toInteger (index `mod` 8))] integerType
                mixed = CorePrimitive CoreBitwiseXor [accumulated, shifted] integerType
             in CorePrimitive CoreAdd [mixed, typedInteger 1] integerType
        typedInteger value = CoreLiteral (CoreInteger value) integerType

makeFloatingModule :: Int -> CoreModule
makeFloatingModule size =
    CoreModule
        (QualifiedName [Identifier "Core", Identifier "FloatingBenchmarks"])
        [ CoreFunction
            (ResolvedName (SymbolId 1) (Identifier "Evaluate"))
            []
            (namedType "float")
            [CoreReturn (foldl addLiteral (CoreLiteral (CoreFloating "0.1") (namedType "float")) [1 .. size])]
        ]
    where
        addLiteral accumulated _ =
            CorePrimitive
                CoreAdd
                [accumulated, CoreLiteral (CoreFloating "0.1") (namedType "float")]
                (namedType "float")

encodedFixture :: Int -> IO (Int, [Word8])
encodedFixture size = case verifyCore (makeCoreModule size) of
    Left diagnostics -> fail (show diagnostics)
    Right verified -> case encodeCore defaultCoreWireLimits verified of
        Left failure -> fail (show failure)
        Right bytes -> pure (size, bytes)

preparedFixture :: Int -> IO (Int, CorePrepModule)
preparedFixture size = case prepareCore (makeCoreModule size) of
    Left diagnostics -> fail (show diagnostics)
    Right value -> case verifyCorePrep value of
        Left diagnostics -> fail (show diagnostics)
        Right verified -> pure (size, verified)

preparedDocument :: Int -> IO (Int, [Word8])
preparedDocument size = do
    (_, prepared) <- preparedFixture size
    case encodeCorePrep prepared of
        Left failure -> fail (show failure)
        Right bytes -> pure (size, bytes)

verifyDigest :: CoreModule -> Int
verifyDigest value = either length coreDigest (verifyCore value)

encodeDigest :: CoreModule -> Int
encodeDigest value = either (length . show) length (encodeCore defaultCoreWireLimits value)

decodeDigest :: [Word8] -> Int
decodeDigest bytes = either (length . show) coreDigest (decodeCore defaultCoreWireLimits bytes)

-- Measure the production verifier/effect/inliner fixed point. Fixture creation
-- remains in Criterion's environment and is not charged to the sample.
optimizeDigest :: CoreModule -> Int
optimizeDigest value = case optimizeCoreWith inlineBenchmarkOptions value of
    Left diagnostics -> length diagnostics
    Right result ->
        coreDigest (optimizedCore result)
            + optimizationIterations result
            + sum (map inlineRewrittenCalls (optimizationInlineReports result))

floatingOptimizeDigest :: CoreModule -> Int
floatingOptimizeDigest value = either length (coreDigest . optimizedCore) (optimizeCoreWith defaultOptimizerOptions value)

integerOptimizeDigest :: CoreModule -> Int
integerOptimizeDigest value = either length (coreDigest . optimizedCore) (optimizeCoreWith defaultOptimizerOptions value)

inlineBenchmarkOptions :: OptimizerOptions
inlineBenchmarkOptions =
    defaultOptimizerOptions
        { optimizerConstantPropagation = False
        , optimizerControlFlowSimplification = False
        , optimizerDeadCodeElimination = False
        }

prepareDigest :: CoreModule -> Int
prepareDigest value = either length corePrepDigest (prepareCore value)

verifyPrepDigest :: CorePrepModule -> Int
verifyPrepDigest value = either length corePrepDigest (verifyCorePrep value)

encodePrepDigest :: CorePrepModule -> Int
encodePrepDigest value = either (length . show) length (encodeCorePrep value)

decodePrepDigest :: [Word8] -> Int
decodePrepDigest bytes = either (length . show) corePrepDigest (decodeCorePrep bytes)

-- A structural digest forces every recursive container without allocating the
-- large intermediate String produced by show. The traversal is intentionally
-- simple and shared by operations whose result is an IR value.
coreDigest :: CoreModule -> Int
coreDigest value = sum (map functionDigest (coreModuleFunctions value))

functionDigest :: CoreFunction -> Int
functionDigest value =
    1
        + length (coreFunctionParameters value)
        + sum (map statementDigest (coreFunctionBody value))

statementDigest :: CoreStatement -> Int
statementDigest statement = case statement of
    CoreBind binding -> 1 + expressionDigest (coreBindingValue binding)
    CoreAssign _ expression -> 1 + expressionDigest expression
    CoreReturn expression -> 1 + expressionDigest expression
    CoreIf condition whenTrue whenFalse ->
        1 + expressionDigest condition + sum (map statementDigest whenTrue) + sum (map statementDigest whenFalse)
    CoreEvaluate expression -> 1 + expressionDigest expression
    CoreWhile condition body -> 1 + expressionDigest condition + sum (map statementDigest body)
    CoreDoWhile body condition -> 1 + sum (map statementDigest body) + expressionDigest condition
    CoreFor condition body update ->
        1
            + expressionDigest condition
            + sum (map statementDigest body)
            + sum (map statementDigest update)
    CoreBreak -> 1
    CoreContinue -> 1

expressionDigest :: CoreExpression -> Int
expressionDigest expression = case expression of
    CoreVariable _ _ -> 1
    CoreLiteral _ _ -> 1
    CoreApply callee arguments _ -> 1 + expressionDigest callee + sum (map expressionDigest arguments)
    CorePrimitive _ arguments _ -> 1 + sum (map expressionDigest arguments)
    CoreLet _ _ value body _ -> 1 + expressionDigest value + expressionDigest body
    CoreConditional condition whenTrue whenFalse _ ->
        1 + sum (map expressionDigest [condition, whenTrue, whenFalse])
    CoreClosure captures parameters _ body _ ->
        1
            + length parameters
            + sum (map captureDigest captures)
            + sum (map statementDigest body)

captureDigest :: CoreCapture -> Int
captureDigest capture = 1 + expressionDigest (coreCaptureValue capture)

corePrepDigest :: CorePrepModule -> Int
corePrepDigest value = sum (map prepFunctionDigest (corePrepModuleFunctions value))

prepFunctionDigest :: CorePrepFunction -> Int
prepFunctionDigest value =
    1
        + length (corePrepFunctionParameters value)
        + sum (map blockDigest (corePrepFunctionBlocks value))

blockDigest :: CorePrepBlock -> Int
blockDigest value =
    1
        + sum (map instructionDigest (corePrepBlockInstructions value))
        + terminatorDigest (corePrepBlockTerminator value)

instructionDigest :: CorePrepInstruction -> Int
instructionDigest instruction = case instruction of
    CorePrepBind _ _ _ operation -> 1 + operationDigest operation
    CorePrepAssign _ atom -> 1 + atomDigest atom
    CorePrepEvaluate operation -> 1 + operationDigest operation

operationDigest :: CorePrepOperation -> Int
operationDigest operation = case operation of
    CorePrepCopy atom -> 1 + atomDigest atom
    CorePrepCall callee arguments -> 1 + atomDigest callee + sum (map atomDigest arguments)
    CorePrepPrimitive _ arguments -> 1 + sum (map atomDigest arguments)
    CorePrepMakeClosure _ captures -> 1 + sum (map prepCaptureDigest captures)

prepCaptureDigest :: CorePrepCapture -> Int
prepCaptureDigest (CorePrepCapture _ _ _ atom) = 1 + atomDigest atom

atomDigest :: CorePrepAtom -> Int
atomDigest atom = case atom of
    CorePrepVariable _ _ -> 1
    CorePrepLiteral _ _ -> 1

terminatorDigest :: CorePrepTerminator -> Int
terminatorDigest terminator = case terminator of
    CorePrepReturn atom -> 1 + atomDigest atom
    CorePrepBranch atom _ _ -> 1 + atomDigest atom
    CorePrepJump _ -> 1
    CorePrepUnreachable -> 1

makeCoreModule :: Int -> CoreModule
makeCoreModule count = CoreModule (QualifiedName [Identifier "Benchmark"]) (map makeFunction [0 .. count - 1])

-- Each call expands a two-binding linear helper. Function and local symbols are
-- globally disjoint so the benchmark measures fresh allocation and cloning,
-- not malformed-input rejection.
makeInlineModule :: Int -> CoreModule
makeInlineModule count =
    CoreModule
        (QualifiedName [Identifier "InlineBenchmark"])
        (inlineHelper : map makeCaller [0 .. count - 1])
    where
        helperName = name 1 "ScaleAndBias"
        parameterName = name 2 "input"
        firstName = name 3 "scaled"
        secondName = name 4 "biased"
        inlineHelper =
            CoreFunction
                helperName
                [(parameterName, intType)]
                intType
                [ CoreBind
                    ( CoreBinding
                        firstName
                        intType
                        False
                        (CorePrimitive CoreMultiply [CoreVariable parameterName intType, integer 2] intType)
                    )
                , CoreBind
                    ( CoreBinding
                        secondName
                        intType
                        False
                        (CorePrimitive CoreAdd [CoreVariable firstName intType, integer 1] intType)
                    )
                , CoreReturn (CoreVariable secondName intType)
                ]
        makeCaller index =
            let base = index * 3 + 100
                argumentName = name (base + 1) "argument"
                callerName = name (base + 2) "Caller"
                argument = CorePrimitive CoreAdd [integer (toInteger index), integer 7] intType
                applied =
                    CoreApply
                        (CoreVariable helperName (FunctionType [intType] intType))
                        [argument]
                        intType
             in CoreFunction
                    callerName
                    []
                    intType
                    [ CoreBind (CoreBinding argumentName intType False applied)
                    , CoreReturn (CoreVariable argumentName intType)
                    ]

makeFunction :: Int -> CoreFunction
makeFunction index =
    CoreFunction
        (name base "Function")
        []
        intType
        [ CoreBind (CoreBinding valueName intType True sumValue)
        , CoreIf comparison [CoreAssign valueName (integer 2)] [CoreAssign valueName (integer 0)]
        , CoreReturn (CoreVariable valueName intType)
        ]
    where
        base = index * 4 + 1
        valueName = name (base + 1) "value"
        sumValue = CorePrimitive CoreAdd [integer (toInteger index), integer 1] intType
        comparison = CorePrimitive CoreGreaterEqual [CoreVariable valueName intType, integer 1] boolType

name :: Int -> String -> ResolvedName
name identifier spelling = ResolvedName (SymbolId identifier) (Identifier spelling)

integer :: Integer -> CoreExpression
integer value = CoreLiteral (CoreInteger value) intType
