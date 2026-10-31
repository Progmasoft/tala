-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
module Main (main) where

import AssignmentExpressionTests (assignmentExpressionTests)
import BranchingDiagnosticTests (branchingDiagnosticTests)
import BranchingOracleTests (branchingOracleTests)
import BranchingTests (branchingTests)
import ClosureTests (closureTests)
import CompileTimeParityTests (compileTimeParityTests)
import ConditionalExpressionTests (conditionalExpressionTests)
import ConsoleTests (consoleTests)
import Control.Exception (finally)
import CoreInliningTests (coreInliningTests)
import CoreLinearInliningTests (coreLinearInliningTests)
import CoreOptimizerSourceTests (coreOptimizerSourceTests)
import CoreOptimizerTests (coreOptimizerTests)
import CoreVerifierTests (coreVerifierTests)
import Data.List (isInfixOf)
import Data.Word (Word8)
import DiagnosticProtocolTests (diagnosticProtocolTests)
import DiagnosticSideChannelTests (diagnosticSideChannelTests)
import EffectTests (effectTests)
import EnumTests (enumTests)
import FallThroughTests (fallThroughTests)
import FloatingOptimizerTests (floatingOptimizerTests)
import FormatSweepTests (formatSweepTests)
import InferredReturnTests (inferredReturnTests)
import IntegerEvaluationTests (integerEvaluationTests)
import IntegerFlowTests (integerFlowTests)
import IterationTests (iterationTests)
import LazyEvaluationTests (lazyEvaluationTests)
import LoopExpressionTests (loopExpressionTests)
import LoopFlowOracleTests (loopFlowOracleTests)
import LoopFlowTests (loopFlowTests)
import MemoizeTests (memoizeTests)
import MonomorphizationTests (monomorphizationTests)
import NestingLimitTests (nestingLimitTests)
import Numeric (readHex)
import NumericTests (numericTests)
import ParserContractTests (parserContractTests)
import PatternTests (patternTests)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Artifact
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.CorePrep.Wire
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser (Token (..), TokenKind (..))
import Progmasoft.Tala.Pipeline.Stage
import Progmasoft.Tala.Resolver.NameResolution
import QualifiedNameTests (qualifiedNameTests)
import RuntimeCallTests (runtimeCallTests)
import ScalarWireTests (scalarWireTests)
import ShortCircuitTests (shortCircuitTests)
import SourceSetTests (sourceSetTests)
import SourceTextTests (sourceTextTests)
import SourceWarningTests (sourceWarningTests)
import SpecializationTests (specializationTests)
import StaticMemberCoreTests (staticMemberCoreTests)
import StaticMemberOverloadTests (staticMemberOverloadTests)
import StaticMemberParserTests (staticMemberParserTests)
import StaticMemberProjectTests (staticMemberProjectTests)
import StaticMemberSemanticTests (staticMemberSemanticTests)
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import TemplateApplicationTests (templateApplicationTests)
import TemplateDeclarationTests (templateDeclarationTests)
import TemplateDiscoveryTests (templateDiscoveryTests)
import TemplateInstantiationTests (templateInstantiationTests)
import TemplateManglingTests (templateManglingTests)
import TemplateMemberReachabilityTests (templateMemberReachabilityTests)
import TemplatePlanVerifierTests (templatePlanVerifierTests)
import TemplateSpecializationPlannerTests (templateSpecializationPlannerTests)
import TemplateTests (templateTests)
import TemplateVerifierTests (templateVerifierTests)
import TestBuildTests (testBuildTests)
import TypeClassificationTests (typeClassificationTests)
import VoidTests (voidTests)

main :: IO ()
main = do
    mapM_ (uncurry check) coreLinearInliningTests
    check "full frontend compiles renewed declarations through CorePrep" fullPipeline
    check "operator precedence is preserved and constants fold" precedence
    check "unterminated final expression supplies the function result" finalExpression
    check "semicolon-terminated pure expression is rejected" pureExpressionStatement
    check "binding statements require semicolons" bindingRequiresSemicolon
    check "assignment statements require semicolons" assignmentRequiresSemicolon
    check "return statements require semicolons" returnRequiresSemicolon
    check "call expression statements require semicolons" callRequiresSemicolon
    check "void functions cannot use a final result expression" voidFinalExpression
    check "nested blocks cannot use a final result expression" nestedFinalExpression
    check "Core optimizer removes a provably pure dead call before CorePrep" preparedControlFlow
    check "CorePrep creates explicit control flow for a live branch" preparedBranchControlFlow
    check "project entry resolves namespace, class, and public static void Main" entryContract
    check "int Main is rejected for the selected project entry" wrongEntryReturn
    check "top-level runtime functions are rejected" topLevelFunction
    check "unknown names are diagnosed by name resolution" unknownName
    check "Renamer starts SymbolId allocation above the reserved zero sentinel" positiveSymbolSeed
    check "name resolution rejects the reserved zero SymbolId" zeroSymbolRejected
    check "immutable assignment is rejected" immutableAssignment
    check "string conditions are rejected while numeric conditions remain valid" wrongCondition
    check "wrong call arity is rejected" wrongArity
    check "lexer rejects unsupported input" badCharacter
    check "if requires a parenthesized condition" ifRequiresParentheses
    check "logical NOT has only the not spelling" logicalNotHasOneSpelling
    check "String comment forms obey long-bracket levels" stringCommentForms
    check "raw strings preserve content and trim boundary newlines" rawStringBoundaries
    check "higher raw-string levels admit lower closing delimiters" rawStringLevels
    check "raw strings do not decode escapes or interpolation" rawStringIsLiteral
    check "normal string line breaks become spaces and escapes decode" normalStringSemantics
    check "comments and raw strings pass through the frontend pipeline" stringPipeline
    check "legacy C comments are not recognized as comments" legacyCommentsRemoved
    check "unterminated raw strings report a lexer diagnostic" unterminatedRawString
    check
        "renewed artifact extensions remain stable"
        (map artifactExtension [Core, CorePrep, Xpp, Xmm] == [Just ".core", Nothing, Just ".xpp", Just ".xmm"])
    check "Haskell CorePrep verifier rejects duplicate blocks" invalidCorePrep
    check "Core verifier rejects an undefined variable" invalidCoreReference
    check "Core verifier rejects a zero function SymbolId" invalidCoreFunctionSymbol
    check "Core verifier rejects assignment to an immutable binding" invalidCoreMutation
    check "Core verifier requires all non-void paths to return" invalidCoreReturnPath
    check "Core wire codec round-trips optimized Core" coreWireRoundTrip
    check "Core wire rejects CorePrep magic" coreWireRejectsCorePrep
    check "Core wire rejects truncated input" coreWireRejectsTruncation
    check "Core wire rejects trailing bytes" coreWireRejectsTrailingInput
    check "Core wire rejects unresolved types" coreWireRejectsUnresolvedType
    check "Core wire preserves Unicode scalar values" coreWirePreservesUnicode
    check "Core wire v10 provenance fields remain stable" coreWireGoldenDocument
    check "Core wire v10 preserves non-empty source-owner field order" coreWireProjectSourceGolden
    check "CorePrep wire codec round-trips the frontend result" wireRoundTrip
    check "CorePrep wire codec rejects truncated input" wireRejectsTruncation
    check "CorePrep wire codec rejects trailing input" wireRejectsTrailingInput
    check "CorePrep wire codec rejects unsupported types" wireRejectsUnsupportedType
    check "CorePrep wire codec preserves Unicode scalar values" wirePreservesUnicode
    check "CorePrep wire v7 provenance fields remain stable" wireGoldenDocument
    checkIO "real Core artifact round-trips through .core I/O" coreArtifactRoundTrip
    checkIO "Core artifact rejects an invalid Core module" coreArtifactRejectsInvalidModule
    checkIO "Core artifact rejects a non-.core path" coreArtifactRejectsExtension
    mapM_ (uncurry checkIO) sourceSetTests
    mapM_ (uncurry check) sourceTextTests
    mapM_ (uncurry check) sourceWarningTests
    mapM_ (uncurry check) staticMemberParserTests
    mapM_ (uncurry check) staticMemberSemanticTests
    mapM_ (uncurry check) staticMemberCoreTests
    mapM_ (uncurry check) staticMemberOverloadTests
    mapM_ (uncurry checkIO) staticMemberProjectTests
    mapM_ (uncurry check) templateTests
    mapM_ (uncurry check) templateDeclarationTests
    mapM_ (uncurry check) templateDiscoveryTests
    mapM_ (uncurry check) templateApplicationTests
    mapM_ (uncurry check) templateInstantiationTests
    mapM_ (uncurry check) templateManglingTests
    mapM_ (uncurry check) templateMemberReachabilityTests
    mapM_ (uncurry check) templatePlanVerifierTests
    mapM_ (uncurry check) templateSpecializationPlannerTests
    mapM_ (uncurry check) templateVerifierTests
    mapM_ (uncurry check) typeClassificationTests
    mapM_ (uncurry check) closureTests
    mapM_ (uncurry check) coreOptimizerTests
    mapM_ (uncurry check) integerFlowTests
    mapM_ (uncurry check) loopFlowTests
    mapM_ (uncurry check) loopFlowOracleTests
    mapM_ (uncurry check) iterationTests
    mapM_ (uncurry check) floatingOptimizerTests
    mapM_ (uncurry check) coreInliningTests
    mapM_ (uncurry check) coreOptimizerSourceTests
    mapM_ (uncurry check) coreVerifierTests
    mapM_ (uncurry check) diagnosticProtocolTests
    mapM_ (uncurry checkIO) diagnosticSideChannelTests
    mapM_ (uncurry check) numericTests
    mapM_ (uncurry check) integerEvaluationTests
    mapM_ (uncurry check) compileTimeParityTests
    mapM_ (uncurry check) patternTests
    mapM_ (uncurry check) monomorphizationTests
    mapM_ (uncurry check) parserContractTests
    mapM_ (uncurry check) scalarWireTests
    mapM_ (uncurry check) shortCircuitTests
    mapM_ (uncurry check) conditionalExpressionTests
    mapM_ (uncurry check) assignmentExpressionTests
    mapM_ (uncurry check) loopExpressionTests
    mapM_ (uncurry check) branchingTests
    mapM_ (uncurry check) inferredReturnTests
    mapM_ (uncurry check) enumTests
    mapM_ (uncurry check) lazyEvaluationTests
    mapM_ (uncurry check) memoizeTests
    mapM_ (uncurry check) fallThroughTests
    mapM_ (uncurry check) runtimeCallTests
    mapM_ (uncurry check) consoleTests
    mapM_ (uncurry check) testBuildTests
    mapM_ (uncurry check) effectTests
    mapM_ (uncurry check) qualifiedNameTests
    mapM_ (uncurry check) formatSweepTests
    mapM_ (uncurry check) branchingOracleTests
    mapM_ (uncurry check) branchingDiagnosticTests
    mapM_ (uncurry check) nestingLimitTests
    mapM_ (uncurry check) specializationTests
    mapM_ (uncurry check) voidTests

check :: String -> Bool -> IO ()
check label passed = if passed then putStrLn ("PASS: " ++ label) else putStrLn ("FAIL: " ++ label) >> exitFailure

checkIO :: String -> IO Bool -> IO ()
checkIO label action = action >>= check label

compile :: String -> Either [Diagnostic] FrontendArtifacts
compile = compileToCorePrep . CompilerInput "test.tala"

sample :: String
sample =
    unlines
        [ "namespace Name;"
        , "class Main {"
        , "  public static int Sum(_ int left, _ int right) {"
        , "    return left + right;"
        , "  }"
        , "  public static void Main() {"
        , "    int value = Sum(20, 22);"
        , "    if (value >= 40) {"
        , "        value = value + 1;"
        , "    } else {"
        , "        value = 0;"
        , "    }"
        , "    return;"
        , "  }"
        , "}"
        ]

fullPipeline :: Bool
fullPipeline = case compileEntryToCorePrep (QualifiedName [Identifier "Name", Identifier "Main"]) (CompilerInput "test.tala" sample) of
    Right artifacts ->
        length (syntaxDeclarations (typedSyntaxTree (artifactTypedAST artifacts))) == 1
            && length (coreModuleFunctions (artifactOptimizedCore artifacts)) == 2
            && length (corePrepModuleFunctions (artifactCorePrep artifacts)) == 2
    Left _ -> False

precedence :: Bool
precedence = case compile "class Math { public static int Calculate() { return 2 + 3 * 4; } }" of
    Right artifacts -> case coreModuleFunctions (artifactOptimizedCore artifacts) of
        function : _ -> case coreFunctionBody function of
            [CoreReturn (CoreLiteral (CoreInteger 14) _)] -> True
            _ -> False
        [] -> False
    Left _ -> False

finalExpression :: Bool
finalExpression = case compile "class Math { auto Calculate() { 2 + 3 * 4 } }" of
    Right artifacts -> case coreModuleFunctions (artifactOptimizedCore artifacts) of
        function : _ -> case coreFunctionBody function of [CoreReturn (CoreLiteral (CoreInteger 14) _)] -> True; _ -> False
        [] -> False
    Left _ -> False

pureExpressionStatement :: Bool
pureExpressionStatement = hasCode "TAT0013" (compile "class App { void Run() { 42; } }")

bindingRequiresSemicolon :: Bool
bindingRequiresSemicolon = rejected (compile "class App { int Read() { int value = 1 return value; } }")

assignmentRequiresSemicolon :: Bool
assignmentRequiresSemicolon = rejected (compile "class App { int Read() { int value = 1; value = 2 return value; } }")

returnRequiresSemicolon :: Bool
returnRequiresSemicolon = rejected (compile "class App { int Read() { return 1 } }")

callRequiresSemicolon :: Bool
callRequiresSemicolon =
    rejected (compile "class App { void Save() { return; } void Run() { Save() return; } }")

voidFinalExpression :: Bool
voidFinalExpression = rejected (compile "class App { void Run() { 1 } }")

nestedFinalExpression :: Bool
nestedFinalExpression = rejected (compile "class App { int Read() { if (true) { 1 } 2 } }")

preparedControlFlow :: Bool
preparedControlFlow = case compileEntryToCorePrep (QualifiedName [Identifier "Name", Identifier "Main"]) (CompilerInput "test.tala" sample) of
    Right artifacts ->
        let functions = corePrepModuleFunctions (artifactCorePrep artifacts)
            mainFunction = functions !! 1
            blocks = corePrepFunctionBlocks mainFunction
         in not (null blocks) && not (any hasCall blocks) && not (any isBranch blocks)
    Left _ -> False
    where
        isBranch block = case corePrepBlockTerminator block of CorePrepBranch _ _ _ -> True; _ -> False
        hasCall block = any callInstruction (corePrepBlockInstructions block)
        callInstruction instruction = case instruction of
            CorePrepBind _ _ _ (CorePrepCall _ _) -> True
            CorePrepEvaluate (CorePrepCall _ _) -> True
            _ -> False

preparedBranchControlFlow :: Bool
preparedBranchControlFlow = case compile source of
    Right artifacts -> case corePrepModuleFunctions (artifactCorePrep artifacts) of
        [function] ->
            let blocks = corePrepFunctionBlocks function
             in length blocks >= 3 && any isBranch blocks
        _ -> False
    Left _ -> False
    where
        source =
            "class Flow { int Choose(_ int value) { if (value) { return 1; } else { return 2; } } }"
        isBranch block = case corePrepBlockTerminator block of CorePrepBranch _ _ _ -> True; _ -> False

entryContract :: Bool
entryContract = case compile sample of
    Right artifacts -> validateEntryPoint (QualifiedName [Identifier "Name", Identifier "Main"]) (artifactTypedAST artifacts) == Right ()
    Left _ -> False
wrongEntryReturn :: Bool
wrongEntryReturn =
    hasCode
        "TAE0008"
        ( compileEntryToCorePrep
            (QualifiedName [Identifier "Name", Identifier "Main"])
            (CompilerInput "entry.tala" "namespace Name; class Main { public static int Main() { return 0; } }")
        )
topLevelFunction :: Bool
topLevelFunction = hasCode "TAP0006" (compile "int Main() { return 0; }")

hasCode :: String -> Either [Diagnostic] a -> Bool
hasCode code result = case result of Left problems -> any ((== code) . diagnosticCode) problems; Right _ -> False

rejected :: Either [Diagnostic] a -> Bool
rejected result = case result of Left _ -> True; Right _ -> False
unknownName :: Bool
unknownName = hasCode "TAN0001" (compile "class App { int Read() { return missing; } }")

positiveSymbolSeed :: Bool
positiveSymbolSeed = case compile "class FirstType { void Run() { return; } }" of
    Right artifacts -> case syntaxDeclarations (resolvedSyntaxTree (artifactResolvedAST artifacts)) of
        TypeDeclaration {declarationName = name} : _ -> symbolIdValue (resolvedSymbol name) == 1
        _ -> False
    Left _ -> False

zeroSymbolRejected :: Bool
zeroSymbolRejected =
    let position = SourcePosition 1 1
        spanValue = SourceSpan "zero-symbol.tala" position position
        declaration = TypeDeclaration spanValue (RenamedName (Identifier "ZeroSymbol") 0) () []
        renamed = RenamedAST (SyntaxTree Nothing [declaration])
     in hasCode "TAN0002" (runNameResolution defaultNameResolution renamed)
immutableAssignment :: Bool
immutableAssignment = hasCode "TAT0003" (compile "class App { int Read() { final int value = 1; value = 2; return value; } }")
wrongCondition :: Bool
wrongCondition = hasCode "TAT0006" (compile "class App { void Run() { if (\"yes\") { return; } return; } }")

ifRequiresParentheses :: Bool
ifRequiresParentheses =
    rejected (compile "class App { void Run() { if true { return; } return; } }")
        && not (rejected (compile "class App { void Run() { if (true) { return; } return; } }"))

logicalNotHasOneSpelling :: Bool
logicalNotHasOneSpelling =
    not (rejected (compile "class App { void Run() { if (not false) { return; } return; } }"))
        && rejected (compile "class App { void Run() { if (!false) { return; } return; } }")
wrongArity :: Bool
wrongArity = hasCode "TAT0008" (compile "class App { int Sum(_ int a, _ int b) { return a+b; } void Run() { Sum(1); } }")
badCharacter :: Bool
badCharacter = case compile "class App { void Run() { @; } }" of
    Left problems -> any (isInfixOf "unsupported character" . diagnosticMessage) problems
    Right _ -> False

lexTokens :: String -> Either [Diagnostic] [Token]
lexTokens = runLexer defaultLexer . LexerInput "string-test.tala"

lexicalText :: String -> Either [Diagnostic] [String]
lexicalText source =
    map tokenText . filter ((/= EndOfFileToken) . tokenKind) <$> lexTokens source

singleStringValue :: String -> Either [Diagnostic] String
singleStringValue source = do
    tokens <- lexTokens source
    case [tokenText value | value <- tokens, tokenKind value == StringToken] of
        [value] -> Right value
        _ -> Left []

stringCommentForms :: Bool
stringCommentForms =
    lexicalText
        ( "int first; -- ordinary\r\n"
            ++ "--| declaration documentation\n"
            ++ "--! namespace documentation\n"
            ++ "--[=[ long comment containing ]] and --[[ text ]=]\n"
            ++ "--[==[! namespace long comment containing ]=] ]==]\n"
            ++ "int second;"
        )
        == Right ["int", "first", ";", "int", "second", ";"]

rawStringBoundaries :: Bool
rawStringBoundaries =
    singleStringValue "[[\r\nHello\nWorld\r\n]]" == Right "Hello\nWorld"
        && singleStringValue "[[Hello\nWorld]]" == Right "Hello\nWorld"
        && singleStringValue "[[\nHello\n\n]]" == Right "Hello\n"

rawStringLevels :: Bool
rawStringLevels =
    singleStringValue "[==[\nThis ]] and this ]=] remain content.\n]==]"
        == Right "This ]] and this ]=] remain content."

rawStringIsLiteral :: Bool
rawStringIsLiteral =
    singleStringValue "[=[\\n\\t${value}]=]" == Right "\\n\\t${value}"

normalStringSemantics :: Bool
normalStringSemantics =
    singleStringValue "\"first\r\nsecond\\nthird\\u0021\\x000000000041\"" == Right "first second\nthird!A"

stringPipeline :: Bool
stringPipeline = case compile source of
    Right artifacts ->
        sourceCorePreservesLiteral (artifactCore artifacts)
            && optimizedCoreRemovesDeadLiteral (artifactOptimizedCore artifacts)
    Left _ -> False
    where
        sourceCorePreservesLiteral moduleValue = case coreModuleFunctions moduleValue of
            [function] -> case coreFunctionBody function of
                [CoreBind (CoreBinding _ _ _ (CoreLiteral (CoreString text) _)), CoreReturn (CoreLiteral (CoreInteger 1) _)] ->
                    text == "-- remains raw\n[=[ remains raw"
                _ -> False
            _ -> False
        optimizedCoreRemovesDeadLiteral moduleValue = case coreModuleFunctions moduleValue of
            [function] -> coreFunctionBody function == [CoreReturn (CoreLiteral (CoreInteger 1) intType)]
            _ -> False
        source =
            unlines
                [ "--! Pipeline namespace documentation"
                , "namespace Text;"
                , "class App {"
                , "  --[=[ ordinary long comment containing ]] ]=]"
                , "  --| Returns a value after exercising a raw literal."
                , "  int Value() {"
                , "    auto text = [["
                , "-- remains raw"
                , "[=[ remains raw"
                , "]] ;"
                , "    return 1;"
                , "  }"
                , "}"
                ]

legacyCommentsRemoved :: Bool
legacyCommentsRemoved =
    lexicalText "int quotient = left // right; /* legacy */"
        == Right ["int", "quotient", "=", "left", "//", "right", ";", "/", "*", "legacy", "*", "/"]

unterminatedRawString :: Bool
unterminatedRawString = hasCode "TAL0005" (lexTokens "[=[never closed")

invalidCorePrep :: Bool
invalidCorePrep = case compile sample of
    Right artifacts -> case corePrepModuleFunctions (artifactCorePrep artifacts) of
        function : rest ->
            hasCode
                "TAC0003"
                ( verifyCorePrep
                    (artifactCorePrep artifacts)
                        { corePrepModuleFunctions =
                            function {corePrepFunctionBlocks = corePrepFunctionBlocks function ++ take 1 (corePrepFunctionBlocks function)} : rest
                        }
                )
        [] -> False
    Left _ -> False

invalidCoreReference :: Bool
invalidCoreReference =
    let name = ResolvedName (SymbolId 90) (Identifier "missing")
        function =
            CoreFunction
                (ResolvedName (SymbolId 1) (Identifier "Read"))
                []
                intType
                [CoreReturn (CoreVariable name intType)]
     in hasCode "TAC1020" (verifyCore (CoreModuleWithSources (QualifiedName [Identifier "CoreTest"]) [function] [] []))

invalidCoreFunctionSymbol :: Bool
invalidCoreFunctionSymbol =
    let name = ResolvedName (SymbolId 0) (Identifier "Invalid")
        function = CoreFunction name [] unitType [CoreReturn (CoreLiteral CoreUnit unitType)]
     in hasCode "TAC1006" (verifyCore (CoreModuleWithSources (QualifiedName [Identifier "CoreTest"]) [function] [] []))

invalidCoreMutation :: Bool
invalidCoreMutation =
    let name = ResolvedName (SymbolId 2) (Identifier "value")
        literal value = CoreLiteral (CoreInteger value) intType
        binding = CoreBinding name intType False (literal 1)
        function =
            CoreFunction
                (ResolvedName (SymbolId 1) (Identifier "Read"))
                []
                intType
                [CoreBind binding, CoreAssign name (literal 2), CoreReturn (CoreVariable name intType)]
     in hasCode "TAC1013" (verifyCore (CoreModuleWithSources (QualifiedName [Identifier "CoreTest"]) [function] [] []))

invalidCoreReturnPath :: Bool
invalidCoreReturnPath =
    let condition = CoreLiteral (CoreBoolean True) boolType
        result = CoreLiteral (CoreInteger 1) intType
        function =
            CoreFunction
                (ResolvedName (SymbolId 1) (Identifier "Read"))
                []
                intType
                [CoreIf condition [CoreReturn result] []]
     in hasCode "TAC1005" (verifyCore (CoreModuleWithSources (QualifiedName [Identifier "CoreTest"]) [function] [] []))

coreWireRoundTrip :: Bool
coreWireRoundTrip = case compile sample of
    Right artifacts ->
        let value = artifactOptimizedCore artifacts
         in (encodeCore defaultCoreWireLimits value >>= decodeCore defaultCoreWireLimits) == Right value
    Left _ -> False

coreWireRejectsCorePrep :: Bool
coreWireRejectsCorePrep = case encodeCorePrep goldenModule of
    Right bytes -> case decodeCore defaultCoreWireLimits bytes of
        Left issue -> coreWireErrorKind issue == CoreInvalidMagic
        Right _ -> False
    Left _ -> False

coreWireRejectsTruncation :: Bool
coreWireRejectsTruncation = case compile sample of
    Right artifacts -> case encodeCore defaultCoreWireLimits (artifactOptimizedCore artifacts) of
        Right bytes -> case decodeCore defaultCoreWireLimits (init bytes) of
            Left issue -> coreWireErrorKind issue == CoreTruncatedInput
            Right _ -> False
        Left _ -> False
    Left _ -> False

coreWireRejectsTrailingInput :: Bool
coreWireRejectsTrailingInput = case compile sample of
    Right artifacts -> case encodeCore defaultCoreWireLimits (artifactOptimizedCore artifacts) of
        Right bytes -> case decodeCore defaultCoreWireLimits (bytes ++ [0]) of
            Left issue -> coreWireErrorKind issue == CoreTrailingInput
            Right _ -> False
        Left _ -> False
    Left _ -> False

coreWireRejectsUnresolvedType :: Bool
coreWireRejectsUnresolvedType =
    let function = CoreFunction (ResolvedName (SymbolId 1) (Identifier "Broken")) [] ErrorType []
        moduleValue = CoreModuleWithSources (QualifiedName [Identifier "CoreTest"]) [function] [] []
     in case encodeCore defaultCoreWireLimits moduleValue of
            Left issue -> coreWireErrorKind issue == CoreUnsupportedType
            Right _ -> False

coreWirePreservesUnicode :: Bool
coreWirePreservesUnicode =
    let functionName = ResolvedName (SymbolId 1) (Identifier "Metinλ")
        value = CoreLiteral (CoreString "Tala λ 😀") stringType
        moduleValue =
            CoreModuleWithSources
                (QualifiedName [Identifier "Unicode"])
                [CoreFunction functionName [] stringType [CoreReturn value]]
                []
                []
     in (encodeCore defaultCoreWireLimits moduleValue >>= decodeCore defaultCoreWireLimits) == Right moduleValue

coreWireGoldenDocument :: Bool
coreWireGoldenDocument =
    let mainName = ResolvedName (SymbolId 1) (Identifier "Main")
        mainFunction = CoreFunction mainName [] unitType [CoreReturn (CoreLiteral CoreUnit unitType)]
        moduleValue = CoreModuleWithSources (QualifiedName [Identifier "Demo"]) [mainFunction] [] []
        bytes =
            upgradeSimpleV5
                0x0a
                [ 0x54
                , 0x41
                , 0x43
                , 0x52
                , 0x05
                , 0x00
                , 0x00
                , 0x00
                , 0x01
                , 0x00
                , 0x00
                , 0x00
                , 0x04
                , 0x00
                , 0x00
                , 0x00
                , 0x44
                , 0x00
                , 0x00
                , 0x00
                , 0x65
                , 0x00
                , 0x00
                , 0x00
                , 0x6d
                , 0x00
                , 0x00
                , 0x00
                , 0x6f
                , 0x00
                , 0x00
                , 0x00
                , 0x01
                , 0x00
                , 0x00
                , 0x00
                , 0x01
                , 0x00
                , 0x00
                , 0x00
                , 0x00
                , 0x00
                , 0x00
                , 0x00
                , 0x04
                , 0x00
                , 0x00
                , 0x00
                , 0x4d
                , 0x00
                , 0x00
                , 0x00
                , 0x61
                , 0x00
                , 0x00
                , 0x00
                , 0x69
                , 0x00
                , 0x00
                , 0x00
                , 0x6e
                , 0x00
                , 0x00
                , 0x00
                , 0x00
                , 0x00
                , 0x00
                , 0x00
                , 0x00
                , 0x01
                , 0x00
                , 0x00
                , 0x00
                , 0x02
                , 0x01
                , 0x00
                , 0x00
                ]
     in encodeCore defaultCoreWireLimits moduleValue == Right bytes
            && decodeCore defaultCoreWireLimits bytes == Right moduleValue

coreWireProjectSourceGolden :: Bool
coreWireProjectSourceGolden =
    let source = "Sources/Main.tala"
        mainName = ResolvedName (SymbolId 1) (Identifier "Main")
        mainFunction = CoreFunction mainName [] unitType [CoreReturn (CoreLiteral CoreUnit unitType)]
        moduleValue =
            CoreModuleWithSources
                (QualifiedName [Identifier "Demo"])
                [mainFunction]
                [source]
                [(symbolIdValue (resolvedSymbol mainName), source)]
        goldenHex =
            unwords
                [ "54 41 43 52 0A 00 00 00 01 00 00 00"
                , "04 00 00 00 44 00 00 00 65 00 00 00"
                , "6d 00 00 00 6f 00 00 00 01 00 00 00"
                , "11 00 00 00 53 00 00 00 6f 00 00 00"
                , "75 00 00 00 72 00 00 00 63 00 00 00"
                , "65 00 00 00 73 00 00 00 2f 00 00 00"
                , "4d 00 00 00 61 00 00 00 69 00 00 00"
                , "6e 00 00 00 2e 00 00 00 74 00 00 00"
                , "61 00 00 00 6c 00 00 00 61 00 00 00"
                , "01 00 00 00"
                , "01 00 00 00 00 00 00 00 04 00 00 00"
                , "4d 00 00 00 61 00 00 00 69 00 00 00"
                , "6e 00 00 00 11 00 00 00 53 00 00 00"
                , "6f 00 00 00 75 00 00 00 72 00 00 00"
                , "63 00 00 00 65 00 00 00 73 00 00 00"
                , "2f 00 00 00 4d 00 00 00 61 00 00 00"
                , "69 00 00 00 6e 00 00 00 2e 00 00 00"
                , "74 00 00 00 61 00 00 00 6c 00 00 00"
                , "61 00 00 00"
                , "00 00 00 00 00 01 00 00 00 02 01 00 00"
                ]
        parsedExpectedBytes = traverse parseHexByte (words goldenHex)
     in case parsedExpectedBytes of
            Just expected ->
                encodeCore defaultCoreWireLimits moduleValue == Right expected
                    && decodeCore defaultCoreWireLimits expected == Right moduleValue
            Nothing -> False
    where
        parseHexByte token = case readHex token of
            [(value, "")] | value >= (0 :: Int) && value <= 255 -> Just (fromIntegral value)
            _ -> Nothing

-- Adding the empty source catalog and function owner to the compact v5 golden
-- shape gives an independent byte-level v10 expectation. The owner follows the
-- function symbol, before its parameter vector, matching the wire contract.
upgradeSimpleV5 :: Word8 -> [Word8] -> [Word8]
upgradeSimpleV5 currentVersion v5Bytes =
    replaceVersion
        (insertAt 68 emptyText (insertAt 32 emptyVector v5Bytes))
    where
        emptyVector = [0, 0, 0, 0]
        emptyText = [0, 0, 0, 0]
        insertAt offset inserted bytes = take offset bytes ++ inserted ++ drop offset bytes
        replaceVersion bytes = take 4 bytes ++ [currentVersion] ++ drop 5 bytes

wireRoundTrip :: Bool
wireRoundTrip = case compile sample of
    Right artifacts -> case encodeCorePrep (artifactCorePrep artifacts) >>= decodeCorePrep of
        Right decoded -> decoded == artifactCorePrep artifacts
        Left _ -> False
    Left _ -> False

wireRejectsTruncation :: Bool
wireRejectsTruncation = case compile sample of
    Right artifacts -> case encodeCorePrep (artifactCorePrep artifacts) of
        Right bytes -> case decodeCorePrep (take (length bytes - 1) bytes) of
            Left problem -> wireErrorKind problem == TruncatedInput
            Right _ -> False
        Left _ -> False
    Left _ -> False

wireRejectsTrailingInput :: Bool
wireRejectsTrailingInput = case compile sample of
    Right artifacts -> case encodeCorePrep (artifactCorePrep artifacts) of
        Right bytes -> case decodeCorePrep (bytes ++ [0]) of
            Left problem -> wireErrorKind problem == TrailingInput
            Right _ -> False
        Left _ -> False
    Left _ -> False

wireRejectsUnsupportedType :: Bool
wireRejectsUnsupportedType = case compile sample of
    Right artifacts ->
        let prepared = artifactCorePrep artifacts
         in case corePrepModuleFunctions prepared of
                function : remaining ->
                    let changed = prepared {corePrepModuleFunctions = function {corePrepFunctionReturnType = ErrorType} : remaining}
                     in case encodeCorePrep changed of
                            Left problem -> wireErrorKind problem == UnsupportedType
                            Right _ -> False
                [] -> False
    Left _ -> False

wirePreservesUnicode :: Bool
wirePreservesUnicode =
    let name = ResolvedName (SymbolId 1) (Identifier "Text")
        literal = CorePrepLiteral (CoreString "Tala λ 😀") stringType
        function = CorePrepFunction name "" [] stringType 0 [CorePrepBlock 0 [] (CorePrepReturn literal)]
        prepared = CorePrepModule (QualifiedName [Identifier "Unicode"]) [function] []
     in case encodeCorePrep prepared >>= decodeCorePrep of
            Right decoded -> decoded == prepared
            Left _ -> False

goldenModule :: CorePrepModule
goldenModule =
    let mainName = ResolvedName (SymbolId 1) (Identifier "Main")
        mainBlock = CorePrepBlock 0 [] (CorePrepReturn (CorePrepLiteral CoreUnit unitType))
        mainFunction = CorePrepFunction mainName "" [] unitType 0 [mainBlock]
     in CorePrepModule (QualifiedName [Identifier "Demo"]) [mainFunction] []

goldenBytes :: [Word8]
goldenBytes =
    upgradeSimpleV5
        0x08
        [ 0x54
        , 0x41
        , 0x43
        , 0x50
        , 0x05
        , 0x00
        , 0x00
        , 0x00
        , 0x01
        , 0x00
        , 0x00
        , 0x00
        , 0x04
        , 0x00
        , 0x00
        , 0x00
        , 0x44
        , 0x00
        , 0x00
        , 0x00
        , 0x65
        , 0x00
        , 0x00
        , 0x00
        , 0x6d
        , 0x00
        , 0x00
        , 0x00
        , 0x6f
        , 0x00
        , 0x00
        , 0x00
        , 0x01
        , 0x00
        , 0x00
        , 0x00
        , 0x01
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x04
        , 0x00
        , 0x00
        , 0x00
        , 0x4d
        , 0x00
        , 0x00
        , 0x00
        , 0x61
        , 0x00
        , 0x00
        , 0x00
        , 0x69
        , 0x00
        , 0x00
        , 0x00
        , 0x6e
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x01
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x00
        , 0x01
        , 0x00
        , 0x00
        ]

wireGoldenDocument :: Bool
wireGoldenDocument =
    encodeCorePrep goldenModule == Right goldenBytes
        && decodeCorePrep goldenBytes == Right goldenModule

coreArtifactRoundTrip :: IO Bool
coreArtifactRoundTrip = case compile sample of
    Left _ -> pure False
    Right artifacts -> do
        temporary <- getTemporaryDirectory
        let path = temporary </> "tala-core-wire-v10.core"
            cleanup = doesFileExist path >>= \exists -> if exists then removeFile path else pure ()
            value = artifactOptimizedCore artifacts
        ( do
                written <- writeCoreArtifact path value
                loaded <- readCoreArtifact path
                pure (written == Right () && loaded == Right value)
            )
            `finally` cleanup

coreArtifactRejectsInvalidModule :: IO Bool
coreArtifactRejectsInvalidModule = do
    let function = CoreFunction (ResolvedName (SymbolId 1) (Identifier "Broken")) [] intType []
        invalid = CoreModuleWithSources (QualifiedName [Identifier "CoreTest"]) [function] [] []
    result <- writeCoreArtifact "invalid-core.core" invalid
    pure $ case result of
        Left (CoreArtifactVerificationError messages) -> any (isInfixOf "TAC1005") messages
        _ -> False

coreArtifactRejectsExtension :: IO Bool
coreArtifactRejectsExtension = do
    let function =
            CoreFunction
                (ResolvedName (SymbolId 1) (Identifier "Main"))
                []
                unitType
                [CoreReturn (CoreLiteral CoreUnit unitType)]
        moduleValue = CoreModuleWithSources (QualifiedName [Identifier "CoreTest"]) [function] [] []
    result <- writeCoreArtifact "invalid-core.xpp" moduleValue
    pure (result == Left (InvalidCoreArtifactPath "invalid-core.xpp"))
