-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Stdio-only entry point. LSP reserves stdout for protocol frames, so all
diagnostic logging and transport failures go to stderr in the transport layer.
-}
module Main (main) where

import System.Exit (ExitCode (..), exitWith)
import Progmasoft.TalaAnalyzer.Server (runAnalyzerServer)

main :: IO ()
main = do
    status <- runAnalyzerServer
    if status == 0 then pure () else exitWith (ExitFailure status)
