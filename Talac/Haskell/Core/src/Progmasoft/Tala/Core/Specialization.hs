-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Deterministic specialization planning for Core monomorphization.

Parsing and type checking preserve ordered template arguments, while this
module owns the transition from a possibly-open type to a concrete cache
entry.  It deliberately contains no code generation policy: the same plan
can feed Core cloning, CorePrep scheduling, or incremental build metadata.
-}
module Progmasoft.Tala.Core.Specialization
    ( Specialization (..)
    , SpecializationCatalog
    , SpecializationError (..)
    , SpecializationId (..)
    , TypeBindings
    , ValueBindings
    , catalogSize
    , emptyCatalog
    , findSpecialization
    , findSpecializationByType
    , internSpecialization
    , internSpecializations
    , prepareSpecialization
    , specializationSnapshot
    ) where

import Data.List (group, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core.Template

-- | Substitution environment mapping template symbols to concrete types.
type TypeBindings = [(SymbolId, Type)]

-- | Substitution environment mapping template symbols to constant values.
type ValueBindings = [(SymbolId, TemplateValue)]

-- | Monotonic identity assigned to an interned concrete specialization.
newtype SpecializationId = SpecializationId {specializationIdValue :: Int}
    deriving (Eq, Ord, Read, Show)

-- | A validated closed type stored in a specialization catalog.
data Specialization = Specialization
    { specializationId :: SpecializationId
    -- ^ Catalog-local stable identifier.
    , specializationIdentity :: String
    -- ^ Canonical structural identity key.
    , specializationType :: Type
    -- ^ Validated concrete type.
    }
    deriving (Eq, Ord, Read, Show)

-- | Persistent immutable index by canonical identity and catalog identifier.
data SpecializationCatalog = SpecializationCatalog
    { catalogNextId :: SpecializationId
    , catalogByIdentity :: Map String Specialization
    , catalogById :: Map SpecializationId Specialization
    }
    deriving (Eq, Read, Show)

-- | Rejected substitution, open type, or ambiguous binding environment.
data SpecializationError
    = -- | Concrete type failed structural validation.
      InvalidSpecialization [TemplateIssue]
    | -- | Type/value parameter identities remain unresolved.
      OpenSpecialization [SymbolId]
    | -- | A type binding key occurs more than once.
      DuplicateTypeBinding [SymbolId]
    | -- | A value binding key occurs more than once.
      DuplicateValueBinding [SymbolId]
    | -- | One identity is bound as both type and value.
      ConflictingBindingKinds [SymbolId]
    deriving (Eq, Ord, Read, Show)

-- | Create a catalog whose first assigned identity is one.
emptyCatalog :: SpecializationCatalog
emptyCatalog = SpecializationCatalog (SpecializationId 1) Map.empty Map.empty

-- | Return the number of unique concrete types currently interned.
catalogSize :: SpecializationCatalog -> Int
catalogSize = Map.size . catalogById

{- | Substitute bindings and prove that the resulting key is both structurally
valid and closed. Binding diagnostics are deterministic and reported before
structural issues, making build failures independent of map insertion order.
-}

-- | Apply bindings, validate structure, and reject any remaining open symbols.
prepareSpecialization :: TypeBindings -> ValueBindings -> Type -> Either SpecializationError Type
prepareSpecialization typeBindings valueBindings input = do
    validateBindings typeBindings valueBindings
    let concrete = substituteTemplateType typeBindings valueBindings input
        issues = validateTemplateType 128 concrete
        parameters = collectTemplateParameters concrete
    if not (null issues)
        then Left (InvalidSpecialization issues)
        else
            if not (null parameters)
                then Left (OpenSpecialization parameters)
                else Right concrete

{- | Intern one already-concrete type. The Bool distinguishes a newly planned
specialization from an existing cache hit without assigning a second id.
-}

-- | Validate and intern one concrete type; report whether it was newly added.
internSpecialization ::
    Type ->
    SpecializationCatalog ->
    Either SpecializationError (Specialization, Bool, SpecializationCatalog)
internSpecialization input catalog = do
    concrete <- prepareSpecialization [] [] input
    let identity = renderTemplateIdentity concrete
    case Map.lookup identity (catalogByIdentity catalog) of
        Just existing -> Right (existing, False, catalog)
        Nothing ->
            let entry = Specialization (catalogNextId catalog) identity concrete
                next = successor (catalogNextId catalog)
                updated =
                    SpecializationCatalog
                        next
                        (Map.insert identity entry (catalogByIdentity catalog))
                        (Map.insert (specializationId entry) entry (catalogById catalog))
             in Right (entry, True, updated)

{- | Intern a worklist atomically. Because the catalog is immutable, returning
Left naturally discards entries prepared earlier in the same batch. Repeated
keys in one worklist share their first insertion-order id.
-}

-- | Intern a batch transactionally while preserving first-seen identity order.
internSpecializations ::
    [Type] ->
    SpecializationCatalog ->
    Either SpecializationError ([Specialization], SpecializationCatalog)
internSpecializations inputs initial = go [] initial inputs
    where
        go entries catalog [] = Right (reverse entries, catalog)
        go entries catalog (input : remaining) = do
            (entry, _, updated) <- internSpecialization input catalog
            go (entry : entries) updated remaining

-- | Find a catalog entry by its assigned identifier.
findSpecialization :: SpecializationId -> SpecializationCatalog -> Maybe Specialization
findSpecialization key = Map.lookup key . catalogById

-- | Find a previously interned entry by canonical type identity.
findSpecializationByType :: Type -> SpecializationCatalog -> Maybe Specialization
findSpecializationByType input catalog =
    Map.lookup (renderTemplateIdentity input) (catalogByIdentity catalog)

-- | Snapshot catalog entries ordered by specialization identifier.
specializationSnapshot :: SpecializationCatalog -> [Specialization]
specializationSnapshot = Map.elems . catalogById

successor :: SpecializationId -> SpecializationId
successor (SpecializationId value) = SpecializationId (value + 1)

validateBindings :: TypeBindings -> ValueBindings -> Either SpecializationError ()
validateBindings typeBindings valueBindings
    | not (null duplicateTypes) = Left (DuplicateTypeBinding duplicateTypes)
    | not (null duplicateValues) = Left (DuplicateValueBinding duplicateValues)
    | not (null conflicts) = Left (ConflictingBindingKinds conflicts)
    | otherwise = Right ()
    where
        typeKeys = map fst typeBindings
        valueKeys = map fst valueBindings
        duplicateTypes = duplicates typeKeys
        duplicateValues = duplicates valueKeys
        conflicts = Map.keys (Map.intersection (keySet typeKeys) (keySet valueKeys))

        keySet = Map.fromList . map (,())
        duplicates values = [first | duplicate@(first : _) <- group (sort values), length duplicate > 1]
