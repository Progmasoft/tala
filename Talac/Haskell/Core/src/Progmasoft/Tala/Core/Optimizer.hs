-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Public facade for the target-independent Core optimization pipeline.

The optimizer accepts only verified Core and verifies its final result again.
That invariant makes the facade safe for compiler orchestration and for tools
which load a Core artifact without running the normal frontend first.
-}
module Progmasoft.Tala.Core.Optimizer
    ( CoreOptimizer (..)
    , OptimizerOptions (..)
    , OptimizationPass (..)
    , OptimizationMetrics (..)
    , PassReport (..)
    , OptimizationResult (..)
    , Effect (..)
    , FunctionEffectReport (..)
    , InlineReport (..)
    , defaultCoreOptimizer
    , defaultOptimizerOptions
    , runCoreOptimizer
    , optimizeCoreWith
    ) where

import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer.Analysis
import Progmasoft.Tala.Core.Optimizer.Inline
import Progmasoft.Tala.Core.Optimizer.Pipeline
import Progmasoft.Tala.Core.Optimizer.Types
import Progmasoft.Tala.Core.Verifier (verifyCore)
import Progmasoft.Tala.Diagnostic (Diagnostic)

-- | Reusable verified-Core transformation supplied to compiler orchestration.
newtype CoreOptimizer = CoreOptimizer
    { optimizeCore :: CoreModule -> Either [Diagnostic] CoreModule
    }

-- | Apply an optimizer while preserving its diagnostic-based failure contract.
runCoreOptimizer :: CoreOptimizer -> CoreModule -> Either [Diagnostic] CoreModule
runCoreOptimizer = optimizeCore

-- | Construct the production optimizer using 'defaultOptimizerOptions'.
defaultCoreOptimizer :: CoreOptimizer
defaultCoreOptimizer =
    CoreOptimizer $ \moduleValue -> optimizedCore <$> optimizeCoreWith defaultOptimizerOptions moduleValue

-- | Verify input, run enabled passes, and verify the optimized result again.
optimizeCoreWith :: OptimizerOptions -> CoreModule -> Either [Diagnostic] OptimizationResult
optimizeCoreWith options moduleValue = do
    verified <- verifyCore moduleValue
    let result = runOptimizationPipeline options verified
    checked <- verifyCore (optimizedCore result)
    pure result {optimizedCore = checked}
