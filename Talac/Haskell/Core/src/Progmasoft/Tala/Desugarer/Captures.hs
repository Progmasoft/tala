-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | What a closure takes from the place that creates it.

A callable written without a capture list captures what its body reads and
does not define: the lowering finds those names in the lowered body. A
closure takes the value of each when it is created.
-}
module Progmasoft.Tala.Desugarer.Captures
    ( discoverImplicitCaptures
    , localSymbols
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Core

{- | The captures of a closure with the given parameters and body: every name
the body reads that is neither a parameter nor a local of the body, once,
in the order of the first read.
-}
discoverImplicitCaptures :: [(ResolvedName, Type)] -> [CoreStatement] -> [CoreCapture]
discoverImplicitCaptures parameters statements =
    let bound = map (resolvedSymbol . fst) parameters ++ localSymbols statements
        free = filter (\(name, _) -> resolvedSymbol name `notElem` bound) (statementReads statements)
     in [CoreCapture StrongCapture name valueType (CoreVariable name valueType) | (name, valueType) <- uniqueReads free]

{- | The symbols the statements bind, in every branch and loop body they
hold. The body of a closure among them is a scope of its own and is not
searched.
-}
localSymbols :: [CoreStatement] -> [SymbolId]
localSymbols = concatMap collect
    where
        collect statement = case statement of
            CoreBind binding -> [resolvedSymbol (coreBindingName binding)]
            CoreIf _ yes no -> localSymbols yes ++ localSymbols no
            CoreWhile _ body -> localSymbols body
            CoreDoWhile body _ -> localSymbols body
            CoreFor _ body update -> localSymbols body ++ localSymbols update
            _ -> []

statementReads :: [CoreStatement] -> [(ResolvedName, Type)]
statementReads = concatMap collect
    where
        collect statement = case statement of
            CoreBind binding -> expressionReads (coreBindingValue binding)
            CoreAssign _ value -> expressionReads value
            CoreReturn value -> expressionReads value
            CoreIf condition yes no -> expressionReads condition ++ statementReads yes ++ statementReads no
            CoreWhile condition body -> expressionReads condition ++ statementReads body
            CoreDoWhile body condition -> statementReads body ++ expressionReads condition
            CoreFor condition body update ->
                expressionReads condition ++ statementReads body ++ statementReads update
            CoreEvaluate value -> expressionReads value
            CoreBreak -> []
            CoreContinue -> []

expressionReads :: CoreExpression -> [(ResolvedName, Type)]
expressionReads expression = case expression of
    CoreVariable name valueType -> [(name, valueType)]
    CoreLiteral _ _ -> []
    CoreApply callee arguments _ -> expressionReads callee ++ concatMap expressionReads arguments
    CorePrimitive _ arguments _ -> concatMap expressionReads arguments
    CoreLet name _ value body _ ->
        expressionReads value ++ filter ((/= resolvedSymbol name) . resolvedSymbol . fst) (expressionReads body)
    CoreConditional condition whenTrue whenFalse _ ->
        expressionReads condition ++ expressionReads whenTrue ++ expressionReads whenFalse
    -- A closure reads, from the place that creates it, its capture
    -- initializers and whatever its body reads that is not its own: its
    -- parameters, its captures and its locals belong to the closure. Without
    -- that, a closure around this one would capture them as if they were
    -- names of its surroundings.
    CoreClosure captures parameters _ body _ ->
        let own =
                map (resolvedSymbol . fst) parameters
                    ++ map (resolvedSymbol . coreCaptureName) captures
                    ++ localSymbols body
         in concatMap (expressionReads . coreCaptureValue) captures
                ++ filter ((`notElem` own) . resolvedSymbol . fst) (statementReads body)

uniqueReads :: [(ResolvedName, Type)] -> [(ResolvedName, Type)]
uniqueReads = foldl append []
    where
        append output value@(name, _)
            | any ((== resolvedSymbol name) . resolvedSymbol . fst) output = output
            | otherwise = output ++ [value]
