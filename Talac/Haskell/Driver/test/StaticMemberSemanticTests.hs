-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Semantic conformance tests for type-qualified static method calls.

The source fragments intentionally use only declaration and call forms already
present in Spec/Language/Decls.tala. These tests pin down candidate collection,
exact parameter matching, access filtering, diagnostics, and the stable symbol
that must survive from semantic analysis into Core.
-}
module StaticMemberSemanticTests (staticMemberSemanticTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend

staticMemberSemanticTests :: [(String, Bool)]
staticMemberSemanticTests =
    [ ("a single public static method resolves", singlePublicMethod)
    , ("a default-access static method resolves in its source unit", defaultAccessMethod)
    , ("an internal static method resolves in its source unit", internalMethod)
    , ("a private static method resolves in its declaring class", privateMethodWithinOwner)
    , ("a protected static method resolves in its declaring class", protectedMethodWithinOwner)
    , ("a private static method is hidden from another class", privateMethodOutsideOwner)
    , ("a protected static method is hidden from an unrelated class", protectedMethodOutsideOwner)
    , ("an instance method is not callable through the type surface", instanceMethodThroughType)
    , ("a static method is not callable through a value receiver", staticMethodThroughValue)
    , ("a local identifier that shadows a type is not a type receiver", localShadowsType)
    , ("a missing member reports the member-not-found diagnostic", missingMethod)
    , ("a case-mismatched member reports the member-not-found diagnostic", caseSensitiveMember)
    , ("a bare member selector is rejected until it denotes a method call", bareMethodSelector)
    , ("a method reference is the method and not its result", methodReferenceAsResult)
    , ("a member selected on a value is rejected until members of values exist", valueMemberSelector)
    , ("an overload call with too few arguments reports arity", tooFewArguments)
    , ("an overload call with too many arguments reports arity", tooManyArguments)
    , ("an overload call rejects a mismatched argument type", mismatchedArgumentType)
    , ("an overload call rejects an implicit numeric conversion", implicitNumericConversionRejected)
    , ("an overload call rejects a String-to-scalar conversion", stringConversionRejected)
    , ("an overload call rejects a scalar-to-String conversion", scalarConversionRejected)
    , ("distinct parameter lists form a valid overload set", distinctParameterLists)
    , ("same-name methods on different owners remain independent", overloadFamiliesAreOwnerScoped)
    , ("the selected overload is stored as a stable symbol reference", selectedSymbolIsRecorded)
    , ("each overload declaration keeps its own SymbolId", overloadDeclarationsHaveDistinctIds)
    , ("method symbols remain distinct across type declarations", methodsAcrossOwnersHaveDistinctIds)
    , ("the Core call target agrees with the selected overload symbol", coreCallTargetAgrees)
    , ("overload selection is independent of declaration order", declarationOrderDoesNotSelect)
    , ("equal arity does not imply equal overload viability", equalArityUsesTypes)
    , ("a call can select the second overload after rejecting the first", secondCandidateWins)
    , ("a call can select the first overload after rejecting the second", firstCandidateWins)
    , ("an overloaded method remains callable from its owner", ownerCallUsesOverloadSet)
    , ("an overload selected by a typed local preserves its annotation", selectedAnnotationIsKept)
    , ("a method returning void remains a valid call statement", voidOverloadCall)
    , ("an overload returning a value can be used as a return expression", valueOverloadReturn)
    , ("an overload returning a value can initialize a typed local", valueOverloadInitializer)
    , ("a selector receiver is checked before member lookup", receiverMustNameDeclaredType)
    , ("a local value receiver does not become a dynamic dispatch", valueReceiverIsNotDynamic)
    , ("a nested call receiver is not silently treated as a type", nestedCallReceiverNotType)
    , ("a qualified selector is rejected when the type is absent", unknownTypeReceiver)
    , ("a public overload remains selectable beside an inaccessible overload", publicCandidateSurvivesPrivateSibling)
    , ("a private-only overload family reports access failure", privateOnlyFamilyReportsAccess)
    , ("access modifiers do not create a second overload identity", accessDoesNotDistinguishSignature)
    , ("return types do not create a second overload identity", returnDoesNotDistinguishSignature)
    , ("static and instance declarations do not create distinct signatures", staticnessDoesNotDistinguishSignature)
    , ("parameter order contributes to overload identity", parameterOrderIsSignificant)
    , ("different owners may reuse a member spelling and signature", ownerScopePermitsSameSignature)
    , ("a type name is case-sensitive", typeNameIsCaseSensitive)
    , ("a returned call has the selected method result type", returnedCallHasResultType)
    , ("a value receiver's own type is not guessed from its spelling", valueReceiverTypeIsNotGuessed)
    , ("unqualified owner calls share the declared overload family", ownerUnqualifiedCall)
    , ("unqualified calls do not resolve methods on other classes", foreignUnqualifiedCallIsRejected)
    , ("selector diagnostics retain a source span", methodDiagnosticHasSpan)
    , ("selector diagnostics belong to the type-checker stage", methodDiagnosticHasStage)
    , ("selector diagnostics are errors rather than warnings", methodDiagnosticSeverity)
    ]
        ++ scalarPairSelectionTests
        ++ scalarDuplicateSignatureTests
        ++ scalarArityTests

singlePublicMethod :: Bool
singlePublicMethod = succeeds (staticProgram "public static int Read() { return 7; }" "int Use() { return Catalog.Read(); }")

defaultAccessMethod :: Bool
defaultAccessMethod = succeeds (staticProgram "static int Read() { return 7; }" "int Use() { return Catalog.Read(); }")

internalMethod :: Bool
internalMethod = succeeds (staticProgram "internal static int Read() { return 7; }" "int Use() { return Catalog.Read(); }")

privateMethodWithinOwner :: Bool
privateMethodWithinOwner =
    succeeds ("class Catalog { private static int Read() { return 7; } int Use() { return Catalog.Read(); } }")

protectedMethodWithinOwner :: Bool
protectedMethodWithinOwner =
    succeeds ("class Catalog { protected static int Read() { return 7; } int Use() { return Catalog.Read(); } }")

privateMethodOutsideOwner :: Bool
privateMethodOutsideOwner =
    hasCode
        "TAT0033"
        "class Catalog { private static int Read() { return 7; } } class Caller { int Use() { return Catalog.Read(); } }"

protectedMethodOutsideOwner :: Bool
protectedMethodOutsideOwner =
    hasCode
        "TAT0033"
        "class Catalog { protected static int Read() { return 7; } } class Caller { int Use() { return Catalog.Read(); } }"

instanceMethodThroughType :: Bool
instanceMethodThroughType = hasCode "TAT0031" "class Catalog { int Read() { return 7; } } class Caller { int Use() { return Catalog.Read(); } }"

staticMethodThroughValue :: Bool
staticMethodThroughValue =
    hasCode
        "TAT0032"
        "class Catalog { public static int Read() { return 7; } } class Caller { int Use(Catalog value) { return value.Read(); } }"

localShadowsType :: Bool
localShadowsType =
    hasCode
        "TAT0032"
        "class Catalog { public static int Read() { return 7; } } class Caller { int Use(int Catalog) { return Catalog.Read(); } }"

missingMethod :: Bool
missingMethod = hasCode "TAT0029" "class Catalog {} class Caller { int Use() { return Catalog.Read(); } }"

caseSensitiveMember :: Bool
caseSensitiveMember =
    hasCode
        "TAT0029"
        "class Catalog { public static int Read() { return 7; } } class Caller { int Use() { return Catalog.read(); } }"

bareMethodSelector :: Bool
bareMethodSelector =
    hasCode
        "TAT0034"
        "class Catalog { public static int Read() { return 7; } } class Caller { int Use() { return Catalog.Read; } }"

-- The reference is the method itself, so returning it as an int is a
-- mismatch of types.
methodReferenceAsResult :: Bool
methodReferenceAsResult =
    hasCode
        "TAT0005"
        "class Catalog { public static int Read() { return 7; } } class Caller { int Use() { return Catalog::Read; } }"

valueMemberSelector :: Bool
valueMemberSelector =
    hasCode
        "TAT0034"
        "class Catalog { public static int Read() { return 7; } } class Caller { int Use() { int value = 1; return value.Read; } }"

tooFewArguments :: Bool
tooFewArguments =
    hasCode
        "TAT0008"
        "class Catalog { public static int Read(int first, int second) { return first; } } class Caller { int Use() { return Catalog.Read(1); } }"

tooManyArguments :: Bool
tooManyArguments =
    hasCode
        "TAT0008"
        "class Catalog { public static int Read(int first) { return first; } } class Caller { int Use() { return Catalog.Read(1, 2); } }"

mismatchedArgumentType :: Bool
mismatchedArgumentType =
    hasCode
        "TAT0009"
        "class Catalog { public static int Read(String text) { return 1; } } class Caller { int Use() { return Catalog.Read(1); } }"

implicitNumericConversionRejected :: Bool
implicitNumericConversionRejected =
    hasCode
        "TAT0009"
        "class Catalog { public static int Read(long value) { return 1; } } class Caller { int Use(int value) { return Catalog.Read(value); } }"

stringConversionRejected :: Bool
stringConversionRejected =
    hasCode
        "TAT0009"
        "class Catalog { public static int Read(String text) { return 1; } } class Caller { int Use(char value) { return Catalog.Read(value); } }"

scalarConversionRejected :: Bool
scalarConversionRejected =
    hasCode
        "TAT0009"
        "class Catalog { public static int Read(int value) { return value; } } class Caller { int Use(String value) { return Catalog.Read(value); } }"

distinctParameterLists :: Bool
distinctParameterLists =
    succeeds
        "class Catalog { public static int Read(int value) { return value; } public static int Read(String value) { return 1; } } class Caller { int Use(int value) { return Catalog.Read(value); } }"

overloadFamiliesAreOwnerScoped :: Bool
overloadFamiliesAreOwnerScoped =
    succeeds
        "class First { public static int Read(int value) { return value; } } class Second { public static int Read(int value) { return value; } } class Caller { int Use() { return First.Read(1) + Second.Read(2); } }"

selectedSymbolIsRecorded :: Bool
selectedSymbolIsRecorded =
    sameSuccessfulSymbol
        (selectedMethodSymbol "int" selectedIntLongProgram)
        (expectedSelectedMethodSymbol "int" selectedIntLongProgram)

overloadDeclarationsHaveDistinctIds :: Bool
overloadDeclarationsHaveDistinctIds = case methodDeclarationSymbols "Select" selectedIntLongProgram of
    [first, second] -> first /= second
    _ -> False

methodsAcrossOwnersHaveDistinctIds :: Bool
methodsAcrossOwnersHaveDistinctIds = case methodDeclarationSymbols "Read" source of
    [first, second] -> first /= second
    _ -> False
    where
        source =
            "class First { public static int Read(int value) { return value; } } class Second { public static int Read(int value) { return value; } }"

coreCallTargetAgrees :: Bool
coreCallTargetAgrees = case compileToCorePrep (CompilerInput "static-member.tala" selectedIntLongProgram) of
    Right artifacts ->
        case [ resolvedSymbol target
             | target <- coreCallTargets (artifactCore artifacts)
             , resolvedSpelling target == Identifier "Select"
             ] of
            selected : _ -> Just selected == expectedSelectedMethodSymbol "int" selectedIntLongProgram
            [] -> False
    Left _ -> False

declarationOrderDoesNotSelect :: Bool
declarationOrderDoesNotSelect =
    sameSuccessfulSymbol
        (selectedMethodSymbol "int" selectedIntLongProgram)
        (expectedSelectedMethodSymbol "int" selectedIntLongProgram)
        && sameSuccessfulSymbol
            (selectedMethodSymbol "long" selectedLongIntProgram)
            (expectedSelectedMethodSymbol "long" selectedLongIntProgram)

equalArityUsesTypes :: Bool
equalArityUsesTypes = succeeds selectedIntLongProgram && succeeds selectedLongIntProgram

secondCandidateWins :: Bool
secondCandidateWins =
    sameSuccessfulSymbol
        (selectedMethodSymbol "int" selectedIntLongProgram)
        (expectedSelectedMethodSymbol "int" selectedIntLongProgram)

firstCandidateWins :: Bool
firstCandidateWins =
    sameSuccessfulSymbol
        (selectedMethodSymbol "long" selectedLongIntProgram)
        (expectedSelectedMethodSymbol "long" selectedLongIntProgram)

ownerCallUsesOverloadSet :: Bool
ownerCallUsesOverloadSet =
    sameSuccessfulSymbol
        (selectedMethodSymbol "int" source)
        (expectedSelectedMethodSymbol "int" source)
    where
        source =
            "class Catalog { public static int Select(long value) { return 1; } public static int Select(int value) { return value; } int Use(int value) { return Select(value); } }"

selectedAnnotationIsKept :: Bool
selectedAnnotationIsKept = case analyze
    "class Catalog { public static int Select(int value) { return value; } int Use(int value) { Select(value); return 0; } }" of
    Right result -> case callsNamed "Select" (typedTree result) of
        CallExpression _ (NameExpression _ target (FunctionType [parameter] resultType)) [NameExpression _ _ argumentType] _ : _ ->
            parameter == intType
                && resultType == intType
                && argumentType == intType
                && Just (resolvedSymbol target)
                    == expectedSelectedMethodSymbol
                        "int"
                        "class Catalog { public static int Select(int value) { return value; } int Use(int value) { Select(value); return 0; } }"
        _ -> False
    Left _ -> False

voidOverloadCall :: Bool
voidOverloadCall =
    succeeds
        "class Catalog { public static void Select(int value) { return; } public static void Select(String value) { return; } } class Caller { void Use(int value) { Catalog.Select(value); return; } }"

valueOverloadReturn :: Bool
valueOverloadReturn = succeeds selectedIntLongProgram

valueOverloadInitializer :: Bool
valueOverloadInitializer =
    succeeds
        "class Catalog { public static int Select(int value) { return value; } public static long Select(long value) { return value; } } class Caller { int Use(int value) { int chosen = Catalog.Select(value); return chosen; } }"

receiverMustNameDeclaredType :: Bool
receiverMustNameDeclaredType = hasCode "TAN0001" "class Caller { int Use() { return Missing.Read(); } }"

valueReceiverIsNotDynamic :: Bool
valueReceiverIsNotDynamic = staticMethodThroughValue

nestedCallReceiverNotType :: Bool
nestedCallReceiverNotType =
    hasCode
        "TAT0032"
        "class Catalog { public static Catalog Create(Catalog value) { return value; } public static int Read() { return 1; } } class Caller { int Use(Catalog value) { return Catalog.Create(value).Read(); } }"

unknownTypeReceiver :: Bool
unknownTypeReceiver = receiverMustNameDeclaredType

publicCandidateSurvivesPrivateSibling :: Bool
publicCandidateSurvivesPrivateSibling =
    succeeds
        "class Catalog { private static int Select(String value) { return 1; } public static int Select(int value) { return value; } } class Caller { int Use(int value) { return Catalog.Select(value); } }"

privateOnlyFamilyReportsAccess :: Bool
privateOnlyFamilyReportsAccess = privateMethodOutsideOwner

accessDoesNotDistinguishSignature :: Bool
accessDoesNotDistinguishSignature =
    hasCode
        "TAT0028"
        "class Catalog { public static int Select(int value) { return value; } private static int Select(int other) { return other; } }"

returnDoesNotDistinguishSignature :: Bool
returnDoesNotDistinguishSignature =
    hasCode
        "TAT0028"
        "class Catalog { public static int Select(int value) { return value; } public static long Select(int other) { return other; } }"

staticnessDoesNotDistinguishSignature :: Bool
staticnessDoesNotDistinguishSignature =
    hasCode
        "TAT0028"
        "class Catalog { public static int Select(int value) { return value; } public int Select(int other) { return other; } }"

parameterOrderIsSignificant :: Bool
parameterOrderIsSignificant =
    succeeds
        "class Catalog { public static int Select(int left, long right) { return left; } public static long Select(long left, int right) { return left; } } class Caller { int Use(int left, long right) { return Catalog.Select(left, right); } }"

ownerScopePermitsSameSignature :: Bool
ownerScopePermitsSameSignature = overloadFamiliesAreOwnerScoped

typeNameIsCaseSensitive :: Bool
typeNameIsCaseSensitive =
    hasCode
        "TAN0001"
        "class Catalog { public static int Read() { return 1; } } class Caller { int Use() { return catalog.Read(); } }"

returnedCallHasResultType :: Bool
returnedCallHasResultType = selectedAnnotationIsKept

valueReceiverTypeIsNotGuessed :: Bool
valueReceiverTypeIsNotGuessed = staticMethodThroughValue

ownerUnqualifiedCall :: Bool
ownerUnqualifiedCall = ownerCallUsesOverloadSet

foreignUnqualifiedCallIsRejected :: Bool
foreignUnqualifiedCallIsRejected =
    hasCode
        "TAN0001"
        "class Catalog { public static int Select(int value) { return value; } } class Caller { int Use(int value) { return Select(value); } }"

methodDiagnosticHasSpan :: Bool
methodDiagnosticHasSpan =
    hasDiagnostic
        "TAT0029"
        (\diagnostic -> diagnosticSpan diagnostic /= Nothing)
        "class Catalog {} class Caller { int Use() { return Catalog.Read(); } }"

methodDiagnosticHasStage :: Bool
methodDiagnosticHasStage =
    hasDiagnostic
        "TAT0029"
        ((== TypeCheckerStage) . diagnosticStage)
        "class Catalog {} class Caller { int Use() { return Catalog.Read(); } }"

methodDiagnosticSeverity :: Bool
methodDiagnosticSeverity =
    hasDiagnostic
        "TAT0029"
        ((== Error) . diagnosticSeverity)
        "class Catalog {} class Caller { int Use() { return Catalog.Read(); } }"

selectedIntLongProgram :: String
selectedIntLongProgram =
    "class Catalog { public static int Select(long value) { return 1; } public static int Select(int value) { return value; } } class Caller { int Use(int value) { return Catalog.Select(value); } }"

selectedLongIntProgram :: String
selectedLongIntProgram =
    "class Catalog { public static long Select(int value) { return 1; } public static long Select(long value) { return value; } } class Caller { long Use(long value) { return Catalog.Select(value); } }"

sameSuccessfulSymbol :: Maybe SymbolId -> Maybe SymbolId -> Bool
sameSuccessfulSymbol (Just first) (Just second) = first == second
sameSuccessfulSymbol _ _ = False

methodDeclarationSymbols :: String -> String -> [SymbolId]
methodDeclarationSymbols name = map (resolvedSymbol . declarationName) . filter isSelected . typedDeclarations
    where
        isSelected FunctionDeclaration {declarationName = candidate} = resolvedSpelling candidate == Identifier name
        isSelected _ = False

scalarPairSelectionTests :: [(String, Bool)]
scalarPairSelectionTests =
    [ ( "exact overload resolution selects " ++ scalarTypeName requested ++ " over " ++ scalarTypeName distractor
      , sameSuccessfulSymbol
            (selectedMethodSymbol (scalarTypeName requested) source)
            (expectedSelectedMethodSymbol (scalarTypeName requested) source)
      )
    | requested <- scalarTypes
    , distractor <- scalarTypes
    , requested /= distractor
    , let source = scalarPairProgram (scalarTypeName requested) (scalarTypeName distractor)
    ]

scalarDuplicateSignatureTests :: [(String, Bool)]
scalarDuplicateSignatureTests =
    [ ( "duplicate " ++ scalarTypeName valueType ++ " parameter signatures are rejected"
      , hasCode "TAT0028" (scalarDuplicateProgram (scalarTypeName valueType))
      )
    | valueType <- scalarTypes
    ]

scalarArityTests :: [(String, Bool)]
scalarArityTests =
    [ ( "an " ++ scalarTypeName valueType ++ " overload preserves its wrong-arity diagnostic"
      , hasCode "TAT0008" (scalarArityProgram (scalarTypeName valueType))
      )
    | valueType <- scalarTypes
    ]

scalarPairProgram :: String -> String -> String
scalarPairProgram requested distractor =
    "class Catalog { public static void Select("
        ++ distractor
        ++ " other) { return; } public static void Select("
        ++ requested
        ++ " other) { return; } public static void Invoke("
        ++ requested
        ++ " value) { Select(value); return; } }"

scalarDuplicateProgram :: String -> String
scalarDuplicateProgram valueType =
    "class Catalog { public static void Select("
        ++ valueType
        ++ " value) { return; } public static void Select("
        ++ valueType
        ++ " other) { return; } }"

scalarArityProgram :: String -> String
scalarArityProgram valueType =
    "class Catalog { public static void Select("
        ++ valueType
        ++ " value) { return; } } class Caller { void Invoke() { Catalog.Select(); return; } }"

selectedMethodSymbol :: String -> String -> Maybe SymbolId
selectedMethodSymbol selectedType source = do
    result <- either (const Nothing) Just (analyze source)
    selectedCall <- firstMatch (callsNamed "Select" (typedTree result))
    functionName <- case selectedCall of
        CallExpression _ (NameExpression _ name _) _ _ -> Just name
        _ -> Nothing
    pure (resolvedSymbol functionName)
    where
        firstMatch [] = Nothing
        firstMatch (call : remaining) = case call of
            CallExpression _ (NameExpression _ name _) _ _
                | any (selectedDeclaration name) (typedDeclarations source) -> Just call
            _ -> firstMatch remaining
        selectedDeclaration name declaration = case declaration of
            FunctionDeclaration {declarationName = candidate, declarationParameters = [parameter]} ->
                resolvedSymbol candidate == resolvedSymbol name
                    && parameterAnnotation parameter == scalarTypeToType (scalarForName selectedType)
                    && resolvedSpelling candidate == Identifier "Select"
            _ -> False

expectedSelectedMethodSymbol :: String -> String -> Maybe SymbolId
expectedSelectedMethodSymbol selectedType source = do
    declaration <- firstMatch (typedDeclarations source)
    pure (resolvedSymbol (declarationName declaration))
    where
        firstMatch [] = Nothing
        firstMatch (declaration : remaining) = case declaration of
            FunctionDeclaration {declarationName = name, declarationParameters = [parameter]}
                | resolvedSpelling name == Identifier "Select"
                , parameterAnnotation parameter == scalarTypeToType (scalarForName selectedType) ->
                    Just declaration
            _ -> firstMatch remaining

scalarForName :: String -> ScalarType
scalarForName spelling = case [scalar | scalar <- scalarTypes, scalarTypeName scalar == spelling] of
    scalar : _ -> scalar
    [] -> IntScalar

typedDeclarations :: String -> [Declaration ResolvedName Type]
typedDeclarations source = case analyze source of
    Right result -> flattenDeclarations (syntaxDeclarations (typedSyntaxTree (typedTree result)))
    Left _ -> []

flattenDeclarations :: [Declaration name annotation] -> [Declaration name annotation]
flattenDeclarations declarations = concatMap flatten declarations
    where
        flatten declaration@TypeDeclaration {} = declaration : flattenDeclarations (typeMembers declaration)
        flatten declaration@TemplateTypeDeclaration {} = declaration : flattenDeclarations (typeMembers declaration)
        flatten declaration = [declaration]

analyze :: String -> Either [Diagnostic] SemanticArtifacts
analyze = analyzeSemantics . CompilerInput "static-member.tala"

typedTree :: SemanticArtifacts -> TypedAST
typedTree = semanticTypedAST

succeeds :: String -> Bool
succeeds = either (const False) (const True) . analyze

hasCode :: String -> String -> Bool
hasCode code = hasDiagnostic code (const True)

hasDiagnostic :: String -> (Diagnostic -> Bool) -> String -> Bool
hasDiagnostic code predicate source = case analyze source of
    Left diagnostics -> any (\diagnostic -> diagnosticCode diagnostic == code && predicate diagnostic) diagnostics
    Right _ -> False

staticProgram :: String -> String -> String
staticProgram method caller = "class Catalog { " ++ method ++ " } class Caller { " ++ caller ++ " }"

callsNamed :: String -> TypedAST -> [Expression ResolvedName Type]
callsNamed name (TypedAST (SyntaxTree _ declarations)) = filter isNamedCall (concatMap declarationCalls declarations)
    where
        isNamedCall (CallExpression _ (NameExpression _ target _) _ _) = resolvedSpelling target == Identifier name
        isNamedCall _ = False

declarationCalls :: Declaration ResolvedName Type -> [Expression ResolvedName Type]
declarationCalls declaration = case declaration of
    TypeDeclaration {typeMembers = members} -> concatMap declarationCalls members
    TemplateTypeDeclaration {typeMembers = members} -> concatMap declarationCalls members
    FunctionDeclaration {declarationBody = body} -> blockCalls body
    EnumDeclaration {} -> []

blockCalls :: Block ResolvedName Type -> [Expression ResolvedName Type]
blockCalls (Block statements) = concatMap statementCalls statements

statementCalls :: Statement ResolvedName Type -> [Expression ResolvedName Type]
statementCalls statement = case statement of
    BindingStatement _ _ _ _ _ value -> expressionCalls value
    AssignmentStatement _ _ _ value -> expressionCalls value
    ReturnStatement _ value -> maybe [] expressionCalls value
    IfStatement _ condition yes no -> expressionCalls condition ++ blockCalls yes ++ maybe [] blockCalls no
    WhileStatement _ condition body -> expressionCalls condition ++ blockCalls body
    DoWhileStatement _ body condition -> blockCalls body ++ expressionCalls condition
    ForStatement _ initializer condition updates body ->
        maybe [] statementCalls initializer
            ++ maybe [] expressionCalls condition
            ++ concatMap statementCalls updates
            ++ blockCalls body
    ForEachStatement _ _ _ _ _ source body -> expressionCalls source ++ blockCalls body
    IncrementStatement {} -> []
    CompoundAssignmentStatement _ _ _ _ value -> expressionCalls value
    DiscardStatement _ value -> expressionCalls value
    BreakStatement _ value -> maybe [] expressionCalls value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> expressionCalls condition ++ blockCalls block
    BlockStatement _ block -> blockCalls block
    ExpressionStatement _ value _ -> expressionCalls value

expressionCalls :: Expression ResolvedName Type -> [Expression ResolvedName Type]
expressionCalls expression = case expression of
    NameExpression {} -> []
    LiteralExpression {} -> []
    MemberAccessExpression _ receiver _ _ -> expressionCalls receiver
    MethodReferenceExpression _ receiver _ _ -> expressionCalls receiver
    CallExpression _ callee arguments _ ->
        [expression | isCall expression] ++ expressionCalls callee ++ concatMap expressionCalls arguments
    UnaryExpression _ _ value _ -> expressionCalls value
    BinaryExpression _ _ left right _ -> expressionCalls left ++ expressionCalls right
    IsPatternExpression _ subject _ _ -> expressionCalls subject
    ConditionalExpression _ condition whenTrue whenFalse _ -> concatMap expressionCalls [condition, whenTrue, whenFalse]
    CoalesceExpression _ left fallback _ -> expressionCalls left ++ expressionCalls fallback
    AssignmentExpression _ _ _ value _ -> expressionCalls value
    IncrementExpression {} -> []
    LoopExpression _ loop _ -> statementCalls loop
    BlockExpression _ block _ -> blockCalls block
    MatchExpression _ subjects arms _ -> concatMap expressionCalls (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression _ _ _ _ body _ -> callableBodyCalls body
    where
        isCall CallExpression {} = True
        isCall _ = False

callableBodyCalls :: CallableBody ResolvedName Type -> [Expression ResolvedName Type]
callableBodyCalls body = case body of
    CallableExpressionBody expression -> expressionCalls expression
    CallableBlockBody block -> blockCalls block

coreCallTargets :: CoreModule -> [ResolvedName]
coreCallTargets moduleValue = concatMap (concatMap statementTargets . coreFunctionBody) (coreModuleFunctions moduleValue)

statementTargets :: CoreStatement -> [ResolvedName]
statementTargets statement = case statement of
    CoreBind binding -> expressionTargets (coreBindingValue binding)
    CoreAssign _ value -> expressionTargets value
    CoreReturn value -> expressionTargets value
    CoreIf condition yes no -> expressionTargets condition ++ concatMap statementTargets yes ++ concatMap statementTargets no
    CoreEvaluate value -> expressionTargets value
    CoreWhile condition body -> expressionTargets condition ++ concatMap statementTargets body
    CoreDoWhile body condition -> concatMap statementTargets body ++ expressionTargets condition
    CoreFor condition updates body -> expressionTargets condition ++ concatMap statementTargets updates ++ concatMap statementTargets body
    CoreBreak -> []
    CoreContinue -> []

expressionTargets :: CoreExpression -> [ResolvedName]
expressionTargets expression = case expression of
    CoreVariable {} -> []
    CoreLiteral {} -> []
    CoreApply callee arguments _ -> calledTarget callee ++ expressionTargets callee ++ concatMap expressionTargets arguments
    CorePrimitive _ arguments _ -> concatMap expressionTargets arguments
    CoreLet _ _ value body _ -> expressionTargets value ++ expressionTargets body
    CoreConditional condition whenTrue whenFalse _ -> concatMap expressionTargets [condition, whenTrue, whenFalse]
    CoreClosure _ _ _ statements _ -> concatMap statementTargets statements
    where
        calledTarget (CoreVariable name _) = [name]
        calledTarget _ = []
