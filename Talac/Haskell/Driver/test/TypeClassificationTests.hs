-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module TypeClassificationTests (typeClassificationTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.TypeClassification

typeClassificationTests :: [(String, Bool)]
typeClassificationTests =
    [ ("every built-in scalar is a trivial value", all scalarIsTrivial scalarTypes)
    , ("void is a trivial no-result marker", classifyType catalog voidType == TrivialValueStorage)
    , ("String has reference identity", classifyType catalog stringType == AarcReferenceStorage)
    , ("callable values own AARC environments", classifyType catalog callableType == AarcReferenceStorage)
    , ("value declaration families use CoW", all nominalIsValue valueNominals)
    , ("reference declaration families use AARC", all nominalIsReference referenceNominals)
    , ("an all-value construction remains a value", classifyType catalog nestedValue == CopyOnWriteValueStorage)
    , ("a direct reference argument makes a value construction reference", usesAarc catalog directReference)
    , ("reference classification propagates through arbitrary nesting", usesAarc catalog deepReference)
    , ("a nominal reference propagates through a value construction", usesAarc catalog nominalReference)
    , ("a reference outer type ignores unresolved arguments", usesAarc catalog referenceWithOpenArgument)
    , ("an open all-value construction remains unresolved", classifyType catalog openValue == UnresolvedStorage)
    , ("reference evidence dominates an earlier unresolved argument", usesAarc catalog unresolvedThenReference)
    , ("reference evidence dominates a later unresolved argument", usesAarc catalog referenceThenUnresolved)
    , ("compile-time value arguments do not affect storage", usesCopyOnWrite catalog fixedBuffer)
    , ("unknown nominal declarations remain unresolved", classifyType catalog missingType == UnresolvedStorage)
    , ("catalog registration rejects empty qualified names", rejectsEmptyName)
    , ("catalog registration rejects empty name components", rejectsEmptyComponent)
    , ("catalog registration rejects exact duplicates", rejectsDuplicate)
    , ("catalog lookup is case-sensitive", caseSensitiveCatalog)
    ]
  where
    scalarIsTrivial scalar = classifyType catalog (scalarTypeToType scalar) == TrivialValueStorage
    nominalIsValue kind = classifyNominal kind == CopyOnWriteValueStorage
    nominalIsReference kind = classifyNominal kind == AarcReferenceStorage

name :: String -> QualifiedName
name spelling = QualifiedName [Identifier spelling]

named :: String -> [Type] -> Type
named spelling arguments = NamedType (name spelling) (map TypeTemplateArgument arguments)

typeVariable :: String -> Int -> Type
typeVariable spelling unique = TypeVariable (ResolvedName (SymbolId unique) (Identifier spelling))

catalog :: NominalCatalog
catalog = case registrations of
    Right result -> result
    Left problem -> error ("invalid ownership test catalog: " ++ show problem)
  where
    registrations = do
        withValue <- registerNominal (name "ValueCell") DataNominal emptyNominalCatalog
        withReference <- registerNominal (name "ReferenceCell") ClassNominal withValue
        registerNominal (name "Buffer") LiteralTypeNominal withReference

valueNominals :: [NominalKind]
valueNominals = [DataNominal, LiteralTypeNominal, ClassicEnumNominal]

referenceNominals :: [NominalKind]
referenceNominals = [ClassNominal, DataClassNominal, EnumClassNominal, ObjectNominal, InterfaceNominal]

callableType :: Type
callableType = FunctionType [intType] voidType

nestedValue :: Type
nestedValue = named "ValueCell" [named "ValueCell" [intType]]

directReference :: Type
directReference = named "ValueCell" [stringType]

deepReference :: Type
deepReference = named "ValueCell" [named "ValueCell" [named "ValueCell" [stringType]]]

nominalReference :: Type
nominalReference = named "ValueCell" [named "ReferenceCell" [intType]]

referenceWithOpenArgument :: Type
referenceWithOpenArgument = named "ReferenceCell" [typeVariable "T" 1]

openValue :: Type
openValue = named "ValueCell" [typeVariable "T" 2]

unresolvedThenReference :: Type
unresolvedThenReference = named "ValueCell" [typeVariable "U" 3, stringType]

referenceThenUnresolved :: Type
referenceThenUnresolved = named "ValueCell" [stringType, typeVariable "V" 4]

fixedBuffer :: Type
fixedBuffer =
    NamedType
        (name "Buffer")
        [TypeTemplateArgument intType, ValueTemplateArgument (IntegerTemplateValue 16)]

missingType :: Type
missingType = named "Missing" [intType]

rejectsEmptyName :: Bool
rejectsEmptyName = registerNominal (QualifiedName []) DataNominal emptyNominalCatalog == Left EmptyNominalName

rejectsEmptyComponent :: Bool
rejectsEmptyComponent =
    registerNominal malformed DataNominal emptyNominalCatalog == Left (EmptyNominalNameComponent malformed)
  where
    malformed = QualifiedName [Identifier "Example", Identifier ""]

rejectsDuplicate :: Bool
rejectsDuplicate = case registerNominal (name "Example") DataNominal emptyNominalCatalog of
    Left _ -> False
    Right once -> registerNominal (name "Example") ClassNominal once == Left (DuplicateNominalName (name "Example"))

caseSensitiveCatalog :: Bool
caseSensitiveCatalog = case registerNominal upper DataNominal emptyNominalCatalog of
    Left _ -> False
    Right result -> lookupNominal upper result == Just DataNominal && lookupNominal lower result == Nothing
  where
    upper = QualifiedName [Identifier "Example", Identifier "Value"]
    lower = QualifiedName [Identifier "Example", Identifier "value"]
