-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | The runtime call in Core, its catalog, and the reading of formats.

A runtime call is one Core primitive whose first operand is a literal that
names a function of the runtime catalog. These cases hold the three things
the rest of the compiler builds on:

* the catalog, row by row. An identity is written into artifacts and a
  symbol is linked against, so a row that changed would silently change what
  compiled programs call; the native stages pin the same rows in
  @RuntimeCallPipelineTests.cpp@;
* the rule each verifier applies to a call, broken in each way it can be
  broken, in Core and in CorePrep, and both wire formats;
* the reading of a format into pieces, which is the one place the output
  format grammar is decided.

The programs that use all of it together are in "ConsoleTests".
-}
module RuntimeCallTests (runtimeCallTests) where

import CoreInterpreter
import Data.List (nub)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.CorePrep.Wire
import Progmasoft.Tala.Core.Optimizer
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.RuntimeCall
import Progmasoft.Tala.TypeChecker.Format

runtimeCallTests :: [(String, Bool)]
runtimeCallTests =
    catalogTests ++ acceptanceTests ++ coreTests ++ corePrepTests ++ optimizerTests ++ formatTests

-- ------------------------------------------------------------------ catalog

-- | A row as the tests state it: identity, symbol, parameters, result, observable.
type Row = (RuntimeFunction, Integer, String, [RuntimeParameter], RuntimeResult, Bool)

rows :: [Row]
rows =
    [ (TextConcat, 1, "tala_text_concat", [TextParameter, TextParameter], TextResult, False)
    , (TextFromSigned, 2, "tala_text_from_signed", [SignedParameter], TextResult, False)
    , (TextFromUnsigned, 3, "tala_text_from_unsigned", [UnsignedParameter], TextResult, False)
    , (TextFromBool, 4, "tala_text_from_bool", [BoolParameter], TextResult, False)
    , (TextFromChar, 5, "tala_text_from_char", [CharParameter], TextResult, False)
    , (TextFormatSigned, 6, "tala_text_format_signed", conversion SignedParameter, TextResult, False)
    , (TextFormatUnsigned, 7, "tala_text_format_unsigned", conversion UnsignedParameter, TextResult, False)
    , (TextFormatFloating, 8, "tala_text_format_floating", conversion FloatingParameter, TextResult, False)
    , (TextFormatString, 9, "tala_text_format_string", conversion TextParameter, TextResult, False)
    , (TextFormatChar, 10, "tala_text_format_char", conversion CharParameter, TextResult, False)
    , (TextNewline, 11, "tala_text_newline", [], TextResult, False)
    , (ConsoleWrite, 12, "tala_console_write", [TextParameter, CountParameter], NoResult, True)
    , (TextEquals, 13, "tala_text_equals", [TextParameter, TextParameter], TruthResult, False)
    ]
    where
        conversion value = [CountParameter, CountParameter, CountParameter, value]

catalogTests :: [(String, Bool)]
catalogTests =
    [ ("the runtime catalog has thirteen functions", length runtimeFunctions == 13)
    , ("every runtime function has a row in the tests", map (\(function, _, _, _, _, _) -> function) rows == runtimeFunctions)
    , ("runtime identities are distinct", length (nub (map runtimeFunctionIdentity runtimeFunctions)) == length runtimeFunctions)
    , ("runtime symbols are distinct", length (nub (map runtimeFunctionSymbol runtimeFunctions)) == length runtimeFunctions)
    , ("runtime identities are the numbers from one", map runtimeFunctionIdentity runtimeFunctions == [1 .. 13])
    , ("zero names no runtime function", runtimeFunctionOf 0 == Nothing)
    , ("a negative number names no runtime function", runtimeFunctionOf (-1) == Nothing)
    , ("the number after the last names no runtime function", runtimeFunctionOf 14 == Nothing)
    , ("only a console write is observable", filter runtimeObservable runtimeFunctions == [ConsoleWrite])
    , -- The name of a runtime call in the typed tree: reserved, and
      -- distinct for every function.
      ("runtime names have negative symbols", all ((< 0) . symbolIdValue . resolvedSymbol . runtimeName) runtimeFunctions)
    , ("runtime names are distinct", length (nub (map runtimeName runtimeFunctions)) == length runtimeFunctions)
    , ("a runtime name is read back as its function", all (\function -> runtimeFunctionOfName (runtimeName function) == Just function) runtimeFunctions)
    , ("a source name is no runtime name", runtimeFunctionOfName (name 5 "Print") == Nothing)
    , ("the names the language declares are no runtime names", all ((== Nothing) . runtimeFunctionOfName . declared) [builtinSystemSymbol, builtinConsoleSymbol])
    , ("System and Console have symbols of their own", builtinSystemSymbol /= builtinConsoleSymbol)
    , ("a runtime name begins with a character no identifier has", all ((== "$") . take 1 . identifierText . resolvedSpelling . runtimeName) runtimeFunctions)
    , -- The values the runtime header gives the flags and the targets.
      ("the conversion flags are distinct bits", [flagLeft, flagZero, flagPlus, flagSpace, flagAlternate, flagGroup, flagHexadecimal] == [1, 2, 4, 8, 16, 32, 64])
    , ("an absent width is minus one", absent == -1)
    , ("the console targets are the four the runtime knows", [consoleOutput, consoleOutputLine, consoleError, consoleErrorLine] == [0, 1, 2, 3])
    ]
        ++ concat
            [ [ ("runtime identity of " ++ show function, runtimeFunctionIdentity function == identity)
              , ("runtime function of identity " ++ show identity, runtimeFunctionOf identity == Just function)
              , ("runtime symbol of " ++ show function, runtimeFunctionSymbol function == symbol)
              , ("runtime parameters of " ++ show function, runtimeParameters function == parameters)
              , ("runtime result of " ++ show function, runtimeResult function == result)
              , ("runtime observability of " ++ show function, runtimeObservable function == observable)
              ]
            | (function, identity, symbol, parameters, result, observable) <- rows
            ]
    where
        declared symbol = ResolvedName symbol (Identifier "Console")

{- | Which types each kind of parameter takes. The runtime functions are
written for 64 bits, so the wider types are not taken.
-}
acceptanceTests :: [(String, Bool)]
acceptanceTests =
    [ ("a signed parameter takes the signed integers up to 64 bits", accepted SignedParameter == ["byte", "short", "long", "int"])
    , ("an unsigned parameter takes the unsigned integers up to 64 bits", accepted UnsignedParameter == ["ubyte", "ushort", "ulong", "uint"])
    , ("a floating parameter takes the floating types up to 64 bits", accepted FloatingParameter == ["sfloat", "lfloat", "float"])
    , ("a Boolean parameter takes bool", accepted BoolParameter == ["bool"])
    , ("a character parameter takes char", accepted CharParameter == ["char"])
    , ("a text parameter takes String", accepted TextParameter == ["String"])
    , ("a count is an int", accepted CountParameter == ["int"])
    , ("no parameter takes a callable", not (any (`runtimeAccepts` FunctionType [] intType) parameterKinds))
    , ("no parameter takes a generic type", not (any (`runtimeAccepts` NamedType (QualifiedName [Identifier "int"]) [TypeTemplateArgument intType]) parameterKinds))
    , ("no parameter takes a qualified name", not (any (`runtimeAccepts` NamedType (QualifiedName [Identifier "System", Identifier "int"]) []) parameterKinds))
    ]
    where
        parameterKinds =
            [SignedParameter, UnsignedParameter, FloatingParameter, BoolParameter, CharParameter, TextParameter, CountParameter]
        spellings =
            [ "bool"
            , "char"
            , "byte"
            , "short"
            , "long"
            , "int"
            , "longint"
            , "ubyte"
            , "ushort"
            , "ulong"
            , "uint"
            , "ulongint"
            , "sfloat"
            , "lfloat"
            , "float"
            , "double"
            , "String"
            , "unit"
            ]
        accepted parameter = [spelling | spelling <- spellings, runtimeAccepts parameter (namedType spelling)]

-- --------------------------------------------------------------------- Core

name :: Int -> String -> ResolvedName
name symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

runName, countName, lineName :: ResolvedName
runName = name 1 "Run"
countName = name 2 "count"
lineName = name 3 "line"

count :: CoreExpression
count = CoreVariable countName intType

integer :: Integer -> CoreExpression
integer value = CoreLiteral (CoreInteger value) intType

text :: String -> CoreExpression
text value = CoreLiteral (CoreString value) stringType

-- | A runtime call of the given function with the given result type.
runtime :: RuntimeFunction -> [CoreExpression] -> Type -> CoreExpression
runtime function arguments = CorePrimitive CoreRuntimeCall (integer (runtimeFunctionIdentity function) : arguments)

-- | @Run(count)@ with the given body.
moduleOf :: [CoreStatement] -> CoreModule
moduleOf body =
    CoreModuleWithSources
        (QualifiedName [Identifier "Calls"])
        [CoreFunction runName [(countName, intType)] intType body]
        []
        []

{- | @line = "Count: " + format(count); write(line); return count@, the shape
a call of @Console.Printfn("Count: %5d", count)@ lowers to.
-}
writingModule :: CoreModule
writingModule =
    moduleOf
        [ CoreBind
            ( CoreBinding
                lineName
                stringType
                False
                ( runtime
                    TextConcat
                    [text "Count: ", runtime TextFormatSigned [integer 0, integer 5, integer absent, count] stringType]
                    stringType
                )
            )
        , CoreEvaluate (runtime ConsoleWrite [CoreVariable lineName stringType, integer consoleOutputLine] unitType)
        , CoreReturn count
        ]

-- | A module whose one statement before the return evaluates the expression.
evaluating :: CoreExpression -> CoreModule
evaluating expression = moduleOf [CoreEvaluate expression, CoreReturn count]

-- | A module that binds the expression at the given type.
binding :: Type -> CoreExpression -> CoreModule
binding valueType expression = moduleOf [CoreBind (CoreBinding lineName valueType False expression), CoreReturn count]

verifiesCore :: CoreModule -> Bool
verifiesCore moduleValue = verifyCore moduleValue == Right moduleValue

rejectsCore :: CoreModule -> Bool
rejectsCore moduleValue = case verifyCore moduleValue of
    Left problems -> any ((== "TAC1075") . diagnosticCode) problems
    Right _ -> False

coreTests :: [(String, Bool)]
coreTests =
    [ ("Core accepts well-formed runtime calls", verifiesCore writingModule)
    , ("Core wire carries runtime calls", (encodeCore defaultCoreWireLimits writingModule >>= decodeCore defaultCoreWireLimits) == Right writingModule)
    , ("the reference evaluator runs the calls", runFunctionWriting 1000 writingModule "Run" [IntegerValue 42] == Just (IntegerValue 42, Written "Count:    42\n" ""))
    , -- Every function of the catalog with arguments of its types.
      ("Core accepts a call of every runtime function", all (verifiesCore . wellFormed) runtimeFunctions)
    , -- What the first operand must be.
      ("Core rejects an identity the catalog does not have", rejectsCore (evaluating (CorePrimitive CoreRuntimeCall [integer 999] unitType)))
    , ("Core rejects the identity zero", rejectsCore (evaluating (CorePrimitive CoreRuntimeCall [integer 0] unitType)))
    , ("Core rejects a negative identity", rejectsCore (evaluating (CorePrimitive CoreRuntimeCall [integer (-12)] unitType)))
    , ("Core rejects a runtime call without operands", rejectsCore (evaluating (CorePrimitive CoreRuntimeCall [] unitType)))
    , -- The function is fixed when the program is compiled.
      ("Core rejects an identity that is computed", rejectsCore (binding stringType (CorePrimitive CoreRuntimeCall [count] stringType)))
    , ( "Core rejects an identity of another integer type"
      , rejectsCore (binding stringType (CorePrimitive CoreRuntimeCall [CoreLiteral (CoreInteger 11) (namedType "uint")] stringType))
      )
    , ("Core rejects a Boolean as an identity", rejectsCore (evaluating (CorePrimitive CoreRuntimeCall [CoreLiteral (CoreBoolean True) boolType] unitType)))
    , -- The arguments are the ones the function takes.
      ("Core rejects a missing argument", rejectsCore (binding stringType (runtime TextConcat [text "a"] stringType)))
    , ("Core rejects an extra argument", rejectsCore (binding stringType (runtime TextConcat [text "a", text "b", text "c"] stringType)))
    , ("Core rejects an argument to a function that takes none", rejectsCore (binding stringType (runtime TextNewline [count] stringType)))
    , ("Core rejects a number where a string is taken", rejectsCore (binding stringType (runtime TextConcat [text "a", count] stringType)))
    , ("Core rejects a string where a number is taken", rejectsCore (binding stringType (runtime TextFromSigned [text "a"] stringType)))
    , ("Core rejects a signed integer where an unsigned one is taken", rejectsCore (binding stringType (runtime TextFromUnsigned [count] stringType)))
    , ( "Core rejects a width that is not an int"
      , rejectsCore
            ( binding
                stringType
                (runtime TextFormatSigned [integer 0, CoreLiteral (CoreInteger 5) (namedType "long"), integer absent, count] stringType)
            )
      )
    , ("Core rejects a write target that is a Boolean", rejectsCore (evaluating (runtime ConsoleWrite [text "a", CoreLiteral (CoreBoolean True) boolType] unitType)))
    , -- The call has the type the function returns.
      ("Core rejects a string result typed as a number", rejectsCore (binding intType (runtime TextConcat [text "a", text "b"] intType)))
    , ("Core rejects a write that yields a string", rejectsCore (binding stringType (runtime ConsoleWrite [text "a", integer 0] stringType)))
    , ("Core rejects an equality that yields a string", rejectsCore (binding stringType (runtime TextEquals [text "a", text "b"] stringType)))
    , ("Core accepts an equality that yields a Boolean", verifiesCore (binding boolType (runtime TextEquals [text "a", text "b"] boolType)))
    ]

-- | A call of the function with an argument of a type each parameter takes.
wellFormed :: RuntimeFunction -> CoreModule
wellFormed function = case runtimeResult function of
    NoResult -> evaluating call
    _ -> binding (runtimeResultType function) call
    where
        call = runtime function (map argument (runtimeParameters function)) (runtimeResultType function)
        argument parameter = case parameter of
            SignedParameter -> count
            UnsignedParameter -> CoreLiteral (CoreInteger 7) (namedType "uint")
            FloatingParameter -> CoreLiteral (CoreFloating "1.5") (namedType "float")
            BoolParameter -> CoreLiteral (CoreBoolean True) boolType
            CharParameter -> CoreLiteral (CoreInteger 65) (namedType "char")
            TextParameter -> text "t"
            CountParameter -> integer 0

-- ----------------------------------------------------------------- CorePrep

corePrepTests :: [(String, Bool)]
corePrepTests =
    [ ("CorePrep accepts well-formed runtime calls", preparedAndVerified writingModule)
    , ("CorePrep accepts a call of every runtime function", all (preparedAndVerified . wellFormed) runtimeFunctions)
    , ( "CorePrep wire carries runtime calls"
      , case prepareCore writingModule of
            Right prepared -> (encodeCorePrep prepared >>= decodeCorePrep) == Right prepared
            Left _ -> False
      )
    , -- The identity stays a literal: it is not bound to a temporary.
      ("CorePrep keeps the identity a literal", identityStaysLiteral)
    , ("CorePrep rejects an unknown identity", rejectsCorePrep stringType [literal 999])
    , ("CorePrep rejects a call without operands", rejectsCorePrep stringType [])
    , ("CorePrep rejects an identity that is a variable", rejectsCorePrep stringType [CorePrepVariable countName intType])
    , ("CorePrep rejects a missing argument", rejectsCorePrep stringType [identity TextConcat, string "a"])
    , ("CorePrep rejects an extra argument", rejectsCorePrep stringType [identity TextNewline, string "a"])
    , ("CorePrep rejects an argument of another type", rejectsCorePrep stringType [identity TextConcat, string "a", CorePrepVariable countName intType])
    , ("CorePrep rejects a result of another type", rejectsCorePrep intType [identity TextConcat, string "a", string "b"])
    , ("CorePrep accepts the same call with its own types", acceptsCorePrep stringType [identity TextConcat, string "a", string "b"])
    ]
    where
        literal value = CorePrepLiteral (CoreInteger value) intType
        identity = literal . runtimeFunctionIdentity
        string value = CorePrepLiteral (CoreString value) stringType

preparedAndVerified :: CoreModule -> Bool
preparedAndVerified moduleValue = case prepareCore moduleValue of
    Right prepared -> verifyCorePrep prepared == Right prepared
    Left _ -> False

identityStaysLiteral :: Bool
identityStaysLiteral = case prepareCore writingModule of
    Right prepared ->
        and
            [ case atoms of
                CorePrepLiteral (CoreInteger _) valueType : _ -> valueType == intType
                _ -> False
            | function <- corePrepModuleFunctions prepared
            , block <- corePrepFunctionBlocks function
            , CorePrepPrimitive CoreRuntimeCall atoms <- map operationOf (corePrepBlockInstructions block)
            ]
    Left _ -> False
    where
        operationOf instruction = case instruction of
            CorePrepBind _ _ _ operation -> operation
            CorePrepEvaluate operation -> operation
            CorePrepAssign _ atom -> CorePrepCopy atom

-- | A CorePrep function that binds a runtime call with the given atoms.
handmade :: Type -> [CorePrepAtom] -> CorePrepModule
handmade valueType atoms =
    CorePrepModule
        (QualifiedName [Identifier "Calls"])
        [ CorePrepFunction
            runName
            ""
            [(countName, intType)]
            intType
            0
            [ CorePrepBlock
                0
                [CorePrepBind lineName valueType False (CorePrepPrimitive CoreRuntimeCall atoms)]
                (CorePrepReturn (CorePrepVariable countName intType))
            ]
        ]
        []

rejectsCorePrep :: Type -> [CorePrepAtom] -> Bool
rejectsCorePrep valueType atoms = case verifyCorePrep (handmade valueType atoms) of
    Left problems -> any ((== "TAC0026") . diagnosticCode) problems
    Right _ -> False

acceptsCorePrep :: Type -> [CorePrepAtom] -> Bool
acceptsCorePrep valueType atoms = let moduleValue = handmade valueType atoms in verifyCorePrep moduleValue == Right moduleValue

-- ---------------------------------------------------------------- optimizer

optimizerTests :: [(String, Bool)]
optimizerTests =
    [ -- A write whose result nothing reads stays: the write is the point.
      ("the optimizer keeps a console write", writes (optimized writingModule) == Just "Count:    42\n")
    , ("the optimizer keeps the order of writes", writes (optimized twoWrites) == Just "first\nsecond\n")
    , ("the optimizer does not repeat a write", writes (optimized boundWrite) == Just "once\n")
    , -- A string that nothing uses is only computed. Whether the optimizer
      -- removes it is its own business; it must not come to be written.
      ("a string that nothing uses is not written", writes (optimized unusedText) == Just "")
    , ("optimized runtime calls still verify", all (maybe False verifiesCore . optimized) [writingModule, twoWrites, boundWrite, unusedText])
    ]
    where
        write value = CoreEvaluate (runtime ConsoleWrite [text value, integer consoleOutputLine] unitType)
        twoWrites = moduleOf [write "first", write "second", CoreReturn count]
        -- The same line is written once however often its string is read.
        boundWrite =
            moduleOf
                [ CoreBind (CoreBinding lineName stringType False (text "once"))
                , CoreEvaluate (runtime ConsoleWrite [CoreVariable lineName stringType, integer consoleOutputLine] unitType)
                , CoreReturn count
                ]
        unusedText =
            moduleOf
                [ CoreBind (CoreBinding lineName stringType False (runtime TextConcat [text "a", text "b"] stringType))
                , CoreReturn count
                ]
        writes moduleValue = do
            value <- moduleValue
            (_, Written output _) <- runFunctionWriting 1000 value "Run" [IntegerValue 42]
            Just output

optimized :: CoreModule -> Maybe CoreModule
optimized moduleValue = either (const Nothing) Just (runCoreOptimizer defaultCoreOptimizer moduleValue)

-- ------------------------------------------------------------------ formats

formatTests :: [(String, Bool)]
formatTests =
    [ ("a format without a percent sign is one literal", parseFormat "plain text" == Right [LiteralPiece "plain text"])
    , ("an empty format has no pieces", parseFormat "" == Right [])
    , ("a conversion alone is one piece", parseFormat "%d" == Right [ConversionPiece (plain SignedDecimal 1)])
    , ( "text and conversions keep their order"
      , parseFormat "a%db%sc"
            == Right
                [ LiteralPiece "a"
                , ConversionPiece (plain SignedDecimal 2)
                , LiteralPiece "b"
                , ConversionPiece (plain Text 5)
                , LiteralPiece "c"
                ]
      )
    , ("every conversion letter is read", map kindOf "duxfscb" == map Just [SignedDecimal, UnsignedDecimal, Hexadecimal, FixedPoint, Text, Character, Truth])
    , ("a conversion is written with the letter it was read from", all (\letter -> fmap conversionLetter (kindOf letter) == Just letter) "duxfscb")
    , -- %% and %n are not conversions of an argument.
      ("a doubled percent sign is a percent sign", parseFormat "100%%" == Right [LiteralPiece "100%"])
    , ("percent signs join the text around them", parseFormat "a%%b%%c" == Right [LiteralPiece "a%b%c"])
    , ("%n is the line terminator", parseFormat "a%nb" == Right [LiteralPiece "a", NewlinePiece, LiteralPiece "b"])
    , ("neither takes an argument", argumentCount "%%%n%%" == Just 0)
    , -- Flags, width and precision.
      ("flags are read in the order written", flagsOf "%-'d" == Just [LeftFlag, GroupFlag])
    , ("a leading zero is a flag and not part of the width", parseFormat "%08d" == Right [ConversionPiece (Conversion SignedDecimal [ZeroFlag] (FixedSize 8) NoSize 1)])
    , ("a width may have several digits", widthOf "%120s" == Just (FixedSize 120))
    , ("a zero inside a width is a digit", widthOf "%10d" == Just (FixedSize 10))
    , ("a precision follows a point", parseFormat "%.3f" == Right [ConversionPiece (Conversion FixedPoint [] NoSize (FixedSize 3) 1)])
    , ("a precision of zero is a precision", precisionOf "%.0f" == Just (FixedSize 0))
    , ("width and precision may both be written", parseFormat "%10.3f" == Right [ConversionPiece (Conversion FixedPoint [] (FixedSize 10) (FixedSize 3) 1)])
    , ("a star is a width from an argument", widthOf "%*d" == Just ArgumentSize)
    , ("a star after a point is a precision from an argument", precisionOf "%.*f" == Just ArgumentSize)
    , ("a conversion takes one argument", argumentCount "%d" == Just 1)
    , ("a star takes one more", argumentCount "%*d" == Just 2)
    , ("two stars take two more", argumentCount "%*.*f" == Just 3)
    , ("the arguments of a format are those of its conversions", argumentCount "%s: %*d (%.2f)%n" == Just 4)
    , -- What the runtime is given for the flags.
      ("no flag is no bit", bitsOf "%d" == Just 0)
    , ("each flag is its bit", map bitsOf ["%-d", "%0d", "%+d", "% d", "%#x", "%'d"] == map Just [1, 2, 4, 8, 16 + 64, 32])
    , ("flags are added", bitsOf "%+08d" == Just (4 + 2))
    , ("%x is the hexadecimal flag of the integer conversions", bitsOf "%x" == Just 64)
    , -- The position a problem is reported at counts from one.
      ("a problem names the position of its conversion", fmap formatProblemOffset (problemOf "abc%q") == Just 4)
    , ("the position counts the conversions before it", fmap formatProblemOffset (problemOf "%d%5d%q") == Just 6)
    , ("a doubled percent sign counts as two characters", fmap formatProblemOffset (problemOf "%%%q") == Just 3)
    ]
        ++ [ ("the format " ++ show format ++ " is rejected with " ++ code, fmap formatProblemCode (problemOf format) == Just code)
           | (format, code) <- rejected
           ]
        ++ [ ("the format " ++ show format ++ " is accepted", either (const False) (const True) (parseFormat format))
           | format <- acceptedFormats
           ]
    where
        plain kind offset = Conversion kind [] NoSize NoSize offset
        single format = case parseFormat format of
            Right [ConversionPiece value] -> Just value
            _ -> Nothing
        kindOf letter = conversionKind <$> single ['%', letter]
        flagsOf = fmap conversionFlags . single
        widthOf = fmap conversionWidth . single
        precisionOf = fmap conversionPrecision . single
        bitsOf = fmap conversionFlagBits . single
        argumentCount format = case parseFormat format of
            Right found -> Just (sum [conversionArgumentCount value | ConversionPiece value <- found])
            Left _ -> Nothing
        problemOf format = either Just (const Nothing) (parseFormat format)
        rejected =
            [ -- Not a conversion, or not finished.
              ("%", "TAT0075")
            , ("abc%", "TAT0075")
            , ("%q", "TAT0075")
            , ("%D", "TAT0075")
            , ("%i", "TAT0075")
            , ("%e", "TAT0075")
            , ("%g", "TAT0075")
            , ("%X", "TAT0075")
            , ("%o", "TAT0075")
            , ("%5", "TAT0075")
            , ("%-", "TAT0075")
            , ("%.", "TAT0075")
            , ("%.f", "TAT0075")
            , ("%5.d", "TAT0075")
            , ("% ", "TAT0075")
            , ("%1234567890d", "TAT0075")
            , ("%.1234567890f", "TAT0075")
            , -- A flag the conversion does not take.
              ("%+s", "TAT0076")
            , ("%0s", "TAT0076")
            , ("% s", "TAT0076")
            , ("%#s", "TAT0076")
            , ("%'s", "TAT0076")
            , ("%#d", "TAT0076")
            , ("%'x", "TAT0076")
            , ("%+x", "TAT0076")
            , ("%+u", "TAT0076")
            , ("% u", "TAT0076")
            , ("%#u", "TAT0076")
            , ("%#f", "TAT0076")
            , ("%0c", "TAT0076")
            , ("%+c", "TAT0076")
            , ("%'c", "TAT0076")
            , ("%0b", "TAT0076")
            , ("%+b", "TAT0076")
            , -- Flags that exclude each other, and a flag written twice.
              ("%-08d", "TAT0076")
            , ("%0-8d", "TAT0076")
            , ("%+ d", "TAT0076")
            , ("% +d", "TAT0076")
            , ("%++d", "TAT0076")
            , ("%--d", "TAT0076")
            , ("%00d", "TAT0076")
            , -- A precision the conversion does not take.
              ("%.2d", "TAT0076")
            , ("%.2u", "TAT0076")
            , ("%.2x", "TAT0076")
            , ("%.1c", "TAT0076")
            , ("%.1b", "TAT0076")
            , ("%.*d", "TAT0076")
            , -- %% and %n take nothing.
              ("%5%", "TAT0076")
            , ("%-%", "TAT0076")
            , ("%.2%", "TAT0076")
            , ("%5n", "TAT0076")
            , ("%-n", "TAT0076")
            , ("%*n", "TAT0076")
            , -- Specified, and waiting for the object model.
              ("%A", "TAT0079")
            , ("%O", "TAT0079")
            , ("%.4A", "TAT0079")
            , ("%#A", "TAT0079")
            ]
        acceptedFormats =
            [ "%d"
            , "%5d"
            , "%-5d"
            , "%05d"
            , "%+d"
            , "% d"
            , "%'d"
            , "%+'010d"
            , "%-+'12d"
            , "%*d"
            , "%-*d"
            , "%u"
            , "%08u"
            , "%'u"
            , "%-'12u"
            , "%x"
            , "%#x"
            , "%08x"
            , "%#010x"
            , "%-#12x"
            , "%f"
            , "%.2f"
            , "%10.3f"
            , "%-10.3f"
            , "%010.3f"
            , "%+.1f"
            , "% .1f"
            , "%'.2f"
            , "%*.*f"
            , "%.*f"
            , "%s"
            , "%10s"
            , "%-10s"
            , "%.5s"
            , "%10.5s"
            , "%*s"
            , "%.*s"
            , "%c"
            , "%3c"
            , "%-3c"
            , "%b"
            , "%6b"
            , "%-6b"
            , "%n"
            , "%%"
            , "Name: %s, Age: %d"
            , "%d%%"
            , "%s%s%s"
            ]
