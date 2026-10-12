-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Filesystem ownership for Tala source compilation.

The Kotlin project evaluator deliberately emits roots and exclusion policy,
not a list of source files. This module is the compiler-owned boundary that
turns that policy into deterministic, UTF-8 decoded compilation units. It is
kept outside the lexer so filesystem failures cannot masquerade as lexical
diagnostics and outside the native driver so namespace discovery remains a
Haskell frontend responsibility.
-}
module Progmasoft.Tala.SourceSet
    ( SourceSetRequest (..)
    , LoadedSource (..)
    , discoverSourceSet
    , loadSourceFile
    , loadSourceSet
    , matchesGlob
    , normalizeSourcePath
    ) where

import Control.Exception (IOException, try)
import Control.Monad (foldM)
import Data.ByteString qualified as ByteString
import Data.Char (toLower)
import Data.List (nubBy, sortOn)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import System.Directory
    ( canonicalizePath
    , doesDirectoryExist
    , doesFileExist
    , listDirectory
    , pathIsSymbolicLink
    )
import System.FilePath
    ( isAbsolute
    , makeRelative
    , normalise
    , splitDirectories
    , takeExtension
    , takeFileName
    , (</>)
    )
import System.Info (os)
import Progmasoft.Tala.Diagnostic

{- | All paths crossing this record may be absolute or relative. Relative roots
are interpreted from 'sourceSetProjectRoot', never from an incidental process
directory after discovery has started.
-}
data SourceSetRequest = SourceSetRequest
    { sourceSetProjectRoot :: FilePath
    , sourceSetRoots :: [FilePath]
    , sourceSetExcludes :: [FilePath]
    }
    deriving (Eq, Ord, Read, Show)

{- | The canonical path is used for diagnostics and de-duplication. The
project-relative path is the stable ordering/exclusion identity. Source text
is decoded strictly as UTF-8 before the lexer sees it.
-}
data LoadedSource = LoadedSource
    { loadedSourcePath :: FilePath
    , loadedSourceRelativePath :: FilePath
    , loadedSourceText :: String
    }
    deriving (Eq, Ord, Read, Show)

data DiscoveredFile = DiscoveredFile
    { discoveredCanonicalPath :: FilePath
    , discoveredRelativePath :: FilePath
    }
    deriving (Eq, Ord, Read, Show)

data WalkState = WalkState
    { walkVisitedDirectories :: [FilePath]
    , walkFiles :: [DiscoveredFile]
    , walkProblems :: [Diagnostic]
    }

emptyWalkState :: WalkState
emptyWalkState = WalkState [] [] []

{- | Load one explicit @-File@ input through the same strict decoder used by
project compilation. File mode does not invent a project root or apply glob
policy, but it still rejects directories, wrong extensions, and malformed
UTF-8 at the source boundary.
-}
loadSourceFile :: FilePath -> IO (Either [Diagnostic] LoadedSource)
loadSourceFile path = do
    canonical <- tryCanonical path
    case canonical of
        Left issue -> pure (Left [sourceProblem "TAS0001" ("cannot resolve source file '" ++ path ++ "': " ++ issue)])
        Right canonicalPath -> do
            exists <- safeDoesFileExist canonicalPath
            if not exists
                then pure (Left [sourceProblem "TAS0002" ("source file does not exist: " ++ canonicalPath)])
                else
                    if takeExtension canonicalPath /= ".tala"
                        then pure (Left [sourceProblem "TAS0003" ("source file must use the case-sensitive .tala extension: " ++ canonicalPath)])
                        else do
                            workingDirectory <- tryCanonical "."
                            let sourceIdentity = case workingDirectory of
                                    Right root
                                        | isContainedBy root canonicalPath -> relativeTo root canonicalPath
                                    _ -> takeFileName canonicalPath
                            decodeSource canonicalPath sourceIdentity

{- | Discover, validate, de-duplicate, sort, and decode a project source set.
A failure in any configured root makes the whole source set invalid; silently
compiling a partial project would make diagnostics dependent on permissions,
junction state, or traversal order.
-}
discoverSourceSet :: SourceSetRequest -> IO (Either [Diagnostic] [FilePath])
discoverSourceSet request = fmap (fmap (map discoveredCanonicalPath)) (discoverSourceFiles request)

{- | Discover project sources and strictly decode each file as UTF-8.
Any discovery or decoding failure rejects the complete set rather than
returning a partial compilation input.
-}
loadSourceSet :: SourceSetRequest -> IO (Either [Diagnostic] [LoadedSource])
loadSourceSet request = do
    discovered <- discoverSourceFiles request
    case discovered of
        Left problems -> pure (Left problems)
        Right files -> do
            decoded <- mapM decodeDiscovered files
            let decodeProblems = concat [problems | Left problems <- decoded]
                sources = [source | Right source <- decoded]
            pure $ if null decodeProblems then Right sources else Left decodeProblems
    where
        decodeDiscovered file =
            decodeSource (discoveredCanonicalPath file) (discoveredRelativePath file)

{- | Discover source identities without opening their contents. Formatting and
linting own their input encoding, so project-wide tool dispatch must not make
the compiler's UTF-8 source decoder an accidental gate before the tool runs.
Compilation still calls 'loadSourceSet' and therefore remains strict UTF-8.
-}
discoverSourceFiles :: SourceSetRequest -> IO (Either [Diagnostic] [DiscoveredFile])
discoverSourceFiles request = do
    canonicalProject <- tryCanonical (sourceSetProjectRoot request)
    case canonicalProject of
        Left problem -> pure (Left [sourceProblem "TAS0004" ("cannot resolve project root: " ++ problem)])
        Right projectRoot -> do
            projectExists <- safeDoesDirectoryExist projectRoot
            if not projectExists
                then pure (Left [sourceProblem "TAS0005" ("project root is not a directory: " ++ projectRoot)])
                else discoverFromRoots projectRoot request

discoverFromRoots :: FilePath -> SourceSetRequest -> IO (Either [Diagnostic] [DiscoveredFile])
discoverFromRoots projectRoot request
    | null (sourceSetRoots request) = pure (Left [sourceProblem "TAS0006" "project has no configured source roots"])
    | otherwise = do
        walked <- foldM (walkConfiguredRoot projectRoot patterns) emptyWalkState (sourceSetRoots request)
        let unique = uniqueFiles (walkFiles walked)
            ordered = sortOn (pathOrderingKey . discoveredRelativePath) unique
            discoveryProblems = reverse (walkProblems walked)
        pure $
            if not (null discoveryProblems)
                then Left discoveryProblems
                else
                    if null ordered
                        then Left [sourceProblem "TAS0007" "configured source roots contain no non-excluded .tala files"]
                        else Right ordered
    where
        patterns = map normalizePattern (sourceSetExcludes request)

walkConfiguredRoot :: FilePath -> [String] -> WalkState -> FilePath -> IO WalkState
walkConfiguredRoot projectRoot patterns state configuredRoot = do
    let rooted = if isAbsolute configuredRoot then configuredRoot else projectRoot </> configuredRoot
    canonical <- tryCanonical rooted
    case canonical of
        Left problem -> pure (addProblem state "TAS0008" ("cannot resolve source root '" ++ configuredRoot ++ "': " ++ problem))
        Right sourceRoot ->
            if not (isContainedBy projectRoot sourceRoot)
                then pure (addProblem state "TAS0009" ("source root escapes the project root: " ++ sourceRoot))
                else do
                    exists <- safeDoesDirectoryExist sourceRoot
                    if not exists
                        then pure (addProblem state "TAS0010" ("source root is not a directory: " ++ sourceRoot))
                        else walkDirectory projectRoot patterns state sourceRoot

walkDirectory :: FilePath -> [String] -> WalkState -> FilePath -> IO WalkState
walkDirectory projectRoot patterns state directory = do
    canonical <- tryCanonical directory
    case canonical of
        Left problem -> pure (addProblem state "TAS0011" ("cannot resolve directory '" ++ directory ++ "': " ++ problem))
        Right canonicalDirectory
            | not (isContainedBy projectRoot canonicalDirectory) ->
                pure (addProblem state "TAS0012" ("source traversal escapes the project root: " ++ canonicalDirectory))
            | pathMember canonicalDirectory (walkVisitedDirectories state) ->
                pure state
            | excluded patterns (relativeTo projectRoot canonicalDirectory) True ->
                pure state
            | otherwise -> do
                entries <- tryListDirectory canonicalDirectory
                case entries of
                    Left problem -> pure (addProblem state "TAS0013" ("cannot enumerate source directory '" ++ canonicalDirectory ++ "': " ++ problem))
                    Right names -> do
                        let entered = state {walkVisitedDirectories = canonicalDirectory : walkVisitedDirectories state}
                        foldM (walkEntry projectRoot patterns canonicalDirectory) entered (sortOn pathOrderingKey names)

walkEntry :: FilePath -> [String] -> FilePath -> WalkState -> FilePath -> IO WalkState
walkEntry projectRoot patterns parent state name = do
    let candidate = parent </> name
    directory <- safeDoesDirectoryExist candidate
    file <- safeDoesFileExist candidate
    symbolic <- safePathIsSymbolicLink candidate
    if directory
        then do
            canonical <- tryCanonical candidate
            case canonical of
                Left problem -> pure (addProblem state "TAS0014" ("cannot resolve source directory '" ++ candidate ++ "': " ++ problem))
                Right target
                    | symbolic && not (isContainedBy projectRoot target) ->
                        pure (addProblem state "TAS0015" ("source directory link escapes the project root: " ++ candidate))
                    | otherwise -> walkDirectory projectRoot patterns state target
        else
            if file
                then considerFile projectRoot patterns state candidate symbolic
                else pure state

considerFile :: FilePath -> [String] -> WalkState -> FilePath -> Bool -> IO WalkState
considerFile projectRoot patterns state candidate symbolic = do
    canonical <- tryCanonical candidate
    case canonical of
        Left problem -> pure (addProblem state "TAS0016" ("cannot resolve source file '" ++ candidate ++ "': " ++ problem))
        Right canonicalFile
            | symbolic && not (isContainedBy projectRoot canonicalFile) ->
                pure (addProblem state "TAS0017" ("source file link escapes the project root: " ++ candidate))
            | not (isContainedBy projectRoot canonicalFile) ->
                pure (addProblem state "TAS0018" ("source file escapes the project root: " ++ canonicalFile))
            | takeExtension candidate /= ".tala" -> pure state
            | excluded patterns relative False -> pure state
            | otherwise ->
                pure state {walkFiles = DiscoveredFile canonicalFile relative : walkFiles state}
            where
                relative = relativeTo projectRoot canonicalFile

decodeSource :: FilePath -> FilePath -> IO (Either [Diagnostic] LoadedSource)
decodeSource canonicalPath relativePath = do
    bytes <- try (ByteString.readFile canonicalPath) :: IO (Either IOException ByteString.ByteString)
    pure $ case bytes of
        Left problem -> Left [sourceProblem "TAS0019" ("cannot read source file '" ++ canonicalPath ++ "': " ++ show problem)]
        Right content -> case Text.decodeUtf8' content of
            Left problem -> Left [sourceProblem "TAS0020" ("source file is not valid UTF-8: " ++ canonicalPath ++ " (" ++ show problem ++ ")")]
            Right text -> Right (LoadedSource canonicalPath (normalizeSourcePath relativePath) (Text.unpack text))

{- | Match a normalized project-relative path against a glob. @*@ and @?@ stay
within one path segment; a segment consisting of @**@ consumes zero or more
complete segments. This deliberately small grammar is deterministic across
Windows and Unix and is sufficient for the DSL's source exclusion policy.
-}
matchesGlob :: FilePath -> FilePath -> Bool
matchesGlob rawPattern rawPath = matchSegments (segments (normalizePattern rawPattern)) (segments (normalizeSourcePath rawPath))

matchSegments :: [String] -> [String] -> Bool
matchSegments [] [] = True
matchSegments [] _ = False
matchSegments ("**" : remaining) values =
    matchSegments remaining values
        || case values of
            [] -> False
            _ : rest -> matchSegments ("**" : remaining) rest
matchSegments (_ : _) [] = False
matchSegments (patternSegment : remainingPatterns) (pathSegment : remainingPaths) =
    matchSegment patternSegment pathSegment
        && matchSegments remainingPatterns remainingPaths

matchSegment :: String -> String -> Bool
matchSegment [] [] = True
matchSegment [] _ = False
matchSegment ('*' : patternRest) value =
    matchSegment patternRest value
        || case value of
            [] -> False
            _ : valueRest -> matchSegment ('*' : patternRest) valueRest
matchSegment ('?' : patternRest) (_ : valueRest) = matchSegment patternRest valueRest
matchSegment ('?' : _) [] = False
matchSegment (expected : patternRest) (actual : valueRest) =
    pathCharacterEqual expected actual && matchSegment patternRest valueRest
matchSegment (_ : _) [] = False

excluded :: [String] -> FilePath -> Bool -> Bool
excluded patterns relative directory =
    any (matchesCandidate normalized) patterns
    where
        normalized = normalizeSourcePath relative
        -- A directory pattern without an explicit descendant wildcard owns the
        -- directory itself and therefore prunes its complete subtree.
        candidates = if directory then [normalized, normalized ++ "/"] else [normalized]
        matchesCandidate path pattern =
            any (matchesGlob pattern) candidates
                || (directory && matchesGlob (trimTrailingSlash pattern ++ "/**") path)

normalizePattern :: FilePath -> String
normalizePattern value =
    let normalized = dropCurrentPrefix (normalizeSourcePath value)
     in trimTrailingSlash normalized

{- | Normalize separators and redundant path syntax to a stable slash form.
Path comparison applies platform-specific case handling separately.
-}
normalizeSourcePath :: FilePath -> String
normalizeSourcePath = collapseSlashes . map slash . normalise
    where
        slash '\\' = '/'
        slash value = value

collapseSlashes :: String -> String
collapseSlashes [] = []
collapseSlashes ('/' : '/' : remaining) = collapseSlashes ('/' : remaining)
collapseSlashes (value : remaining) = value : collapseSlashes remaining

dropCurrentPrefix :: String -> String
dropCurrentPrefix ('.' : '/' : remaining) = dropCurrentPrefix remaining
dropCurrentPrefix value = dropWhile (== '/') value

trimTrailingSlash :: String -> String
trimTrailingSlash = reverse . dropWhile (== '/') . reverse

segments :: String -> [String]
segments value = filter (not . null) (splitOnSlash value)

splitOnSlash :: String -> [String]
splitOnSlash [] = [[]]
splitOnSlash ('/' : remaining) = [] : splitOnSlash remaining
splitOnSlash (value : remaining) = case splitOnSlash remaining of
    [] -> [[value]]
    first : rest -> (value : first) : rest

relativeTo :: FilePath -> FilePath -> FilePath
relativeTo root path = normalizeSourcePath (makeRelative root path)

isContainedBy :: FilePath -> FilePath -> Bool
isContainedBy root path =
    let relative = normalise (makeRelative root path)
        parts = splitDirectories relative
     in not (isAbsolute relative) && case parts of
            ".." : _ -> False
            _ -> relative /= ".."

uniqueFiles :: [DiscoveredFile] -> [DiscoveredFile]
uniqueFiles = nubBy (\left right -> pathEqual (discoveredCanonicalPath left) (discoveredCanonicalPath right))

pathMember :: FilePath -> [FilePath] -> Bool
pathMember value = any (pathEqual value)

pathEqual :: FilePath -> FilePath -> Bool
pathEqual left right = pathOrderingKey left == pathOrderingKey right

pathOrderingKey :: FilePath -> String
pathOrderingKey value
    | os == "mingw32" = map toLower (normalizeSourcePath value)
    | otherwise = normalizeSourcePath value

pathCharacterEqual :: Char -> Char -> Bool
pathCharacterEqual left right
    | os == "mingw32" = toLower left == toLower right
    | otherwise = left == right

tryCanonical :: FilePath -> IO (Either String FilePath)
tryCanonical path = do
    result <- try (canonicalizePath path) :: IO (Either IOException FilePath)
    pure (either (Left . show) (Right . normalise) result)

tryListDirectory :: FilePath -> IO (Either String [FilePath])
tryListDirectory path = do
    result <- try (listDirectory path) :: IO (Either IOException [FilePath])
    pure (either (Left . show) Right result)

safeDoesDirectoryExist :: FilePath -> IO Bool
safeDoesDirectoryExist path = do
    result <- try (doesDirectoryExist path) :: IO (Either IOException Bool)
    pure (either (const False) id result)

safeDoesFileExist :: FilePath -> IO Bool
safeDoesFileExist path = do
    result <- try (doesFileExist path) :: IO (Either IOException Bool)
    pure (either (const False) id result)

safePathIsSymbolicLink :: FilePath -> IO Bool
safePathIsSymbolicLink path = do
    result <- try (pathIsSymbolicLink path) :: IO (Either IOException Bool)
    pure (either (const False) id result)

addProblem :: WalkState -> String -> String -> WalkState
addProblem state code message = state {walkProblems = sourceProblem code message : walkProblems state}

sourceProblem :: String -> String -> Diagnostic
sourceProblem code message = Diagnostic SourceLoaderStage Error code Nothing message
