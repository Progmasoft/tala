-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | The loops around the place the type checker is at.

A @break@ or a @continue@ is checked against the innermost loop, and what a
@break@ may carry depends on how that loop is used. Blocks used as values and
loop headers are not loops, but a transfer has to cross them to reach one, so
they are entries of the same stack.
-}
module Progmasoft.Tala.TypeChecker.Loops
    ( LoopKind (..)
    , LoopContext (..)
    , outsideLoops
    , enterLoop
    , loopCondition
    , loopUpdate
    , transferTarget
    ) where

import Progmasoft.Tala.AST (Type)

-- | How a loop is used, which decides what its @break@ statements carry.
data LoopKind
    = -- | A loop statement: @break@ carries no value.
      StatementLoop
    | {- | A loop used as an expression: every @break@ carries the loop's
      value, typed in the context that receives it.
      -}
      ExpressionLoop (Maybe Type)
    | {- | Not a loop: the edge of a block used as a value. A @break@ or
      @continue@ inside it leaves the block without a value and targets the
      loop around the expression the block belongs to.
      -}
      ValueBlockEdge
    | {- | The condition of a loop of the given kind. A @break@ there leaves
      that loop, like one in its body. A @continue@ there abandons the rest
      of the condition and evaluates the condition of that loop again.
      -}
      LoopCondition LoopKind
    | {- | The update clause of a loop of the given kind. A @continue@ there
      ends the update, and the condition of the loop is tested next. A
      @break@ there leaves that loop.
      -}
      LoopUpdate LoopKind

{- | The loops around a statement, innermost first, and the kind of the loop
statement that is about to be checked. A loop expression checks its loop
statement with the pending kind set; every loop moves the pending kind onto
the stack for its own body.
-}
data LoopContext = LoopContext
    { pendingLoop :: LoopKind
    , enclosingLoops :: [LoopKind]
    }

-- | The context of a statement that no loop encloses.
outsideLoops :: LoopContext
outsideLoops = LoopContext StatementLoop []

-- | The context of the body of the loop statement being checked.
enterLoop :: LoopContext -> LoopContext
enterLoop loops = LoopContext StatementLoop (pendingLoop loops : enclosingLoops loops)

-- | The context of the condition of the loop statement about to be checked.
loopCondition :: LoopContext -> LoopContext
loopCondition loops = LoopContext StatementLoop (LoopCondition (pendingLoop loops) : enclosingLoops loops)

-- | The context of the update clause of the loop statement about to be checked.
loopUpdate :: LoopContext -> LoopContext
loopUpdate loops = LoopContext StatementLoop (LoopUpdate (pendingLoop loops) : enclosingLoops loops)

{- | The loop a @break@ or @continue@ targets: the innermost entry that is
not the edge of a block used as a value. A transfer crosses such an edge
freely; the block it leaves simply yields no value.
-}
transferTarget :: LoopContext -> Maybe LoopKind
transferTarget loops = case dropWhile isValueBlockEdge (enclosingLoops loops) of
    kind : _ -> Just kind
    [] -> Nothing
    where
        isValueBlockEdge kind = case kind of
            ValueBlockEdge -> True
            _ -> False
