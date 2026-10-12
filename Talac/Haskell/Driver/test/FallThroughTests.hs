-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | How a function ends when its body ends.

A function without a result may end without a @return@: reaching the end of
its body returns. A function with a result returns on every path, so the end
of its body is never reached, and the block that stands there is marked as
unreachable rather than given a value nobody wrote.

The two must not be confused. A function without a result whose last block
was marked unreachable had no meaning once it was called, and a native
program whose @Main@ ended that way stopped instead of ending.
-}
module FallThroughTests (fallThroughTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.CorePrep.Verifier (verifyCorePrep)

fallThroughTests :: [(String, Bool)]
fallThroughTests =
    [ ("an empty body without a result returns", terminators (prepared unitType []) == [returnsNothing])
    , ("a body without a result that ends in a binding returns", terminators (prepared unitType [bind 2 1]) == [returnsNothing])
    , ("a body without a result that ends in a call returns", terminators (prepared unitType [CoreEvaluate callee]) == [returnsNothing])
    , ("a body without a result never ends in an unreachable block", all (noneUnreachable . prepared unitType) resultless)
    , ("every body without a result passes verification", all (verified . prepared unitType) resultless)
    , -- One return was written; the other is the end of the body.
      ("the block after a conditional return returns", returns (prepared unitType [returnWhen]) == 2)
    , ("the block after a loop returns", returns (prepared unitType [CoreWhile condition [bind 3 1]]) == 1)
    , ("the block after a loop that is left early returns", returns (prepared unitType [CoreWhile condition [CoreBreak]]) == 1)
    , ("the block after nested conditionals returns", returns (prepared unitType [nested]) == 2)
    , ("an explicit return keeps its own value", terminators (prepared unitType [CoreReturn nothing]) == [returnsNothing])
    , ("a loop body still continues with its loop", loopBodyJumps)
    , ("a body with a result is not given a value at its end", notElem returnsNothing (terminators (prepared intType [bothReturn])))
    , ("the end of a body with a result stays unreachable", elem CorePrepUnreachable (terminators (prepared intType [bothReturn])))
    , ("a body with a result that returns directly has one block", terminators (prepared intType [CoreReturn (integer 1)]) == [CorePrepReturn (CorePrepLiteral (CoreInteger 1) intType)])
    , ("a closure without a result returns at the end of its body", closureReturns)
    , ("a closure with a result is not given a value at its end", closureWithResultIsNotCompleted)
    ]
    where
        resultless =
            [ []
            , [bind 2 1]
            , [CoreEvaluate callee]
            , [returnWhen]
            , [returnWhen, bind 2 1]
            , [CoreWhile condition [bind 3 1]]
            , [CoreWhile condition [CoreBreak]]
            , [CoreWhile condition [CoreContinue]]
            , [CoreDoWhile [bind 3 1] condition]
            , [CoreFor condition [bind 3 1] [bind 4 1]]
            , [nested]
            , [nested, returnWhen, CoreWhile condition []]
            , [CoreIf condition [CoreReturn nothing] [CoreReturn nothing]]
            ]

-- | What reaching the end of a body without a result does.
returnsNothing :: CorePrepTerminator
returnsNothing = CorePrepReturn (CorePrepLiteral CoreUnit unitType)

nothing :: CoreExpression
nothing = CoreLiteral CoreUnit unitType

integer :: Integer -> CoreExpression
integer value = CoreLiteral (CoreInteger value) intType

condition :: CoreExpression
condition = CoreVariable (name 20 "flag") boolType

callee :: CoreExpression
callee = CoreApply (CoreVariable (name 21 "Act") (FunctionType [] unitType)) [] unitType

bind :: Int -> Integer -> CoreStatement
bind symbol value = CoreBind (CoreBinding (name symbol "local") intType False (integer value))

-- | @if (flag) { return; }@
returnWhen :: CoreStatement
returnWhen = CoreIf condition [CoreReturn nothing] []

-- | @if (flag) { if (flag) { return; } } else { local = 1; }@
nested :: CoreStatement
nested = CoreIf condition [returnWhen] [bind 5 1]

-- | @if (flag) { return 1; } else { return 2; }@
bothReturn :: CoreStatement
bothReturn = CoreIf condition [CoreReturn (integer 1)] [CoreReturn (integer 2)]

prepared :: Type -> [CoreStatement] -> CorePrepModule
prepared returnType statements = case prepareCore moduleValue of
    Right moduleResult -> moduleResult
    Left _ -> error "prepareCore cannot fail on these bodies"
    where
        moduleValue = CoreModuleWithSources (QualifiedName [Identifier "FallThrough"]) [function] [] []
        function =
            CoreFunction
                (name 1 "Evaluate")
                [(name 20 "flag", boolType), (name 21 "Act", FunctionType [] unitType)]
                returnType
                statements

terminators :: CorePrepModule -> [CorePrepTerminator]
terminators moduleValue =
    [ corePrepBlockTerminator block
    | function <- corePrepModuleFunctions moduleValue
    , block <- corePrepFunctionBlocks function
    ]

-- | How many blocks return without a value.
returns :: CorePrepModule -> Int
returns = length . filter (== returnsNothing) . terminators

noneUnreachable :: CorePrepModule -> Bool
noneUnreachable = notElem CorePrepUnreachable . terminators

verified :: CorePrepModule -> Bool
verified = either (const False) (const True) . verifyCorePrep

{- | The end of a loop body goes back to the loop, whatever the function
returns: only the end of the function's own body returns.
-}
loopBodyJumps :: Bool
loopBodyJumps =
    length [() | CorePrepJump _ <- found] >= 2
        && length (filter (== returnsNothing) found) == 1
    where
        found = terminators (prepared unitType [CoreWhile condition [bind 3 1]])

closureReturns :: Bool
closureReturns = case corePrepModuleFunctions moduleValue of
    [_, lifted] -> map corePrepBlockTerminator (corePrepFunctionBlocks lifted) == [returnsNothing]
    _ -> False
    where
        moduleValue = prepared unitType [CoreBind (CoreBinding (name 6 "act") callable False closure)]
        callable = FunctionType [] unitType
        closure = CoreClosure [] [] unitType [bind 7 1] callable

closureWithResultIsNotCompleted :: Bool
closureWithResultIsNotCompleted = case corePrepModuleFunctions moduleValue of
    [_, lifted] ->
        let found = map corePrepBlockTerminator (corePrepFunctionBlocks lifted)
         in notElem returnsNothing found && elem CorePrepUnreachable found
    _ -> False
    where
        moduleValue = prepared unitType [CoreBind (CoreBinding (name 6 "pick") callable False closure)]
        callable = FunctionType [] intType
        closure = CoreClosure [] [] intType [bothReturn] callable

name :: Int -> String -> ResolvedName
name symbol spelling = ResolvedName (SymbolId symbol) (Identifier spelling)
