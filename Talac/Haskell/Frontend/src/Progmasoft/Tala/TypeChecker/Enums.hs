-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Classic enums: their members, their values and their rules.

A classic enum is a value type whose members are named integers of one
underlying type. Members are numbered from zero, a member without a written
value takes the value after that of the member before it, and two members
may have the same value. A written value is a constant integer expression:
integer literals and earlier members of the same enum, joined by the
arithmetic, shift and bitwise operators. Inside its own declaration the name
of a member stands for its number; that is where the numbers behind the names
are defined, and it is the only place where a member is a number. An enum is
a type of its own: its values are
compared with @==@ and @\\=@ and with nothing else, and there is no
conversion between an enum and an integer in either direction.

The checker reads the enums of a source set into a table before it checks
any body, so that a use may precede the declaration.
-}
module Progmasoft.Tala.TypeChecker.Enums
    ( EnumInfo (..)
    , enumInfos
    , enumBySymbol
    , enumBySpelling
    , enumMemberValue
    , enumDeclarationProblems
    , isEnumType
    ) where

import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.ConstantEvaluation
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.TypeChecker.Literals (problem)

-- | What the checker knows of one enum.
data EnumInfo = EnumInfo
    { enumInfoName :: ResolvedName
    -- ^ The declared name and its symbol.
    , enumInfoType :: Type
    -- ^ The type of its values, as 'enumType' encodes it.
    , enumInfoMembers :: [(Identifier, Integer)]
    -- ^ Its members in source order, each with its value.
    }

-- | The enums among the declarations of a source set.
enumInfos :: [Declaration ResolvedName ()] -> [EnumInfo]
enumInfos declarations =
    [ EnumInfo name (enumType (resolvedSpelling name) valueType (sort (nub (map snd members)))) members
    | EnumDeclaration _ name _ underlying cases <- declarations
    , let valueType = underlyingType underlying
    , let members = [(enumCaseName member, value) | (member, value, _) <- numbered valueType cases]
    ]

{- | Each member with its value: the written one, or one more than the last,
and what is wrong with the written one when it has no value. A member whose
written value has none is numbered as if nothing had been written, so that
one mistake is reported once and the members after it keep their numbers.
-}
numbered :: Type -> [EnumCase] -> [(EnumCase, Integer, Maybe String)]
numbered valueType = go 0 Map.empty
    where
        go _ _ [] = []
        go next earlier (member : remaining) =
            let (value, issue) = case enumCaseValue member of
                    Nothing -> (next, Nothing)
                    Just written -> case memberConstant valueType earlier written of
                        Right computed -> (computed, Nothing)
                        Left reason -> (next, Just reason)
             in (member, value, issue) : go (value + 1) (Map.insert (enumCaseName member) value earlier) remaining

{- | The value of a constant integer expression written for a member, given
the values of the members before it.

The expression is given the underlying type of the enum and the earlier
members their numbers, and the constant evaluator of the language computes
it: the same arithmetic, the same rounding of @//@, the same complement of
@!@ for the width and signedness of the type, and the same refusal of a
division by zero as anywhere else in a program.
-}
memberConstant :: Type -> Map.Map Identifier Integer -> Expression Identifier () -> Either String Integer
memberConstant valueType earlier written = do
    typed <- typedConstant written
    case evaluateConstantInteger typed of
        Right (Just value) -> Right value
        Right Nothing -> Left notConstant
        Left issue -> Left (renderConstantIntegerError issue)
    where
        typedConstant :: Expression Identifier () -> Either String (Expression Identifier Type)
        typedConstant expression = case expression of
            LiteralExpression spanValue (IntegerLiteral value) _ ->
                Right (LiteralExpression spanValue (IntegerLiteral value) valueType)
            NameExpression spanValue name _ -> case Map.lookup name earlier of
                Just value -> Right (LiteralExpression spanValue (IntegerLiteral value) valueType)
                Nothing -> Left (identifierText name ++ " is not an earlier member of this enum")
            UnaryExpression spanValue operator value _
                | operator `elem` [UnaryPlus, UnaryNegate, BitwiseNot] ->
                    (\operand -> UnaryExpression spanValue operator operand valueType) <$> typedConstant value
            BinaryExpression spanValue operator left right _
                | operator `elem` constantOperators ->
                    (\first second -> BinaryExpression spanValue operator first second valueType)
                        <$> typedConstant left
                        <*> typedConstant right
            _ -> Left notConstant
        constantOperators =
            [ Add
            , Subtract
            , Multiply
            , Divide
            , FloorDivide
            , Remainder
            , Power
            , ShiftLeft
            , ShiftRight
            , BitwiseAnd
            , BitwiseXor
            , BitwiseOr
            ]
        notConstant =
            "the value of an enum member is a constant integer expression: integer literals and earlier members of "
                ++ "the enum, joined by arithmetic, shift and bitwise operators"

{- | The underlying type an enum declares, @int@ when it declares none. A
type that is not an integer type is reported by 'enumDeclarationProblems';
the enum is then checked as if it had declared none.
-}
underlyingType :: Maybe TypeSyntax -> Type
underlyingType syntax = maybe intType scalarTypeToType (syntax >>= integerScalar)

integerScalar :: TypeSyntax -> Maybe ScalarType
integerScalar syntax = case syntax of
    ExplicitType (Identifier spelling) ->
        case [scalar | scalar <- scalarTypes, scalarTypeName scalar == spelling, isInteger scalar] of
            scalar : _ -> Just scalar
            [] -> Nothing
    _ -> Nothing
    where
        isInteger scalar = scalarTypeFamily scalar `elem` [SignedIntegerFamily, UnsignedIntegerFamily]

-- | The enum a name in an expression refers to.
enumBySymbol :: [EnumInfo] -> SymbolId -> Maybe EnumInfo
enumBySymbol enums symbol = case [info | info <- enums, resolvedSymbol (enumInfoName info) == symbol] of
    info : _ -> Just info
    [] -> Nothing

-- | The enum a name in a type refers to.
enumBySpelling :: [EnumInfo] -> Identifier -> Maybe EnumInfo
enumBySpelling enums spelling = case [info | info <- enums, resolvedSpelling (enumInfoName info) == spelling] of
    info : _ -> Just info
    [] -> Nothing

-- | The value of a member of the enum with the given type.
enumMemberValue :: [EnumInfo] -> Type -> Identifier -> Maybe Integer
enumMemberValue enums valueType member =
    case [value | info <- enums, enumInfoType info == valueType, (name, value) <- enumInfoMembers info, name == member] of
        value : _ -> Just value
        [] -> Nothing

-- | Whether a type is the type of an enum.
isEnumType :: Type -> Bool
isEnumType valueType = case enumUnderlyingType valueType of
    Just _ -> True
    Nothing -> False

{- | The problems of an enum declaration by itself: an underlying type that
is not an integer type, a member named twice, a written value that is not a
constant integer expression or has no value, and a value its underlying type
cannot hold.
-}
enumDeclarationProblems :: Declaration ResolvedName () -> [Diagnostic]
enumDeclarationProblems declaration = case declaration of
    EnumDeclaration spanValue _ _ underlying cases ->
        let scalar = maybe (Just defaultScalar) integerScalar underlying
            members = numbered (underlyingType underlying) cases
         in [ problem spanValue "TAT0066" "the underlying type of an enum must be an integer type"
            | Nothing <- [scalar]
            ]
                ++ [ problem
                        (enumCaseSpan member)
                        "TAT0067"
                        ("the enum already has a member named " ++ identifierText (enumCaseName member))
                   | (index, member) <- zip [0 :: Int ..] cases
                   , enumCaseName member `elem` map enumCaseName (take index cases)
                   ]
                ++ [ problem (enumCaseSpan member) "TAT0070" reason
                   | (member, _, Just reason) <- members
                   ]
                ++ [ problem
                        (enumCaseSpan member)
                        "TAT0068"
                        ( "the value "
                            ++ show value
                            ++ " of this enum member does not fit "
                            ++ scalarTypeName (maybe defaultScalar id scalar)
                        )
                   | (member, value, Nothing) <- members
                   , not (integerFits (maybe defaultScalar id scalar) value)
                   ]
    _ -> []
    where
        defaultScalar = defaultIntegerScalar
