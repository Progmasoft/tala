-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Private command model shared by the Haskell shared-library boundary and
the small command-line adapter. It returns owned bytes instead of opening an
output artifact: the native driver consumes Core in memory and is the only
component that writes user-requested outputs.
-}
module Progmasoft.Tala.Driver.Command
    ( FrontendOutcome (..)
    , FrontendOutputKind (..)
    , runFrontendArguments
    ) where

import Data.ByteString qualified as ByteString
import Data.Char (isAlpha, isAlphaNum)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core (CoreModule)
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.SourceSet
import Progmasoft.Tala.SourceWarnings

{- | Output tags are part of the private in-process ABI, not public artifact
names. Each output is borrowed only for the synchronous native callback.
-}
data FrontendOutputKind
    = CoreWireOutput
    | ProjectSourceListOutput
    | DiagnosticWireOutput
    | ErrorTextOutput
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

{- | Owned result of one private frontend request, ready for native consumption.

A success carries the warnings of the sources it compiled. A rejection lists
its errors first and the warnings after them, because a warning often
explains the error that follows it in the same statement.
-}
data FrontendOutcome
    = FrontendSuccess FrontendOutputKind ByteString.ByteString [Diagnostic]
    | FrontendDiagnostics [Diagnostic]
    | FrontendFailure String

data FrontendCommand
    = CompileFile FilePath
    | CompileFiles QualifiedName [FilePath]
    | CompileProject FilePath QualifiedName [FilePath] [FilePath]
    | ListProjectSources FilePath [FilePath] [FilePath]

data CommandOptions = CommandOptions
    { optionSourceFiles :: [FilePath]
    , optionProjectRoot :: Maybe FilePath
    , optionEntry :: Maybe String
    , optionSourceRoots :: [FilePath]
    , optionExcludes :: [FilePath]
    , optionListSources :: Bool
    }

emptyOptions :: CommandOptions
emptyOptions = CommandOptions [] Nothing Nothing [] [] False

{- | Parse the deliberately narrow private argument vocabulary. Values remain
separate from option names so file names and glob patterns cannot be
reinterpreted by a shell or by option-prefix heuristics.
-}
runFrontendArguments :: [String] -> IO FrontendOutcome
runFrontendArguments arguments = case parseCommand arguments of
    Left problem -> pure (FrontendFailure problem)
    Right command -> executeCommand command

parseCommand :: [String] -> Either String FrontendCommand
parseCommand arguments = parseOptions emptyOptions arguments >>= finishCommand

parseOptions :: CommandOptions -> [String] -> Either String CommandOptions
parseOptions options [] = Right options
parseOptions options (name : remaining) = case name of
    "--source-file" -> repeatedValue name addSourceFile options remaining
    "--project-root" -> uniqueValue name optionProjectRoot setProjectRoot options remaining
    "--entry" -> uniqueValue name optionEntry setEntry options remaining
    "--source-root" -> repeatedValue name addSourceRoot options remaining
    "--exclude" -> repeatedValue name addExclude options remaining
    "--list-sources"
        | optionListSources options -> Left "--list-sources may be specified only once"
        | otherwise -> parseOptions options {optionListSources = True} remaining
    _ -> Left ("unknown private frontend option: " ++ name)

uniqueValue ::
    String ->
    (CommandOptions -> Maybe String) ->
    (String -> CommandOptions -> CommandOptions) ->
    CommandOptions ->
    [String] ->
    Either String CommandOptions
uniqueValue name getter setter options remaining = case remaining of
    [] -> Left (name ++ " requires one value")
    value : rest
        | null value -> Left (name ++ " value is empty")
        | getter options /= Nothing -> Left (name ++ " may be specified only once")
        | otherwise -> parseOptions (setter value options) rest

repeatedValue ::
    String ->
    (String -> CommandOptions -> CommandOptions) ->
    CommandOptions ->
    [String] ->
    Either String CommandOptions
repeatedValue name setter options remaining = case remaining of
    [] -> Left (name ++ " requires one value")
    value : rest
        | null value -> Left (name ++ " value is empty")
        | otherwise -> parseOptions (setter value options) rest

setProjectRoot, setEntry :: String -> CommandOptions -> CommandOptions
setProjectRoot value options = options {optionProjectRoot = Just value}
setEntry value options = options {optionEntry = Just value}

addSourceFile, addSourceRoot, addExclude :: String -> CommandOptions -> CommandOptions
addSourceFile value options = options {optionSourceFiles = optionSourceFiles options ++ [value]}
addSourceRoot value options = options {optionSourceRoots = optionSourceRoots options ++ [value]}
addExclude value options = options {optionExcludes = optionExcludes options ++ [value]}

finishCommand :: CommandOptions -> Either String FrontendCommand
finishCommand options = case ( optionSourceFiles options
                             , optionProjectRoot options
                             , optionEntry options
                             , optionListSources options
                             ) of
    (sources@(_ : _), Nothing, entryText, False)
        | not (null (optionSourceRoots options) && null (optionExcludes options)) ->
            Left "file compilation cannot declare project roots or exclusions"
        | otherwise -> case (entryText, sources) of
            (Just written, _) -> fmap (`CompileFiles` sources) (parseQualifiedName written)
            (Nothing, [source]) -> Right (CompileFile source)
            (Nothing, _) -> Left "several source files require --entry"
    ([], Just root, Just entryText, False) -> do
        entry <- parseQualifiedName entryText
        if null (optionSourceRoots options)
            then Left "project compilation requires at least one --source-root"
            else Right (CompileProject root entry (optionSourceRoots options) (optionExcludes options))
    ([], Just root, Nothing, True)
        | not (null (optionSourceRoots options)) ->
            Right (ListProjectSources root (optionSourceRoots options) (optionExcludes options))
        | otherwise -> Left "project source listing requires at least one --source-root"
    _ -> Left "arguments must describe exactly one file compile, project compile, or project source listing"

{- | Load every explicitly named source. A file named twice is one source;
the first failure of any file rejects the whole set, as project loading does.
-}
loadSourceFiles :: [FilePath] -> IO (Either [Diagnostic] [LoadedSource])
loadSourceFiles paths = do
    loaded <- mapM loadSourceFile paths
    let problems = concat [issues | Left issues <- loaded]
        sources = [source | Right source <- loaded]
    pure $ if null problems then Right (uniqueSources sources) else Left problems
    where
        uniqueSources = foldr keepFirst []
        keepFirst source rest =
            source : filter ((/= loadedSourcePath source) . loadedSourcePath) rest

parseQualifiedName :: String -> Either String QualifiedName
parseQualifiedName text =
    let parts = splitDot text
     in if length parts < 2
            then Left "--entry must name a namespace-qualified class"
            else
                if all validIdentifier parts
                    then Right (QualifiedName (map Identifier parts))
                    else Left ("--entry contains an invalid identifier: " ++ text)

validIdentifier :: String -> Bool
validIdentifier [] = False
validIdentifier (first : remaining) =
    (isAlpha first || first == '_') && all (\value -> isAlphaNum value || value == '_') remaining

splitDot :: String -> [String]
splitDot [] = [""]
splitDot ('.' : remaining) = "" : splitDot remaining
splitDot (value : remaining) = case splitDot remaining of
    [] -> [[value]]
    first : rest -> (value : first) : rest

executeCommand :: FrontendCommand -> IO FrontendOutcome
executeCommand command = case command of
    CompileFile source -> do
        loaded <- loadSourceFile source
        case loaded of
            Left diagnostics -> pure (FrontendDiagnostics diagnostics)
            Right document ->
                let warnings = loadedSourceWarnings document
                 in case compileToCorePrep (CompilerInput (loadedSourceRelativePath document) (loadedSourceText document)) of
                        Left diagnostics -> pure (FrontendDiagnostics (diagnostics ++ warnings))
                        Right artifacts -> encodeCoreOutcome warnings (artifactOptimizedCore artifacts)
    CompileFiles entry sources -> do
        loaded <- loadSourceFiles sources
        case loaded of
            Left diagnostics -> pure (FrontendDiagnostics diagnostics)
            Right documents ->
                let warnings = concatMap loadedSourceWarnings documents
                    inputs = map toProjectCompilerInput documents
                    -- One source keeps the single-file pipeline, whose Core
                    -- carries no source catalog; several are one program.
                    compiled = case inputs of
                        [input] -> fmap artifactOptimizedCore (compileEntryToCorePrep entry input)
                        _ -> fmap projectEntryCore (compileProjectToCorePrep entry inputs)
                 in case compiled of
                        Left diagnostics -> pure (FrontendDiagnostics (diagnostics ++ warnings))
                        Right core -> encodeCoreOutcome warnings core
    CompileProject root entry roots excludes -> do
        loaded <- loadSourceSet (SourceSetRequest root roots excludes)
        case loaded of
            Left diagnostics -> pure (FrontendDiagnostics diagnostics)
            Right documents ->
                let warnings = concatMap loadedSourceWarnings documents
                 in case compileProjectToCorePrep entry (map toProjectCompilerInput documents) of
                        Left diagnostics -> pure (FrontendDiagnostics (diagnostics ++ warnings))
                        Right artifacts -> encodeCoreOutcome warnings (projectEntryCore artifacts)
    ListProjectSources root roots excludes -> do
        discovered <- discoverSourceSet (SourceSetRequest root roots excludes)
        pure $ case discovered of
            Left diagnostics -> FrontendDiagnostics diagnostics
            Right paths ->
                FrontendSuccess
                    ProjectSourceListOutput
                    (Text.encodeUtf8 (Text.pack (concatMap (++ "\0") paths)))
                    []

toProjectCompilerInput :: LoadedSource -> CompilerInput
toProjectCompilerInput source = CompilerInput (loadedSourceRelativePath source) (loadedSourceText source)

loadedSourceWarnings :: LoadedSource -> [Diagnostic]
loadedSourceWarnings source = sourceWarnings (loadedSourceRelativePath source) (loadedSourceText source)

encodeCoreOutcome :: [Diagnostic] -> CoreModule -> IO FrontendOutcome
encodeCoreOutcome warnings core = pure $ case encodeCore defaultCoreWireLimits core of
    Left issue -> FrontendFailure ("could not encode verified Core: " ++ show issue)
    Right bytes -> FrontendSuccess CoreWireOutput (ByteString.pack bytes) warnings
