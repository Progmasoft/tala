-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module ParserContractTests (parserContractTests) where

import Data.List (isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser

-- These tests exercise the public source/token boundary rather than testing
-- individual combinators against copies of their own implementation. Diagnostic
-- assertions include the offending source location, not just a Left result.
parserContractTests :: [(String, Bool)]
parserContractTests =
    diagnosticTests
        ++ comparisonTests
        ++ operatorPrecedenceTests
        ++ literalTests
        ++ spanTests
        ++ tokenStreamTests
        ++ typeSyntaxTests
        ++ pipelineTests
        ++ booleanOperandTests

parseSource :: String -> Either [Diagnostic] ParsedAST
parseSource source = do
    tokens <- runLexer defaultLexer (LexerInput "parser-contract.tala" source)
    runParser defaultParser (ParserInput "parser-contract.tala" tokens)

sourceWith :: String -> String
sourceWith body = "class Program { int Value() { " ++ body ++ " } }"

accepted :: String -> Bool
accepted source = case parseSource source of
    Right _ -> True
    Left _ -> False

rejectedAt :: String -> String -> String -> Int -> Int -> Bool
rejectedAt source code message line column = case parseSource source of
    Left [problem] ->
        diagnosticStage problem == ParserStage
            && diagnosticSeverity problem == Error
            && diagnosticCode problem == code
            && message `isInfixOf` diagnosticMessage problem
            && fmap sourceStart (diagnosticSpan problem) == Just (SourcePosition line column)
            && fmap sourceFile (diagnosticSpan problem) == Just "parser-contract.tala"
    _ -> False

-- Keep each failure on a separate line so expected columns are independent of
-- the enclosing class spelling. Consumed optional constructs must retain their
-- own errors: namespace, else, and capture modes are especially important.
diagnosticTests :: [(String, Bool)]
diagnosticTests =
    [ bad "namespace missing name" "namespace ;" "TAP0006" "identifier" 1 11
    , bad "namespace missing terminator" "namespace Demo class C {}" "TAP0006" ";" 1 16
    , bad "namespace missing component" "namespace Demo.;" "TAP0006" "identifier" 1 16
    , bad "namespace keyword is not an identifier" "namespace class;" "TAP0006" "identifier" 1 11
    , bodyBad "return missing value" "return +;" "TAP0004" "expression" 9
    , bodyBad "return missing semicolon" "return 1 }" "TAP0006" ";" 10
    , bodyBad "binding missing initializer" "int value = ;" "TAP0004" "expression" 13
    , bodyBad "binding missing equals" "int value 1;" "TAP0006" "=" 11
    , bodyBad "binding missing semicolon" "int value = 1 }" "TAP0006" ";" 15
    , bodyBad "final binding missing name" "final int = 1;" "TAP0006" "identifier" 11
    , bodyBad "if missing parentheses" "if true {}" "TAP0006" "(" 4
    , bodyBad "if missing condition" "if () {}" "TAP0004" "expression" 5
    , bodyBad "if missing close paren" "if (true {}" "TAP0006" ")" 10
    , bodyBad "if missing block" "if (true) return 1;" "TAP0006" "{" 11
    , bodyBad "else missing block" "if (true) {} else return 1;" "TAP0006" "{" 19
    , bodyBad "else if missing parentheses" "if (true) {} else if true {}" "TAP0006" "(" 22
    , bodyBad "else if missing expression" "if (true) {} else if () {}" "TAP0004" "expression" 23
    , bodyBad "call missing argument" "Call(,);" "TAP0004" "expression" 6
    , bodyBad "call missing close paren" "Call(1;" "TAP0006" ")" 7
    , bodyBad "assignment missing value" "value = ;" "TAP0004" "expression" 9
    , bodyBad "assignment missing semicolon" "value = 1 }" "TAP0006" ";" 11
    , bodyBad "non-name assignment" "Call() = 1;" "TAP0003" "target" 1
    , bodyBad "parenthesized incomplete expression" "return (1 +);" "TAP0004" "expression" 12
    , bodyBad "lambda missing arrow" "auto f = \\(int x) x;" "TAP0006" "->" 19
    , bodyBad "lambda missing typed parameter" "auto f = \\(int) -> 1;" "TAP0006" "identifier" 12
    , bodyBad "capture missing name" "auto f = [weak ]\\ -> 1;" "TAP0006" "identifier" 16
    , bodyBad "capture missing initializer" "auto f = [x = ]\\ -> 1;" "TAP0004" "expression" 15
    , bodyBad "capture missing closing bracket" "auto f = [x;" "TAP0009" "]" 12
    , bodyBad "unit diagnostic survives dispatch" "unit value = 1;" "TAP0013" "unit" 1
    ]
    where
        bad label source code message line column = (label, rejectedAt source code message line column)
        bodyBad label body code message column =
            bad label ("class Program { int Value() {\n" ++ body ++ "\n} }") code message 2 column

comparisonTests :: [(String, Bool)]
comparisonTests =
    [ parses "single less comparison" "return a < b;"
    , parses "single less-equal comparison" "return a <= b;"
    , parses "single greater comparison" "return a > b;"
    , parses "single greater-equal comparison" "return a >= b;"
    , parses "single equality" "return a == b;"
    , parses "single inequality" "return a \\= b;"
    , parses "logical conjunction of comparisons" "return a < b && b < c;"
    , parses "logical disjunction of equalities" "return a == b || b == c;"
    , parses "left parenthesized comparison" "return (a < b) < c;"
    , parses "right parenthesized comparison" "return a < (b < c);"
    , parses "left parenthesized equality" "return (a == b) == c;"
    , parses "right parenthesized equality" "return a == (b == c);"
    , parses "separate precedence groups" "return a < b == c < d;"
    , parses "arithmetic inside comparison" "return a + b < c * d;"
    , parses "negated comparison" "return not (a < b);"
    , chain "less chain" "a < b < c" 7
    , chain "greater chain" "a > b > c" 7
    , chain "mixed relational chain" "a <= b > c" 8
    , chain "reverse mixed relational chain" "a >= b < c" 8
    , chain "equality chain" "a == b == c" 8
    , chain "inequality chain" "a \\= b \\= c" 8
    , chain "mixed equality chain" "a == b \\= c" 8
    , chain "chain inside parentheses" "(a < b < c)" 8
    ]
    where
        parses label body = (label, accepted (sourceWith body))
        chain label expression column =
            ( label
            , rejectedAt
                ("class Program { int Value() {\n" ++ expression ++ "\n} }")
                "TAP0014"
                "cannot be chained"
                2
                column
            )

-- The operator ladder is a language contract.  These cases intentionally mix
-- adjacent precedence groups so a parser change cannot silently flatten the
-- tree while still accepting each token in isolation.
operatorPrecedenceTests :: [(String, Bool)]
operatorPrecedenceTests =
    [ parses "power is right associative" "return 2 ** 3 ** 2;"
    , parses "power binds before unary negation" "return -2 ** 2;"
    , parses "bitwise not is an integer prefix operator" "return !mask;"
    , parses "multiplication binds before addition" "return 1 + 2 * 3;"
    , parses "addition binds before shift" "return 1 + 2 << 3;"
    , parses "shift binds before bitwise and" "return 8 >> 1 & 3;"
    , parses "bitwise and binds before xor" "return 7 & 3 ^ 1;"
    , parses "bitwise xor binds before or" "return 7 ^ 3 | 1;"
    , parses "bitwise or binds before comparison" "return flags | mask == expected;"
    , ("pattern combinators are rejected outside is", not (accepted (sourceWith "return ready and valid or fallback;")))
    , ("exclamation inequality alias is rejected", not (accepted (sourceWith "return left != right;")))
    , ("removed membership operator is rejected", not (accepted (sourceWith "return item in values;")))
    , ("removed not-in operator is rejected", not (accepted (sourceWith "return item not in values;")))
    , ("removed cast operator is rejected", not (accepted (sourceWith "return value as Target;")))
    , ("removed nullable cast operator is rejected", not (accepted (sourceWith "return value as? Target;")))
    , ("removed forced cast operator is rejected", not (accepted (sourceWith "return value as! Target;")))
    ]
    where
        parses label body = (label, accepted (sourceWith body))

-- A string payload that happens to spell punctuation must remain a literal.
-- In particular a closing-brace payload must not terminate a block early.
literalTests :: [(String, Bool)]
literalTests =
    [ ("literal payload remains data: " ++ show payload, literalResult payload)
    | payload <-
        [ "if"
        , "else"
        , "return"
        , "final"
        , "class"
        , "namespace"
        , "static"
        , "not"
        , "+"
        , "-"
        , "*"
        , "=="
        , "{"
        , "}"
        , "("
        , ")"
        , "["
        , "]"
        , ";"
        , ","
        , "->"
        , "true"
        , "false"
        ]
    ]
        ++ [ ("keyword text cannot act as class keyword", not (accepted "\"class\" Program {}"))
           , ("String brace cannot open a class", not (accepted "class Program \"{\" }"))
           , ("String semicolon cannot terminate namespace", not (accepted "namespace Demo \";\" class Program {}"))
           , ("String else cannot introduce branch", not (accepted (sourceWith "if (true) {} \"else\" {}")))
           , ("String operator cannot connect operands", not (accepted (sourceWith "return 1 \"+\" 2;")))
           ]

literalResult :: String -> Bool
literalResult payload = case statements (sourceWith ("return " ++ show payload ++ ";")) of
    Just [ReturnStatement _ (Just (LiteralExpression _ (StringLiteral value) ()))] -> value == payload
    _ -> False

statements :: String -> Maybe [Statement Identifier ()]
statements source = case parseSource source of
    Right (ParsedAST (SyntaxTree _ [TypeDeclaration _ _ _ [FunctionDeclaration _ _ _ _ _ (Block body) _ _ _]])) -> Just body
    _ -> Nothing

spanTests :: [(String, Bool)]
spanTests =
    [ ("empty closure retains source file and closing brace", closureSpan "\\ -> {}")
    , ("explicit empty capture span includes brackets", closureSpan "[]\\ -> {}")
    , ("strong capture span includes opening bracket", closureSpan "[value]\\ -> {}")
    , ("weak capture span includes mode and delimiters", closureSpan "[weak value]\\ -> {}")
    , ("unowned capture span includes mode and delimiters", closureSpan "[unowned value]\\ -> {}")
    , ("expression closure span includes expression", closureSpan "\\x -> x + 1")
    , ("typed closure span includes parameter syntax", closureSpan "\\(int x) -> x")
    , ("empty if span includes closing block delimiter", ifSpan "if (true) {}")
    , ("empty else span includes final delimiter", ifSpan "if (true) {} else {}")
    , ("else-if span includes complete chain", ifSpan "if (true) {} else if (false) {} else {}")
    , ("guard span runs from the keyword to the closing brace", guardSpan "guard (true) else { return 1; }")
    , ("nested block span includes both braces", blockSpan "{ int inner = 1; }")
    , ("empty nested block span includes both braces", blockSpan "{}")
    ,
        ( "match statement span runs from the keyword to the closing brace"
        , matchStatementSpan "match (1) { 1 -> { }, _ -> { } }"
        )
    , ("match statement without arms keeps its span", matchStatementSpan "match (1) { }")
    , ("match expression span excludes the binding around it", matchExpressionSpan "match (1) { 1 -> 2, _ -> 3 }")
    , ("if expression span runs from the keyword to the else block", ifExpressionSpan "if (true) { 1 } else { 2 }")
    , ("value block span includes both braces", valueBlockSpans)
    , ("match arm span starts at its pattern and includes its comma", armSpans)
    , ("match arm without a comma ends at its body", lastArmSpan)
    , ("match pattern span includes its parentheses", patternSpans)
    , ("type pattern span covers the type and the name", typePatternSpan)
    , ("return span includes semicolon", returnSpan)
    , ("binding span starts at type", bindingSpan)
    , ("member span includes access and closing brace", memberSpan)
    ]

closureSpan :: String -> Bool
closureSpan spelling = case statements ("class Program { int Value() {\nauto f = " ++ spelling ++ ";\nreturn 1; } }") of
    Just (BindingStatement _ _ _ _ _ (CallableExpression value _ _ _ _ _) : _) ->
        exactSpan value 2 10 (10 + length spelling)
    _ -> False

ifSpan :: String -> Bool
ifSpan spelling = case statements ("class Program { int Value() {\n" ++ spelling ++ "\nreturn 1; } }") of
    Just (IfStatement value _ _ _ : _) -> exactSpan value 2 1 (1 + length spelling)
    _ -> False

guardSpan :: String -> Bool
guardSpan spelling = case statements ("class Program { int Value() {\n" ++ spelling ++ "\nreturn 1; } }") of
    Just (GuardStatement value _ _ : _) -> exactSpan value 2 1 (1 + length spelling)
    _ -> False

blockSpan :: String -> Bool
blockSpan spelling = case statements ("class Program { int Value() {\n" ++ spelling ++ "\nreturn 1; } }") of
    Just (BlockStatement value _ : _) -> exactSpan value 2 1 (1 + length spelling)
    _ -> False

matchStatementSpan :: String -> Bool
matchStatementSpan spelling = case statements ("class Program { int Value() {\n" ++ spelling ++ "\nreturn 1; } }") of
    Just (ExpressionStatement outer (MatchExpression inner _ _ _) True : _) ->
        exactSpan outer 2 1 (1 + length spelling) && exactSpan inner 2 1 (1 + length spelling)
    _ -> False

-- The initializer starts at column 10 of `auto r = ...;`.
matchExpressionSpan :: String -> Bool
matchExpressionSpan spelling = case statements ("class Program { int Value() {\nauto r = " ++ spelling ++ ";\nreturn r; } }") of
    Just (BindingStatement _ _ _ _ _ (MatchExpression value _ _ _) : _) -> exactSpan value 2 10 (10 + length spelling)
    _ -> False

ifExpressionSpan :: String -> Bool
ifExpressionSpan spelling = case statements ("class Program { int Value() {\nauto r = " ++ spelling ++ ";\nreturn r; } }") of
    Just (BindingStatement _ _ _ _ _ (ConditionalExpression value _ _ _ _) : _) -> exactSpan value 2 10 (10 + length spelling)
    _ -> False

-- `auto r = if (true) { 1 } else { 2 };`: the blocks are at columns 20 to 24
-- and 31 to 35.
valueBlockSpans :: Bool
valueBlockSpans = case statements "class Program { int Value() {\nauto r = if (true) { 1 } else { 2 };\nreturn r; } }" of
    Just
        (BindingStatement _ _ _ _ _ (ConditionalExpression _ _ (BlockExpression first _ _) (BlockExpression second _ _) _) : _) ->
        exactSpan first 2 20 25 && exactSpan second 2 31 36
    _ -> False

-- `auto r = match (1) { 1 -> 2, _ -> 3 };`: the first arm is `1 -> 2,` at
-- columns 22 to 28 and the second `_ -> 3` at columns 30 to 35.
armSpans :: Bool
armSpans = case statements "class Program { int Value() {\nauto r = match (1) { 1 -> 2, _ -> 3 };\nreturn r; } }" of
    Just (BindingStatement _ _ _ _ _ (MatchExpression _ _ [first, second] _) : _) ->
        exactSpan (matchArmSpan first) 2 22 29 && exactSpan (matchArmSpan second) 2 30 36
    _ -> False

lastArmSpan :: Bool
lastArmSpan = case statements "class Program { int Value() {\nmatch (1) { _ -> { } }\nreturn 1; } }" of
    Just (ExpressionStatement _ (MatchExpression _ _ [arm] _) _ : _) -> exactSpan (matchArmSpan arm) 2 13 21
    _ -> False

-- `match (1), (2) { (1), _ -> { } }`: the first pattern is `(1)` at columns
-- 18 to 20 and the second `_` at column 23.
patternSpans :: Bool
patternSpans = case statements "class Program { int Value() {\nmatch (1), (2) { (1), _ -> { } }\nreturn 1; } }" of
    Just (ExpressionStatement _ (MatchExpression _ _ [arm] _) _ : _) -> case matchArmPatterns arm of
        [first, second] -> exactSpan (matchPatternSpan first) 2 18 21 && exactSpan (matchPatternSpan second) 2 23 24
        _ -> False
    _ -> False

typePatternSpan :: Bool
typePatternSpan = case statements "class Program { int Value() {\nmatch (1) { int other -> { } }\nreturn 1; } }" of
    Just (ExpressionStatement _ (MatchExpression _ _ [arm] _) _ : _) -> case matchArmPatterns arm of
        [patternValue] -> exactSpan (matchPatternSpan patternValue) 2 13 22
        _ -> False
    _ -> False

returnSpan :: Bool
returnSpan = case statements "class Program { void Value() {\nreturn;\n} }" of
    Just [ReturnStatement value Nothing] -> exactSpan value 2 1 8
    _ -> False

bindingSpan :: Bool
bindingSpan = case statements "class Program { int Value() {\nint value = 1;\nreturn value; } }" of
    Just (BindingStatement value _ _ _ _ _ : _) -> exactSpan value 2 1 15
    _ -> False

memberSpan :: Bool
memberSpan = case parseSource "class Program {\npublic static void Main() {}\n}" of
    Right (ParsedAST (SyntaxTree _ [TypeDeclaration _ _ _ [member]])) -> exactSpan (declarationSpan member) 2 1 29
    _ -> False

exactSpan :: SourceSpan -> Int -> Int -> Int -> Bool
exactSpan value line start end =
    sourceFile value == "parser-contract.tala"
        && sourceStart value == SourcePosition line start
        && sourceEnd value == SourcePosition line end

tokenStreamTests :: [(String, Bool)]
tokenStreamTests =
    [ ("empty token stream is an empty module", parsesTokens [])
    , ("single EOF is an empty module", parsesTokens [eofToken])
    ,
        ( "valid supplied stream need not have EOF"
        , case tokensOf "class Program {}" of
            Just tokens -> parsesTokens (filter ((/= EndOfFileToken) . tokenKind) tokens)
            Nothing -> False
        )
    , ("EOF cannot hide a declaration suffix", rejectsTokens [eofToken, wordToken] "TAP0015")
    , ("duplicate EOF cannot hide trailing input", rejectsTokens [eofToken, eofToken] "TAP0015")
    ,
        ( "missing namespace terminator without EOF retains error"
        , case tokensOf "namespace Demo" of
            Just tokens -> rejectsTokens (filter ((/= EndOfFileToken) . tokenKind) tokens) "TAP0007"
            Nothing -> False
        )
    ,
        ( "truncated class without EOF terminates"
        , case tokensOf "class Program {" of
            Just tokens -> not (parsesTokens (filter ((/= EndOfFileToken) . tokenKind) tokens))
            Nothing -> False
        )
    , ("String token cannot masquerade as keyword", rejectsTokens [wordToken {tokenKind = StringToken}, eofToken] "TAP0006")
    ]
    where
        spanValue = SourceSpan "tokens.tala" (SourcePosition 1 1) (SourcePosition 1 2)
        eofToken = Token EndOfFileToken "" spanValue
        wordToken = Token KeywordToken "class" spanValue

tokensOf :: String -> Maybe [Token]
tokensOf source = case runLexer defaultLexer (LexerInput "tokens.tala" source) of
    Left _ -> Nothing
    Right tokens -> Just tokens

parsesTokens :: [Token] -> Bool
parsesTokens tokens = case runParser defaultParser (ParserInput "tokens.tala" tokens) of
    Right _ -> True
    Left _ -> False

rejectsTokens :: [Token] -> String -> Bool
rejectsTokens tokens code = case runParser defaultParser (ParserInput "tokens.tala" tokens) of
    Left [problem] -> diagnosticCode problem == code
    _ -> False

-- Type spelling is tested at the parsed boundary. This makes sugar choices
-- observable without relying on later passes that may normalize System types.
-- In particular Array<T, N> keeps two generic arguments: fixed versus dynamic
-- behavior belongs to overload and template resolution, not to a second class.
typeSyntaxTests :: [(String, Bool)]
typeSyntaxTests =
    [ ("simple type keeps compact syntax", returnSyntax "int" == Just (ExplicitType (Identifier "int")))
    ,
        ( "qualified type preserves every name component"
        , returnSyntax "System.Text.String"
            == Just
                ( QualifiedTypeSyntax
                    (QualifiedName [Identifier "System", Identifier "Text", Identifier "String"])
                    []
                )
        )
    ,
        ( "generic type preserves its type argument"
        , returnSyntax "System.Array<int>"
            == Just
                ( QualifiedTypeSyntax
                    (QualifiedName [Identifier "System", Identifier "Array"])
                    [TemplateTypeSyntax (ExplicitType (Identifier "int"))]
                )
        )
    ,
        ( "Array<T, N> remains one overloaded generic family"
        , returnSyntax "System.Array<Element, Length>"
            == Just
                ( QualifiedTypeSyntax
                    (QualifiedName [Identifier "System", Identifier "Array"])
                    [ TemplateTypeSyntax (ExplicitType (Identifier "Element"))
                    , TemplateTypeSyntax (ExplicitType (Identifier "Length"))
                    ]
                )
        )
    ,
        ( "nested generic closing delimiters remain independent"
        , returnSyntax "System.Array<System.Array<int>>"
            == Just
                ( QualifiedTypeSyntax
                    (QualifiedName [Identifier "System", Identifier "Array"])
                    [ TemplateTypeSyntax
                        ( QualifiedTypeSyntax
                            (QualifiedName [Identifier "System", Identifier "Array"])
                            [TemplateTypeSyntax (ExplicitType (Identifier "int"))]
                        )
                    ]
                )
        )
    ,
        ( "built-in fixed array remains distinct from System.Array"
        , returnSyntax "[]int" == Just (BuiltinArrayTypeSyntax (ExplicitType (Identifier "int")))
        )
    ,
        ( "dynamic array sugar has one element type"
        , returnSyntax "[String]" == Just (ArrayTypeSyntax (ExplicitType (Identifier "String")))
        )
    ,
        ( "dictionary sugar preserves key and value types"
        , returnSyntax "[String to int]"
            == Just (DictionaryTypeSyntax (ExplicitType (Identifier "String")) (ExplicitType (Identifier "int")))
        )
    ,
        ( "callable type preserves parameters and result"
        , returnSyntax "(int, String) -> bool"
            == Just
                ( CallableTypeSyntax
                    [ExplicitType (Identifier "int"), ExplicitType (Identifier "String")]
                    (ExplicitType (Identifier "bool"))
                )
        )
    ,
        ( "zero-parameter callable type is accepted"
        , returnSyntax "() -> void" == Just (CallableTypeSyntax [] (ExplicitType (Identifier "void")))
        )
    ,
        ( "compound binding dispatch recognizes a qualified generic type"
        , bindingSyntax "System.Array<int> values = Source();"
            == Just
                ( QualifiedTypeSyntax
                    (QualifiedName [Identifier "System", Identifier "Array"])
                    [TemplateTypeSyntax (ExplicitType (Identifier "int"))]
                )
        )
    ,
        ( "compound binding dispatch recognizes dictionary sugar"
        , bindingSyntax "[String to int] values = Source();"
            == Just (DictionaryTypeSyntax (ExplicitType (Identifier "String")) (ExplicitType (Identifier "int")))
        )
    ,
        ( "callable parameter dispatch recognizes a compound type"
        , callableParameterSyntax "\\(System.Array<int> values) -> 1"
            == Just
                ( QualifiedTypeSyntax
                    (QualifiedName [Identifier "System", Identifier "Array"])
                    [TemplateTypeSyntax (ExplicitType (Identifier "int"))]
                )
        )
    , ("underscore parameter label remains accepted", parameterNameFor "_ int value" == Just (Identifier "value"))
    , ("explicit parameter label is accepted", parameterNameFor "input: int value" == Just (Identifier "value"))
    , ("generic argument list cannot be empty", hasParserCode "TAP0016" (functionWithReturn "Array<>"))
    , ("qualified type cannot end after a dot", rejected (parseSource (functionWithReturn "System.")))
    , ("generic type requires a closing delimiter", rejected (parseSource (functionWithReturn "Array<int")))
    ,
        ( "fixed array sugar preserves its compile-time size"
        , case returnSyntax "[int; 3]" of
            Just (FixedArrayTypeSyntax (ExplicitType (Identifier "int")) (TemplateIntegerSyntax _ 3)) -> True
            _ -> False
        )
    ,
        ( "dynamic array sugar normalizes to System.Array<T>"
        , typedParameterType "[int]"
            == Just
                ( NamedType
                    (QualifiedName [Identifier "System", Identifier "Array"])
                    [TypeTemplateArgument intType]
                )
        )
    ,
        ( "dictionary sugar normalizes to System.Dictionary<K, V>"
        , typedParameterType "[String to int]"
            == Just
                ( NamedType
                    (QualifiedName [Identifier "System", Identifier "Dictionary"])
                    [TypeTemplateArgument stringType, TypeTemplateArgument intType]
                )
        )
    ,
        ( "built-in array has no invented public class name"
        , typedParameterType "[]int"
            == Just (NamedType (QualifiedName [Identifier "[]"]) [TypeTemplateArgument intType])
        )
    ,
        ( "callable syntax becomes a structural FunctionType"
        , typedParameterType "(int, String) -> bool"
            == Just (FunctionType [intType, stringType] boolType)
        )
    ]

functionWithReturn :: String -> String
functionWithReturn spelling = "class Program { " ++ spelling ++ " Value() { return Source(); } }"

returnSyntax :: String -> Maybe TypeSyntax
returnSyntax spelling = case parseSource (functionWithReturn spelling) of
    Right (ParsedAST (SyntaxTree _ [TypeDeclaration _ _ _ [FunctionDeclaration _ _ _ syntax _ _ _ _ _]])) -> Just syntax
    _ -> Nothing

bindingSyntax :: String -> Maybe TypeSyntax
bindingSyntax spelling = case statements (sourceWith spelling) of
    Just (BindingStatement _ _ syntax _ _ _ : _) -> Just syntax
    _ -> Nothing

callableParameterSyntax :: String -> Maybe TypeSyntax
callableParameterSyntax spelling = case statements (sourceWith ("auto value = " ++ spelling ++ ";")) of
    Just (BindingStatement _ _ _ _ _ (CallableExpression _ _ _ [parameter] _ _) : _) ->
        Just (parameterTypeSyntax parameter)
    _ -> Nothing

parameterNameFor :: String -> Maybe Identifier
parameterNameFor spelling = case parseSource ("class Program { void Apply(" ++ spelling ++ ") { return; } }") of
    Right (ParsedAST (SyntaxTree _ [TypeDeclaration _ _ _ [FunctionDeclaration _ _ _ _ [parameter] _ _ _ _]])) ->
        Just (parameterName parameter)
    _ -> Nothing

typedParameterType :: String -> Maybe Type
typedParameterType spelling =
    case compileToCorePrep
        (CompilerInput "type-contract.tala" ("class Program { void Apply(_ " ++ spelling ++ " value) { return; } }")) of
        Right artifacts ->
            case syntaxDeclarations (typedSyntaxTree (artifactTypedAST artifacts)) of
                [TypeDeclaration _ _ _ [FunctionDeclaration _ _ _ _ [parameter] _ _ _ _]] ->
                    Just (parameterAnnotation parameter)
                _ -> Nothing
        Left _ -> Nothing

hasParserCode :: String -> String -> Bool
hasParserCode code source = case parseSource source of
    Left problems -> any (\problem -> diagnosticStage problem == ParserStage && diagnosticCode problem == code) problems
    Right _ -> False

rejected :: Either problems value -> Bool
rejected result = case result of
    Left _ -> True
    Right _ -> False

-- Complete compilation proves that the nested representation of else-if is
-- understood by name resolution, typing, Core optimization, and CorePrep.
pipelineTests :: [(String, Bool)]
pipelineTests =
    [
        ( "first branch of else-if folds"
        , returnsInteger "if (true) { return 1; } else if (true) { return 2; } else { return 3; }" 1
        )
    ,
        ( "middle branch of else-if folds"
        , returnsInteger "if (false) { return 1; } else if (true) { return 2; } else { return 3; }" 2
        )
    ,
        ( "last branch of else-if folds"
        , returnsInteger "if (false) { return 1; } else if (false) { return 2; } else { return 3; }" 3
        )
    ,
        ( "unbraced else-if still requires condition parentheses"
        , not (accepted (sourceWith "if (false) {} else if true {} return 0;"))
        )
    , ("parenthesized comparison results type-check", compiles "return (1 < 2) == (2 < 3);")
    , ("explicit conjunction reaches CorePrep", compiles "return 1 < 2 && 2 < 3;")
    , ("mutable local dispatch reaches CorePrep", returnsInteger "int value = 1; value = 2; return 3;" 3)
    , ("immutable local dispatch reaches CorePrep", returnsInteger "final int value = 7; return value;" 7)
    , ("logical not of name is not a declaration", compiles "bool flag = true; return not flag;")
    , ("floating comparison reaches CorePrep", compiles "return 2.5 < 3.5;")
    , ("floating equality reaches CorePrep", compiles "return 2.5 == 3.5;")
    ,
        ( "live Boolean equality reaches CorePrep"
        , case compileToCorePrep
            (CompilerInput "live.tala" "class Program { bool Same(bool left, bool right) { return left == right; } }") of
            Right _ -> True
            Left _ -> False
        )
    ]

returnsInteger :: String -> Integer -> Bool
returnsInteger body expected = case compileToCorePrep (CompilerInput "parser-contract.tala" (sourceWith body)) of
    Right artifacts -> case coreModuleFunctions (artifactOptimizedCore artifacts) of
        [function] -> case reverse (coreFunctionBody function) of
            CoreReturn (CoreLiteral (CoreInteger value) _) : _ -> value == expected
            _ -> False
        _ -> False
    Left _ -> False

compiles :: String -> Bool
compiles body = case compileToCorePrep (CompilerInput "parser-contract.tala" ("class Program { bool Value() { " ++ body ++ " } }")) of
    Right _ -> True
    Left _ -> False

-- Check the computed result, not only successful compilation. Coercing every
-- integer operand to bool can otherwise make equality silently return true.
booleanOperandTests :: [(String, Bool)]
booleanOperandTests =
    [ ("Boolean result preserves operands: " ++ expression, returnsBoolean expression expected)
    | (expression, expected) <-
        [ ("1 == 2", False)
        , ("2 == 2", True)
        , ("1 \\= 2", True)
        , ("2 \\= 2", False)
        , ("1 < 2", True)
        , ("2 < 1", False)
        , ("2 <= 2", True)
        , ("2 > 1", True)
        , ("1 >= 2", False)
        , ("(1 < 2) == (3 < 4)", True)
        , ("1 < 2 && 3 > 4", False)
        , ("1 > 2 || 3 < 4", True)
        , ("not (1 == 2)", True)
        , ("not (1 < 2)", False)
        , ("not 0", True)
        , ("not 7", False)
        , ("1 \\= 2", True)
        , ("2 \\= 2", False)
        , ("1 + 2 == 3", True)
        , ("1 + 2 == 4", False)
        , ("true == false", False)
        , ("true \\= false", True)
        ]
    ]

returnsBoolean :: String -> Bool -> Bool
returnsBoolean expression expected =
    case compileToCorePrep
        (CompilerInput "parser-contract.tala" ("class Program { bool Value() { return " ++ expression ++ "; } }")) of
        Right artifacts -> case coreModuleFunctions (artifactOptimizedCore artifacts) of
            [function] -> case coreFunctionBody function of
                [CoreReturn (CoreLiteral (CoreBoolean value) _)] -> value == expected
                _ -> False
            _ -> False
        Left _ -> False
