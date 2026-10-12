-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module PatternTests (patternTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Wire
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser

-- Pattern coverage is deliberately organized by compiler boundary. Successful
-- parsing alone would not catch a lost annotation, repeated subject evaluation,
-- a broken Core wire tag, or a CorePrep operation that never reaches native code.
patternTests :: [(String, Bool)]
patternTests =
    [ ("wildcard pattern reaches typed Core", wildcardLowersToTrue)
    , ("literal pattern reaches equality Core", literalLowersToEquality)
    , ("all relational pattern spellings compile", relationalSpellingsCompile)
    , ("pattern and binds more tightly than or", combinatorPrecedence)
    , ("pattern not negates only its nested pattern", notPatternShape)
    , ("null pattern accepts a reference subject", compilesReference "value is null")
    , ("null pattern rejects a numeric subject", rejectedWith "TAT0020" (numericSource "value is null"))
    , ("type pattern accepts reference-to-reference tests", compilesReference "value is Payload")
    , ("type pattern rejects a numeric target", rejectedWith "TAT0022" (numericSource "value is String"))
    , ("literal pattern rejects an incompatible subject", rejectedWith "TAT0021" (referenceSource "value is 1"))
    , ("relational pattern rejects an incompatible subject", rejectedWith "TAT0023" (referenceSource "value is > 1"))
    , ("pattern subject call appears exactly once in Core", effectfulSubjectEvaluatedOnce)
    , ("pattern-local symbol is reused by every test", patternSubjectIsShared)
    , ("pattern Core remains verifier-valid", patternCoreVerifies)
    , ("Core wire round-trips pattern sequencing", patternCoreWireRoundTrip)
    , ("CorePrep wire round-trips pattern control flow", patternCorePrepWireRoundTrip)
    , ("pattern compilation reaches nonempty CorePrep", patternReachesCorePrep)
    ]

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource source = compileToCorePrep (CompilerInput "pattern-test.tala" source)

numericSource :: String -> String
numericSource expression =
    "class Program { bool Match(_ int value) { return " ++ expression ++ "; } }"

referenceSource :: String -> String
referenceSource expression =
    unlines
        [ "class Payload {}"
        , "class Program { bool Match(_ Payload value) { return " ++ expression ++ "; } }"
        ]

compilesReference :: String -> Bool
compilesReference expression = accepted (compileSource (referenceSource expression))

accepted :: Either problems value -> Bool
accepted result = case result of
    Right _ -> True
    Left _ -> False

rejectedWith :: String -> String -> Bool
rejectedWith code source = case compileSource source of
    Left diagnostics -> any ((== code) . diagnosticCode) diagnostics
    Right _ -> False

singleReturn :: String -> Maybe CoreExpression
singleReturn source = do
    artifacts <- either (const Nothing) Just (compileSource source)
    function <- case coreModuleFunctions (artifactCore artifacts) of
        [value] -> Just value
        values -> case reverse values of
            value : _ -> Just value
            [] -> Nothing
    case coreFunctionBody function of
        [CoreReturn expression] -> Just expression
        _ -> Nothing

wildcardLowersToTrue :: Bool
wildcardLowersToTrue = case singleReturn (numericSource "value is _") of
    Just (CoreLet _ intBinding (CoreVariable _ intSubject) (CoreLiteral (CoreBoolean True) resultType) letType) ->
        intBinding == intType && intSubject == intType && resultType == boolType && letType == boolType
    _ -> False

literalLowersToEquality :: Bool
literalLowersToEquality = case singleReturn (numericSource "value is 42") of
    Just
        (CoreLet subject _ _ (CorePrimitive CoreEqual [CoreVariable used _, CoreLiteral (CoreInteger 42) _] result) letType) ->
            resolvedSymbol subject == resolvedSymbol used && result == boolType && letType == boolType
    _ -> False

relationalSpellingsCompile :: Bool
relationalSpellingsCompile =
    all
        (accepted . compileSource . numericSource . ("value is " ++))
        ["< 1", "<= 1", "> 1", ">= 1", "== 1", "\\= 1"]

combinatorPrecedence :: Bool
combinatorPrecedence = case parsePatternSource (referenceSource "value is null or Payload and not null") of
    Just (OrPattern _ _ (AndPattern _ _ _ _) _) -> True
    _ -> False

parsePatternSource :: String -> Maybe (Pattern Identifier ())
parsePatternSource source = do
    tokens <- either (const Nothing) Just (runLexer defaultLexer (LexerInput "pattern-test.tala" source))
    ParsedAST tree <- either (const Nothing) Just (runParser defaultParser (ParserInput "pattern-test.tala" tokens))
    expression <- case [ value
                       | TypeDeclaration {typeMembers = members} <- syntaxDeclarations tree
                       , FunctionDeclaration {declarationName = Identifier "Match", declarationBody = Block statements} <- members
                       , ReturnStatement _ (Just value) <- statements
                       ] of
        [value] -> Just value
        _ -> Nothing
    case expression of
        IsPatternExpression _ _ patternValue _ -> Just patternValue
        _ -> Nothing

notPatternShape :: Bool
notPatternShape = case singleReturn (numericSource "value is not > 0") of
    Just (CoreLet _ _ _ (CorePrimitive CoreLogicalNot [CorePrimitive CoreGreaterThan _ _] result) letType) ->
        result == boolType && letType == boolType
    _ -> False

effectfulSource :: String
effectfulSource =
    unlines
        [ "class Program {"
        , "  String Source() { return \"value\"; }"
        , "  bool Match() { return Source() is not null and String; }"
        , "}"
        ]

effectfulSubjectEvaluatedOnce :: Bool
effectfulSubjectEvaluatedOnce = case singleReturn effectfulSource of
    Just expression@CoreLet {} -> countCalls expression == 1
    _ -> False

patternSubjectIsShared :: Bool
patternSubjectIsShared = case singleReturn effectfulSource of
    Just (CoreLet subject _ _ body _) ->
        let uses = expressionSymbols body
         in length uses >= 2 && all (== resolvedSymbol subject) uses
    _ -> False

countCalls :: CoreExpression -> Int
countCalls expression = case expression of
    CoreVariable {} -> 0
    CoreLiteral {} -> 0
    CoreApply callee arguments _ -> 1 + countCalls callee + sum (map countCalls arguments)
    CorePrimitive _ arguments _ -> sum (map countCalls arguments)
    CoreLet _ _ value body _ -> countCalls value + countCalls body
    CoreConditional condition whenTrue whenFalse _ -> sum (map countCalls [condition, whenTrue, whenFalse])
    CoreClosure captures _ _ body _ ->
        sum (map (countCalls . coreCaptureValue) captures) + sum (map statementCalls body)

statementCalls :: CoreStatement -> Int
statementCalls statement = case statement of
    CoreBind binding -> countCalls (coreBindingValue binding)
    CoreAssign _ value -> countCalls value
    CoreReturn value -> countCalls value
    CoreIf condition whenTrue whenFalse ->
        countCalls condition + sum (map statementCalls whenTrue) + sum (map statementCalls whenFalse)
    CoreEvaluate value -> countCalls value
    CoreWhile condition body -> countCalls condition + sum (map statementCalls body)
    CoreDoWhile body condition -> sum (map statementCalls body) + countCalls condition
    CoreFor condition updates body ->
        countCalls condition + sum (map statementCalls updates) + sum (map statementCalls body)
    CoreBreak -> 0
    CoreContinue -> 0

expressionSymbols :: CoreExpression -> [SymbolId]
expressionSymbols expression = case expression of
    CoreVariable name _ -> [resolvedSymbol name]
    CoreLiteral {} -> []
    CoreApply callee arguments _ -> expressionSymbols callee ++ concatMap expressionSymbols arguments
    CorePrimitive _ arguments _ -> concatMap expressionSymbols arguments
    CoreLet _ _ value body _ -> expressionSymbols value ++ expressionSymbols body
    CoreConditional condition whenTrue whenFalse _ -> concatMap expressionSymbols [condition, whenTrue, whenFalse]
    CoreClosure captures _ _ body _ ->
        concatMap (expressionSymbols . coreCaptureValue) captures ++ concatMap statementSymbols body

statementSymbols :: CoreStatement -> [SymbolId]
statementSymbols statement = case statement of
    CoreBind binding -> expressionSymbols (coreBindingValue binding)
    CoreAssign _ value -> expressionSymbols value
    CoreReturn value -> expressionSymbols value
    CoreIf condition whenTrue whenFalse ->
        expressionSymbols condition ++ concatMap statementSymbols whenTrue ++ concatMap statementSymbols whenFalse
    CoreEvaluate value -> expressionSymbols value
    CoreWhile condition body -> expressionSymbols condition ++ concatMap statementSymbols body
    CoreDoWhile body condition -> concatMap statementSymbols body ++ expressionSymbols condition
    CoreFor condition updates body ->
        expressionSymbols condition ++ concatMap statementSymbols updates ++ concatMap statementSymbols body
    CoreBreak -> []
    CoreContinue -> []

patternArtifacts :: Maybe FrontendArtifacts
patternArtifacts = either (const Nothing) Just (compileSource effectfulSource)

patternCoreVerifies :: Bool
patternCoreVerifies = case patternArtifacts of
    Just artifacts -> verifyCore (artifactCore artifacts) == Right (artifactCore artifacts)
    Nothing -> False

patternCoreWireRoundTrip :: Bool
patternCoreWireRoundTrip = case patternArtifacts of
    Just artifacts ->
        case encodeCore defaultCoreWireLimits (artifactCore artifacts) >>= decodeCore defaultCoreWireLimits of
            Right decoded -> decoded == artifactCore artifacts
            Left _ -> False
    Nothing -> False

patternCorePrepWireRoundTrip :: Bool
patternCorePrepWireRoundTrip = case patternArtifacts of
    Just artifacts -> case encodeCorePrep (artifactCorePrep artifacts) >>= decodeCorePrep of
        Right decoded -> decoded == artifactCorePrep artifacts
        Left _ -> False
    Nothing -> False

patternReachesCorePrep :: Bool
patternReachesCorePrep = case patternArtifacts of
    Just artifacts -> not (null (corePrepModuleFunctions (artifactCorePrep artifacts)))
    Nothing -> False
