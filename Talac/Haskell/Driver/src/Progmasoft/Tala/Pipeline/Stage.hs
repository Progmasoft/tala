-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Stage names shared by the compiler driver's internal pipeline reporting.
Only Core, Xpp, and Xmm currently have explicit emission extensions.
-}
module Progmasoft.Tala.Pipeline.Stage
    ( Stage (..)
    , artifactExtension
    ) where

-- | Stable stage names in the renewed Tala compiler pipeline.
data Stage
    = ParsedAst
    | ResolvedAst
    | TypedAst
    | Core
    | CorePrep
    | Xpp
    | Xmm
    | LlvmBitcode
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

{- | Public file extension for stages that may be explicitly emitted.
Other stages remain in-memory unless a later backend contract defines an artifact.
-}
artifactExtension :: Stage -> Maybe String
artifactExtension Core = Just ".core"
artifactExtension Xpp = Just ".xpp"
artifactExtension Xmm = Just ".xmm"
artifactExtension _ = Nothing
