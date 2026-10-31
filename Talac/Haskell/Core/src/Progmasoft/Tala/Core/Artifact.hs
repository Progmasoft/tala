-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Bounded, verified persistence for standalone Core artifacts.
Readers decode and semantically verify before returning a module; writers
verify before encoding so invalid compiler state never becomes a trusted file.
-}
module Progmasoft.Tala.Core.Artifact
    ( CoreArtifactError (..)
    , readCoreArtifact
    , readCoreArtifactWith
    , writeCoreArtifact
    , writeCoreArtifactWith
    ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import System.FilePath (takeExtension)
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Core.Wire
import Progmasoft.Tala.Diagnostic (diagnosticCode, diagnosticMessage)

-- | Path, wire, semantic, or filesystem failure while handling a Core file.
data CoreArtifactError
    = -- | Artifact path does not use the required @.core@ extension.
      InvalidCoreArtifactPath FilePath
    | -- | The byte document failed wire decoding or encoding.
      CoreArtifactWireError CoreWireError
    | -- | Decoded Core failed semantic verification.
      CoreArtifactVerificationError [String]
    | -- | Filesystem operation failed at this path.
      CoreArtifactIOError FilePath String
    deriving (Eq, Ord, Read, Show)

-- | Read, decode, and verify a Core artifact using default wire ceilings.
readCoreArtifact :: FilePath -> IO (Either CoreArtifactError CoreModule)
readCoreArtifact = readCoreArtifactWith defaultCoreWireLimits

-- | Read and verify a Core artifact under caller-selected resource limits.
readCoreArtifactWith :: CoreWireLimits -> FilePath -> IO (Either CoreArtifactError CoreModule)
readCoreArtifactWith limits path
    | takeExtension path /= ".core" = pure (Left (InvalidCoreArtifactPath path))
    | otherwise = do
        loaded <- try (ByteString.readFile path) :: IO (Either IOException ByteString.ByteString)
        pure $ case loaded of
            Left issue -> Left (CoreArtifactIOError path (show issue))
            Right bytes -> case decodeCore limits (ByteString.unpack bytes) of
                Left issue -> Left (CoreArtifactWireError issue)
                Right moduleValue -> verify moduleValue

-- | Verify and write a Core module using default wire ceilings.
writeCoreArtifact :: FilePath -> CoreModule -> IO (Either CoreArtifactError ())
writeCoreArtifact = writeCoreArtifactWith defaultCoreWireLimits

-- | Verify and write a Core module under caller-selected resource limits.
writeCoreArtifactWith :: CoreWireLimits -> FilePath -> CoreModule -> IO (Either CoreArtifactError ())
writeCoreArtifactWith limits path moduleValue
    | takeExtension path /= ".core" = pure (Left (InvalidCoreArtifactPath path))
    | otherwise = case verify moduleValue >>= encode of
        Left issue -> pure (Left issue)
        Right bytes -> do
            written <- try (ByteString.writeFile path (ByteString.pack bytes)) :: IO (Either IOException ())
            pure $ either (Left . CoreArtifactIOError path . show) (const (Right ())) written
    where
        encode value = either (Left . CoreArtifactWireError) Right (encodeCore limits value)

verify :: CoreModule -> Either CoreArtifactError CoreModule
verify moduleValue = case verifyCore moduleValue of
    Left problems -> Left (CoreArtifactVerificationError (map diagnosticText problems))
    Right verified -> Right verified
    where
        diagnosticText diagnostic = diagnosticCode diagnostic ++ ": " ++ diagnosticMessage diagnostic
