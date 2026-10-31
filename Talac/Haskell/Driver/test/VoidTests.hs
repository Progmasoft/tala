-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module VoidTests (voidTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Diagnostic

voidTests :: [(String, Bool)]
voidTests =
    [ ("void helper retains source spelling", voidType == namedType "void")
    , ("unit remains an internal no-result marker", unitType == namedType "unit")
    , ("void function is typed as void", typedReturnType voidFunction == Just voidType)
    , ("source unit type is rejected", rejected unitFunction)
    , ("empty parentheses are not a unit literal", rejected emptyParenthesesFunction)
    , ("void is erased to the internal Core no-result marker", coreReturnType voidFunction == Just unitType)
    , ("void bare return becomes CoreUnit", coreHasUnitReturn voidFunction)
    , ("void function rejects a value return", rejected "class App { void Run() { return 1; } }")
    , ("void function rejects a final expression", rejected "class App { void Run() { 1 } }")
    , ("void call is typed void before Core", typedCallResult == Just voidType)
    , ("void call result uses the internal marker after Core lowering", coreCallResult == Just unitType)
    , ("entry contract accepts public static void Main", entryAccepted)
    , ("entry contract rejects source unit before entry validation", entryUnitRejected)
    , ("entry contract rejects public static int Main", entryIntRejected)
    ]

voidFunction :: String
voidFunction = "class App { void Run() { return; } }"

unitFunction :: String
unitFunction = "class App { unit Value() { () } }"

emptyParenthesesFunction :: String
emptyParenthesesFunction = "class App { int Value() { () } }"

rejected :: String -> Bool
rejected source = case compileSource source of Left _ -> True; Right _ -> False

typedReturnType :: String -> Maybe Type
typedReturnType source = do
    artifacts <- either (const Nothing) Just (compileSource source)
    declaration <- firstFunction (artifactTypedAST artifacts)
    case declarationAnnotation declaration of
        FunctionType _ result -> Just result
        _ -> Nothing

coreReturnType :: String -> Maybe Type
coreReturnType source = do
    artifacts <- either (const Nothing) Just (compileSource source)
    function <- firstValue (coreModuleFunctions (artifactCore artifacts))
    pure (coreFunctionReturnType function)

coreHasUnitReturn :: String -> Bool
coreHasUnitReturn source = case compileSource source of
    Right artifacts -> case coreModuleFunctions (artifactCore artifacts) of
        [function] -> any isUnitReturn (coreFunctionBody function)
        _ -> False
    Left _ -> False
    where
        isUnitReturn (CoreReturn (CoreLiteral CoreUnit valueType)) = valueType == unitType
        isUnitReturn _ = False

typedCallResult :: Maybe Type
typedCallResult = do
    artifacts <- either (const Nothing) Just (compileSource callSource)
    declarations <- case artifactTypedAST artifacts of TypedAST tree -> Just (syntaxDeclarations tree)
    case declarations of
        [TypeDeclaration {typeMembers = [_save, FunctionDeclaration {declarationBody = body}]}] -> findTypedCall body
        _ -> Nothing

coreCallResult :: Maybe Type
coreCallResult = do
    artifacts <- either (const Nothing) Just (compileSource callSource)
    case coreModuleFunctions (artifactCore artifacts) of
        [_save, run] -> findCoreCall (coreFunctionBody run)
        _ -> Nothing

callSource :: String
callSource = "class App { void Save() { return; } void Run() { Save(); return; } }"

findTypedCall :: Block name Type -> Maybe Type
findTypedCall (Block statements) = case statements of
    ExpressionStatement _ (CallExpression _ _ _ resultType) True : _ -> Just resultType
    _ : remaining -> findTypedCall (Block remaining)
    [] -> Nothing

findCoreCall :: [CoreStatement] -> Maybe Type
findCoreCall statements = case statements of
    CoreEvaluate (CoreApply _ _ resultType) : _ -> Just resultType
    _ : remaining -> findCoreCall remaining
    [] -> Nothing

entryAccepted :: Bool
entryAccepted = case compileEntry entry "namespace Demo; class Program { public static void Main() { return; } }" of
    Right _ -> True
    Left _ -> False

entryUnitRejected :: Bool
entryUnitRejected = rejectedEntry (compileEntry entry "namespace Demo; class Program { public static unit Main() { () } }")

entryIntRejected :: Bool
entryIntRejected =
    hasDiagnostic "TAE0008" (compileEntry entry "namespace Demo; class Program { public static int Main() { return 0; } }")

entry :: QualifiedName
entry = QualifiedName [Identifier "Demo", Identifier "Program"]

compileEntry :: QualifiedName -> String -> Either [Diagnostic] FrontendArtifacts
compileEntry name source = compileEntryToCorePrep name (CompilerInput "void-entry-test.tala" source)

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource source = compileToCorePrep (CompilerInput "void-test.tala" source)

hasDiagnostic :: String -> Either [Diagnostic] a -> Bool
hasDiagnostic code result = case result of
    Left problems -> any ((== code) . diagnosticCode) problems
    Right _ -> False

rejectedEntry :: Either [Diagnostic] a -> Bool
rejectedEntry result = case result of
    Left _ -> True
    Right _ -> False

firstFunction :: TypedAST -> Maybe (Declaration ResolvedName Type)
firstFunction (TypedAST tree) = case syntaxDeclarations tree of
    TypeDeclaration {typeMembers = function : _} : _ -> Just function
    function@FunctionDeclaration {} : _ -> Just function
    _ -> Nothing

firstValue :: [a] -> Maybe a
firstValue [] = Nothing
firstValue (value : _) = Just value
