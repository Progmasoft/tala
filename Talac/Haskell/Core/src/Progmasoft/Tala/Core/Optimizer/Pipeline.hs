-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Progmasoft.Tala.Core.Optimizer.Pipeline (runOptimizationPipeline) where

import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Optimizer.Analysis (emptyEffectEnvironment)
import Progmasoft.Tala.Core.Optimizer.Constant
import Progmasoft.Tala.Core.Optimizer.ControlFlow
import Progmasoft.Tala.Core.Optimizer.EffectInference
import Progmasoft.Tala.Core.Optimizer.Inline
import Progmasoft.Tala.Core.Optimizer.Liveness
import Progmasoft.Tala.Core.Optimizer.Types

runOptimizationPipeline :: OptimizerOptions -> CoreModule -> OptimizationResult
runOptimizationPipeline options original =
    let maximumIterations = max 1 (optimizerMaximumIterations options)
        (optimized, iterations, converged, reports, inlineReports) = iteratePipeline maximumIterations 1 original [] []
     in OptimizationResult
            { optimizedCore = optimized
            , optimizationBefore = measureModule original
            , optimizationAfter = measureModule optimized
            , optimizationIterations = iterations
            , optimizationConverged = converged
            , optimizationPassReports = reports
            , optimizationEffectReports = finalEffectReports optimized
            , optimizationInlineReports = inlineReports
            }
    where
        finalEffectReports value
            | optimizerInterproceduralEffects options = snd (inferFunctionEffects value)
            | otherwise = []
        iteratePipeline maximumIterations iteration current reports inlineReports =
            let (next, currentReports, currentInlineReports) = runIteration options iteration current
                accumulated = reports ++ currentReports
                accumulatedInline = inlineReports ++ currentInlineReports
             in if next == current
                    then (next, iteration, True, accumulated, accumulatedInline)
                    else
                        if iteration >= maximumIterations
                            then (next, iteration, False, accumulated, accumulatedInline)
                            else iteratePipeline maximumIterations (iteration + 1) next accumulated accumulatedInline

runIteration :: OptimizerOptions -> Int -> CoreModule -> (CoreModule, [PassReport], [InlineReport])
runIteration options iteration input =
    let (_, effectReports) = inferFunctionEffects input
        (afterInlining, inliningReports, inlineReports) =
            runInlining
                (optimizerInlining options && optimizerInterproceduralEffects options)
                effectReports
                input
        (afterConstants, constantReports) =
            runEnabled
                (optimizerConstantPropagation options)
                ConstantPropagationPass
                propagateConstants
                afterInlining
        controlEnvironment = inferEnvironment afterConstants
        (afterControlFlow, controlFlowReports) =
            runEnabled
                (optimizerControlFlowSimplification options)
                ControlFlowSimplificationPass
                (simplifyControlFlowWith controlEnvironment)
                afterConstants
        deadCodeEnvironment = inferEnvironment afterControlFlow
        (afterDeadCode, deadCodeReports) =
            runEnabled
                (optimizerDeadCodeElimination options)
                DeadCodeEliminationPass
                (eliminateDeadCodeWith deadCodeEnvironment)
                afterControlFlow
     in (afterDeadCode, inliningReports ++ constantReports ++ controlFlowReports ++ deadCodeReports, inlineReports)
    where
        runInlining enabled effects before
            | not enabled = (before, [], [])
            | otherwise =
                let (after, inlineReport) = inlineFunctions (optimizerMaximumInlineExpressionNodes options) effects before
                 in ( after
                    , [PassReport iteration InliningPass (measureModule before) (measureModule after) (before /= after)]
                    , [inlineReport]
                    )
        inferEnvironment value
            | optimizerInterproceduralEffects options = fst (inferFunctionEffects value)
            | otherwise = emptyEffectEnvironment
        runEnabled enabled passName pass before
            | not enabled = (before, [])
            | otherwise =
                let after = pass before
                 in ( after
                    ,
                        [ PassReport
                            { passReportIteration = iteration
                            , passReportPass = passName
                            , passReportBefore = measureModule before
                            , passReportAfter = measureModule after
                            , passReportChanged = before /= after
                            }
                        ]
                    )
