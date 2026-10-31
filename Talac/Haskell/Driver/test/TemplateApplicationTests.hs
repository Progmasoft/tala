-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module TemplateApplicationTests (templateApplicationTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Template.Application

templateApplicationTests :: [(String, Bool)]
templateApplicationTests =
    [ ("catalog records a qualified template name", catalogRecordsQualifiedName)
    , ("catalog records the declaration symbol", catalogRecordsDeclarationSymbol)
    , ("catalog records member semantic signatures", catalogRecordsMembers)
    , ("catalog excludes ordinary declarations", catalogExcludesOrdinaryDeclarations)
    , ("catalog preserves source declaration order", catalogPreservesOrder)
    , ("catalog describes a type parameter", catalogDescribesTypeParameter)
    , ("catalog describes a value parameter", catalogDescribesValueParameter)
    , ("catalog describes a template parameter", catalogDescribesTemplateParameter)
    , ("catalog preserves pack status", catalogPreservesPackStatus)
    , ("catalog preserves default syntax", catalogPreservesDefault)
    , ("lookup finds an exact qualified name", lookupFindsQualifiedName)
    , ("lookup does not fall back to a short name", lookupRejectsShortName)
    , ("lookup reports unknown declarations", lookupReportsUnknown)
    , ("lookup reports ambiguous catalog entries", lookupReportsAmbiguous)
    , ("minimum arity counts required parameters", minimumArityCountsRequired)
    , ("minimum arity excludes defaults", minimumArityExcludesDefaults)
    , ("minimum arity excludes packs", minimumArityExcludesPacks)
    , ("maximum arity is exact without packs", maximumArityIsExact)
    , ("maximum arity is unbounded with a pack", maximumArityIsUnbounded)
    , ("binding accepts one type argument", bindingAcceptsType)
    , ("binding accepts one value argument", bindingAcceptsValue)
    , ("binding accepts a template declaration name", bindingAcceptsTemplateName)
    , ("binding rejects a value for a type parameter", bindingRejectsValueForType)
    , ("binding rejects a type for a value parameter", bindingRejectsTypeForValue)
    , ("binding rejects a function type for a template parameter", bindingRejectsFunctionForTemplate)
    , ("binding reports too few arguments", bindingReportsTooFew)
    , ("binding reports too many arguments", bindingReportsTooMany)
    , ("binding fills an omitted type default", bindingFillsTypeDefault)
    , ("binding fills an omitted value default", bindingFillsValueDefault)
    , ("binding resolves a later type default", bindingResolvesLaterTypeDefault)
    , ("binding resolves a later value default", bindingResolvesLaterValueDefault)
    , ("binding rejects a cyclic type default", bindingRejectsCyclicTypeDefault)
    , ("binding places zero arguments in an empty pack", bindingCreatesEmptyPack)
    , ("binding places every surplus argument in a final pack", bindingFillsFinalPack)
    , ("binding reserves required suffix arguments after a pack", bindingReservesRequiredSuffix)
    , ("binding keeps explicit and default origins distinct", bindingPreservesArgumentOrigin)
    , ("substitution replaces a type variable", substitutionReplacesTypeVariable)
    , ("substitution replaces nested named arguments", substitutionReplacesNestedType)
    , ("substitution replaces callable parameter and result types", substitutionReplacesCallableType)
    , ("substitution replaces a value parameter", substitutionReplacesValueParameter)
    , ("substitution preserves concrete scalar values", substitutionPreservesConcreteValue)
    , ("substitution preserves ErrorType", substitutionPreservesErrorType)
    , ("substitution reports an unbound type variable", substitutionReportsMissingType)
    , ("substitution reports an unbound value variable", substitutionReportsMissingValue)
    , ("rendering names an unknown template", renderingNamesUnknownTemplate)
    , ("rendering reports arity values", renderingReportsArity)
    , ("rendering identifies a mismatched parameter", renderingIdentifiesParameter)
    ]

analyzeCatalog :: String -> Maybe TemplateCatalog
analyzeCatalog source = case analyzeSemantics (CompilerInput "application-test.tala" source) of
    Right artifacts -> Just (buildTemplateCatalog (semanticTypedAST artifacts))
    Left _ -> Nothing

singleDescriptor :: String -> Maybe TemplateDeclarationDescriptor
singleDescriptor source = do
    TemplateCatalog declarations <- analyzeCatalog source
    case declarations of { [declaration] -> Just declaration; _ -> Nothing }

qualified :: [String] -> QualifiedName
qualified = QualifiedName . map Identifier

typeArgument :: String -> TemplateArgument
typeArgument name = TypeTemplateArgument (namedType name)

valueArgument :: Integer -> TemplateArgument
valueArgument = ValueTemplateArgument . IntegerTemplateValue

application :: QualifiedName -> [TemplateArgument] -> TemplateApplication
application = TemplateApplication

bindSource :: String -> QualifiedName -> [TemplateArgument] -> Either [TemplateApplicationError] TemplateBinding
bindSource source name arguments = case analyzeCatalog source of
    Just catalog -> bindTemplateApplication catalog (application name arguments)
    Nothing -> Left []

catalogRecordsQualifiedName :: Bool
catalogRecordsQualifiedName = case singleDescriptor "namespace Library; template<typename T> class Box {}" of
    Just descriptor -> templateDeclarationName descriptor == qualified ["Library", "Box"]
    Nothing -> False

catalogRecordsDeclarationSymbol :: Bool
catalogRecordsDeclarationSymbol = case singleDescriptor "template<typename T> class Box {}" of
    Just descriptor -> symbolIdValue (templateDeclarationSymbol descriptor) > 0
    Nothing -> False

catalogRecordsMembers :: Bool
catalogRecordsMembers = case singleDescriptor source of
    Just descriptor -> case templateDeclarationMembers descriptor of
        [(name, FunctionType [TypeVariable input] (TypeVariable output))] ->
            identifierText (resolvedSpelling name) == "Identity" && resolvedSymbol input == resolvedSymbol output
        _ -> False
    Nothing -> False
    where
        source = "template<typename T> class Box { T Identity(_ T value) { return value; } }"

catalogExcludesOrdinaryDeclarations :: Bool
catalogExcludesOrdinaryDeclarations = case analyzeCatalog "class App { void Run() { return; } }" of
    Just (TemplateCatalog []) -> True
    _ -> False

catalogPreservesOrder :: Bool
catalogPreservesOrder = case analyzeCatalog source of
    Just (TemplateCatalog declarations) -> map templateDeclarationName declarations == map (qualified . (: [])) ["Left", "Right"]
    Nothing -> False
    where
        source = "template<typename T> class Left {} template<typename U> class Right {}"

catalogDescribesTypeParameter :: Bool
catalogDescribesTypeParameter = case singleDescriptor "template<typename T> class Box {}" of
    Just descriptor -> case templateDeclarationParameters descriptor of
        [parameter] -> templateDescriptorCategory parameter == TypeParameterCategory
        _ -> False
    Nothing -> False

catalogDescribesValueParameter :: Bool
catalogDescribesValueParameter = case singleDescriptor "template<int N> class Buffer {}" of
    Just descriptor -> case templateDeclarationParameters descriptor of
        [parameter] -> templateDescriptorCategory parameter == ValueParameterCategory intType
        _ -> False
    Nothing -> False

catalogDescribesTemplateParameter :: Bool
catalogDescribesTemplateParameter = case singleDescriptor "template<template<typename> class C> class Box {}" of
    Just descriptor -> case templateDeclarationParameters descriptor of
        [parameter] -> case templateDescriptorCategory parameter of TemplateParameterCategory [_] -> True; _ -> False
        _ -> False
    Nothing -> False

catalogPreservesPackStatus :: Bool
catalogPreservesPackStatus = case singleDescriptor "template<typename... T> class Tuple {}" of
    Just descriptor -> case templateDeclarationParameters descriptor of [parameter] -> templateDescriptorIsPack parameter; _ -> False
    Nothing -> False

catalogPreservesDefault :: Bool
catalogPreservesDefault = case singleDescriptor "template<typename T = int> class Box {}" of
    Just descriptor -> case templateDeclarationParameters descriptor of
        [parameter] -> templateDescriptorDefault parameter == Just (TemplateTypeDefault (ExplicitType (Identifier "int")))
        _ -> False
    Nothing -> False

lookupFindsQualifiedName :: Bool
lookupFindsQualifiedName = case analyzeCatalog "namespace A; template<typename T> class Box {}" of
    Just catalog -> case lookupTemplateDeclaration (qualified ["A", "Box"]) catalog of Right _ -> True; Left _ -> False
    Nothing -> False

lookupRejectsShortName :: Bool
lookupRejectsShortName = case analyzeCatalog "namespace A; template<typename T> class Box {}" of
    Just catalog -> lookupTemplateDeclaration (qualified ["Box"]) catalog == Left (UnknownTemplateDeclaration (qualified ["Box"]))
    Nothing -> False

lookupReportsUnknown :: Bool
lookupReportsUnknown =
    lookupTemplateDeclaration (qualified ["Missing"]) (TemplateCatalog [])
        == Left (UnknownTemplateDeclaration (qualified ["Missing"]))

lookupReportsAmbiguous :: Bool
lookupReportsAmbiguous = case singleDescriptor "template<typename T> class Box {}" of
    Just descriptor -> case lookupTemplateDeclaration (qualified ["Box"]) (TemplateCatalog [descriptor, descriptor]) of
        Left (AmbiguousTemplateDeclaration _ symbols) -> length symbols == 2
        _ -> False
    Nothing -> False

minimumArityCountsRequired :: Bool
minimumArityCountsRequired = case singleDescriptor "template<typename T, int N> class Box {}" of
    Just value -> minimumTemplateArity value == 2
    Nothing -> False

minimumArityExcludesDefaults :: Bool
minimumArityExcludesDefaults = case singleDescriptor "template<typename T = int, int N = 4> class Box {}" of
    Just value -> minimumTemplateArity value == 0
    Nothing -> False

minimumArityExcludesPacks :: Bool
minimumArityExcludesPacks = case singleDescriptor "template<typename... T> class Box {}" of
    Just value -> minimumTemplateArity value == 0
    Nothing -> False

maximumArityIsExact :: Bool
maximumArityIsExact = case singleDescriptor "template<typename T, int N> class Box {}" of
    Just value -> maximumTemplateArity value == Just 2
    Nothing -> False

maximumArityIsUnbounded :: Bool
maximumArityIsUnbounded = case singleDescriptor "template<typename... T> class Box {}" of
    Just value -> maximumTemplateArity value == Nothing
    Nothing -> False

bindingAcceptsType :: Bool
bindingAcceptsType = case bindSource "template<typename T> class Box {}" (qualified ["Box"]) [typeArgument "String"] of
    Right _ -> True
    Left _ -> False

bindingAcceptsValue :: Bool
bindingAcceptsValue = case bindSource "template<int N> class Buffer {}" (qualified ["Buffer"]) [valueArgument 4] of
    Right _ -> True
    Left _ -> False

bindingAcceptsTemplateName :: Bool
bindingAcceptsTemplateName = case bindSource source (qualified ["Wrapper"]) [typeArgument "System.Array"] of Right _ -> True; Left _ -> False
    where
        source = "template<template<typename> class C> class Wrapper {}"

bindingRejectsValueForType :: Bool
bindingRejectsValueForType = categoryFailure (bindSource "template<typename T> class Box {}" (qualified ["Box"]) [valueArgument 1])

bindingRejectsTypeForValue :: Bool
bindingRejectsTypeForValue = categoryFailure (bindSource "template<int N> class Box {}" (qualified ["Box"]) [typeArgument "int"])

bindingRejectsFunctionForTemplate :: Bool
bindingRejectsFunctionForTemplate = categoryFailure (bindSource source (qualified ["Box"]) [TypeTemplateArgument (FunctionType [] voidType)])
    where
        source = "template<template<typename> class C> class Box {}"

categoryFailure :: Either [TemplateApplicationError] value -> Bool
categoryFailure result = case result of Left [TemplateArgumentCategoryMismatch {}] -> True; _ -> False

bindingReportsTooFew :: Bool
bindingReportsTooFew = case bindSource "template<typename T> class Box {}" (qualified ["Box"]) [] of
    Left [TooFewTemplateArguments _ 1 0] -> True
    _ -> False

bindingReportsTooMany :: Bool
bindingReportsTooMany = case bindSource "template<typename T> class Box {}" (qualified ["Box"]) [typeArgument "int", typeArgument "long"] of
    Left [TooManyTemplateArguments _ 1 2] -> True
    _ -> False

bindingFillsTypeDefault :: Bool
bindingFillsTypeDefault = defaultBindingIs (typeArgument "int") (bindSource "template<typename T = int> class Box {}" (qualified ["Box"]) [])

bindingFillsValueDefault :: Bool
bindingFillsValueDefault = defaultBindingIs (valueArgument 8) (bindSource "template<int N = 8> class Box {}" (qualified ["Box"]) [])

defaultBindingIs :: TemplateArgument -> Either [TemplateApplicationError] TemplateBinding -> Bool
defaultBindingIs expected result = case result of
    Right binding -> case templateBindingArguments binding of [(_, [DefaultTemplateArgument actual])] -> actual == expected; _ -> False
    Left _ -> False

bindingResolvesLaterTypeDefault :: Bool
bindingResolvesLaterTypeDefault = case bindSource source (qualified ["Pair"]) [] of
    Right binding -> map (map unwrap . snd) (templateBindingArguments binding) == [[typeArgument "int"], [typeArgument "int"]]
    Left _ -> False
    where
        source = "template<typename T = U, typename U = int> class Pair {}"
        unwrap (ExplicitTemplateArgument value) = value
        unwrap (DefaultTemplateArgument value) = value

bindingResolvesLaterValueDefault :: Bool
bindingResolvesLaterValueDefault = case bindSource source (qualified ["Buffer"]) [] of
    Right binding -> map (map unwrap . snd) (templateBindingArguments binding) == [[valueArgument 4], [valueArgument 4]]
    Left _ -> False
    where
        source = "template<int N = M, int M = 4> class Buffer {}"
        unwrap (ExplicitTemplateArgument value) = value
        unwrap (DefaultTemplateArgument value) = value

bindingRejectsCyclicTypeDefault :: Bool
bindingRejectsCyclicTypeDefault = case bindSource source (qualified ["Cycle"]) [] of Left [UnresolvedTemplateDefault {}] -> True; _ -> False
    where
        source = "template<typename T = U, typename U = T> class Cycle {}"

bindingCreatesEmptyPack :: Bool
bindingCreatesEmptyPack = case bindSource "template<typename... T> class Tuple {}" (qualified ["Tuple"]) [] of
    Right binding -> case templateBindingArguments binding of [(_, [])] -> True; _ -> False
    Left _ -> False

bindingFillsFinalPack :: Bool
bindingFillsFinalPack = case bindSource "template<typename... T> class Tuple {}" (qualified ["Tuple"]) arguments of
    Right binding -> case templateBindingArguments binding of [(_, values)] -> length values == 3; _ -> False
    Left _ -> False
    where
        arguments = map typeArgument ["int", "String", "bool"]

bindingReservesRequiredSuffix :: Bool
bindingReservesRequiredSuffix = case bindSource source (qualified ["Tuple"]) arguments of
    Right binding -> map (length . snd) (templateBindingArguments binding) == [2, 1]
    Left _ -> False
    where
        source = "template<typename... T, int N> class Tuple {}"
        arguments = [typeArgument "int", typeArgument "String", valueArgument 2]

bindingPreservesArgumentOrigin :: Bool
bindingPreservesArgumentOrigin = case bindSource source (qualified ["Pair"]) [typeArgument "String"] of
    Right binding -> case templateBindingArguments binding of
        [(_, [ExplicitTemplateArgument _]), (_, [DefaultTemplateArgument _])] -> True
        _ -> False
    Left _ -> False
    where
        source = "template<typename T, typename U = int> class Pair {}"

typeBinding :: Maybe TemplateBinding
typeBinding = case bindSource "template<typename T> class Box {}" (qualified ["Box"]) [typeArgument "String"] of
    Right value -> Just value
    Left _ -> Nothing

valueBinding :: Maybe TemplateBinding
valueBinding = case bindSource "template<int N> class Buffer {}" (qualified ["Buffer"]) [valueArgument 16] of
    Right value -> Just value
    Left _ -> Nothing

firstParameterName :: TemplateBinding -> ResolvedName
firstParameterName binding = case templateBindingArguments binding of
    (name, _) : _ -> name
    [] -> ResolvedName (SymbolId (-1)) (Identifier "<missing-template-parameter>")

substitutionReplacesTypeVariable :: Bool
substitutionReplacesTypeVariable = case typeBinding of
    Just binding -> substituteType binding (TypeVariable (firstParameterName binding)) == Right (namedType "String")
    Nothing -> False

substitutionReplacesNestedType :: Bool
substitutionReplacesNestedType = case typeBinding of
    Just binding ->
        let variable = TypeVariable (firstParameterName binding)
            input = NamedType (qualified ["System", "Array"]) [TypeTemplateArgument variable]
            expected = NamedType (qualified ["System", "Array"]) [typeArgument "String"]
         in substituteType binding input == Right expected
    Nothing -> False

substitutionReplacesCallableType :: Bool
substitutionReplacesCallableType = case typeBinding of
    Just binding ->
        let variable = TypeVariable (firstParameterName binding)
         in substituteType binding (FunctionType [variable] variable)
                == Right (FunctionType [namedType "String"] (namedType "String"))
    Nothing -> False

substitutionReplacesValueParameter :: Bool
substitutionReplacesValueParameter = case valueBinding of
    Just binding ->
        substituteTemplateValue binding (TemplateValueParameter (firstParameterName binding)) == Right (IntegerTemplateValue 16)
    Nothing -> False

substitutionPreservesConcreteValue :: Bool
substitutionPreservesConcreteValue = case valueBinding of
    Just binding -> substituteTemplateValue binding (IntegerTemplateValue 3) == Right (IntegerTemplateValue 3)
    Nothing -> False

substitutionPreservesErrorType :: Bool
substitutionPreservesErrorType = case typeBinding of Just binding -> substituteType binding ErrorType == Right ErrorType; Nothing -> False

substitutionReportsMissingType :: Bool
substitutionReportsMissingType = case typeBinding of
    Just binding -> case substituteType binding (TypeVariable (ResolvedName (SymbolId 999) (Identifier "Missing"))) of
        Left UnresolvedTemplateDefault {} -> True
        _ -> False
    Nothing -> False

substitutionReportsMissingValue :: Bool
substitutionReportsMissingValue = case valueBinding of
    Just binding -> case substituteTemplateValue binding (TemplateValueParameter (ResolvedName (SymbolId 999) (Identifier "Missing"))) of
        Left UnresolvedTemplateDefault {} -> True
        _ -> False
    Nothing -> False

renderingNamesUnknownTemplate :: Bool
renderingNamesUnknownTemplate =
    renderTemplateApplicationError (UnknownTemplateDeclaration (qualified ["A", "Box"]))
        == "unknown template declaration A.Box"

renderingReportsArity :: Bool
renderingReportsArity =
    renderTemplateApplicationError (TooFewTemplateArguments (qualified ["Box"]) 2 1)
        == "Box requires at least 2 template arguments, but received 1"

renderingIdentifiesParameter :: Bool
renderingIdentifiesParameter = case singleDescriptor "template<typename T> class Box {}" of
    Just descriptor -> case templateDeclarationParameters descriptor of
        [parameter] ->
            "parameter T"
                `contains` renderTemplateApplicationError
                    ( TemplateArgumentCategoryMismatch
                        (qualified ["Box"])
                        (templateDescriptorName parameter)
                        0
                        TypeParameterCategory
                        (valueArgument 1)
                    )
        _ -> False
    Nothing -> False

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)
    where
        tails [] = [[]]
        tails value@(_ : rest) = value : tails rest
        prefixOf [] _ = True
        prefixOf _ [] = False
        prefixOf (left : leftRest) (right : rightRest) = left == right && prefixOf leftRest rightRest
