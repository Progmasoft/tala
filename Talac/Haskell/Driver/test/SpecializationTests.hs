-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module SpecializationTests (specializationTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Core.Specialization
import Progmasoft.Tala.Core.Template

specializationTests :: [(String, Bool)]
specializationTests =
    [ ("specialization preparation substitutes type and value parameters", preparesBothKinds)
    , ("specialization preparation supports partial substitution diagnostics", rejectsPartiallyOpen)
    , ("specialization preparation rejects an untouched generic type", rejectsOpenType)
    , ("specialization preparation rejects duplicate type bindings", rejectsDuplicateTypes)
    , ("specialization preparation rejects duplicate value bindings", rejectsDuplicateValues)
    , ("specialization preparation rejects cross-kind binding conflicts", rejectsBindingKindConflict)
    , ("specialization preparation validates the substituted result", rejectsInvalidSubstitution)
    , ("specialization catalog starts empty", emptyCatalogContract)
    , ("specialization catalog assigns positive insertion-order ids", insertionOrderIds)
    , ("specialization catalog coalesces identical concrete types", coalescesIdentity)
    , ("specialization catalog distinguishes fixed array sizes", distinguishesArraySizes)
    , ("specialization catalog distinguishes argument order", distinguishesArgumentOrder)
    , ("specialization lookup works by id and structural type", lookupContract)
    , ("specialization snapshot follows id order", snapshotOrder)
    , ("specialization batches preserve duplicate request results", batchDuplicates)
    , ("specialization batches roll back on invalid input", batchFailureIsAtomic)
    , ("specialization catalog rejects malformed array families", rejectsMalformedArray)
    , ("specialization identity preserves value argument kinds", distinguishesValueKinds)
    ]

resolved :: Int -> String -> ResolvedName
resolved symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)

named :: String -> [TemplateArgument] -> Type
named name = NamedType (QualifiedName [Identifier name])

systemArray :: [TemplateArgument] -> Type
systemArray = NamedType (QualifiedName [Identifier "System", Identifier "Array"])

typeArgument :: Type -> TemplateArgument
typeArgument = TypeTemplateArgument

integerArgument :: Integer -> TemplateArgument
integerArgument = ValueTemplateArgument . IntegerTemplateValue

booleanArgument :: Bool -> TemplateArgument
booleanArgument = ValueTemplateArgument . BooleanTemplateValue

characterArgument :: Integer -> TemplateArgument
characterArgument = ValueTemplateArgument . CharacterTemplateValue

fixedArray :: Type -> Integer -> Type
fixedArray element size = systemArray [typeArgument element, integerArgument size]

typeParameterName, valueParameterName :: ResolvedName
typeParameterName = resolved 10 "T"
valueParameterName = resolved 20 "N"

genericArray :: Type
genericArray =
    systemArray
        [ typeArgument (TypeVariable typeParameterName)
        , ValueTemplateArgument (TemplateValueParameter valueParameterName)
        ]

preparesBothKinds :: Bool
preparesBothKinds =
    prepareSpecialization
        [(SymbolId 10, stringType)]
        [(SymbolId 20, IntegerTemplateValue 32)]
        genericArray
        == Right (fixedArray stringType 32)

rejectsPartiallyOpen :: Bool
rejectsPartiallyOpen =
    prepareSpecialization [(SymbolId 10, stringType)] [] genericArray
        == Left (OpenSpecialization [SymbolId 20])

rejectsOpenType :: Bool
rejectsOpenType =
    prepareSpecialization [] [] genericArray
        == Left (OpenSpecialization [SymbolId 10, SymbolId 20])

rejectsDuplicateTypes :: Bool
rejectsDuplicateTypes =
    prepareSpecialization
        [(SymbolId 10, intType), (SymbolId 10, stringType)]
        []
        (TypeVariable typeParameterName)
        == Left (DuplicateTypeBinding [SymbolId 10])

rejectsDuplicateValues :: Bool
rejectsDuplicateValues =
    prepareSpecialization
        []
        [(SymbolId 20, IntegerTemplateValue 4), (SymbolId 20, IntegerTemplateValue 8)]
        genericArray
        == Left (DuplicateValueBinding [SymbolId 20])

rejectsBindingKindConflict :: Bool
rejectsBindingKindConflict =
    prepareSpecialization
        [(SymbolId 10, intType)]
        [(SymbolId 10, IntegerTemplateValue 4)]
        intType
        == Left (ConflictingBindingKinds [SymbolId 10])

rejectsInvalidSubstitution :: Bool
rejectsInvalidSubstitution =
    case prepareSpecialization
        [(SymbolId 10, intType)]
        [(SymbolId 20, IntegerTemplateValue (-1))]
        genericArray of
        Left (InvalidSpecialization issues) ->
            any ((== TemplateNegativeArraySize) . templateIssueKind) issues
        _ -> False

emptyCatalogContract :: Bool
emptyCatalogContract =
    catalogSize emptyCatalog == 0
        && null (specializationSnapshot emptyCatalog)
        && findSpecialization (SpecializationId 1) emptyCatalog == Nothing

insertionOrderIds :: Bool
insertionOrderIds = case internSpecializations [fixedArray intType 4, fixedArray intType 5] emptyCatalog of
    Right ([first, second], catalog) ->
        specializationId first == SpecializationId 1
            && specializationId second == SpecializationId 2
            && catalogSize catalog == 2
    _ -> False

coalescesIdentity :: Bool
coalescesIdentity = case internSpecialization (fixedArray intType 4) emptyCatalog of
    Right (first, True, once) -> case internSpecialization (fixedArray intType 4) once of
        Right (second, False, twice) ->
            first == second && once == twice && catalogSize twice == 1
        _ -> False
    _ -> False

distinguishesArraySizes :: Bool
distinguishesArraySizes = case internSpecializations [fixedArray intType 4, fixedArray intType 5] emptyCatalog of
    Right ([first, second], _) -> specializationIdentity first /= specializationIdentity second
    _ -> False

distinguishesArgumentOrder :: Bool
distinguishesArgumentOrder =
    let first = named "Mix" [typeArgument intType, integerArgument 4]
        second = named "Mix" [integerArgument 4, typeArgument intType]
     in case internSpecializations [first, second] emptyCatalog of
            Right ([left, right], catalog) ->
                specializationIdentity left /= specializationIdentity right
                    && catalogSize catalog == 2
            _ -> False

lookupContract :: Bool
lookupContract = case internSpecialization (fixedArray stringType 16) emptyCatalog of
    Right (entry, _, catalog) ->
        findSpecialization (specializationId entry) catalog == Just entry
            && findSpecializationByType (specializationType entry) catalog == Just entry
            && findSpecialization (SpecializationId 99) catalog == Nothing
    _ -> False

snapshotOrder :: Bool
snapshotOrder = case internSpecializations inputs emptyCatalog of
    Right (entries, catalog) -> specializationSnapshot catalog == entries
    _ -> False
    where
        inputs = [fixedArray intType 8, named "Flag" [booleanArgument True], named "Code" [characterArgument 65]]

batchDuplicates :: Bool
batchDuplicates = case internSpecializations [value, value, value] emptyCatalog of
    Right (entries, catalog) ->
        length entries == 3
            && all ((== SpecializationId 1) . specializationId) entries
            && catalogSize catalog == 1
    _ -> False
    where
        value = fixedArray intType 64

batchFailureIsAtomic :: Bool
batchFailureIsAtomic =
    let malformed = systemArray []
     in case internSpecializations [fixedArray intType 4, malformed] emptyCatalog of
            Left (InvalidSpecialization _) -> catalogSize emptyCatalog == 0
            _ -> False

rejectsMalformedArray :: Bool
rejectsMalformedArray = case internSpecialization (systemArray [integerArgument 8]) emptyCatalog of
    Left (InvalidSpecialization issues) ->
        any ((== TemplateMalformedArrayFamily) . templateIssueKind) issues
    _ -> False

distinguishesValueKinds :: Bool
distinguishesValueKinds = case internSpecializations values emptyCatalog of
    Right (entries, catalog) ->
        catalogSize catalog == 3
            && length (map specializationIdentity entries) == 3
            && allDifferent (map specializationIdentity entries)
    _ -> False
    where
        values =
            [ named "Value" [integerArgument 1]
            , named "Value" [booleanArgument True]
            , named "Value" [characterArgument 1]
            ]
        allDifferent [first, second, third] = first /= second && first /= third && second /= third
        allDifferent _ = False
