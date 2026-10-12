-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Compiler diagnostics and the first independently actionable lint checks.

The linter consumes the compiler's semantic frontend rather than approximating
language validity. Source-hygiene checks operate on the original physical text
because line endings and trailing whitespace are intentionally absent from the
semantic AST.
-}
module Progmasoft.Talalint
    ( LintSeverity (..)
    , LintDiagnostic (..)
    , availableChecks
    , lintSource
    , applySafeFixes
    ) where

import Data.List (nub, sortOn)
import Progmasoft.Talafmt
import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend

data LintSeverity = LintInfo | LintWarning | LintError
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

data LintDiagnostic = LintDiagnostic
    { lintRuleId :: String
    , lintSeverity :: LintSeverity
    , lintSpan :: Maybe SourceSpan
    , lintMessage :: String
    }
    deriving (Eq, Ord, Read, Show)

availableChecks :: [(String, String)]
availableChecks =
    [ ("compiler", "Diagnostics produced by the canonical semantic frontend")
    , ("format.trailingWhitespace", "Trailing spaces or tabs at the end of a physical line")
    , ("format.mixedLineEndings", "More than one physical line-ending convention in a file")
    , ("format.missingFinalNewline", "A non-empty source file without a final newline")
    ]

lintSource :: CompilerInput -> [LintDiagnostic]
lintSource input =
    sortOn
        diagnosticOrder
        ( compilerDiagnostics input
            ++ trailingWhitespaceDiagnostics input
            ++ mixedLineEndingDiagnostics input
            ++ missingFinalNewlineDiagnostics input
        )

applySafeFixes :: CompilerInput -> Either [Diagnostic] FormatResult
applySafeFixes = formatSource defaultFormatOptions

compilerDiagnostics :: CompilerInput -> [LintDiagnostic]
compilerDiagnostics input = case analyzeSemantics input of
    Left problems -> map compilerDiagnostic problems
    Right _ -> []

compilerDiagnostic :: Diagnostic -> LintDiagnostic
compilerDiagnostic problem =
    LintDiagnostic
        ("compiler." ++ diagnosticCode problem)
        (case diagnosticSeverity problem of Error -> LintError; Warning -> LintWarning)
        (diagnosticSpan problem)
        (diagnosticMessage problem)

trailingWhitespaceDiagnostics :: CompilerInput -> [LintDiagnostic]
trailingWhitespaceDiagnostics input =
    [ LintDiagnostic
        "format.trailingWhitespace"
        LintWarning
        (Just (lineSpan (compilerSourceFile input) lineNumber startColumn (length line + 1)))
        "physical line has trailing whitespace"
    | (lineNumber, line) <- zip [1 ..] (logicalLines (compilerSourceText input))
    , let trimmed = trimHorizontalEnd line
          startColumn = length trimmed + 1
    , length trimmed /= length line
    ]

mixedLineEndingDiagnostics :: CompilerInput -> [LintDiagnostic]
mixedLineEndingDiagnostics input
    | length (nub (lineEndings (compilerSourceText input))) > 1 =
        [ LintDiagnostic
            "format.mixedLineEndings"
            LintWarning
            (Just (lineSpan (compilerSourceFile input) 1 1 1))
            "source file mixes physical line-ending conventions"
        ]
    | otherwise = []

missingFinalNewlineDiagnostics :: CompilerInput -> [LintDiagnostic]
missingFinalNewlineDiagnostics input
    | null source || endsWithLineBreak source = []
    | otherwise =
        let (lineNumber, column) = endPosition source
         in [ LintDiagnostic
                "format.missingFinalNewline"
                LintWarning
                (Just (lineSpan (compilerSourceFile input) lineNumber column column))
                "source file does not end with a newline"
            ]
    where
        source = compilerSourceText input

diagnosticOrder :: LintDiagnostic -> (FilePath, Int, Int, String)
diagnosticOrder problem = case lintSpan problem of
    Just spanValue ->
        ( sourceFile spanValue
        , sourceLine (sourceStart spanValue)
        , sourceColumn (sourceStart spanValue)
        , lintRuleId problem
        )
    Nothing -> ("", 0, 0, lintRuleId problem)

lineSpan :: FilePath -> Int -> Int -> Int -> SourceSpan
lineSpan file line startColumn endColumn =
    SourceSpan file (SourcePosition line startColumn) (SourcePosition line endColumn)

logicalLines :: String -> [String]
logicalLines source = case break isLineBreak source of
    (line, []) -> [line]
    (line, '\r' : '\n' : remaining) -> line : logicalLines remaining
    (line, _ : remaining) -> line : logicalLines remaining

lineEndings :: String -> [String]
lineEndings [] = []
lineEndings ('\r' : '\n' : remaining) = "CRLF" : lineEndings remaining
lineEndings ('\r' : remaining) = "CR" : lineEndings remaining
lineEndings ('\n' : remaining) = "LF" : lineEndings remaining
lineEndings (_ : remaining) = lineEndings remaining

endsWithLineBreak :: String -> Bool
endsWithLineBreak source = case reverse source of
    '\n' : _ -> True
    '\r' : _ -> True
    _ -> False

endPosition :: String -> (Int, Int)
endPosition = go 1 1
    where
        go line column [] = (line, column)
        go line _ ('\r' : '\n' : remaining) = go (line + 1) 1 remaining
        go line _ ('\r' : remaining) = go (line + 1) 1 remaining
        go line _ ('\n' : remaining) = go (line + 1) 1 remaining
        go line column (_ : remaining) = go line (column + 1) remaining

trimHorizontalEnd :: String -> String
trimHorizontalEnd = reverse . dropWhile isHorizontalSpace . reverse
    where
        isHorizontalSpace character = character == ' ' || character == '\t'

isLineBreak :: Char -> Bool
isLineBreak character = character == '\r' || character == '\n'
