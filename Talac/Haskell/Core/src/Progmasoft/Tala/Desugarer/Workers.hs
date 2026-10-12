-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Giving a second lowering of a method body symbols of its own.

A method whose parameters may be passed by need is lowered twice: once as
the method itself, which receives values, and once as the function that
receives suspended computations, for the callers that hand them on. Both
come from the same source statements, whose locals carry the symbols the
renamer gave them. Symbols are unique in a module, so the second lowering
takes fresh ones for everything it defines.
-}
module Progmasoft.Tala.Desugarer.Workers
    ( definedNames
    , renameSymbols
    ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core

{- | Every name the statements define, at any depth: bindings, expression
bindings, and the parameters of closures. A capture is not listed: it is
the name it captures.
-}
definedNames :: [CoreStatement] -> [ResolvedName]
definedNames = concatMap statement
    where
        statement value = case value of
            CoreBind binding -> coreBindingName binding : expression (coreBindingValue binding)
            CoreAssign _ assigned -> expression assigned
            CoreReturn returned -> expression returned
            CoreEvaluate evaluated -> expression evaluated
            CoreIf condition whenTrue whenFalse -> expression condition ++ definedNames whenTrue ++ definedNames whenFalse
            CoreWhile condition body -> expression condition ++ definedNames body
            CoreDoWhile body condition -> definedNames body ++ expression condition
            CoreFor condition body update -> expression condition ++ definedNames body ++ definedNames update
            CoreBreak -> []
            CoreContinue -> []
        expression value = case value of
            CoreVariable {} -> []
            CoreLiteral {} -> []
            CoreApply callee arguments _ -> concatMap expression (callee : arguments)
            CorePrimitive _ arguments _ -> concatMap expression arguments
            CoreLet name _ bound body _ -> name : expression bound ++ expression body
            CoreConditional condition whenTrue whenFalse _ -> concatMap expression [condition, whenTrue, whenFalse]
            CoreClosure captures parameters _ body _ ->
                map fst parameters
                    ++ concatMap (expression . coreCaptureValue) captures
                    ++ definedNames body

{- | Replace every occurrence of the given symbols, where they are defined and
where they are used. A symbol without a replacement is kept: the functions
of the module, and whatever the statements read from outside.
-}
renameSymbols :: Map SymbolId ResolvedName -> [CoreStatement] -> [CoreStatement]
renameSymbols replacements = map statement
    where
        name original = Map.findWithDefault original (resolvedSymbol original) replacements
        statement value = case value of
            CoreBind binding ->
                CoreBind
                    binding
                        { coreBindingName = name (coreBindingName binding)
                        , coreBindingValue = expression (coreBindingValue binding)
                        }
            CoreAssign target assigned -> CoreAssign (name target) (expression assigned)
            CoreReturn returned -> CoreReturn (expression returned)
            CoreEvaluate evaluated -> CoreEvaluate (expression evaluated)
            CoreIf condition whenTrue whenFalse ->
                CoreIf (expression condition) (map statement whenTrue) (map statement whenFalse)
            CoreWhile condition body -> CoreWhile (expression condition) (map statement body)
            CoreDoWhile body condition -> CoreDoWhile (map statement body) (expression condition)
            CoreFor condition body update ->
                CoreFor (expression condition) (map statement body) (map statement update)
            CoreBreak -> CoreBreak
            CoreContinue -> CoreContinue
        expression value = case value of
            CoreVariable variable valueType -> CoreVariable (name variable) valueType
            CoreLiteral {} -> value
            CoreApply callee arguments valueType ->
                CoreApply (expression callee) (map expression arguments) valueType
            CorePrimitive primitive arguments valueType ->
                CorePrimitive primitive (map expression arguments) valueType
            CoreLet bound bindingType boundValue body valueType ->
                CoreLet (name bound) bindingType (expression boundValue) (expression body) valueType
            CoreConditional condition whenTrue whenFalse valueType ->
                CoreConditional (expression condition) (expression whenTrue) (expression whenFalse) valueType
            CoreClosure captures parameters returnType body valueType ->
                CoreClosure
                    [ capture
                        { coreCaptureName = name (coreCaptureName capture)
                        , coreCaptureValue = expression (coreCaptureValue capture)
                        }
                    | capture <- captures
                    ]
                    [(name parameter, parameterType) | (parameter, parameterType) <- parameters]
                    returnType
                    (map statement body)
                    valueType
