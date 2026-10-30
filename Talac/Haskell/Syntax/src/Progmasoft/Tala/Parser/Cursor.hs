-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Progmasoft.Tala.Parser.Cursor
    ( P
    , runP
    , (<|?>)
    , optionalParser
    , matchesAhead
    , peekToken
    , peekTokens
    , peekText
    , peekKind
    , takeToken
    , satisfy
    , keyword
    , contextualWord
    , symbol
    , optionalSymbol
    , failCurrent
    , failAt
    , problemAt
    , withSpan
    , withTokens
    , endOfInput
    ) where

import Progmasoft.Tala.AST (SourceSpan (..))
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Parser.Token

-- Consumption is measured in tokens, independently of source spans. Synthetic
-- input may contain identical spans, and decoded String payload lengths need
-- not equal the source width. Neither is a safe backtracking checkpoint.
data Cursor = Cursor
    { remainingTokens :: [Token]
    , consumedTokens :: !Int
    , previousSpan :: Maybe SourceSpan
    }

data Reply a
    = Accepted a Cursor
    | Rejected Diagnostic !Int

newtype P a = P {step :: Cursor -> Reply a}

instance Functor P where
    fmap function parser = P $ \cursor -> case step parser cursor of
        Accepted value next -> Accepted (function value) next
        Rejected problem offset -> Rejected problem offset

instance Applicative P where
    pure value = P (Accepted value)
    functions <*> values = do
        function <- functions
        value <- values
        pure (function value)

instance Monad P where
    parser >>= continuation = P $ \cursor -> case step parser cursor of
        Accepted value next -> step (continuation value) next
        Rejected problem offset -> Rejected problem offset

runP :: P a -> [Token] -> Either Diagnostic (a, [Token])
runP parser tokens = case step parser (Cursor tokens 0 Nothing) of
    Accepted value cursor -> Right (value, remainingTokens cursor)
    Rejected problem _ -> Left problem

-- Alternatives may retry only when the first parser consumed nothing. Once a
-- declaration keyword or delimiter has been read, its failure belongs to that
-- construct. Falling back would replace the useful diagnostic with a guess.
(<|?>) :: P a -> P a -> P a
left <|?> right = P $ \cursor -> case step left cursor of
    Rejected _ offset | offset == consumedTokens cursor -> step right cursor
    result -> result

optionalParser :: P a -> P (Maybe a)
optionalParser parser = (Just <$> parser) <|?> pure Nothing

-- Lookahead is deliberately explicit. It is used only to choose an ambiguous
-- grammar branch and never exposes a parsed value whose cursor was discarded.
matchesAhead :: P a -> P Bool
matchesAhead parser = P $ \cursor -> case step parser cursor of
    Accepted _ _ -> Accepted True cursor
    Rejected _ _ -> Accepted False cursor

peekToken :: P (Maybe Token)
peekToken = P $ \cursor ->
    Accepted
        ( case remainingTokens cursor of
            [] -> Nothing
            token : _ -> Just token
        )
        cursor

-- Bounded lookahead chooses ambiguous identifier-led statements without
-- executing and rolling back a full expression or declaration parser.
peekTokens :: Int -> P [Token]
peekTokens count = P $ \cursor -> Accepted (take count (remainingTokens cursor)) cursor

peekText :: String -> P Bool
peekText text = maybe False matches <$> peekToken
    where
        matches token = tokenKind token `elem` [KeywordToken, SymbolToken] && tokenText token == text

peekKind :: TokenKind -> P Bool
peekKind kind = maybe False ((== kind) . tokenKind) <$> peekToken

takeToken :: P Token
takeToken = P $ \cursor -> case remainingTokens cursor of
    token : rest ->
        Accepted token (Cursor rest (consumedTokens cursor + 1) (Just (tokenSpan token)))
    [] -> reject cursor "TAP0008" "unexpected end of input"

satisfy :: (Token -> Bool) -> String -> P Token
satisfy predicate expectation = do
    next <- peekToken
    case next of
        Just token | predicate token -> takeToken
        Just token -> failCurrent "TAP0006" ("expected " ++ expectation ++ ", found " ++ show (tokenText token))
        Nothing -> failCurrent "TAP0007" ("expected " ++ expectation ++ " at end of input")

-- Checking the kind as well as the spelling prevents decoded literals whose
-- payload happens to be a keyword or delimiter from changing the grammar.
keyword :: String -> P Token
keyword text = satisfy matches (show text)
    where
        matches token =
            tokenText token == text
                && ( tokenKind token == KeywordToken
                        || (text `elem` ["weak", "unowned"] && tokenKind token == IdentifierToken)
                   )

-- Contextual separators remain ordinary identifiers outside their owning
-- syntax. This avoids reserving words such as `to` throughout the language.
contextualWord :: String -> P Token
contextualWord text =
    satisfy
        (\token -> tokenKind token `elem` [IdentifierToken, KeywordToken] && tokenText token == text)
        (show text)

symbol :: String -> P Token
symbol text = satisfy (\token -> tokenKind token == SymbolToken && tokenText token == text) (show text)

optionalSymbol :: String -> P Bool
optionalSymbol text = do
    next <- peekToken
    case next of
        Just token | tokenKind token == SymbolToken && tokenText token == text -> takeToken >> pure True
        _ -> pure False

failCurrent :: String -> String -> P a
failCurrent code message = P $ \cursor -> reject cursor code message

failAt :: SourceSpan -> String -> String -> P a
failAt spanValue code message = P $ \cursor ->
    Rejected (Diagnostic ParserStage Error code (Just spanValue) message) (consumedTokens cursor)

reject :: Cursor -> String -> String -> Reply a
reject cursor code message =
    Rejected
        (Diagnostic ParserStage Error code (currentSpan cursor) message)
        (consumedTokens cursor)

currentSpan :: Cursor -> Maybe SourceSpan
currentSpan cursor = case remainingTokens cursor of
    token : _ -> Just (tokenSpan token)
    [] -> endSpan <$> previousSpan cursor

endSpan :: SourceSpan -> SourceSpan
endSpan value = value {sourceStart = sourceEnd value}

problemAt :: Token -> String -> String -> Diagnostic
problemAt token code message = Diagnostic ParserStage Error code (Just (tokenSpan token)) message

-- Delimiters belong to the construct's span even when its body is empty.
-- Capturing cursor positions also preserves the filename of empty closures.
withSpan :: P a -> P (a, SourceSpan)
withSpan parser = P $ \cursor -> case currentSpan cursor of
    Nothing -> reject cursor "TAP0008" "expected construct at end of input"
    Just start -> case step parser cursor of
        Rejected problem offset -> Rejected problem offset
        Accepted value next ->
            let finish = maybe start id (previousSpan next)
                spanValue = start {sourceEnd = sourceEnd finish}
             in Accepted (value, spanValue) next

-- | The value of a parser and the tokens it consumed, in order.
withTokens :: P a -> P (a, [Token])
withTokens parser = P $ \cursor -> case step parser cursor of
    Rejected problem offset -> Rejected problem offset
    Accepted value next ->
        Accepted (value, take (consumedTokens next - consumedTokens cursor) (remainingTokens cursor)) next

-- The public Parser accepts token streams as well as lexer output. An EOF in
-- the middle must never hide the suffix of a malformed supplied stream.
endOfInput :: P ()
endOfInput = do
    next <- peekToken
    case next of
        Nothing -> pure ()
        Just token | tokenKind token == EndOfFileToken -> do
            _ <- takeToken
            trailing <- peekToken
            case trailing of
                Nothing -> pure ()
                Just extra -> failAt (tokenSpan extra) "TAP0015" "tokens follow the end-of-file marker"
        Just token -> failAt (tokenSpan token) "TAP0001" ("unexpected token " ++ show (tokenText token))
