-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module SourceTextTests (sourceTextTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.SourceText

sourceTextTests :: [(String, Bool)]
sourceTextTests =
    [ ("lossless source fragments reconstruct mixed source", reconstructsMixedSource)
    , ("source fragments classify every protected spelling", classifiesProtectedSpelling)
    , ("source fragment spans cross CRLF exactly once", spansTrackCrLf)
    , ("source mask hides structural characters in protected text", masksProtectedBraces)
    , ("source mask retains physical line endings", maskRetainsLineEndings)
    , ("multi-line raw strings protect every crossed line", rawStringProtectedLines)
    , ("multi-line long comments protect every crossed line", longCommentProtectedLines)
    , ("single-line protected fragments do not protect indentation", singleLineFragmentsRemainIndentable)
    , ("an attached double dash begins a line comment", attachedDoubleDashIsComment)
    , ("a double dash after a literal begins a line comment", literalDoubleDashIsComment)
    , ("spaced double dash begins a line comment", spacedDoubleDashIsComment)
    , ("unterminated normal strings have a lossless-scan diagnostic", rejectsUnterminatedString)
    , ("unterminated character literals have a lossless-scan diagnostic", rejectsUnterminatedCharacter)
    , ("unterminated raw strings have a lossless-scan diagnostic", rejectsUnterminatedRawString)
    , ("unterminated long comments have a lossless-scan diagnostic", rejectsUnterminatedLongComment)
    ]

mixedSource :: String
mixedSource =
    "namespace Demo;\r\n"
        ++ "-- ordinary { comment }\n"
        ++ "class Program {\n"
        ++ "  String text = \"escaped \\\" }\";\n"
        ++ "  char marker = '}';\n"
        ++ "  auto raw = [=[\n{ untouched }\n]=];\n"
        ++ "  --[==[ long { comment ]=] still open ]==]\n"
        ++ "}\n"

fragmentsOf :: String -> Either [Diagnostic] [SourceFragment]
fragmentsOf = scanSourceFragments "source-text.tala"

reconstructsMixedSource :: Bool
reconstructsMixedSource = (reconstructSource <$> fragmentsOf mixedSource) == Right mixedSource

classifiesProtectedSpelling :: Bool
classifiesProtectedSpelling = case fragmentsOf mixedSource of
    Right fragments ->
        all
            (`elem` map sourceFragmentKind fragments)
            [ CodeFragment
            , LineCommentFragment
            , LongCommentFragment
            , StringLiteralFragment
            , CharacterLiteralFragment
            , RawStringLiteralFragment
            ]
    Left _ -> False

spansTrackCrLf :: Bool
spansTrackCrLf = case fragmentsOf "code\r\n\"text\"" of
    Right [code, literal] ->
        sourceFragmentSpan code == SourceSpan "source-text.tala" (SourcePosition 1 1) (SourcePosition 2 1)
            && sourceFragmentSpan literal == SourceSpan "source-text.tala" (SourcePosition 2 1) (SourcePosition 2 7)
    _ -> False

masksProtectedBraces :: Bool
masksProtectedBraces = case fragmentsOf "class A { String x = \"}\"; -- {\n}" of
    Right fragments -> maskedSource fragments == "class A { String x =    ;     \n}"
    Left _ -> False

maskRetainsLineEndings :: Bool
maskRetainsLineEndings = case fragmentsOf "-- a\r\n\"b\nc\"\r\n" of
    Right fragments -> filter (`elem` "\r\n") (maskedSource fragments) == "\r\n\n\r\n"
    Left _ -> False

rawStringProtectedLines :: Bool
rawStringProtectedLines = case fragmentsOf "auto value = [=[\n one \n two \n]=];" of
    Right fragments -> protectedLineNumbers fragments == [1, 2, 3, 4]
    Left _ -> False

longCommentProtectedLines :: Bool
longCommentProtectedLines = case fragmentsOf "--[=[ first\n second\n]=]\nclass A {}" of
    Right fragments -> protectedLineNumbers fragments == [1, 2, 3]
    Left _ -> False

singleLineFragmentsRemainIndentable :: Bool
singleLineFragmentsRemainIndentable = case fragmentsOf "\"text\" -- comment\n" of
    Right fragments -> null (protectedLineNumbers fragments)
    Left _ -> False

attachedDoubleDashIsComment :: Bool
attachedDoubleDashIsComment = case fragmentsOf "value--;" of
    Right [code, comment] ->
        sourceFragmentKind code == CodeFragment
            && sourceFragmentText code == "value"
            && sourceFragmentKind comment == LineCommentFragment
            && sourceFragmentText comment == "--;"
    _ -> False

literalDoubleDashIsComment :: Bool
literalDoubleDashIsComment = case fragmentsOf "\"value\"--;" of
    Right [literal, comment] ->
        sourceFragmentKind literal == StringLiteralFragment
            && sourceFragmentKind comment == LineCommentFragment
            && sourceFragmentText comment == "--;"
    _ -> False

spacedDoubleDashIsComment :: Bool
spacedDoubleDashIsComment = case fragmentsOf "value -- explanation" of
    Right [code, comment] ->
        sourceFragmentKind code == CodeFragment
            && sourceFragmentText code == "value "
            && sourceFragmentKind comment == LineCommentFragment
    _ -> False

rejectsUnterminatedString :: Bool
rejectsUnterminatedString = hasCode "TAL0101" (fragmentsOf "\"open")

rejectsUnterminatedCharacter :: Bool
rejectsUnterminatedCharacter = hasCode "TAL0102" (fragmentsOf "'x")

rejectsUnterminatedRawString :: Bool
rejectsUnterminatedRawString = hasCode "TAL0103" (fragmentsOf "[=[open")

rejectsUnterminatedLongComment :: Bool
rejectsUnterminatedLongComment = hasCode "TAL0104" (fragmentsOf "--[=[open")

hasCode :: String -> Either [Diagnostic] value -> Bool
hasCode code result = case result of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False
