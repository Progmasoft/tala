-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

-- | Canonical scalar facts shared by Core verification and optimization.
module Progmasoft.Tala.Core.Scalar
    ( coreTypeSpelling
    , coreIntegerTypeNames
    , coreFloatingTypeNames
    , coreNumericTypeNames
    , isCoreIntegerType
    , isCoreFloatingType
    , isCoreNumericType
    , coreIntegerBitWidth
    , coreIntegerIsSigned
    , integerFitsCoreType
    , validCoreFloatingSpelling
    ) where

import Progmasoft.Tala.AST

-- | Extract the leaf spelling from a non-generic built-in type.
coreTypeSpelling :: Type -> String
coreTypeSpelling (NamedType (QualifiedName [Identifier name]) []) = name
coreTypeSpelling _ = ""

-- | Canonical integer type names, including signed and unsigned widths.
coreIntegerTypeNames :: [String]
coreIntegerTypeNames = map fst integerLayouts

-- | Canonical floating-point type names in the language.
coreFloatingTypeNames :: [String]
coreFloatingTypeNames = ["sfloat", "lfloat", "float", "double"]

-- | Integer and floating-point names accepted by Core numeric rules.
coreNumericTypeNames :: [String]
coreNumericTypeNames = coreIntegerTypeNames ++ coreFloatingTypeNames

-- | Test whether a Core type is a built-in integer scalar.
isCoreIntegerType :: Type -> Bool
isCoreIntegerType valueType = coreTypeSpelling valueType `elem` coreIntegerTypeNames

-- | Test whether a Core type is a built-in floating scalar.
isCoreFloatingType :: Type -> Bool
isCoreFloatingType valueType = coreTypeSpelling valueType `elem` coreFloatingTypeNames

-- | Test whether a Core type is an integer or floating scalar.
isCoreNumericType :: Type -> Bool
isCoreNumericType valueType = coreTypeSpelling valueType `elem` coreNumericTypeNames

{- | Return the source-level storage width for a built-in integer type.
Keeping this catalog next to range validation lets optimizer operations
reject unsafe shifts without duplicating the language's integer table.
-}
coreIntegerBitWidth :: Type -> Maybe Int
coreIntegerBitWidth valueType = snd <$> lookup (coreTypeSpelling valueType) integerLayouts

-- | Report whether a scalar integer type uses a sign bit.
coreIntegerIsSigned :: Type -> Maybe Bool
coreIntegerIsSigned valueType = fst <$> lookup (coreTypeSpelling valueType) integerLayouts

integerLayouts :: [(String, (Bool, Int))]
integerLayouts =
    [ ("char", (False, 32))
    , ("byte", (True, 8))
    , ("short", (True, 16))
    , ("long", (True, 32))
    , ("int", (True, 64))
    , ("longint", (True, 128))
    , ("ubyte", (False, 8))
    , ("ushort", (False, 16))
    , ("ulong", (False, 32))
    , ("uint", (False, 64))
    , ("ulongint", (False, 128))
    ]

-- | Test whether an exact integer value lies in a Core integer type's range.
integerFitsCoreType :: Type -> Integer -> Bool
integerFitsCoreType valueType value = case lookup (coreTypeSpelling valueType) integerLayouts of
    Just (isSigned, width) ->
        let magnitude = 2 ^ (width - if isSigned then 1 else 0)
            minimumValue = if isSigned then negate magnitude else 0
            maximumValue = magnitude - 1
         in value >= minimumValue && value <= maximumValue
    Nothing -> False

-- | Validate a deterministic ASCII decimal or supported special float spelling.
validCoreFloatingSpelling :: String -> Bool
validCoreFloatingSpelling spelling
    | spelling `elem` ["nan", "+nan", "-nan", "inf", "+inf", "-inf"] = True
    | otherwise = case dropSign spelling of
        [] -> False
        unsignedSpelling ->
            let (mantissa, exponentPart) = break (`elem` "eE") unsignedSpelling
             in validMantissa mantissa && validExponent exponentPart
    where
        dropSign ('+' : remaining) = remaining
        dropSign ('-' : remaining) = remaining
        dropSign value = value
        validMantissa value = case break (== '.') value of
            (whole, []) -> digits whole
            (whole, _ : fraction) ->
                (not (null whole) || not (null fraction))
                    && digitsOrEmpty whole
                    && digitsOrEmpty fraction
        validExponent [] = True
        validExponent (_ : remaining) = digits (dropExponentSign remaining)
        dropExponentSign ('+' : remaining) = remaining
        dropExponentSign ('-' : remaining) = remaining
        dropExponentSign value = value
        -- Core artifacts are a stable, language-neutral boundary. Accepting
        -- Unicode decimal categories here would make spellings depend on the
        -- host implementation of character classification even though source
        -- numeric tokens are deliberately ASCII.
        asciiDigit character = character >= '0' && character <= '9'
        digits value = not (null value) && all asciiDigit value
        digitsOrEmpty value = null value || all asciiDigit value
