-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Arity and ordered parameter-vector tests for static member overloads.

The scalar cross-product is deliberately resolved through the real frontend,
not a test-only ranking function. Every selected target is checked against
the typed declaration that owns its SymbolId. This catches a category of bug
that a successful parse or a return-type-only assertion would miss.
-}
module StaticMemberOverloadTests (staticMemberOverloadTests) where

import Data.List (find)
import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend

staticMemberOverloadTests :: [(String, Bool)]
staticMemberOverloadTests =
    [ ("a two-parameter call selects by its ordered type vector", orderedPairSelection)
    , ("reversing overload declaration order does not change the selected vector", reversedPairOrderSelection)
    , ("an overload may differ at the first parameter position", firstPositionSelection)
    , ("an overload may differ at the second parameter position", secondPositionSelection)
    , ("a three-parameter call checks all positions", threePositionSelection)
    , ("a mismatch in each parameter position is rejected", everyPositionMismatchRejected)
    , ("two-parameter duplicate signatures are rejected", duplicateTwoParameterSignature)
    , ("wrong arity is diagnosed when no overload has the supplied count", wrongArityAmongOverloads)
    , ("matching arity with a wrong ordered type vector reports type mismatch", wrongVectorReportsTypeMismatch)
    , ("the selected return type comes from the matching declaration", selectedResultTypeIsPreserved)
    , ("multi-argument resolution preserves method identity in the typed tree", selectedMethodIdentityIsStable)
    ]
        ++ pairSelectionMatrix
        ++ triplePositionMatrix
        ++ scalarPositionMismatchMatrix

orderedPairSelection :: Bool
orderedPairSelection =
    selectedParameterTypes (pairProgram IntScalar LongScalar False)
        == Just [scalarTypeToType IntScalar, scalarTypeToType LongScalar]

reversedPairOrderSelection :: Bool
reversedPairOrderSelection =
    selectedParameterTypes (pairProgram IntScalar LongScalar True)
        == Just [scalarTypeToType IntScalar, scalarTypeToType LongScalar]

firstPositionSelection :: Bool
firstPositionSelection =
    selectedParameterTypes (pairProgram BooleanScalar IntScalar False) == Just [boolType, intType]

secondPositionSelection :: Bool
secondPositionSelection =
    selectedParameterTypes (pairProgram IntScalar BooleanScalar False) == Just [intType, boolType]

threePositionSelection :: Bool
threePositionSelection =
    selectedParameterTypes (threeParameterProgram [ByteScalar, IntScalar, DoubleScalar])
        == Just (map scalarTypeToType [ByteScalar, IntScalar, DoubleScalar])

everyPositionMismatchRejected :: Bool
everyPositionMismatchRejected =
    and
        [ hasDiagnostic "TAT0009" (threeParameterMismatchProgram position)
        | position <- [0 .. 2]
        ]

duplicateTwoParameterSignature :: Bool
duplicateTwoParameterSignature =
    hasDiagnostic
        "TAT0028"
        "class Catalog { public static int Select(int first, long second) { return 1; } public static long Select(int left, long right) { return 2; } }"

wrongArityAmongOverloads :: Bool
wrongArityAmongOverloads =
    hasDiagnostic
        "TAT0008"
        "class Catalog { public static int Select(int value) { return value; } public static int Select(int first, int second) { return first; } } class Caller { int Invoke(int value) { return Catalog.Select(value, value, value); } }"

wrongVectorReportsTypeMismatch :: Bool
wrongVectorReportsTypeMismatch =
    hasDiagnostic
        "TAT0009"
        "class Catalog { public static int Select(int first, long second) { return first; } public static int Select(long first, int second) { return second; } } class Caller { int Invoke(long first, long second) { return Catalog.Select(first, second); } }"

selectedResultTypeIsPreserved :: Bool
selectedResultTypeIsPreserved =
    case selectedFunctionType resultTypeProgram of
        Just (FunctionType [first, second] result) ->
            first == scalarTypeToType IntScalar
                && second == scalarTypeToType LongScalar
                && result == stringType
        _ -> False

selectedMethodIdentityIsStable :: Bool
selectedMethodIdentityIsStable =
    case selectedDeclaration (pairProgram LongScalar IntScalar False) of
        Just (target, parametersValue) ->
            resolvedSpelling target == Identifier "Select"
                && map parameterAnnotation parametersValue == map scalarTypeToType [LongScalar, IntScalar]
                && resolvedSymbol target /= SymbolId 0
        Nothing -> False

pairSelectionMatrix :: [(String, Bool)]
pairSelectionMatrix =
    [ ( "two-parameter vector " ++ vectorName [first, second] ++ " wins in " ++ orderName reversed
      , selectedParameterTypes (pairProgram first second reversed)
            == Just (map scalarTypeToType [first, second])
      )
    | first <- scalarTypes
    , second <- scalarTypes
    , first /= second
    , reversed <- [False, True]
    ]

triplePositionMatrix :: [(String, Bool)]
triplePositionMatrix =
    [ ( "three-parameter vector " ++ vectorName expected ++ " wins against a mismatch at position " ++ show position
      , selectedParameterTypes (threeOverloadProgram expected distractor)
            == Just (map scalarTypeToType expected)
      )
    | selected <- scalarTypes
    , selected /= IntScalar
    , position <- [0 .. 2]
    , let expected = replaceAt position selected [IntScalar, IntScalar, IntScalar]
    , let otherPosition = (position + 1) `mod` 3
    , let distractor = replaceAt otherPosition selected expected
    ]

scalarPositionMismatchMatrix :: [(String, Bool)]
scalarPositionMismatchMatrix =
    [ ( "three-parameter candidate rejects "
            ++ scalarTypeName target
            ++ " versus "
            ++ scalarTypeName actual
            ++ " at position "
            ++ show position
      , hasDiagnostic "TAT0009" (typedThreeParameterProgram target actual position)
      )
    | target <- scalarTypes
    , let actual = nextScalar target
    , position <- [0 .. 2]
    ]

pairProgram :: ScalarType -> ScalarType -> Bool -> String
pairProgram first second reverseDeclarations =
    "class Catalog { "
        ++ method (if reverseDeclarations then second else first) (if reverseDeclarations then first else second) "first" "second"
        ++ method (if reverseDeclarations then first else second) (if reverseDeclarations then second else first) "left" "right"
        ++ " } class Caller { "
        ++ "int Invoke("
        ++ scalarTypeName first
        ++ " first, "
        ++ scalarTypeName second
        ++ " second) { return Catalog.Select(first, second); } }"

threeParameterProgram :: [ScalarType] -> String
threeParameterProgram signature =
    "class Catalog { public static int Select("
        ++ parameters signature ["first", "second", "third"]
        ++ ") { return 1; } } class Caller { int Invoke("
        ++ parameters signature ["first", "second", "third"]
        ++ ") { return Catalog.Select(first, second, third); } }"

threeOverloadProgram :: [ScalarType] -> [ScalarType] -> String
threeOverloadProgram selected distractor =
    "class Catalog { public static int Select("
        ++ parameters selected ["first", "second", "third"]
        ++ ") { return 1; } public static int Select("
        ++ parameters distractor ["left", "middle", "right"]
        ++ ") { return 2; } } class Caller { int Invoke("
        ++ parameters selected ["first", "second", "third"]
        ++ ") { return Catalog.Select(first, second, third); } }"

typedThreeParameterProgram :: ScalarType -> ScalarType -> Int -> String
typedThreeParameterProgram target actual changedPosition =
    let expected = [IntScalar, IntScalar, IntScalar]
        candidate = replaceAt changedPosition target expected
        callerTypes = replaceAt changedPosition actual candidate
     in "class Catalog { public static int Select("
            ++ parameters candidate ["first", "second", "third"]
            ++ ") { return 1; } } class Caller { int Invoke("
            ++ parameters callerTypes ["first", "second", "third"]
            ++ ") { return Catalog.Select(first, second, third); } }"

threeParameterMismatchProgram :: Int -> String
threeParameterMismatchProgram position = typedThreeParameterProgram IntScalar LongScalar position

resultTypeProgram :: String
resultTypeProgram =
    "class Catalog { public static String Select(int first, long second) { return \"selected\"; } public static String Select(long first, int second) { return \"other\"; } } class Caller { String Invoke(int first, long second) { return Catalog.Select(first, second); } }"

method :: ScalarType -> ScalarType -> String -> String -> String
method first second firstName secondName =
    "public static int Select("
        ++ scalarTypeName first
        ++ " "
        ++ firstName
        ++ ", "
        ++ scalarTypeName second
        ++ " "
        ++ secondName
        ++ ") { return 1; } "

parameters :: [ScalarType] -> [String] -> String
parameters types names =
    joinComma [scalarTypeName valueType ++ " " ++ name | (valueType, name) <- zip types names]

joinComma :: [String] -> String
joinComma [] = ""
joinComma [value] = value
joinComma (value : remaining) = value ++ ", " ++ joinComma remaining

replaceAt :: Int -> value -> [value] -> [value]
replaceAt position replacement values =
    [if index == position then replacement else value | (index, value) <- zip [0 ..] values]

nextScalar :: ScalarType -> ScalarType
nextScalar value = case dropWhile (/= value) scalarTypes of
    _ : following : _ -> following
    _ -> case scalarTypes of
        first : _ -> first
        [] -> value

vectorName :: [ScalarType] -> String
vectorName = joinComma . map scalarTypeName

orderName :: Bool -> String
orderName False = "forward declaration order"
orderName True = "reverse declaration order"

selectedParameterTypes :: String -> Maybe [Type]
selectedParameterTypes source = do
    (_, parametersValue) <- selectedDeclaration source
    pure (map parameterAnnotation parametersValue)

selectedFunctionType :: String -> Maybe Type
selectedFunctionType source = do
    (target, _) <- selectedDeclaration source
    result <- either (const Nothing) Just (analyze source)
    call <- findCall (semanticTypedAST result)
    case call of
        CallExpression _ (NameExpression _ name functionType) _ _
            | resolvedSymbol name == resolvedSymbol target -> Just functionType
        _ -> Nothing

selectedDeclaration :: String -> Maybe (ResolvedName, [Parameter ResolvedName Type])
selectedDeclaration source = do
    result <- either (const Nothing) Just (analyze source)
    call <- findCall (semanticTypedAST result)
    target <- case call of
        CallExpression _ (NameExpression _ name _) _ _ -> Just name
        _ -> Nothing
    declaration <- find (sameIdentity target) (methodDeclarations (semanticTypedAST result))
    case declaration of
        FunctionDeclaration {declarationName = name, declarationParameters = parametersValue} -> Just (name, parametersValue)
        _ -> Nothing
    where
        sameIdentity target FunctionDeclaration {declarationName = candidate} = resolvedSymbol target == resolvedSymbol candidate
        sameIdentity _ _ = False

methodDeclarations :: TypedAST -> [Declaration ResolvedName Type]
methodDeclarations (TypedAST (SyntaxTree _ declarations)) = concatMap membersOf declarations
    where
        membersOf declaration@TypeDeclaration {} = declaration : concatMap membersOf (typeMembers declaration)
        membersOf declaration@TemplateTypeDeclaration {} = declaration : concatMap membersOf (typeMembers declaration)
        membersOf declaration@FunctionDeclaration {} = [declaration]
        membersOf EnumDeclaration {} = []

findCall :: TypedAST -> Maybe (Expression ResolvedName Type)
findCall (TypedAST (SyntaxTree _ declarations)) = find isSelected (concatMap callsInDeclaration declarations)
    where
        isSelected (CallExpression _ (NameExpression _ name _) _ _) = resolvedSpelling name == Identifier "Select"
        isSelected _ = False

callsInDeclaration :: Declaration ResolvedName Type -> [Expression ResolvedName Type]
callsInDeclaration declaration = case declaration of
    TypeDeclaration {typeMembers = members} -> concatMap callsInDeclaration members
    TemplateTypeDeclaration {typeMembers = members} -> concatMap callsInDeclaration members
    FunctionDeclaration {declarationBody = body} -> callsInBlock body
    EnumDeclaration {} -> []

callsInBlock :: Block ResolvedName Type -> [Expression ResolvedName Type]
callsInBlock (Block statements) = concatMap callsInStatement statements

callsInStatement :: Statement ResolvedName Type -> [Expression ResolvedName Type]
callsInStatement statement = case statement of
    BindingStatement _ _ _ _ _ value -> callsInExpression value
    AssignmentStatement _ _ _ value -> callsInExpression value
    ReturnStatement _ value -> maybe [] callsInExpression value
    IfStatement _ condition yes no -> callsInExpression condition ++ callsInBlock yes ++ maybe [] callsInBlock no
    WhileStatement _ condition body -> callsInExpression condition ++ callsInBlock body
    DoWhileStatement _ body condition -> callsInBlock body ++ callsInExpression condition
    ForStatement _ initializer condition updates body ->
        maybe [] callsInStatement initializer
            ++ maybe [] callsInExpression condition
            ++ concatMap callsInStatement updates
            ++ callsInBlock body
    ForEachStatement _ _ _ _ _ source body -> callsInExpression source ++ callsInBlock body
    IncrementStatement {} -> []
    CompoundAssignmentStatement _ _ _ _ value -> callsInExpression value
    DiscardStatement _ value -> callsInExpression value
    BreakStatement _ value -> maybe [] callsInExpression value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> callsInExpression condition ++ callsInBlock block
    BlockStatement _ block -> callsInBlock block
    ExpressionStatement _ value _ -> callsInExpression value

callsInExpression :: Expression ResolvedName Type -> [Expression ResolvedName Type]
callsInExpression expression = case expression of
    NameExpression {} -> []
    LiteralExpression {} -> []
    MemberAccessExpression _ receiver _ _ -> callsInExpression receiver
    MethodReferenceExpression _ receiver _ _ -> callsInExpression receiver
    CallExpression _ callee arguments _ ->
        [expression | isSelectedCall expression]
            ++ callsInExpression callee
            ++ concatMap callsInExpression arguments
    UnaryExpression _ _ value _ -> callsInExpression value
    BinaryExpression _ _ left right _ -> callsInExpression left ++ callsInExpression right
    IsPatternExpression _ subject _ _ -> callsInExpression subject
    ConditionalExpression _ condition whenTrue whenFalse _ -> concatMap callsInExpression [condition, whenTrue, whenFalse]
    CoalesceExpression _ left fallback _ -> callsInExpression left ++ callsInExpression fallback
    AssignmentExpression _ _ _ value _ -> callsInExpression value
    IncrementExpression {} -> []
    LoopExpression _ loop _ -> callsInStatement loop
    BlockExpression _ block _ -> callsInBlock block
    MatchExpression _ subjects arms _ -> concatMap callsInExpression (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression _ _ _ _ body _ -> callsInCallableBody body
    where
        isSelectedCall (CallExpression _ (NameExpression _ name _) _ _) = resolvedSpelling name == Identifier "Select"
        isSelectedCall _ = False

callsInCallableBody :: CallableBody ResolvedName Type -> [Expression ResolvedName Type]
callsInCallableBody body = case body of
    CallableExpressionBody expression -> callsInExpression expression
    CallableBlockBody block -> callsInBlock block

analyze :: String -> Either [Diagnostic] SemanticArtifacts
analyze = analyzeSemantics . CompilerInput "static-member-overloads.tala"

hasDiagnostic :: String -> String -> Bool
hasDiagnostic code source = case analyze source of
    Left diagnostics -> any ((== code) . diagnosticCode) diagnostics
    Right _ -> False
