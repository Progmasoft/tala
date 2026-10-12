-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
{-# LANGUAGE ForeignFunctionInterface #-}

{- | C ABI entry points for the in-process native driver. Every pointer from
the caller is length-bounded and copied before decoding. Output memory remains
owned by a strict ByteString and is borrowed only for the synchronous callback,
so no Haskell heap pointer or allocator crosses the ABI boundary.
-}
module Progmasoft.Tala.Driver.FFI
    ( frontendAbiVersion
    , frontendExecute
    , frontendCompileSource
    , frontendFuzzSyntax
    , frontendFuzzCompile
    ) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word (Word32, Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr)
import System.Environment (lookupEnv)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core.CorePrep.Wire (encodeCorePrep)
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Diagnostic.SideChannel
import Progmasoft.Tala.Driver.Command
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Lexer

type OutputCallback = Ptr () -> Word32 -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall "dynamic"
    callOutputCallback :: FunPtr OutputCallback -> OutputCallback

foreign export ccall "tala_frontend_abi_version"
    frontendAbiVersion :: IO Word32

foreign export ccall "tala_frontend_execute"
    frontendExecute :: Ptr Word8 -> CSize -> FunPtr OutputCallback -> Ptr () -> IO CInt

foreign export ccall "tala_frontend_compile_source"
    frontendCompileSource :: Ptr Word8 -> CSize -> FunPtr OutputCallback -> Ptr () -> IO CInt

foreign export ccall "tala_frontend_fuzz_syntax"
    frontendFuzzSyntax :: Word32 -> Ptr Word8 -> CSize -> IO CInt

foreign export ccall "tala_frontend_fuzz_compile"
    frontendFuzzCompile :: Ptr Word8 -> CSize -> FunPtr OutputCallback -> Ptr () -> IO CInt

frontendAbiVersion :: IO Word32
frontendAbiVersion = pure 2

frontendExecute :: Ptr Word8 -> CSize -> FunPtr OutputCallback -> Ptr () -> IO CInt
frontendExecute argumentPointer argumentSize callback context =
    withCaughtFailure callback context $ do
        arguments <- readArgumentBlob argumentPointer argumentSize
        case arguments of
            Left message -> emitBytes callback context 3 (Text.encodeUtf8 (Text.pack message)) >> pure (CInt 2)
            Right values -> do
                outcome <- runFrontendArguments values
                case outcome of
                    FrontendSuccess kind bytes warnings -> do
                        sideChannel <- writeDiagnosticSideChannel warnings
                        case sideChannel of
                            Left issue -> emitBytes callback context 3 (Text.encodeUtf8 (Text.pack (show issue))) >> pure (CInt 3)
                            Right () -> do
                                -- Warnings precede the payload: the receiver
                                -- accepts them only while no result exists.
                                warned <-
                                    if null warnings
                                        then pure True
                                        else emitBytes callback context warningTextKind (Text.encodeUtf8 (Text.pack (renderDiagnostics warnings)))
                                delivered <-
                                    if warned
                                        then emitBytes callback context (fromIntegral (fromEnum kind)) bytes
                                        else pure False
                                pure (if delivered then CInt 0 else CInt 4)
                    FrontendDiagnostics diagnostics -> do
                        sideChannel <- writeDiagnosticSideChannel diagnostics
                        case sideChannel of
                            Left issue -> emitBytes callback context 3 (Text.encodeUtf8 (Text.pack (show issue))) >> pure (CInt 3)
                            Right () -> do
                                delivered <- emitBytes callback context 3 (Text.encodeUtf8 (Text.pack (renderDiagnostics diagnostics)))
                                pure (if delivered then CInt 1 else CInt 4)
                    FrontendFailure message -> do
                        delivered <- emitBytes callback context 3 (Text.encodeUtf8 (Text.pack message))
                        pure (if delivered then CInt 2 else CInt 4)

-- The native REPL and coverage-guided harness share this memory-only route.
-- Diagnostics are ordinary results; only an internal failure trips fuzzing.
frontendCompileSource :: Ptr Word8 -> CSize -> FunPtr OutputCallback -> Ptr () -> IO CInt
frontendCompileSource sourcePointer sourceSize callback context =
    withCaughtFailure callback context $ do
        copied <- readSource sourcePointer sourceSize
        case copied of
            Left message -> emitResult callback context (CInt 2) message
            Right source -> case Text.decodeUtf8' source of
                Left _ -> emitResult callback context (CInt 1) "source is not valid UTF-8"
                Right decoded ->
                    case compileToCorePrep (CompilerInput "<memory>.tala" (Text.unpack decoded)) of
                        Left diagnostics -> emitBytesResult callback context (CInt 1) 3 (renderDiagnostics diagnostics)
                        Right artifacts -> case encodeCore defaultCoreWireLimits (artifactOptimizedCore artifacts) of
                            Left issue -> emitBytesResult callback context (CInt 3) 3 (show issue)
                            Right bytes -> do
                                delivered <- emitBytes callback context 0 (ByteString.pack bytes)
                                pure (if delivered then CInt 0 else CInt 4)

frontendFuzzSyntax :: Word32 -> Ptr Word8 -> CSize -> IO CInt
frontendFuzzSyntax stage sourcePointer sourceSize
    | stage > 1 = pure (CInt 2)
    | otherwise = do
        -- Never let a lazy AST exception escape a foreign export into C++.
        -- Force the complete result, not just the Either constructor/list spine.
        outcome <- try syntaxAction :: IO (Either SomeException CInt)
        pure (either (const (CInt 3)) id outcome)
    where
        syntaxAction = do
            copied <- readSource sourcePointer sourceSize
            case copied of
                Left _ -> pure (CInt 0)
                Right source -> case Text.decodeUtf8' source of
                    Left _ -> pure (CInt 0)
                    Right decoded -> do
                        let text = Text.unpack decoded
                            input = CompilerInput "<fuzz>.tala" text
                        case stage of
                            0 -> do
                                let tokenized = runLexer defaultLexer (LexerInput "<fuzz>.tala" text)
                                _ <- evaluate (length (show tokenized))
                                pure (CInt 0)
                            _ -> do
                                _ <- evaluate (length (show (analyzeSyntax input)))
                                pure (CInt 0)

{- | Testing entry: compile like the in-memory source route and additionally
hand out the frontend's own CorePrep lowering of the same optimized Core. The
native pipeline derives CorePrep from Core with its own adapter; delivering both
artifacts of one compilation lets a harness compare the two lowerings instead
of trusting either. Core is delivered first and CorePrep second; a rejected
callback stops the sequence. Production entries never emit CorePrep.
-}
frontendFuzzCompile :: Ptr Word8 -> CSize -> FunPtr OutputCallback -> Ptr () -> IO CInt
frontendFuzzCompile sourcePointer sourceSize callback context =
    withCaughtFailure callback context $ do
        copied <- readSource sourcePointer sourceSize
        case copied of
            Left message -> emitResult callback context (CInt 2) message
            Right source -> case Text.decodeUtf8' source of
                Left _ -> emitResult callback context (CInt 1) "source is not valid UTF-8"
                Right decoded ->
                    case compileToCorePrep (CompilerInput "<memory>.tala" (Text.unpack decoded)) of
                        Left diagnostics -> emitBytesResult callback context (CInt 1) 3 (renderDiagnostics diagnostics)
                        Right artifacts ->
                            case ( encodeCore defaultCoreWireLimits (artifactOptimizedCore artifacts)
                                 , encodeCorePrep (artifactCorePrep artifacts)
                                 ) of
                                (Left issue, _) -> emitBytesResult callback context (CInt 3) 3 (show issue)
                                (_, Left issue) -> emitBytesResult callback context (CInt 3) 3 (show issue)
                                (Right core, Right corePrep) -> do
                                    coreDelivered <- emitBytes callback context 0 (ByteString.pack core)
                                    prepDelivered <-
                                        if coreDelivered
                                            then emitBytes callback context 4 (ByteString.pack corePrep)
                                            else pure False
                                    pure (if prepDelivered then CInt 0 else CInt 4)

emitResult :: FunPtr OutputCallback -> Ptr () -> CInt -> String -> IO CInt
emitResult callback context status message =
    emitBytesResult callback context status 3 message

emitBytesResult :: FunPtr OutputCallback -> Ptr () -> CInt -> Word32 -> String -> IO CInt
emitBytesResult callback context status kind message = do
    delivered <- emitBytes callback context kind (Text.encodeUtf8 (Text.pack message))
    pure (if delivered then status else CInt 4)

readArgumentBlob :: Ptr Word8 -> CSize -> IO (Either String [String])
readArgumentBlob pointer size
    | size == 0 = pure (Left "private frontend argument list is empty")
    | size > 1024 * 1024 = pure (Left "private frontend argument list exceeds 1 MiB")
    | pointer == nullPtr = pure (Left "private frontend argument pointer is null")
    | otherwise = do
        bytes <- ByteString.packCStringLen (castPtr pointer, fromIntegral size)
        if ByteString.last bytes /= 0
            then pure (Left "private frontend argument list is not NUL-terminated")
            else case Text.decodeUtf8' bytes of
                Left _ -> pure (Left "private frontend arguments are not valid UTF-8")
                Right decoded ->
                    let values = init (splitNul (Text.unpack decoded))
                     in pure $
                            if null values || any null values || length values > 1024
                                then Left "private frontend argument list has an empty or excessive argument"
                                else Right values

readSource :: Ptr Word8 -> CSize -> IO (Either String ByteString.ByteString)
readSource pointer size
    | size > 1024 * 1024 = pure (Left "fuzz source exceeds 1 MiB")
    | size > 0 && pointer == nullPtr = pure (Left "fuzz source pointer is null")
    | size == 0 = pure (Right ByteString.empty)
    | otherwise = Right <$> ByteString.packCStringLen (castPtr pointer, fromIntegral size)

splitNul :: String -> [String]
splitNul [] = [""]
splitNul ('\0' : remaining) = "" : splitNul remaining
splitNul (value : remaining) = case splitNul remaining of
    [] -> [[value]]
    first : rest -> (value : first) : rest

emitBytes :: FunPtr OutputCallback -> Ptr () -> Word32 -> ByteString.ByteString -> IO Bool
emitBytes callback context kind bytes =
    ByteString.useAsCStringLen bytes $ \(pointer, size) -> do
        let outputPointer = if size == 0 then nullPtr else castPtr pointer
        result <- callOutputCallback callback context kind outputPointer (fromIntegral size)
        pure (result == 0)

-- Public terminal text is returned in the callback. The stable binary
-- diagnostic document remains available through the explicit opt-in path, so
-- the in-process compiler never creates a file merely to print an error.
writeDiagnosticSideChannel :: [Diagnostic] -> IO (Either String ())
writeDiagnosticSideChannel diagnostics = do
    configuredPath <- lookupEnv "TALA_DIAGNOSTICS_FILE"
    case configuredPath of
        Nothing -> pure (Right ())
        Just "" -> pure (Left "TALA_DIAGNOSTICS_FILE must not be empty")
        Just path -> do
            written <- writeDiagnosticFile path diagnostics
            pure (either (Left . show) Right written)

-- Output kind 5 of the C ABI: warning text that accompanies a successful
-- result. It is not a constructor of 'FrontendOutputKind' because it is never
-- the result of a request.
warningTextKind :: Word32
warningTextKind = 5

renderDiagnostics :: [Diagnostic] -> String
renderDiagnostics = unlines . map renderDiagnostic
    where
        renderDiagnostic diagnostic =
            maybe "" renderLocation (diagnosticSpan diagnostic)
                ++ (if diagnosticSeverity diagnostic == Warning then "warning " else "")
                ++ diagnosticCode diagnostic
                ++ ": "
                ++ diagnosticMessage diagnostic
        renderLocation source =
            sourceFile source
                ++ ":"
                ++ show (sourceLine (sourceStart source))
                ++ ":"
                ++ show (sourceColumn (sourceStart source))
                ++ ": "

withCaughtFailure :: FunPtr OutputCallback -> Ptr () -> IO CInt -> IO CInt
withCaughtFailure callback context action = do
    result <- try action :: IO (Either SomeException CInt)
    case result of
        Right status -> pure status
        Left exception -> do
            _ <- emitBytes callback context 3 (Text.encodeUtf8 (Text.pack (displayException exception)))
            pure (CInt 3)
