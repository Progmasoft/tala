-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Grammar of @match@, of @if@ used as an expression, and of @guard@.

These forms contain expressions, blocks, and types, which the main parser
owns. They receive those parsers through 'BranchGrammar' instead of importing
them, so the main parser can depend on this module without a cycle and each
nested construct still has exactly one grammar.
-}
module Progmasoft.Tala.Parser.Match
    ( BranchGrammar (..)
    , parseCondition
    , parseIfExpression
    , parseMatchExpression
    , parseGuardStatement
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Parser.Cursor
import Progmasoft.Tala.Parser.Token

-- | The parsers of the main grammar that the branching forms are built from.
data BranchGrammar = BranchGrammar
    { grammarExpression :: P (Expression Identifier ())
    -- ^ A complete expression.
    , grammarValueBlock :: P (Block Identifier ())
    -- ^ A block that may end with an expression without a semicolon.
    , grammarStatementBlock :: P (Block Identifier ())
    -- ^ A block whose statements are all terminated.
    , grammarType :: P TypeSyntax
    -- ^ A type as written in a declaration.
    , grammarLiteral :: P (Literal, SourceSpan)
    -- ^ One literal token, decoded.
    }

{- | The condition of an @if@, @guard@, or @while@.

The grammar also allows a binding, @auto user = FindUser()@, whose test is
whether the bound value is present. That needs optional values, which the
compiler does not have, so the binding form is recognized and rejected by
name instead of failing later as a malformed expression.
-}
parseCondition :: BranchGrammar -> String -> P (Expression Identifier ())
parseCondition grammar construct = do
    binding <- matchesAhead (grammarType grammar >> identifierToken >> symbol "=")
    if binding
        then
            failCurrent
                "TAP0035"
                ( "a binding in "
                    ++ construct
                    ++ " condition requires optional values, which are not implemented"
                )
        else grammarExpression grammar

{- | @if (condition) { ... } else { ... }@ in operand position.

Both branches are blocks and both are required: the expression must have a
value whichever way the condition falls. The result is the conditional
expression node with block operands, so the two spellings of a two-way choice
share one typing rule and one lowering.
-}
parseIfExpression :: BranchGrammar -> P (Expression Identifier ())
parseIfExpression grammar = do
    ((condition, first, second), spanValue) <- withSpan $ do
        _ <- keyword "if"
        _ <- symbol "("
        condition <- parseCondition grammar "an if"
        _ <- symbol ")"
        first <- valueBlock grammar
        hasElse <- peekText "else"
        if hasElse
            then pure ()
            else failCurrent "TAP0033" "an if used as an expression requires an else branch"
        _ <- keyword "else"
        chained <- peekText "if"
        if chained
            then failCurrent "TAP0034" "the else branch of an if used as an expression must be a block"
            else pure ()
        second <- valueBlock grammar
        pure (condition, first, second)
    pure (ConditionalExpression spanValue condition first second ())

valueBlock :: BranchGrammar -> P (Expression Identifier ())
valueBlock grammar = do
    (block, spanValue) <- withSpan (grammarValueBlock grammar)
    pure (BlockExpression spanValue block ())

{- | @match (subject), ... { arm, ... }@.

The statement and the expression have the same grammar; the caller decides
which one it is from the position of the keyword.
-}
parseMatchExpression :: BranchGrammar -> P (Expression Identifier ())
parseMatchExpression grammar = do
    ((subjects, arms), spanValue) <- withSpan $ do
        _ <- keyword "match"
        subjects <- parseSubjects grammar
        _ <- symbol "{"
        arms <- parseArms grammar
        _ <- symbol "}"
        pure (subjects, arms)
    pure (MatchExpression spanValue subjects arms ())

-- Every subject has its own parentheses: @match (a), (b)@.
parseSubjects :: BranchGrammar -> P [Expression Identifier ()]
parseSubjects grammar = do
    _ <- symbol "("
    subject <- grammarExpression grammar
    _ <- symbol ")"
    more <- optionalSymbol ","
    if more then (subject :) <$> parseSubjects grammar else pure [subject]

parseArms :: BranchGrammar -> P [MatchArm Identifier ()]
parseArms grammar = do
    done <- peekText "}"
    eof <- peekKind EndOfFileToken
    if done
        then pure []
        else
            if eof
                then failCurrent "TAP0002" "unterminated match"
                else (:) <$> parseArm grammar <*> parseArms grammar

{- | One arm: @patterns [if guard] -> body [,]@.

The comma is optional after every body, as in the grammar. An expression
body is parsed like any expression, so a parenthesized pattern that follows
it without a comma is read as the argument list of a call of the body. That
reading is the grammar's own: the arrow that then follows cannot continue an
expression, and the diagnostic for it says what happened instead of naming
the arrow as unexpected.
-}
parseArm :: BranchGrammar -> P (MatchArm Identifier ())
parseArm grammar = do
    ((patterns, guard, body), spanValue) <- withSpan $ do
        patterns <- parsePatterns grammar
        guarded <- peekText "if"
        guard <-
            if guarded
                then do
                    _ <- keyword "if"
                    Just <$> grammarExpression grammar
                else pure Nothing
        _ <- symbol "->"
        blockBody <- peekText "{"
        body <- if blockBody then valueBlock grammar else grammarExpression grammar
        separated <- optionalSymbol ","
        swallowed <- peekText "->"
        if not blockBody && not separated && swallowed
            then
                failCurrent
                    "TAP0038"
                    "the pattern of this arm was read as part of the previous arm's body; write ',' after that body"
            else pure ()
        pure (patterns, guard, body)
    pure (MatchArm spanValue patterns guard body)

parsePatterns :: BranchGrammar -> P [MatchPattern Identifier ()]
parsePatterns grammar = do
    first <- parseMatchPattern grammar
    more <- optionalSymbol ","
    if more then (first :) <$> parsePatterns grammar else pure [first]

{- | One pattern, optionally in its own parentheses.

A bare name is not a pattern: a binding always states its type, as in
@int value@, so a name can never be mistaken for a constant to compare with.
A numeric literal may be preceded by a minus sign, which makes the constant
negative; the range of the constant is checked against the subject's type by
the type checker, so the most negative value of a signed type is a pattern
although its magnitude alone is not a value of that type.
-}
parseMatchPattern :: BranchGrammar -> P (MatchPattern Identifier ())
parseMatchPattern grammar = do
    (build, spanValue) <- withSpan $ do
        parenthesized <- optionalSymbol "("
        build <- parseBarePattern grammar
        if parenthesized then () <$ symbol ")" else pure ()
        pure build
    pure (build spanValue)

parseBarePattern :: BranchGrammar -> P (SourceSpan -> MatchPattern Identifier ())
parseBarePattern grammar = do
    next <- peekToken
    case next of
        Just token
            | isWildcard token -> do
                _ <- takeToken
                pure (\spanValue -> MatchWildcardPattern spanValue ())
            | tokenKind token == KeywordToken && tokenText token == "null" -> do
                _ <- takeToken
                pure (\spanValue -> MatchNullPattern spanValue ())
            | tokenKind token == SymbolToken && tokenText token == "." -> do
                _ <- takeToken
                name <- identifierToken
                pure (\spanValue -> MatchCasePattern spanValue (Identifier (tokenText name)) ())
            | isLiteralStart token -> do
                (literal, _) <- grammarLiteral grammar
                pure (\spanValue -> MatchLiteralPattern spanValue literal ())
            -- A minus sign belongs to the numeric literal that follows it.
            -- It is part of the constant, not an operator: no other
            -- expression is a pattern.
            | tokenKind token == SymbolToken && tokenText token == "-" -> do
                _ <- takeToken
                numeric <- peekToken
                case numeric of
                    Just following | tokenKind following `elem` [IntegerToken, FloatingToken] -> do
                        (literal, _) <- grammarLiteral grammar
                        pure (\spanValue -> MatchLiteralPattern spanValue (negated literal) ())
                    _ -> failCurrent "TAP0036" "a '-' in a match pattern must be followed by a numeric literal"
        _ -> do
            typed <- matchesAhead (grammarType grammar >> identifierToken)
            if not typed
                then
                    failCurrent
                        "TAP0036"
                        "expected a match pattern: a literal, '_', 'null', '.Case', or a type followed by a name or '_'"
                else do
                    syntax <- grammarType grammar
                    name <- identifierToken
                    let binding = if isWildcard name then Nothing else Just (Identifier (tokenText name))
                    pure (\spanValue -> MatchTypePattern spanValue syntax binding ())
    where
        negated literal = case literal of
            IntegerLiteral value -> IntegerLiteral (negate value)
            FloatingLiteral spelling -> FloatingLiteral ('-' : spelling)
            other -> other
        isWildcard token = tokenKind token == IdentifierToken && tokenText token == "_"
        isLiteralStart token =
            tokenKind token `elem` [IntegerToken, FloatingToken, CharacterToken, StringToken]
                || (tokenKind token == KeywordToken && tokenText token `elem` ["true", "false"])

identifierToken :: P Token
identifierToken = satisfy ((== IdentifierToken) . tokenKind) "identifier"

{- | @guard (condition) else { ... }@.

The block is an ordinary statement block. That it must leave the enclosing
scope is a rule about control flow, which the type checker enforces.
-}
parseGuardStatement :: BranchGrammar -> P (Statement Identifier ())
parseGuardStatement grammar = do
    ((condition, block), spanValue) <- withSpan $ do
        _ <- keyword "guard"
        _ <- symbol "("
        condition <- parseCondition grammar "a guard"
        _ <- symbol ")"
        hasElse <- peekText "else"
        if hasElse
            then pure ()
            else failCurrent "TAP0037" "guard requires an else block"
        _ <- keyword "else"
        block <- grammarStatementBlock grammar
        pure (condition, block)
    pure (GuardStatement spanValue condition block)
