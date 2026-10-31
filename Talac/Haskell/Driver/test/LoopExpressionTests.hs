-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Vertical tests for loops used as expressions and the value-carrying
@break@ that supplies their value.

A loop expression must not be able to end without a value, so the type
tests pin every way it could: a condition that can become false, a bare
@break@, no value-carrying @break@ at all. The evaluation tests state the
value each program must compute and run the reference evaluator of
"CoreInterpreter" on the unoptimized and on the optimized Core.
-}
module LoopExpressionTests (loopExpressionTests) where

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

loopExpressionTests :: [(String, Bool)]
loopExpressionTests = parserTests ++ typeTests ++ loweringTests ++ evaluationTests ++ pipelineTests

-- ---------------------------------------------------------------- sources

body :: String -> String
body statements =
    unlines
        [ "class Program {"
        , "    public static int Evaluate(_ bool flag, _ bool other, _ int left, _ int right) {"
        , "        " ++ statements
        , "    }"
        , "    public static int Twice(_ int value) { return value + value; }"
        , "}"
        ]

parseSource :: String -> Either [Diagnostic] ParsedAST
parseSource text = do
    tokens <- runLexer defaultLexer (LexerInput "loop-expression.tala" text)
    runParser defaultParser (ParserInput "loop-expression.tala" tokens)

parseRejected :: String -> Bool
parseRejected text = either (const True) (const False) (parseSource text)

firstStatements :: String -> Maybe [Statement Identifier ()]
firstStatements text = case parseSource text of
    Right (ParsedAST (SyntaxTree _ (TypeDeclaration {typeMembers = member : _} : _))) -> case member of
        FunctionDeclaration {declarationBody = Block statements} -> Just statements
        _ -> Nothing
    _ -> Nothing

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "loop-expression.tala" text)

accepted :: String -> Bool
accepted text = either (const False) (const True) (compileSource text)

rejectedWith :: String -> String -> Bool
rejectedWith code text = case compileSource text of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

-- | The codes a source is rejected with, or none when it is accepted.
codesOf :: String -> [String]
codesOf text = either (map diagnosticCode) (const []) (compileSource text)

-- ---------------------------------------------------------------- parser

parserTests :: [(String, Bool)]
parserTests =
    [ ("a while loop in a binding initializer is a loop expression", whileExpressionParses)
    , ("a for loop in a binding initializer is a loop expression", forExpressionParses)
    , ("a loop expression is an operand of a binary operator", loopIsOperand)
    , ("a loop expression is a call argument", loopIsArgument)
    , ("a loop at the start of a statement stays a loop statement", loopStatementKeepsItsNode)
    , ("a break may carry an assignment expression", breakCarriesAssignment)
    , ("a do/while loop is not an expression", parseRejected (body "int r = do { break 1; } while (true); return r;"))
    ,
        ( "a loop expression in a binding needs its terminator"
        , parseRejected (body "int r = while (true) { break 1; } return r;")
        )
    ]

whileExpressionParses :: Bool
whileExpressionParses = case firstStatements (body "int r = while (true) { break 10; }; return r;") of
    Just
        [ BindingStatement
                _
                _
                _
                (Identifier "r")
                ()
                (LoopExpression _ (WhileStatement _ _ (Block [BreakStatement _ (Just _)])) ())
            , _
            ] ->
        True
    _ -> False

forExpressionParses :: Bool
forExpressionParses = case firstStatements (body "int r = for (int i = 0; ; i++) { break i; }; return r;") of
    Just [BindingStatement _ _ _ _ () (LoopExpression _ (ForStatement _ (Just _) Nothing [_] _) ()), _] -> True
    _ -> False

loopIsOperand :: Bool
loopIsOperand = case firstStatements (body "return 1 + while (true) { break 2; } + 3;") of
    Just [ReturnStatement _ (Just (BinaryExpression _ Add (BinaryExpression _ Add _ (LoopExpression {}) ()) _ ()))] -> True
    _ -> False

loopIsArgument :: Bool
loopIsArgument = case firstStatements (body "return Twice(while (true) { break 2; });") of
    Just [ReturnStatement _ (Just (CallExpression _ _ [LoopExpression {}] ()))] -> True
    _ -> False

loopStatementKeepsItsNode :: Bool
loopStatementKeepsItsNode = case firstStatements (body "while (flag) { break; } for (int i = 0; i < 2; i++) { } return 0;") of
    Just [WhileStatement {}, ForStatement {}, _] -> True
    _ -> False

breakCarriesAssignment :: Bool
breakCarriesAssignment = case firstStatements (body "int a = 0; int r = while (true) { break a = 5; }; return r;") of
    Just
        [ _
            , BindingStatement
                _
                _
                _
                _
                ()
                (LoopExpression _ (WhileStatement _ _ (Block [BreakStatement _ (Just (AssignmentExpression {}))])) ())
            , _
            ] ->
        True
    _ -> False

-- ---------------------------------------------------------------- type checker

typeTests :: [(String, Bool)]
typeTests =
    [ ("a while loop expression is accepted", accepted (body "int r = while (true) { break 10; }; return r;"))
    ,
        ( "a for loop expression without a condition is accepted"
        , accepted (body "int r = for (int i = 0; ; i++) { if (i > left) { break i; } }; return r;")
        )
    ,
        ( "a for loop expression with a constant true condition is accepted"
        , accepted (body "int r = for (int i = 0; true; i++) { if (i > left) { break i; } }; return r;")
        )
    ,
        ( "a break value takes its type from the receiver of the loop value"
        , accepted (body "long wide = while (true) { break 10; }; return wide > 5 ? 1 : 0;")
        )
    ,
        ( "a Boolean loop expression is accepted"
        , accepted (body "bool found = while (true) { break flag; }; return found ? 1 : 0;")
        )
    ,
        ( "continue is allowed in a loop expression"
        , accepted (body "int n = 0; int r = while (true) { n++; if (n < 3) { continue; } break n; }; return r;")
        )
    ,
        ( "a nested loop statement may use a bare break"
        , accepted (body "int r = while (true) { while (flag) { break; } break 1; }; return r;")
        )
    ,
        ( "a loop expression may nest in a loop expression"
        , accepted (body "int r = while (true) { int inner = while (true) { break 2; }; break inner; }; return r;")
        )
    ,
        ( "a value-carrying break in a loop statement is rejected"
        , rejectedWith "TAT0026" (body "while (true) { break 3; } return 0;")
        )
    ,
        ( "a value-carrying break in a nested loop statement is rejected"
        , rejectedWith "TAT0026" (body "int r = while (true) { while (flag) { break 2; } break 1; }; return r;")
        )
    ,
        ( "a value-carrying break in a do/while statement is rejected"
        , rejectedWith "TAT0026" (body "do { break 3; } while (flag); return 0;")
        )
    , ("a value-carrying break outside any loop is rejected", codesOf (body "break 3; return 0;") == ["TAT0025"])
    ,
        ( "a bare break in a loop expression is rejected"
        , rejectedWith "TAT0040" (body "int r = while (true) { if (flag) { break; } break 1; }; return r;")
        )
    ,
        ( "a while loop expression with a variable condition is rejected"
        , rejectedWith "TAT0041" (body "int r = while (flag) { break 1; }; return r;")
        )
    ,
        ( "a while loop expression with a constant false condition is rejected"
        , rejectedWith "TAT0041" (body "int r = while (false) { break 1; }; return r;")
        )
    ,
        ( "a for loop expression with a condition that can fail is rejected"
        , rejectedWith "TAT0041" (body "int r = for (int i = 0; i < left; i++) { break i; }; return r;")
        )
    ,
        ( "a loop expression without a value-carrying break is rejected"
        , rejectedWith "TAT0042" (body "int n = 0; int r = while (true) { n++; }; return r;")
        )
    ,
        ( "break values of different types are rejected"
        , rejectedWith "TAT0043" (body "long wide = 3; int r = while (true) { if (flag) { break wide; } break left; }; return r;")
        )
    ,
        ( "a loop yields a string"
        , accepted (body "int n = 0; auto text = while (true) { break \"done\"; }; return n;")
        )
    ,
        ( "a callable loop value is not lowered yet"
        , rejectedWith "TAT0044" (body "int n = 0; auto pick = while (true) { break \\(int v) -> v + 1; }; return n;")
        )
    ,
        ( "a string and a number are not values of one loop"
        , rejectedWith "TAT0043" (body "int n = 0; auto text = while (true) { if (n > 0) { break \"done\"; } break 1; }; return n;")
        )
    ,
        ( "a return inside a loop expression leaves the method"
        , accepted (body "int r = while (true) { if (flag) { return 1; } break 2; }; return r;")
        )
    ,
        ( "a return inside a loop expression carries the return type of the method"
        , rejectedWith "TAT0005" (body "int r = while (true) { if (flag) { return true; } break 2; }; return r;")
        )
    ,
        ( "a loop expression that only returns never yields a value"
        , accepted (body "int r = while (true) { return left; }; return r;")
        )
    ,
        ( "a loop value of the wrong type is rejected by its receiver"
        , not (accepted (body "long wide = 3; int r = while (true) { break wide; }; return r;"))
        )
    ,
        ( "a problem in a break value is still reported"
        , not (accepted (body "int r = while (true) { break missing; }; return r;"))
        )
    , ("an accepted loop expression reports nothing", codesOf (body "int r = while (true) { break left; }; return r;") == [])
    ]

-- ---------------------------------------------------------------- lowering

loweringTests :: [(String, Bool)]
loweringTests =
    [ ("a loop expression lowers to a result slot, the loop and a read of the slot", loopLowers)
    , ("a break value is stored before the loop is left", breakStoresThenLeaves)
    , ("a for loop expression keeps its initializer and update", forLoopLowers)
    , ("a loop expression in a conditional result runs only in that branch", loopInConditionalIsLazy)
    , ("an operand read before a loop expression is held across it", operandIsHeldAcrossLoop)
    , ("a loop statement lowers without a result slot", statementLoopHasNoSlot)
    ]

loweredBody :: String -> Maybe [CoreStatement]
loweredBody text = case compileSource text of
    Right artifacts -> functionBody (artifactCore artifacts)
    Left _ -> Nothing

functionBody :: CoreModule -> Maybe [CoreStatement]
functionBody moduleValue =
    case [ coreFunctionBody function
         | function <- coreModuleFunctions moduleValue
         , spelling (coreFunctionName function) == "Evaluate"
         ] of
        statements : _ -> Just statements
        [] -> Nothing

spelling :: ResolvedName -> String
spelling = identifierText . resolvedSpelling

isSlot :: ResolvedName -> Bool
isSlot name = "$loop" `isPrefixOf` spelling name

alwaysTrue :: CoreExpression
alwaysTrue = CoreLiteral (CoreBoolean True) boolType

loopLowers :: Bool
loopLowers = case loweredBody (body "int r = while (true) { break left; }; return r;") of
    Just
        [ CoreBind (CoreBinding slot _ True initial)
            , CoreWhile header [CoreAssign stored value, CoreBreak]
            , CoreBind (CoreBinding _ _ _ (CoreVariable result _))
            , _
            ] ->
        isSlot slot
            && initial == CoreLiteral (CoreInteger 0) intType
            && header == alwaysTrue
            && stored == slot
            && result == slot
            && case value of
                CoreVariable name _ -> spelling name == "left"
                _ -> False
    _ -> False

breakStoresThenLeaves :: Bool
breakStoresThenLeaves = case loweredBody (body "int n = 0; int r = while (true) { n += 1; if (n > left) { break n; } }; return r;") of
    Just [_, CoreBind (CoreBinding slot _ True _), CoreWhile _ [_, CoreIf _ [CoreAssign stored _, CoreBreak] []], _, _] ->
        isSlot slot && stored == slot
    _ -> False

forLoopLowers :: Bool
forLoopLowers = case loweredBody (body "int r = for (int i = 0; ; i++) { if (i > left) { break i; } }; return r;") of
    Just
        [ CoreBind (CoreBinding slot _ True _)
            , CoreBind (CoreBinding index _ True _)
            , CoreFor header [CoreIf _ [CoreAssign stored _, CoreBreak] []] [CoreAssign updated _]
            , _
            , _
            ] ->
        isSlot slot && spelling index == "i" && header == alwaysTrue && stored == slot && updated == index
    _ -> False

loopInConditionalIsLazy :: Bool
loopInConditionalIsLazy = case loweredBody (body "int r = flag ? while (true) { break left; } : right; return r;") of
    Just
        [ CoreBind (CoreBinding selected _ True _)
            , CoreIf _ [CoreBind (CoreBinding slot _ True _), CoreWhile {}, CoreAssign first _] [CoreAssign second _]
            , _
            , _
            ] ->
        "$selected" `isPrefixOf` spelling selected && isSlot slot && first == selected && second == selected
    _ -> False

operandIsHeldAcrossLoop :: Bool
operandIsHeldAcrossLoop = case loweredBody (body "int a = left; return a + while (true) { a += 1; break a; };") of
    Just
        [ _
            , CoreBind (CoreBinding held _ False (CoreVariable source _))
            , CoreBind (CoreBinding slot _ True _)
            , CoreWhile {}
            , CoreReturn (CorePrimitive CoreAdd [CoreVariable first _, CoreVariable second _] _)
            ] ->
        "$operand" `isPrefixOf` spelling held && spelling source == "a" && isSlot slot && first == held && second == slot
    _ -> False

statementLoopHasNoSlot :: Bool
statementLoopHasNoSlot = case loweredBody (body "int n = 0; while (true) { n += 1; if (n > left) { break; } } return n;") of
    Just [_, CoreWhile _ [_, CoreIf _ [CoreBreak] []], _] -> True
    _ -> False

-- ---------------------------------------------------------------- evaluation

-- | Source bodies, the arguments to run them on, and the value each run must return.
evaluationCases :: [(String, [((Bool, Bool, Integer, Integer), Integer)])]
evaluationCases =
    [ ("int r = while (true) { break left; }; return r;", [(plain 7 0, 7)])
    ,
        ( "int n = 0; int r = while (true) { n += 1; if (n * n > left) { break n; } }; return r;"
        , [(plain 10 0, 4), (plain 0 0, 1)]
        )
    , ("int r = for (int i = 0; ; i++) { if (i * 3 >= left) { break i; } }; return r;", [(plain 10 0, 4), (plain 0 0, 0)])
    , ("int r = for (int i = 0; true; i += 2) { if (i > left) { break i * 10; } }; return r;", [(plain 5 0, 60)])
    ,
        ( "int n = left; int r = while (true) { if (n > 100) { break 1; } if (n < 0) { break 0 - 1; } n = n * 2 - 3; }; return r * 1000 + n;"
        , [(plain 5 0, 1131), (plain 2 0, -1001)]
        )
    ,
        ( "int r = while (true) { int inner = for (int j = 0; ; j++) { if (j == right) { break j * 2; } }; break inner + 1; }; return r;"
        , [(plain 0 3, 7)]
        )
    , ("int a = left; return a + while (true) { a += 1; if (a > 5) { break a; } } + a;", [(plain 3 0, 15), (plain 9 0, 29)])
    ,
        ( "int n = 0; int sum = 0; int r = while (true) { n++; if (n == 2) { continue; } sum += n; if (n >= left) { break sum; } }; return r;"
        , [(plain 4 0, 8)]
        )
    ,
        ( "int total = 0; int r = while (true) { int k = 0; while (true) { k++; if (k == 3) { break; } } total += k; if (total > left) { break total; } }; return r;"
        , [(plain 7 0, 9)]
        )
    ,
        ( "bool found = while (true) { break flag; }; return found ? 1 : 0;"
        , [(flags True False 0 0, 1), (flags False False 0 0, 0)]
        )
    ,
        ( "int a = 0; int r = while (true) { if (flag) { break a = left; } break (a += right); }; return r * 10 + a;"
        , [(flags True False 3 4, 33), (flags False False 3 4, 44)]
        )
    ,
        ( "int a = 0; int r = flag ? while (true) { a += 1; if (a == 3) { break a; } } : 7; return r * 10 + a;"
        , [(flags True False 0 0, 33), (flags False False 0 0, 70)]
        )
    ,
        ( "int n = 0; int sum = 0; while (for (int i = n; ; i++) { if (i >= n) { break i; } } < left) { sum += n; n++; } return sum;"
        , [(plain 4 0, 6)]
        )
    , ("int n = 0; int r = Twice(while (true) { n += 3; if (n > left) { break n; } }) + n; return r;", [(plain 7 0, 27)])
    ,
        ( "int n = left; bool big = flag && while (true) { n += 1; break n > 5; }; return n * 10 + (big ? 1 : 0);"
        , [(flags True False 5 0, 61), (flags True False 1 0, 20), (flags False False 5 0, 50)]
        )
    ,
        ( "int n = 0; int r = (n = left) ?: while (true) { n += 7; break n; }; return r * 100 + n;"
        , [(plain 4 0, 404), (plain 0 0, 707)]
        )
    , ("long wide = while (true) { break 10; }; return wide > 9 ? 1 : 0;", [(plain 0 0, 1)])
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

runs :: (FrontendArtifacts -> CoreModule) -> String -> (Bool, Bool, Integer, Integer) -> Integer -> Bool
runs select statements (flag, other, left, right) expected = case compileSource (body statements) of
    Right artifacts ->
        runFunction
            (select artifacts)
            "Evaluate"
            [BooleanValue flag, BooleanValue other, IntegerValue left, IntegerValue right]
            == Just (IntegerValue expected)
    Left _ -> False

-- ---------------------------------------------------------------- pipeline

pipelineTests :: [(String, Bool)]
pipelineTests =
    [ ("every lowered case verifies as Core", all (verifies artifactCore) (map fst evaluationCases))
    , ("every optimized case verifies as Core", all (verifies artifactOptimizedCore) (map fst evaluationCases))
    , ("every case verifies as CorePrep", all corePrepVerifies (map fst evaluationCases))
    , ("Core wire round-trips every lowered case", all wireRoundTrips (map fst evaluationCases))
    , ("a template member keeps its loop expression when instantiated", templateInstantiates)
    , ("a call inside a loop expression is reachable from the template member", templateReachesLoopCalls)
    , ("a closure body may contain a loop expression", accepted closureSource)
    ]

verifies :: (FrontendArtifacts -> CoreModule) -> String -> Bool
verifies select statements = case compileSource (body statements) of
    Right artifacts -> verifyCore (select artifacts) == Right (select artifacts)
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
        , "int n = seed;"
        , "int found = while (true) { n = Step(n); if (n > 9) { break Scale(n); } };"
        , "return found;"
        , "}"
        , "int Step(_ int value) { return value + 4; }"
        , "int Scale(_ int value) { return value * 2; }"
        , "int Unused() { return 9; }"
        , "}"
        ]

templatePlan :: Maybe TemplateSpecializationPlan
templatePlan = case analyzeSemantics (CompilerInput "loop-template.tala" templateSource) of
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
                    "loop-template"
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

templateInstantiates :: Bool
templateInstantiates = "LoopExpression" `isInfixOf` show specializedMembers

templateReachesLoopCalls :: Bool
templateReachesLoopCalls =
    all (`elem` specializedNames) ["Entry", "Step", "Scale"] && "Unused" `notElem` specializedNames

closureSource :: String
closureSource =
    unlines
        [ "class Program {"
        , "    public static int Run(_ int seed) {"
        , "        auto search = \\(int limit) -> { int n = 0; return while (true) { n += 1; if (n * n > limit) { break n; } }; };"
        , "        return search(seed);"
        , "    }"
        , "}"
        ]
