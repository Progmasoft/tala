-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Tests for classic enums.

A classic enum is a value type whose members are named integers. The tests
pin its declaration, the numbering of its members, the one comparison its
values have, the absence of any conversion to or from an integer, and
@match@ over it: a case pattern names a member, two members with one value
are one case, and a match that names every value needs no catch-all arm.

The expected values are written by hand. Every accepted program runs in the
reference evaluator on the unoptimized and on the optimized Core and is
verified as Core and as CorePrep; an enum must reach Core as its underlying
integer type and never as a named type.
-}
module EnumTests (enumTests) where

import CoreInterpreter
import Data.List (isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser

enumTests :: [(String, Bool)]
enumTests =
    parserTests
        ++ concat
            [ [ ("unoptimized Core computes " ++ label, runs artifactCore statements arguments expected)
              , ("optimized Core computes " ++ label, runs artifactOptimizedCore statements arguments expected)
              ]
            | (statements, runsOfCase) <- evaluationCases
            , (arguments, expected) <- runsOfCase
            , let label = show expected ++ " for " ++ show arguments ++ ": " ++ statements
            ]
        ++ [ ("every enum program verifies as Core and as CorePrep", all (verifies . fst) evaluationCases)
           , ("no enum reaches Core as a named type", all (erased . fst) evaluationCases)
           ]
        ++ [(label, rejectedWith code (program statements)) | (label, code, statements) <- rejectedBodies]
        ++ [(label, rejectedWith code (declarations ++ emptyProgram)) | (label, code, declarations) <- rejectedDeclarations]
        ++ [ ("an enum without members is a declaration", accepted ("enum Empty { }\n" ++ emptyProgram))
           , ("an enum may be declared after the class that follows it in use", accepted (emptyProgram ++ "enum Later { ONE }\n"))
           , ("a negative member value is accepted in a signed type", accepted ("enum Signed { LOW = -5, NEXT }\n" ++ emptyProgram))
           ]

-- ---------------------------------------------------------------- sources

enums :: String
enums =
    unlines
        [ "enum Status { NONE, UNKNOWN = 0, READY }"
        , "enum Level = byte { LOW = 1, MID, HIGH = 10, TOP }"
        , -- Values computed from earlier members: 1, 2, 4, 7, 8, 2, 250, 5.
          "enum Flag = ubyte { READ = 1, WRITE = READ << 1, EXECUTE = WRITE * 2, ALL = READ | WRITE | EXECUTE, NEXT,"
            ++ " HALF = EXECUTE / 2, REST = !(EXECUTE + 1), ROUNDED = 9 // 2 }"
        , "enum Offset = int { BASE = -3, ABOVE = BASE + 5, POWER = 2 ** 10, MODULO = -7 % 4, MIX = (ABOVE ^ 7) & 6 }"
        ]

-- | A program around the given body of @Evaluate@.
program :: String -> String
program statements =
    "namespace Test;\n"
        ++ enums
        ++ unlines
            [ "class Program {"
            , "    public static Status Pick(_ int v) { if (v > 0) { return Status.READY; } return Status.NONE; }"
            , "    public static int Rank(_ Level l) { return match (l) { .LOW -> 1, .MID -> 2, .HIGH -> 10, .TOP -> 11 }; }"
            , "    public static Level Raise(_ Level l) { return match (l) { .LOW -> Level.MID, .MID -> Level.HIGH, _ -> Level.TOP }; }"
            , "    public static Flag Bit(_ int v) { return match (v) { 1 -> .READ, 2 -> .WRITE, 4 -> .EXECUTE, 7 -> .ALL, 8 -> .NEXT, 250 -> .REST, 5 -> .ROUNDED, _ -> .HALF }; }"
            , "    public static Offset At(_ int v) { return match (v) { -3 -> .BASE, 2 -> .ABOVE, 1024 -> .POWER, _ -> .MODULO }; }"
            , "    public static int Evaluate(_ int left, _ int right) {"
            , "        " ++ statements
            , "    }"
            , "}"
            ]

emptyProgram :: String
emptyProgram = "class Program { public static int Evaluate(_ int left, _ int right) { return 0; } }\n"

-- ----------------------------------------------------------------- parser

parserTests :: [(String, Bool)]
parserTests =
    [ ("an enum declaration keeps its members in order", memberNames "enum Direction { NORTH, EAST, SOUTH, WEST, }" == Just ["NORTH", "EAST", "SOUTH", "WEST"])
    , ("a member keeps the value written for it", memberValues "enum Value = int { FIRST = 5, SECOND, THIRD = 10, FOURTH }" == Just [Just "5", Nothing, Just "10", Nothing])
    , ("a member value may be negative", memberValues "enum Signed { LOW = -5 }" == Just [Just "-5"])
    , -- A value is an expression; a comma ends it and the next member begins.
      ("a member value is an expression", memberValues "enum Bits { A = 1, B = A << 1, C = (A | B) + 2 * 3, D }" == Just [Just "1", Just "A<<1", Just "A|B+2*3", Nothing])
    , ("a member value is not an assignment", not (parses "enum Bad { A = 1, B = A = 2 }"))
    , ("the underlying type is kept", underlying "enum Status = byte { PENDING = 0 }" == Just (Just (ExplicitType (Identifier "byte"))))
    , ("the underlying type may be absent", underlying "enum Status { PENDING }" == Just Nothing)
    , ("enum is a reserved word", not (parses "class enum { }"))
    ]
    where
        -- The underlying type and the members of the first declaration.
        declaration text = case parseSource text of
            Right (ParsedAST (SyntaxTree _ (EnumDeclaration _ _ _ written members : _))) -> Just (written, members)
            _ -> Nothing
        memberNames text = map (identifierText . enumCaseName) . snd <$> declaration text
        memberValues text = map (fmap spelled . enumCaseValue) . snd <$> declaration text
        -- The operators and operands of a value in the order they are written.
        spelled :: Expression Identifier () -> String
        spelled value = case value of
            LiteralExpression _ (IntegerLiteral number) _ -> show number
            NameExpression _ name _ -> identifierText name
            UnaryExpression _ UnaryNegate operand _ -> "-" ++ spelled operand
            BinaryExpression _ operator left right _ -> spelled left ++ sign operator ++ spelled right
            _ -> "?"
        sign operator = case operator of
            Add -> "+"
            Multiply -> "*"
            ShiftLeft -> "<<"
            BitwiseOr -> "|"
            _ -> "?"
        underlying text = fst <$> declaration text

-- -------------------------------------------------------------- evaluation

-- | Bodies of @Evaluate@, the arguments to run them on, and the value each run must return.
evaluationCases :: [(String, [((Integer, Integer), Integer)])]
evaluationCases =
    [ -- Values of an enum are compared with == and \=.
      ("Status s = Pick(left); return s == Status.READY ? 1 : 2;", [((3, 0), 1), ((0, 0), 2)])
    , ("Status s = Pick(left); return s \\= Status.NONE ? 1 : 2;", [((3, 0), 1), ((0, 0), 2)])
    , -- Two members with one value are equal.
      ("return Status.NONE == Status.UNKNOWN ? 1 : 2;", [((0, 0), 1)])
    , -- Members are numbered from zero; one without a value follows the one before it.
      ("return Rank(Level.LOW) + Rank(Level.MID) * 10 + Rank(Level.HIGH) * 100 + Rank(Level.TOP) * 1000;", [((0, 0), 12021)])
    , -- A match that names every value needs no catch-all arm.
      ("return match (Pick(left)) { .NONE -> 10, .READY -> 20 };", [((3, 0), 20), ((0, 0), 10)])
    , -- A member is named through either of its names.
      ("return match (Pick(left)) { .UNKNOWN -> 10, .READY -> 20 };", [((0, 0), 10)])
    , ("Level l = Level.MID; return match (l) { .LOW -> 1, _ -> 9 };", [((0, 0), 9)])
    , -- A guard does not count towards completeness, and a catch-all is then needed.
      ("return match (Pick(left)) { .READY if (right > 0) -> 1, .READY -> 2, .NONE -> 3 };", [((1, 1), 1), ((1, 0), 2), ((0, 5), 3)])
    , -- An enum is assigned, passed, returned and yielded by a match.
      ("Status s = Status.NONE; s = Status.READY; return s == Status.READY ? 7 : 8;", [((0, 0), 7)])
    , ("return Rank(Raise(Raise(Level.LOW))) * 100 + Rank(Raise(Level.HIGH));", [((0, 0), 1011)])
    , ("Status s = match (left) { 1 -> Status.READY, _ -> Status.NONE }; return s == Status.READY ? 1 : 0;", [((1, 0), 1), ((2, 0), 0)])
    , -- The target-typed spelling names a member of the enum the place
      -- expects: a declared type, a parameter, a return type, the other
      -- operand of a comparison, the variable assigned to.
      ("Status s = .READY; return s == Status.READY ? 1 : 2;", [((0, 0), 1)])
    , ("Status s = Pick(left); return s == .READY ? 1 : 2;", [((3, 0), 1), ((0, 0), 2)])
    , ("return Rank(.HIGH) + Rank(.LOW);", [((0, 0), 11)])
    , ("Level l = .LOW; l = .TOP; return Rank(l);", [((0, 0), 11)])
    , ("Status s = match (left) { 1 -> .READY, _ -> .NONE }; return s == .READY ? 1 : 0;", [((1, 0), 1), ((2, 0), 0)])
    , -- A conditional, an if expression and a loop expression yield an enum.
      ("Status s = left > 0 ? .READY : .NONE; return s == .READY ? 1 : 0;", [((1, 0), 1), ((0, 0), 0)])
    , ("Level l = if (left > 0) { Level.HIGH } else { Level.LOW }; return Rank(l);", [((1, 0), 10), ((0, 0), 1)])
    , ("Level l = while (true) { if (left > 0) { break Level.TOP; } break Level.MID; }; return Rank(l);", [((1, 0), 11), ((0, 0), 2)])
    , -- Two subjects with closed sets of values are complete together.
        ( "return match (Pick(left)), (right > 0) { (.NONE), (true) -> 1, (.NONE), (false) -> 2, (.READY), (true) -> 3, (.READY), (false) -> 4 };"
        , [((0, 1), 1), ((0, 0), 2), ((1, 1), 3), ((1, 0), 4)]
        )
    , -- A member has the value its expression computes from the members
      -- before it. Two members are equal exactly when their values are, so
      -- comparing a member with the one a number selects reads its value.
      ("return Bit(left) == Flag.WRITE ? 1 : 0;", [((2, 0), 1), ((1, 0), 0), ((4, 0), 0)])
    , ("return Bit(left) == Flag.EXECUTE ? 1 : 0;", [((4, 0), 1), ((2, 0), 0)])
    , ("return Bit(left) == Flag.ALL ? 1 : 0;", [((7, 0), 1), ((4, 0), 0)])
    , -- A member without a value follows a computed one: ALL is 7, NEXT is 8.
      ("return Bit(left) == Flag.NEXT ? 1 : 0;", [((8, 0), 1), ((7, 0), 0)])
    , -- HALF is 4 / 2, the value of WRITE: the two names are one value.
      ("return Flag.HALF == Flag.WRITE ? 1 : 0;", [((0, 0), 1)])
    , -- The complement is that of the underlying type: !5 in ubyte is 250.
      ("return Bit(left) == Flag.REST ? 1 : 0;", [((250, 0), 1), ((5, 0), 0)])
    , -- 9 // 2 rounds to the nearest integer, away from zero at a half.
      ("return Bit(left) == Flag.ROUNDED ? 1 : 0;", [((5, 0), 1), ((4, 0), 0)])
    , ("return At(left) == Offset.ABOVE ? 1 : 0;", [((2, 0), 1), ((-3, 0), 0)])
    , ("return At(left) == Offset.POWER ? 1 : 0;", [((1024, 0), 1), ((2, 0), 0)])
    , -- -7 % 4 is -3, the value of BASE; (2 ^ 7) & 6 is 4.
      ("return Offset.MODULO == Offset.BASE ? 1 : 0;", [((0, 0), 1)])
    , ("return Offset.MIX == Offset.ABOVE ? 1 : 0;", [((0, 0), 0)])
    , -- A match over an enum with computed values is complete when every
      -- value is named, through whichever of its names.
      ("return match (Bit(left)) { .READ -> 1, .HALF -> 2, .EXECUTE -> 3, .ALL -> 4, .NEXT -> 5, .REST -> 6, .ROUNDED -> 7 };", [((1, 0), 1), ((2, 0), 2), ((4, 0), 3), ((7, 0), 4), ((8, 0), 5), ((250, 0), 6), ((5, 0), 7)])
    , -- An enum in a callable and in a loop.
      ("auto f = \\(Status s) -> s == Status.READY ? 5 : 6; return f(Pick(left)) * 10 + f(Status.NONE);", [((2, 0), 56)])
    , ("Level l = Level.LOW; int n = 0; while (l \\= Level.TOP) { l = Raise(l); n += 1; } return n;", [((0, 0), 3)])
    ]

-- ----------------------------------------------------------------- rejects

rejectedBodies :: [(String, String, String)]
rejectedBodies =
    [ ("a match over an enum must name every value", "TAT0052", "return match (Pick(left)) { .NONE -> 10 };")
    , ("a guarded arm does not complete a match over an enum", "TAT0052", "return match (Pick(left)) { .NONE -> 1, .READY if (right > 0) -> 2 };")
    , ("a second arm for the same value can never be selected", "TAT0053", "return match (Pick(left)) { .NONE -> 10, .UNKNOWN -> 11, .READY -> 20 };")
    , ("an enum has only the members it declares", "TAT0064", "Status s = Status.MISSING; return 0;")
    , ("a case pattern names a member of the subject's enum", "TAT0064", "return match (Pick(left)) { .LOW -> 1, _ -> 2 };")
    , ("a case pattern needs a subject of an enum type", "TAT0056", "return match (left) { .NONE -> 1, _ -> 2 };")
    , ("values of an enum are not ordered", "TAT0065", "return Status.NONE < Status.READY ? 1 : 2;")
    , ("values of an enum are not added", "TAT0065", "Status s = Status.NONE + Status.READY; return 0;")
    , ("values of different enums are not compared", "TAT0065", "return Status.NONE == Level.LOW ? 1 : 2;")
    , ("a value of an enum is not compared with an integer", "TAT0065", "return Status.NONE == 0 ? 1 : 2;")
    , ("a value of an enum is not an integer", "TAT0002", "int x = Status.READY; return x;")
    , ("an integer is not a value of an enum", "TAT0002", "Status s = 1; return 0;")
    , ("a value of an enum is not a condition", "TAT0006", "if (Status.READY) { return 1; } return 2;")
    , ("the target-typed spelling needs a known target type", "TAT0069", "auto s = .READY; return 0;")
    , ("the target-typed spelling needs an enum as its target", "TAT0069", "int x = .READY; return x;")
    , ("the left operand of a comparison has no target type", "TAT0069", "Status s = Pick(left); return .NONE == s ? 1 : 2;")
    , ("the target-typed spelling names a member of the expected enum", "TAT0064", "Status s = .LOW; return 0;")
    , ("a call through the target-typed spelling has no type to call on", "TAT0032", ".Pick(left); return 0;")
    , ("a value of one enum is not a value of another", "TAT0002", "Level l = Status.NONE; return 0;")
    ]

rejectedDeclarations :: [(String, String, String)]
rejectedDeclarations =
    [ ("the underlying type of an enum is an integer type", "TAT0066", "enum A = float { X }\n")
    , ("a member is named once", "TAT0067", "enum A { X, X }\n")
    , ("a member value fits the underlying type", "TAT0068", "enum A = byte { X = 300 }\n")
    , ("a numbered member fits the underlying type", "TAT0068", "enum A = byte { X = 127, Y }\n")
    , ("an unsigned underlying type has no negative member", "TAT0068", "enum A = ubyte { X = -1 }\n")
    , ("a computed member value fits the underlying type", "TAT0068", "enum A = byte { X = 100, Y = X + X }\n")
    , ("a member value is an integer", "TAT0070", "enum A { X = 1.5 }\n")
    , ("a member value names earlier members only", "TAT0070", "enum A { X = Y, Y = 1 }\n")
    , ("a member value does not name the member itself", "TAT0070", "enum A { X = X + 1 }\n")
    , ("a member value does not name a member of another enum", "TAT0070", "enum A { X = 1 }\nenum B { Y = A.X }\n")
    , ("a member value is not a call", "TAT0070", "enum A { X = Program.Evaluate(1, 2) }\n")
    , ("a member value is not a comparison", "TAT0070", "enum A { X = 1, Y = X < 2 }\n")
    , ("a member value does not divide by zero", "TAT0070", "enum A { X = 0, Y = 4 / X }\n")
    , ("a member value has no negative exponent", "TAT0070", "enum A { X = 2 ** -1 }\n")
    , -- The value of a member is an expression like any other for the
      -- nesting limit: 1100 negations in one another are deeper than 1024
      -- levels.
        ( "a member value is within the expression nesting limit"
        , "TAP0040"
        , "enum A { X = " ++ concat (replicate 1100 "-(") ++ "1" ++ replicate 1100 ')' ++ " }\n"
        )
    , ("the match of a member with a computed value is unreachable after its other name", "TAT0053", "enum A { X = 1, Y = X }\nclass P { public static int F(_ A a) { return match (a) { .X -> 1, .Y -> 2 }; } }\n")
    , ("an enum is declared once", "TAR0001", "enum A { X }\nenum A { Y }\n")
    , ("an enum and a class do not share a name", "TAR0001", "enum A { X }\nclass A { }\n")
    ]

-- ----------------------------------------------------------------- helpers

parseSource :: String -> Either [Diagnostic] ParsedAST
parseSource text = do
    tokens <- runLexer defaultLexer (LexerInput "enum.tala" text)
    runParser defaultParser (ParserInput "enum.tala" tokens)

parses :: String -> Bool
parses = either (const False) (const True) . parseSource

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "enum.tala" text)

accepted :: String -> Bool
accepted = either (const False) (const True) . compileSource

rejectedWith :: String -> String -> Bool
rejectedWith code text = case compileSource text of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

runs :: (FrontendArtifacts -> CoreModule) -> String -> (Integer, Integer) -> Integer -> Bool
runs select statements (left, right) expected = case compileSource (program statements) of
    Right artifacts ->
        runFunction (select artifacts) "Evaluate" [IntegerValue left, IntegerValue right] == Just (IntegerValue expected)
    Left _ -> False

verifies :: String -> Bool
verifies statements = case compileSource (program statements) of
    Right artifacts ->
        verifyCore (artifactCore artifacts) == Right (artifactCore artifacts)
            && verifyCore (artifactOptimizedCore artifacts) == Right (artifactOptimizedCore artifacts)
            && verifyCorePrep (artifactCorePrep artifacts) == Right (artifactCorePrep artifacts)
    Left _ -> False

{- | Whether the Core of a program mentions no enum. The reserved root of an
enum type cannot be spelled in source, so its absence from the printed Core
shows that every enum was lowered to its underlying type.
-}
erased :: String -> Bool
erased statements = case compileSource (program statements) of
    Right artifacts -> not ("Identifier \"enum\"" `isInfixOf` show (artifactCore artifacts))
    Left _ -> False
