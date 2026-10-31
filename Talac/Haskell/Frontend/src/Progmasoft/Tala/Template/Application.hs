-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- |
Typed template declaration catalog and application binding.

The parser and semantic passes preserve open declarations.  This module owns
the next boundary: matching a concrete ordered argument list to one template
declaration without cloning its body yet.  Keeping binding independent from
Core is important because defaults and packs are source declaration semantics,
whereas Core may only contain a fully closed specialization.
-}
module Progmasoft.Tala.Template.Application
    ( TemplateCatalog (..)
    , TemplateDeclarationDescriptor (..)
    , TemplateParameterDescriptor (..)
    , TemplateParameterCategory (..)
    , TemplateApplication (..)
    , TemplateBinding (..)
    , BoundTemplateArgument (..)
    , TemplateApplicationError (..)
    , buildTemplateCatalog
    , lookupTemplateDeclaration
    , bindTemplateApplication
    , minimumTemplateArity
    , maximumTemplateArity
    , substituteType
    , substituteTemplateArgument
    , substituteTemplateValue
    , renderTemplateApplicationError
    ) where

import Progmasoft.Tala.AST

-- | Index of all typed template declarations in one compilation unit.
newtype TemplateCatalog = TemplateCatalog
    { templateCatalogDeclarations :: [TemplateDeclarationDescriptor]
    -- ^ Declarations retained in deterministic source order.
    }
    deriving (Eq, Ord, Read, Show)

-- | Resolved template declaration identity, parameters, and member signatures.
data TemplateDeclarationDescriptor = TemplateDeclarationDescriptor
    { templateDeclarationName :: QualifiedName
    -- ^ Fully qualified source name.
    , templateDeclarationSymbol :: SymbolId
    -- ^ Unique symbol assigned by the renamer.
    , templateDeclarationParameters :: [TemplateParameterDescriptor]
    -- ^ Parameters in declaration order.
    , templateDeclarationMembers :: [(ResolvedName, Type)]
    -- ^ Direct members and their resolved types.
    }
    deriving (Eq, Ord, Read, Show)

-- | Semantic matching requirements for one template parameter.
data TemplateParameterDescriptor = TemplateParameterDescriptor
    { templateDescriptorName :: ResolvedName
    -- ^ Resolved parameter identity.
    , templateDescriptorCategory :: TemplateParameterCategory
    -- ^ Accepted argument category and shape.
    , templateDescriptorIsPack :: Bool
    -- ^ Whether the parameter captures remaining arguments.
    , templateDescriptorDefault :: Maybe TemplateDefault
    -- ^ Source default, if declared.
    , templateDescriptorAnnotation :: Type
    -- ^ Resolved value/type annotation.
    }
    deriving (Eq, Ord, Read, Show)

-- | Category expected for an explicit template argument.
data TemplateParameterCategory
    = -- | A type-valued template parameter.
      TypeParameterCategory
    | -- | A compile-time value constrained by this type.
      ValueParameterCategory Type
    | -- | A template-template parameter with accepted shape.
      TemplateParameterCategory [TemplateParameterShape]
    deriving (Eq, Ord, Read, Show)

-- | One application request with an ordered list of supplied arguments.
data TemplateApplication = TemplateApplication
    { templateApplicationTarget :: QualifiedName
    -- ^ Fully qualified declaration to instantiate.
    , templateApplicationArguments :: [TemplateArgument]
    -- ^ Explicit arguments in source order.
    }
    deriving (Eq, Ord, Read, Show)

-- | Complete parameter-to-argument environment after defaults and packs bind.
data TemplateBinding = TemplateBinding
    { templateBindingDeclaration :: TemplateDeclarationDescriptor
    -- ^ Declaration selected by name lookup.
    , templateBindingArguments :: [(ResolvedName, [BoundTemplateArgument])]
    -- ^ Bound values grouped by parameter identity.
    }
    deriving (Eq, Ord, Read, Show)

-- | Argument together with whether it was supplied or came from a default.
data BoundTemplateArgument
    = -- | Written by the source application.
      ExplicitTemplateArgument TemplateArgument
    | -- | Filled from the parameter declaration.
      DefaultTemplateArgument TemplateArgument
    deriving (Eq, Ord, Read, Show)

-- | Binding, lookup, or substitution failure for a template application.
data TemplateApplicationError
    = -- | No declaration has this qualified name.
      UnknownTemplateDeclaration QualifiedName
    | -- | Required arity and supplied arity.
      TooFewTemplateArguments QualifiedName Int Int
    | -- | Maximum arity and supplied arity.
      TooManyTemplateArguments QualifiedName Int Int
    | -- | An argument does not match its parameter category.
      TemplateArgumentCategoryMismatch QualifiedName ResolvedName Int TemplateParameterCategory TemplateArgument
    | -- | A default references a parameter without a bound value.
      UnresolvedTemplateDefault QualifiedName ResolvedName TemplateDefault
    | -- | A parameter pack default cannot be represented.
      UnsupportedTemplatePackDefault QualifiedName ResolvedName
    | -- | Multiple declarations share the requested name.
      AmbiguousTemplateDeclaration QualifiedName [SymbolId]
    deriving (Eq, Ord, Read, Show)

-- | Build a source-ordered catalog from template declarations in a typed AST.
buildTemplateCatalog :: TypedAST -> TemplateCatalog
buildTemplateCatalog (TypedAST (SyntaxTree namespace declarations)) =
    TemplateCatalog (concatMap (describe namespace) declarations)
    where
        describe owner declaration = case declaration of
            TemplateTypeDeclaration _ name _ parameters members ->
                [ TemplateDeclarationDescriptor
                    (qualify owner (resolvedSpelling name))
                    (resolvedSymbol name)
                    (map describeParameter parameters)
                    [(declarationName member, declarationAnnotation member) | member <- members]
                ]
            _ -> []

        qualify Nothing name = QualifiedName [name]
        qualify (Just (QualifiedName parts)) name = QualifiedName (parts ++ [name])

describeParameter :: TemplateParameter ResolvedName Type -> TemplateParameterDescriptor
describeParameter parameter =
    TemplateParameterDescriptor
        (templateParameterName parameter)
        category
        (templateParameterIsPack parameter)
        (templateParameterDefault parameter)
        (templateParameterAnnotation parameter)
    where
        category = case templateParameterKind parameter of
            TemplateTypeParameter -> TypeParameterCategory
            TemplateValueParameterKind _ -> ValueParameterCategory (templateParameterAnnotation parameter)
            TemplateTemplateParameter shapes -> TemplateParameterCategory shapes

-- | Resolve a qualified template name, rejecting missing or ambiguous matches.
lookupTemplateDeclaration ::
    QualifiedName ->
    TemplateCatalog ->
    Either TemplateApplicationError TemplateDeclarationDescriptor
lookupTemplateDeclaration name catalog = case matching of
    [] -> Left (UnknownTemplateDeclaration name)
    [declaration] -> Right declaration
    declarations -> Left (AmbiguousTemplateDeclaration name (map templateDeclarationSymbol declarations))
    where
        matching = filter ((== name) . templateDeclarationName) (templateCatalogDeclarations catalog)

-- | Count required explicit arguments after defaults and packs are considered.
minimumTemplateArity :: TemplateDeclarationDescriptor -> Int
minimumTemplateArity = length . filter required . templateDeclarationParameters
    where
        required parameter =
            not (templateDescriptorIsPack parameter)
                && templateDescriptorDefault parameter == Nothing

-- | Return the finite maximum argument count, or Nothing for a parameter pack.
maximumTemplateArity :: TemplateDeclarationDescriptor -> Maybe Int
maximumTemplateArity declaration
    | any templateDescriptorIsPack parameters = Nothing
    | otherwise = Just (length parameters)
    where
        parameters = templateDeclarationParameters declaration

-- | Bind explicit arguments, defaults, and packs to the selected declaration.
bindTemplateApplication ::
    TemplateCatalog ->
    TemplateApplication ->
    Either [TemplateApplicationError] TemplateBinding
bindTemplateApplication catalog application = case lookupTemplateDeclaration target catalog of
    Left issue -> Left [issue]
    Right declaration ->
        let supplied = templateApplicationArguments application
            minimumArity = minimumTemplateArity declaration
            maximumArity = maximumTemplateArity declaration
         in if length supplied < minimumArity
                then Left [TooFewTemplateArguments target minimumArity (length supplied)]
                else case maximumArity of
                    Just limit
                        | length supplied > limit ->
                            Left [TooManyTemplateArguments target limit (length supplied)]
                    _ -> bindKnownDeclaration declaration supplied
    where
        target = templateApplicationTarget application

bindKnownDeclaration ::
    TemplateDeclarationDescriptor ->
    [TemplateArgument] ->
    Either [TemplateApplicationError] TemplateBinding
bindKnownDeclaration declaration supplied =
    case bindParameters declaration [] (templateDeclarationParameters declaration) supplied of
        (bindings, [], []) -> Right (TemplateBinding declaration bindings)
        (_, leftovers, []) ->
            Left
                [ TooManyTemplateArguments
                    (templateDeclarationName declaration)
                    (length supplied - length leftovers)
                    (length supplied)
                ]
        (_, _, problems) -> Left problems

type PartialBindings = [(ResolvedName, [BoundTemplateArgument])]

bindParameters ::
    TemplateDeclarationDescriptor ->
    PartialBindings ->
    [TemplateParameterDescriptor] ->
    [TemplateArgument] ->
    (PartialBindings, [TemplateArgument], [TemplateApplicationError])
bindParameters _ bindings [] supplied = (bindings, supplied, [])
bindParameters declaration bindings (parameter : remaining) supplied
    | templateDescriptorIsPack parameter =
        let reserve = minimumRequired remaining
            count = max 0 (length supplied - reserve)
            (packArguments, rest) = splitAt count supplied
            checked = zipWith (validateCategory declaration parameter) [bindingOffset bindings ..] packArguments
            problems = concatMap snd checked
            values = map (ExplicitTemplateArgument . fst) checked
            nextBindings = bindings ++ [(templateDescriptorName parameter, values)]
            (finalBindings, leftovers, laterProblems) =
                bindParameters declaration nextBindings remaining rest
         in (finalBindings, leftovers, problems ++ laterProblems)
    | otherwise = case supplied of
        argument : rest ->
            let (checked, problems) = validateCategory declaration parameter (bindingOffset bindings) argument
                nextBindings = bindings ++ [(templateDescriptorName parameter, [ExplicitTemplateArgument checked])]
                (finalBindings, leftovers, laterProblems) =
                    bindParameters declaration nextBindings remaining rest
             in (finalBindings, leftovers, problems ++ laterProblems)
        [] -> case templateDescriptorDefault parameter of
            Nothing ->
                ( bindings
                , []
                ,
                    [ TooFewTemplateArguments
                        (templateDeclarationName declaration)
                        (minimumTemplateArity declaration)
                        (bindingOffset bindings)
                    ]
                )
            Just defaultSyntax -> case resolveDefaultFor declaration bindings [resolvedSymbol (templateDescriptorName parameter)] defaultSyntax of
                Nothing ->
                    ( bindings
                    , []
                    ,
                        [ UnresolvedTemplateDefault
                            (templateDeclarationName declaration)
                            (templateDescriptorName parameter)
                            defaultSyntax
                        ]
                    )
                Just argument ->
                    let (checked, problems) = validateCategory declaration parameter (bindingOffset bindings) argument
                        nextBindings = bindings ++ [(templateDescriptorName parameter, [DefaultTemplateArgument checked])]
                        (finalBindings, leftovers, laterProblems) =
                            bindParameters declaration nextBindings remaining []
                     in (finalBindings, leftovers, problems ++ laterProblems)

minimumRequired :: [TemplateParameterDescriptor] -> Int
minimumRequired = length . filter required
    where
        required parameter =
            not (templateDescriptorIsPack parameter)
                && templateDescriptorDefault parameter == Nothing

bindingOffset :: PartialBindings -> Int
bindingOffset = sum . map (length . snd)

validateCategory ::
    TemplateDeclarationDescriptor ->
    TemplateParameterDescriptor ->
    Int ->
    TemplateArgument ->
    (TemplateArgument, [TemplateApplicationError])
validateCategory declaration parameter index argument
    | acceptsCategory (templateDescriptorCategory parameter) argument = (argument, [])
    | otherwise =
        ( argument
        ,
            [ TemplateArgumentCategoryMismatch
                (templateDeclarationName declaration)
                (templateDescriptorName parameter)
                index
                (templateDescriptorCategory parameter)
                argument
            ]
        )

acceptsCategory :: TemplateParameterCategory -> TemplateArgument -> Bool
acceptsCategory category argument = case (category, argument) of
    (TypeParameterCategory, TypeTemplateArgument _) -> True
    (ValueParameterCategory _, ValueTemplateArgument _) -> True
    -- A template-template argument is represented by its named type until the
    -- declaration catalog grows first-class template references.  Requiring a
    -- zero-argument named type prevents values and structural function types
    -- from being mistaken for declaration identities.
    (TemplateParameterCategory _, TypeTemplateArgument (NamedType _ [])) -> True
    _ -> False

resolveDefault :: PartialBindings -> TemplateDefault -> Maybe TemplateArgument
resolveDefault bindings defaultSyntax = case defaultSyntax of
    TemplateTypeDefault valueType -> TypeTemplateArgument <$> resolveDefaultType bindings valueType
    TemplateValueDefault value -> ValueTemplateArgument <$> resolveDefaultValue bindings value

-- Defaults may name a parameter declared later in the list.  Resolution is
-- therefore graph-shaped rather than a left fold.  The visited SymbolId set
-- rejects a default cycle without relying on source order or recursion depth.
resolveDefaultFor ::
    TemplateDeclarationDescriptor ->
    PartialBindings ->
    [SymbolId] ->
    TemplateDefault ->
    Maybe TemplateArgument
resolveDefaultFor declaration bindings visited defaultSyntax = case defaultSyntax of
    TemplateTypeDefault (ExplicitType identifier) ->
        case lookupBoundType identifier bindings of
            Just valueType -> Just (TypeTemplateArgument valueType)
            Nothing -> case findParameter identifier declaration of
                Nothing -> resolveDefault bindings defaultSyntax
                Just parameter ->
                    let symbol = resolvedSymbol (templateDescriptorName parameter)
                     in if symbol `elem` visited
                            then Nothing
                            else do
                                nestedDefault <- templateDescriptorDefault parameter
                                resolveDefaultFor declaration bindings (symbol : visited) nestedDefault
    TemplateValueDefault (TemplateNameSyntax _ (QualifiedName [identifier])) ->
        case lookupBoundValue identifier bindings of
            Just value -> Just (ValueTemplateArgument value)
            Nothing -> do
                parameter <- findParameter identifier declaration
                let symbol = resolvedSymbol (templateDescriptorName parameter)
                if symbol `elem` visited
                    then Nothing
                    else do
                        nestedDefault <- templateDescriptorDefault parameter
                        resolveDefaultFor declaration bindings (symbol : visited) nestedDefault
    _ -> resolveDefault bindings defaultSyntax

findParameter :: Identifier -> TemplateDeclarationDescriptor -> Maybe TemplateParameterDescriptor
findParameter identifier declaration = first matching (templateDeclarationParameters declaration)
    where
        matching parameter = resolvedSpelling (templateDescriptorName parameter) == identifier
        first _ [] = Nothing
        first predicate (value : remaining)
            | predicate value = Just value
            | otherwise = first predicate remaining

resolveDefaultType :: PartialBindings -> TypeSyntax -> Maybe Type
resolveDefaultType bindings syntax = case syntax of
    AutoType -> Nothing
    ExplicitType identifier ->
        lookupBoundType identifier bindings
            `orElse` Just (NamedType (QualifiedName [identifier]) [])
    QualifiedTypeSyntax name arguments ->
        NamedType name <$> traverse (resolveDefaultArgument bindings) arguments
    BuiltinArrayTypeSyntax element ->
        named "[]" . (: []) . TypeTemplateArgument <$> resolveDefaultType bindings element
    ArrayTypeSyntax element ->
        system "Array" . (: []) . TypeTemplateArgument <$> resolveDefaultType bindings element
    FixedArrayTypeSyntax element size -> do
        elementType <- resolveDefaultType bindings element
        sizeValue <- resolveDefaultValue bindings size
        pure (system "Array" [TypeTemplateArgument elementType, ValueTemplateArgument sizeValue])
    DictionaryTypeSyntax key value -> do
        keyType <- resolveDefaultType bindings key
        valueType <- resolveDefaultType bindings value
        pure (system "Dictionary" [TypeTemplateArgument keyType, TypeTemplateArgument valueType])
    CallableTypeSyntax parameters result ->
        FunctionType <$> traverse (resolveDefaultType bindings) parameters <*> resolveDefaultType bindings result
    where
        named spelling arguments = NamedType (QualifiedName [Identifier spelling]) arguments
        system spelling arguments = NamedType (QualifiedName [Identifier "System", Identifier spelling]) arguments

resolveDefaultArgument :: PartialBindings -> TemplateArgumentSyntax -> Maybe TemplateArgument
resolveDefaultArgument bindings argument = case argument of
    TemplateTypeSyntax valueType -> TypeTemplateArgument <$> resolveDefaultType bindings valueType
    TemplateValueArgumentSyntax value -> ValueTemplateArgument <$> resolveDefaultValue bindings value

resolveDefaultValue :: PartialBindings -> TemplateValueSyntax -> Maybe TemplateValue
resolveDefaultValue bindings syntax = case syntax of
    TemplateIntegerSyntax _ value -> Just (IntegerTemplateValue value)
    TemplateCharacterSyntax _ value -> Just (CharacterTemplateValue value)
    TemplateBooleanSyntax _ value -> Just (BooleanTemplateValue value)
    TemplateNameSyntax _ (QualifiedName [identifier]) -> lookupBoundValue identifier bindings
    -- Arithmetic defaults are deliberately not evaluated here.  The type
    -- checker already validates them, and the specialization evaluator will
    -- own substitution-aware constant folding in the cloning stage.
    TemplateUnarySyntax {} -> Nothing
    TemplateBinarySyntax {} -> Nothing
    TemplateNameSyntax {} -> Nothing

lookupBoundType :: Identifier -> PartialBindings -> Maybe Type
lookupBoundType identifier bindings = do
    arguments <- lookupBySpelling identifier bindings
    case arguments of
        [ExplicitTemplateArgument (TypeTemplateArgument valueType)] -> Just valueType
        [DefaultTemplateArgument (TypeTemplateArgument valueType)] -> Just valueType
        _ -> Nothing

lookupBoundValue :: Identifier -> PartialBindings -> Maybe TemplateValue
lookupBoundValue identifier bindings = do
    arguments <- lookupBySpelling identifier bindings
    case arguments of
        [ExplicitTemplateArgument (ValueTemplateArgument value)] -> Just value
        [DefaultTemplateArgument (ValueTemplateArgument value)] -> Just value
        _ -> Nothing

lookupBySpelling :: Identifier -> PartialBindings -> Maybe [BoundTemplateArgument]
lookupBySpelling identifier = lookupFirst . filter ((== identifier) . resolvedSpelling . fst)
    where
        lookupFirst [] = Nothing
        lookupFirst ((_, values) : _) = Just values

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just value) _ = Just value
orElse Nothing fallback = fallback

-- | Replace bound type variables recursively in a resolved type expression.
substituteType :: TemplateBinding -> Type -> Either TemplateApplicationError Type
substituteType binding valueType = case valueType of
    TypeVariable name -> case lookup (resolvedSymbol name) substitutions of
        Just [TypeTemplateArgument replacement] -> Right replacement
        _ -> Left (missing name (TemplateTypeDefault (ExplicitType (resolvedSpelling name))))
    NamedType name arguments -> NamedType name <$> traverse (substituteTemplateArgument binding) arguments
    FunctionType parameters result -> FunctionType <$> traverse (substituteType binding) parameters <*> substituteType binding result
    ErrorType -> Right ErrorType
    where
        substitutions = flattenedBindings binding
        missing name defaultValue =
            UnresolvedTemplateDefault
                (templateDeclarationName (templateBindingDeclaration binding))
                name
                defaultValue

-- | Substitute type or compile-time value variables inside one argument.
substituteTemplateArgument :: TemplateBinding -> TemplateArgument -> Either TemplateApplicationError TemplateArgument
substituteTemplateArgument binding argument = case argument of
    TypeTemplateArgument valueType -> TypeTemplateArgument <$> substituteType binding valueType
    ValueTemplateArgument value -> ValueTemplateArgument <$> substituteTemplateValue binding value

-- | Substitute one value-parameter reference using the completed binding.
substituteTemplateValue :: TemplateBinding -> TemplateValue -> Either TemplateApplicationError TemplateValue
substituteTemplateValue binding value = case value of
    TemplateValueParameter name -> case lookup (resolvedSymbol name) (flattenedBindings binding) of
        Just [ValueTemplateArgument replacement] -> Right replacement
        _ ->
            Left
                ( UnresolvedTemplateDefault
                    (templateDeclarationName (templateBindingDeclaration binding))
                    name
                    (TemplateValueDefault (TemplateNameSyntax syntheticSpan (QualifiedName [resolvedSpelling name])))
                )
    _ -> Right value

flattenedBindings :: TemplateBinding -> [(SymbolId, [TemplateArgument])]
flattenedBindings binding =
    [ (resolvedSymbol name, map unwrap values)
    | (name, values) <- templateBindingArguments binding
    ]
    where
        unwrap (ExplicitTemplateArgument argument) = argument
        unwrap (DefaultTemplateArgument argument) = argument

syntheticSpan :: SourceSpan
syntheticSpan = SourceSpan "<template>" (SourcePosition 1 1) (SourcePosition 1 1)

-- | Render a template lookup, arity, category, or substitution failure.
renderTemplateApplicationError :: TemplateApplicationError -> String
renderTemplateApplicationError issue = case issue of
    UnknownTemplateDeclaration name -> "unknown template declaration " ++ renderQualifiedName name
    TooFewTemplateArguments name expected actual ->
        renderQualifiedName name
            ++ " requires at least "
            ++ show expected
            ++ " template arguments, but received "
            ++ show actual
    TooManyTemplateArguments name expected actual ->
        renderQualifiedName name
            ++ " accepts at most "
            ++ show expected
            ++ " template arguments, but received "
            ++ show actual
    TemplateArgumentCategoryMismatch name parameter index category argument ->
        "template argument "
            ++ show (index + 1)
            ++ " for "
            ++ renderQualifiedName name
            ++ " does not match parameter "
            ++ identifierText (resolvedSpelling parameter)
            ++ " (expected "
            ++ renderCategory category
            ++ ", received "
            ++ renderArgumentCategory argument
            ++ ")"
    UnresolvedTemplateDefault name parameter _ ->
        "default for template parameter "
            ++ identifierText (resolvedSpelling parameter)
            ++ " of "
            ++ renderQualifiedName name
            ++ " could not be resolved"
    UnsupportedTemplatePackDefault name parameter ->
        "template parameter pack "
            ++ identifierText (resolvedSpelling parameter)
            ++ " of "
            ++ renderQualifiedName name
            ++ " cannot have a default"
    AmbiguousTemplateDeclaration name symbols ->
        "template declaration "
            ++ renderQualifiedName name
            ++ " is ambiguous across symbols "
            ++ show (map symbolIdValue symbols)

renderQualifiedName :: QualifiedName -> String
renderQualifiedName (QualifiedName parts) = joinWith "." (map identifierText parts)

renderCategory :: TemplateParameterCategory -> String
renderCategory category = case category of
    TypeParameterCategory -> "type"
    ValueParameterCategory _ -> "value"
    TemplateParameterCategory _ -> "template"

renderArgumentCategory :: TemplateArgument -> String
renderArgumentCategory argument = case argument of
    TypeTemplateArgument _ -> "type"
    ValueTemplateArgument _ -> "value"

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [value] = value
joinWith separator (value : remaining) = value ++ separator ++ joinWith separator remaining
