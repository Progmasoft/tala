-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | End-to-end tests for callable literals and closure conversion.

These tests intentionally inspect every compiler boundary.  A parser-only
assertion would miss capture identity bugs, while a CorePrep-only assertion
would make source regressions unnecessarily hard to diagnose.
-}
module ClosureTests (closureTests) where

import Data.List (find, isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.CorePrep.Wire
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser

closureTests :: [(String, Bool)]
closureTests =
    [ ("lexer recognizes callable and capture delimiters", lexerRecognizesDelimiters)
    , ("typed callable parameters preserve their declared types", typedParameters)
    , ("parenthesized inferred callable parameters are accepted", parenthesizedInferredParameters)
    , ("bare inferred callable parameters are accepted", bareInferredParameters)
    , ("parenthesized zero-parameter callable is accepted", parenthesizedZeroParameters)
    , ("bare zero-parameter callable is accepted", bareZeroParameters)
    , ("callable expression body is retained", expressionBody)
    , ("callable block body is retained", blockBody)
    , ("empty explicit capture list is distinct from implicit capture", emptyExplicitCaptureList)
    , ("normal explicit capture is parsed", normalCapture)
    , ("weak explicit capture is parsed", weakCapture)
    , ("unowned explicit capture is parsed", unownedCapture)
    , ("capture aliases retain their initializer", captureAlias)
    , ("capture source order remains stable", captureOrder)
    , ("duplicate explicit capture is diagnosed", duplicateCapture)
    , ("an omitted explicit capture is rejected", omittedExplicitCapture)
    , ("callable parameters receive private symbols", privateParameterSymbols)
    , ("captured bindings receive private symbols", privateCaptureSymbols)
    , ("typed callable expression produces a function type", callableType)
    , ("callable invocation checks argument count", callableArity)
    , ("callable invocation checks argument types", callableArgumentType)
    , ("weak primitive capture is rejected", weakPrimitiveCapture)
    , ("weak capture rejects every canonical scalar family", weakScalarCaptures)
    , ("unowned primitive capture is rejected", unownedPrimitiveCapture)
    , ("weak String capture is accepted", weakStringCapture)
    , ("weak callable capture is accepted", weakCallableCapture)
    , ("implicit capture is discovered during Core lowering", implicitCaptureDiscovery)
    , ("explicit capture lowers its initializer", explicitCaptureLowering)
    , ("capture alias evaluates outside the callable body", aliasLowering)
    , ("closure conversion lifts a CorePrep function", liftedFunction)
    , ("closure creation records a CorePrep operation", makeClosureOperation)
    , ("lifted closure receives hidden capture parameters first", hiddenCaptureParameters)
    , ("closure result remains callable after CorePrep", closureResultType)
    , ("nested callable conversion reaches a fixed point", nestedClosureConversion)
    , ("Core verifier accepts a well-formed closure", coreVerifierAcceptsClosure)
    , ("Core verifier rejects mismatched closure type", coreVerifierRejectsTypeMismatch)
    , ("Core verifier rejects capture initializer mismatch", coreVerifierRejectsCaptureMismatch)
    , ("Core wire v10 round-trips closure values and ownership", coreWireClosureRoundTrip)
    , ("CorePrep wire v7 round-trips closure creation and ownership", corePrepWireClosureRoundTrip)
    , ("CorePrep verifier accepts converted closure", corePrepVerifierAcceptsClosure)
    , ("CorePrep verifier rejects primitive weak capture", corePrepVerifierRejectsWeakPrimitive)
    ]

lexerRecognizesDelimiters :: Bool
lexerRecognizesDelimiters = case lexText "[weak owner] \\(int value) -> value" of
    Right tokens -> all (`elem` map tokenText tokens) ["[", "]", "\\", "(", ")", "->"]
    Left _ -> False

typedParameters :: Bool
typedParameters = case parsedCallable "\\(int left, int right) -> left + right" of
    Just (CallableExpression _ False [] parameters _ _) ->
        map parameterTypeSyntax parameters
            == [ExplicitType (Identifier "int"), ExplicitType (Identifier "int")]
    _ -> False

parenthesizedInferredParameters :: Bool
parenthesizedInferredParameters = case parsedCallable "\\(left, right) -> left" of
    Just (CallableExpression _ False [] parameters _ _) ->
        map parameterTypeSyntax parameters == [AutoType, AutoType]
    _ -> False

bareInferredParameters :: Bool
bareInferredParameters = case parsedCallable "\\left, right -> right" of
    Just (CallableExpression _ False [] parameters _ _) ->
        map (identifierText . parameterName) parameters == ["left", "right"]
    _ -> False

parenthesizedZeroParameters :: Bool
parenthesizedZeroParameters = callableParameterCount "\\() -> 42" == Just 0

bareZeroParameters :: Bool
bareZeroParameters = callableParameterCount "\\ -> 42" == Just 0

expressionBody :: Bool
expressionBody = case parsedCallable "\\(int value) -> value + 1" of
    Just CallableExpression {} -> case callableBodyOf (parsedCallable "\\(int value) -> value + 1") of
        Just CallableExpressionBody {} -> True
        _ -> False
    _ -> False

blockBody :: Bool
blockBody = case callableBodyOf (parsedCallable "\\(int value) -> { int next = value + 1; next }") of
    Just (CallableBlockBody (Block statements)) -> length statements == 2
    _ -> False

emptyExplicitCaptureList :: Bool
emptyExplicitCaptureList = case parsedCallable "[] \\ -> 42" of
    Just (CallableExpression _ explicit captures _ _ _) -> explicit && null captures
    _ -> False

normalCapture :: Bool
normalCapture = captureModes "[value] \\ -> value" == Just [StrongCapture]

weakCapture :: Bool
weakCapture = captureModes "[weak owner] \\ -> owner" == Just [WeakCapture]

unownedCapture :: Bool
unownedCapture = captureModes "[unowned owner] \\ -> owner" == Just [UnownedCapture]

captureAlias :: Bool
captureAlias = case parsedCallable "[answer = seed + 1] \\ -> answer" of
    Just (CallableExpression _ True [Capture _ StrongCapture (Identifier "answer") _ (Just BinaryExpression {})] _ _ _) -> True
    _ -> False

captureOrder :: Bool
captureOrder = case parsedCallable "[first = one, second = two, third = three] \\ -> first" of
    Just (CallableExpression _ True captures _ _ _) ->
        map (identifierText . captureName) captures == ["first", "second", "third"]
    _ -> False

duplicateCapture :: Bool
duplicateCapture = hasDiagnostic "TAR0005" (compileSource "int seed = 1; auto f = [seed, seed] \\ -> seed;")

omittedExplicitCapture :: Bool
omittedExplicitCapture =
    hasDiagnostic "TAN0001" (compileSource "int first = 1; int second = 2; auto f = [first] \\ -> first + second;")

privateParameterSymbols :: Bool
privateParameterSymbols = case resolvedCallable "auto f = \\(int value) -> value;" of
    Just (CallableExpression _ _ _ [parameter] body _) ->
        resolvedSymbol (parameterName parameter) `elem` expressionSymbols body
    _ -> False

privateCaptureSymbols :: Bool
privateCaptureSymbols = case resolvedCallable "int seed = 1; auto f = [seed] \\ -> seed;" of
    Just (CallableExpression _ True [capture] _ body _) ->
        resolvedSymbol (captureName capture) `elem` expressionSymbols body
    _ -> False

callableType :: Bool
callableType = case typedCallable "auto f = \\(int value) -> value + 1;" of
    Just (CallableExpression _ _ _ _ _ (FunctionType [parameter] result)) ->
        parameter == intType && result == intType
    _ -> False

callableArity :: Bool
callableArity = hasDiagnostic "TAT0008" (compileSource "auto f = \\(int value) -> value; int result = f(1, 2);")

callableArgumentType :: Bool
callableArgumentType = hasDiagnostic "TAT0009" (compileSource "auto f = \\(int value) -> value; int result = f(true);")

weakPrimitiveCapture :: Bool
weakPrimitiveCapture = hasDiagnostic "TAT0014" (compileSource "int value = 1; auto f = [weak value] \\ -> value;")

weakScalarCaptures :: Bool
weakScalarCaptures = all rejectsWeak scalarTypes
    where
        rejectsWeak scalar = hasDiagnostic "TAT0014" (compileSource (scalarSource scalar))
        scalarSource scalar =
            scalarTypeName scalar
                ++ " value = "
                ++ scalarInitializer scalar
                ++ "; auto f = [weak value] \\ -> value;"
        scalarInitializer CharacterScalar = "'A'"
        scalarInitializer BooleanScalar = "true"
        scalarInitializer scalar
            | scalarTypeFamily scalar == FloatingFamily = "1.0"
            | otherwise = "1"

unownedPrimitiveCapture :: Bool
unownedPrimitiveCapture = hasDiagnostic "TAT0015" (compileSource "int value = 1; auto f = [unowned value] \\ -> value;")

weakStringCapture :: Bool
weakStringCapture =
    not (hasDiagnostic "TAT0014" (compileSource "String value = \"Wolf\"; auto f = [weak value] \\ -> value;"))

weakCallableCapture :: Bool
weakCallableCapture =
    not (hasDiagnostic "TAT0014" (compileSource "auto first = \\ -> 1; auto second = [weak first] \\ -> first;"))

implicitCaptureDiscovery :: Bool
implicitCaptureDiscovery = case coreClosure "int seed = 1; auto f = \\ -> seed;" of
    Just (CoreClosure captures [] _ _ _) -> map (identifierText . resolvedSpelling . coreCaptureName) captures == ["seed"]
    _ -> False

explicitCaptureLowering :: Bool
explicitCaptureLowering = case coreClosure "int seed = 1; auto f = [seed] \\ -> seed;" of
    Just (CoreClosure [capture] [] _ _ _) ->
        coreCaptureMode capture == StrongCapture && expressionType (coreCaptureValue capture) == intType
    _ -> False

aliasLowering :: Bool
aliasLowering = case coreClosure "int seed = 1; auto f = [answer = seed + 1] \\ -> answer;" of
    Just (CoreClosure [capture] [] _ _ _) -> case coreCaptureValue capture of
        CorePrimitive CoreAdd [CoreVariable _ _, CoreLiteral (CoreInteger 1) _] _ -> True
        _ -> False
    _ -> False

liftedFunction :: Bool
liftedFunction = case compiled "int seed = 1; auto f = \\ -> seed;" of
    Right artifacts -> length (corePrepModuleFunctions (artifactCorePrep artifacts)) == 2
    Left _ -> False

makeClosureOperation :: Bool
makeClosureOperation = case preparedClosure "int seed = 1; auto f = \\ -> seed;" of
    Just (CorePrepMakeClosure _ [_]) -> True
    _ -> False

hiddenCaptureParameters :: Bool
hiddenCaptureParameters = case compiled "int seed = 1; auto f = \\(int value) -> seed + value;" of
    Right artifacts -> case drop 1 (corePrepModuleFunctions (artifactCorePrep artifacts)) of
        [function] -> map (identifierText . resolvedSpelling . fst) (corePrepFunctionParameters function) == ["seed", "value"]
        _ -> False
    Left _ -> False

closureResultType :: Bool
closureResultType = case preparedBinding "auto f = \\(int value) -> value; f(1);" of
    Just (CorePrepBind _ valueType _ CorePrepMakeClosure {}) ->
        valueType == FunctionType [intType] intType
    _ -> False

nestedClosureConversion :: Bool
nestedClosureConversion = case compiled "int seed = 1; auto outer = \\ -> \\ -> seed;" of
    Right artifacts -> length (corePrepModuleFunctions (artifactCorePrep artifacts)) == 3
    Left _ -> False

coreVerifierAcceptsClosure :: Bool
coreVerifierAcceptsClosure = case compiled "int seed = 1; auto f = \\ -> seed;" of
    Right artifacts -> verifyCore (artifactOptimizedCore artifacts) == Right (artifactOptimizedCore artifacts)
    Left _ -> False

coreVerifierRejectsTypeMismatch :: Bool
coreVerifierRejectsTypeMismatch = isLeftDiagnostics (verifyCore invalidClosureType)

coreVerifierRejectsCaptureMismatch :: Bool
coreVerifierRejectsCaptureMismatch = isLeftDiagnostics (verifyCore invalidCaptureType)

coreWireClosureRoundTrip :: Bool
coreWireClosureRoundTrip = case compiled "int seed = 1; auto f = \\ -> seed;" of
    Right artifacts ->
        let value = artifactOptimizedCore artifacts
         in (encodeCore defaultCoreWireLimits value >>= decodeCore defaultCoreWireLimits) == Right value
    Left _ -> False

corePrepWireClosureRoundTrip :: Bool
corePrepWireClosureRoundTrip = case compiled "int seed = 1; auto f = \\ -> seed;" of
    Right artifacts ->
        let value = artifactCorePrep artifacts
         in (encodeCorePrep value >>= decodeCorePrep) == Right value
    Left _ -> False

corePrepVerifierAcceptsClosure :: Bool
corePrepVerifierAcceptsClosure = case compiled "int seed = 1; auto f = \\ -> seed;" of
    Right artifacts -> verifyCorePrep (artifactCorePrep artifacts) == Right (artifactCorePrep artifacts)
    Left _ -> False

corePrepVerifierRejectsWeakPrimitive :: Bool
corePrepVerifierRejectsWeakPrimitive = isLeftDiagnostics (verifyCorePrep invalidPreparedWeakCapture)

-- Test source is wrapped in the smallest valid declaration context.  Statements
-- are injected before a final unit-producing return so callable values may be
-- exercised without conflating closure behavior with entry-point validation.
compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource = compiled

compiled :: String -> Either [Diagnostic] FrontendArtifacts
compiled statements =
    compileToCorePrep
        ( CompilerInput
            "closure-test.tala"
            ( unlines
                [ "namespace ClosureTests;"
                , "class Program {"
                , "  public static void Main() {"
                , statements
                , "    return;"
                , "  }"
                , "}"
                ]
            )
        )

parseOnly :: String -> Either [Diagnostic] ParsedAST
parseOnly statements = do
    tokens <- lexText (source statements)
    runParser defaultParser (ParserInput "closure-test.tala" tokens)

lexText :: String -> Either [Diagnostic] [Token]
lexText = runLexer defaultLexer . LexerInput "closure-test.tala"

source :: String -> String
source statements =
    unlines
        [ "namespace ClosureTests;"
        , "class Program {"
        , "  public static void Main() {"
        , "    auto callable = " ++ statements ++ ";"
        , "    return;"
        , "  }"
        , "}"
        ]

parsedCallable :: String -> Maybe (Expression Identifier ())
parsedCallable value = either (const Nothing) findParsedCallable (parseOnly value)

findParsedCallable :: ParsedAST -> Maybe (Expression Identifier ())
findParsedCallable (ParsedAST tree) = firstCallableInTree tree

firstCallableInTree :: SyntaxTree name annotation -> Maybe (Expression name annotation)
firstCallableInTree tree = firstJust (map declarationCallable (syntaxDeclarations tree))

declarationCallable :: Declaration name annotation -> Maybe (Expression name annotation)
declarationCallable declaration = case declaration of
    TypeDeclaration {typeMembers = members} -> firstJust (map declarationCallable members)
    TemplateTypeDeclaration {typeMembers = members} -> firstJust (map declarationCallable members)
    FunctionDeclaration {declarationBody = body} -> blockCallable body
    EnumDeclaration {} -> Nothing

blockCallable :: Block name annotation -> Maybe (Expression name annotation)
blockCallable (Block statements) = firstJust (map statementCallable statements)

statementCallable :: Statement name annotation -> Maybe (Expression name annotation)
statementCallable statement = case statement of
    BindingStatement _ _ _ _ _ value -> expressionCallable value
    AssignmentStatement _ _ _ value -> expressionCallable value
    ReturnStatement _ value -> value >>= expressionCallable
    IfStatement _ condition yes no ->
        expressionCallable condition `orElse` blockCallable yes `orElse` (no >>= blockCallable)
    WhileStatement _ condition body -> expressionCallable condition `orElse` blockCallable body
    DoWhileStatement _ body condition -> blockCallable body `orElse` expressionCallable condition
    ForStatement _ initializer condition updates body ->
        (initializer >>= statementCallable)
            `orElse` (condition >>= expressionCallable)
            `orElse` blockCallable body
            `orElse` firstJust (map statementCallable updates)
    ForEachStatement _ _ _ _ _ collection body -> expressionCallable collection `orElse` blockCallable body
    IncrementStatement {} -> Nothing
    CompoundAssignmentStatement _ _ _ _ value -> expressionCallable value
    DiscardStatement _ value -> expressionCallable value
    BreakStatement _ value -> value >>= expressionCallable
    ContinueStatement {} -> Nothing
    GuardStatement _ condition block -> expressionCallable condition `orElse` blockCallable block
    BlockStatement _ block -> blockCallable block
    ExpressionStatement _ value _ -> expressionCallable value

expressionCallable :: Expression name annotation -> Maybe (Expression name annotation)
expressionCallable expression@CallableExpression {} = Just expression
expressionCallable expression = case expression of
    CallExpression _ callee arguments _ -> expressionCallable callee `orElse` firstJust (map expressionCallable arguments)
    UnaryExpression _ _ value _ -> expressionCallable value
    BinaryExpression _ _ left right _ -> expressionCallable left `orElse` expressionCallable right
    _ -> Nothing

callableParameterCount :: String -> Maybe Int
callableParameterCount value = case parsedCallable value of
    Just (CallableExpression _ _ _ parameters _ _) -> Just (length parameters)
    _ -> Nothing

callableBodyOf :: Maybe (Expression name annotation) -> Maybe (CallableBody name annotation)
callableBodyOf (Just (CallableExpression _ _ _ _ body _)) = Just body
callableBodyOf _ = Nothing

captureModes :: String -> Maybe [CaptureMode]
captureModes value = case parsedCallable value of
    Just (CallableExpression _ _ captures _ _ _) -> Just (map captureMode captures)
    _ -> Nothing

resolvedCallable :: String -> Maybe (Expression ResolvedName ())
resolvedCallable statements = case compiledFrontend statements of
    Left _ -> Nothing
    Right artifacts -> firstCallableInTree (resolvedSyntaxTree (artifactResolvedAST artifacts))

typedCallable :: String -> Maybe (Expression ResolvedName Type)
typedCallable statements = case compiledFrontend statements of
    Left _ -> Nothing
    Right artifacts -> firstCallableInTree (typedSyntaxTree (artifactTypedAST artifacts))

compiledFrontend :: String -> Either [Diagnostic] FrontendArtifacts
compiledFrontend = compiled

expressionSymbols :: CallableBody ResolvedName annotation -> [SymbolId]
expressionSymbols body = case body of
    CallableExpressionBody expression -> symbols expression
    CallableBlockBody block -> blockSymbols block

symbols :: Expression ResolvedName annotation -> [SymbolId]
symbols expression = case expression of
    NameExpression _ name _ -> [resolvedSymbol name]
    LiteralExpression {} -> []
    MemberAccessExpression _ receiver _ _ -> symbols receiver
    MethodReferenceExpression _ receiver _ _ -> symbols receiver
    CallExpression _ callee arguments _ -> symbols callee ++ concatMap symbols arguments
    UnaryExpression _ _ value _ -> symbols value
    BinaryExpression _ _ left right _ -> symbols left ++ symbols right
    IsPatternExpression _ value _ _ -> symbols value
    ConditionalExpression _ condition whenTrue whenFalse _ -> concatMap symbols [condition, whenTrue, whenFalse]
    CoalesceExpression _ left fallback _ -> symbols left ++ symbols fallback
    AssignmentExpression _ _ name value _ -> resolvedSymbol name : symbols value
    IncrementExpression _ _ name _ -> [resolvedSymbol name]
    LoopExpression {} -> []
    BlockExpression _ block _ -> blockSymbols block
    MatchExpression _ subjects arms _ -> concatMap symbols (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression _ _ captures parameters body _ ->
        map (resolvedSymbol . captureName) captures
            ++ map (resolvedSymbol . parameterName) parameters
            ++ expressionSymbols body

blockSymbols :: Block ResolvedName annotation -> [SymbolId]
blockSymbols (Block statements) = concatMap statementSymbols statements

statementSymbols :: Statement ResolvedName annotation -> [SymbolId]
statementSymbols statement = case statement of
    BindingStatement _ _ _ name _ value -> resolvedSymbol name : symbols value
    AssignmentStatement _ name _ value -> resolvedSymbol name : symbols value
    ReturnStatement _ value -> maybe [] symbols value
    IfStatement _ condition yes no -> symbols condition ++ blockSymbols yes ++ maybe [] blockSymbols no
    WhileStatement _ condition body -> symbols condition ++ blockSymbols body
    DoWhileStatement _ body condition -> blockSymbols body ++ symbols condition
    ForStatement _ initializer condition updates body ->
        maybe [] statementSymbols initializer
            ++ maybe [] symbols condition
            ++ blockSymbols body
            ++ concatMap statementSymbols updates
    ForEachStatement _ _ _ name _ collection body ->
        resolvedSymbol name : symbols collection ++ blockSymbols body
    IncrementStatement _ name _ -> [resolvedSymbol name]
    CompoundAssignmentStatement _ _ name _ value -> resolvedSymbol name : symbols value
    DiscardStatement _ value -> symbols value
    BreakStatement _ value -> maybe [] symbols value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> symbols condition ++ blockSymbols block
    BlockStatement _ block -> blockSymbols block
    ExpressionStatement _ value _ -> symbols value

coreClosure :: String -> Maybe CoreExpression
coreClosure statements = case compiled statements of
    Left _ -> Nothing
    Right artifacts -> findCoreClosure (artifactOptimizedCore artifacts)

findCoreClosure :: CoreModule -> Maybe CoreExpression
findCoreClosure moduleValue =
    firstJust
        [ firstJust (map statementCoreClosure (coreFunctionBody function))
        | function <- coreModuleFunctions moduleValue
        ]

statementCoreClosure :: CoreStatement -> Maybe CoreExpression
statementCoreClosure statement = case statement of
    CoreBind binding -> expressionCoreClosure (coreBindingValue binding)
    CoreAssign _ value -> expressionCoreClosure value
    CoreReturn value -> expressionCoreClosure value
    CoreIf condition yes no ->
        expressionCoreClosure condition
            `orElse` firstJust (map statementCoreClosure yes)
            `orElse` firstJust (map statementCoreClosure no)
    CoreEvaluate value -> expressionCoreClosure value
    CoreWhile condition body -> expressionCoreClosure condition `orElse` firstJust (map statementCoreClosure body)
    CoreDoWhile body condition ->
        firstJust (map statementCoreClosure body) `orElse` expressionCoreClosure condition
    CoreFor condition body update ->
        expressionCoreClosure condition
            `orElse` firstJust (map statementCoreClosure body)
            `orElse` firstJust (map statementCoreClosure update)
    CoreBreak -> Nothing
    CoreContinue -> Nothing

expressionCoreClosure :: CoreExpression -> Maybe CoreExpression
expressionCoreClosure expression@CoreClosure {} = Just expression
expressionCoreClosure expression = case expression of
    CoreApply callee arguments _ -> expressionCoreClosure callee `orElse` firstJust (map expressionCoreClosure arguments)
    CorePrimitive _ arguments _ -> firstJust (map expressionCoreClosure arguments)
    _ -> Nothing

preparedClosure :: String -> Maybe CorePrepOperation
preparedClosure statements = preparedBinding statements >>= operationOf

preparedBinding :: String -> Maybe CorePrepInstruction
preparedBinding statements = case compiled statements of
    Left _ -> Nothing
    Right artifacts ->
        firstJust
            [ find isClosureBinding (corePrepBlockInstructions block)
            | function <- corePrepModuleFunctions (artifactCorePrep artifacts)
            , block <- corePrepFunctionBlocks function
            ]

isClosureBinding :: CorePrepInstruction -> Bool
isClosureBinding (CorePrepBind _ _ _ CorePrepMakeClosure {}) = True
isClosureBinding (CorePrepEvaluate CorePrepMakeClosure {}) = True
isClosureBinding _ = False

operationOf :: CorePrepInstruction -> Maybe CorePrepOperation
operationOf (CorePrepBind _ _ _ operation) = Just operation
operationOf (CorePrepEvaluate operation) = Just operation
operationOf _ = Nothing

hasDiagnostic :: String -> Either [Diagnostic] value -> Bool
hasDiagnostic code result = case result of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

isLeftDiagnostics :: Either [Diagnostic] value -> Bool
isLeftDiagnostics (Left (_ : _)) = True
isLeftDiagnostics _ = False

orElse :: Maybe value -> Maybe value -> Maybe value
orElse (Just value) _ = Just value
orElse Nothing right = right

firstJust :: [Maybe value] -> Maybe value
firstJust = foldr orElse Nothing

testName :: Int -> String -> ResolvedName
testName value spelling = ResolvedName (SymbolId value) (Identifier spelling)

invalidClosureType :: CoreModule
invalidClosureType =
    CoreModule
        (QualifiedName [Identifier "ClosureTests"])
        [ CoreFunction
            (testName 1 "Main")
            []
            unitType
            [ CoreBind
                ( CoreBinding
                    (testName 2 "callable")
                    intType
                    False
                    (CoreClosure [] [] intType [CoreReturn (CoreLiteral (CoreInteger 1) intType)] intType)
                )
            , CoreReturn (CoreLiteral CoreUnit unitType)
            ]
        ]

invalidCaptureType :: CoreModule
invalidCaptureType =
    CoreModule
        (QualifiedName [Identifier "ClosureTests"])
        [ CoreFunction
            (testName 1 "Main")
            []
            unitType
            [ CoreBind (CoreBinding (testName 2 "seed") intType True (CoreLiteral (CoreInteger 1) intType))
            , CoreBind
                ( CoreBinding
                    (testName 3 "callable")
                    (FunctionType [] intType)
                    False
                    ( CoreClosure
                        [CoreCapture StrongCapture (testName 4 "seed") intType (CoreLiteral (CoreBoolean True) boolType)]
                        []
                        intType
                        [CoreReturn (CoreVariable (testName 4 "seed") intType)]
                        (FunctionType [] intType)
                    )
                )
            , CoreReturn (CoreLiteral CoreUnit unitType)
            ]
        ]

invalidPreparedWeakCapture :: CorePrepModule
invalidPreparedWeakCapture =
    CorePrepModule
        (QualifiedName [Identifier "ClosureTests"])
        [ CorePrepFunction
            (testName 1 "Main")
            ""
            []
            unitType
            0
            [ CorePrepBlock
                0
                [ CorePrepBind
                    (testName 2 "callable")
                    (FunctionType [] intType)
                    False
                    ( CorePrepMakeClosure
                        (testName 3 "lifted")
                        [CorePrepCapture WeakCapture (testName 4 "value") intType (CorePrepLiteral (CoreInteger 1) intType)]
                    )
                ]
                (CorePrepReturn (CorePrepLiteral CoreUnit unitType))
            ]
        , CorePrepFunction
            (testName 3 "lifted")
            ""
            [(testName 4 "value", intType)]
            intType
            0
            [CorePrepBlock 0 [] (CorePrepReturn (CorePrepVariable (testName 4 "value") intType))]
        ]
        []

-- Keep a textual assertion near the wire tests so failures caused by an
-- accidental version rollback explain themselves in the test output.
_wireVersionContext :: String
_wireVersionContext = "closures require Core wire version 10 and CorePrep wire version 8"

_diagnosticContext :: Diagnostic -> Bool
_diagnosticContext diagnostic = "closure" `isInfixOf` diagnosticMessage diagnostic
