-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module IterationTests (iterationTests) where

import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser (Token (..), TokenKind (..))

-- These are vertical tests: each accepted loop must survive the source parser,
-- name resolution, type checking, Core verification, Core wire, and CorePrep.
iterationTests :: [(String, Bool)]
iterationTests =
    [ ("loop-control words are reserved lexer tokens", loopControlWordsAreReserved)
    , ("a double dash after a value starts a line comment", doubleDashAfterValueIsComment)
    , ("while lowers to a verified CorePrep back-edge", whileLowersToControlFlow)
    , ("do/while executes its body before testing its condition", doWhileEntersBodyFirst)
    , ("classic for lowers its update as a separate CFG region", forUpdateHasItsOwnBlock)
    , ("continue in a for body targets the update region", forContinueRunsUpdate)
    , ("break in a while body targets that loop's exit", breakTargetsLoopExit)
    , ("nested break targets the innermost loop exit", nestedBreakTargetsInnerLoop)
    , ("prefix and postfix increments are accepted in statement position", bothIncrementFormsCompile)
    , ("for initializer bindings remain scoped to the loop", forInitializerDoesNotEscape)
    , ("increment rejects immutable bindings", immutableIncrementIsRejected)
    , ("increment rejects non-numeric bindings", nonNumericIncrementIsRejected)
    , ("loop conditions use the ordinary boolean-or-numeric rule", stringLoopConditionIsRejected)
    , ("break outside a loop is rejected", breakOutsideLoopIsRejected)
    , ("continue outside a loop is rejected", continueOutsideLoopIsRejected)
    , ("value-carrying break remains an explicit unsupported feature", valuedBreakIsRejected)
    , ("enumerable for remains guarded by its missing generator ABI", forEachIsRejected)
    , ("Core v10 round-trips all structured loop statement tags", loopCoreRoundTrips)
    , ("loop CorePrep survives its verifier", loopCorePrepVerifies)
    ]

source :: String -> String
source body =
    unlines
        [ "class Program {"
        , "    public static int Evaluate(int limit) {"
        , body
        , "    }"
        , "}"
        ]

whileSource :: String
whileSource =
    source $
        unlines
            [ "        int index = 0;"
            , "        int total = 0;"
            , "        while (index < limit) {"
            , "            total = total + index;"
            , "            index++;"
            , "        }"
            , "        return total;"
            ]

doWhileSource :: String
doWhileSource =
    source $
        unlines
            [ "        int value = limit;"
            , "        do {"
            , "            value -= 1;"
            , "        } while (value > 0);"
            , "        return value;"
            ]

forSource :: String
forSource =
    source $
        unlines
            [ "        int total = 0;"
            , "        for (int index = 0; index < limit; index++) {"
            , "            if (index == 2) {"
            , "                continue;"
            , "            }"
            , "            total = total + index;"
            , "        }"
            , "        return total;"
            ]

allLoopsSource :: String
allLoopsSource =
    unlines
        [ "class Program {"
        , "    public static int WhileLoop(int limit) {"
        , "        int index = 0;"
        , "        while (index < limit) { index++; }"
        , "        return index;"
        , "    }"
        , "    public static int DoLoop(int limit) {"
        , "        int index = limit;"
        , "        do { index -= 1; } while (index > 0);"
        , "        return index;"
        , "    }"
        , "    public static int ForLoop(int limit) {"
        , "        int total = 0;"
        , "        for (int index = 0; index < limit; index++) {"
        , "            if (index == 2) { continue; }"
        , "            total = total + index;"
        , "        }"
        , "        return total;"
        , "    }"
        , "}"
        ]

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "iteration.tala" text)

compiled :: String -> Maybe FrontendArtifacts
compiled text = either (const Nothing) Just (compileSource text)

singleCoreFunction :: FrontendArtifacts -> Maybe CoreFunction
singleCoreFunction artifacts = case coreModuleFunctions (artifactOptimizedCore artifacts) of
    [function] -> Just function
    _ -> Nothing

singlePreparedFunction :: FrontendArtifacts -> Maybe CorePrepFunction
singlePreparedFunction artifacts = case corePrepModuleFunctions (artifactCorePrep artifacts) of
    [function] -> Just function
    _ -> Nothing

loopControlWordsAreReserved :: Bool
loopControlWordsAreReserved = case runLexer defaultLexer (LexerInput "iteration.tala" "while do for break continue") of
    Right tokens ->
        [(tokenText token, tokenKind token) | token <- tokens, tokenKind token /= EndOfFileToken]
            == [(word, KeywordToken) | word <- ["while", "do", "for", "break", "continue"]]
    Left _ -> False

-- The language has no decrement operator: `--` starts a comment wherever it
-- stands outside a string, also directly after a value.
doubleDashAfterValueIsComment :: Bool
doubleDashAfterValueIsComment = case runLexer defaultLexer (LexerInput "iteration.tala" "value--; -- explanation\nnext") of
    Right tokens ->
        [(tokenText token, tokenKind token) | token <- tokens, tokenKind token /= EndOfFileToken]
            == [("value", IdentifierToken), ("next", IdentifierToken)]
    Left _ -> False

whileLowersToControlFlow :: Bool
whileLowersToControlFlow = case compiled whileSource of
    Just artifacts -> any hasLoopShape (corePrepModuleFunctions (artifactCorePrep artifacts))
    Nothing -> False
    where
        hasLoopShape function =
            let blocks = corePrepFunctionBlocks function
             in any isBranch blocks && any jumpsBackward blocks
        jumpsBackward block = case corePrepBlockTerminator block of
            CorePrepJump target -> target <= corePrepBlockId block
            _ -> False

doWhileEntersBodyFirst :: Bool
doWhileEntersBodyFirst = case compiled doWhileSource >>= singlePreparedFunction of
    Just function -> case corePrepFunctionBlocks function of
        entry : body : condition : _ ->
            corePrepBlockTerminator entry == CorePrepJump (corePrepBlockId body)
                && corePrepBlockTerminator body == CorePrepJump (corePrepBlockId condition)
                && case corePrepBlockTerminator condition of
                    CorePrepBranch _ bodyId _ -> bodyId == corePrepBlockId body
                    _ -> False
        _ -> False
    Nothing -> False

forUpdateHasItsOwnBlock :: Bool
forUpdateHasItsOwnBlock = case compiled forSource >>= singlePreparedFunction of
    Just function -> case corePrepFunctionBlocks function of
        entry : condition : _ -> case corePrepBlockTerminator condition of
            CorePrepBranch _ bodyId _ ->
                let updateId = bodyId + 1
                 in corePrepBlockTerminator entry == CorePrepJump (corePrepBlockId condition)
                        && maybe
                            False
                            ((== CorePrepJump (corePrepBlockId condition)) . corePrepBlockTerminator)
                            (findBlock updateId (corePrepFunctionBlocks function))
                        && maybe False (not . null . corePrepBlockInstructions) (findBlock updateId (corePrepFunctionBlocks function))
            _ -> False
        _ -> False
    Nothing -> False

forContinueRunsUpdate :: Bool
forContinueRunsUpdate = case compiled forSource >>= singlePreparedFunction of
    Just function -> case corePrepFunctionBlocks function of
        entry : condition : _ -> case corePrepBlockTerminator condition of
            CorePrepBranch _ bodyId _ ->
                let updateId = bodyId + 1
                    blocks = corePrepFunctionBlocks function
                    loopBodyBlocks = takeWhile ((/= updateId) . corePrepBlockId) (drop 2 blocks)
                 in corePrepBlockTerminator entry == CorePrepJump (corePrepBlockId condition)
                        && maybe False ((== CorePrepJump (corePrepBlockId condition)) . corePrepBlockTerminator) (findBlock updateId blocks)
                        && any (jumpsTo updateId) loopBodyBlocks
            _ -> False
        _ -> False
    Nothing -> False

breakTargetsLoopExit :: Bool
breakTargetsLoopExit =
    let text = source "int value = 0; while (value < limit) { break; } return value;"
     in case compiled text >>= singlePreparedFunction of
            Just function -> case corePrepFunctionBlocks function of
                _entry : condition : _ -> case corePrepBlockTerminator condition of
                    CorePrepBranch _ bodyId exitId ->
                        bodyId /= corePrepBlockId condition
                            && maybe False ((== CorePrepJump exitId) . corePrepBlockTerminator) (findBlock bodyId (corePrepFunctionBlocks function))
                    _ -> False
                _ -> False
            Nothing -> False

nestedBreakTargetsInnerLoop :: Bool
nestedBreakTargetsInnerLoop =
    let text =
            source $
                unlines
                    [ "int outer = 0;"
                    , "while (outer < limit) {"
                    , "    int inner = 0;"
                    , "    while (inner < limit) { break; }"
                    , "    outer++;"
                    , "}"
                    , "return outer;"
                    ]
     in case compiled text >>= singlePreparedFunction of
            Just function -> case filter isBranch (corePrepFunctionBlocks function) of
                outerCondition : innerCondition : _ ->
                    case (corePrepBlockTerminator outerCondition, corePrepBlockTerminator innerCondition) of
                        (CorePrepBranch _ _ outerExit, CorePrepBranch _ innerBody innerExit) ->
                            let blocks = corePrepFunctionBlocks function
                             in innerBody /= corePrepBlockId outerCondition
                                    && maybe False ((== CorePrepJump innerExit) . corePrepBlockTerminator) (findBlock innerBody blocks)
                                    && innerExit /= outerExit
                        _ -> False
                _ -> False
            Nothing -> False

bothIncrementFormsCompile :: Bool
bothIncrementFormsCompile =
    let text = source "int value = 0; ++value; value++; return value;"
     in case compiled text >>= singleCoreFunction of
            Just function -> countIncrements (coreFunctionBody function) == 2
            Nothing -> False

forInitializerDoesNotEscape :: Bool
forInitializerDoesNotEscape =
    let text = source "for (int index = 0; index < limit; index++) {} return index;"
     in case compileSource text of
            Left _ -> True
            Right _ -> False

immutableIncrementIsRejected :: Bool
immutableIncrementIsRejected = rejectedWith "TAT0022" (source "final int value = 0; value++; return value;")

nonNumericIncrementIsRejected :: Bool
nonNumericIncrementIsRejected = rejectedWith "TAT0024" (source "bool value = false; value++; return 0;")

stringLoopConditionIsRejected :: Bool
stringLoopConditionIsRejected = rejectedWith "TAT0020" (source "while (\"not a condition\") {} return 0;")

breakOutsideLoopIsRejected :: Bool
breakOutsideLoopIsRejected = rejectedWith "TAT0025" (source "break; return 0;")

continueOutsideLoopIsRejected :: Bool
continueOutsideLoopIsRejected = rejectedWith "TAT0027" (source "continue; return 0;")

valuedBreakIsRejected :: Bool
valuedBreakIsRejected = rejectedWith "TAT0026" (source "while (true) { break 3; } return 0;")

forEachIsRejected :: Bool
forEachIsRejected =
    let text =
            unlines
                [ "class Program {"
                , "    public static int Evaluate(System.Array<int> values) {"
                , "        for (int value : values) {}"
                , "        return 0;"
                , "    }"
                , "}"
                ]
     in rejectedWith "TAT0021" text

loopCoreRoundTrips :: Bool
loopCoreRoundTrips = case compiled allLoopsSource of
    Just artifacts ->
        let core = artifactOptimizedCore artifacts
         in case encodeCore defaultCoreWireLimits core >>= decodeCore defaultCoreWireLimits of
                Right decoded -> decoded == core
                Left _ -> False
    Nothing -> False

loopCorePrepVerifies :: Bool
loopCorePrepVerifies = case compiled allLoopsSource of
    Just artifacts -> verifyCorePrep (artifactCorePrep artifacts) == Right (artifactCorePrep artifacts)
    Nothing -> False

rejectedWith :: String -> String -> Bool
rejectedWith code text = case compileSource text of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

countIncrements :: [CoreStatement] -> Int
countIncrements = sum . map count
    where
        count statement = case statement of
            CoreAssign _ (CorePrimitive primitive _ _) | primitive `elem` [CoreAdd, CoreSubtract] -> 1
            CoreIf _ yes no -> countIncrements yes + countIncrements no
            CoreWhile _ body -> countIncrements body
            CoreDoWhile body _ -> countIncrements body
            CoreFor _ body update -> countIncrements body + countIncrements update
            _ -> 0

isBranch :: CorePrepBlock -> Bool
isBranch block = case corePrepBlockTerminator block of
    CorePrepBranch {} -> True
    _ -> False

jumpsTo :: Int -> CorePrepBlock -> Bool
jumpsTo target block = corePrepBlockTerminator block == CorePrepJump target

findBlock :: Int -> [CorePrepBlock] -> Maybe CorePrepBlock
findBlock identifier = find ((== identifier) . corePrepBlockId)
    where
        find _ [] = Nothing
        find predicate (value : rest)
            | predicate value = Just value
            | otherwise = find predicate rest
