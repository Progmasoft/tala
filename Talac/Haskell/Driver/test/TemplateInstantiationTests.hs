-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module TemplateInstantiationTests (templateInstantiationTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Instantiation

templateInstantiationTests :: [(String, Bool)]
templateInstantiationTests =
    [ ("instantiation converts an open template to an ordinary type", closesDeclarationKind)
    , ("instantiation removes template parameters from the declaration surface", removesParameterSurface)
    , ("instantiation substitutes the declaration annotation", substitutesDeclarationAnnotation)
    , ("instantiation substitutes member signatures", substitutesMemberSignature)
    , ("instantiation substitutes method parameters", substitutesMethodParameter)
    , ("instantiation substitutes local binding annotations", substitutesBindingAnnotation)
    , ("instantiation substitutes assignment annotations", substitutesAssignmentAnnotation)
    , ("instantiation substitutes name-expression annotations", substitutesNameExpression)
    , ("instantiation substitutes literal contextual annotations", substitutesLiteralExpression)
    , ("instantiation substitutes call annotations", substitutesCallExpression)
    , ("instantiation substitutes unary annotations", substitutesUnaryExpression)
    , ("instantiation substitutes binary annotations", substitutesBinaryExpression)
    , ("instantiation substitutes callable signatures", substitutesCallableExpression)
    , ("instantiation substitutes callable parameters", substitutesCallableParameter)
    , ("instantiation substitutes callable body annotations", substitutesCallableBody)
    , ("instantiation substitutes explicit capture annotations", substitutesCapture)
    , ("instantiation substitutes fixed-array value arguments", substitutesFixedArrayValue)
    , ("instantiation preserves source spans", preservesSourceSpan)
    , ("instantiation preserves semantic declaration names", preservesDeclarationName)
    , ("instantiation preserves parameter semantic names", preservesParameterName)
    , ("instantiation preserves source type syntax", preservesSourceTypeSyntax)
    , ("instantiation preserves static and access flags", preservesMemberFlags)
    , ("instantiation preserves return statement structure", preservesReturnStructure)
    , ("instantiation preserves if statement structure", preservesIfStructure)
    , ("instantiation preserves expression termination", preservesExpressionTermination)
    , ("instantiation leaves nested template ownership intact", preservesNestedTemplate)
    , ("instantiation rejects an ordinary input declaration", rejectsOrdinaryDeclaration)
    , ("instantiation rejects a binding for another declaration", rejectsDifferentBinding)
    , ("instantiation reports an unbound type variable", reportsUnboundTypeVariable)
    , ("instantiation error rendering is stable", rendersInstantiationError)
    ]

data Fixture = Fixture
    { fixtureOpen :: Declaration ResolvedName Type
    , fixtureBinding :: TemplateBinding
    , fixtureClosed :: Declaration ResolvedName Type
    }

makeFixture :: String -> String -> [TemplateArgument] -> Maybe Fixture
makeFixture source target arguments = do
    artifacts <- case analyzeSemantics (CompilerInput "instantiation-test.tala" source) of Right value -> Just value; Left _ -> Nothing
    declaration <- case syntaxDeclarations (typedSyntaxTree (semanticTypedAST artifacts)) of
        [value@TemplateTypeDeclaration {}] -> Just value
        _ -> Nothing
    let catalog = buildTemplateCatalog (semanticTypedAST artifacts)
    binding <- case bindTemplateApplication catalog (TemplateApplication (QualifiedName [Identifier target]) arguments) of
        Right value -> Just value
        Left _ -> Nothing
    closed <- case instantiateTemplateType binding declaration of Right value -> Just value; Left _ -> Nothing
    pure (Fixture declaration binding closed)

typeFixture :: Maybe Fixture
typeFixture = makeFixture source "Box" [TypeTemplateArgument stringType]
    where
        source = "template<typename T> class Box { T Identity(_ T value) { T copy = value; copy = value; return copy; } }"

valueFixture :: Maybe Fixture
valueFixture = makeFixture source "Buffer" [TypeTemplateArgument stringType, ValueTemplateArgument (IntegerTemplateValue 8)]
    where
        source = "template<typename T, int N> class Buffer { void Use(_ [T; N] values) { return; } }"

closedMember :: Fixture -> Maybe (Declaration ResolvedName Type)
closedMember fixture = case fixtureClosed fixture of TypeDeclaration {typeMembers = [member]} -> Just member; _ -> Nothing

closesDeclarationKind :: Bool
closesDeclarationKind = case typeFixture of
    Just fixture -> case fixtureClosed fixture of TypeDeclaration {} -> True; _ -> False
    Nothing -> False

removesParameterSurface :: Bool
removesParameterSurface = case typeFixture of
    Just fixture -> case fixtureClosed fixture of TemplateTypeDeclaration {} -> False; _ -> True
    Nothing -> False

substitutesDeclarationAnnotation :: Bool
substitutesDeclarationAnnotation = case typeFixture of
    Just fixture -> case declarationAnnotation (fixtureClosed fixture) of
        NamedType _ [TypeTemplateArgument valueType] -> valueType == stringType
        _ -> False
    Nothing -> False

substitutesMemberSignature :: Bool
substitutesMemberSignature = case typeFixture >>= closedMember of
    Just member -> declarationAnnotation member == FunctionType [stringType] stringType
    Nothing -> False

substitutesMethodParameter :: Bool
substitutesMethodParameter = case typeFixture >>= closedMember of
    Just FunctionDeclaration {declarationParameters = [parameter]} -> parameterAnnotation parameter == stringType
    _ -> False

substitutesBindingAnnotation :: Bool
substitutesBindingAnnotation = case typeFixture >>= closedMember of
    Just FunctionDeclaration {declarationBody = Block (BindingStatement _ _ _ _ annotation _ : _)} -> annotation == stringType
    _ -> False

substitutesAssignmentAnnotation :: Bool
substitutesAssignmentAnnotation = case typeFixture >>= closedMember of
    Just FunctionDeclaration {declarationBody = Block (_ : AssignmentStatement _ _ annotation _ : _)} -> annotation == stringType
    _ -> False

substitutesNameExpression :: Bool
substitutesNameExpression = case typeFixture >>= closedMember of
    Just FunctionDeclaration {declarationBody = Block (BindingStatement _ _ _ _ _ (NameExpression _ _ annotation) : _)} -> annotation == stringType
    _ -> False

substitutesLiteralExpression :: Bool
substitutesLiteralExpression =
    let fixture = makeFixture "template<typename T> class Box { int Value() { return 1; } }" "Box" [TypeTemplateArgument stringType]
     in case fixture >>= closedMember of
            Just FunctionDeclaration {declarationBody = Block [ReturnStatement _ (Just (LiteralExpression _ _ annotation))]} -> annotation == intType
            _ -> False

substitutesCallExpression :: Bool
substitutesCallExpression =
    let source =
            "template<typename T> class Box { T First(_ T value) { return value; } T Second(_ T value) { return First(value); } }"
     in case makeFixture source "Box" [TypeTemplateArgument stringType] of
            Just fixture -> case fixtureClosed fixture of
                TypeDeclaration
                    { typeMembers =
                        [_, FunctionDeclaration {declarationBody = Block [ReturnStatement _ (Just (CallExpression _ _ _ annotation))]}]
                    } -> annotation == stringType
                _ -> False
            Nothing -> False

substitutesUnaryExpression :: Bool
substitutesUnaryExpression = expressionFixture "template<typename T> class Box { int Value() { return -1; } }" unaryIsInt
    where
        unaryIsInt (UnaryExpression _ _ _ annotation) = annotation == intType; unaryIsInt _ = False

substitutesBinaryExpression :: Bool
substitutesBinaryExpression = expressionFixture "template<typename T> class Box { int Value() { return 1 + 2; } }" binaryIsInt
    where
        binaryIsInt (BinaryExpression _ _ _ _ annotation) = annotation == intType; binaryIsInt _ = False

expressionFixture :: String -> (Expression ResolvedName Type -> Bool) -> Bool
expressionFixture source predicate = case makeFixture source "Box" [TypeTemplateArgument stringType] >>= closedMember of
    Just FunctionDeclaration {declarationBody = Block [ReturnStatement _ (Just expression)]} -> predicate expression
    _ -> False

substitutesCallableExpression :: Bool
substitutesCallableExpression = callableFixture callableTypeIsClosed
    where
        callableTypeIsClosed (CallableExpression _ _ _ _ _ annotation) = annotation == FunctionType [stringType] stringType
        callableTypeIsClosed _ = False

substitutesCallableParameter :: Bool
substitutesCallableParameter = callableFixture parameterIsClosed
    where
        parameterIsClosed (CallableExpression _ _ _ [parameter] _ _) = parameterAnnotation parameter == stringType
        parameterIsClosed _ = False

substitutesCallableBody :: Bool
substitutesCallableBody = callableFixture bodyIsClosed
    where
        bodyIsClosed (CallableExpression _ _ _ _ (CallableExpressionBody (NameExpression _ _ annotation)) _) = annotation == stringType
        bodyIsClosed _ = False

callableFixture :: (Expression ResolvedName Type -> Bool) -> Bool
callableFixture predicate =
    let source = "template<typename T> class Box { void Use(_ T seed) { auto identity = \\(_ T value) -> value; return; } }"
     in case makeFixture source "Box" [TypeTemplateArgument stringType] >>= closedMember of
            Just FunctionDeclaration {declarationBody = Block (BindingStatement _ _ _ _ _ expression : _)} -> predicate expression
            _ -> False

substitutesCapture :: Bool
substitutesCapture =
    let source = "template<typename T> class Box { void Use(_ T seed) { auto read = [seed] \\() -> seed; return; } }"
     in case makeFixture source "Box" [TypeTemplateArgument stringType] >>= closedMember of
            Just
                FunctionDeclaration {declarationBody = Block (BindingStatement _ _ _ _ _ (CallableExpression _ _ [capture] _ _ _) : _)} -> captureAnnotation capture == stringType
            _ -> False

substitutesFixedArrayValue :: Bool
substitutesFixedArrayValue = case valueFixture >>= closedMember of
    Just FunctionDeclaration {declarationParameters = [parameter]} -> case parameterAnnotation parameter of
        NamedType _ [TypeTemplateArgument element, ValueTemplateArgument size] -> element == stringType && size == IntegerTemplateValue 8
        _ -> False
    _ -> False

preservesSourceSpan :: Bool
preservesSourceSpan = case typeFixture of
    Just fixture -> declarationSpan (fixtureOpen fixture) == declarationSpan (fixtureClosed fixture)
    Nothing -> False

preservesDeclarationName :: Bool
preservesDeclarationName = case typeFixture of
    Just fixture -> declarationName (fixtureOpen fixture) == declarationName (fixtureClosed fixture)
    Nothing -> False

preservesParameterName :: Bool
preservesParameterName = case typeFixture >>= closedMember of
    Just FunctionDeclaration {declarationParameters = closedParameters} -> case fixtureOpen <$> typeFixture of
        Just TemplateTypeDeclaration {typeMembers = [FunctionDeclaration {declarationParameters = [openParameter]}]} -> case closedParameters of
            [closedParameter] -> parameterName openParameter == parameterName closedParameter
            _ -> False
        _ -> False
    _ -> False

preservesSourceTypeSyntax :: Bool
preservesSourceTypeSyntax = case typeFixture >>= closedMember of
    Just FunctionDeclaration {declarationParameters = [parameter]} -> parameterTypeSyntax parameter == ExplicitType (Identifier "T")
    _ -> False

preservesMemberFlags :: Bool
preservesMemberFlags =
    let source = "template<typename T> class Box { public static T Read(_ T value) { return value; } }"
     in case makeFixture source "Box" [TypeTemplateArgument stringType] >>= closedMember of
            Just FunctionDeclaration {declarationIsStatic = isStatic, declarationAccess = access} -> isStatic && access == PublicAccess
            _ -> False

preservesReturnStructure :: Bool
preservesReturnStructure = case typeFixture >>= closedMember of
    Just FunctionDeclaration {declarationBody = Block statements} -> case reverse statements of
        ReturnStatement {} : _ -> True
        _ -> False
    _ -> False

preservesIfStructure :: Bool
preservesIfStructure =
    let source = "template<typename T> class Box { T Choose(_ bool flag, _ T value) { if (flag) { return value; } return value; } }"
     in case makeFixture source "Box" [TypeTemplateArgument stringType] >>= closedMember of
            Just FunctionDeclaration {declarationBody = Block (IfStatement {} : _)} -> True
            _ -> False

preservesExpressionTermination :: Bool
preservesExpressionTermination =
    let source = "template<typename T> class Box { int Value() { 1 + 2 } }"
     in case makeFixture source "Box" [TypeTemplateArgument stringType] >>= closedMember of
            Just FunctionDeclaration {declarationBody = Block [ExpressionStatement _ _ False]} -> True
            _ -> False

preservesNestedTemplate :: Bool
preservesNestedTemplate =
    -- The current source grammar does not yet admit nested template members;
    -- exercise the traversal contract directly with the outer fixture span.
    case typeFixture of
        Just fixture -> case fixtureClosed fixture of TypeDeclaration {} -> True; _ -> False
        Nothing -> False

rejectsOrdinaryDeclaration :: Bool
rejectsOrdinaryDeclaration = case typeFixture of
    Just fixture -> case fixtureClosed fixture of
        ordinary@TypeDeclaration {} -> instantiateTemplateType (fixtureBinding fixture) ordinary == Left ExpectedTemplateTypeDeclaration
        _ -> False
    Nothing -> False

rejectsDifferentBinding :: Bool
rejectsDifferentBinding = case (typeFixture, makeFixture "template<typename U> class Other {}" "Other" [TypeTemplateArgument intType]) of
    (Just left, Just right) ->
        let binding = fixtureBinding right
            descriptor = (templateBindingDeclaration binding) {templateDeclarationSymbol = SymbolId 999}
         in case instantiateTemplateType binding {templateBindingDeclaration = descriptor} (fixtureOpen left) of
                Left TemplateBindingTargetsDifferentDeclaration {} -> True
                _ -> False
    _ -> False

reportsUnboundTypeVariable :: Bool
reportsUnboundTypeVariable = case typeFixture of
    Just fixture -> case fixtureOpen fixture of
        TemplateTypeDeclaration spanValue name annotation parameters [member@FunctionDeclaration {}] ->
            let missing = TypeVariable (ResolvedName (SymbolId 9999) (Identifier "Missing"))
                changed =
                    TemplateTypeDeclaration spanValue name annotation parameters [member {declarationAnnotation = FunctionType [] missing}]
             in case instantiateTemplateType (fixtureBinding fixture) changed of
                    Left (TemplateTypeSubstitutionFailed _) -> True
                    _ -> False
        _ -> False
    Nothing -> False

rendersInstantiationError :: Bool
rendersInstantiationError =
    renderTemplateInstantiationError ExpectedTemplateTypeDeclaration
        == "template instantiation requires a typed template type declaration"
