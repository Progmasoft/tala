-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Main (main) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Feedback
import Mutation
import System.Exit (die)
import Trace.Hpc.Tix (Tix (..), TixModule (..))
import Trace.Hpc.Util (toHash)

main :: IO ()
main = do
    let ticks = Tix [TixModule "Progmasoft.Tala.Parser" (toHash (1 :: Int)) 3 [1, 0, 2], TixModule "Main" (toHash (2 :: Int)) 1 [1]]
        changed = Tix [TixModule "Progmasoft.Tala.Parser" (toHash (3 :: Int)) 3 [1, 0, 2]]
    unless
        (Set.size (coverageFor ticks) == 2 && availableTicks ticks == 3)
        (die "feedback included harness ticks or missed production ticks")
    unless
        (requiredModulePresent "parser" ticks && not (requiredModulePresent "lexer" ticks))
        (die "coverage-disabled stage passed its gate")
    unless
        (Set.null (Set.intersection (coverageFor ticks) (coverageFor changed)))
        (die "different module hashes shared tick identities")
    let large = BS.replicate maximumInput 255
        empty = BS.empty
    unless
        ( all
            (\seed -> BS.length (mutate seed large large) <= maximumInput && BS.length (mutate seed empty empty) <= maximumInput)
            [0 .. 10000]
        )
        (die "mutation exceeded its input bound")
    unless
        (mutate 42 large empty == mutate 42 large empty && fingerprint empty /= fingerprint large)
        (die "mutation/replay identity is inconsistent")
    putStrLn "HPC feedback and mutation policy tests passed"
