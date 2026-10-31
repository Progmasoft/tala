-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Write validated frontend diagnostics to the private native-driver channel.

The module never prints or chooses user-facing presentation; the C++ CLI owns
that policy and supplies a fresh destination for each compilation request.
-}
module Progmasoft.Tala.Diagnostic.SideChannel
    ( SideChannelError (..)
    , writeDiagnosticFile
    ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Diagnostic.Protocol

-- | Failure while validating, encoding, or writing a diagnostic document.
data SideChannelError
    = SideChannelModelError DiagnosticProtocolError
    | SideChannelEncodingError DiagnosticProtocolError
    | SideChannelWriteError FilePath String
    deriving (Eq, Ord, Read, Show)

-- The caller selects a fresh path for each compiler process. This function
-- converts the frontend's one-based source model, encodes the complete TADG
-- document in memory, and performs only one write after all validation passes.
-- It returns failures instead of printing because the native driver owns the
-- public presentation policy.

-- | Encode a complete diagnostic document before performing one file write.
writeDiagnosticFile :: FilePath -> [Diagnostic] -> IO (Either SideChannelError ())
writeDiagnosticFile path diagnostics
    | null path = pure (Left (SideChannelWriteError path "diagnostic path is empty"))
    | otherwise = case diagnosticDocument diagnostics of
        Left issue -> pure (Left (SideChannelModelError issue))
        Right document -> case encodeDiagnosticDocument defaultDiagnosticProtocolLimits document of
            Left issue -> pure (Left (SideChannelEncodingError issue))
            Right bytes -> do
                result <- try (ByteString.writeFile path bytes) :: IO (Either IOException ())
                pure $ case result of
                    Left issue -> Left (SideChannelWriteError path (show issue))
                    Right () -> Right ()
