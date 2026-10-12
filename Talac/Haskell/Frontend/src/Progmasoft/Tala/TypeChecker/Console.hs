-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Text and the console in the type checker.

@System.Console@ is not declared in any source file. Its methods are known
to the compiler, and a call of one is checked here and rewritten into calls
of the runtime: the typed tree that leaves the type checker has no
@Console.Printf@ in it, only the conversions of its format, joined, and one
write. The stages after the type checker therefore need to know nothing of
formats, and a format that is wrong never reaches them.

The same holds for the two operations of the language on strings that need
the runtime: @+@, which joins two strings and writes a value that is not a
string as text first, and @==@ and @\\=@, which compare the characters of
two strings and not the places they are kept.

A runtime call is written in the typed tree as a call of a name whose
symbol is reserved for one function of the runtime catalog; see
'runtimeName'. No source name has such a symbol.
-}
module Progmasoft.Tala.TypeChecker.Console
    ( CheckExpression
    , consoleReceiver
    , checkConsoleCall
    , concatenation
    , textEquality
    , runtimeCall
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.RuntimeCall
import Progmasoft.Tala.TypeChecker.Format
import Progmasoft.Tala.TypeChecker.Returns (typedExpressionType)

{- | The type checker for an expression, given the type its place expects.
This module is called by the checker and calls it back for the arguments.
-}
type CheckExpression =
    Maybe Type -> Expression ResolvedName () -> (Expression ResolvedName Type, Type, [Diagnostic])

type Checked = (Expression ResolvedName Type, Type, [Diagnostic])

{- | Whether the receiver of a member call is the console: @Console@ or
@System.Console@, where neither name has been declared by the program. A
declaration of the program with one of those names is found by the renamer
first and has an ordinary symbol.
-}
consoleReceiver :: Expression ResolvedName () -> Bool
consoleReceiver receiver = case receiver of
    NameExpression _ name _ -> resolvedSymbol name == builtinConsoleSymbol
    MemberAccessExpression _ (NameExpression _ name _) member _ ->
        resolvedSymbol name == builtinSystemSymbol && identifierText member == "Console"
    _ -> False

-- | A call of a runtime function, with the type its row of the catalog gives it.
runtimeCall :: SourceSpan -> RuntimeFunction -> [Expression ResolvedName Type] -> Expression ResolvedName Type
runtimeCall spanValue function arguments =
    CallExpression
        spanValue
        (NameExpression spanValue (runtimeName function) (FunctionType (map typedExpressionType arguments) result))
        arguments
        result
    where
        result = case runtimeResult function of
            NoResult -> voidType
            TextResult -> stringType
            TruthResult -> boolType

integer :: SourceSpan -> Integer -> Expression ResolvedName Type
integer spanValue value = LiteralExpression spanValue (IntegerLiteral value) intType

text :: SourceSpan -> String -> Expression ResolvedName Type
text spanValue value = LiteralExpression spanValue (StringLiteral value) stringType

problem :: SourceSpan -> String -> String -> Diagnostic
problem spanValue code message = Diagnostic TypeCheckerStage Error code (Just spanValue) message

-- | What a failed check leaves in the tree; the diagnostics stop compilation.
failed :: SourceSpan -> [Diagnostic] -> Checked
failed spanValue problems = (LiteralExpression spanValue UnitLiteral ErrorType, ErrorType, problems)

typeName :: Type -> String
typeName valueType = case valueType of
    NamedType (QualifiedName parts) [] | not (null parts) -> identifierText (last parts)
    FunctionType _ _ -> "callable"
    _ -> "value of this type"

-- | The scalar types the runtime does not take yet, with what they wait for.
pendingScalar :: Type -> Maybe String
pendingScalar valueType = case valueType of
    NamedType (QualifiedName [Identifier name]) []
        | name `elem` ["longint", "ulongint"] -> Just "128-bit integers are not written as text yet"
        | name == "double" -> Just "128-bit floating-point numbers are not written as text yet"
    _ -> Nothing

isFloating :: Type -> Bool
isFloating = runtimeAccepts FloatingParameter

{- | A value as text, the way @Console.Print@ and @+@ write it: a string is
itself, an integer is written in decimal, a Boolean as @true@ or @false@ and
a character as itself. A floating-point number has no form of its own here:
how many digits to write is a decision @%f@ makes with its precision.
-}
asText :: SourceSpan -> Expression ResolvedName Type -> Type -> Either [Diagnostic] (Expression ResolvedName Type)
asText spanValue value valueType
    | valueType == ErrorType = Left []
    | valueType == stringType = Right value
    | runtimeAccepts SignedParameter valueType = Right (runtimeCall spanValue TextFromSigned [value])
    | runtimeAccepts UnsignedParameter valueType = Right (runtimeCall spanValue TextFromUnsigned [value])
    | runtimeAccepts BoolParameter valueType = Right (runtimeCall spanValue TextFromBool [value])
    | runtimeAccepts CharParameter valueType = Right (runtimeCall spanValue TextFromChar [value])
    | Just reason <- pendingScalar valueType = Left [problem spanValue "TAT0079" reason]
    | isFloating valueType =
        Left
            [ problem
                spanValue
                "TAT0079"
                "a floating-point number has no text form of its own yet; write it with Console.Printf or Console.Format and %f"
            ]
    | otherwise =
        Left [problem spanValue "TAT0073" ("a " ++ typeName valueType ++ " cannot be written as text")]

{- | @left + right@ where at least one side is a string: the two as text,
joined. The operands are already checked.
-}
concatenation :: SourceSpan -> (Expression ResolvedName Type, Type) -> (Expression ResolvedName Type, Type) -> Checked
concatenation spanValue (left, leftType) (right, rightType) =
    case (asText (expressionSourceSpan left) left leftType, asText (expressionSourceSpan right) right rightType) of
        (Right first, Right second) -> (runtimeCall spanValue TextConcat [first, second], stringType, [])
        (first, second) -> failed spanValue (either id (const []) first ++ either id (const []) second)

{- | @left == right@ or @left \\= right@ on two strings: whether they hold
the same characters.
-}
textEquality :: SourceSpan -> Bool -> Expression ResolvedName Type -> Expression ResolvedName Type -> Checked
textEquality spanValue equal left right =
    ( if equal then same else UnaryExpression spanValue LogicalNot same boolType
    , boolType
    , []
    )
    where
        same = runtimeCall spanValue TextEquals [left, right]

{- | Check a call of a method of the console and rewrite it into runtime
calls.
-}
checkConsoleCall :: CheckExpression -> SourceSpan -> Identifier -> [Expression ResolvedName ()] -> Checked
checkConsoleCall check callSpan member arguments = case identifierText member of
    "Print" -> write consoleOutput
    "Println" -> write consoleOutputLine
    "Error" -> write consoleError
    "Errorln" -> write consoleErrorLine
    "Printf" -> formatted (Just consoleOutput)
    "Printfn" -> formatted (Just consoleOutputLine)
    "Errorf" -> formatted (Just consoleError)
    "Errorfn" -> formatted (Just consoleErrorLine)
    "Format" -> formatted Nothing
    name
        | name `elem` ["Stdin", "Stdout", "Stderr"] ->
            failed
                callSpan
                ( argumentProblems
                    ++ [problem callSpan "TAT0079" ("Console." ++ name ++ " needs stream objects and is not implemented yet")]
                )
        | otherwise ->
            failed callSpan (argumentProblems ++ [problem callSpan "TAT0071" ("Console has no method named " ++ name)])
    where
        method = "Console." ++ identifierText member
        argumentProblems = concat [problems | (_, _, problems) <- map (check Nothing) arguments]

        -- One value, written as text.
        write target = case arguments of
            [argument] ->
                let (value, valueType, problems) = check Nothing argument
                 in case asText (expressionSourceSpan value) value valueType of
                        Right written ->
                            (runtimeCall callSpan ConsoleWrite [written, integer callSpan target], voidType, problems)
                        Left more -> failed callSpan (problems ++ more)
            _ ->
                failed
                    callSpan
                    ( argumentProblems
                        ++ [problem callSpan "TAT0072" (method ++ " takes one argument; " ++ given (length arguments))]
                    )

        -- A format and its arguments: written when there is a target, and
        -- the string itself when there is none.
        formatted target = case arguments of
            [] -> failed callSpan [problem callSpan "TAT0072" (method ++ " takes a format; " ++ given 0)]
            formatArgument : values -> case formatArgument of
                LiteralExpression formatSpan (StringLiteral format) _ -> case parseFormat format of
                    Left wrong ->
                        failed
                            callSpan
                            ( concat [problems | (_, _, problems) <- map (check Nothing) values]
                                ++ [ problem
                                        formatSpan
                                        (formatProblemCode wrong)
                                        ( formatProblemMessage wrong
                                            ++ " (character "
                                            ++ show (formatProblemOffset wrong)
                                            ++ " of the format)"
                                        )
                                   ]
                            )
                    Right parsed ->
                        let needed = sum [conversionArgumentCount value | ConversionPiece value <- parsed]
                         in if needed /= length values
                                then
                                    failed
                                        callSpan
                                        ( concat [problems | (_, _, problems) <- map (check Nothing) values]
                                            ++ [ problem
                                                    callSpan
                                                    "TAT0077"
                                                    ( "the format of "
                                                        ++ method
                                                        ++ " takes "
                                                        ++ counted needed
                                                        ++ " after it; "
                                                        ++ given (length values)
                                                    )
                                               ]
                                        )
                                else finish target (convert formatSpan parsed values)
                _ ->
                    failed
                        callSpan
                        ( argumentProblems
                            ++ [ problem
                                    (expressionSourceSpan formatArgument)
                                    "TAT0074"
                                    ("the format of " ++ method ++ " must be a string literal, so that it can be checked when the program is compiled")
                               ]
                        )

        finish target (pieces, problems)
            | not (null problems) = failed callSpan problems
            | otherwise =
                let joined = case pieces of
                        [] -> text callSpan ""
                        first : rest -> foldl (\whole part -> runtimeCall callSpan TextConcat [whole, part]) first rest
                 in case target of
                        Just stream -> (runtimeCall callSpan ConsoleWrite [joined, integer callSpan stream], voidType, [])
                        Nothing -> (joined, stringType, [])

        -- Each piece of the format as a string expression, taking the
        -- arguments in the order the conversions name them.
        convert _ [] _ = ([], [])
        convert formatSpan (piece : later) values = case piece of
            LiteralPiece literal -> prepend (text formatSpan literal, []) (convert formatSpan later values)
            NewlinePiece -> prepend (runtimeCall formatSpan TextNewline [], []) (convert formatSpan later values)
            ConversionPiece value ->
                let (width, afterWidth, widthProblems) = size (conversionWidth value) values
                    (precision, afterPrecision, precisionProblems) = size (conversionPrecision value) afterWidth
                 in case afterPrecision of
                        argument : remaining ->
                            let (converted, valueProblems) = converting value width precision argument
                             in prepend
                                    (converted, widthProblems ++ precisionProblems ++ valueProblems)
                                    (convert formatSpan later remaining)
                        -- The count was checked before; nothing is missing.
                        [] -> ([], widthProblems ++ precisionProblems)
        prepend (piece, problems) (pieces, more) = (piece : pieces, problems ++ more)

        -- A width or a precision: absent, written in the format, or the
        -- next argument, which is an int.
        size written values = case written of
            NoSize -> (integer callSpan absent, values, [])
            FixedSize amount -> (integer callSpan amount, values, [])
            ArgumentSize -> case values of
                argument : remaining ->
                    let (value, valueType, problems) = check (Just intType) argument
                        mismatch =
                            [ problem
                                (expressionSourceSpan value)
                                "TAT0078"
                                ("a width or a precision written as * takes an int, and the argument is a " ++ typeName valueType)
                            | valueType /= ErrorType
                            , valueType /= intType
                            ]
                     in (value, remaining, problems ++ mismatch)
                [] -> (integer callSpan absent, values, [])

        converting value width precision argument =
            let kind = conversionKind value
                (typed, valueType, problems) = check (expectedFor kind) argument
                spanValue = expressionSourceSpan typed
                flags = integer spanValue (conversionFlagBits value)
                call function operand = runtimeCall spanValue function [flags, width, precision, operand]
                plain = null (conversionFlags value) && conversionWidth value == NoSize && conversionPrecision value == NoSize
                mismatch wanted =
                    ( typed
                    , problems
                        ++ [ problem
                                spanValue
                                "TAT0078"
                                ( "the conversion %"
                                    ++ [conversionLetter kind]
                                    ++ " takes "
                                    ++ wanted
                                    ++ ", and the argument is a "
                                    ++ typeName valueType
                                )
                           | valueType /= ErrorType
                           ]
                    )
                accepted
                    | valueType == ErrorType = (typed, problems)
                    | Just reason <- pendingScalar valueType = (typed, problems ++ [problem spanValue "TAT0079" reason])
                    | otherwise = case kind of
                        SignedDecimal
                            | runtimeAccepts SignedParameter valueType -> (call TextFormatSigned typed, problems)
                            | otherwise -> mismatch "a signed integer"
                        UnsignedDecimal
                            | runtimeAccepts UnsignedParameter valueType -> (call TextFormatUnsigned typed, problems)
                            | otherwise -> mismatch "an unsigned integer"
                        Hexadecimal
                            | runtimeAccepts SignedParameter valueType -> (call TextFormatSigned typed, problems)
                            | runtimeAccepts UnsignedParameter valueType -> (call TextFormatUnsigned typed, problems)
                            | otherwise -> mismatch "an integer"
                        FixedPoint
                            | isFloating valueType -> (call TextFormatFloating typed, problems)
                            | otherwise -> mismatch "a floating-point number"
                        Text
                            | valueType /= stringType -> mismatch "a String"
                            | plain -> (typed, problems)
                            | otherwise -> (call TextFormatString typed, problems)
                        Character
                            | runtimeAccepts CharParameter valueType -> (call TextFormatChar typed, problems)
                            | otherwise -> mismatch "a char"
                        Truth
                            | not (runtimeAccepts BoolParameter valueType) -> mismatch "a bool"
                            | plain -> (runtimeCall spanValue TextFromBool [typed], problems)
                            | otherwise -> (call TextFormatString (runtimeCall spanValue TextFromBool [typed]), problems)
             in accepted

        -- A literal has the type its conversion takes; a value that already
        -- has a type keeps it and is then held to the conversion.
        expectedFor kind = case kind of
            UnsignedDecimal -> Just (namedType "uint")
            FixedPoint -> Just (namedType "float")
            _ -> Nothing

        counted :: Int -> String
        counted amount = case amount of
            0 -> "no argument"
            1 -> "one argument"
            _ -> show amount ++ " arguments"

        given :: Int -> String
        given amount = case amount of
            0 -> "none was given"
            1 -> "one was given"
            _ -> show amount ++ " were given"
