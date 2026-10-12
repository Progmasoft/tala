-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Vertical tests for assignments and increments used as values:
@target = value@, @target op= value@, @++target@, @target++@ and
@target--@ in operand position.

Core expressions never store into a local, so these source forms lower to
statements plus a store-free read. The shape tests pin that lowering. The
evaluation tests are the semantic oracle: each one states the value a source
program must compute under left-to-right evaluation and runs the reference
evaluator of "CoreInterpreter" on the Core the Desugarer produced and again
on the Core the optimizer left, so a lowering that reorders a read and a
store, or an optimization that does, fails with a wrong number.
-}
module AssignmentExpressionTests (assignmentExpressionTests) where

import CoreInterpreter
import Data.List (isInfixOf, isPrefixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Specialization

assignmentExpressionTests :: [(String, Bool)]
assignmentExpressionTests =
    parserTests
        ++ typeTests
        ++ loweringTests
        ++ evaluationTests
        ++ pipelineTests

-- ---------------------------------------------------------------- sources

-- | One method with immutable parameters; tests declare the locals they store into.
body :: String -> String
body statements =
    unlines
        [ "class Program {"
        , "    public static int Evaluate(_ bool flag, _ bool other, _ int left, _ int right) {"
        , "        " ++ statements
        , "    }"
        , "    public static int Next() { return 7; }"
        , "    public static int Twice(_ int value) { return value + value; }"
        , "    public static int Minus(_ int first, _ int second) { return first - second; }"
        , "    public static int Pick(_ int first, _ int second, _ int third) { return first * 100 + second * 10 + third; }"
        , "    public static void Touch() { }"
        , "}"
        ]

returning :: String -> String
returning expression = body ("int a = left; int b = right; return " ++ expression ++ ";")

parseSource :: String -> Either [Diagnostic] ParsedAST
parseSource text = do
    tokens <- runLexer defaultLexer (LexerInput "assignment.tala" text)
    runParser defaultParser (ParserInput "assignment.tala" tokens)

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

-- | The expression returned by 'returning'.
returned :: String -> Maybe (Expression Identifier ())
returned expression = case firstStatements (returning expression) of
    Just [_, _, ReturnStatement _ value] -> value
    _ -> Nothing

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "assignment.tala" text)

accepted :: String -> Bool
accepted text = either (const False) (const True) (compileSource text)

rejectedWith :: String -> String -> Bool
rejectedWith code text = case compileSource text of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

isName :: String -> Expression Identifier () -> Bool
isName expected expression = case expression of
    NameExpression _ (Identifier actual) () -> actual == expected
    _ -> False

isInteger :: Integer -> Expression Identifier () -> Bool
isInteger expected expression = case expression of
    LiteralExpression _ (IntegerLiteral actual) () -> actual == expected
    _ -> False

-- ---------------------------------------------------------------- parser

parserTests :: [(String, Bool)]
parserTests =
    [ ("an assignment in operand position is an assignment expression", assignmentParses)
    , ("assignment expressions group to the right", assignmentIsRightAssociative)
    , ("a statement assignment keeps its statement node", statementKeepsItsNode)
    , ("a chained statement assignment nests an assignment expression", chainedStatementNests)
    , ("a binding initializer may be an assignment expression", bindingInitializerNests)
    , ("every compound operator parses as an assignment expression", all compoundParses compoundOperators)
    , ("a simple assignment groups a compound assignment on its right", simpleGroupsCompound)
    , ("assignment binds more weakly than a conditional", assignmentIsWeakerThanConditional)
    , ("assignment binds more weakly than logical OR", assignmentIsWeakerThanLogicalOr)
    , ("an assignment is a call argument", assignmentIsCallArgument)
    , ("a parenthesized assignment is an operand of a binary operator", parenthesizedAssignmentIsOperand)
    , ("an unparenthesized assignment cannot be a conditional result", parseRejected (returning "flag ? a = 1 : 2"))
    , ("an unparenthesized assignment cannot follow a binary operator", parseRejected (returning "1 + a = 2"))
    , ("a call is not an assignment target in an expression", parseRejected (returning "Next() = 1"))
    , ("prefix increment parses as the prefix form", incrementParses "++a" True)
    , ("postfix increment parses as the postfix form", incrementParses "a++" False)
    , ("a double dash after a name starts a comment, not a decrement", doubleDashIsComment)
    , ("the old postfix decrement spelling leaves only the name before the comment", oldPostfixSpellingIsName)
    , ("the old prefix decrement spelling is entirely a comment", oldPrefixSpellingIsComment)
    , ("a postfix increment is the left operand of a following addition", postfixThenAddition)
    , ("a prefix increment is an operand of unary minus", prefixUnderNegation)
    , ("a statement increment keeps its statement node", incrementStatementKeepsItsNode)
    , ("a statement compound assignment keeps its statement node", compoundStatementKeepsItsNode)
    , ("prefix increment of a literal has no storage", parseRejectedWith "TAP0028" (returning "++10"))
    , ("prefix increment of a parenthesized value has no storage", parseRejectedWith "TAP0028" (returning "++(a)"))
    , ("postfix increment of a sum has no storage", parseRejectedWith "TAP0028" (returning "(a + b)++"))
    , ("postfix increment of a call has no storage", parseRejectedWith "TAP0028" (returning "Next()++"))
    , ("postfix increment of a literal has no storage", parseRejectedWith "TAP0028" (returning "10++"))
    , ("an increment result is not a storage location", parseRejected (returning "a++++"))
    , ("discard is not a value in a binding", parseRejectedWith "TAP0032" (body "int value = (_ = Next()); return value;"))
    , ("discard is not a value in a return", parseRejectedWith "TAP0032" (returning "_ = 1"))
    , ("discard is not a value in a call argument", parseRejectedWith "TAP0032" (returning "Twice(_ = 1)"))
    , ("the discard statement itself still parses", discardStatementStillParses)
    ,
        ( "null-coalescing assignment is still reported as unimplemented"
        , parseRejectedWith "TAP0031" (body "int a = 0; a ??= 1; return a;")
        )
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

assignmentParses :: Bool
assignmentParses = case returned "a = 5" of
    Just (AssignmentExpression _ Nothing (Identifier "a") value ()) -> isInteger 5 value
    _ -> False

assignmentIsRightAssociative :: Bool
assignmentIsRightAssociative = case returned "a = b = 5" of
    Just (AssignmentExpression _ Nothing (Identifier "a") (AssignmentExpression _ Nothing (Identifier "b") value ()) ()) ->
        isInteger 5 value
    _ -> False

statementKeepsItsNode :: Bool
statementKeepsItsNode = case firstStatements (body "int a = 0; a = 5; return a;") of
    Just [_, AssignmentStatement _ (Identifier "a") () value, _] -> isInteger 5 value
    _ -> False

chainedStatementNests :: Bool
chainedStatementNests = case firstStatements (body "int a = 0; int b = 0; a = b = 10; return a;") of
    Just [_, _, AssignmentStatement _ (Identifier "a") () (AssignmentExpression _ Nothing (Identifier "b") value ()), _] ->
        isInteger 10 value
    _ -> False

bindingInitializerNests :: Bool
bindingInitializerNests = case firstStatements (body "int a = 0; int b = a = 3; return b;") of
    Just [_, BindingStatement _ _ _ (Identifier "b") () (AssignmentExpression _ Nothing (Identifier "a") value ()), _] ->
        isInteger 3 value
    _ -> False

compoundParses :: (String, BinaryOperator) -> Bool
compoundParses (operatorText, operator) = case returned ("a " ++ operatorText ++ " b") of
    Just (AssignmentExpression _ (Just actual) (Identifier "a") value ()) -> actual == operator && isName "b" value
    _ -> False

simpleGroupsCompound :: Bool
simpleGroupsCompound = case returned "a = b += 2" of
    Just (AssignmentExpression _ Nothing (Identifier "a") (AssignmentExpression _ (Just Add) (Identifier "b") value ()) ()) ->
        isInteger 2 value
    _ -> False

assignmentIsWeakerThanConditional :: Bool
assignmentIsWeakerThanConditional = case returned "a = flag ? 1 : 2" of
    Just (AssignmentExpression _ Nothing (Identifier "a") (ConditionalExpression _ condition first second ()) ()) ->
        isName "flag" condition && isInteger 1 first && isInteger 2 second
    _ -> False

assignmentIsWeakerThanLogicalOr :: Bool
assignmentIsWeakerThanLogicalOr = case firstStatements (body "bool seen = false; return (seen = flag || other) ? 1 : 0;") of
    Just
        [ _
            , ReturnStatement _ (Just (ConditionalExpression _ (AssignmentExpression _ Nothing (Identifier "seen") value ()) _ _ ()))
            ] ->
            case value of
                BinaryExpression _ LogicalOr left right () -> isName "flag" left && isName "other" right
                _ -> False
    _ -> False

assignmentIsCallArgument :: Bool
assignmentIsCallArgument = case returned "Twice(a = 3)" of
    Just (CallExpression _ callee [AssignmentExpression _ Nothing (Identifier "a") value ()] ()) ->
        isName "Twice" callee && isInteger 3 value
    _ -> False

parenthesizedAssignmentIsOperand :: Bool
parenthesizedAssignmentIsOperand = case returned "a + (a = 5)" of
    Just (BinaryExpression _ Add left (AssignmentExpression _ Nothing (Identifier "a") value ()) ()) ->
        isName "a" left && isInteger 5 value
    _ -> False

incrementParses :: String -> Bool -> Bool
incrementParses expression isPrefix = case returned expression of
    Just (IncrementExpression _ actualPrefix (Identifier "a") ()) -> actualPrefix == isPrefix
    _ -> False

-- `a--; return a;` is the name `a` followed by a comment. The name is then
-- the last thing in the block, which reads it as the block's final
-- expression: nothing is subtracted and no diagnostic is produced.
oldPostfixSpellingIsName :: Bool
oldPostfixSpellingIsName = case firstStatements (body "int a = 1; a--; return a;") of
    Just [BindingStatement {}, ExpressionStatement _ value False] -> isName "a" value
    _ -> False

oldPrefixSpellingIsComment :: Bool
oldPrefixSpellingIsComment = case firstStatements (body "int a = 1; --a; return a;") of
    Just [BindingStatement {}] -> True
    _ -> False

-- The language has no decrement operator, so everything from `--` to the end
-- of the line is a comment and the statement before it is all that remains.
doubleDashIsComment :: Bool
doubleDashIsComment = case firstStatements (body "return left;-- - right--;") of
    Just [ReturnStatement _ (Just value)] -> isName "left" value
    _ -> False

postfixThenAddition :: Bool
postfixThenAddition = case returned "a+++b" of
    Just (BinaryExpression _ Add (IncrementExpression _ False (Identifier "a") ()) right ()) -> isName "b" right
    _ -> False

prefixUnderNegation :: Bool
prefixUnderNegation = case returned "-++a" of
    Just (UnaryExpression _ UnaryNegate (IncrementExpression _ True (Identifier "a") ()) ()) -> True
    _ -> False

incrementStatementKeepsItsNode :: Bool
incrementStatementKeepsItsNode = case firstStatements (body "int a = 0; a++; ++a; return a;") of
    Just [_, IncrementStatement _ (Identifier "a") (), IncrementStatement _ (Identifier "a") (), _] -> True
    _ -> False

compoundStatementKeepsItsNode :: Bool
compoundStatementKeepsItsNode = case firstStatements (body "int a = 0; a += 2; return a;") of
    Just [_, CompoundAssignmentStatement _ Add (Identifier "a") () value, _] -> isInteger 2 value
    _ -> False

discardStatementStillParses :: Bool
discardStatementStillParses = case firstStatements (body "_ = Next(); return 0;") of
    Just [DiscardStatement _ _, _] -> True
    _ -> False

-- ---------------------------------------------------------------- type checker

typeTests :: [(String, Bool)]
typeTests =
    [ ("an assignment expression is accepted where its target type fits", accepted (returning "(a = 5) + b"))
    , ("a chained assignment is accepted", accepted (body "int a = 0; int b = 0; a = b = left; return a + b;"))
    , ("a compound assignment expression is accepted", accepted (returning "(a += 5) * 2"))
    , ("a Boolean assignment expression is accepted", accepted (body "bool seen = false; return (seen = flag) ? 1 : 0;"))
    , ("an increment expression is accepted", accepted (returning "a++ + ++b"))
    , ("an assignment expression statement is not a pure value statement", accepted (body "int a = 0; (a = 5); return a;"))
    ,
        ( "an assignment in a while condition is accepted"
        , accepted (body "int a = left; int v = 0; while ((v = (a -= 1)) > 0) { } return v;")
        )
    , ("an assignment yields the target type, not the value type", yieldsTargetType)
    ,
        ( "a statement assignment types its literal from the target"
        , accepted (body "long wide = 1; wide = 5; return wide > 4 ? 1 : 0;")
        )
    ,
        ( "a literal that does not fit the target is still rejected"
        , not (accepted (body "ubyte small = 1; small = 300; return 0;"))
        )
    , ("assigning to a parameter is rejected", rejectedWith "TAT0003" (body "return (left = 1);"))
    , ("assigning to a final binding is rejected", rejectedWith "TAT0003" (body "final int a = 1; return (a = 2);"))
    ,
        ( "a compound assignment to a final binding is rejected"
        , rejectedWith "TAT0003" (body "final int a = 1; return (a += 2);")
        )
    , ("a value of the wrong type is rejected", rejectedWith "TAT0004" (body "int a = 0; return (a = flag) ? 1 : 0;"))
    , ("an assignment result of the wrong type is rejected by its receiver", resultTypeIsChecked)
    ,
        ( "a compound operator that does not apply is rejected"
        , rejectedWith "TAT0012" (body "bool seen = false; return (seen += flag) ? 1 : 0;")
        )
    ,
        ( "a compound result that is not the target type is rejected"
        , rejectedWith "TAT0035" (body "double ratio = 7.5; return (ratio //= 2.0) > 1.0 ? 1 : 0;")
        )
    , ("incrementing a final binding is rejected", rejectedWith "TAT0022" (body "final int a = 1; return a++;"))
    , ("incrementing a parameter is rejected", rejectedWith "TAT0022" (body "return ++left;"))
    , ("incrementing a Boolean is rejected", rejectedWith "TAT0024" (body "bool seen = false; return seen++ ? 1 : 0;"))
    , ("an assignment to an undeclared name is rejected", not (accepted (body "return (missing = 1);")))
    , ("an increment of an undeclared name is rejected", not (accepted (body "return missing++;")))
    , ("the value of an assignment is checked like any other", not (accepted (body "int a = 0; return (a = absent);")))
    ]

-- The stored value is read back from the target, so the expression has the
-- target type even when the right operand is a literal that could have been
-- typed otherwise.
yieldsTargetType :: Bool
yieldsTargetType = case compileSource (body "long wide = 1; long copy = (wide = 5); return copy > 4 ? 1 : 0;") of
    Right _ -> True
    Left _ -> False

resultTypeIsChecked :: Bool
resultTypeIsChecked =
    not (accepted (body "long wide = 1; int narrow = 0; narrow = (wide += 1); return narrow;"))

-- ---------------------------------------------------------------- lowering

loweringTests :: [(String, Bool)]
loweringTests =
    [ ("an assignment expression lowers to a store and a read of the target", assignmentLowers)
    , ("a prefix increment lowers to a store and a read of the target", prefixLowers)
    , ("a postfix increment keeps the previous value in a temporary", postfixLowers)
    , ("a later store binds an earlier read of the same local", earlierReadIsBound)
    , ("a later store binds an earlier call", earlierCallIsBound)
    , ("a later store does not bind a literal", literalIsNotBound)
    , ("a later store does not bind a read of another local", otherLocalIsNotBound)
    , ("operands after the store are not bound", laterOperandIsNotBound)
    , ("a compound assignment keeps its earlier target value when its operand stores", compoundKeepsTarget)
    , ("a compound assignment without a storing operand has no temporary", compoundHasNoTemporary)
    , ("a store in a conditional result becomes a statement inside that branch", conditionalArmIsLazy)
    , ("a conditional whose test stores stays a Core conditional", conditionalTestStaysExpression)
    , ("a store on the right of && runs under the left operand", logicalAndIsLazy)
    , ("a store on the right of || runs only when the left operand is false", logicalOrIsLazy)
    , ("a store in a coalescing fallback runs under the false branch", coalesceFallbackIsLazy)
    , ("a while condition that stores is tested at the top of the body", whileConditionMoves)
    , ("a while condition without a store stays in the loop header", whileConditionStays)
    , ("a for condition that stores keeps the update clause", forConditionMoves)
    , ("a do/while condition that stores is skipped on the first pass only", doWhileConditionMoves)
    , ("a do/while condition without a store stays a Core do/while", doWhileConditionStays)
    , ("an assignment expression statement leaves no evaluation statement", expressionStatementHasNoEvaluate)
    , ("a discarded assignment leaves no evaluation statement", discardedAssignmentHasNoEvaluate)
    , ("a discarded call is still an evaluation statement", discardedCallIsEvaluated)
    , ("generated temporaries are immutable except result slots", temporariesAreImmutable)
    ]

-- | Unoptimized Core body of the method named @Evaluate@.
loweredBody :: String -> Maybe [CoreStatement]
loweredBody text = case compileSource text of
    Right artifacts -> functionBody "Evaluate" (artifactCore artifacts)
    Left _ -> Nothing

functionBody :: String -> CoreModule -> Maybe [CoreStatement]
functionBody name moduleValue =
    case [coreFunctionBody function | function <- coreModuleFunctions moduleValue, spelling (coreFunctionName function) == name] of
        statements : _ -> Just statements
        [] -> Nothing

spelling :: ResolvedName -> String
spelling = identifierText . resolvedSpelling

-- | The statements after the two bindings that 'returning' declares.
loweredReturning :: String -> Maybe [CoreStatement]
loweredReturning expression = drop 2 <$> loweredBody (returning expression)

isRead :: String -> CoreExpression -> Bool
isRead expected expression = case expression of
    CoreVariable name _ -> spelling name == expected
    _ -> False

isGenerated :: String -> ResolvedName -> Bool
isGenerated prefix name = prefix `isPrefixOf` spelling name

isLiteral :: Integer -> CoreExpression -> Bool
isLiteral expected expression = case expression of
    CoreLiteral (CoreInteger actual) _ -> actual == expected
    _ -> False

assignmentLowers :: Bool
assignmentLowers = case loweredReturning "a = 5" of
    Just [CoreAssign target value, CoreReturn result] -> spelling target == "a" && isLiteral 5 value && isRead "a" result
    _ -> False

prefixLowers :: Bool
prefixLowers = case loweredReturning "++a" of
    Just [CoreAssign target (CorePrimitive CoreAdd [from, one] _), CoreReturn result] ->
        spelling target == "a" && isRead "a" from && isLiteral 1 one && isRead "a" result
    _ -> False

postfixLowers :: Bool
postfixLowers = case loweredReturning "a++" of
    Just
        [ CoreBind (CoreBinding previous _ False initial)
            , CoreAssign target (CorePrimitive CoreAdd [CoreVariable from _, one] _)
            , CoreReturn (CoreVariable result _)
            ] ->
            isGenerated "$previous" previous
                && isRead "a" initial
                && spelling target == "a"
                && from == previous
                && isLiteral 1 one
                && result == previous
    _ -> False

earlierReadIsBound :: Bool
earlierReadIsBound = case loweredReturning "a + (a = 5)" of
    Just
        [ CoreBind (CoreBinding held _ False initial)
            , CoreAssign target _
            , CoreReturn (CorePrimitive CoreAdd [CoreVariable left _, right] _)
            ] ->
            isGenerated "$operand" held && isRead "a" initial && spelling target == "a" && left == held && isRead "a" right
    _ -> False

earlierCallIsBound :: Bool
earlierCallIsBound = case loweredReturning "Next() + (a = 5)" of
    Just
        [ CoreBind (CoreBinding held _ False CoreApply {})
            , CoreAssign _ _
            , CoreReturn (CorePrimitive CoreAdd [CoreVariable left _, _] _)
            ] ->
            isGenerated "$operand" held && left == held
    _ -> False

literalIsNotBound :: Bool
literalIsNotBound = case loweredReturning "1 + (a = 5)" of
    Just [CoreAssign _ _, CoreReturn (CorePrimitive CoreAdd [left, right] _)] -> isLiteral 1 left && isRead "a" right
    _ -> False

otherLocalIsNotBound :: Bool
otherLocalIsNotBound = case loweredReturning "b + (a = 5)" of
    Just [CoreAssign _ _, CoreReturn (CorePrimitive CoreAdd [left, right] _)] -> isRead "b" left && isRead "a" right
    _ -> False

laterOperandIsNotBound :: Bool
laterOperandIsNotBound = case loweredReturning "(a = 5) + a" of
    Just [CoreAssign _ _, CoreReturn (CorePrimitive CoreAdd [left, right] _)] -> isRead "a" left && isRead "a" right
    _ -> False

compoundKeepsTarget :: Bool
compoundKeepsTarget = case loweredBody (body "int a = left; a += (a = right); return a;") of
    Just
        [ _
            , CoreBind (CoreBinding previous _ False initial)
            , CoreAssign inner _
            , CoreAssign outer (CorePrimitive CoreAdd [CoreVariable from _, operand] _)
            , _
            ] ->
            isGenerated "$target" previous
                && isRead "a" initial
                && spelling inner == "a"
                && spelling outer == "a"
                && from == previous
                && isRead "a" operand
    _ -> False

compoundHasNoTemporary :: Bool
compoundHasNoTemporary = case loweredBody (body "int a = left; int b = 0; a += (b = right); return a;") of
    Just [_, _, CoreAssign inner _, CoreAssign outer (CorePrimitive CoreAdd [from, operand] _), _] ->
        spelling inner == "b" && spelling outer == "a" && isRead "a" from && isRead "b" operand
    _ -> False

conditionalArmIsLazy :: Bool
conditionalArmIsLazy = case loweredReturning "flag ? (a = 1) : b" of
    Just
        [ CoreBind (CoreBinding slot _ True _)
            , CoreIf condition [CoreAssign stored _, CoreAssign first _] [CoreAssign second value]
            , CoreReturn (CoreVariable result _)
            ] ->
            isGenerated "$selected" slot
                && isRead "flag" condition
                && spelling stored == "a"
                && first == slot
                && second == slot
                && isRead "b" value
                && result == slot
    _ -> False

conditionalTestStaysExpression :: Bool
conditionalTestStaysExpression = case loweredReturning "(a = 0) ? 1 : 2" of
    Just [CoreAssign target _, CoreReturn (CoreConditional condition _ _ _)] -> spelling target == "a" && isRead "a" condition
    _ -> False

logicalAndIsLazy :: Bool
logicalAndIsLazy = case loweredBody (body "int a = 0; bool both = flag && (a = 5) > 0; return a;") of
    Just
        [ _
            , CoreBind (CoreBinding slot _ True initial)
            , CoreIf left [CoreAssign stored _, CoreIf _ [CoreAssign set _] []] []
            , CoreBind _
            , _
            ] ->
            isGenerated "$logical" slot
                && initial == CoreLiteral (CoreBoolean False) boolType
                && isRead "flag" left
                && spelling stored == "a"
                && set == slot
    _ -> False

logicalOrIsLazy :: Bool
logicalOrIsLazy = case loweredBody (body "int a = 0; bool either = flag || (a = 5) > 0; return a;") of
    Just
        [ _
            , CoreBind (CoreBinding slot _ True _)
            , CoreIf left [CoreAssign set _] [CoreAssign stored _, CoreIf _ [CoreAssign later _] []]
            , CoreBind _
            , _
            ] ->
            isGenerated "$logical" slot && isRead "flag" left && set == slot && spelling stored == "a" && later == slot
    _ -> False

coalesceFallbackIsLazy :: Bool
coalesceFallbackIsLazy = case loweredReturning "b ?: (a = 9)" of
    Just
        [ CoreBind (CoreBinding subject _ False initial)
            , CoreBind (CoreBinding slot _ True _)
            , CoreIf (CoreVariable test _) [CoreAssign kept (CoreVariable keptValue _)] [CoreAssign stored _, CoreAssign replaced _]
            , CoreReturn (CoreVariable result _)
            ] ->
            isGenerated "$coalesce" subject
                && isRead "b" initial
                && isGenerated "$selected" slot
                && test == subject
                && kept == slot
                && keptValue == subject
                && spelling stored == "a"
                && replaced == slot
                && result == slot
    _ -> False

alwaysTrue :: CoreExpression
alwaysTrue = CoreLiteral (CoreBoolean True) boolType

whileConditionMoves :: Bool
whileConditionMoves = case loweredBody (body "int a = left; int v = 0; while ((v = a) > 0) { a -= 1; } return v;") of
    Just [_, _, CoreWhile header (CoreAssign stored _ : CoreIf _ [] [CoreBreak] : loopBody), _] ->
        header == alwaysTrue && spelling stored == "v" && length loopBody == 1
    _ -> False

whileConditionStays :: Bool
whileConditionStays = case loweredBody (body "int a = left; while (a > 0) { a -= 1; } return a;") of
    Just [_, CoreWhile (CorePrimitive CoreGreaterThan _ _) [_], _] -> True
    _ -> False

forConditionMoves :: Bool
forConditionMoves = case loweredBody (body "int v = 0; for (int i = 0; (v = i) < left; i++) { } return v;") of
    Just [_, _, CoreFor header [CoreAssign stored _, CoreIf _ [] [CoreBreak]] [CoreAssign updated _], _] ->
        header == alwaysTrue && spelling stored == "v" && spelling updated == "i"
    _ -> False

doWhileConditionMoves :: Bool
doWhileConditionMoves = case loweredBody (body "int a = left; int n = 0; do { n += 1; } while ((a -= 1) > 0); return n;") of
    Just
        [ _
            , _
            , CoreBind (CoreBinding first _ True initial)
            , CoreWhile header [CoreIf (CoreVariable test _) [CoreAssign cleared _] [CoreAssign stored _, CoreIf _ [] [CoreBreak]], _]
            , _
            ] ->
            isGenerated "$first" first
                && initial == alwaysTrue
                && header == alwaysTrue
                && test == first
                && cleared == first
                && spelling stored == "a"
    _ -> False

doWhileConditionStays :: Bool
doWhileConditionStays = case loweredBody (body "int a = left; do { a -= 1; } while (a > 0); return a;") of
    Just [_, CoreDoWhile [_] (CorePrimitive CoreGreaterThan _ _), _] -> True
    _ -> False

evaluations :: [CoreStatement] -> Int
evaluations statements = length [() | CoreEvaluate _ <- statements]

expressionStatementHasNoEvaluate :: Bool
expressionStatementHasNoEvaluate = case loweredBody (body "int a = 0; (a = 5); a++; return a;") of
    Just statements -> evaluations statements == 0 && length statements == 4
    Nothing -> False

discardedAssignmentHasNoEvaluate :: Bool
discardedAssignmentHasNoEvaluate = case loweredBody (body "int a = 0; _ = (a = 5); _ = a++; return a;") of
    Just statements -> evaluations statements == 0
    Nothing -> False

discardedCallIsEvaluated :: Bool
discardedCallIsEvaluated = case loweredBody (body "int a = 0; _ = Twice(a = 5); return a;") of
    Just [_, CoreAssign _ _, CoreEvaluate CoreApply {}, _] -> True
    _ -> False

temporariesAreImmutable :: Bool
temporariesAreImmutable = all immutableTemporaries (map fst evaluationCases)
    where
        immutableTemporaries statements = case compileSource (body statements) of
            Right artifacts -> all acceptable (moduleBindings (artifactCore artifacts))
            Left _ -> False
        acceptable binding =
            let name = coreBindingName binding
                slot = any (`isGenerated` name) ["$selected", "$logical", "$first"]
                held = any (`isGenerated` name) ["$operand", "$previous", "$target", "$coalesce", "$pattern"]
             in if held then not (coreBindingMutable binding) else not slot || coreBindingMutable binding

moduleStatements :: CoreModule -> [CoreStatement]
moduleStatements = concatMap (concatMap nested . coreFunctionBody) . coreModuleFunctions
    where
        nested statement =
            statement : case statement of
                CoreIf _ whenTrue whenFalse -> concatMap nested (whenTrue ++ whenFalse)
                CoreWhile _ loopBody -> concatMap nested loopBody
                CoreDoWhile loopBody _ -> concatMap nested loopBody
                CoreFor _ loopBody update -> concatMap nested (loopBody ++ update)
                _ -> []

moduleBindings :: CoreModule -> [CoreBinding]
moduleBindings moduleValue = [binding | CoreBind binding <- moduleStatements moduleValue]

-- ---------------------------------------------------------------- evaluation

{- | Source bodies with the arguments to run them on and the value each run
must return. The expected values follow from left-to-right evaluation of
operands and from the Spec rules that an assignment yields the stored value,
a prefix form the new value and a postfix form the previous one.
-}
evaluationCases :: [(String, [((Bool, Bool, Integer, Integer), Integer)])]
evaluationCases =
    [ ("int a = left; int b = (a = right); return a * 10 + b;", [(plain 3 4, 44), (plain 0 9, 99)])
    , ("int a = 0; int b = 0; a = b = left; return a * 10 + b;", [(plain 3 0, 33)])
    , ("int a = 1; int b = 2; int c = 3; a = b = c = left; return a + b + c;", [(plain 5 0, 15)])
    , ("int a = left; return a = right;", [(plain 3 4, 4)])
    , ("int a = left; return a + (a = right);", [(plain 3 4, 7), (plain 10 1, 11)])
    , ("int a = left; return (a = right) + a;", [(plain 3 4, 8)])
    , ("int a = left; return (a + 1) * (a = right);", [(plain 3 4, 16)])
    , ("int a = left; return a + (a = right) + a;", [(plain 3 4, 11)])
    , ("int a = left; return a - (a = right) - a;", [(plain 10 3, 4)])
    , ("int a = left; return (a = 2) * (a = 3) + a;", [(plain 0 0, 9)])
    , ("int a = left; return -(a = right) + a;", [(plain 3 4, 0)])
    , ("int a = left; int b = right; return (a = b) + (b = 1) + a + b;", [(plain 3 4, 10)])
    , ("int a = left; return a++ + a;", [(plain 3 0, 7)])
    , ("int a = left; return ++a + a;", [(plain 3 0, 8)])
    , ("int a = left; return a++ + a++;", [(plain 3 0, 7)])
    , ("int a = left; return ++a * ++a;", [(plain 3 0, 20)])
    , ("int a = left; int b = a++; return a * 10 + b;", [(plain 3 0, 43)])
    , ("int a = left; int b = ++a; return a * 10 + b;", [(plain 3 0, 44)])
    , ("int a = left; return a + a++ + a;", [(plain 3 0, 10)])
    , ("int a = left; int total = (a += right); return a + total;", [(plain 3 4, 14)])
    , ("int a = left; a += (a = right); return a;", [(plain 3 4, 7)])
    , ("int a = left; a -= (a = right); return a;", [(plain 10 4, 6)])
    , ("int a = left; return (a += 1) * (a += 2);", [(plain 3 0, 24)])
    , ("int a = left; return a + (a += right) + a;", [(plain 3 4, 17)])
    , ("int a = left; a *= a++; return a;", [(plain 3 0, 9)])
    , ("int a = left; int b = right; a = b += 2; return a * 10 + b;", [(plain 0 4, 66)])
    , ("int a = left; int b = right; a += b -= 1; return a * 10 + b;", [(plain 3 4, 63)])
    , ("int a = left; return (a <<= 2) + a;", [(plain 3 0, 24)])
    , ("int a = left; return (a %= right) + a;", [(plain 17 5, 4)])
    , ("int a = left; return (a &= right) | (a ^= 1);", [(plain 6 3, 3)])
    , ("int a = left; return Twice(a = right) + a;", [(plain 3 4, 12)])
    , ("int a = left; return Twice(a) + (a = right);", [(plain 3 4, 10)])
    , ("int a = left; return Minus(a, a = right);", [(plain 10 3, 7)])
    , ("int a = left; return Minus(a = right, a);", [(plain 10 3, 0)])
    , ("int a = left; return Minus(a++, a++);", [(plain 5 0, -1)])
    , ("int a = left; return Pick(a, a = right, a);", [(plain 1 2, 122)])
    , ("int a = left; return Pick(a++, a++, a);", [(plain 1 0, 123)])
    , ("int a = left; return Pick(Twice(a), a += 1, Twice(a));", [(plain 1 0, 224)])
    ,
        ( "int a = left; int r = flag ? (a = 1) : (a = 2); return a * 10 + r;"
        , [(flags True False 7 0, 11), (flags False False 7 0, 22)]
        )
    ,
        ( "int a = left; int r = flag ? (a = 100) : right; return a + r;"
        , [(flags True False 3 4, 200), (flags False False 3 4, 7)]
        )
    ,
        ( "int a = left; int r = flag ? right : (a = 100); return a + r;"
        , [(flags True False 3 4, 7), (flags False False 3 4, 200)]
        )
    , ("int a = left; int r = (a = right) ? a + 1 : -1; return r;", [(plain 3 4, 5), (plain 3 0, -1)])
    ,
        ( "int a = left; int r = flag ? (other ? (a = 1) : (a = 2)) : (a = 3); return a * 10 + r;"
        , [(flags True True 9 0, 11), (flags True False 9 0, 22), (flags False True 9 0, 33)]
        )
    , ("int a = left; return a + (flag ? (a = right) : 0) + a;", [(flags True False 3 4, 11), (flags False False 3 4, 6)])
    ,
        ( "int a = 0; bool r = flag && (a = 5) > 0; return a + (r ? 100 : 0);"
        , [(flags True False 0 0, 105), (flags False False 0 0, 0)]
        )
    ,
        ( "int a = 9; bool r = flag && (a = 0) > 0; return a + (r ? 100 : 0);"
        , [(flags True False 0 0, 0), (flags False False 0 0, 9)]
        )
    ,
        ( "int a = 0; bool r = flag || (a = 5) > 3; return a + (r ? 100 : 0);"
        , [(flags True False 0 0, 100), (flags False False 0 0, 105)]
        )
    , ("int a = 0; bool r = flag || (a = 5) > 7; return a + (r ? 100 : 0);", [(flags False False 0 0, 5)])
    ,
        ( "int a = 0; bool r = (a = left) > 0 && (a = right) > 0; return a + (r ? 100 : 0);"
        , [(plain 3 4, 104), (plain 0 4, 0), (plain 3 0, 0)]
        )
    ,
        ( "int a = 0; int b = 0; bool r = flag && (a = 1) > 0 && (b = 2) > 0; return a * 10 + b + (r ? 100 : 0);"
        , [(flags True False 0 0, 112), (flags False False 0 0, 0)]
        )
    ,
        ( "int a = 0; bool r = flag && other || (a = 5) > 0; return a + (r ? 100 : 0);"
        , [(flags True True 0 0, 100), (flags True False 0 0, 105)]
        )
    , ("int a = 0; int r = left ?: (a = 9); return a * 100 + r;", [(plain 4 0, 4), (plain 0 0, 909)])
    , ("int a = left; int r = (a = right) ?: 7; return a * 10 + r;", [(plain 3 4, 44), (plain 3 0, 7)])
    , ("int a = 0; if ((a = left) > 2) { return a; } return -a;", [(plain 5 0, 5), (plain 1 0, -1)])
    ,
        ( "int n = 0; int sum = 0; int v = 0; while ((v = n++) < left) { sum += v; } return sum * 10 + n;"
        , [(plain 4 0, 65), (plain 0 0, 1)]
        )
    ,
        ( "int n = 0; int sum = 0; int v = 0; while ((v = n++) < left) { if (v == 2) { continue; } sum += v; } return sum;"
        , [(plain 4 0, 4)]
        )
    ,
        ( "int n = 0; int sum = 0; int v = 0; while ((v = n++) < left) { if (v == 2) { break; } sum += v; } return sum * 10 + n;"
        , [(plain 4 0, 13)]
        )
    , ("int n = 0; int count = 0; while (n++ < left) { count++; } return count * 10 + n;", [(plain 3 0, 34)])
    , ("int n = 0; int count = 0; while (++n < left) { count++; } return count * 10 + n;", [(plain 3 0, 23)])
    ,
        ( "int n = left; int count = 0; do { count++; } while ((n = n - 1) > 0); return count;"
        , [(plain 3 0, 3), (plain 0 0, 1)]
        )
    ,
        ( "int n = left; int count = 0; do { count++; if (count == 12) { continue; } count += 10; } while ((n -= 1) > 0); return count;"
        , [(plain 3 0, 23)]
        )
    ,
        ( "int n = left; int count = 0; do { count++; if (count == 2) { break; } } while ((n -= 1) > 0); return count * 10 + n;"
        , [(plain 5 0, 24)]
        )
    , ("int n = 0; int count = 0; do { count++; } while (n++ < left); return count * 10 + n;", [(plain 3 0, 44)])
    ,
        ( "int sum = 0; int v = 0; for (int i = 0; (v = i * 2) < left; i++) { if (v == 2) { continue; } sum += v; } return sum;"
        , [(plain 7 0, 10)]
        )
    ,
        ( "int sum = 0; int v = 0; for (int i = 0; (v = i * 2) < left; i++) { if (v == 4) { break; } sum += v; } return sum * 10 + v;"
        , [(plain 7 0, 24)]
        )
    , ("int sum = 0; for (int i = 0; i++ < left; i += 0) { sum += i; } return sum;", [(plain 3 0, 6)])
    ,
        ( "int total = 0; for (int i = 0; i < left; i += 1) { int j = 0; while ((j += 1) < 3) { total += i * j; } } return total;"
        , [(plain 3 0, 9)]
        )
    , ("int a = left; (a = right); return a;", [(plain 3 4, 4)])
    , ("int a = left; _ = (a = right); return a;", [(plain 3 4, 4)])
    , ("int a = left; _ = Twice(a = right); return a;", [(plain 3 4, 4)])
    , ("int a = left; _ = a++; _ = ++a; return a;", [(plain 3 0, 5)])
    , ("int a = left; int b = 0; b = a++ + a++ + a++; return b * 10 + a;", [(plain 1 0, 64)])
    , ("int a = left; bool big = (a += right) is > 5; return big ? a : -a;", [(plain 3 4, 7), (plain 1 2, -3)])
    ]

plain :: Integer -> Integer -> (Bool, Bool, Integer, Integer)
plain = flags False False

flags :: Bool -> Bool -> Integer -> Integer -> (Bool, Bool, Integer, Integer)
flags flag other left right = (flag, other, left, right)

evaluationTests :: [(String, Bool)]
evaluationTests =
    concat
        [ [ ("unoptimized Core computes " ++ label, runs artifactCore statements arguments expected)
          , ("optimized Core computes " ++ label, runs artifactOptimizedCore statements arguments expected)
          ]
        | (statements, runsOfCase) <- evaluationCases
        , (arguments, expected) <- runsOfCase
        , let label = show expected ++ " for " ++ show arguments ++ ": " ++ statements
        ]
        ++ [ ("the reference evaluator rejects a run that never ends", endlessLoopIsBounded)
           , ("the reference evaluator computes a plain loop", plainLoopEvaluates)
           ]

runs :: (FrontendArtifacts -> CoreModule) -> String -> (Bool, Bool, Integer, Integer) -> Integer -> Bool
runs select statements (flag, other, left, right) expected = case compileSource (body statements) of
    Right artifacts ->
        runFunction
            (select artifacts)
            "Evaluate"
            [BooleanValue flag, BooleanValue other, IntegerValue left, IntegerValue right]
            == Just (IntegerValue expected)
    Left _ -> False

-- The evaluator must fail closed: a wrong lowering that loops forever has to
-- fail its test, not hang the suite.
endlessLoopIsBounded :: Bool
endlessLoopIsBounded = case compileSource (body "int a = 0; while (true) { a += 1; } return a;") of
    Right artifacts ->
        runFunctionWithBudget
            5000
            (artifactCore artifacts)
            "Evaluate"
            [BooleanValue False, BooleanValue False, IntegerValue 0, IntegerValue 0]
            == Nothing
    Left _ -> False

plainLoopEvaluates :: Bool
plainLoopEvaluates = runs artifactCore "int sum = 0; for (int i = 1; i <= left; i += 1) { sum += i; } return sum;" (plain 10 0) 55

-- ---------------------------------------------------------------- pipeline

pipelineTests :: [(String, Bool)]
pipelineTests =
    [ ("every lowered case verifies as Core", all coreVerifies (map fst evaluationCases))
    , ("every optimized case verifies as Core", all optimizedVerifies (map fst evaluationCases))
    , ("every case verifies as CorePrep", all corePrepVerifies (map fst evaluationCases))
    , ("Core wire round-trips every lowered case", all wireRoundTrips (map fst evaluationCases))
    , ("a closure body may store into its own local", accepted closureSource)
    , ("an explicit capture initializer may store into an enclosing local", accepted captureSource)
    , ("a template member keeps its assignment and increment expressions when instantiated", templateInstantiates)
    , ("a call in an assigned value is reachable from the template member", templateReachesAssignedCalls)
    , ("a member that no assignment reaches is not instantiated", "Unused" `notElem` specializedNames)
    ]

coreVerifies :: String -> Bool
coreVerifies statements = case compileSource (body statements) of
    Right artifacts -> verifyCore (artifactCore artifacts) == Right (artifactCore artifacts)
    Left _ -> False

optimizedVerifies :: String -> Bool
optimizedVerifies statements = case compileSource (body statements) of
    Right artifacts -> verifyCore (artifactOptimizedCore artifacts) == Right (artifactOptimizedCore artifacts)
    Left _ -> False

corePrepVerifies :: String -> Bool
corePrepVerifies statements = case compileSource (body statements) of
    Right artifacts -> verifyCorePrep (artifactCorePrep artifacts) == Right (artifactCorePrep artifacts)
    Left _ -> False

wireRoundTrips :: String -> Bool
wireRoundTrips statements = case compileSource (body statements) of
    Right artifacts ->
        let core = artifactCore artifacts
         in (encodeCore defaultCoreWireLimits core >>= decodeCore defaultCoreWireLimits) == Right core
    Left _ -> False

templateSource :: String
templateSource =
    unwords
        [ "template<typename T> class Box {"
        , "int Entry(_ int seed) {"
        , "int value = seed;"
        , "int copy = 0;"
        , "copy = value = First(seed);"
        , "int total = (value += Second(copy)) + value++ + ++copy;"
        , "while ((copy = Third(copy)) > 0) { total += copy; }"
        , "return total;"
        , "}"
        , "int First(_ int value) { return value; }"
        , "int Second(_ int value) { return value; }"
        , "int Third(_ int value) { return value - 1; }"
        , "int Unused() { return 9; }"
        , "}"
        ]

-- | Specialize @Box<string>@ for its @Entry@ member only.
templatePlan :: Maybe TemplateSpecializationPlan
templatePlan = case analyzeSemantics (CompilerInput "assignment-template.tala" templateSource) of
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
                    "assignment-template"
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
-- member, so both new nodes must have been copied by every template pass.
templateInstantiates :: Bool
templateInstantiates =
    let closed = show specializedMembers
     in all (`isInfixOf` closed) ["AssignmentExpression", "IncrementExpression"]

templateReachesAssignedCalls :: Bool
templateReachesAssignedCalls = all (`elem` specializedNames) ["Entry", "First", "Second", "Third"]

closureSource :: String
closureSource =
    unlines
        [ "class Program {"
        , "    public static int Run(_ int seed) {"
        , "        auto step = \\(int value) -> { int local = value; return (local += 1) + local++; };"
        , "        return step(seed);"
        , "    }"
        , "}"
        ]

captureSource :: String
captureSource =
    unlines
        [ "class Program {"
        , "    public static int Run(_ int seed) {"
        , "        int counter = seed;"
        , "        auto read = [held = counter++] \\ -> held;"
        , "        return read() + counter;"
        , "    }"
        , "}"
        ]
