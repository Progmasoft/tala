-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Differential tests for the lowering of @match@.

A match over scalars means the same as a chain of @if@ statements that tests
the arms in order: the first arm whose literals equal the subjects and whose
guard holds supplies the result, and a guard is evaluated only when the
literals of its arm are equal. The @if@ chain is lowered by code that existed
before @match@ did and has its own tests, so it serves as the oracle here.

The tests generate families of arm lists from a fixed seed, write each family
once as a match and once as the chain, and require the two programs to return
the same value for every argument in a small domain, on the unoptimized and
on the optimized Core. Every guard also adds a distinct weight to a counter
that is part of the result, so a guard that runs when it should not, or does
not run when it should, changes the value even when the selected arm is the
same.
-}
module BranchingOracleTests (branchingOracleTests) where

import CoreInterpreter
import Data.List (intercalate)
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core

branchingOracleTests :: [(String, Bool)]
branchingOracleTests =
    generatorTests
        ++ concatMap familyTests (zip [0 :: Int ..] singleSubjectFamilies)
        ++ concatMap pairFamilyTests (zip [0 :: Int ..] pairSubjectFamilies)
        ++ concatMap wideTests [15, 16, 17, 33, 100]

-- ------------------------------------------------------------- generator

{- | A deterministic stream of small numbers.

The constants are those of the linear congruential generator in the C
standard's example, reduced to the bits whose period is long enough for the
few hundred draws made here. The stream is fixed, so a failing family has the
same index on every run.
-}
draws :: Int -> [Int]
draws seed = map (\value -> (value `div` 65536) `mod` 32768) (drop 1 (iterate step seed))
    where
        step value = (value * 1103515245 + 12345) `mod` 2147483648

-- | What a pattern requires of its subject.
data Test
    = -- | Accepts every value.
      Anything
    | -- | Accepts the value equal to the literal.
      Exactly Integer
    | -- | Accepts every value and binds it; the guard compares the binding.
      Bound
    deriving stock (Eq, Show)

{- | One generated arm for one subject: its test, an optional guard, and the
value of its body. A guard adds its weight to the counter and then holds when
the counter exceeds the threshold, or, for a bound value, when that value
exceeds it.
-}
data Arm = Arm
    { armTest :: Test
    , armGuard :: Maybe (Integer, Integer)
    , armValue :: Integer
    }
    deriving stock (Eq, Show)

{- | Arms for the literals @0@ up to the given count, then a catch-all.

A guarded literal arm may be followed by an unguarded arm for the same
literal, which is the case where a false guard must pass the value on. No
unguarded arm repeats a literal, and nothing follows the catch-all, so the
type checker accepts every generated list.
-}
generateArms :: Int -> [Int] -> [Arm]
generateArms count stream = go 0 stream
    where
        go index values
            | index >= count = [Arm Anything Nothing 99]
            | otherwise = case values of
                kind : weight : threshold : value : remaining ->
                    let literal = toInteger index
                        result = toInteger (10 + value `mod` 80)
                        guard = (toInteger (1 + weight `mod` 9) * (10 ^ (index `mod` 3)), toInteger (threshold `mod` 4))
                     in case kind `mod` 5 of
                            0 -> Arm (Exactly literal) Nothing result : go (index + 1) remaining
                            1 -> Arm (Exactly literal) (Just guard) result : go (index + 1) remaining
                            2 ->
                                Arm (Exactly literal) (Just guard) result
                                    : Arm (Exactly literal) Nothing (result + 100)
                                    : go (index + 1) remaining
                            3 -> Arm Bound (Just (0, toInteger (threshold `mod` 6))) result : go (index + 1) remaining
                            _ -> Arm Anything (Just guard) result : go (index + 1) remaining
                _ -> [Arm Anything Nothing 99]

singleSubjectFamilies :: [[Arm]]
singleSubjectFamilies =
    [ generateArms (2 + family `mod` 4) (drop (family * 37) (draws 20261004))
    | family <- [0 .. 23 :: Int]
    ]

-- | One generated arm for two subjects.
data PairArm = PairArm
    { pairTests :: (Test, Test)
    , pairGuard :: Maybe (Integer, Integer)
    , pairValue :: Integer
    }
    deriving stock (Eq, Show)

{- | Arms over two subjects: every pair of literals below the count in a
generated order, some replaced by a wildcard in one position, then the
catch-all. Each pair of tests appears at most once, and an arm that an
earlier one would shadow is dropped, so every list is accepted.
-}
generatePairArms :: Int -> [Int] -> [PairArm]
generatePairArms count stream = distinct [] (go candidates stream) ++ [PairArm (Anything, Anything) Nothing 99]
    where
        candidates = [(toInteger left, toInteger right) | left <- [0 .. count - 1], right <- [0 .. count - 1]]
        go [] _ = []
        go ((left, right) : remaining) values = case values of
            shape : weight : threshold : value : later ->
                let result = toInteger (10 + value `mod` 80)
                    guard = (toInteger (1 + weight `mod` 9), toInteger (threshold `mod` 3))
                    tests = case shape `mod` 6 of
                        0 -> (Anything, Exactly right)
                        1 -> (Exactly left, Anything)
                        _ -> (Exactly left, Exactly right)
                    guarded = if shape `mod` 4 == 3 then Just guard else Nothing
                 in PairArm tests guarded result : go remaining later
            _ -> []
        distinct _ [] = []
        distinct seen (arm : remaining)
            | any (`covers` pairTests arm) seen = distinct seen remaining
            | otherwise =
                arm : distinct (if pairGuard arm == Nothing then pairTests arm : seen else seen) remaining
        covers (first, second) (otherFirst, otherSecond) = accepts first otherFirst && accepts second otherSecond
        accepts earlier later = earlier == Anything || earlier == later

pairSubjectFamilies :: [[PairArm]]
pairSubjectFamilies =
    [ generatePairArms (2 + family `mod` 2) (drop (family * 53) (draws 4102026))
    | family <- [0 .. 11 :: Int]
    ]

generatorTests :: [(String, Bool)]
generatorTests =
    [ ("the generated draws are deterministic", take 5 (draws 1) == take 5 (draws 1))
    , ("every single-subject family ends with the catch-all", all ((== Arm Anything Nothing 99) . last) singleSubjectFamilies)
    , ("the single-subject families use guards", any (any ((/= Nothing) . armGuard)) singleSubjectFamilies)
    , ("the single-subject families bind values", any (any ((== Bound) . armTest)) singleSubjectFamilies)
    ,
        ( "the single-subject families repeat a literal after a guard"
        , any hasRepeatedLiteral singleSubjectFamilies
        )
    , ("every pair family ends with the catch-all", all ((== (Anything, Anything)) . pairTests . last) pairSubjectFamilies)
    , ("the pair families use wildcards beside literals", any (any mixed) pairSubjectFamilies)
    ]
    where
        hasRepeatedLiteral arms = or (zipWith sameLiteral arms (drop 1 arms))
        sameLiteral first second = case (armTest first, armTest second) of
            (Exactly left, Exactly right) -> left == right
            _ -> False
        mixed arm = case pairTests arm of
            (Anything, Exactly _) -> True
            (Exactly _, Anything) -> True
            _ -> False

-- --------------------------------------------------------------- sources

program :: String -> String
program statements =
    unlines
        [ "class Program {"
        , "    public static int Evaluate(_ int left, _ int right) {"
        , "        " ++ statements
        , "    }"
        , "}"
        ]

-- | The condition a guard stands for, over the given bound value.
guardSource :: String -> (Integer, Integer) -> String
guardSource bound (weight, threshold)
    | weight == 0 = bound ++ " > " ++ show threshold
    | otherwise = "(hits += " ++ show weight ++ ") > " ++ show threshold

matchSource :: [Arm] -> String
matchSource arms =
    "int hits = 0; int result = match (left) { "
        ++ intercalate ", " (zipWith armSource [0 :: Int ..] arms)
        ++ " }; return result * 1000 + hits;"
    where
        armSource index arm =
            let name = "bound" ++ show index
                patternSource = case armTest arm of
                    Anything -> "_"
                    Exactly value -> show value
                    Bound -> "int " ++ name
             in patternSource
                    ++ maybe "" ((" if " ++) . guardSource name) (armGuard arm)
                    ++ " -> "
                    ++ show (armValue arm)

{- | The same arms as a chain of @if@ statements. A bound value is the
subject itself, and a guard follows the literal test behind @&&@, which
evaluates it only when the literal is equal.
-}
chainSource :: [Arm] -> String
chainSource arms = "int hits = 0; int result = 0; " ++ chain arms ++ " return result * 1000 + hits;"
    where
        chain [] = ""
        chain (arm : remaining) = case conditionOf arm of
            Nothing -> "{ result = " ++ show (armValue arm) ++ "; }"
            Just condition ->
                "if ("
                    ++ condition
                    ++ ") { result = "
                    ++ show (armValue arm)
                    ++ "; }"
                    ++ if null remaining then "" else " else " ++ chain remaining
        conditionOf arm =
            let literal = case armTest arm of
                    Exactly value -> Just ("left == " ++ show value)
                    _ -> Nothing
                guard = fmap (guardSource "left") (armGuard arm)
             in case (literal, guard) of
                    (Nothing, Nothing) -> Nothing
                    (Just test, Nothing) -> Just test
                    (Nothing, Just test) -> Just test
                    (Just test, Just condition) -> Just (test ++ " && " ++ condition)

pairMatchSource :: [PairArm] -> String
pairMatchSource arms =
    "int hits = 0; int result = match (left), (right) { "
        ++ intercalate ", " (map armSource arms)
        ++ " }; return result * 1000 + hits;"
    where
        armSource arm =
            let (first, second) = pairTests arm
             in "("
                    ++ testSource first
                    ++ "), ("
                    ++ testSource second
                    ++ ")"
                    ++ maybe "" ((" if " ++) . guardSource "left") (pairGuard arm)
                    ++ " -> "
                    ++ show (pairValue arm)
        testSource test = case test of
            Exactly value -> show value
            _ -> "_"

pairChainSource :: [PairArm] -> String
pairChainSource arms = "int hits = 0; int result = 0; " ++ chain arms ++ " return result * 1000 + hits;"
    where
        chain [] = ""
        chain (arm : remaining) = case conditions arm of
            [] -> "{ result = " ++ show (pairValue arm) ++ "; }"
            tests ->
                "if ("
                    ++ intercalate " && " tests
                    ++ ") { result = "
                    ++ show (pairValue arm)
                    ++ "; }"
                    ++ if null remaining then "" else " else " ++ chain remaining
        conditions arm =
            let (first, second) = pairTests arm
             in literalTest "left" first ++ literalTest "right" second ++ maybe [] ((: []) . guardSource "left") (pairGuard arm)
        literalTest name test = case test of
            Exactly value -> [name ++ " == " ++ show value]
            _ -> []

-- ---------------------------------------------------------------- oracle

compileSource :: String -> Either String FrontendArtifacts
compileSource text = either (Left . show) Right (compileToCorePrep (CompilerInput "branching-oracle.tala" text))

-- | The values a program returns over the argument domain, or nothing when it does not compile or run.
results :: (FrontendArtifacts -> CoreModule) -> String -> Maybe [Integer]
results select statements = case compileSource (program statements) of
    Left _ -> Nothing
    Right artifacts ->
        mapM
            ( \(left, right) -> case runFunction (select artifacts) "Evaluate" [IntegerValue left, IntegerValue right] of
                Just (IntegerValue value) -> Just value
                _ -> Nothing
            )
            domain

-- Subjects below, at, and above every generated literal, in both positions.
domain :: [(Integer, Integer)]
domain = [(left, right) | left <- [0 .. 7], right <- [0 .. 3]]

agree :: String -> String -> [(String, Bool)]
agree matchText chainText =
    let oracle = results artifactCore chainText
     in [ ("the if chain compiles and runs: " ++ chainText, oracle /= Nothing)
        , ("unoptimized match agrees with the if chain: " ++ matchText, results artifactCore matchText == oracle)
        , ("optimized match agrees with the if chain: " ++ matchText, results artifactOptimizedCore matchText == oracle)
        , ("optimized if chain agrees with itself: " ++ chainText, results artifactOptimizedCore chainText == oracle)
        ]

{- | Matches around and beyond the nesting bound of the lowering, where the
arms are split into groups. Every sixth literal has a guarded arm before its
unguarded one, and half of those guards are false, so a false guard also
passes its value on inside and across groups. The subject domain reaches the
last literal and the catch-all.
-}
wideArms :: Int -> [Arm]
wideArms count =
    concat
        [ [Arm (Exactly literal) (Just (1, if index `mod` 4 == 0 then 0 else 1)) (literal * 7 + 3) | index `mod` 6 == 0]
            ++ [Arm (Exactly literal) Nothing (literal * 5 + 1)]
        | index <- [0 .. count - 1]
        , let literal = toInteger index
        ]
        ++ [Arm Anything Nothing 99]

wideResults :: (FrontendArtifacts -> CoreModule) -> String -> Int -> Maybe [Integer]
wideResults select statements count = case compileSource (program statements) of
    Left _ -> Nothing
    Right artifacts ->
        mapM
            ( \left -> case runFunction (select artifacts) "Evaluate" [IntegerValue left, IntegerValue 0] of
                Just (IntegerValue value) -> Just value
                _ -> Nothing
            )
            [0 .. toInteger count + 1]

wideTests :: Int -> [(String, Bool)]
wideTests count =
    let arms = wideArms count
        oracle = wideResults artifactCore (chainSource arms) count
        label = "a match of " ++ show (length arms) ++ " arms"
     in [ (label ++ " has an if chain that compiles and runs", oracle /= Nothing)
        , (label ++ " agrees with the if chain unoptimized", wideResults artifactCore (matchSource arms) count == oracle)
        , (label ++ " agrees with the if chain optimized", wideResults artifactOptimizedCore (matchSource arms) count == oracle)
        ]

familyTests :: (Int, [Arm]) -> [(String, Bool)]
familyTests (index, arms) =
    [ ("family " ++ show index ++ ": " ++ label, outcome)
    | (label, outcome) <- agree (matchSource arms) (chainSource arms)
    ]

pairFamilyTests :: (Int, [PairArm]) -> [(String, Bool)]
pairFamilyTests (index, arms) =
    [ ("pair family " ++ show index ++ ": " ++ label, outcome)
    | (label, outcome) <- agree (pairMatchSource arms) (pairChainSource arms)
    ]
