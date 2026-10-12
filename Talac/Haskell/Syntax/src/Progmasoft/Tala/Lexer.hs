-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

-- | Configurable lexical scanner that returns source-positioned tokens.
module Progmasoft.Tala.Lexer (LexerInput (..), Lexer (..), defaultLexer, runLexer) where

import Data.Char (chr, digitToInt, isAlpha, isAlphaNum, isDigit, isHexDigit, isSpace)
import Data.List (stripPrefix)
import Progmasoft.Tala.AST (SourcePosition (..), SourceSpan (..))
import Progmasoft.Tala.CharacterLiteral
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.FloatingLiteral
import Progmasoft.Tala.NumericLiteral
import Progmasoft.Tala.Parser (Token (..), TokenKind (..))

-- | Source identity and complete text supplied to a lexer implementation.
data LexerInput = LexerInput {lexerSourceFile :: FilePath, lexerSourceText :: String}
    deriving stock (Eq, Ord, Read, Show)

-- | Lexer strategy whose failures are returned as structured diagnostics.
newtype Lexer = Lexer {lexSource :: LexerInput -> Either [Diagnostic] [Token]}

-- | Run a lexer over a source input.
runLexer :: Lexer -> LexerInput -> Either [Diagnostic] [Token]
runLexer = lexSource

-- | Default Tala lexer implementation.
defaultLexer :: Lexer
defaultLexer = Lexer lexTala

-- Long comments and raw strings deliberately share one delimiter recognizer. Keeping
-- the level matching in one place prevents the two source forms from drifting apart.
lexTala :: LexerInput -> Either [Diagnostic] [Token]
lexTala (LexerInput file source) = go 1 1 source []
    where
        go line column [] output = Right (reverse (token EndOfFileToken "" line column line column : output))
        go line column input@(character : rest) output
            | Just remaining <- stripPrefix "--" input =
                lexComment line column remaining output
            | Just (level, openerWidth, remaining) <- longBracketOpener input =
                lexRawString line column level openerWidth remaining output
            | Just (nextLine, nextColumn, remaining) <- consumeLineBreak line column input =
                go nextLine nextColumn remaining output
            | isSpace character = go line (column + 1) rest output
            | isAlpha character || character == '_' =
                let (tailText, remaining) = span (\c -> isAlphaNum c || c == '_') rest
                    text = character : tailText
                    kind = if text `elem` keywords then KeywordToken else IdentifierToken
                 in go line (column + length text) remaining (token kind text line column line (column + length text) : output)
            | isDigit character =
                let (text, remaining) = scanNumericCandidate input
                 in if isFloatingCandidate text
                        then case validateFloatingSpelling text of
                            Left issue -> Left [diagnostic "TAL0008" line column (renderFloatingLiteralError issue)]
                            Right _ ->
                                go
                                    line
                                    (column + length text)
                                    remaining
                                    (token FloatingToken text line column line (column + length text) : output)
                        else case parseIntegerSpelling text of
                            Left issue -> Left [diagnostic "TAL0006" line column (renderIntegerLiteralError issue)]
                            Right _ ->
                                go
                                    line
                                    (column + length text)
                                    remaining
                                    (token IntegerToken text line column line (column + length text) : output)
            | character == '"' = lexString line column rest output
            | character == '\'' = case scanCharacterLiteral input of
                Left issue -> Left [diagnostic "TAL0007" line column (renderCharacterLiteralError issue)]
                Right (text, remaining) ->
                    go
                        line
                        (column + length text)
                        remaining
                        (token CharacterToken text line column line (column + length text) : output)
            | otherwise = case longestSymbol input of
                Just symbol ->
                    go
                        line
                        (column + length symbol)
                        (drop (length symbol) input)
                        (token SymbolToken symbol line column line (column + length symbol) : output)
                Nothing -> Left [diagnostic "TAL0001" line column ("unsupported character " ++ show character)]

        -- Documentation markers are consumed with their comments. Their eventual
        -- Document-attribute lowering belongs to the Attributes/AST stage, not to the
        -- delimiter scanner. Recognizing them here still gives every form the exact
        -- language-defined termination and source-position rules.
        lexComment line column input output = case longBracketOpener input of
            Just (level, openerWidth, afterOpener) ->
                let afterMarker = dropDocumentationMarker afterOpener
                    markerWidth = length afterOpener - length afterMarker
                 in skipLongComment line (column + 2 + openerWidth + markerWidth) level afterMarker output
            Nothing ->
                let afterMarker = dropDocumentationMarker input
                    (comment, remaining) = break isLineBreak afterMarker
                 in go line (column + 2 + (length input - length afterMarker) + length comment) remaining output

        skipLongComment line column level input output = case stripPrefix (longBracketCloser level) input of
            Just remaining -> go line (column + level + 2) remaining output
            Nothing -> case input of
                [] -> Left [diagnostic "TAL0002" line column "unterminated long comment"]
                _
                    | Just (nextLine, nextColumn, remaining) <- consumeLineBreak line column input ->
                        skipLongComment nextLine nextColumn level remaining output
                (_ : remaining) -> skipLongComment line (column + 1) level remaining output

        lexRawString startLine startColumn level openerWidth input output =
            let (line, column, content) = case consumeLineBreak startLine (startColumn + openerWidth) input of
                    Just (nextLine, nextColumn, remaining) -> (nextLine, nextColumn, remaining)
                    Nothing -> (startLine, startColumn + openerWidth, input)
             in collectRaw startLine startColumn line column level content [] output

        collectRaw startLine startColumn line column level input value output =
            case stripPrefix (longBracketCloser level) input of
                Just remaining ->
                    let text = dropFinalBoundaryNewline (reverse value)
                        endColumn = column + level + 2
                     in go
                            line
                            endColumn
                            remaining
                            (token StringToken text startLine startColumn line endColumn : output)
                Nothing -> case input of
                    [] -> Left [diagnostic "TAL0005" startLine startColumn "unterminated raw string literal"]
                    _
                        | Just (nextLine, nextColumn, remaining) <- consumeLineBreak line column input ->
                            collectRaw startLine startColumn nextLine nextColumn level remaining ('\n' : value) output
                    (next : remaining) -> collectRaw startLine startColumn line (column + 1) level remaining (next : value) output

        -- Normal strings retain the core escape table. Unlike raw strings, physical
        -- line breaks are normalized to one space and escape sequences are decoded.
        lexString startLine startColumn input output = collect input [] startLine (startColumn + 1)
            where
                collect [] _ currentLine currentColumn =
                    Left [diagnostic "TAL0003" currentLine currentColumn "unterminated string literal"]
                collect ('"' : remaining) value currentLine currentColumn =
                    let text = reverse value
                     in go
                            currentLine
                            (currentColumn + 1)
                            remaining
                            (token StringToken text startLine startColumn currentLine (currentColumn + 1) : output)
                collect current value currentLine currentColumn
                    | Just (nextLine, nextColumn, remaining) <- consumeLineBreak currentLine currentColumn current =
                        collect remaining (' ' : value) nextLine nextColumn
                collect ('\\' : remaining) value currentLine currentColumn =
                    case decodeEscape remaining of
                        Left message -> Left [diagnostic "TAL0004" currentLine currentColumn message]
                        Right (decoded, width, rest) -> collect rest (decoded : value) currentLine (currentColumn + width + 1)
                collect (next : remaining) value currentLine currentColumn =
                    collect remaining (next : value) currentLine (currentColumn + 1)

        token kind text startLine startColumn endLine endColumn =
            Token kind text (SourceSpan file (SourcePosition startLine startColumn) (SourcePosition endLine endColumn))
        diagnostic code line column message =
            Diagnostic
                LexerStage
                Error
                code
                (Just (SourceSpan file (SourcePosition line column) (SourcePosition line (column + 1))))
                message

dropDocumentationMarker :: String -> String
dropDocumentationMarker ('|' : remaining) = remaining
dropDocumentationMarker ('!' : remaining) = remaining
dropDocumentationMarker input = input

isLineBreak :: Char -> Bool
isLineBreak character = character == '\n' || character == '\r'

consumeLineBreak :: Int -> Int -> String -> Maybe (Int, Int, String)
consumeLineBreak line _ ('\r' : '\n' : remaining) = Just (line + 1, 1, remaining)
consumeLineBreak line _ ('\r' : remaining) = Just (line + 1, 1, remaining)
consumeLineBreak line _ ('\n' : remaining) = Just (line + 1, 1, remaining)
consumeLineBreak _ _ _ = Nothing

-- Returns the delimiter level, opener width, and content after the opener.
longBracketOpener :: String -> Maybe (Int, Int, String)
longBracketOpener ('[' : remaining) =
    let (equals, suffix) = span (== '=') remaining
     in case suffix of
            '[' : content -> Just (length equals, length equals + 2, content)
            _ -> Nothing
longBracketOpener _ = Nothing

longBracketCloser :: Int -> String
longBracketCloser level = ']' : replicate level '=' ++ "]"

dropFinalBoundaryNewline :: String -> String
dropFinalBoundaryNewline value = case reverse value of
    '\n' : remaining -> reverse remaining
    _ -> value

decodeEscape :: String -> Either String (Char, Int, String)
decodeEscape [] = Left "unterminated escape sequence"
decodeEscape (escape : remaining) = case escape of
    '\'' -> simple '\''
    '"' -> simple '"'
    '\\' -> simple '\\'
    '0' -> simple '\0'
    'a' -> simple '\a'
    'b' -> simple '\b'
    'e' -> simple (chr 0x1b)
    'f' -> simple '\f'
    'n' -> simple '\n'
    'r' -> simple '\r'
    't' -> simple '\t'
    'v' -> simple '\v'
    'x' -> hexadecimal remaining
    'u' -> exactHexadecimal 4 remaining
    'U' -> exactHexadecimal 8 remaining
    _ -> Left ("unsupported escape sequence \\" ++ [escape])
    where
        simple value = Right (value, 1, remaining)
        hexadecimal input =
            let (digits, rest) = span isHexDigit input
             in if null digits
                    then Left "hexadecimal escape requires at least one digit"
                    else scalar digits rest
        exactHexadecimal width input =
            let (digits, rest) = splitAt width input
             in if length digits /= width || any (not . isHexDigit) digits
                    then Left ("Unicode escape requires exactly " ++ show width ++ " hexadecimal digits")
                    else scalar digits rest
        scalar digits rest =
            let value = foldl (\total digit -> total * 16 + fromIntegral (digitToInt digit)) 0 digits :: Integer
             in if value > 0x10ffff || value >= 0xd800 && value <= 0xdfff
                    then Left "escape does not encode a Unicode scalar value"
                    else Right (chr (fromInteger value), length digits + 1, rest)

keywords :: [String]
keywords =
    [ "and"
    , "auto"
    , "bool"
    , "break"
    , "byte"
    , "char"
    , "class"
    , "continue"
    , "do"
    , "for"
    , "else"
    , "enum"
    , "false"
    , "final"
    , "guard"
    , "if"
    , "int"
    , "internal"
    , "is"
    , "long"
    , "longint"
    , "match"
    , "namespace"
    , "null"
    , "not"
    , "or"
    , "private"
    , "protected"
    , "public"
    , "return"
    , "static"
    , "template"
    , "typename"
    , "sfloat"
    , "lfloat"
    , "float"
    , "double"
    , "true"
    , "unit"
    , "ubyte"
    , "ushort"
    , "ulong"
    , "uint"
    , "ulongint"
    , "void"
    , "while"
    ]

longestSymbol :: String -> Maybe String
longestSymbol source =
    firstMatch
        [ "..."
        , "<<="
        , ">>="
        , "**="
        , "//="
        , "??="
        , "+="
        , "-="
        , "*="
        , "/="
        , "%="
        , "&="
        , "|="
        , "^="
        , "??"
        , "?:"
        , "::"
        , "=="
        , "\\="
        , "<="
        , ">="
        , "&&"
        , "||"
        , "//"
        , "->"
        , "**"
        , "++"
        , "{"
        , "}"
        , "("
        , ")"
        , ","
        , ":"
        , ";"
        , "."
        , "="
        , "+"
        , "-"
        , "*"
        , "/"
        , "%"
        , "&"
        , "|"
        , "^"
        , "<"
        , ">"
        , "!"
        , "?"
        , "["
        , "]"
        , "\\"
        ]
    where
        firstMatch [] = Nothing
        firstMatch (candidate : remaining)
            | take (length candidate) source == candidate = Just candidate
            | otherwise = firstMatch remaining
