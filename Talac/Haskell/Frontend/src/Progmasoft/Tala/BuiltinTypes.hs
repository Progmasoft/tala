-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Canonical built-in scalar descriptions shared by type checking and Core.
Widths here are language widths, never host-machine widths.
-}
module Progmasoft.Tala.BuiltinTypes
    ( ScalarFamily (..)
    , ScalarType (..)
    , scalarTypes
    , scalarTypeName
    , scalarTypeWidth
    , scalarTypeFamily
    , scalarTypeSigned
    , scalarWrapperName
    , wrapperNameToScalarType
    , scalarTypeRank
    , widerScalarType
    , scalarTypeToType
    , typeToScalarType
    , isIntegerType
    , isSignedIntegerType
    , isUnsignedIntegerType
    , isFloatingType
    , isNumericType
    , integerMinimum
    , integerMaximum
    , integerFits
    , defaultIntegerScalar
    , defaultFloatingScalar
    ) where

import Progmasoft.Tala.AST

-- | Semantic family used to group built-in scalar types for operator rules.
data ScalarFamily = CharacterFamily | BooleanFamily | SignedIntegerFamily | UnsignedIntegerFamily | FloatingFamily
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

-- | Closed inventory of Tala built-in scalar types.
data ScalarType
    = -- | Unicode scalar-value character type.
      CharacterScalar
    | -- | Boolean type with an 8-bit storage width.
      BooleanScalar
    | -- | 8-bit signed integer.
      ByteScalar
    | -- | 16-bit signed integer.
      ShortScalar
    | -- | 32-bit signed integer.
      LongScalar
    | -- | 64-bit signed integer and default integer type.
      IntScalar
    | -- | 128-bit signed integer.
      LongIntScalar
    | -- | 8-bit unsigned integer.
      UByteScalar
    | -- | 16-bit unsigned integer.
      UShortScalar
    | -- | 32-bit unsigned integer.
      ULongScalar
    | -- | 64-bit unsigned integer.
      UIntScalar
    | -- | 128-bit unsigned integer.
      ULongIntScalar
    | -- | 16-bit floating-point type.
      SFloatScalar
    | -- | 32-bit floating-point type.
      LFloatScalar
    | -- | 64-bit floating-point type and default float.
      FloatScalar
    | -- | 128-bit floating-point type.
      DoubleScalar
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

-- | All built-in scalar types in canonical declaration/rank order.
scalarTypes :: [ScalarType]
scalarTypes = [minBound .. maxBound]

-- | Return the lowercase source spelling of a scalar type.
scalarTypeName :: ScalarType -> String
scalarTypeName scalar = case scalar of
    CharacterScalar -> "char"
    BooleanScalar -> "bool"
    ByteScalar -> "byte"
    ShortScalar -> "short"
    LongScalar -> "long"
    IntScalar -> "int"
    LongIntScalar -> "longint"
    UByteScalar -> "ubyte"
    UShortScalar -> "ushort"
    ULongScalar -> "ulong"
    UIntScalar -> "uint"
    ULongIntScalar -> "ulongint"
    SFloatScalar -> "sfloat"
    LFloatScalar -> "lfloat"
    FloatScalar -> "float"
    DoubleScalar -> "double"

-- | Return the language-defined storage width, independent of host architecture.
scalarTypeWidth :: ScalarType -> Int
scalarTypeWidth scalar = case scalar of
    CharacterScalar -> 32
    BooleanScalar -> 8
    ByteScalar -> 8
    ShortScalar -> 16
    LongScalar -> 32
    IntScalar -> 64
    LongIntScalar -> 128
    UByteScalar -> 8
    UShortScalar -> 16
    ULongScalar -> 32
    UIntScalar -> 64
    ULongIntScalar -> 128
    SFloatScalar -> 16
    LFloatScalar -> 32
    FloatScalar -> 64
    DoubleScalar -> 128

-- | Classify a scalar by its semantic arithmetic family.
scalarTypeFamily :: ScalarType -> ScalarFamily
scalarTypeFamily scalar = case scalar of
    CharacterScalar -> CharacterFamily
    BooleanScalar -> BooleanFamily
    ByteScalar -> SignedIntegerFamily
    ShortScalar -> SignedIntegerFamily
    LongScalar -> SignedIntegerFamily
    IntScalar -> SignedIntegerFamily
    LongIntScalar -> SignedIntegerFamily
    UByteScalar -> UnsignedIntegerFamily
    UShortScalar -> UnsignedIntegerFamily
    ULongScalar -> UnsignedIntegerFamily
    UIntScalar -> UnsignedIntegerFamily
    ULongIntScalar -> UnsignedIntegerFamily
    SFloatScalar -> FloatingFamily
    LFloatScalar -> FloatingFamily
    FloatScalar -> FloatingFamily
    DoubleScalar -> FloatingFamily

-- | Test whether a scalar uses signed integer arithmetic.
scalarTypeSigned :: ScalarType -> Bool
scalarTypeSigned scalar = scalarTypeFamily scalar == SignedIntegerFamily

-- Wrapper names are canonical system types used by contextual Of(value: ...)
-- insertion. Keeping the table beside scalar widths prevents wrapper and
-- primitive catalogs from drifting as the standard library grows.

-- | Resolve the canonical @System.*@ wrapper name for contextual conversions.
scalarWrapperName :: ScalarType -> QualifiedName
scalarWrapperName scalar = QualifiedName [Identifier "System", Identifier (wrapperLeaf scalar)]
    where
        wrapperLeaf value = case value of
            CharacterScalar -> "Character"
            BooleanScalar -> "Boolean"
            ByteScalar -> "Byte"
            ShortScalar -> "Short"
            LongScalar -> "Long"
            IntScalar -> "Integer"
            LongIntScalar -> "LongInteger"
            UByteScalar -> "UByte"
            UShortScalar -> "UShort"
            ULongScalar -> "ULong"
            UIntScalar -> "UInteger"
            ULongIntScalar -> "ULongInteger"
            SFloatScalar -> "SFloat"
            LFloatScalar -> "LFloat"
            FloatScalar -> "Float"
            DoubleScalar -> "Double"

-- | Resolve a canonical wrapper qualified name to its scalar type.
wrapperNameToScalarType :: QualifiedName -> Maybe ScalarType
wrapperNameToScalarType name = lookup name [(scalarWrapperName scalar, scalar) | scalar <- scalarTypes]

-- Rank is meaningful only inside one family. It is not an implicit-conversion
-- rule; it exists for range analysis and explicit conversion diagnostics.

{- | Return widening rank within the scalar's own arithmetic family.
The rank is metadata for range analysis, not an implicit-conversion rule.
-}
scalarTypeRank :: ScalarType -> Int
scalarTypeRank scalar = case scalar of
    CharacterScalar -> 0
    BooleanScalar -> 0
    ByteScalar -> 0
    ShortScalar -> 1
    LongScalar -> 2
    IntScalar -> 3
    LongIntScalar -> 4
    UByteScalar -> 0
    UShortScalar -> 1
    ULongScalar -> 2
    UIntScalar -> 3
    ULongIntScalar -> 4
    SFloatScalar -> 0
    LFloatScalar -> 1
    FloatScalar -> 2
    DoubleScalar -> 3

{- | Select the wider scalar when both operands belong to the same family.
@Nothing@ means the families differ and no widening relation is defined.
-}
widerScalarType :: ScalarType -> ScalarType -> Maybe ScalarType
widerScalarType left right
    | scalarTypeFamily left /= scalarTypeFamily right = Nothing
    | scalarTypeRank left >= scalarTypeRank right = Just left
    | otherwise = Just right

-- | Convert a scalar descriptor to its canonical AST named type.
scalarTypeToType :: ScalarType -> Type
scalarTypeToType = named . scalarTypeName
    where
        named value = NamedType (QualifiedName [Identifier value]) []

-- | Recognize a non-generic built-in scalar AST type.
typeToScalarType :: Type -> Maybe ScalarType
typeToScalarType (NamedType (QualifiedName [Identifier name]) []) = lookup name table
    where
        table = [(scalarTypeName scalar, scalar) | scalar <- scalarTypes]
typeToScalarType _ = Nothing

-- | Test whether an AST type denotes a signed or unsigned integer scalar.
isIntegerType :: Type -> Bool
isIntegerType valueType = maybe False integerScalar (typeToScalarType valueType)
    where
        integerScalar scalar = scalarTypeFamily scalar `elem` [SignedIntegerFamily, UnsignedIntegerFamily]

-- | Test whether an AST type denotes a signed integer scalar.
isSignedIntegerType :: Type -> Bool
isSignedIntegerType valueType = maybe False ((== SignedIntegerFamily) . scalarTypeFamily) (typeToScalarType valueType)

-- | Test whether an AST type denotes an unsigned integer scalar.
isUnsignedIntegerType :: Type -> Bool
isUnsignedIntegerType valueType = maybe False ((== UnsignedIntegerFamily) . scalarTypeFamily) (typeToScalarType valueType)

-- | Test whether an AST type denotes a floating-point scalar.
isFloatingType :: Type -> Bool
isFloatingType valueType = maybe False ((== FloatingFamily) . scalarTypeFamily) (typeToScalarType valueType)

-- | Test whether an AST type denotes an integer or floating-point scalar.
isNumericType :: Type -> Bool
isNumericType valueType = isIntegerType valueType || isFloatingType valueType

{- | Return the inclusive minimum mathematical value for an integer scalar.
Character, Boolean, and floating-point types have no integer range.
-}
integerMinimum :: ScalarType -> Maybe Integer
integerMinimum scalar = case scalarTypeFamily scalar of
    SignedIntegerFamily -> Just (negate (2 ^ (scalarTypeWidth scalar - 1)))
    UnsignedIntegerFamily -> Just 0
    _ -> Nothing

-- | Return the inclusive maximum mathematical value for an integer scalar.
integerMaximum :: ScalarType -> Maybe Integer
integerMaximum scalar = case scalarTypeFamily scalar of
    SignedIntegerFamily -> Just (2 ^ (scalarTypeWidth scalar - 1) - 1)
    UnsignedIntegerFamily -> Just (2 ^ scalarTypeWidth scalar - 1)
    _ -> Nothing

-- | Test whether an arbitrary-precision integer fits a scalar's exact range.
integerFits :: ScalarType -> Integer -> Bool
integerFits scalar value = case (integerMinimum scalar, integerMaximum scalar) of
    (Just minimumValue, Just maximumValue) -> value >= minimumValue && value <= maximumValue
    _ -> False

-- | Default contextual type for an otherwise-unconstrained integer literal.
defaultIntegerScalar :: ScalarType
defaultIntegerScalar = IntScalar

-- | Default contextual type for an otherwise-unconstrained float literal.
defaultFloatingScalar :: ScalarType
defaultFloatingScalar = FloatScalar
