-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Tests for the source warnings, which today are the two spellings of the
removed decrement operator.

A warning must never change what compiles: every text below that the
compiler accepts is still accepted, and the warning only points at the place
where @--@ became a comment.
-}
module SourceWarningTests (sourceWarningTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.SourceWarnings

sourceWarningTests :: [(String, Bool)]
sourceWarningTests =
    [ ("an attached double dash after a name is warned about", positions "count--;" == [(1, 6)])
    , ("an attached double dash after a parenthesis is warned about", positions "(count)--;" == [(1, 8)])
    , ("an attached double dash after an index is warned about", positions "items[i]--;" == [(1, 9)])
    , ("a leading double dash before a terminated name is warned about", positions "--count;" == [(1, 1)])
    , ("a leading double dash tolerates blanks around the terminator", positions "  --count ;  " == [(1, 3)])
    , ("every occurrence is reported in source order", positions "a--;\nb = 1;\n--c;" == [(1, 2), (3, 1)])
    , ("the warning is a lexer-stage warning with its own code", attachedShape)
    , ("the two spellings give different advice", differentAdvice)
    , ("a spaced comment after code is not warned about", quiet "count -- one less")
    , ("a comment on its own line is not warned about", quiet "-- count the items")
    , ("a comment that starts with a word and continues is not warned about", quiet "--count the items;")
    , ("commented-out code that is not a bare name is not warned about", quiet "--count = 5;")
    , ("an attached comment after an operator is not warned about", quiet "total = left +-- right\n1;")
    , ("a documentation comment is never a decrement spelling", quiet "value--| documented\n--!module;")
    , ("a long comment is never a decrement spelling", quiet "value--[[ long ]] + 1; --[[name;]]")
    , ("a double dash inside a string is not a comment at all", quiet "String text = \"count--;\";")
    , ("a double dash inside a raw string is not a comment at all", quiet "String text = [[--count;]];")
    , ("compound subtraction is the replacement and is not warned about", quiet "count -= 1; total = a - -b;")
    , ("a text with a lexical error has no warnings", quiet "count--;\n\"unterminated")
    , ("an empty text has no warnings", quiet "")
    , ("a warned program still compiles when it is otherwise valid", warnedProgramStillCompiles)
    , ("the warning does not turn a valid program into an error", null (lefts (compileToCorePrep validWarned)))
    ]

warnings :: String -> [Diagnostic]
warnings = sourceWarnings "warnings.tala"

-- | Line and column of each warning's start.
positions :: String -> [(Int, Int)]
positions text =
    [ (sourceLine start, sourceColumn start)
    | diagnostic <- warnings text
    , Just spanValue <- [diagnosticSpan diagnostic]
    , let start = sourceStart spanValue
    ]

quiet :: String -> Bool
quiet = null . warnings

attachedShape :: Bool
attachedShape = case warnings "count--;" of
    [Diagnostic LexerStage Warning code (Just spanValue) _] ->
        code == decrementSpellingCode
            && code == "TAL0009"
            && sourceFile spanValue == "warnings.tala"
            -- The span covers exactly the two characters of the sign.
            && sourceColumn (sourceEnd spanValue) - sourceColumn (sourceStart spanValue) == 2
            && sourceLine (sourceEnd spanValue) == sourceLine (sourceStart spanValue)
    _ -> False

differentAdvice :: Bool
differentAdvice = case (warnings "count--;", warnings "--count;") of
    ([attached], [leading]) ->
        diagnosticMessage attached /= diagnosticMessage leading
            && all (mentions "no decrement operator") [attached, leading]
            && mentions "space before" attached
            && mentions "space after" leading
    _ -> False
    where
        mentions needle diagnostic = needle `isInfixOfText` diagnosticMessage diagnostic

isInfixOfText :: String -> String -> Bool
isInfixOfText needle haystack = any (startsWith needle) (suffixes haystack)
    where
        startsWith prefix text = take (length prefix) text == prefix
        suffixes text = case text of
            [] -> [[]]
            _ : rest -> text : suffixes rest

-- `value--;` leaves the name as the final expression of its block, so the
-- program is accepted. The warning is the only sign that nothing is
-- subtracted.
validWarned :: CompilerInput
validWarned =
    CompilerInput
        "warnings.tala"
        ( unlines
            [ "class Program {"
            , "    public static int Evaluate(_ int limit) {"
            , "        int value = limit;"
            , "        value--;"
            , "    }"
            , "}"
            ]
        )

warnedProgramStillCompiles :: Bool
warnedProgramStillCompiles =
    length (sourceWarnings "warnings.tala" (compilerSourceText validWarned)) == 1

lefts :: Either [left] right -> [left]
lefts = either id (const [])
