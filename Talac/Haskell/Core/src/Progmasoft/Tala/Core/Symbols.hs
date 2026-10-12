-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Complete SymbolId inventory for Core.

Optimization passes sometimes have to introduce compiler-owned binders.  They
must not guess a starting value from function names alone: parameters, local
bindings, expression-local lets, closure captures, and lifted closure
parameters all inhabit the same resolved identity space.  This module owns the
structural traversal used to find a collision-free fresh-symbol frontier.

The inventory includes definitions and uses.  Including uses is intentional.
A verified module cannot contain a dangling use, but transformation helpers are
also exercised on partially built fixtures.  Starting above every observed id
keeps those transformations deterministic and prevents a secondary diagnostic
from obscuring the original malformed reference.
-}
module Progmasoft.Tala.Core.Symbols
    ( coreModuleSymbols
    , coreFunctionSymbols
    , coreStatementSymbols
    , coreExpressionSymbols
    , maximumCoreSymbolValue
    , nextCoreSymbolValue
    ) where

import Progmasoft.Tala.AST (ResolvedName, resolvedSymbol, symbolIdValue)
import Progmasoft.Tala.Core

-- | Return every resolved name observed in deterministic source order.
coreModuleSymbols :: CoreModule -> [ResolvedName]
coreModuleSymbols = concatMap coreFunctionSymbols . coreModuleFunctions

-- | Include the function definition before its parameter and body identities.
coreFunctionSymbols :: CoreFunction -> [ResolvedName]
coreFunctionSymbols function =
    coreFunctionName function
        : map fst (coreFunctionParameters function)
        ++ concatMap coreStatementSymbols (coreFunctionBody function)

-- | Traverse a statement, including both targets and expression references.
coreStatementSymbols :: CoreStatement -> [ResolvedName]
coreStatementSymbols statement = case statement of
    CoreBind binding ->
        coreBindingName binding : coreExpressionSymbols (coreBindingValue binding)
    CoreAssign name value -> name : coreExpressionSymbols value
    CoreReturn value -> coreExpressionSymbols value
    CoreEvaluate value -> coreExpressionSymbols value
    CoreIf condition whenTrue whenFalse ->
        coreExpressionSymbols condition
            ++ concatMap coreStatementSymbols whenTrue
            ++ concatMap coreStatementSymbols whenFalse
    CoreWhile condition body -> coreExpressionSymbols condition ++ concatMap coreStatementSymbols body
    CoreDoWhile body condition -> concatMap coreStatementSymbols body ++ coreExpressionSymbols condition
    CoreFor condition body update ->
        coreExpressionSymbols condition
            ++ concatMap coreStatementSymbols body
            ++ concatMap coreStatementSymbols update
    CoreBreak -> []
    CoreContinue -> []

-- | Traverse all expression-owned scopes, including closure bodies.
coreExpressionSymbols :: CoreExpression -> [ResolvedName]
coreExpressionSymbols expression = case expression of
    CoreVariable name _ -> [name]
    CoreLiteral {} -> []
    CoreApply callee arguments _ ->
        coreExpressionSymbols callee ++ concatMap coreExpressionSymbols arguments
    CorePrimitive _ arguments _ -> concatMap coreExpressionSymbols arguments
    CoreLet name _ value body _ ->
        name : coreExpressionSymbols value ++ coreExpressionSymbols body
    CoreConditional condition whenTrue whenFalse _ ->
        coreExpressionSymbols condition ++ coreExpressionSymbols whenTrue ++ coreExpressionSymbols whenFalse
    CoreClosure captures parameters _ body _ ->
        map coreCaptureName captures
            ++ map fst parameters
            ++ concatMap (coreExpressionSymbols . coreCaptureValue) captures
            ++ concatMap coreStatementSymbols body

-- | Largest numeric identity observed in the complete Core tree.
maximumCoreSymbolValue :: CoreModule -> Int
maximumCoreSymbolValue moduleValue =
    maximum
        ( 0
            : map
                (symbolIdValue . resolvedSymbol)
                (coreModuleSymbols moduleValue)
        )

-- | First positive identity that is guaranteed not to collide with the module.
nextCoreSymbolValue :: CoreModule -> Int
nextCoreSymbolValue moduleValue = maximumCoreSymbolValue moduleValue + 1
