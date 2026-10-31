-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Exact HPC tick identities for frontend mutation feedback. Module hashes
keep different builds' counters distinct; each execution resets counters before
running so coverage is attributed to that input rather than accumulated history.
-}
module Feedback (Coverage, coverageFor, availableTicks, requiredModulePresent) where

import Data.List (isInfixOf)
import Data.Set qualified as Set
import Trace.Hpc.Tix (Tix (..), TixModule (..))

type Coverage = Set.Set (String, String, Int)

ownedModule :: String -> Bool
ownedModule = isInfixOf "Tala."

coverageFor :: Tix -> Coverage
coverageFor (Tix modules) =
    Set.fromList
        [ (name, show identity, index)
        | TixModule name identity _ ticks <- modules
        , ownedModule name
        , (index, count) <- zip [0 ..] ticks
        , count > 0
        ]

availableTicks :: Tix -> Int
availableTicks (Tix modules) = sum [size | TixModule name _ size _ <- modules, ownedModule name]

requiredModulePresent :: String -> Tix -> Bool
requiredModulePresent stage (Tix modules) =
    any (\(TixModule name _ size _) -> size > 0 && isInfixOf expected name) modules
    where
        expected = case stage of
            "lexer" -> "Progmasoft.Tala.Lexer"
            "parser" -> "Progmasoft.Tala.Parser"
            _ -> "Progmasoft.Tala.Compiler"
