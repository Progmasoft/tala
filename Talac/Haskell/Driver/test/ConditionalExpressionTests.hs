-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Vertical tests for the conditional forms and the statement forms that
landed with them: @condition ? first : second@, @left ?: fallback@, compound
assignment, and the discard statement.

Shape assertions read the unoptimized Core wherever a call must stay visible,
because the optimizer is free to fold a pure callee. Laziness is asserted on
CorePrep blocks, which is the representation the native backend executes.
-}
module ConditionalExpressionTests (conditionalExpressionTests) where

import Data.List (isInfixOf, isPrefixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Specialization

conditionalExpressionTests :: [(String, Bool)]
conditionalExpressionTests =
    lexerTests
        ++ parserTests
        ++ typeTests
        ++ loweringTests
        ++ verifierTests
        ++ optimizerTests
        ++ corePrepTests

-- ---------------------------------------------------------------- lexer

lexerTests :: [(String, Bool)]
lexerTests =
    [ ("a spaced conditional lexes '?' and ':' separately", symbolsOf "a ? b : c" == ["?", ":"])
    , ("the omitted-middle operator is one token", symbolsOf "a ?: b" == ["?:"])
    , ("a conditional with a spaced empty middle is not the coalescing token", symbolsOf "a ? : b" == ["?", ":"])
    , ("null coalescing lexes as its own token", symbolsOf "a ?? b" == ["??"])
    , ("null-coalescing assignment lexes as its own token", symbolsOf "a ??= b" == ["??="])
    , ("every compound assignment operator is one token", all compoundIsOneToken compoundSpellings)
    , ("rounded-division assignment is not a division followed by '/='", symbolsOf "a //= b" == ["//="])
    , ("power assignment is not a multiplication followed by '*='", symbolsOf "a **= b" == ["**="])
    , ("shift assignments are single tokens", symbolsOf "a <<= b >>= c" == ["<<=", ">>="])
    , ("relational operators keep their spelling next to assignments", symbolsOf "a <= b >= c" == ["<=", ">="])
    , ("nested generic closers stay separate tokens", symbolsOf "A<B<C>> value" == ["<", "<", ">", ">"])
    , ("a line comment still starts at a spaced '--'", symbolsOf "a -= b -- c ? d : e" == ["-="])
    ]

compoundSpellings :: [String]
compoundSpellings = ["+=", "-=", "*=", "/=", "//=", "%=", "**=", "<<=", ">>=", "&=", "^=", "|="]

compoundIsOneToken :: String -> Bool
compoundIsOneToken operatorText = symbolsOf ("target " ++ operatorText ++ " 1") == [operatorText]

symbolsOf :: String -> [String]
symbolsOf text = case runLexer defaultLexer (LexerInput "conditional.tala" text) of
    Right tokens -> [tokenText token | token <- tokens, tokenKind token == SymbolToken]
    Left _ -> ["<lexer error>"]

-- ---------------------------------------------------------------- parser

parserTests :: [(String, Bool)]
parserTests =
    [ ("a conditional parses into its three operands", conditionalParses)
    , ("chained conditionals group to the right", conditionalIsRightAssociative)
    , ("a conditional may nest in its first result without parentheses", conditionalNestsInFirstResult)
    , ("logical OR binds more tightly than a conditional", logicalOrBindsTighter)
    , ("the conditional is the weakest expression level in a call argument", conditionalIsCallArgument)
    , ("truthy coalescing parses into its two operands", coalesceParses)
    , ("a spaced empty middle is the same omitted-middle form", spacedCoalesceParses)
    , ("chained truthy coalescing groups to the right", coalesceIsRightAssociative)
    , ("coalescing in a conditional result stays inside that result", coalesceNestsInConditional)
    , ("a conditional without ':' is a dedicated syntax error", parseRejectedWith "TAP0029" (returning "flag ? 1"))
    , ("null coalescing is rejected until nullable types exist", parseRejectedWith "TAP0030" (returning "left ?? right"))
    , ("null-coalescing assignment is rejected until nullable types exist", parseRejectedWith "TAP0031" (body "left ??= right; return 0;"))
    , ("every compound operator parses to its binary operator", all compoundParses compoundOperators)
    , ("a compound assignment needs a named target", parseRejectedWith "TAP0003" (body "Next() += 1; return 0;"))
    , ("a compound assignment needs its terminator", parseRejected (body "left += 1 return left;"))
    , ("a for update may be a compound assignment", forUpdateIsCompound)
    , ("a for update list may mix increments and compound assignments", forUpdateListParses)
    , ("the discard statement parses as its own statement", discardParses)
    , ("discard is not an expression", parseRejected (returning "(_ = Next())"))
    , ("discard needs its terminator", parseRejected (body "_ = Next() return 0;"))
    , ("a conditional is not a template value argument", parseRejectedWith "TAP0018" templateConditionalArgument)
    ]

compoundOperators :: [(String, BinaryOperator)]
compoundOperators =
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

conditionalParses :: Bool
conditionalParses = case returned "flag ? left : right" of
    Just (ConditionalExpression _ condition first second ()) ->
        isName "flag" condition && isName "left" first && isName "right" second
    _ -> False

conditionalIsRightAssociative :: Bool
conditionalIsRightAssociative = case returned "flag ? 1 : other ? 2 : 3" of
    Just (ConditionalExpression _ condition _ (ConditionalExpression _ inner _ _ ()) ()) ->
        isName "flag" condition && isName "other" inner
    _ -> False

conditionalNestsInFirstResult :: Bool
conditionalNestsInFirstResult = case returned "flag ? other ? 1 : 2 : 3" of
    Just (ConditionalExpression _ condition (ConditionalExpression _ inner _ _ ()) third ()) ->
        isName "flag" condition && isName "other" inner && isInteger 3 third
    _ -> False

logicalOrBindsTighter :: Bool
logicalOrBindsTighter = case returned "flag || other ? 1 : 2" of
    Just (ConditionalExpression _ (BinaryExpression _ LogicalOr _ _ ()) first second ()) ->
        isInteger 1 first && isInteger 2 second
    _ -> False

conditionalIsCallArgument :: Bool
conditionalIsCallArgument = case returned "Twice(flag ? 1 : 2)" of
    Just (CallExpression _ _ [ConditionalExpression {}] ()) -> True
    _ -> False

coalesceParses :: Bool
coalesceParses = case returned "left ?: right" of
    Just (CoalesceExpression _ left fallback ()) -> isName "left" left && isName "right" fallback
    _ -> False

spacedCoalesceParses :: Bool
spacedCoalesceParses = case returned "left ? : right" of
    Just (CoalesceExpression _ left fallback ()) -> isName "left" left && isName "right" fallback
    _ -> False

coalesceIsRightAssociative :: Bool
coalesceIsRightAssociative = case returned "left ?: right ?: 9" of
    Just (CoalesceExpression _ left (CoalesceExpression _ middle final ()) ()) ->
        isName "left" left && isName "right" middle && isInteger 9 final
    _ -> False

coalesceNestsInConditional :: Bool
coalesceNestsInConditional = case returned "flag ? left ?: 1 : right ?: 2" of
    Just (ConditionalExpression _ _ CoalesceExpression {} CoalesceExpression {} ()) -> True
    _ -> False

compoundParses :: (String, BinaryOperator) -> Bool
compoundParses (operatorText, operator) =
    case firstStatements (body ("left " ++ operatorText ++ " right; return left;")) of
        Just (CompoundAssignmentStatement _ parsed (Identifier "left") () value : _) ->
            parsed == operator && isName "right" value
        _ -> False

forUpdateIsCompound :: Bool
forUpdateIsCompound =
    case firstStatements (body "for (int index = 0; index < left; index += 2) {} return left;") of
        Just (ForStatement _ _ _ [CompoundAssignmentStatement _ Add (Identifier "index") () _] _ : _) -> True
        _ -> False

forUpdateListParses :: Bool
forUpdateListParses =
    case firstStatements (body "for (int index = 0; index < left; index++, right -= 1) {} return left;") of
        Just (ForStatement _ _ _ [IncrementStatement {}, CompoundAssignmentStatement _ Subtract _ () _] _ : _) -> True
        _ -> False

discardParses :: Bool
discardParses = case firstStatements (body "_ = Next(); return 0;") of
    Just (DiscardStatement _ CallExpression {} : _) -> True
    _ -> False

templateConditionalArgument :: String
templateConditionalArgument =
    unlines
        [ "template<int N> class Buffer {}"
        , "class Program {"
        , "    public static int Evaluate() {"
        , "        final Buffer<+(1 ? 2 : 3)> value = 0;"
        , "        return 0;"
        , "    }"
        , "}"
        ]

isName :: String -> Expression Identifier () -> Bool
isName expected expression = case expression of
    NameExpression _ (Identifier actual) () -> actual == expected
    _ -> False

isInteger :: Integer -> Expression Identifier () -> Bool
isInteger expected expression = case expression of
    LiteralExpression _ (IntegerLiteral actual) () -> actual == expected
    _ -> False

parseSource :: String -> Either [Diagnostic] ParsedAST
parseSource text = do
    tokens <- runLexer defaultLexer (LexerInput "conditional.tala" text)
    runParser defaultParser (ParserInput "conditional.tala" tokens)

parseRejected :: String -> Bool
parseRejected text = either (const True) (const False) (parseSource text)

parseRejectedWith :: String -> String -> Bool
parseRejectedWith code text = case parseSource text of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

-- | Statements of the first method of the first class in a parsed unit.
firstStatements :: String -> Maybe [Statement Identifier ()]
firstStatements text = case parseSource text of
    Right (ParsedAST (SyntaxTree _ (TypeDeclaration {typeMembers = member : _} : _))) -> case member of
        FunctionDeclaration {declarationBody = Block statements} -> Just statements
        _ -> Nothing
    _ -> Nothing

returned :: String -> Maybe (Expression Identifier ())
returned expression = case firstStatements (returning expression) of
    Just [ReturnStatement _ value] -> value
    _ -> Nothing

-- ---------------------------------------------------------------- sources

-- | One method whose parameters give every test non-constant operands.
body :: String -> String
body statements =
    unlines
        [ "class Program {"
        , "    public static int Evaluate(_ bool flag, _ bool other, _ int left, _ int right) {"
        , "        " ++ statements
        , "    }"
        , "    public static int Next() { return 7; }"
        , "    public static int Twice(_ int value) { return value + value; }"
        , "    public static void Touch() { }"
        , "    public static int Countdown(_ int value) { return value > 0 ? Countdown(value - 1) : 0; }"
        , "}"
        ]

returning :: String -> String
returning expression = body ("return " ++ expression ++ ";")

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "conditional.tala" text)

accepted :: String -> Bool
accepted text = either (const False) (const True) (compileSource text)

rejectedWith :: String -> String -> Bool
rejectedWith code text = case compileSource text of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

-- ---------------------------------------------------------------- type checker

typeTests :: [(String, Bool)]
typeTests =
    [ ("a conditional over int operands is accepted", accepted (returning "flag ? left : right"))
    , ("a conditional test may be numeric", accepted (returning "left ? left : right"))
    , ("a conditional test must be bool or numeric", rejectedWith "TAT0036" (returning "\"text\" ? left : right"))
    , ("conditional results must have one type", rejectedWith "TAT0037" (returning "flag ? left : other"))
    , ("a conditional selects one of two strings", accepted (body "bool same = (flag ? \"a\" : \"b\") == \"a\"; return 0;"))
    , ("a string and a number are not results of one conditional", rejectedWith "TAT0037" (body "bool same = (flag ? \"a\" : 1) == \"a\"; return 0;"))
    , ("a void call is not a conditional result", rejected (body "flag ? Touch() : Touch(); return 0;"))
    , ("a literal first result takes the type of the second", accepted (longBody "long chosen = flag ? 1 : wide; return 0;"))
    , ("a literal second result takes the type of the first", accepted (longBody "long chosen = flag ? wide : 1; return 0;"))
    , ("an untyped literal pair takes the expected type", accepted (longBody "long chosen = flag ? 1 : 2; return 0;"))
    , ("an expected type does not convert a computed result", rejected (longBody "long chosen = flag ? narrow : 2; return 0;"))
    , ("a conditional result out of the target range is diagnosed", rejectedWith "TAT0016" (body "byte small = flag ? 300 : 1; return 0;"))
    , ("a floating conditional is accepted", accepted (body "double ratio = flag ? 1.5 : 2.5; return 0;"))
    , ("a Boolean conditional is accepted", accepted (body "bool chosen = flag ? other : false; return 0;"))
    , ("a conditional with a call is an effect-capable statement", accepted (body "flag ? Next() : 0; return 0;"))
    , ("a call-free conditional statement is a pure value statement", rejectedWith "TAT0013" (body "flag ? left : right; return 0;"))
    , ("truthy coalescing over int operands is accepted", accepted (returning "left ?: right"))
    , ("truthy coalescing over bool operands is accepted", accepted (body "bool chosen = flag ?: other; return 0;"))
    , ("truthy coalescing operands must have one type", rejectedWith "TAT0038" (returning "left ?: flag"))
    , ("truthy coalescing needs a condition-compatible left operand", rejectedWith "TAT0039" (body "bool same = (\"a\" ?: \"b\") == \"a\"; return 0;"))
    , ("a literal left operand takes the type of the fallback", accepted (longBody "long chosen = 0 ?: wide; return 0;"))
    , ("a literal fallback takes the type of the left operand", accepted (longBody "long chosen = wide ?: 5; return 0;"))
    , ("every arithmetic compound assignment type-checks on int", all compoundAccepted ["+=", "-=", "*=", "/=", "//=", "%=", "**=", "<<=", ">>=", "&=", "^=", "|="])
    , ("a compound literal operand takes the target type", accepted (longBody "wide += 1; return 0;"))
    , ("a compound assignment cannot modify an immutable binding", rejectedWith "TAT0003" (body "final int fixed = 1; fixed += 1; return fixed;"))
    , ("compound operands must match the target type", rejectedWith "TAT0012" (longBody "narrow += wide; return 0;"))
    , ("a bitwise compound assignment needs an integer target", rejectedWith "TAT0012" (body "double ratio = 1.5; ratio &= 2.5; return 0;"))
    , ("a compound assignment needs a numeric target", rejectedWith "TAT0012" (body "bool state = flag; state += other; return 0;"))
    , ("a compound result must have the target type", rejectedWith "TAT0035" (body "double ratio = 7.5; ratio //= 2.0; return 0;"))
    , ("a compound assignment to an unknown name is a resolution error", rejected (body "missing += 1; return 0;"))
    , ("discard accepts a call", accepted (body "_ = Next(); return 0;"))
    , ("discard accepts a void call", accepted (body "_ = Touch(); return 0;"))
    , ("discard accepts a pure value", accepted (body "_ = left + right; return 0;"))
    , ("discard still type-checks its operand", rejectedWith "TAT0012" (body "_ = left + flag; return 0;"))
    , ("the new forms survive template instantiation", templateInstantiates)
    , ("template reachability follows calls in both conditional results", templateReachesBothResults)
    , ("template reachability follows calls in a coalescing fallback and a discard", templateReachesFallbackAndDiscard)
    , ("a closure body may use the conditional forms", accepted closureSource)
    ]

rejected :: String -> Bool
rejected = not . accepted

compoundAccepted :: String -> Bool
compoundAccepted operatorText = accepted (body ("int value = left; value " ++ operatorText ++ " 2; return value;"))

longBody :: String -> String
longBody statements = body ("long wide = 5; int narrow = 3; " ++ statements)

templateSource :: String
templateSource =
    unwords
        [ "template<typename T> class Box {"
        , "int Entry(_ bool flag, _ int seed) {"
        , "int value = seed;"
        , "value += 2;"
        , "_ = Audit(value);"
        , "return flag ? First(value) : Second(seed) ?: Fallback();"
        , "}"
        , "int First(_ int value) { return value; }"
        , "int Second(_ int value) { return value; }"
        , "int Fallback() { return 7; }"
        , "int Audit(_ int value) { return value; }"
        , "int Unused() { return 9; }"
        , "}"
        ]

-- | Specialize @Box<string>@ for its @Entry@ member only.
templatePlan :: Maybe TemplateSpecializationPlan
templatePlan = case analyzeSemantics (CompilerInput "conditional-template.tala" templateSource) of
    Right artifacts ->
        either
            (const Nothing)
            Just
            ( planTemplateSpecializations
                defaultTemplateSpecializationLimits
                (semanticTypedAST artifacts)
                [ TemplateSpecializationDemand
                    (TemplateApplication (QualifiedName [Identifier "Box"]) [TypeTemplateArgument stringType])
                    (TemplateMemberDemand [Identifier "Entry"])
                    "conditional-template"
                ]
            )
    Left _ -> Nothing

specializedMembers :: [Declaration ResolvedName Type]
specializedMembers = case templatePlan of
    Just plan ->
        concat
            [ members
            | TypeDeclaration {typeMembers = members} <-
                map templateSpecializationDeclaration (plannedTemplateSpecializations plan)
            ]
    Nothing -> []

specializedNames :: [String]
specializedNames = map (identifierText . resolvedSpelling . declarationName) specializedMembers

-- The instantiated declaration is a fresh, closed copy of the template
-- member. Every new node must have been copied by the template passes.
templateInstantiates :: Bool
templateInstantiates =
    let closed = show specializedMembers
     in all
            (`isInfixOf` closed)
            ["ConditionalExpression", "CoalesceExpression", "CompoundAssignmentStatement", "DiscardStatement"]

templateReachesBothResults :: Bool
templateReachesBothResults = all (`elem` specializedNames) ["Entry", "First", "Second"]

templateReachesFallbackAndDiscard :: Bool
templateReachesFallbackAndDiscard =
    all (`elem` specializedNames) ["Fallback", "Audit"] && "Unused" `notElem` specializedNames

closureSource :: String
closureSource =
    unlines
        [ "class Program {"
        , "    public static int Evaluate(_ bool flag, _ int left, _ int right) {"
        , "        auto choose = \\ -> flag ? left : right ?: 1;"
        , "        return choose();"
        , "    }"
        , "}"
        ]

-- ---------------------------------------------------------------- lowering

loweringTests :: [(String, Bool)]
loweringTests =
    [ ("a conditional lowers to one Core conditional", conditionalLowers)
    , ("truthy coalescing binds its left operand once", coalesceBindsLeftOnce)
    , ("truthy coalescing reads the bound value as test and result", coalesceReadsBinding)
    , ("every compound operator lowers to its primitive", all compoundLowers compoundPrimitives)
    , ("a compound assignment reads its target as the left operand", compoundReadsTarget)
    , ("a for update compound assignment lowers into the update region", forUpdateLowers)
    , ("discard lowers to an evaluated expression", discardLowers)
    , ("the lowered conditional forms verify as Core", loweredCoreVerifies)
    , ("Core wire round-trips the conditional forms", wireRoundTrips)
    , ("a truncated conditional payload is rejected by the wire reader", wireRejectsTruncation)
    , ("a closure captures the operands of its conditional body", closureCapturesOperands)
    ]

compoundPrimitives :: [(String, CorePrimitive)]
compoundPrimitives =
    [ ("+=", CoreAdd)
    , ("-=", CoreSubtract)
    , ("*=", CoreMultiply)
    , ("/=", CoreDivide)
    , ("//=", CoreFloorDivide)
    , ("%=", CoreRemainder)
    , ("**=", CorePower)
    , ("<<=", CoreShiftLeft)
    , (">>=", CoreShiftRight)
    , ("&=", CoreBitwiseAnd)
    , ("^=", CoreBitwiseXor)
    , ("|=", CoreBitwiseOr)
    ]

-- | Unoptimized Core body of the method named @Evaluate@.
loweredBody :: String -> Maybe [CoreStatement]
loweredBody text = case compileSource text of
    Right artifacts -> evaluateBody (artifactCore artifacts)
    Left _ -> Nothing

evaluateBody :: CoreModule -> Maybe [CoreStatement]
evaluateBody moduleValue =
    case [coreFunctionBody function | function <- coreModuleFunctions moduleValue, named "Evaluate" function] of
        statements : _ -> Just statements
        [] -> Nothing

named :: String -> CoreFunction -> Bool
named expected function = identifierText (resolvedSpelling (coreFunctionName function)) == expected

conditionalLowers :: Bool
conditionalLowers = case loweredBody (returning "flag ? left : right") of
    Just [CoreReturn (CoreConditional (CoreVariable condition _) (CoreVariable first _) (CoreVariable second _) valueType)] ->
        map spelling [condition, first, second] == ["flag", "left", "right"] && valueType == intType
    _ -> False

coalesceBindsLeftOnce :: Bool
coalesceBindsLeftOnce = case loweredBody (returning "Next() ?: right") of
    Just [CoreReturn expression@(CoreLet _ _ CoreApply {} _ _)] -> countCalls expression == 1
    _ -> False

coalesceReadsBinding :: Bool
coalesceReadsBinding = case loweredBody (returning "Next() ?: right") of
    Just [CoreReturn (CoreLet bound _ _ (CoreConditional (CoreVariable test _) (CoreVariable first _) (CoreVariable second _) _) _)] ->
        resolvedSymbol test == resolvedSymbol bound
            && resolvedSymbol first == resolvedSymbol bound
            && spelling second == "right"
            && "$coalesce" `isPrefixOf` spelling bound
    _ -> False

compoundLowers :: (String, CorePrimitive) -> Bool
compoundLowers (text, primitive) =
    case loweredBody (body ("int value = left; value " ++ text ++ " right; return value;")) of
        Just [_, CoreAssign target (CorePrimitive actual [_, _] valueType), _] ->
            spelling target == "value" && actual == primitive && valueType == intType
        _ -> False

compoundReadsTarget :: Bool
compoundReadsTarget = case loweredBody (body "int value = left; value -= right; return value;") of
    Just [_, CoreAssign target (CorePrimitive CoreSubtract [CoreVariable current _, CoreVariable operand _] _), _] ->
        resolvedSymbol current == resolvedSymbol target && spelling operand == "right"
    _ -> False

forUpdateLowers :: Bool
forUpdateLowers =
    case loweredBody (body "int total = 0; for (int index = 0; index < left; index += 2) { total += index; } return total;") of
        Just [_, _, CoreFor _ [CoreAssign _ (CorePrimitive CoreAdd _ _)] [CoreAssign index (CorePrimitive CoreAdd _ _)], _] ->
            spelling index == "index"
        _ -> False

discardLowers :: Bool
discardLowers = case loweredBody (body "_ = Next(); return 0;") of
    Just [CoreEvaluate CoreApply {}, CoreReturn _] -> True
    _ -> False

allFormsSource :: String
allFormsSource =
    body $
        unwords
            [ "int value = flag ? left : right;"
            , "value += other ? 1 : 2;"
            , "value = Twice(value) ?: Next();"
            , "_ = Countdown(value);"
            , "for (int index = 0; index < left; index += 1) { value -= index ?: 1; }"
            , "return flag ? other ? value : left : right ?: 3;"
            ]

loweredCoreVerifies :: Bool
loweredCoreVerifies = case compileSource allFormsSource of
    Right artifacts ->
        verifyCore (artifactCore artifacts) == Right (artifactCore artifacts)
            && verifyCore (artifactOptimizedCore artifacts) == Right (artifactOptimizedCore artifacts)
    Left _ -> False

wireRoundTrips :: Bool
wireRoundTrips = case compileSource allFormsSource of
    Right artifacts ->
        let core = artifactCore artifacts
         in moduleHasConditional core
                && (encodeCore defaultCoreWireLimits core >>= decodeCore defaultCoreWireLimits) == Right core
    Left _ -> False

wireRejectsTruncation :: Bool
wireRejectsTruncation = case encodeCore defaultCoreWireLimits conditionalModule of
    Right bytes ->
        -- Every proper prefix must fail: a conditional has no count that a
        -- shorter payload could satisfy.
        all (isLeft . decodeCore defaultCoreWireLimits) [take size bytes | size <- [0 .. length bytes - 1]]
            && decodeCore defaultCoreWireLimits bytes == Right conditionalModule
    Left _ -> False
    where
        isLeft = either (const True) (const False)

closureCapturesOperands :: Bool
closureCapturesOperands = case compileSource closureSource of
    Right artifacts ->
        let captured =
                [ spelling (coreCaptureName capture)
                | function <- coreModuleFunctions (artifactCore artifacts)
                , CoreClosure captures _ _ _ _ <- concatMap statementExpressions (coreFunctionBody function)
                , capture <- captures
                ]
         in captured == ["flag", "left", "right"]
    Left _ -> False

spelling :: ResolvedName -> String
spelling = identifierText . resolvedSpelling

-- | Top-level expressions of a statement list, without descending into them.
statementExpressions :: CoreStatement -> [CoreExpression]
statementExpressions statement = case statement of
    CoreBind binding -> [coreBindingValue binding]
    CoreAssign _ value -> [value]
    CoreReturn value -> [value]
    CoreEvaluate value -> [value]
    CoreIf condition yes no -> condition : concatMap statementExpressions (yes ++ no)
    CoreWhile condition loopBody -> condition : concatMap statementExpressions loopBody
    CoreDoWhile loopBody condition -> concatMap statementExpressions loopBody ++ [condition]
    CoreFor condition loopBody update -> condition : concatMap statementExpressions (loopBody ++ update)
    CoreBreak -> []
    CoreContinue -> []

-- | Every expression node reachable from an expression, itself included.
subexpressions :: CoreExpression -> [CoreExpression]
subexpressions expression =
    expression : case expression of
        CoreVariable {} -> []
        CoreLiteral {} -> []
        CoreApply callee arguments _ -> concatMap subexpressions (callee : arguments)
        CorePrimitive _ arguments _ -> concatMap subexpressions arguments
        CoreLet _ _ value letBody _ -> subexpressions value ++ subexpressions letBody
        CoreConditional condition whenTrue whenFalse _ -> concatMap subexpressions [condition, whenTrue, whenFalse]
        CoreClosure captures _ _ closureBody _ ->
            concatMap (subexpressions . coreCaptureValue) captures
                ++ concatMap subexpressions (concatMap statementExpressions closureBody)

moduleExpressions :: CoreModule -> [CoreExpression]
moduleExpressions moduleValue =
    concatMap
        subexpressions
        (concatMap statementExpressions (concatMap coreFunctionBody (coreModuleFunctions moduleValue)))

countCalls :: CoreExpression -> Int
countCalls expression = length [() | CoreApply {} <- subexpressions expression]

isConditional :: CoreExpression -> Bool
isConditional expression = case expression of
    CoreConditional {} -> True
    _ -> False

moduleHasConditional :: CoreModule -> Bool
moduleHasConditional = any isConditional . moduleExpressions

-- ---------------------------------------------------------------- Core verifier

verifierTests :: [(String, Bool)]
verifierTests =
    [ ("the Core verifier accepts a well-typed conditional", verifyCore conditionalModule == Right conditionalModule)
    , ("the Core verifier rejects a non-condition test", coreRejectedWith "TAC1067" (conditionalOf text one two intType))
    , ("the Core verifier rejects a mistyped first result", coreRejectedWith "TAC1068" (conditionalOf flagRead truth two intType))
    , ("the Core verifier rejects a mistyped second result", coreRejectedWith "TAC1069" (conditionalOf flagRead one truth intType))
    , ("the Core verifier rejects a non-scalar result", coreRejectedWith "TAC1070" (conditionalOf flagRead text text stringType))
    , ("the Core verifier rejects a void result", coreRejectedWith "TAC1070" (conditionalOf flagRead unit unit unitType))
    , ("the Core verifier checks names inside both results", coreRejectedWith "TAC1020" (conditionalOf flagRead one missing intType))
    , ("the Core verifier checks names inside the test", coreRejectedWith "TAC1020" (conditionalOf missingFlag one two intType))
    , ("a let inside a result does not leak into the other result", coreRejectedWith "TAC1020" leakingLet)
    ]
    where
        text = CoreLiteral (CoreString "text") stringType
        truth = CoreLiteral (CoreBoolean True) boolType
        unit = CoreLiteral CoreUnit unitType
        missing = CoreVariable (ResolvedName (SymbolId 90) (Identifier "missing")) intType
        missingFlag = CoreVariable (ResolvedName (SymbolId 91) (Identifier "missing")) boolType
        scoped = ResolvedName (SymbolId 50) (Identifier "scoped")
        leakingLet =
            conditionalOf
                flagRead
                (CoreLet scoped intType one (CoreVariable scoped intType) intType)
                (CoreVariable scoped intType)
                intType

flagName :: ResolvedName
flagName = ResolvedName (SymbolId 2) (Identifier "flag")

flagRead :: CoreExpression
flagRead = CoreVariable flagName boolType

one, two :: CoreExpression
one = CoreLiteral (CoreInteger 1) intType
two = CoreLiteral (CoreInteger 2) intType

-- | A one-function module returning the given conditional.
conditionalOf :: CoreExpression -> CoreExpression -> CoreExpression -> Type -> CoreModule
conditionalOf condition whenTrue whenFalse valueType =
    CoreModuleWithSources
        (QualifiedName [Identifier "Conditional"])
        [ CoreFunction
            (ResolvedName (SymbolId 1) (Identifier "Choose"))
            [(flagName, boolType)]
            valueType
            [CoreReturn (CoreConditional condition whenTrue whenFalse valueType)]
        ]
        []
        []

conditionalModule :: CoreModule
conditionalModule = conditionalOf flagRead one two intType

coreRejectedWith :: String -> CoreModule -> Bool
coreRejectedWith code moduleValue = case verifyCore moduleValue of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

-- ---------------------------------------------------------------- optimizer

optimizerTests :: [(String, Bool)]
optimizerTests =
    [ ("a constant true test leaves only the first result", foldsTo "true ? left : right" "left")
    , ("a constant false test leaves only the second result", foldsTo "false ? left : right" "right")
    , ("a numeric constant test selects by truth", foldsTo "0 ? left : right" "right")
    , ("a non-constant test keeps the conditional", optimizedHasConditional (returning "flag ? left : right"))
    , ("a truthy constant left operand removes the fallback", coalesceKeepsConstantLeft)
    , ("a zero left operand selects the fallback", coalesceSelectsFallback)
    , ("constants fold inside a kept conditional", constantsFoldInResults)
    , ("a pure discarded value disappears", optimizedBodyLength (body "_ = left + right; return 0;") == Just 1)
    , ("a recursive call stays behind its conditional", optimizedKeepsRecursiveCall)
    , ("the optimized conditional forms still verify", optimizedVerifies)
    ]

optimizedBody :: String -> Maybe [CoreStatement]
optimizedBody text = case compileSource text of
    Right artifacts -> evaluateBody (artifactOptimizedCore artifacts)
    Left _ -> Nothing

optimizedBodyLength :: String -> Maybe Int
optimizedBodyLength = fmap length . optimizedBody

foldsTo :: String -> String -> Bool
foldsTo expression expected = case optimizedBody (returning expression) of
    Just [CoreReturn (CoreVariable name _)] -> spelling name == expected
    _ -> False

-- The constant folder propagates the bound literal into the body but keeps
-- the now unread binding; only the conditional itself must be gone.
coalesceKeepsConstantLeft :: Bool
coalesceKeepsConstantLeft = case optimizedBody (returning "5 ?: right") of
    Just [CoreReturn (CoreLet _ _ (CoreLiteral (CoreInteger 5) _) (CoreLiteral (CoreInteger 5) _) _)] -> True
    _ -> False

coalesceSelectsFallback :: Bool
coalesceSelectsFallback = case optimizedBody (returning "0 ?: right") of
    Just [CoreReturn (CoreLet _ _ (CoreLiteral (CoreInteger 0) _) (CoreVariable name _) _)] -> spelling name == "right"
    _ -> False

optimizedHasConditional :: String -> Bool
optimizedHasConditional text = case optimizedBody text of
    Just statements -> any isConditional (concatMap subexpressions (concatMap statementExpressions statements))
    Nothing -> False

constantsFoldInResults :: Bool
constantsFoldInResults = case optimizedBody (returning "flag ? 2 + 3 : 4 * 5") of
    Just [CoreReturn (CoreConditional _ (CoreLiteral (CoreInteger 5) _) (CoreLiteral (CoreInteger 20) _) _)] -> True
    _ -> False

optimizedKeepsRecursiveCall :: Bool
optimizedKeepsRecursiveCall = case compileSource (returning "Countdown(left)") of
    Right artifacts ->
        case [coreFunctionBody function | function <- coreModuleFunctions (artifactOptimizedCore artifacts), named "Countdown" function] of
            [[CoreReturn (CoreConditional _ whenTrue (CoreLiteral (CoreInteger 0) _) _)]] -> countCalls whenTrue == 1
            _ -> False
    Left _ -> False

optimizedVerifies :: Bool
optimizedVerifies = case compileSource allFormsSource of
    Right artifacts -> verifyCore (artifactOptimizedCore artifacts) == Right (artifactOptimizedCore artifacts)
    Left _ -> False

-- ---------------------------------------------------------------- CorePrep

corePrepTests :: [(String, Bool)]
corePrepTests =
    [ ("a conditional lowers to a branch, two arms and a join", conditionalHasFourBlocks)
    , ("both arms assign the result slot and jump to the join", armsAssignAndJoin)
    , ("the result slot has exactly one mutable seed", slotHasOneSeed)
    , ("the join returns the result slot", joinReturnsSlot)
    , ("a numeric test is compared with zero before the branch", numericTestIsBooleanized)
    , ("a Boolean test is branched on directly", booleanTestHasNoComparison)
    , ("a floating result slot starts from a floating zero", floatingSlotSeed)
    , ("a Boolean result slot starts from false", booleanSlotSeed)
    , ("a call in a result is emitted only in that arm", callStaysInItsArm)
    , ("nested conditionals create one region each", nestedConditionalRegions)
    , ("truthy coalescing evaluates its fallback behind a branch", coalesceFallbackIsConditional)
    , ("a conditional in a loop condition keeps the back-edge", conditionalInLoopCondition)
    , ("every generated block id is unique", all blockIdsAreUnique (preparedFunctions allFormsSource))
    , ("every branch and jump target exists", all targetsExist (preparedFunctions allFormsSource))
    , ("CorePrep of the conditional forms survives its verifier", preparedVerifies)
    , ("a discarded call stays one result-dropping instruction", discardedCallIsEvaluated)
    , ("a discarded non-call value is computed into a temporary", discardedOperatorIsBound)
    , ("a discarded division still executes", discardedDivisionIsBound)
    , ("a conditional statement leaves no result-dropping copy", conditionalStatementHasNoEvaluate)
    , ("a discarded closure creation is bound, not dropped", discardedClosureIsBound)
    ]

preparedFunctions :: String -> [CorePrepFunction]
preparedFunctions text = case compileSource text of
    Right artifacts -> corePrepModuleFunctions (artifactCorePrep artifacts)
    Left _ -> []

preparedNamed :: String -> String -> Maybe CorePrepFunction
preparedNamed name text =
    case [function | function <- preparedFunctions text, spelling (corePrepFunctionName function) == name] of
        function : _ -> Just function
        [] -> Nothing

prepared :: String -> Maybe CorePrepFunction
prepared = preparedNamed "Evaluate"

blocksOf :: String -> [CorePrepBlock]
blocksOf = maybe [] corePrepFunctionBlocks . prepared

instructionsOf :: String -> [CorePrepInstruction]
instructionsOf = concatMap corePrepBlockInstructions . blocksOf

simple :: String
simple = returning "flag ? left : right"

conditionalHasFourBlocks :: Bool
conditionalHasFourBlocks = case blocksOf simple of
    [entry, whenTrue, whenFalse, joinBlock] ->
        corePrepBlockTerminator entry
            `isBranchTo` (corePrepBlockId whenTrue, corePrepBlockId whenFalse)
            && corePrepBlockTerminator whenTrue == CorePrepJump (corePrepBlockId joinBlock)
            && corePrepBlockTerminator whenFalse == CorePrepJump (corePrepBlockId joinBlock)
    _ -> False

isBranchTo :: CorePrepTerminator -> (Int, Int) -> Bool
isBranchTo terminator (expectedTrue, expectedFalse) = case terminator of
    CorePrepBranch _ actualTrue actualFalse -> actualTrue == expectedTrue && actualFalse == expectedFalse
    _ -> False

armsAssignAndJoin :: Bool
armsAssignAndJoin = case blocksOf simple of
    [_, whenTrue, whenFalse, _] ->
        map assignedFrom (corePrepBlockInstructions whenTrue) == [Just "left"]
            && map assignedFrom (corePrepBlockInstructions whenFalse) == [Just "right"]
    _ -> False
    where
        assignedFrom instruction = case instruction of
            CorePrepAssign target (CorePrepVariable value _) | isSlot target -> Just (spelling value)
            _ -> Nothing

isSlot :: ResolvedName -> Bool
isSlot name = "$conditional" `isPrefixOf` spelling name

slotSeeds :: [CorePrepInstruction] -> [(Type, CorePrepOperation)]
slotSeeds instructions =
    [(valueType, operation) | CorePrepBind name valueType True operation <- instructions, isSlot name]

slotHasOneSeed :: Bool
slotHasOneSeed = case blocksOf simple of
    entry : rest ->
        slotSeeds (corePrepBlockInstructions entry) == [(intType, CorePrepCopy (CorePrepLiteral (CoreInteger 0) intType))]
            && null (slotSeeds (concatMap corePrepBlockInstructions rest))
    [] -> False

joinReturnsSlot :: Bool
joinReturnsSlot = case reverse (blocksOf simple) of
    joinBlock : _ -> case corePrepBlockTerminator joinBlock of
        CorePrepReturn (CorePrepVariable name _) -> isSlot name
        _ -> False
    [] -> False

comparisons :: [CorePrepInstruction] -> Int
comparisons instructions =
    length [() | CorePrepBind _ _ _ (CorePrepPrimitive CoreNotEqual _) <- instructions]

numericTestIsBooleanized :: Bool
numericTestIsBooleanized = comparisons (instructionsOf (returning "left ? left : right")) == 1

booleanTestHasNoComparison :: Bool
booleanTestHasNoComparison = comparisons (instructionsOf simple) == 0

floatingSlotSeed :: Bool
floatingSlotSeed =
    map snd (slotSeeds (instructionsOf (body "double ratio = flag ? 1.5 : 2.5; return ratio > 2.0 ? 1 : 0;")))
        == [ CorePrepCopy (CorePrepLiteral (CoreFloating "0") doubleType)
           , CorePrepCopy (CorePrepLiteral (CoreInteger 0) intType)
           ]
    where
        doubleType = namedType "double"

booleanSlotSeed :: Bool
booleanSlotSeed =
    map snd (slotSeeds (instructionsOf (body "bool chosen = flag ? other : left > right; return chosen ? 1 : 0;")))
        == [ CorePrepCopy (CorePrepLiteral (CoreBoolean False) boolType)
           , CorePrepCopy (CorePrepLiteral (CoreInteger 0) intType)
           ]

isCall :: CorePrepInstruction -> Bool
isCall instruction = case instruction of
    CorePrepBind _ _ _ CorePrepCall {} -> True
    _ -> False

callStaysInItsArm :: Bool
callStaysInItsArm = case maybe [] corePrepFunctionBlocks (preparedNamed "Countdown" simple) of
    [entry, whenTrue, whenFalse, joinBlock] ->
        not (any isCall (corePrepBlockInstructions entry))
            && length (filter isCall (corePrepBlockInstructions whenTrue)) == 1
            && not (any isCall (corePrepBlockInstructions whenFalse))
            && not (any isCall (corePrepBlockInstructions joinBlock))
    _ -> False

branches :: [CorePrepBlock] -> Int
branches blocks = length [() | CorePrepBranch {} <- map corePrepBlockTerminator blocks]

nestedConditionalRegions :: Bool
nestedConditionalRegions =
    let blocks = blocksOf (returning "flag ? other ? left : right : 0")
     in branches blocks == 2
            && length (slotSeeds (concatMap corePrepBlockInstructions blocks)) == 2
            && length blocks == 7

coalesceFallbackIsConditional :: Bool
coalesceFallbackIsConditional =
    case blocksOf (returning "left ?: Countdown(right)") of
        [entry, whenTrue, whenFalse, _] ->
            not (any isCall (corePrepBlockInstructions entry))
                && not (any isCall (corePrepBlockInstructions whenTrue))
                && length (filter isCall (corePrepBlockInstructions whenFalse)) == 1
        _ -> False

conditionalInLoopCondition :: Bool
conditionalInLoopCondition =
    let blocks = blocksOf (body "int value = left; while (flag ? value > 0 : value > right) { value -= 1; } return value;")
        backward block = case corePrepBlockTerminator block of
            CorePrepJump target -> target < corePrepBlockId block
            _ -> False
     in branches blocks == 2 && length (filter backward blocks) == 1

evaluations :: [CorePrepInstruction] -> [CorePrepOperation]
evaluations instructions = [operation | CorePrepEvaluate operation <- instructions]

discardedCallIsEvaluated :: Bool
discardedCallIsEvaluated =
    case evaluations (instructionsOf (body "_ = Countdown(left); return 0;")) of
        [CorePrepCall {}] -> True
        _ -> False

-- `_ = !Countdown(left);` once reached later stages as a discarded bitwise
-- instruction, which only calls and closure creations may be.
discardedOperatorIsBound :: Bool
discardedOperatorIsBound =
    let instructions = instructionsOf (body "_ = !Countdown(left); return 0;")
     in null (evaluations instructions)
            && length [() | CorePrepBind _ _ _ (CorePrepPrimitive CoreBitwiseNot _) <- instructions] == 1
            && length (filter isCall instructions) == 1

discardedDivisionIsBound :: Bool
discardedDivisionIsBound =
    let instructions = instructionsOf (body "_ = 12 / left; return 0;")
     in null (evaluations instructions)
            && length [() | CorePrepBind _ _ _ (CorePrepPrimitive CoreDivide _) <- instructions] == 1

conditionalStatementHasNoEvaluate :: Bool
conditionalStatementHasNoEvaluate =
    let blocks = blocksOf (body "flag ? Countdown(left) : 0; return 0;")
        instructions = concatMap corePrepBlockInstructions blocks
     in null (evaluations instructions) && branches blocks == 1 && length (filter isCall instructions) == 1

discardedClosureIsBound :: Bool
discardedClosureIsBound =
    let instructions = instructionsOf (body "_ = \\ -> left; return 0;")
     in null (evaluations instructions)
            && length [() | CorePrepBind _ _ _ CorePrepMakeClosure {} <- instructions] == 1

blockIdsAreUnique :: CorePrepFunction -> Bool
blockIdsAreUnique function =
    let identifiers = map corePrepBlockId (corePrepFunctionBlocks function)
     in all (\identifier -> length (filter (== identifier) identifiers) == 1) identifiers

targetsExist :: CorePrepFunction -> Bool
targetsExist function =
    let blocks = corePrepFunctionBlocks function
        identifiers = map corePrepBlockId blocks
        targets block = case corePrepBlockTerminator block of
            CorePrepJump target -> [target]
            CorePrepBranch _ whenTrue whenFalse -> [whenTrue, whenFalse]
            _ -> []
     in all (`elem` identifiers) (concatMap targets blocks)

preparedVerifies :: Bool
preparedVerifies = case compileSource allFormsSource of
    Right artifacts -> verifyCorePrep (artifactCorePrep artifacts) == Right (artifactCorePrep artifacts)
    Left _ -> False
