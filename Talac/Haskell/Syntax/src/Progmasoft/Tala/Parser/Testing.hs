-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | The syntax of tests: the @[Fact]@ attribute and the @#expect@ statement.

@#expect condition;@ leaves the parser as ordinary statements. Its
operands are bound once, the condition is tested, and when it is false a
call of the test runtime records the failure with a report the parser has
already written: the source location and the text of the condition, and
for a comparison the text of each operand that is not a literal, which the
type checker pairs with its value. Every stage after the parser sees only
bindings, an @if@ and a call; none of them knows about tests.

The call is a method of @$Test@, a name the language declares for every
program and that no source can spell, because no identifier starts with
@$@. Where @#expect@ may stand is the directive pass's decision.
-}
module Progmasoft.Tala.Parser.Testing
    ( parseFactAttribute
    , parseExpectStatement
    , testReceiverName
    ) where

import Data.Char (isAlphaNum)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Parser.Cursor
import Progmasoft.Tala.Parser.Token

-- | The spelling of the receiver of the test runtime's methods.
testReceiverName :: Identifier
testReceiverName = Identifier "$Test"

{- | @[Fact]@ or @[Fact("name")]@ before a method, when one stands there.
@[Fact]@ followed by a name and a parenthesis is an array type, the return
type of a method named after it, and is left alone.
-}
parseFactAttribute :: P (Maybe FactAttribute)
parseFactAttribute = do
    tokens <- peekTokens 5
    case tokens of
        open : name : close : next : afterNext
            | isSymbol "[" open
            , isFact name
            , isSymbol "]" close
            , not (tokenKind next == IdentifierToken && take 1 (map (isSymbol "(") afterNext) == [True]) -> do
                _ <- takeToken
                _ <- takeToken
                end <- takeToken
                pure (Just (FactAttribute (mergeSpans (tokenSpan open) (tokenSpan end)) Nothing))
        open : name : parenthesis : _
            | isSymbol "[" open
            , isFact name
            , isSymbol "(" parenthesis -> do
                _ <- takeToken
                _ <- takeToken
                _ <- takeToken
                label <- satisfy ((== StringToken) . tokenKind) "the name of the test as a string literal"
                _ <- symbol ")"
                end <- symbol "]"
                pure (Just (FactAttribute (mergeSpans (tokenSpan open) (tokenSpan end)) (Just (tokenText label))))
        _ -> pure Nothing
    where
        isFact token = tokenKind token == IdentifierToken && tokenText token == "Fact"

{- | @#expect condition;@, with the condition parser of @if@. The result is
a block that names the operands it binds with spellings no source can
write, so they hide nothing of the program.
-}
parseExpectStatement :: P (Expression Identifier ()) -> P (Statement Identifier ())
parseExpectStatement conditionParser = do
    start <- takeToken
    (condition, tokens) <- withTokens conditionParser
    end <- symbol ";"
    let spanValue = mergeSpans (tokenSpan start) (tokenSpan end)
        position = sourceStart (tokenSpan start)
        header =
            sourceFile (tokenSpan start)
                ++ ":"
                ++ show (sourceLine position)
                ++ ":"
                ++ show (sourceColumn position)
                ++ ": expectation failed: "
                ++ renderTokens tokens
    pure (BlockStatement spanValue (Block (lower spanValue header condition tokens)))
    where
        lower spanValue header condition tokens = case condition of
            BinaryExpression operatorSpan operator left right ()
                | operator `elem` [Equal, NotEqual, LessThan, LessEqual, GreaterThan, GreaterEqual] ->
                    let leftName = Identifier "$left"
                        rightName = Identifier "$right"
                        bind name value = BindingStatement (expressionSourceSpan value) ImmutableBinding AutoType name () value
                        reference name value = NameExpression (expressionSourceSpan value) name ()
                        compared =
                            BinaryExpression operatorSpan operator (reference leftName left) (reference rightName right) ()
                        shown =
                            concat
                                [ [LiteralExpression spanValue (StringLiteral (renderTokens (operandTokens value tokens))) (), reference name value]
                                | (name, value) <- [(leftName, left), (rightName, right)]
                                , not (isLiteral value)
                                ]
                     in [bind leftName left, bind rightName right, check spanValue header compared shown]
            _ -> [check spanValue header condition []]

        check spanValue header condition shown =
            IfStatement
                spanValue
                (UnaryExpression spanValue LogicalNot condition ())
                ( Block
                    [ ExpressionStatement
                        spanValue
                        ( CallExpression
                            spanValue
                            (MemberAccessExpression spanValue (NameExpression spanValue testReceiverName ()) (Identifier "Fail") ())
                            (LiteralExpression spanValue (StringLiteral header) () : shown)
                            ()
                        )
                        True
                    ]
                )
                Nothing

        isLiteral value = case value of
            LiteralExpression {} -> True
            UnaryExpression _ UnaryNegate LiteralExpression {} _ -> True
            _ -> False

-- | The tokens of a condition that fall inside the span of one operand.
operandTokens :: Expression Identifier () -> [Token] -> [Token]
operandTokens value = filter inside
    where
        spanValue = expressionSourceSpan value
        inside token =
            position (sourceStart (tokenSpan token)) >= position (sourceStart spanValue)
                && position (sourceEnd (tokenSpan token)) <= position (sourceEnd spanValue)
        position point = (sourceLine point, sourceColumn point)

{- | Tokens as source text: the spaces between tokens on one line are kept,
a line break becomes one space, and a string is written with quotes and
escapes again.
-}
renderTokens :: [Token] -> String
renderTokens tokens = concat (zipWith piece (Nothing : map Just tokens) tokens)
    where
        piece previous token = gap previous token ++ spelling token
        gap previous token = case previous of
            Nothing -> ""
            Just before
                | sourceLine (sourceEnd (tokenSpan before)) == sourceLine (sourceStart (tokenSpan token)) ->
                    replicate (max 0 (sourceColumn (sourceStart (tokenSpan token)) - sourceColumn (sourceEnd (tokenSpan before)))) ' '
                | otherwise -> " "
        spelling token = case tokenKind token of
            StringToken -> "\"" ++ concatMap escape (tokenText token) ++ "\""
            _ -> tokenText token
        escape character = case character of
            '"' -> "\\\""
            '\\' -> "\\\\"
            '\n' -> "\\n"
            '\t' -> "\\t"
            '\r' -> "\\r"
            _ | isAlphaNum character || character >= ' ' -> [character]
            _ -> "?"

isSymbol :: String -> Token -> Bool
isSymbol text token = tokenKind token == SymbolToken && tokenText token == text

mergeSpans :: SourceSpan -> SourceSpan -> SourceSpan
mergeSpans first final = first {sourceEnd = sourceEnd final}
