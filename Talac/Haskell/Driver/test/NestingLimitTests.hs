-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Tests for the nesting limits of "Progmasoft.Tala.NestingLimits".

Every construct that holds statements or operands is nested to exactly the
limit, which must be accepted, and to one level more, which must be rejected
with the diagnostic of that limit at the first node that is too deep. The
accepted programs are also lowered and run, on the unoptimized and the
optimized Core, so the limit is known to be a depth the frontend handles and
not only one it does not reject. Chains that are not nesting, an @else if@
chain above all, are far longer than either limit and are accepted.
-}
module NestingLimitTests (nestingLimitTests) where

import CoreInterpreter
import Data.List (intercalate)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.NestingLimits

nestingLimitTests :: [(String, Bool)]
nestingLimitTests = limitTests ++ statementTests ++ expressionTests ++ combinedTests ++ chainTests

-- ---------------------------------------------------------------- sources

-- | A method whose body is the given text on line 3, starting at column 1.
method :: String -> String
method statements =
    unlines
        [ "class Program {"
        , "public static int Evaluate(_ int value) {"
        , statements
        , "}"
        , "}"
        ]

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "nesting-limit.tala" text)

accepted :: String -> Bool
accepted text = either (const False) (const True) (compileSource text)

-- | The codes a source is rejected with, in order, or none when it is accepted.
codesOf :: String -> [String]
codesOf text = either (map diagnosticCode) (const []) (compileSource text)

-- | The one-based columns on line 3 at which the code is reported.
columnsOf :: String -> String -> [Int]
columnsOf code text = case compileSource text of
    Right _ -> []
    Left problems ->
        [ sourceColumn (sourceStart spanValue)
        | problem <- problems
        , diagnosticCode problem == code
        , Just spanValue <- [diagnosticSpan problem]
        , sourceLine (sourceStart spanValue) == 3
        ]

-- | The value the method returns for the argument, on both forms of Core.
valuesOf :: String -> Integer -> [Maybe Integer]
valuesOf text argument = case compileSource text of
    Left _ -> [Nothing]
    Right artifacts ->
        [ case runFunction (select artifacts) "Evaluate" [IntegerValue argument] of
            Just (IntegerValue result) -> Just result
            _ -> Nothing
        | select <- [artifactCore, artifactOptimizedCore]
        ]

-- ------------------------------------------------------------------ limits

limitTests :: [(String, Bool)]
limitTests =
    [ ("the statement limit is 256 levels", maximumStatementNesting == 256)
    , ("the expression limit is 1024 levels", maximumExpressionNesting == 1024)
    ]

-- -------------------------------------------------------------- statements

{- | A statement nest: the opening text repeated, the innermost statement,
and the closing text repeated. With @count@ openings the innermost statement
is at level @count + 1@.
-}
nest :: Int -> String -> String -> String
nest count open close = "int total = 0; " ++ concat (replicate count open) ++ "total += 1; " ++ concat (replicate count close)

-- | The column of the innermost statement of 'nest'.
innermostColumn :: Int -> String -> Int
innermostColumn count open = 1 + length "int total = 0; " + count * length open

-- | Constructs that put a statement one level below themselves.
nestingConstructs :: [(String, String, String)]
nestingConstructs =
    [ ("if", "if (value > 0) { ", "} ")
    , ("while", "while (total < 1) { ", "} ")
    , ("do/while", "do { ", "} while (total < 1); ")
    , ("for", "for (; total < 1; total += 1) { ", "} ")
    , ("guard", "guard (total > 0) else { ", "return 0; } ")
    , ("block", "{ ", "} ")
    , ("match arm", "match (value) { _ -> { ", "} } ")
    ]

statementTests :: [(String, Bool)]
statementTests =
    concat
        [ [ ( "a statement at level 256 inside nested " ++ name ++ " statements is accepted"
            , accepted (method (nest atLimit open close ++ "return total;"))
            )
          , ( "a statement at level 257 inside nested " ++ name ++ " statements is rejected at that statement"
            , columnsOf "TAP0039" (method (nest beyondLimit open close ++ "return total;"))
                == [innermostColumn beyondLimit open]
            )
          , ( "nothing else is reported for nested " ++ name ++ " statements"
            , codesOf (method (nest beyondLimit open close ++ "return total;")) == ["TAP0039"]
            )
          ]
        | (name, open, close) <- nestingConstructs
        ]
        ++ [ ("256 levels of if statements compute their value", valuesOf (method (nest atLimit ifOpen "} " ++ "return total;")) 5 == [Just 1, Just 1])
           , ("256 levels of if statements skip the innermost one", valuesOf (method (nest atLimit ifOpen "} " ++ "return total;")) 0 == [Just 0, Just 0])
           , ("256 levels of blocks compute their value", valuesOf (method (nest atLimit "{ " "} " ++ "return total;")) 0 == [Just 1, Just 1])
           , -- Each level of nested loops once multiplied the time of the
             -- loop analysis, so that 50 levels did not finish. These nests
             -- are compiled, optimized and run.
             ("255 nested while loops compute their value", valuesOf (method (nest atLimit "while (total < 1) { " "} " ++ "return total;")) 0 == [Just 1, Just 1])
           , ("255 nested for loops compute their value", valuesOf (method (nest atLimit "for (; total < 1; total += 1) { " "} " ++ "return total;")) 0 == [Just 256, Just 256])
           , ("40 nested counting loops compute their value", valuesOf (method (countingLoops 40)) 1 == [Just 1, Just 1])
           , ("3 nested counting loops compute their value", valuesOf (method (countingLoops 3)) 4 == [Just 64, Just 64])
           , ("a statement far beyond the limit is still reported once", codesOf (method (nest 2000 ifOpen "} " ++ "return total;")) == ["TAP0039"])
           , ("every function reports its own excess", codesOf twoDeepFunctions == ["TAP0039", "TAP0039"])
           , ("a deep function does not hide an accepted one", codesOf oneDeepFunction == ["TAP0039"])
           ]
    where
        -- The innermost statement of `count` constructs is at level count + 1.
        atLimit = maximumStatementNesting - 1
        beyondLimit = maximumStatementNesting
        ifOpen = "if (value > 0) { "
        -- Loops that each count to the argument with a counter of their
        -- own, around one statement: the innermost statement runs
        -- value ^ depth times.
        countingLoops :: Int -> String
        countingLoops depth =
            "int total = 0; "
                ++ concat ["for (int c" ++ show level ++ " = 0; c" ++ show level ++ " < value; c" ++ show level ++ " += 1) { " | level <- [1 .. depth]]
                ++ "total += 1; "
                ++ concat (replicate depth "} ")
                ++ "return total;"
        twoDeepFunctions =
            unlines
                [ "class Program {"
                , "public static int First(_ int value) { " ++ nest beyondLimit ifOpen "} " ++ "return total; }"
                , "public static int Second(_ int value) { " ++ nest beyondLimit ifOpen "} " ++ "return total; }"
                , "}"
                ]
        oneDeepFunction =
            unlines
                [ "class Program {"
                , "public static int First(_ int value) { return value; }"
                , "public static int Second(_ int value) { " ++ nest beyondLimit ifOpen "} " ++ "return total; }"
                , "}"
                ]

-- ------------------------------------------------------------- expressions

-- | @value + value + ...@ with the given number of operands.
sumOf :: Int -> String
sumOf operands = intercalate " + " (replicate operands "value")

-- | @value + (value + (... value))@ with the given number of additions.
rightNested :: Int -> String
rightNested additions = concat (replicate additions "value + (") ++ "value" ++ replicate additions ')'

-- | @(((value + 1) + 1) ...)@ with the given number of additions.
parenthesized :: Int -> String
parenthesized additions = replicate additions '(' ++ "value" ++ concat (replicate additions " + 1)")

-- | @value == 0 ? 0 : value == 1 ? 1 : ... : 7@ with the given number of tests.
conditionalChain :: Int -> String
conditionalChain tests = concat ["value == " ++ show index ++ " ? " ++ show index ++ " : " | index <- [0 .. tests - 1]] ++ "7"

-- | @Twice(Twice(...(value)))@ with the given number of calls.
calls :: Int -> String
calls count = concat (replicate count "Twice(") ++ "value" ++ replicate count ')'

withTwice :: String -> String
withTwice statements =
    unlines
        [ "class Program {"
        , "public static int Evaluate(_ int value) {"
        , statements
        , "}"
        , "public static int Twice(_ int value) { return value + value; }"
        , "}"
        ]

expressionTests :: [(String, Bool)]
expressionTests =
    [ -- A chain of a left-associative operator is not nesting: the left
      -- operand of a binary operator is at the level of the operator, and
      -- every stage walks the chain in a loop.
      ("a sum of 1024 operands is accepted", accepted (method ("return " ++ sumOf limit ++ ";")))
    , ("a sum of 1024 operands computes its value", valuesOf (method ("return " ++ sumOf limit ++ ";")) 3 == [Just 3072, Just 3072])
    , ("a sum of 1025 operands is not nesting", codesOf (method ("return " ++ sumOf (limit + 1) ++ ";")) == [])
    , ("a sum of 20000 operands computes its value", valuesOf (method ("return " ++ sumOf 20000 ++ ";")) 3 == [Just 60000, Just 60000])
    , -- Parentheses around a left operand do not change the tree.
        ( "5000 parentheses around left operands compute their value"
        , valuesOf (method ("return " ++ parenthesized 5000 ++ ";")) 1 == [Just 5001, Just 5001]
        )
    , ("a chain of comparisons joined by && is not nesting", accepted (method ("return (" ++ intercalate " && " (replicate 3000 "value > 0") ++ ") ? 1 : 0;")))
    , -- A right operand is one level below its operator: n additions that
      -- nest to the right put the last `value` at level n + 1.
      ("1023 additions nested to the right are accepted", accepted (method ("return " ++ rightNested (limit - 1) ++ ";")))
    ,
        ( "1023 additions nested to the right compute their value"
        , valuesOf (method ("return " ++ rightNested (limit - 1) ++ ";")) 2 == [Just 2048, Just 2048]
        )
    ,
        ( "1024 additions nested to the right are rejected at the innermost operand"
        , columnsOf "TAP0040" (method ("return " ++ rightNested limit ++ ";")) == [1 + length "return " + limit * length "value + ("]
        )
    , ("nothing else is reported for the deep right operand", codesOf (method ("return " ++ rightNested limit ++ ";")) == ["TAP0040"])
    , -- A long chain as a right operand costs one level, not its length.
        ( "a long sum as a right operand is one level"
        , accepted (method ("return " ++ rightNested 1000 ++ " + (" ++ sumOf 5000 ++ ");"))
        )
    , -- Each test of a conditional chain puts the rest of the chain one level deeper.
      -- The operands of the last test are two levels below its conditional.
      ("a conditional chain of 1022 tests is accepted", accepted (method ("return " ++ conditionalChain (limit - 2) ++ ";")))
    , ("a conditional chain of 1022 tests selects its last result", valuesOf (method ("return " ++ conditionalChain (limit - 2) ++ ";")) 5000 == [Just 7, Just 7])
    , ("a conditional chain of 1022 tests selects a late test", valuesOf (method ("return " ++ conditionalChain (limit - 2) ++ ";")) 1000 == [Just 1000, Just 1000])
    , ("a conditional chain of 1023 tests is rejected", codesOf (method ("return " ++ conditionalChain (limit - 1) ++ ";")) == ["TAP0040"])
    , -- n calls put `value` at level n + 1.
      ("1023 nested calls are accepted", accepted (withTwice ("return " ++ calls (limit - 1) ++ ";")))
    , ("1024 nested calls are rejected", codesOf (withTwice ("return " ++ calls limit ++ ";")) == ["TAP0040"])
    , ("an expression far beyond the limit is reported once", codesOf (method ("return " ++ rightNested 5000 ++ ";")) == ["TAP0040"])
    ,
        ( "many separate expressions at the limit are accepted"
        , accepted (method ("int a = " ++ sumOf limit ++ "; int b = " ++ sumOf limit ++ "; return a + b;"))
        )
    ]
    where
        limit = maximumExpressionNesting

-- ---------------------------------------------------------------- combined

combinedTests :: [(String, Bool)]
combinedTests =
    [ -- A value block is one statement level below the statement that holds
      -- its expression: 255 if expressions put the innermost block at 256.
        ( "value blocks nested to level 256 are accepted"
        , accepted (method ("return " ++ valueBlocks (maximumStatementNesting - 1) ++ ";"))
        )
    ,
        ( "value blocks nested to level 256 compute their value"
        , valuesOf (method ("return " ++ valueBlocks (maximumStatementNesting - 1) ++ ";")) 1 == [Just 1, Just 1]
        )
    ,
        ( "if expressions nested in last position need no parentheses"
        , valuesOf (method ("return " ++ concat (replicate 100 "if (value > 0) { ") ++ "value" ++ concat (replicate 100 " } else { 0 }") ++ ";")) 4
            == [Just 4, Just 4]
        )
    ,
        ( "value blocks nested to level 257 are rejected as statements"
        , codesOf (method ("return " ++ valueBlocks maximumStatementNesting ++ ";")) == ["TAP0039"]
        )
    , -- Expressions inside nested statements keep counting from the
      -- expression around them, so the two limits bound the total depth.
        ( "an expression split by value blocks is still limited"
        , codesOf (method ("return " ++ nestedThroughBlocks 4 300 ++ ";")) == ["TAP0040"]
        )
    ,
        ( "an expression split by value blocks below the limit is accepted"
        , accepted (method ("return " ++ nestedThroughBlocks 4 200 ++ ";"))
        )
    ,
        ( "a statement excess and an expression excess are both reported"
        , codesOf (method (nest maximumStatementNesting "if (value > 0) { " "} " ++ "return " ++ rightNested maximumExpressionNesting ++ ";"))
            == ["TAP0039", "TAP0040"]
        )
    ,
        ( "a closure body is one statement level below its expression"
        , codesOf (method ("auto f = " ++ concat (replicate maximumStatementNesting "\\() -> { return ") ++ "1" ++ concat (replicate maximumStatementNesting "; }") ++ "; return 0;"))
            == ["TAP0039"]
        )
    ]
    where
        -- `if (value > 0) { (<inner>) } else { 0 }`, nested the given number
        -- of times around `value`. The parentheses keep the inner `if` in
        -- operand position: at the start of a statement it would be the
        -- `if` statement.
        valueBlocks :: Int -> String
        valueBlocks count = concat (replicate count "if (value > 0) { (") ++ "value" ++ concat (replicate count ") } else { 0 }")
        -- Nested if expressions whose blocks each hold additions that
        -- nest to the right, the innermost operand of which is the next
        -- if expression: the deepest operand is below every addition and
        -- every block around it.
        nestedThroughBlocks :: Int -> Int -> String
        nestedThroughBlocks blocks additions =
            concat (replicate blocks ("if (value > 0) { " ++ concat (replicate additions "value + (")))
                ++ "value"
                ++ concat (replicate blocks (replicate additions ')' ++ " } else { 0 }"))

-- ------------------------------------------------------------------ chains

-- | An else-if chain: link @index@ returns @index * 3 + 1@.
chain :: Int -> String
chain links =
    concat
        [ (if index == 0 then "if" else " else if") ++ " (value == " ++ show index ++ ") { return " ++ show (index * 3 + 1) ++ "; }"
        | index <- [0 .. links - 1]
        ]
        ++ " return 0;"

chainTests :: [(String, Bool)]
chainTests =
    [ -- The links of an else-if chain are all at the level of the first if.
      ("an else-if chain of 1000 links is not nesting", accepted (method (chain 1000)))
    , ("an else-if chain of 1000 links selects its last link", valuesOf (method (chain 1000)) 999 == [Just 2998, Just 2998])
    , ("an else-if chain of 1000 links falls through", valuesOf (method (chain 1000)) 1000 == [Just 0, Just 0])
    , -- The body of every link is one level below the chain, whichever link it belongs to.
        ( "the bodies of a chain at level 255 are accepted in every link"
        , accepted (method (around (maximumStatementNesting - 2) threeLinks))
        )
    ,
        ( "the bodies of a chain at level 256 are rejected once"
        , codesOf (method (around (maximumStatementNesting - 1) threeLinks)) == ["TAP0039"]
        )
    , -- An else block that holds exactly one if is the same tree as `else if`.
      ("else blocks that hold only an if form a chain", accepted (method (nest 600 "if (value < 0) { } else { " "} " ++ "return total;")))
    , -- The body of an arm is one level below its match, however many arms it has.
        ( "the arms of a wide match are one level below it"
        , accepted (method (around (maximumStatementNesting - 2) wideArms))
            && codesOf (method (around (maximumStatementNesting - 1) wideArms)) == ["TAP0039"]
        )
    ,
        ( "the arms of a narrow match are one level below it"
        , accepted (method (around (maximumStatementNesting - 2) narrowArms))
            && codesOf (method (around (maximumStatementNesting - 1) narrowArms)) == ["TAP0039"]
        )
    , ("a statement match of 300 arms is not nesting", accepted (method ("match (value) { " ++ concat [show index ++ " -> { return " ++ show index ++ "; }, " | index <- [0 .. 298 :: Int]] ++ "_ -> { return 0; } } return 1;")))
    ]
    where
        -- Twenty arms with block bodies.
        wideArms = "match (value) { " ++ concat [show index ++ " -> { total = " ++ show index ++ "; }, " | index <- [0 .. 18 :: Int]] ++ "_ -> { total = 0; } } "
        -- Three arms with block bodies.
        narrowArms = "match (value) { 1 -> { total = 1; }, 2 -> { total = 2; }, _ -> { total = 0; } } "
        threeLinks = "if (value == 1) { total = 1; } else if (value == 2) { total = 2; } else if (value == 3) { total = 3; } "
        -- The statement inside the given number of if statements, at level count + 1.
        around :: Int -> String -> String
        around count statement =
            "int total = 0; " ++ concat (replicate count "if (value >= 0) { ") ++ statement ++ concat (replicate count "} ") ++ "return total;"
