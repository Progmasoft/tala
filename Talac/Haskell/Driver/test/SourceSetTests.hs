-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module SourceSetTests (sourceSetTests) where

import Control.Exception (finally)
import Data.ByteString qualified as ByteString
import Data.List (sort)
import System.Directory
    ( canonicalizePath
    , createDirectory
    , createDirectoryIfMissing
    , getTemporaryDirectory
    , removeDirectoryRecursive
    , removeFile
    )
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, openTempFile)
import System.Info (os)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.SourceSet

sourceSetTests :: [(String, IO Bool)]
sourceSetTests =
    [ ("source globs distinguish segments and recursive wildcards", pure globSemantics)
    , ("source loader discovers deterministic project-relative order", discoveryOrder)
    , ("source loader applies project-relative exclusions", exclusionPolicy)
    , ("overlapping source roots do not duplicate compilation units", overlappingRoots)
    , ("uppercase source extensions are not treated as .tala", caseSensitiveExtension)
    , ("malformed UTF-8 is rejected before lexing", invalidUtf8)
    , ("tool source discovery does not impose compiler UTF-8", encodingNeutralDiscovery)
    , ("explicit file mode uses the strict source decoder", explicitFileDecoder)
    , ("explicit file mode requires the exact .tala extension", explicitFileExtension)
    , ("explicit file compilation uses a safe relative Core identity", explicitFileIdentity)
    , ("a configured source root cannot escape the project", escapingRoot)
    , ("an empty discovered source set is diagnosed", emptySourceSet)
    , ("project compiler merges files that declare one namespace", namespaceMerge)
    , ("project Core keeps every source and one owner per function", sourceOwnership)
    , ("source ownership survives the versioned Core wire round trip", sourceOwnershipWireRoundTrip)
    , ("project source paths use portable relative spelling", portableProjectSourcePaths)
    , ("empty namespace source files remain in the project catalog", emptyNamespaceSourceIsRetained)
    , ("project compiler selects entry by namespace and class", entrySelection)
    , ("project compiler validates every namespace", validatesEveryNamespace)
    , ("project compiler accumulates independent file diagnostics", accumulatesFileDiagnostics)
    , ("duplicate types across physical files are rejected", duplicateAcrossFiles)
    , ("missing entry namespaces are diagnosed", missingEntryNamespace)
    , ("entry names must include a namespace", unqualifiedEntry)
    , ("entry Main remains public static void across merged units", mergedEntryContract)
    ]

globSemantics :: Bool
globSemantics =
    and
        [ matchesGlob "Sources/**/*.tala" "Sources/Main.tala"
        , matchesGlob "Sources/**/*.tala" "Sources/Talac/Parser.tala"
        , matchesGlob "Sources/Generated/**" "Sources/Generated/Nested/File.tala"
        , matchesGlob "Sources/?ain.tala" "Sources/Main.tala"
        , matchesGlob "Sources/*.tala" "Sources/Main.tala"
        , not (matchesGlob "Sources/*.tala" "Sources/Nested/Main.tala")
        , if os == "mingw32"
            then matchesGlob "Sources/Main.tala" "Sources/main.tala"
            else not (matchesGlob "Sources/Main.tala" "Sources/main.tala")
        , not (matchesGlob "Tests/**" "Sources/Tests/Main.tala")
        ]

discoveryOrder :: IO Bool
discoveryOrder = withTemporaryTree $ \root -> do
    writeSource root "Sources/Zeta.tala" minimalSource
    writeSource root "Sources/Alpha.tala" minimalSource
    writeSource root "Sources/Nested/Middle.tala" minimalSource
    result <- loadSourceSet (SourceSetRequest root ["Sources"] [])
    pure $ case result of
        Right sources ->
            map loadedSourceRelativePath sources
                == ["Sources/Alpha.tala", "Sources/Nested/Middle.tala", "Sources/Zeta.tala"]
        Left _ -> False

exclusionPolicy :: IO Bool
exclusionPolicy = withTemporaryTree $ \root -> do
    writeSource root "Sources/Main.tala" minimalSource
    writeSource root "Sources/Generated/Bindings.tala" "this would not parse"
    writeSource root "Sources/Skip.tala" "this would not parse"
    writeSource root "Sources/Nested/Keep.tala" minimalSource
    result <-
        loadSourceSet
            ( SourceSetRequest
                root
                ["Sources"]
                ["Sources/Generated/**", "Sources/Skip.tala"]
            )
    pure $ case result of
        Right sources ->
            map loadedSourceRelativePath sources
                == ["Sources/Main.tala", "Sources/Nested/Keep.tala"]
        Left _ -> False

overlappingRoots :: IO Bool
overlappingRoots = withTemporaryTree $ \root -> do
    writeSource root "Sources/Main.tala" minimalSource
    writeSource root "Sources/Nested/Helper.tala" minimalSource
    result <- loadSourceSet (SourceSetRequest root ["Sources", "Sources/Nested"] [])
    pure $ case result of
        Right sources ->
            map loadedSourceRelativePath sources
                == ["Sources/Main.tala", "Sources/Nested/Helper.tala"]
        Left _ -> False

caseSensitiveExtension :: IO Bool
caseSensitiveExtension = withTemporaryTree $ \root -> do
    writeSource root "Sources/Main.TALA" minimalSource
    result <- loadSourceSet (SourceSetRequest root ["Sources"] [])
    pure (hasDiagnostic "TAS0007" result)

invalidUtf8 :: IO Bool
invalidUtf8 = withTemporaryTree $ \root -> do
    let path = root </> "Sources" </> "Invalid.tala"
    createDirectoryIfMissing True (root </> "Sources")
    ByteString.writeFile path (ByteString.pack [0x63, 0x6c, 0x61, 0x73, 0x73, 0x20, 0xc3, 0x28])
    result <- loadSourceSet (SourceSetRequest root ["Sources"] [])
    pure (hasDiagnostic "TAS0020" result)

encodingNeutralDiscovery :: IO Bool
encodingNeutralDiscovery = withTemporaryTree $ \root -> do
    let path = root </> "Sources" </> "Utf16.tala"
    createDirectoryIfMissing True (root </> "Sources")
    ByteString.writeFile path (ByteString.pack [0xff, 0xfe, 0x63, 0x00])
    expected <- canonicalizePath path
    result <- discoverSourceSet (SourceSetRequest root ["Sources"] [])
    pure $ case result of
        Right [discovered] -> discovered == expected
        _ -> False

explicitFileDecoder :: IO Bool
explicitFileDecoder = withTemporaryTree $ \root -> do
    let path = root </> "Türkçe.tala"
    ByteString.writeFile path (ByteString.pack [0xc3, 0x28])
    result <- loadSourceFile path
    pure (hasDiagnostic "TAS0020" result)

explicitFileExtension :: IO Bool
explicitFileExtension = withTemporaryTree $ \root -> do
    let path = root </> "Main.TALA"
    writeFile path minimalSource
    result <- loadSourceFile path
    pure (hasDiagnostic "TAS0003" result)

explicitFileIdentity :: IO Bool
explicitFileIdentity = withTemporaryTree $ \root -> do
    writeSource root "Sources/Main.tala" minimalSource
    let path = root </> "Sources" </> "Main.tala"
    loaded <- loadSourceFile path
    pure $ case loaded of
        Left _ -> False
        Right source ->
            loadedSourceRelativePath source == "Main.tala"
                && case compileToCorePrep
                    (CompilerInput (loadedSourceRelativePath source) (loadedSourceText source)) of
                    Left _ -> False
                    Right artifacts ->
                        let owners = map snd (coreModuleFunctionSources (artifactOptimizedCore artifacts))
                         in not (null owners) && all (== "Main.tala") owners

escapingRoot :: IO Bool
escapingRoot = withTemporaryTree $ \root -> do
    let project = root </> "Project"
        outside = root </> "Outside"
    createDirectory project
    createDirectory outside
    writeSource outside "Escape.tala" minimalSource
    result <- loadSourceSet (SourceSetRequest project ["../Outside"] [])
    pure (hasDiagnostic "TAS0009" result)

emptySourceSet :: IO Bool
emptySourceSet = withTemporaryTree $ \root -> do
    createDirectoryIfMissing True (root </> "Sources")
    writeFile (root </> "Sources" </> "README.txt") "not source"
    result <- loadSourceSet (SourceSetRequest root ["Sources"] [])
    pure (hasDiagnostic "TAS0007" result)

namespaceMerge :: IO Bool
namespaceMerge = pure $ case compileProjectToCorePrep applicationEntry inputs of
    Right project ->
        length (projectNamespaces project) == 1
            && artifactSourceFiles (projectEntryNamespace project) == ["helper.tala", "main.tala"]
            && length (coreModuleFunctions (projectEntryCore project)) == 2
    Left _ -> False
    where
        inputs =
            [ CompilerInput "main.tala" applicationMain
            , CompilerInput "helper.tala" applicationHelper
            ]

-- Physical source ownership is carried beside semantic symbols. It must stay
-- deterministic as files are merged, lowered, and written to the Core wire.
sourceOwnership :: IO Bool
sourceOwnership = pure $ case compileProjectToCorePrep applicationEntry inputs of
    Right project ->
        let core = projectEntryCore project
            prepared = artifactCorePrep (artifactFrontend (projectEntryNamespace project))
            expectedSources = ["helper.tala", "main.tala"]
            owners = map snd (coreModuleFunctionSources core)
         in sort (coreModuleSourceFiles core) == expectedSources
                && sort (corePrepModuleSourceFiles prepared) == expectedSources
                && sort owners == expectedSources
                && sort (map corePrepFunctionSourceFile (corePrepModuleFunctions prepared)) == expectedSources
                && all (`elem` coreModuleSourceFiles core) owners
    Left _ -> False
    where
        inputs =
            [ CompilerInput "main.tala" applicationMain
            , CompilerInput "helper.tala" applicationHelper
            ]

sourceOwnershipWireRoundTrip :: IO Bool
sourceOwnershipWireRoundTrip = pure $ case compileProjectToCorePrep applicationEntry inputs of
    Right project ->
        let core = projectEntryCore project
         in case encodeCore defaultCoreWireLimits core >>= decodeCore defaultCoreWireLimits of
                Right decoded ->
                    coreModuleSourceFiles decoded == coreModuleSourceFiles core
                        && coreModuleFunctionSources decoded == coreModuleFunctionSources core
                        && decoded == core
                Left _ -> False
    Left _ -> False
    where
        inputs =
            [ CompilerInput "main.tala" applicationMain
            , CompilerInput "helper.tala" applicationHelper
            ]

portableProjectSourcePaths :: IO Bool
portableProjectSourcePaths = pure $ case compileProjectToCorePrep applicationEntry inputs of
    Right project ->
        let core = projectEntryCore project
            paths = coreModuleSourceFiles core ++ map snd (coreModuleFunctionSources core)
         in paths == ["Sources/helper.tala", "Sources/main.tala", "Sources/helper.tala", "Sources/main.tala"]
                && all (not . any (== '\\')) paths
    Left _ -> False
    where
        inputs =
            [ CompilerInput "Sources\\main.tala" applicationMain
            , CompilerInput "Sources\\helper.tala" applicationHelper
            ]

emptyNamespaceSourceIsRetained :: IO Bool
emptyNamespaceSourceIsRetained = pure $ case compileProjectToCorePrep applicationEntry inputs of
    Right project ->
        let core = projectEntryCore project
            prepared = artifactCorePrep (artifactFrontend (projectEntryNamespace project))
         in sort (coreModuleSourceFiles core) == ["empty.tala", "helper.tala", "main.tala"]
                && sort (corePrepModuleSourceFiles prepared) == ["empty.tala", "helper.tala", "main.tala"]
                && length (coreModuleFunctions core) == 2
    Left _ -> False
    where
        inputs =
            [ CompilerInput "main.tala" applicationMain
            , CompilerInput "helper.tala" applicationHelper
            , CompilerInput "empty.tala" "namespace Application;"
            ]

entrySelection :: IO Bool
entrySelection = pure $ case compileProjectToCorePrep applicationEntry inputs of
    Right project ->
        length (projectNamespaces project) == 2
            && artifactNamespace (projectEntryNamespace project) == Just applicationNamespace
            && coreModuleName (projectEntryCore project) == applicationNamespace
    Left _ -> False
    where
        inputs =
            [ CompilerInput "library.tala" "namespace Library; class Utility { public static int Value() { return 7; } }"
            , CompilerInput "main.tala" applicationMain
            ]

validatesEveryNamespace :: IO Bool
validatesEveryNamespace =
    pure $
        hasDiagnostic
            "TAN0001"
            ( compileProjectToCorePrep
                applicationEntry
                [ CompilerInput "main.tala" applicationMain
                , CompilerInput "broken.tala" "namespace Broken; class Utility { int Value() { return missing; } }"
                ]
            )

accumulatesFileDiagnostics :: IO Bool
accumulatesFileDiagnostics = pure $ case compileProjectToCorePrep applicationEntry inputs of
    Left diagnostics ->
        length diagnostics == 2
            && map (fmap sourceFile . diagnosticSpan) diagnostics
                == [Just "first.tala", Just "second.tala"]
    Right _ -> False
    where
        inputs =
            [ CompilerInput "first.tala" "namespace First; class One { void Run() { @; } }"
            , CompilerInput "second.tala" "namespace Second; class Two { void Run() { #; } }"
            ]

duplicateAcrossFiles :: IO Bool
duplicateAcrossFiles =
    pure $
        hasDiagnostic
            "TAR0001"
            ( compileProjectToCorePrep
                applicationEntry
                [ CompilerInput "first.tala" applicationMain
                , CompilerInput "second.tala" "namespace Application; class Program { public static void Main() { return; } }"
                ]
            )

missingEntryNamespace :: IO Bool
missingEntryNamespace =
    pure $
        hasDiagnostic
            "TAE0011"
            ( compileProjectToCorePrep
                (QualifiedName [Identifier "Missing", Identifier "Program"])
                [CompilerInput "main.tala" applicationMain]
            )

unqualifiedEntry :: IO Bool
unqualifiedEntry =
    pure $
        hasDiagnostic
            "TAE0001"
            ( compileProjectToCorePrep
                (QualifiedName [Identifier "Program"])
                [CompilerInput "main.tala" applicationMain]
            )

mergedEntryContract :: IO Bool
mergedEntryContract =
    pure $
        hasDiagnostic
            "TAE0008"
            ( compileProjectToCorePrep
                applicationEntry
                [ CompilerInput "helper.tala" applicationHelper
                , CompilerInput
                    "main.tala"
                    "namespace Application; class Program { public static int Main() { return 0; } }"
                ]
            )

applicationNamespace :: QualifiedName
applicationNamespace = QualifiedName [Identifier "Application"]

applicationEntry :: QualifiedName
applicationEntry = QualifiedName [Identifier "Application", Identifier "Program"]

applicationMain :: String
applicationMain =
    unlines
        [ "namespace Application;"
        , "class Program {"
        , "  public static void Main() {"
        , "    return;"
        , "  }"
        , "}"
        ]

applicationHelper :: String
applicationHelper =
    unlines
        [ "namespace Application;"
        , "class Helper {"
        , "  public static int Value() {"
        , "    return 42;"
        , "  }"
        , "}"
        ]

minimalSource :: String
minimalSource = "namespace Example; class Value { public static int Get() { return 1; } }"

hasDiagnostic :: String -> Either [Diagnostic] value -> Bool
hasDiagnostic code result = case result of
    Left diagnostics -> any ((== code) . diagnosticCode) diagnostics
    Right _ -> False

withTemporaryTree :: (FilePath -> IO Bool) -> IO Bool
withTemporaryTree action = do
    temporary <- getTemporaryDirectory
    (path, handle) <- openTempFile temporary "tala-source-set-"
    hClose handle
    removeFile path
    createDirectory path
    action path `finally` removeDirectoryRecursive path

writeSource :: FilePath -> FilePath -> String -> IO ()
writeSource root relative content = do
    let path = root </> relative
    createDirectoryIfMissing True (takeDirectory path)
    writeFile path content
