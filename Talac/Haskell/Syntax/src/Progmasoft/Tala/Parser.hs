-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | The syntax parser turns one lexed source unit into a positioned parsed AST.

It owns grammar and precedence, but not name binding or type decisions. Parsing
stops at the first structural error so later phases never receive a guessed or
partially recovered declaration tree.
-}
module Progmasoft.Tala.Parser (TokenKind (..), Token (..), ParserInput (..), Parser (..), defaultParser, runParser) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.CharacterLiteral
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.FloatingLiteral
import Progmasoft.Tala.NumericLiteral
import Progmasoft.Tala.Parser.Cursor
import Progmasoft.Tala.Parser.Match
import Progmasoft.Tala.Parser.Token

-- | Tokens and diagnostic source identity for one physical input file.
data ParserInput = ParserInput
    { parserSourceFile :: FilePath
    -- ^ Path reported on syntax diagnostics.
    , parserTokens :: [Token]
    -- ^ Lexer tokens, including the end-of-file token.
    }
    deriving stock (Eq, Ord, Read, Show)

-- | A parser implementation that returns a complete AST or diagnostics.
newtype Parser = Parser {parseTokens :: ParserInput -> Either [Diagnostic] ParsedAST}

-- | Run the supplied parser over one lexed file.
runParser :: Parser -> ParserInput -> Either [Diagnostic] ParsedAST
runParser = parseTokens

-- | The repository grammar parser for the currently supported declaration set.
defaultParser :: Parser
defaultParser = Parser parseTala

parseTala :: ParserInput -> Either [Diagnostic] ParsedAST
parseTala input = case runP (parseModule <* endOfInput) (parserTokens input) of
    Left problem -> Left [problem]
    Right (tree, []) -> Right (ParsedAST tree)
    Right (_, token : _) -> Left [problemAt token "TAP0001" ("unexpected token " ++ show (tokenText token))]
    where
        parseModule = do
            namespace <- optionalParser parseNamespace
            SyntaxTree namespace <$> manyUntilEof parseDeclaration

parseNamespace :: P QualifiedName
parseNamespace = do
    _ <- keyword "namespace"
    (first, _) <- identifier
    remaining <- moreParts
    _ <- symbol ";"
    pure (QualifiedName (first : remaining))
    where
        moreParts = do
            dot <- optionalSymbol "."
            if dot then do (part, _) <- identifier; (part :) <$> moreParts else pure []

manyUntilEof :: P a -> P [a]
manyUntilEof parser = do
    next <- peekToken
    case next of
        Nothing -> pure []
        Just token | tokenKind token == EndOfFileToken -> pure []
        _ -> (:) <$> parser <*> manyUntilEof parser

parseDeclaration :: P (Declaration Identifier ())
parseDeclaration = do
    isTemplate <- peekText "template"
    isEnum <- peekText "enum"
    if isTemplate
        then parseTemplateDeclaration
        else if isEnum then parseEnumDeclaration else parseOrdinaryTypeDeclaration

{- | Parse a classic enum: @enum Name { A, B = 2, C }@, with an optional
underlying type written as @enum Name = byte { ... }@. A comma separates the
members and may follow the last one. The value of a member is read as an
integer literal with an optional minus sign; other constant expressions are
not implemented yet.
-}
parseEnumDeclaration :: P (Declaration Identifier ())
parseEnumDeclaration = do
    start <- keyword "enum"
    (name, _) <- identifier
    hasUnderlying <- optionalSymbol "="
    underlying <- if hasUnderlying then Just <$> parseTypeSyntax else pure Nothing
    _ <- symbol "{"
    cases <- parseCases
    close <- symbol "}"
    pure (EnumDeclaration (mergeSpan (tokenSpan start) (tokenSpan close)) name () underlying cases)
    where
        parseCases = do
            done <- peekText "}"
            if done
                then pure []
                else do
                    (caseName, caseSpan) <- identifier
                    hasValue <- optionalSymbol "="
                    -- A value is an expression without assignment; which
                    -- expressions are constant is the type checker's rule.
                    value <- if hasValue then Just <$> parseConditional else pure Nothing
                    comma <- optionalSymbol ","
                    remaining <- if comma then parseCases else pure []
                    pure (EnumCase caseSpan caseName value : remaining)

parseOrdinaryTypeDeclaration :: P (Declaration Identifier ())
parseOrdinaryTypeDeclaration = do
    _ <- parseAccess
    start <- keyword "class"
    (name, _) <- identifier
    _ <- symbol "{"
    members <- manyUntil "}" parseMember
    close <- symbol "}"
    pure (TypeDeclaration (mergeSpan (tokenSpan start) (tokenSpan close)) name () members)

{- | Parse a template declaration while preserving ordered, typed parameters.
Later phases distinguish type and value arguments, so the prefix cannot be
discarded as decoration after recognizing the class name.
-}
parseTemplateDeclaration :: P (Declaration Identifier ())
parseTemplateDeclaration = do
    start <- keyword "template"
    _ <- symbol "<"
    empty <- peekText ">"
    if empty
        then failCurrent "TAP0019" "a template parameter list cannot be empty"
        else pure ()
    parameters <- separatedUntil ">" "," parseTemplateParameter
    _ <- symbol ">"
    _ <- parseAccess
    _ <- keyword "class"
    (name, _) <- identifier
    _ <- symbol "{"
    members <- manyUntil "}" parseMember
    close <- symbol "}"
    pure
        ( TemplateTypeDeclaration
            (mergeSpan (tokenSpan start) (tokenSpan close))
            name
            ()
            parameters
            members
        )

parseTemplateParameter :: P (TemplateParameter Identifier ())
parseTemplateParameter = do
    (parameter, spanValue) <- withSpan parseTemplateParameterBody
    pure parameter {templateParameterSpan = spanValue}

parseTemplateParameterBody :: P (TemplateParameter Identifier ())
parseTemplateParameterBody = do
    nested <- peekText "template"
    if nested then parseTemplateTemplateParameter else parseDirectTemplateParameter

parseDirectTemplateParameter :: P (TemplateParameter Identifier ())
parseDirectTemplateParameter = do
    typeParameter <- peekText "typename"
    if typeParameter
        then do
            _ <- keyword "typename"
            packed <- optionalSymbol "..."
            (name, spanValue) <- identifier
            defaultValue <- optionalTemplateTypeDefault
            pure (TemplateParameter spanValue name () TemplateTypeParameter packed defaultValue)
        else do
            parameterType <- parseTypeSyntax
            packed <- optionalSymbol "..."
            (name, spanValue) <- identifier
            defaultValue <- optionalTemplateValueDefault
            pure
                ( TemplateParameter
                    spanValue
                    name
                    ()
                    (TemplateValueParameterKind parameterType)
                    packed
                    defaultValue
                )

parseTemplateTemplateParameter :: P (TemplateParameter Identifier ())
parseTemplateTemplateParameter = do
    _ <- keyword "template"
    _ <- symbol "<"
    empty <- peekText ">"
    if empty
        then failCurrent "TAP0020" "a template-template parameter signature cannot be empty"
        else pure ()
    shapes <- separatedUntil ">" "," parseTemplateParameterShape
    _ <- symbol ">"
    _ <- keyword "class"
    packed <- optionalSymbol "..."
    (name, spanValue) <- identifier
    defaultValue <- optionalTemplateTypeDefault
    pure
        ( TemplateParameter
            spanValue
            name
            ()
            (TemplateTemplateParameter shapes)
            packed
            defaultValue
        )

parseTemplateParameterShape :: P TemplateParameterShape
parseTemplateParameterShape = do
    nested <- peekText "template"
    if nested
        then do
            _ <- keyword "template"
            _ <- symbol "<"
            shapes <- separatedUntil ">" "," parseTemplateParameterShape
            _ <- symbol ">"
            _ <- keyword "class"
            packed <- optionalSymbol "..."
            pure (TemplateParameterShape (TemplateTemplateParameterShape shapes) packed)
        else do
            isType <- peekText "typename"
            if isType
                then do
                    _ <- keyword "typename"
                    packed <- optionalSymbol "..."
                    pure (TemplateParameterShape TemplateTypeParameterShape packed)
                else do
                    valueType <- parseTypeSyntax
                    packed <- optionalSymbol "..."
                    pure (TemplateParameterShape (TemplateValueParameterShape valueType) packed)

optionalTemplateTypeDefault :: P (Maybe TemplateDefault)
optionalTemplateTypeDefault = do
    equals <- optionalSymbol "="
    if equals then Just . TemplateTypeDefault <$> parseTypeSyntax else pure Nothing

optionalTemplateValueDefault :: P (Maybe TemplateDefault)
optionalTemplateValueDefault = do
    equals <- optionalSymbol "="
    if equals
        then Just . TemplateValueDefault <$> (parseAdditive >>= requireTemplateValue)
        else pure Nothing

parseMember :: P (Declaration Identifier ())
parseMember = do
    (member, spanValue) <- withSpan parseMemberBody
    pure member {declarationSpan = spanValue}

parseMemberBody :: P (Declaration Identifier ())
parseMemberBody = do
    access <- parseAccess
    isStatic <- maybe False (const True) <$> optionalParser (keyword "static")
    returnType <- parseTypeSyntax
    (name, nameSpan) <- identifier
    _ <- symbol "("
    parameters <- separated "," parseParameter
    _ <- symbol ")"
    -- A semicolon-free expression is a function result, not an optionally
    -- terminated statement. Only a value-returning function's outer body may
    -- therefore admit that form; nested control-flow blocks may not.
    body <- parseBlock (returnType /= ExplicitType (Identifier "void"))
    pure
        (FunctionDeclaration (mergeSpan nameSpan (blockSpan body nameSpan)) name () returnType parameters body isStatic access)

parseAccess :: P Access
parseAccess = do
    token <- optionalParser (keyword "public" <|?> keyword "internal" <|?> keyword "private" <|?> keyword "protected")
    pure $ case fmap tokenText token of
        Just "public" -> PublicAccess
        Just "internal" -> InternalAccess
        Just "private" -> PrivateAccess
        Just "protected" -> ProtectedAccess
        _ -> DefaultAccess

manyUntil :: String -> P a -> P [a]
manyUntil closing parser = do
    done <- peekText closing
    eof <- peekKind EndOfFileToken
    if done
        then pure []
        else if eof then failCurrent "TAP0002" "unterminated declaration" else (:) <$> parser <*> manyUntil closing parser

parseParameter :: P (Parameter Identifier ())
parseParameter = do
    _ <- optionalParameterLabel
    parameterType <- parseTypeSyntax
    (name, spanValue) <- identifier
    pure (Parameter spanValue name () parameterType)

-- External parameter labels are independent from the implementation name. An
-- underscore suppresses a label, while `label:` gives one explicitly. The AST
-- intentionally stores only the implementation name until call-site labels
-- become part of name resolution rather than pretending both names are equal.
optionalParameterLabel :: P (Maybe Token)
optionalParameterLabel = do
    tokens <- peekTokens 2
    case tokens of
        first : _
            | tokenKind first == IdentifierToken
            , tokenText first == "_" ->
                Just <$> takeToken
        first : colon : _
            | tokenKind first == IdentifierToken
            , tokenKind colon == SymbolToken
            , tokenText colon == ":" -> do
                label <- takeToken
                _ <- takeToken
                pure (Just label)
        _ -> pure Nothing

parseTypeSyntax :: P TypeSyntax
parseTypeSyntax = parseCallableTypeSyntax <|?> parseArrayTypeSyntax <|?> parseNamedTypeSyntax

-- Function types use the same arrow as callable literals, but are unambiguous
-- in a type position because their left hand side is a parenthesized type list.
parseCallableTypeSyntax :: P TypeSyntax
parseCallableTypeSyntax = do
    _ <- symbol "("
    empty <- peekText ")"
    parameters <- if empty then pure [] else separatedUntil ")" "," parseTypeSyntax
    _ <- symbol ")"
    _ <- symbol "->"
    CallableTypeSyntax parameters <$> parseTypeSyntax

-- Bracket spelling is surface sugar. `[T]` and `[K to V]` lower to the public
-- System collection types in the type checker. The compact `[]T` built-in form
-- stays distinct because its runtime representation is not System.Array.
parseArrayTypeSyntax :: P TypeSyntax
parseArrayTypeSyntax = do
    _ <- symbol "["
    builtin <- optionalSymbol "]"
    if builtin
        then BuiltinArrayTypeSyntax <$> parseTypeSyntax
        else do
            first <- parseTypeSyntax
            separator <- peekToken
            case separator of
                Just token | tokenText token == "to" && tokenKind token `elem` [IdentifierToken, KeywordToken] -> do
                    _ <- contextualWord "to"
                    value <- parseTypeSyntax
                    _ <- symbol "]"
                    pure (DictionaryTypeSyntax first value)
                Just token
                    | tokenKind token == SymbolToken && tokenText token == ";" ->
                        do
                            _ <- takeToken
                            value <- parseExpression >>= requireTemplateValue
                            _ <- symbol "]"
                            pure (FixedArrayTypeSyntax first value)
                _ -> do
                    _ <- symbol "]"
                    pure (ArrayTypeSyntax first)

parseNamedTypeSyntax :: P TypeSyntax
parseNamedTypeSyntax = do
    token <- satisfy (\candidate -> tokenKind candidate `elem` [IdentifierToken, KeywordToken]) "type"
    case tokenText token of
        "unit" -> failAt (tokenSpan token) "TAP0013" "Tala has no source-language unit type; use void for a no-result function"
        "auto" -> pure AutoType
        value -> do
            remaining <- qualifiedTypeParts
            arguments <- optionalTypeArguments
            let parts = Identifier value : remaining
            pure $ case (parts, arguments) of
                ([name], []) -> ExplicitType name
                _ -> QualifiedTypeSyntax (QualifiedName parts) arguments

qualifiedTypeParts :: P [Identifier]
qualifiedTypeParts = do
    dot <- optionalSymbol "."
    if dot
        then do
            (part, _) <- identifier
            (part :) <$> qualifiedTypeParts
        else pure []

optionalTypeArguments :: P [TemplateArgumentSyntax]
optionalTypeArguments = do
    open <- optionalSymbol "<"
    if not open
        then pure []
        else do
            empty <- peekText ">"
            if empty
                then failCurrent "TAP0016" "a generic type argument list cannot be empty"
                else do
                    arguments <- separatedUntil ">" "," parseTemplateArgumentSyntax
                    _ <- symbol ">"
                    pure arguments

-- A leading literal or unary operator makes a generic argument unambiguously
-- a value.  A bare identifier remains a type until declaration-aware template
-- lookup exists; fixed-array sugar has an explicit semicolon and therefore
-- supports named values without that ambiguity today.
parseTemplateArgumentSyntax :: P TemplateArgumentSyntax
parseTemplateArgumentSyntax = do
    next <- peekToken
    case next of
        Just token
            | tokenKind token `elem` [IntegerToken, CharacterToken]
                || (tokenKind token == KeywordToken && tokenText token `elem` ["true", "false", "not"])
                || (tokenKind token == SymbolToken && tokenText token `elem` ["+", "-"]) ->
                -- The outer '>' terminates this argument and is also a binary
                -- comparison token. Parsing the unparenthesized prefix only
                -- through additive precedence prevents the delimiter from
                -- being consumed as an operator. Comparisons remain available
                -- when explicitly parenthesized, for example Flag<(1 > 0)>.
                TemplateValueArgumentSyntax <$> (parseAdditive >>= requireTemplateValue)
        _ -> TemplateTypeSyntax <$> parseTypeSyntax

requireTemplateValue :: Expression Identifier () -> P TemplateValueSyntax
requireTemplateValue expression = case expression of
    NameExpression spanValue name _ -> pure (TemplateNameSyntax spanValue (QualifiedName [name]))
    MemberAccessExpression spanValue _ _ _ -> unsupported spanValue
    MethodReferenceExpression spanValue _ _ _ -> unsupported spanValue
    LiteralExpression spanValue literal _ -> case literal of
        IntegerLiteral value -> pure (TemplateIntegerSyntax spanValue value)
        CharacterLiteral value -> pure (TemplateCharacterSyntax spanValue value)
        BooleanLiteral value -> pure (TemplateBooleanSyntax spanValue value)
        _ -> unsupported spanValue
    UnaryExpression spanValue operator value _ ->
        TemplateUnarySyntax spanValue operator <$> requireTemplateValue value
    BinaryExpression spanValue operator left right _ ->
        TemplateBinarySyntax spanValue operator <$> requireTemplateValue left <*> requireTemplateValue right
    CallExpression spanValue _ _ _ -> unsupported spanValue
    IsPatternExpression spanValue _ _ _ -> unsupported spanValue
    ConditionalExpression spanValue _ _ _ _ -> unsupported spanValue
    CoalesceExpression spanValue _ _ _ -> unsupported spanValue
    AssignmentExpression spanValue _ _ _ _ -> unsupported spanValue
    IncrementExpression spanValue _ _ _ -> unsupported spanValue
    LoopExpression spanValue _ _ -> unsupported spanValue
    BlockExpression spanValue _ _ -> unsupported spanValue
    MatchExpression spanValue _ _ _ -> unsupported spanValue
    CallableExpression spanValue _ _ _ _ _ -> unsupported spanValue
    where
        unsupported spanValue =
            failAt spanValue "TAP0018" "template value arguments must be compile-time scalar expressions"

{- | What the last item of a block may be.

Every block may end with a statement. A callable body may also end with an
expression that has no semicolon, which is its result. A value block, the
block of an @if@ expression or of a @match@ arm, is one whose last item is
its value: there an @if@ with an @else@ and a @match@ in last position are
expressions as well, as the grammar's @final-expression@ allows.
-}
data BlockMode = StatementBlock | CallableBlock | ValueBlock
    deriving stock (Eq)

parseBlock :: Bool -> P (Block Identifier ())
parseBlock allowFinalExpression = parseBlockIn (if allowFinalExpression then CallableBlock else StatementBlock)

parseBlockIn :: BlockMode -> P (Block Identifier ())
parseBlockIn mode = do _ <- symbol "{"; statements <- go; _ <- symbol "}"; pure (Block statements)
    where
        go = do
            done <- peekText "}"
            eof <- peekKind EndOfFileToken
            if done
                then pure []
                else
                    if eof
                        then failCurrent "TAP0002" "unterminated block"
                        else (:) <$> parseStatementIn mode <*> go

blockSpan :: Block name annotation -> SourceSpan -> SourceSpan
blockSpan (Block []) fallback = fallback
blockSpan (Block statements) fallback = foldl mergeSpan fallback (map statementSpan statements)

statementSpan :: Statement name annotation -> SourceSpan
statementSpan statement = case statement of
    BindingStatement value _ _ _ _ _ -> value
    AssignmentStatement value _ _ _ -> value
    ReturnStatement value _ -> value
    IfStatement value _ _ _ -> value
    WhileStatement value _ _ -> value
    DoWhileStatement value _ _ -> value
    ForStatement value _ _ _ _ -> value
    ForEachStatement value _ _ _ _ _ _ -> value
    IncrementStatement value _ _ -> value
    CompoundAssignmentStatement value _ _ _ _ -> value
    DiscardStatement value _ -> value
    BreakStatement value _ -> value
    ContinueStatement value -> value
    GuardStatement value _ _ -> value
    BlockStatement value _ -> value
    ExpressionStatement value _ _ -> value

-- The branching forms of "Progmasoft.Tala.Parser.Match" are built from the
-- expression, block, and type grammar of this module.
branchGrammar :: BranchGrammar
branchGrammar = BranchGrammar parseExpression (parseBlockIn ValueBlock) (parseBlock False) parseTypeSyntax parsePatternLiteral

parseStatementIn :: BlockMode -> P (Statement Identifier ())
parseStatementIn mode =
    do
        let allowFinalExpression = mode /= StatementBlock
        tokens <- peekTokens 3
        -- Compound types make a fixed token-count heuristic incorrect. Probe
        -- the complete declaration prefix without consuming it, then commit to
        -- that grammar branch so a later initializer error remains precise.
        case tokens of
            first : _ | tokenKind first == KeywordToken && tokenText first == "return" -> parseReturn
            first : _
                | tokenKind first == KeywordToken && tokenText first == "if" ->
                    if mode == ValueBlock then parseIfInValueBlock else parseIf
            first : _ | tokenKind first == KeywordToken && tokenText first == "while" -> parseWhile
            first : _ | tokenKind first == KeywordToken && tokenText first == "do" -> parseDoWhile
            first : _ | tokenKind first == KeywordToken && tokenText first == "for" -> parseFor
            first : _ | tokenKind first == KeywordToken && tokenText first == "break" -> parseBreak
            first : _ | tokenKind first == KeywordToken && tokenText first == "continue" -> parseContinue
            first : _ | tokenKind first == KeywordToken && tokenText first == "guard" -> parseGuardStatement branchGrammar
            -- No expression starts with a brace, so a brace that starts a
            -- statement opens a nested block.
            first : _ | tokenKind first == SymbolToken && tokenText first == "{" -> do
                (block, spanValue) <- withSpan (parseBlock False)
                pure (BlockStatement spanValue block)
            -- A `match` that starts a statement is the statement form: it
            -- needs no terminator and its arms need not cover every value.
            -- As the last item of a value block it is the value of the block.
            first : _ | tokenKind first == KeywordToken && tokenText first == "match" -> do
                value <- parseMatchExpression branchGrammar
                closesBlock <- peekText "}"
                pure (ExpressionStatement (expressionSpan value) value (not (mode == ValueBlock && closesBlock)))
            _ | startsIncrement tokens -> parseIncrementStatement
            _ | startsCompoundAssignment tokens -> parseCompoundAssignmentStatement
            _ | startsDiscard tokens -> parseDiscard
            first : _ | tokenKind first == KeywordToken && tokenText first == "final" -> parseBinding
            -- `unit` is forbidden specifically in type position. Commit here
            -- so declaration lookahead cannot hide TAP0013 behind an unrelated
            -- expression diagnostic.
            first : _ | tokenKind first == KeywordToken && tokenText first == "unit" -> parseBinding
            _ -> do
                binding <- matchesAhead (parseTypeSyntax >> identifier)
                if binding then parseBinding else parseAssignmentOrExpression allowFinalExpression

parseReturn :: P (Statement Identifier ())
parseReturn = do
    start <- keyword "return"
    empty <- peekText ";"
    if empty
        then do end <- symbol ";"; pure (ReturnStatement (mergeSpan (tokenSpan start) (tokenSpan end)) Nothing)
        else do
            value <- parseExpression
            end <- symbol ";"
            pure (ReturnStatement (mergeSpan (tokenSpan start) (tokenSpan end)) (Just value))

parseIf :: P (Statement Identifier ())
parseIf = do
    ((condition, trueBlock, falseBlock), spanValue) <- withSpan $ do
        _ <- keyword "if"
        _ <- symbol "("
        condition <- parseCondition branchGrammar "an if"
        _ <- symbol ")"
        trueBlock <- parseBlock False
        falseBlock <- optionalParser $ do
            _ <- keyword "else"
            chained <- peekText "if"
            if chained then Block . (: []) <$> parseIf else parseBlock False
        pure (condition, trueBlock, falseBlock)
    pure (IfStatement spanValue condition trueBlock falseBlock)

{- | An @if@ at the start of an item of a value block.

Whether it is the statement or the expression is known only after it: it is
the value of the block when it is the last item, has an @else@ block, and
one of its blocks ends with a value; the other block then either ends with a
value as well or leaves the block, which the type checker decides. Its blocks are therefore parsed once,
as value blocks, and the statement form is recovered from them when the @if@
turns out to be a statement. Parsing it twice instead would double the work
at every level of nested value blocks.
-}
parseIfInValueBlock :: P (Statement Identifier ())
parseIfInValueBlock = do
    ((condition, first, second, chained), spanValue) <- withSpan $ do
        _ <- keyword "if"
        _ <- symbol "("
        condition <- parseCondition branchGrammar "an if"
        _ <- symbol ")"
        first <- withSpan (parseBlockIn ValueBlock)
        hasElse <- peekText "else"
        if not hasElse
            then pure (condition, first, Nothing, Nothing)
            else do
                _ <- keyword "else"
                chain <- peekText "if"
                if chain
                    then do
                        next <- parseIf
                        pure (condition, first, Nothing, Just next)
                    else do
                        second <- withSpan (parseBlockIn ValueBlock)
                        pure (condition, first, Just second, Nothing)
    closesBlock <- peekText "}"
    case (second, chained) of
        (Just (secondBlock, secondSpan), Nothing)
            | closesBlock && (blockEndsWithValue (fst first) || blockEndsWithValue secondBlock) ->
                pure
                    ( ExpressionStatement
                        spanValue
                        ( ConditionalExpression
                            spanValue
                            condition
                            (BlockExpression (snd first) (fst first) ())
                            (BlockExpression secondSpan secondBlock ())
                            ()
                        )
                        False
                    )
        _ -> do
            whenTrue <- statementBlock (fst first)
            whenFalse <- case (second, chained) of
                (Just (secondBlock, _), _) -> Just <$> statementBlock secondBlock
                (Nothing, Just next) -> pure (Just (Block [next]))
                (Nothing, Nothing) -> pure Nothing
            pure (IfStatement spanValue condition whenTrue whenFalse)

-- | Whether the last item of a block is an expression without a semicolon.
blockEndsWithValue :: Block name annotation -> Bool
blockEndsWithValue (Block statements) = case reverse statements of
    ExpressionStatement _ _ False : _ -> True
    _ -> False

{- | The statement form of a block that was parsed as a value block.

An @if@ or a @match@ in last position was read as the value of the block;
as statements they need no terminator, so they become statements again. Any
other expression in last position is missing its semicolon.
-}
statementBlock :: Block Identifier () -> P (Block Identifier ())
statementBlock (Block statements) = case reverse statements of
    ExpressionStatement spanValue value False : before -> do
        final <- case value of
            MatchExpression {} -> pure (ExpressionStatement spanValue value True)
            ConditionalExpression _ condition (BlockExpression _ first _) (BlockExpression _ second _) _ ->
                IfStatement spanValue condition <$> statementBlock first <*> (Just <$> statementBlock second)
            _ -> failAt (endOf spanValue) "TAP0006" "expected \";\""
        pure (Block (reverse (final : before)))
    _ -> pure (Block statements)
    where
        endOf spanValue = spanValue {sourceStart = sourceEnd spanValue}

-- Loops are retained as structured syntax until the Desugarer. Keeping their
-- delimiters and header clauses explicit lets the type checker validate loop
-- scope before CorePrep assigns basic-block identities.
parseWhile :: P (Statement Identifier ())
parseWhile = do
    ((condition, body), spanValue) <- withSpan $ do
        _ <- keyword "while"
        _ <- symbol "("
        condition <- parseCondition branchGrammar "a while"
        _ <- symbol ")"
        body <- parseBlock False
        pure (condition, body)
    pure (WhileStatement spanValue condition body)

parseDoWhile :: P (Statement Identifier ())
parseDoWhile = do
    ((body, condition), spanValue) <- withSpan $ do
        _ <- keyword "do"
        body <- parseBlock False
        _ <- keyword "while"
        _ <- symbol "("
        condition <- parseExpression
        _ <- symbol ")"
        _ <- symbol ";"
        pure (body, condition)
    pure (DoWhileStatement spanValue body condition)

parseFor :: P (Statement Identifier ())
parseFor = do
    (header, spanValue) <- withSpan $ do
        _ <- keyword "for"
        _ <- symbol "("
        emptyInitializer <- peekText ";"
        if emptyInitializer
            then parseForHeaderWithoutInitializer
            else do
                foreach <- matchesAhead (parseForBinding >> symbol ":")
                if foreach then parseForEachHeader else parseClassicForHeader
    pure $ case header of
        ClassicHeader initializer condition updates body -> ForStatement spanValue initializer condition updates body
        ForEachHeader binding source body ->
            ForEachStatement spanValue (forBindingKind binding) (forBindingType binding) (forBindingName binding) () source body
    where
        parseForHeaderWithoutInitializer = do
            _ <- symbol ";"
            condition <- optionalUntil ";" parseExpression
            _ <- symbol ";"
            updates <- separatedUntil ")" "," parseForAction
            _ <- symbol ")"
            body <- parseBlock False
            pure (ClassicHeader Nothing condition updates body)

        parseForEachHeader = do
            binding <- parseForBinding
            _ <- symbol ":"
            source <- parseExpression
            _ <- symbol ")"
            body <- parseBlock False
            pure (ForEachHeader binding source body)

        parseClassicForHeader = do
            initializer <- parseForInitializer
            _ <- symbol ";"
            condition <- optionalUntil ";" parseExpression
            _ <- symbol ";"
            updates <- separatedUntil ")" "," parseForAction
            _ <- symbol ")"
            body <- parseBlock False
            pure (ClassicHeader initializer condition updates body)

data ForHeader
    = ClassicHeader
        (Maybe (Statement Identifier ()))
        (Maybe (Expression Identifier ()))
        [Statement Identifier ()]
        (Block Identifier ())
    | ForEachHeader ForBinding (Expression Identifier ()) (Block Identifier ())

parseForInitializer :: P (Maybe (Statement Identifier ()))
parseForInitializer = do
    binding <- matchesAhead (optionalParser (keyword "final") >> parseTypeSyntax >> identifier >> symbol "=")
    if binding
        then do
            start <- peekToken
            finalToken <- optionalParser (keyword "final")
            syntax <- parseTypeSyntax
            (name, nameSpan) <- identifier
            _ <- symbol "="
            value <- parseExpression
            let kind = maybe MutableBinding (const ImmutableBinding) finalToken
                spanValue = maybe nameSpan tokenSpan start
            pure (Just (BindingStatement spanValue kind syntax name () value))
        else Just <$> parseForAction

optionalUntil :: String -> P value -> P (Maybe value)
optionalUntil closing parser = do
    done <- peekText closing
    if done then pure Nothing else Just <$> parser

data ForBinding = ForBinding BindingKind TypeSyntax Identifier SourceSpan

forBindingKind :: ForBinding -> BindingKind
forBindingKind (ForBinding kind _ _ _) = kind

forBindingType :: ForBinding -> TypeSyntax
forBindingType (ForBinding _ syntax _ _) = syntax

forBindingName :: ForBinding -> Identifier
forBindingName (ForBinding _ _ name _) = name

parseForBinding :: P ForBinding
parseForBinding = do
    finalToken <- optionalParser (keyword "final")
    syntax <- parseTypeSyntax
    (name, nameSpan) <- identifier
    pure (ForBinding (maybe MutableBinding (const ImmutableBinding) finalToken) syntax name nameSpan)

-- Assignment headers are represented with the same statement node used in a
-- body. Prefix and postfix `++` have the same effect as a statement; their
-- value-producing forms are expressions. The language has no decrement
-- operator: `--` always starts a comment.
parseForAction :: P (Statement Identifier ())
parseForAction = do
    tokens <- peekTokens 2
    case tokens of
        first : second : _
            | isIncrementToken first && tokenKind second == IdentifierToken -> parseIncrement True
        first : second : _
            | tokenKind first == IdentifierToken && isIncrementToken second -> parseIncrement False
        _ | startsCompoundAssignment tokens -> parseCompoundAssignment
        _ -> do
            value <- parseConditional
            assignment <- optionalSymbol "="
            if assignment
                then case value of
                    NameExpression start name _ -> AssignmentStatement start name () <$> parseExpression
                    _ -> failAt (expressionSpan value) "TAP0003" "assignment target must be a name"
                else pure (ExpressionStatement (expressionSpan value) value True)

startsIncrement :: [Token] -> Bool
startsIncrement tokens = case tokens of
    first : second : _ ->
        (isIncrementToken first && tokenKind second == IdentifierToken)
            || (tokenKind first == IdentifierToken && isIncrementToken second)
    _ -> False

parseIncrementStatement :: P (Statement Identifier ())
parseIncrementStatement = do
    increment <- parseForAction
    end <- symbol ";"
    pure $ case increment of
        IncrementStatement spanValue name annotation ->
            IncrementStatement (mergeSpan spanValue (tokenSpan end)) name annotation
        _ -> increment

parseIncrement :: Bool -> P (Statement Identifier ())
parseIncrement prefix = do
    tokens <- peekTokens 2
    case (prefix, tokens) of
        (True, first : second : _)
            | isIncrementToken first && tokenKind second == IdentifierToken -> do
                _ <- symbol "++"
                (name, spanValue) <- identifier
                pure (IncrementStatement (mergeSpan (tokenSpan first) spanValue) name ())
        (False, first : second : _)
            | tokenKind first == IdentifierToken && isIncrementToken second -> do
                (name, spanValue) <- identifier
                finalOperator <- symbol "++"
                pure (IncrementStatement (mergeSpan spanValue (tokenSpan finalOperator)) name ())
        _ -> failCurrent "TAP0028" incrementTargetMessage

-- Every compound operator stores the result of its binary operator back into
-- the target. Comparison and logical operators have no compound spelling.
compoundAssignmentOperators :: [(String, BinaryOperator)]
compoundAssignmentOperators =
    [ ("+=", Add)
    , ("-=", Subtract)
    , ("*=", Multiply)
    , ("/=", Divide)
    , ("//=", FloorDivide)
    , ("%=", Remainder)
    , ("**=", Power)
    , ("<<=", ShiftLeft)
    , (">>=", ShiftRight)
    , ("&=", BitwiseAnd)
    , ("^=", BitwiseXor)
    , ("|=", BitwiseOr)
    ]

compoundAssignmentOperator :: Token -> Maybe BinaryOperator
compoundAssignmentOperator token
    | tokenKind token == SymbolToken = lookup (tokenText token) compoundAssignmentOperators
    | otherwise = Nothing

startsCompoundAssignment :: [Token] -> Bool
startsCompoundAssignment tokens = case tokens of
    first : second : _ ->
        tokenKind first == IdentifierToken && compoundAssignmentOperator second /= Nothing
    _ -> False

-- The header form has no terminator; a `for` update list separates its
-- actions with commas and closes them with the parenthesis.
parseCompoundAssignment :: P (Statement Identifier ())
parseCompoundAssignment = do
    (name, nameSpan) <- identifier
    operatorTokenValue <- takeToken
    case compoundAssignmentOperator operatorTokenValue of
        Nothing ->
            failAt (tokenSpan operatorTokenValue) "TAP0006" "expected a compound assignment operator"
        Just operator -> do
            value <- parseExpression
            pure (CompoundAssignmentStatement (mergeSpan nameSpan (expressionSpan value)) operator name () value)

parseCompoundAssignmentStatement :: P (Statement Identifier ())
parseCompoundAssignmentStatement = do
    assignment <- parseCompoundAssignment
    end <- symbol ";"
    pure $ case assignment of
        CompoundAssignmentStatement spanValue operator name annotation value ->
            CompoundAssignmentStatement (mergeSpan spanValue (tokenSpan end)) operator name annotation value
        _ -> assignment

-- `_` never names a binding, so `_ =` can be recognized from two tokens and
-- cannot be confused with an assignment to a declared name.
startsDiscard :: [Token] -> Bool
startsDiscard tokens = case tokens of
    first : second : _ ->
        tokenKind first == IdentifierToken
            && tokenText first == "_"
            && tokenKind second == SymbolToken
            && tokenText second == "="
    _ -> False

parseDiscard :: P (Statement Identifier ())
parseDiscard = do
    start <- takeToken
    _ <- symbol "="
    value <- parseExpression
    end <- symbol ";"
    pure (DiscardStatement (mergeSpan (tokenSpan start) (tokenSpan end)) value)

parseBreak :: P (Statement Identifier ())
parseBreak = do
    start <- keyword "break"
    hasValue <- not <$> peekText ";"
    value <- if hasValue then Just <$> parseExpression else pure Nothing
    end <- symbol ";"
    pure (BreakStatement (mergeSpan (tokenSpan start) (tokenSpan end)) value)

parseContinue :: P (Statement Identifier ())
parseContinue = do
    start <- keyword "continue"
    end <- symbol ";"
    pure (ContinueStatement (mergeSpan (tokenSpan start) (tokenSpan end)))

parseBinding :: P (Statement Identifier ())
parseBinding = do
    start <- peekToken
    finalToken <- optionalParser (keyword "final")
    bindingType <- parseTypeSyntax
    (name, nameSpan) <- identifier
    _ <- symbol "="
    value <- parseExpression
    end <- symbol ";"
    let startSpan = maybe nameSpan tokenSpan start
        kind = maybe MutableBinding (const ImmutableBinding) finalToken
    pure (BindingStatement (mergeSpan startSpan (tokenSpan end)) kind bindingType name () value)

parseAssignmentOrExpression :: Bool -> P (Statement Identifier ())
parseAssignmentOrExpression allowFinalExpression = do
    -- The statement's own target is parsed below the assignment level so a
    -- top-level `target = value;` keeps its statement node; the value on the
    -- right may itself be an assignment expression.
    expression <- parseConditional
    assignment <- optionalSymbol "="
    if assignment
        then case expression of
            NameExpression start name _ -> do
                value <- parseExpression
                end <- symbol ";"
                pure (AssignmentStatement (mergeSpan start (tokenSpan end)) name () value)
            _ -> failAt (expressionSpan expression) "TAP0003" "assignment target must be a name"
        else do
            -- A named target was dispatched before this parser ran, so a
            -- compound operator here follows a non-storage expression.
            next <- peekToken
            case next of
                Just token
                    | compoundAssignmentOperator token /= Nothing ->
                        failAt (expressionSpan expression) "TAP0003" "assignment target must be a name"
                    | tokenKind token == SymbolToken && tokenText token == "??=" ->
                        failAt
                            (tokenSpan token)
                            "TAP0031"
                            "null-coalescing assignment requires nullable types, which are not implemented"
                _ -> pure ()
            terminated <- peekText ";"
            if terminated
                then do
                    end <- symbol ";"
                    pure (ExpressionStatement (mergeSpan (expressionSpan expression) (tokenSpan end)) expression True)
                else do
                    closesBody <- peekText "}"
                    if allowFinalExpression && closesBody
                        then pure (ExpressionStatement (expressionSpan expression) expression False)
                        else do
                            _ <- symbol ";"
                            pure (ExpressionStatement (expressionSpan expression) expression True)

parseExpression :: P (Expression Identifier ())
parseExpression = parseAssignment

-- Assignment binds more weakly than every other operator and is
-- right-associative: `a = b = 10` groups as `a = (b = 10)` and `a = b += 2` as
-- `a = (b += 2)`. The target is a single name, so two tokens decide whether an
-- expression is an assignment. `_ = value` is the discard statement and is
-- never an expression.
parseAssignment :: P (Expression Identifier ())
parseAssignment = do
    tokens <- peekTokens 2
    case tokens of
        first : second : _
            | startsDiscard tokens ->
                failAt
                    (mergeSpan (tokenSpan first) (tokenSpan second))
                    "TAP0032"
                    "discard is a statement and cannot be used as a value"
            | tokenKind first == IdentifierToken && isSimpleAssignment second -> do
                (name, nameSpan) <- identifier
                _ <- takeToken
                value <- parseAssignment
                pure (AssignmentExpression (mergeSpan nameSpan (expressionSpan value)) Nothing name value ())
            | tokenKind first == IdentifierToken
            , Just operator <- compoundAssignmentOperator second -> do
                (name, nameSpan) <- identifier
                _ <- takeToken
                value <- parseAssignment
                pure (AssignmentExpression (mergeSpan nameSpan (expressionSpan value)) (Just operator) name value ())
        _ -> parseConditional
    where
        isSimpleAssignment token = tokenKind token == SymbolToken && tokenText token == "="

-- The conditional forms bind more weakly than every binary operator and are
-- right-associative: `a ? b : c ? d : e` groups as `a ? b : (c ? d : e)` and
-- `a ?: b ?: c` as `a ?: (b ?: c)`.
parseConditional :: P (Expression Identifier ())
parseConditional = do
    condition <- parseLogicalOr
    next <- peekToken
    case next of
        Just token | tokenKind token == SymbolToken && tokenText token == "?" -> do
            _ <- takeToken
            omittedMiddle <- peekText ":"
            if omittedMiddle
                then do
                    -- `left ? : fallback` is the same omitted-middle form
                    -- as the adjacent `?:` spelling.
                    _ <- symbol ":"
                    coalesce condition
                else do
                    first <- parseConditional
                    separator <- peekText ":"
                    if separator
                        then do
                            _ <- symbol ":"
                            second <- parseConditional
                            pure
                                ( ConditionalExpression
                                    (mergeSpan (expressionSpan condition) (expressionSpan second))
                                    condition
                                    first
                                    second
                                    ()
                                )
                        else failCurrent "TAP0029" "conditional expression requires ':' and a second result"
        Just token | tokenKind token == SymbolToken && tokenText token == "?:" -> do
            _ <- takeToken
            coalesce condition
        Just token
            | tokenKind token == SymbolToken && tokenText token == "??" ->
                failAt (tokenSpan token) "TAP0030" "null coalescing requires nullable types, which are not implemented"
        _ -> pure condition
    where
        coalesce left = do
            fallback <- parseConditional
            pure (CoalesceExpression (mergeSpan (expressionSpan left) (expressionSpan fallback)) left fallback ())

parseLogicalOr
    , parseLogicalAnd
    , parseEquality
    , parseComparison
    , parseBitwiseOr
    , parseBitwiseXor
    , parseBitwiseAnd
    , parseShift
    , parseAdditive
    , parseMultiplicative ::
        P (Expression Identifier ())
parseLogicalOr = chainLeft parseLogicalAnd [("||", LogicalOr)]
parseLogicalAnd = chainLeft parseEquality [("&&", LogicalAnd)]
parseEquality = nonAssociative "equality" parseComparison [("==", Equal), ("\\=", NotEqual)]
parseComparison = do
    left <-
        nonAssociative
            "relational"
            parseBitwiseOr
            [("<", LessThan), ("<=", LessEqual), (">", GreaterThan), (">=", GreaterEqual)]
    introducesPattern <- peekText "is"
    if not introducesPattern
        then pure left
        else do
            _ <- keyword "is"
            patternValue <- parsePattern
            pure (IsPatternExpression (mergeSpan (expressionSpan left) (patternSpan patternValue)) left patternValue ())
parseBitwiseOr = chainLeft parseBitwiseXor [("|", BitwiseOr)]
parseBitwiseXor = chainLeft parseBitwiseAnd [("^", BitwiseXor)]
parseBitwiseAnd = chainLeft parseShift [("&", BitwiseAnd)]
-- Shift spellings deliberately remain two lexer tokens. Treating `>>` as one
-- context-free token would consume the adjacent closing delimiters in nested
-- generic types such as `A<B<C>>`. The parser has enough context to combine
-- the pair here without weakening the generic grammar.
parseShift = parseAdditive >>= continue
    where
        continue left = do
            tokens <- peekTokens 2
            case fmap tokenText tokens of
                ["<", "<"] -> combine ShiftLeft left
                [">", ">"] -> combine ShiftRight left
                _ -> pure left
        combine operator left = do
            _ <- takeToken
            _ <- takeToken
            right <- parseAdditive
            continue (BinaryExpression (mergeSpan (expressionSpan left) (expressionSpan right)) operator left right ())
parseAdditive = chainLeft parseMultiplicative [("+", Add), ("-", Subtract)]
parseMultiplicative = chainLeft parseUnary [("*", Multiply), ("/", Divide), ("//", FloorDivide), ("%", Remainder)]

chainLeft :: P (Expression Identifier ()) -> [(String, BinaryOperator)] -> P (Expression Identifier ())
chainLeft operand operators = operand >>= continue
    where
        continue left = do
            next <- peekToken
            case next >>= operatorToken operators of
                Nothing -> pure left
                Just operator -> do
                    _ <- takeToken
                    right <- operand
                    continue (BinaryExpression (mergeSpan (expressionSpan left) (expressionSpan right)) operator left right ())

parseUnary :: P (Expression Identifier ())
parseUnary = do
    next <- peekToken
    case next
        >>= operatorToken [("+", UnaryPlus), ("-", UnaryNegate), ("not", LogicalNot), ("!", BitwiseNot)] of
        Just operator -> do
            start <- takeToken
            value <- parseUnary
            pure (UnaryExpression (mergeSpan (tokenSpan start) (expressionSpan value)) operator value ())
        Nothing -> case next of
            Just token | isIncrementToken token -> parsePrefixIncrement
            _ -> parsePower

isIncrementToken :: Token -> Bool
isIncrementToken token = tokenKind token == SymbolToken && tokenText token == "++"

-- A prefix form modifies a named storage location and yields the new value.
-- Anything else after the operator, such as `++10` or `++(a + b)`, has no
-- storage to modify.
parsePrefixIncrement :: P (Expression Identifier ())
parsePrefixIncrement = do
    operator <- takeToken
    next <- peekToken
    case next of
        Just token | tokenKind token == IdentifierToken -> do
            (name, nameSpan) <- identifier
            pure
                (IncrementExpression (mergeSpan (tokenSpan operator) nameSpan) True name ())
        _ -> failAt (tokenSpan operator) "TAP0028" incrementTargetMessage

incrementTargetMessage :: String
incrementTargetMessage = "increment requires a named storage location"

-- Power binds more strongly than prefix operators and recurses through the
-- prefix layer on its right, making `2 ** 3 ** 2` right-associative while
-- preserving the specified `-2 ** 2 == -(2 ** 2)` grouping.
parsePower :: P (Expression Identifier ())
parsePower = do
    left <- parsePostfix
    present <- optionalSymbol "**"
    if present
        then do
            right <- parseUnary
            pure (BinaryExpression (mergeSpan (expressionSpan left) (expressionSpan right)) Power left right ())
        else pure left

-- Equality and relational groups are non-associative. A parenthesized operand
-- starts a fresh level; a second operator at this level is a syntax error.
nonAssociative :: String -> P (Expression Identifier ()) -> [(String, BinaryOperator)] -> P (Expression Identifier ())
nonAssociative group operand operators = do
    left <- operand
    next <- peekToken
    case next >>= operatorToken operators of
        Nothing -> pure left
        Just operator -> do
            _ <- takeToken
            right <- operand
            following <- peekToken
            case following >>= operatorToken operators of
                Just _ -> failCurrent "TAP0014" (group ++ " operators cannot be chained; use parentheses or an explicit logical conjunction")
                Nothing -> pure (BinaryExpression (mergeSpan (expressionSpan left) (expressionSpan right)) operator left right ())

operatorToken :: [(String, a)] -> Token -> Maybe a
operatorToken operators token
    | tokenKind token `elem` [SymbolToken, KeywordToken] = lookup (tokenText token) operators
    | otherwise = Nothing

parsePostfix :: P (Expression Identifier ())
parsePostfix = parsePrimary >>= calls
    where
        calls callee = do
            next <- peekToken
            case next of
                Just token | tokenText token == "." -> do
                    _ <- symbol "."
                    (member, memberSpan) <- identifier
                    let selected = MemberAccessExpression (mergeSpan (expressionSpan callee) memberSpan) callee member ()
                    calls selected
                -- `::` names a method without calling it.
                Just token | tokenText token == "::" -> do
                    _ <- symbol "::"
                    (member, memberSpan) <- identifier
                    calls (MethodReferenceExpression (mergeSpan (expressionSpan callee) memberSpan) callee member ())
                Just token | tokenText token == "(" -> do
                    _ <- symbol "("
                    arguments <- separated "," parseExpression
                    close <- symbol ")"
                    calls (CallExpression (mergeSpan (expressionSpan callee) (tokenSpan close)) callee arguments ())
                -- A postfix form yields the previous value of a named storage
                -- location. It is not a storage location itself, so nothing
                -- may be selected from, called on, or incremented after it.
                Just token | isIncrementToken token -> case callee of
                    NameExpression nameSpan name _ -> do
                        _ <- takeToken
                        pure (IncrementExpression (mergeSpan nameSpan (tokenSpan token)) False name ())
                    _ -> failAt (expressionSpan callee) "TAP0028" incrementTargetMessage
                _ -> pure callee

parsePrimary :: P (Expression Identifier ())
parsePrimary = do
    next <- peekToken
    case next of
        Just token | tokenKind token == SymbolToken && tokenText token `elem` ["\\", "["] -> parseCallable
        -- `.Member` names a member of the enum that the context expects.
        -- It is a member selection without a receiver; the place of the
        -- receiver holds the unit literal, which no source can write.
        Just token | tokenKind token == SymbolToken && tokenText token == "." -> do
            _ <- takeToken
            (member, memberSpan) <- identifier
            pure
                ( MemberAccessExpression
                    (mergeSpan (tokenSpan token) memberSpan)
                    (LiteralExpression (tokenSpan token) UnitLiteral ())
                    member
                    ()
                )
        -- A loop in operand position is a loop expression: its value is
        -- supplied by `break value;`. The statement parsers are reused, so
        -- both forms have exactly one grammar.
        Just token | tokenKind token == KeywordToken && tokenText token `elem` ["while", "for"] -> do
            loop <- if tokenText token == "while" then parseWhile else parseFor
            pure (LoopExpression (statementSpan loop) loop ())
        -- `if` and `match` in operand position are expressions. At the start
        -- of a statement the statement parsers have already taken them.
        Just token | tokenKind token == KeywordToken && tokenText token == "if" -> parseIfExpression branchGrammar
        Just token | tokenKind token == KeywordToken && tokenText token == "match" -> parseMatchExpression branchGrammar
        Just token | tokenKind token == IntegerToken -> do
            _ <- takeToken
            case parseIntegerSpelling (tokenText token) of
                Right parsed -> pure (LiteralExpression (tokenSpan token) (IntegerLiteral (parsedIntegerValue parsed)) ())
                Left issue -> failAt (tokenSpan token) "TAP0010" (renderIntegerLiteralError issue)
        Just token | tokenKind token == FloatingToken -> do
            _ <- takeToken
            case validateFloatingSpelling (tokenText token) of
                Right normalized -> pure (LiteralExpression (tokenSpan token) (FloatingLiteral normalized) ())
                Left issue -> failAt (tokenSpan token) "TAP0012" (renderFloatingLiteralError issue)
        Just token | tokenKind token == CharacterToken -> do
            _ <- takeToken
            case parseCharacterLiteral (tokenText token) of
                Right value -> pure (LiteralExpression (tokenSpan token) (CharacterLiteral value) ())
                Left issue -> failAt (tokenSpan token) "TAP0011" (renderCharacterLiteralError issue)
        Just token | tokenKind token == StringToken -> do _ <- takeToken; pure (LiteralExpression (tokenSpan token) (StringLiteral (tokenText token)) ())
        Just token | tokenKind token == KeywordToken && tokenText token `elem` ["true", "false"] -> do _ <- takeToken; pure (LiteralExpression (tokenSpan token) (BooleanLiteral (tokenText token == "true")) ())
        Just token | tokenKind token == IdentifierToken -> do _ <- takeToken; pure (NameExpression (tokenSpan token) (Identifier (tokenText token)) ())
        Just token | tokenText token == "(" -> do
            _ <- takeToken
            value <- parseExpression
            _ <- symbol ")"
            pure value
        Just token -> failAt (tokenSpan token) "TAP0004" ("expected expression, found " ++ show (tokenText token))
        Nothing -> failCurrent "TAP0005" "expected expression at end of input"

-- Pattern combinators intentionally live in their own parser. Letting them
-- fall through the ordinary expression precedence table would make `and` and
-- `or` accidental aliases for && and || and would evaluate the subject more
-- than once during lowering.
parsePattern :: P (Pattern Identifier ())
parsePattern = parseOrPattern

parseOrPattern :: P (Pattern Identifier ())
parseOrPattern = parseAndPattern >>= continue
    where
        continue left = do
            present <- peekText "or"
            if not present
                then pure left
                else do
                    _ <- keyword "or"
                    right <- parseAndPattern
                    continue (OrPattern (mergeSpan (patternSpan left) (patternSpan right)) left right ())

parseAndPattern :: P (Pattern Identifier ())
parseAndPattern = parsePrimaryPattern >>= continue
    where
        continue left = do
            present <- peekText "and"
            if not present
                then pure left
                else do
                    _ <- keyword "and"
                    right <- parsePrimaryPattern
                    continue (AndPattern (mergeSpan (patternSpan left) (patternSpan right)) left right ())

parsePrimaryPattern :: P (Pattern Identifier ())
parsePrimaryPattern = do
    next <- peekToken
    case next of
        Just token | tokenText token == "not" -> do
            start <- keyword "not"
            nested <- parsePrimaryPattern
            pure (NotPattern (mergeSpan (tokenSpan start) (patternSpan nested)) nested ())
        Just token | tokenText token `elem` ["<", "<=", ">", ">=", "==", "\\="] -> do
            operatorTokenValue <- takeToken
            (literal, literalSpan) <- parsePatternLiteral
            let operator = case tokenText operatorTokenValue of
                    "<" -> PatternLessThan
                    "<=" -> PatternLessEqual
                    ">" -> PatternGreaterThan
                    ">=" -> PatternGreaterEqual
                    "==" -> PatternEqual
                    _ -> PatternNotEqual
            pure (RelationalPattern (mergeSpan (tokenSpan operatorTokenValue) literalSpan) operator literal ())
        Just token | tokenText token == "_" -> do
            _ <- takeToken
            pure (WildcardPattern (tokenSpan token) ())
        Just token | tokenText token == "null" -> do
            _ <- keyword "null"
            pure (NullPattern (tokenSpan token) ())
        Just token | tokenText token == "(" -> do
            _ <- symbol "("
            nested <- parsePattern
            _ <- symbol ")"
            pure nested
        Just token
            | tokenKind token `elem` [IntegerToken, FloatingToken, CharacterToken, StringToken]
                || tokenText token `elem` ["true", "false"] -> do
                (literal, spanValue) <- parsePatternLiteral
                pure (LiteralPattern spanValue literal ())
        Just _ -> do
            (typeSyntax, spanValue) <- withSpan parseTypeSyntax
            pure (TypePattern spanValue typeSyntax ())
        Nothing -> failCurrent "TAP0021" "expected pattern after is"

parsePatternLiteral :: P (Literal, SourceSpan)
parsePatternLiteral = do
    token <- takeToken
    let spanValue = tokenSpan token
    case tokenKind token of
        IntegerToken -> case parseIntegerSpelling (tokenText token) of
            Right parsed -> pure (IntegerLiteral (parsedIntegerValue parsed), spanValue)
            Left issue -> failAt spanValue "TAP0010" (renderIntegerLiteralError issue)
        FloatingToken -> case validateFloatingSpelling (tokenText token) of
            Right normalized -> pure (FloatingLiteral normalized, spanValue)
            Left issue -> failAt spanValue "TAP0012" (renderFloatingLiteralError issue)
        CharacterToken -> case parseCharacterLiteral (tokenText token) of
            Right value -> pure (CharacterLiteral value, spanValue)
            Left issue -> failAt spanValue "TAP0011" (renderCharacterLiteralError issue)
        StringToken -> pure (StringLiteral (tokenText token), spanValue)
        KeywordToken | tokenText token == "true" -> pure (BooleanLiteral True, spanValue)
        KeywordToken | tokenText token == "false" -> pure (BooleanLiteral False, spanValue)
        _ -> failAt spanValue "TAP0022" "relational and constant patterns require a literal"

-- A capture list belongs to the callable which follows it.  Keeping this at
-- primary-expression precedence allows immediately invoking a literal while
-- preventing binary operators from becoming part of capture initializers.
parseCallable :: P (Expression Identifier ())
parseCallable = do
    ((explicitCaptures, captures, parameters, body), spanValue) <- withSpan $ do
        (explicitCaptures, captures) <- optionalCaptureList
        _ <- symbol "\\"
        parameters <- parseCallableParameters
        _ <- symbol "->"
        body <- parseCallableBody
        pure (explicitCaptures, captures, parameters, body)
    pure (CallableExpression spanValue explicitCaptures captures parameters body ())

optionalCaptureList :: P (Bool, [Capture Identifier ()])
optionalCaptureList = do
    present <- peekText "["
    if not present
        then pure (False, [])
        else do
            _ <- symbol "["
            empty <- peekText "]"
            captures <- if empty then pure [] else separatedUntil "]" "," parseCapture
            _ <- symbol "]"
            pure (True, captures)

parseCapture :: P (Capture Identifier ())
parseCapture = do
    modeToken <- optionalParser (keyword "weak" <|?> keyword "unowned")
    (name, nameSpan) <- identifier
    hasInitializer <- optionalSymbol "="
    initializer <- if hasInitializer then Just <$> parseExpression else pure Nothing
    let mode = case fmap tokenText modeToken of
            Just "weak" -> WeakCapture
            Just "unowned" -> UnownedCapture
            _ -> StrongCapture
        spanValue = maybe nameSpan (mergeSpan nameSpan . expressionSpan) initializer
    pure (Capture spanValue mode name () initializer)

parseCallableParameters :: P [Parameter Identifier ()]
parseCallableParameters = do
    parenthesized <- optionalSymbol "("
    if parenthesized
        then do
            empty <- peekText ")"
            parameters <- if empty then pure [] else separatedUntil ")" "," parseCallableParameter
            _ <- symbol ")"
            pure parameters
        else do
            arrow <- peekText "->"
            if arrow then pure [] else separatedUntil "->" "," parseInferredCallableParameter

parseCallableParameter :: P (Parameter Identifier ())
parseCallableParameter = do
    typed <- matchesAhead (optionalParameterLabel >> parseTypeSyntax >> identifier)
    if typed then parseParameter else parseInferredCallableParameter

parseInferredCallableParameter :: P (Parameter Identifier ())
parseInferredCallableParameter = do
    (name, spanValue) <- identifier
    pure (Parameter spanValue name () AutoType)

parseCallableBody :: P (CallableBody Identifier ())
parseCallableBody = do
    block <- peekText "{"
    if block
        then CallableBlockBody <$> parseBlock True
        else CallableExpressionBody <$> parseExpression

separatedUntil :: String -> String -> P a -> P [a]
separatedUntil closing separator parser = do
    first <- parser
    more <- optionalSymbol separator
    if more
        then (first :) <$> separatedUntil closing separator parser
        else do
            done <- peekText closing
            if done then pure [first] else failCurrent "TAP0009" ("expected " ++ show separator ++ " or " ++ show closing)

expressionSpan :: Expression name annotation -> SourceSpan
expressionSpan expression = case expression of
    NameExpression value _ _ -> value
    LiteralExpression value _ _ -> value
    MemberAccessExpression value _ _ _ -> value
    MethodReferenceExpression value _ _ _ -> value
    CallExpression value _ _ _ -> value
    UnaryExpression value _ _ _ -> value
    BinaryExpression value _ _ _ _ -> value
    IsPatternExpression value _ _ _ -> value
    ConditionalExpression value _ _ _ _ -> value
    CoalesceExpression value _ _ _ -> value
    AssignmentExpression value _ _ _ _ -> value
    IncrementExpression value _ _ _ -> value
    LoopExpression value _ _ -> value
    BlockExpression value _ _ -> value
    MatchExpression value _ _ _ -> value
    CallableExpression value _ _ _ _ _ -> value

patternSpan :: Pattern name annotation -> SourceSpan
patternSpan patternValue = case patternValue of
    WildcardPattern value _ -> value
    NullPattern value _ -> value
    LiteralPattern value _ _ -> value
    TypePattern value _ _ -> value
    RelationalPattern value _ _ _ -> value
    NotPattern value _ _ -> value
    AndPattern value _ _ _ -> value
    OrPattern value _ _ _ -> value

separated :: String -> P a -> P [a]
separated separator parser = do
    done <- peekText ")"
    if done
        then pure []
        else do
            first <- parser
            more <- optionalSymbol separator
            if more then (first :) <$> separated separator parser else pure [first]
identifier :: P (Identifier, SourceSpan)
identifier = do
    token <- satisfy ((== IdentifierToken) . tokenKind) "identifier"; pure (Identifier (tokenText token), tokenSpan token)
mergeSpan :: SourceSpan -> SourceSpan -> SourceSpan
mergeSpan left right = SourceSpan (sourceFile left) (sourceStart left) (sourceEnd right)
