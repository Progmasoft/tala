-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | The catalog of runtime calls.

A runtime call is an operation the compiler does not lower to instructions
but to a call of a function of the Tala runtime: joining two strings,
converting a number for output, writing to the console. Core and the stages
after it carry it as one operation whose first operand is an integer
literal, the identity of the function, and whose remaining operands are the
arguments.

This module is what the frontend knows about each function: its identity,
the types it takes and returns, and whether it does something that can be
observed. The native stages have the same table in
@Tala\/Core\/RuntimeCall.hpp@. The identities are part of the
artifact formats: a function is never renumbered, and a new one takes the
next free number. The tests of both sides pin every row.

The catalog stands in the syntax package because the type checker, which
chooses the function for a source construct, and Core, which verifies the
call, both need it and neither depends on the other.
-}
module Progmasoft.Tala.RuntimeCall
    ( RuntimeFunction (..)
    , RuntimeParameter (..)
    , RuntimeResult (..)
    , runtimeFunctions
    , runtimeFunctionIdentity
    , runtimeFunctionOf
    , runtimeFunctionSymbol
    , runtimeParameters
    , runtimeResult
    , runtimeResultType
    , runtimeObservable
    , runtimeAccepts
    , runtimeName
    , runtimeFunctionOfName
    , builtinSystemSymbol
    , builtinConsoleSymbol
    , builtinTestSymbol
    , RuntimeDefect (..)
    , runtimeCallDefect
    , runtimeDefectText

      -- * Conversion flags
    , flagLeft
    , flagZero
    , flagPlus
    , flagSpace
    , flagAlternate
    , flagGroup
    , flagHexadecimal
    , absent

      -- * Console targets
    , consoleOutput
    , consoleOutputLine
    , consoleError
    , consoleErrorLine
    ) where

import Progmasoft.Tala.AST

-- | A function of the runtime that generated code may call.
data RuntimeFunction
    = -- | Two strings one after the other.
      TextConcat
    | -- | A signed integer in decimal.
      TextFromSigned
    | -- | An unsigned integer in decimal.
      TextFromUnsigned
    | -- | @true@ or @false@.
      TextFromBool
    | -- | The one character.
      TextFromChar
    | -- | @%d@ and @%x@ of a signed integer.
      TextFormatSigned
    | -- | @%u@ and @%x@ of an unsigned integer.
      TextFormatUnsigned
    | -- | @%f@.
      TextFormatFloating
    | -- | @%s@.
      TextFormatString
    | -- | @%c@.
      TextFormatChar
    | -- | @%n@: the line terminator of the platform.
      TextNewline
    | -- | Write a string to standard output or standard error.
      ConsoleWrite
    | -- | Whether two strings hold the same characters.
      TextEquals
    | -- | Record a failed @#expect@ of the current test and write its report.
      TestFail
    | -- | Close the current test, named by the argument, and write whether it passed.
      TestEnd
    | {- | Write how many tests passed and failed. A failure makes the
      program end with a nonzero status.
      -}
      TestFinish
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

{- | What an argument of a runtime function may be. A function takes a family
of types where the language gives the operation to all of them; the backend
widens the argument to the representation the runtime function is written
for, which changes no value.
-}
data RuntimeParameter
    = -- | A signed integer of at most 64 bits.
      SignedParameter
    | -- | An unsigned integer of at most 64 bits.
      UnsignedParameter
    | -- | A floating-point number of at most 64 bits.
      FloatingParameter
    | -- | @bool@.
      BoolParameter
    | -- | @char@.
      CharParameter
    | -- | @String@.
      TextParameter
    | -- | @int@: flags, a width or a precision.
      CountParameter
    deriving (Eq, Ord, Read, Show)

-- | What a runtime function returns.
data RuntimeResult
    = -- | No value.
      NoResult
    | -- | A @String@ the caller owns.
      TextResult
    | -- | A @bool@.
      TruthResult
    deriving (Eq, Ord, Read, Show)

-- | Every runtime function, in order of identity.
runtimeFunctions :: [RuntimeFunction]
runtimeFunctions = [minBound .. maxBound]

-- | The identity the first operand of a call holds.
runtimeFunctionIdentity :: RuntimeFunction -> Integer
runtimeFunctionIdentity function = case function of
    TextConcat -> 1
    TextFromSigned -> 2
    TextFromUnsigned -> 3
    TextFromBool -> 4
    TextFromChar -> 5
    TextFormatSigned -> 6
    TextFormatUnsigned -> 7
    TextFormatFloating -> 8
    TextFormatString -> 9
    TextFormatChar -> 10
    TextNewline -> 11
    ConsoleWrite -> 12
    TextEquals -> 13
    TestFail -> 14
    TestEnd -> 15
    TestFinish -> 16

-- | The function with the given identity, when there is one.
runtimeFunctionOf :: Integer -> Maybe RuntimeFunction
runtimeFunctionOf identity = lookup identity [(runtimeFunctionIdentity function, function) | function <- runtimeFunctions]

-- | The symbol of the runtime library that implements the function.
runtimeFunctionSymbol :: RuntimeFunction -> String
runtimeFunctionSymbol function = case function of
    TextConcat -> "tala_text_concat"
    TextFromSigned -> "tala_text_from_signed"
    TextFromUnsigned -> "tala_text_from_unsigned"
    TextFromBool -> "tala_text_from_bool"
    TextFromChar -> "tala_text_from_char"
    TextFormatSigned -> "tala_text_format_signed"
    TextFormatUnsigned -> "tala_text_format_unsigned"
    TextFormatFloating -> "tala_text_format_floating"
    TextFormatString -> "tala_text_format_string"
    TextFormatChar -> "tala_text_format_char"
    TextNewline -> "tala_text_newline"
    ConsoleWrite -> "tala_console_write"
    TextEquals -> "tala_text_equals"
    TestFail -> "tala_test_fail"
    TestEnd -> "tala_test_end"
    TestFinish -> "tala_test_finish"

-- | The arguments of the function, in order.
runtimeParameters :: RuntimeFunction -> [RuntimeParameter]
runtimeParameters function = case function of
    TextConcat -> [TextParameter, TextParameter]
    TextFromSigned -> [SignedParameter]
    TextFromUnsigned -> [UnsignedParameter]
    TextFromBool -> [BoolParameter]
    TextFromChar -> [CharParameter]
    TextFormatSigned -> conversion SignedParameter
    TextFormatUnsigned -> conversion UnsignedParameter
    TextFormatFloating -> conversion FloatingParameter
    TextFormatString -> conversion TextParameter
    TextFormatChar -> conversion CharParameter
    TextNewline -> []
    ConsoleWrite -> [TextParameter, CountParameter]
    TextEquals -> [TextParameter, TextParameter]
    TestFail -> [TextParameter]
    TestEnd -> [TextParameter]
    TestFinish -> []
    where
        -- Flags, width and precision, and then the value. The value stands
        -- last because that is the order of a format's arguments: a width
        -- or a precision written as @*@ is the argument before the value,
        -- and the operands of a call are evaluated in order.
        conversion value = [CountParameter, CountParameter, CountParameter, value]

-- | What the function returns.
runtimeResult :: RuntimeFunction -> RuntimeResult
runtimeResult function = case function of
    ConsoleWrite -> NoResult
    TextEquals -> TruthResult
    TestFail -> NoResult
    TestEnd -> NoResult
    TestFinish -> NoResult
    _ -> TextResult

-- | The type a call of the function has.
runtimeResultType :: RuntimeFunction -> Type
runtimeResultType function = case runtimeResult function of
    NoResult -> unitType
    TextResult -> stringType
    TruthResult -> boolType

{- | Whether a call does something that can be observed apart from its
result. Such a call is an effect: it happens where it is written, and it is
never removed, repeated or moved.
-}
runtimeObservable :: RuntimeFunction -> Bool
runtimeObservable function = function `elem` [ConsoleWrite, TestFail, TestEnd, TestFinish]

-- | Whether an argument of the given type may stand where the parameter is.
runtimeAccepts :: RuntimeParameter -> Type -> Bool
runtimeAccepts parameter valueType = case parameter of
    SignedParameter -> spelling `elem` ["byte", "short", "long", "int"]
    UnsignedParameter -> spelling `elem` ["ubyte", "ushort", "ulong", "uint"]
    FloatingParameter -> spelling `elem` ["sfloat", "lfloat", "float"]
    BoolParameter -> spelling == "bool"
    CharParameter -> spelling == "char"
    TextParameter -> spelling == "String"
    CountParameter -> spelling == "int"
    where
        spelling = case valueType of
            NamedType (QualifiedName [Identifier name]) [] -> name
            _ -> ""

{- | The name a call of a runtime function has in the typed tree.

The type checker rewrites a source construct that needs the runtime into a
call of this name, and the lowering to Core turns a call of it into a
runtime call. Its symbol is reserved: the renamer gives every declaration of
a program a positive symbol, so no source name is ever one of these. The
spelling begins with a character no identifier may contain.
-}
runtimeName :: RuntimeFunction -> ResolvedName
runtimeName function =
    ResolvedName
        (SymbolId (negate (runtimeNameBase + fromInteger (runtimeFunctionIdentity function))))
        (Identifier ('$' : runtimeFunctionSymbol function))

-- | The runtime function a name of the typed tree stands for, if it is one.
runtimeFunctionOfName :: ResolvedName -> Maybe RuntimeFunction
runtimeFunctionOfName name =
    let value = negate (symbolIdValue (resolvedSymbol name)) - runtimeNameBase
     in if value > 0 then runtimeFunctionOf (toInteger value) else Nothing

runtimeNameBase :: Int
runtimeNameBase = 1000

{- | The symbols of the two names the language declares for every program:
@System@ and, because @System@ is imported implicitly, @Console@. A
declaration of the program with one of these names shadows it.
-}
builtinSystemSymbol, builtinConsoleSymbol :: SymbolId
builtinSystemSymbol = SymbolId (-2)
builtinConsoleSymbol = SymbolId (-3)

{- | The symbol of @$Test@, the receiver of the calls @#expect@ and the
runner of a test build make of the test runtime. No source can spell it.
-}
builtinTestSymbol :: SymbolId
builtinTestSymbol = SymbolId (-4)

-- | Why a runtime call is malformed.
data RuntimeDefect
    = -- | No first operand, or one that names no function of the catalog.
      DefectiveIdentity
    | -- | The number of arguments is not the number the function takes.
      DefectiveArity
    | -- | An argument has a type its parameter does not accept.
      DefectiveArgument
    | -- | The call does not have the type the function returns.
      DefectiveResult
    deriving (Eq, Ord, Read, Show)

{- | Check a runtime call: the function its first operand names, if it names
one, the types of the arguments after it, and the type of the call.
-}
runtimeCallDefect :: Maybe RuntimeFunction -> [Type] -> Type -> Maybe RuntimeDefect
runtimeCallDefect named arguments resultType = case named of
    Nothing -> Just DefectiveIdentity
    Just function
        | length arguments /= length (runtimeParameters function) -> Just DefectiveArity
        | not (and (zipWith runtimeAccepts (runtimeParameters function) arguments)) -> Just DefectiveArgument
        | resultType /= runtimeResultType function -> Just DefectiveResult
        | otherwise -> Nothing

-- | What is wrong with a call, in the words every stage reports.
runtimeDefectText :: RuntimeDefect -> String
runtimeDefectText defect = case defect of
    DefectiveIdentity -> "runtime call must begin with an integer literal that names a function of the runtime catalog"
    DefectiveArity -> "runtime call has the wrong number of arguments for its function"
    DefectiveArgument -> "runtime call argument has a type its function does not take"
    DefectiveResult -> "runtime call does not have the type its function returns"

{- | The flags of a conversion, combined by addition in the @flags@ argument
of the formatting functions. The values are those of @TALA_TEXT_FLAG_*@ in
the runtime header.
-}
flagLeft, flagZero, flagPlus, flagSpace, flagAlternate, flagGroup, flagHexadecimal :: Integer
flagLeft = 1
flagZero = 2
flagPlus = 4
flagSpace = 8
flagAlternate = 16
flagGroup = 32
flagHexadecimal = 64

-- | A width or a precision that a conversion does not have.
absent :: Integer
absent = -1

{- | Where a console write goes and whether a line ends after it: the second
argument of 'ConsoleWrite'. The values are those of @TALA_CONSOLE_*@.
-}
consoleOutput, consoleOutputLine, consoleError, consoleErrorLine :: Integer
consoleOutput = 0
consoleOutputLine = 1
consoleError = 2
consoleErrorLine = 3
