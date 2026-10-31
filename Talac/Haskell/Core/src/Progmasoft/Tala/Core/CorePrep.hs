-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Normalize tree-shaped Core into typed operations and explicit basic blocks.

CorePrep preserves Core identity and evaluation order while making control flow
and storage actions visible to native Xpp lowering. It is an internal adapter,
not a user-selectable emission format or an optimization owner.
-}
module Progmasoft.Tala.Core.CorePrep
    ( CorePrepAtom (..)
    , CorePrepCapture (..)
    , CorePrepOperation (..)
    , CorePrepInstruction (..)
    , CorePrepTerminator (..)
    , CorePrepBlock (..)
    , CorePrepFunction (..)
    , CorePrepModule (..)
    , prepareCore
    ) where

import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Scalar (isCoreFloatingType)
import Progmasoft.Tala.Core.Verifier (verifyCore)
import Progmasoft.Tala.Diagnostic

-- | A value already reduced to a symbol reference or a literal constant.
data CorePrepAtom = CorePrepVariable ResolvedName Type | CorePrepLiteral CoreLiteral Type
    deriving (Eq, Ord, Read, Show)

-- | One atom-only computation; nested expressions have already been sequenced.
data CorePrepOperation
    = CorePrepCopy CorePrepAtom
    | CorePrepCall CorePrepAtom [CorePrepAtom]
    | CorePrepPrimitive CorePrimitive [CorePrepAtom]
    | CorePrepMakeClosure ResolvedName [CorePrepCapture]
    deriving (Eq, Ord, Read, Show)

-- | Closure environment slot with its source ownership mode and initializer.
data CorePrepCapture = CorePrepCapture CaptureMode ResolvedName Type CorePrepAtom
    deriving (Eq, Ord, Read, Show)

-- | A storage definition or side effect that executes in block order.
data CorePrepInstruction
    = CorePrepBind ResolvedName Type Bool CorePrepOperation
    | CorePrepAssign ResolvedName CorePrepAtom
    | CorePrepEvaluate CorePrepOperation
    deriving (Eq, Ord, Read, Show)

-- | The control transfer that closes a prepared basic block.
data CorePrepTerminator
    = CorePrepReturn CorePrepAtom
    | CorePrepBranch CorePrepAtom Int Int
    | CorePrepJump Int
    | CorePrepUnreachable
    deriving (Eq, Ord, Read, Show)

-- | A deterministic block identifier, ordered instructions, and final transfer.
data CorePrepBlock = CorePrepBlock
    { corePrepBlockId :: Int
    , corePrepBlockInstructions :: [CorePrepInstruction]
    , corePrepBlockTerminator :: CorePrepTerminator
    }
    deriving (Eq, Ord, Read, Show)

-- | Function signature plus entry block and deterministic control-flow body.
data CorePrepFunction = CorePrepFunction
    { corePrepFunctionName :: ResolvedName
    , corePrepFunctionSourceFile :: FilePath
    , corePrepFunctionParameters :: [(ResolvedName, Type)]
    , corePrepFunctionReturnType :: Type
    , corePrepFunctionEntry :: Int
    , corePrepFunctionBlocks :: [CorePrepBlock]
    }
    deriving (Eq, Ord, Read, Show)

-- | Module identity, prepared functions, and source files retained as provenance.
data CorePrepModule = CorePrepModule
    { corePrepModuleName :: QualifiedName
    , corePrepModuleFunctions :: [CorePrepFunction]
    , corePrepModuleSourceFiles :: [FilePath]
    }
    deriving (Eq, Ord, Read, Show)

data PrepState = PrepState
    { nextTemporary :: Int
    , nextBlock :: Int
    , pendingFunctions :: [(CoreFunction, FilePath)]
    , currentSourceFile :: FilePath
    , loopTargets :: [(Int, Int)]
    -- ^ Innermost first; each pair is the @break@ exit and @continue@ target.
    }

-- An OpenBlock is the current continuation while expressions are being
-- atomized. Most expressions only append instructions, but short-circuit
-- expressions close the current block, emit a conditional region, and return
-- a fresh join block. Keeping that distinction explicit prevents a nested
-- logical expression from being flattened back into eager instruction order.
data OpenBlock = OpenBlock
    { openBlockId :: Int
    , openBlockInstructions :: [CorePrepInstruction]
    {- ^ Newest first, so that appending one is constant time; 'closeBlock'
    puts them in execution order.
    -}
    }

{- | Adapt one verified Core module without changing its source-level semantics.
Fresh IDs start above every Core ID so generated temporaries cannot alias
declarations, locals, parameters, or captures already present in the module.
-}
prepareCore :: CoreModule -> Either [Diagnostic] CorePrepModule
prepareCore moduleValue =
    do
        verified <- verifyCore moduleValue
        let seed = 1 + maximum (0 : concatMap symbolIds (coreModuleFunctions verified))
            sourceOwners = Map.fromList (coreModuleFunctionSources verified)
            sourceOf function =
                Map.findWithDefault
                    ""
                    (symbolIdValue (resolvedSymbol (coreFunctionName function)))
                    sourceOwners
            initial = PrepState seed 1 [] "" []
            work = [(function, sourceOf function) | function <- coreModuleFunctions verified]
            (functions, _) = prepareFunctionQueue initial work
        pure (CorePrepModule (coreModuleName verified) functions (coreModuleSourceFiles verified))

-- Closure conversion yields lifted functions together with their source
-- owner. They are prepared after every function that was already waiting, in
-- the order they were found, and the functions lifted out of them after
-- those: that supports nested closures without a separate whole-module pass
-- or a filename guess.
--
-- The lifted functions wait in batches of their own, newest first. Appending
-- them to the functions still waiting wrapped that list once more for every
-- function prepared, also when nothing was lifted, and taking the next
-- function then cost time with the number of functions before it.
prepareFunctionQueue :: PrepState -> [(CoreFunction, FilePath)] -> ([CorePrepFunction], PrepState)
prepareFunctionQueue initial work = go initial work []
    where
        go state [] [] = ([], state)
        go state [] lifted = go state (concat (reverse lifted)) []
        go state ((function, sourceFile) : remaining) lifted =
            let (prepared, afterFunction) = prepareFunction (state {nextBlock = 1, currentSourceFile = sourceFile}) function
                pending = pendingFunctions afterFunction
                nextState = afterFunction {pendingFunctions = []}
                (later, final) = go nextState remaining (if null pending then lifted else pending : lifted)
             in (prepared : later, final)

prepareFunction :: PrepState -> CoreFunction -> (CorePrepFunction, PrepState)
prepareFunction state function =
    let (blocks, after) =
            prepareStatementsTo fallingOff (state {loopTargets = []}) (OpenBlock 0 []) (coreFunctionBody function) []
     in ( CorePrepFunction
            (coreFunctionName function)
            (currentSourceFile state)
            (coreFunctionParameters function)
            (coreFunctionReturnType function)
            0
            blocks
        , after
        )
    where
        -- A function without a result may end without a return: reaching
        -- the end of its body returns. A function with a result returns on
        -- every path, which Core verification has established, so the end
        -- of its body is not reached and is marked as such.
        fallingOff
            | coreFunctionReturnType function == unitType = CorePrepReturn (CorePrepLiteral CoreUnit unitType)
            | otherwise = CorePrepUnreachable

{- | Every symbol identity a function mentions.

The identities are prepended to an accumulator. Appending the lists of the
operands instead would copy the identities of a first operand once for every
operator above it, which is quadratic in the length of an operator chain.
-}
symbolIds :: CoreFunction -> [Int]
symbolIds function =
    symbolIdValue (resolvedSymbol (coreFunctionName function))
        : map (symbolIdValue . resolvedSymbol . fst) (coreFunctionParameters function)
        ++ statementsSymbolIds (coreFunctionBody function) []

statementsSymbolIds :: [CoreStatement] -> [Int] -> [Int]
statementsSymbolIds statements rest = foldr statementSymbolIds rest statements

statementSymbolIds :: CoreStatement -> [Int] -> [Int]
statementSymbolIds statement rest = case statement of
    CoreBind binding -> symbol (coreBindingName binding) : expressionSymbolIds (coreBindingValue binding) rest
    CoreAssign name expression -> symbol name : expressionSymbolIds expression rest
    CoreReturn expression -> expressionSymbolIds expression rest
    CoreIf condition trueBranch falseBranch ->
        expressionSymbolIds condition (statementsSymbolIds trueBranch (statementsSymbolIds falseBranch rest))
    CoreWhile condition body -> expressionSymbolIds condition (statementsSymbolIds body rest)
    CoreDoWhile body condition -> statementsSymbolIds body (expressionSymbolIds condition rest)
    CoreFor condition body update ->
        expressionSymbolIds condition (statementsSymbolIds body (statementsSymbolIds update rest))
    CoreBreak -> rest
    CoreContinue -> rest
    CoreEvaluate expression -> expressionSymbolIds expression rest
    where
        symbol = symbolIdValue . resolvedSymbol

expressionSymbolIds :: CoreExpression -> [Int] -> [Int]
expressionSymbolIds expression rest = case expression of
    CoreVariable name _ -> symbol name : rest
    CoreLiteral _ _ -> rest
    CoreApply callee arguments _ -> expressionSymbolIds callee (expressions arguments rest)
    CorePrimitive _ arguments _ -> expressions arguments rest
    CoreLet name _ value body _ -> symbol name : expressionSymbolIds value (expressionSymbolIds body rest)
    CoreConditional condition whenTrue whenFalse _ -> expressions [condition, whenTrue, whenFalse] rest
    CoreClosure captures parameters _ body _ ->
        map (symbol . coreCaptureName) captures
            ++ expressions
                (map coreCaptureValue captures)
                (map (symbol . fst) parameters ++ statementsSymbolIds body rest)
    where
        symbol = symbolIdValue . resolvedSymbol
        expressions values after = foldr expressionSymbolIds after values

{- | Lower statements into blocks, ending the last open block with the given
terminator and placing the given blocks after the ones produced.

Both arguments exist so that the work is linear in the size of the body. A
branch or a loop body falls through to a known block; passing that jump down
ends the region with it directly, where patching the blocks afterwards would
visit every block of a nested region once per enclosing region. The blocks
that follow are passed in so that they are consed onto, where appending them
would copy the blocks of a nested region once per enclosing region; an
@else if@ chain is such a nest, one level per link.

Only the last block of a region can be left open: a @return@, @break@ or
@continue@ closes its block and drops the statements after it, and every
nested region is closed by its own terminator.
-}
prepareStatementsTo ::
    CorePrepTerminator -> PrepState -> OpenBlock -> [CoreStatement] -> [CorePrepBlock] -> ([CorePrepBlock], PrepState)
prepareStatementsTo end state open [] rest = (closeBlock open end : rest, state)
prepareStatementsTo end state open (statement : remaining) rest = case statement of
    CoreBind binding ->
        let (closed, continued, operation, after) = atomizeOperation state open (coreBindingValue binding)
            instruction = CorePrepBind (coreBindingName binding) (coreBindingType binding) (coreBindingMutable binding) operation
            (later, final) = prepareStatementsTo end after (appendInstruction continued instruction) remaining rest
         in (closed ++ later, final)
    CoreAssign name value ->
        let (closed, continued, atom, after) = atomize state open value
            (later, final) = prepareStatementsTo end after (appendInstruction continued (CorePrepAssign name atom)) remaining rest
         in (closed ++ later, final)
    CoreEvaluate value
        | discardsItsOperation value ->
            let (closed, continued, operation, after) = atomizeOperation state open value
                (later, final) =
                    prepareStatementsTo end after (appendInstruction continued (CorePrepEvaluate operation)) remaining rest
             in (closed ++ later, final)
        | otherwise ->
            -- Only a call may be an instruction whose result is dropped.
            -- Any other value is computed into an ordinary temporary, so
            -- its operands still run and may trap, and the unused atom is
            -- ignored.
            let (closed, continued, _, after) = atomize state open value
                (later, final) = prepareStatementsTo end after continued remaining rest
             in (closed ++ later, final)
    CoreReturn value ->
        let (closed, continued, atom, after) = atomize state open value
         in (closed ++ closeBlock continued (CorePrepReturn atom) : rest, after)
    CoreIf condition trueBranch falseBranch ->
        let (conditionBlocks, conditionOpen, conditionAtom, afterCondition) = atomize state open condition
            (booleanOpen, booleanAtom, afterBoolean) = booleanizeAtom afterCondition conditionOpen conditionAtom
            trueId = nextBlock afterBoolean
            falseId = trueId + 1
            joinId = falseId + 1
            branchState = afterBoolean {nextBlock = joinId + 1}
            -- The states are threaded in source order. The block lists are
            -- built back to front: each region is consed onto the blocks
            -- that follow it, which laziness allows although those depend
            -- on a later state.
            (trueBlocks, afterTrue) = prepareBranchTo branchState trueId joinId trueBranch falseBlocks
            (falseBlocks, afterFalse) = prepareBranchTo afterTrue falseId joinId falseBranch tailBlocks
            header = closeBlock booleanOpen (CorePrepBranch booleanAtom trueId falseId)
            (tailBlocks, final) = prepareStatementsTo end afterFalse (OpenBlock joinId []) remaining rest
         in (conditionBlocks ++ header : trueBlocks, final)
    CoreWhile condition body ->
        let (loopBlocks, exitOpen, afterLoop) = prepareWhile state open condition body
            (tailBlocks, final) = prepareStatementsTo end afterLoop exitOpen remaining rest
         in (loopBlocks ++ tailBlocks, final)
    CoreDoWhile body condition ->
        let (loopBlocks, exitOpen, afterLoop) = prepareDoWhile state open body condition
            (tailBlocks, final) = prepareStatementsTo end afterLoop exitOpen remaining rest
         in (loopBlocks ++ tailBlocks, final)
    CoreFor condition body update ->
        let (loopBlocks, exitOpen, afterLoop) = prepareFor state open condition body update
            (tailBlocks, final) = prepareStatementsTo end afterLoop exitOpen remaining rest
         in (loopBlocks ++ tailBlocks, final)
    CoreBreak -> onto (closeLoopControl state open True)
    CoreContinue -> onto (closeLoopControl state open False)
    where
        onto (blocks, after) = (blocks ++ rest, after)

{- | Close the current block at the innermost loop transfer destination.
The Boolean selects @break@ (exit) versus @continue@ (continuation point);
Core verification rejects either transfer when this stack is empty.
-}
closeLoopControl :: PrepState -> OpenBlock -> Bool -> ([CorePrepBlock], PrepState)
closeLoopControl state open isBreak = case loopTargets state of
    (breakTarget, continueTarget) : _ ->
        let target = if isBreak then breakTarget else continueTarget
         in ([closeBlock open (CorePrepJump target)], state)
    [] -> ([closeBlock open CorePrepUnreachable], state)

-- | Lower a pre-test loop and route its body fallthrough to the condition.
prepareWhile ::
    PrepState ->
    OpenBlock ->
    CoreExpression ->
    [CoreStatement] ->
    ([CorePrepBlock], OpenBlock, PrepState)
prepareWhile state incoming condition body =
    let conditionId = nextBlock state
        bodyId = conditionId + 1
        exitId = bodyId + 1
        reserved = state {nextBlock = exitId + 1}
        entry = closeBlock incoming (CorePrepJump conditionId)
        (conditionBlocks, conditionOpen, atom, afterCondition) =
            atomize reserved (OpenBlock conditionId []) condition
        (booleanOpen, predicate, afterBoolean) = booleanizeAtom afterCondition conditionOpen atom
        branch = closeBlock booleanOpen (CorePrepBranch predicate bodyId exitId)
        bodyState = afterBoolean {loopTargets = (exitId, conditionId) : loopTargets afterBoolean}
        (bodyEnd, afterBody) = prepareStatementsTo (CorePrepJump conditionId) bodyState (OpenBlock bodyId []) body []
        finalState = afterBody {loopTargets = loopTargets state}
     in ([entry] ++ conditionBlocks ++ [branch] ++ bodyEnd, OpenBlock exitId [], finalState)

-- | Lower a post-test loop so even its first entered body reaches the test.
prepareDoWhile ::
    PrepState ->
    OpenBlock ->
    [CoreStatement] ->
    CoreExpression ->
    ([CorePrepBlock], OpenBlock, PrepState)
prepareDoWhile state incoming body condition =
    let bodyId = nextBlock state
        conditionId = bodyId + 1
        exitId = conditionId + 1
        reserved = state {nextBlock = exitId + 1}
        entry = closeBlock incoming (CorePrepJump bodyId)
        bodyState = reserved {loopTargets = (exitId, conditionId) : loopTargets state}
        (bodyEnd, afterBody) = prepareStatementsTo (CorePrepJump conditionId) bodyState (OpenBlock bodyId []) body []
        (conditionBlocks, conditionOpen, atom, afterCondition) =
            atomize afterBody (OpenBlock conditionId []) condition
        (booleanOpen, predicate, afterBoolean) = booleanizeAtom afterCondition conditionOpen atom
        branch = closeBlock booleanOpen (CorePrepBranch predicate bodyId exitId)
        finalState = afterBoolean {loopTargets = loopTargets state}
     in ([entry] ++ bodyEnd ++ conditionBlocks ++ [branch], OpenBlock exitId [], finalState)

-- | Lower a classic loop with a dedicated update block used by @continue@.
prepareFor ::
    PrepState ->
    OpenBlock ->
    CoreExpression ->
    [CoreStatement] ->
    [CoreStatement] ->
    ([CorePrepBlock], OpenBlock, PrepState)
prepareFor state incoming condition body update =
    let conditionId = nextBlock state
        bodyId = conditionId + 1
        updateId = bodyId + 1
        exitId = updateId + 1
        reserved = state {nextBlock = exitId + 1}
        entry = closeBlock incoming (CorePrepJump conditionId)
        (conditionBlocks, conditionOpen, atom, afterCondition) =
            atomize reserved (OpenBlock conditionId []) condition
        (booleanOpen, predicate, afterBoolean) = booleanizeAtom afterCondition conditionOpen atom
        branch = closeBlock booleanOpen (CorePrepBranch predicate bodyId exitId)
        bodyState = afterBoolean {loopTargets = (exitId, updateId) : loopTargets afterBoolean}
        (bodyEnd, afterBody) = prepareStatementsTo (CorePrepJump updateId) bodyState (OpenBlock bodyId []) body []
        updateState = afterBody {loopTargets = (exitId, updateId) : loopTargets state}
        (updateEnd, afterUpdate) =
            prepareStatementsTo (CorePrepJump conditionId) updateState (OpenBlock updateId []) update []
        finalState = afterUpdate {loopTargets = loopTargets state}
     in ([entry] ++ conditionBlocks ++ [branch] ++ bodyEnd ++ updateEnd, OpenBlock exitId [], finalState)

{- | Whether an evaluated expression lowers to one result-discarding
instruction. The record has no result type on the wire; a reader recovers
it from the callee, which only a call has. A discarded closure creation is
therefore bound like any other value.
-}
discardsItsOperation :: CoreExpression -> Bool
discardsItsOperation expression = case expression of
    CoreApply {} -> True
    _ -> False

appendInstruction :: OpenBlock -> CorePrepInstruction -> OpenBlock
appendInstruction open instruction =
    open {openBlockInstructions = instruction : openBlockInstructions open}

closeBlock :: OpenBlock -> CorePrepTerminator -> CorePrepBlock
closeBlock open terminator =
    CorePrepBlock (openBlockId open) (reverse (openBlockInstructions open)) terminator

-- Numeric conditions are a source-language convenience. Core retains their
-- numeric type for optimization, while CorePrep makes the zero comparison
-- explicit so every native branch still consumes a canonical bool atom. The
-- zero has the literal form of the operand type, a floating zero for a
-- floating operand, exactly as the native adapter spells it.
booleanizeAtom :: PrepState -> OpenBlock -> CorePrepAtom -> (OpenBlock, CorePrepAtom, PrepState)
booleanizeAtom state open atom
    | corePrepAtomType atom == boolType = (open, atom, state)
    | otherwise =
        let identifier = nextTemporary state
            temporary = ResolvedName (SymbolId identifier) (Identifier ("$condition" ++ show identifier))
            zero = zeroAtom (corePrepAtomType atom)
            instruction = CorePrepBind temporary boolType False (CorePrepPrimitive CoreNotEqual [atom, zero])
         in (appendInstruction open instruction, CorePrepVariable temporary boolType, state {nextTemporary = identifier + 1})

booleanizeMany :: PrepState -> OpenBlock -> [CorePrepAtom] -> (OpenBlock, [CorePrepAtom], PrepState)
booleanizeMany state open [] = (open, [], state)
booleanizeMany state open (atom : remaining) =
    let (continued, boolean, after) = booleanizeAtom state open atom
        (finalOpen, later, final) = booleanizeMany after continued remaining
     in (finalOpen, boolean : later, final)

corePrepAtomType :: CorePrepAtom -> Type
corePrepAtomType atom = case atom of
    CorePrepVariable _ valueType -> valueType
    CorePrepLiteral _ valueType -> valueType

-- | Lower one branch of a conditional: it falls through to the join block.
prepareBranchTo :: PrepState -> Int -> Int -> [CoreStatement] -> [CorePrepBlock] -> ([CorePrepBlock], PrepState)
prepareBranchTo state blockId joinId =
    prepareStatementsTo (CorePrepJump joinId) state (OpenBlock blockId [])

atomize :: PrepState -> OpenBlock -> CoreExpression -> ([CorePrepBlock], OpenBlock, CorePrepAtom, PrepState)
atomize state open expression = case expression of
    CoreVariable name valueType -> ([], open, CorePrepVariable name valueType, state)
    CoreLiteral literal valueType -> ([], open, CorePrepLiteral literal valueType, state)
    CoreLet name valueType value body _ ->
        let (valueBlocks, valueOpen, valueOperation, afterValue) = atomizeOperation state open value
            boundOpen = appendInstruction valueOpen (CorePrepBind name valueType False valueOperation)
            (bodyBlocks, bodyOpen, bodyAtom, afterBody) = atomize afterValue boundOpen body
         in (valueBlocks ++ bodyBlocks, bodyOpen, bodyAtom, afterBody)
    CorePrimitive primitive [left, right] _
        | primitive == CoreLogicalAnd || primitive == CoreLogicalOr ->
            atomizeShortCircuit state open primitive left right
    CoreConditional condition whenTrue whenFalse valueType ->
        atomizeConditional state open condition whenTrue whenFalse valueType
    _ ->
        let (closed, continued, operation, afterOperation) = atomizeOperation state open expression
            temporary =
                ResolvedName (SymbolId (nextTemporary afterOperation)) (Identifier ("$coreprep" ++ show (nextTemporary afterOperation)))
            valueType = expressionType expression
            instruction = CorePrepBind temporary valueType False operation
         in ( closed
            , appendInstruction continued instruction
            , CorePrepVariable temporary valueType
            , afterOperation {nextTemporary = nextTemporary afterOperation + 1}
            )

atomizeOperation ::
    PrepState -> OpenBlock -> CoreExpression -> ([CorePrepBlock], OpenBlock, CorePrepOperation, PrepState)
atomizeOperation state open expression = case expression of
    CoreVariable name valueType -> ([], open, CorePrepCopy (CorePrepVariable name valueType), state)
    CoreLiteral literal valueType -> ([], open, CorePrepCopy (CorePrepLiteral literal valueType), state)
    CorePrimitive primitive [left, right] _
        | primitive == CoreLogicalAnd || primitive == CoreLogicalOr ->
            let (closed, continued, atom, after) = atomizeShortCircuit state open primitive left right
             in (closed, continued, CorePrepCopy atom, after)
    CoreConditional condition whenTrue whenFalse valueType ->
        let (closed, continued, atom, after) = atomizeConditional state open condition whenTrue whenFalse valueType
         in (closed, continued, CorePrepCopy atom, after)
    CoreApply callee arguments _ ->
        let (calleeBlocks, calleeOpen, calleeAtom, afterCallee) = atomize state open callee
            (argumentBlocks, argumentOpen, argumentAtoms, afterArguments) = atomizeMany afterCallee calleeOpen arguments
         in (calleeBlocks ++ argumentBlocks, argumentOpen, CorePrepCall calleeAtom argumentAtoms, afterArguments)
    CorePrimitive primitive arguments _ ->
        let (closed, continued, atoms, after) = atomizeMany state open arguments
            logical = primitive `elem` [CoreLogicalAnd, CoreLogicalOr, CoreLogicalNot]
            (finalOpen, preparedAtoms, final) =
                if logical then booleanizeMany after continued atoms else (continued, atoms, after)
         in (closed, finalOpen, CorePrepPrimitive primitive preparedAtoms, final)
    CoreLet name valueType value body _ ->
        let (valueBlocks, valueOpen, valueOperation, afterValue) = atomizeOperation state open value
            boundOpen = appendInstruction valueOpen (CorePrepBind name valueType False valueOperation)
            (bodyBlocks, bodyOpen, bodyAtom, afterBody) = atomize afterValue boundOpen body
         in (valueBlocks ++ bodyBlocks, bodyOpen, CorePrepCopy bodyAtom, afterBody)
    CoreClosure captures parameters returnType body _ ->
        let closureId = nextTemporary state
            closureName =
                ResolvedName (SymbolId closureId) (Identifier ("$closure" ++ show closureId))
            (captureBlocks, captureOpen, preparedCaptures, afterCaptures) =
                atomizeCaptures
                    (state {nextTemporary = closureId + 1})
                    open
                    captures
            hiddenParameters = [(coreCaptureName capture, coreCaptureType capture) | capture <- captures]
            lifted = CoreFunction closureName (hiddenParameters ++ parameters) returnType body
            finalState =
                afterCaptures
                    { pendingFunctions = pendingFunctions afterCaptures ++ [(lifted, currentSourceFile afterCaptures)]
                    }
         in (captureBlocks, captureOpen, CorePrepMakeClosure closureName preparedCaptures, finalState)

-- Logical conjunction and disjunction are control flow, not ordinary eager
-- primitive instructions. The result slot is initialized before branching and
-- overwritten only on the path that evaluates the right operand. Consequently
-- every join predecessor carries an initialized Bool without requiring a phi
-- node in CorePrep's storage-oriented IR.
atomizeShortCircuit ::
    PrepState ->
    OpenBlock ->
    CorePrimitive ->
    CoreExpression ->
    CoreExpression ->
    ([CorePrepBlock], OpenBlock, CorePrepAtom, PrepState)
atomizeShortCircuit state open primitive left right =
    let (leftBlocks, leftOpen, leftAtom, afterLeft) = atomize state open left
        (conditionOpen, conditionAtom, afterCondition) = booleanizeAtom afterLeft leftOpen leftAtom
        resultId = nextTemporary afterCondition
        resultName = ResolvedName (SymbolId resultId) (Identifier ("$shortcircuit" ++ show resultId))
        resultAtom = CorePrepVariable resultName boolType
        defaultValue = CorePrepLiteral (CoreBoolean (primitive == CoreLogicalOr)) boolType
        initializedOpen =
            appendInstruction conditionOpen (CorePrepBind resultName boolType True (CorePrepCopy defaultValue))
        rightId = nextBlock afterCondition
        joinId = rightId + 1
        afterReservation =
            afterCondition
                { nextTemporary = resultId + 1
                , nextBlock = joinId + 1
                }
        branch =
            if primitive == CoreLogicalAnd
                then CorePrepBranch conditionAtom rightId joinId
                else CorePrepBranch conditionAtom joinId rightId
        header = closeBlock initializedOpen branch
        (rightBlocks, rightOpen, rightAtom, afterRight) =
            atomize afterReservation (OpenBlock rightId []) right
        (booleanRightOpen, booleanRight, final) = booleanizeAtom afterRight rightOpen rightAtom
        assignedRight = appendInstruction booleanRightOpen (CorePrepAssign resultName booleanRight)
        rightExit = closeBlock assignedRight (CorePrepJump joinId)
     in ( leftBlocks ++ [header] ++ rightBlocks ++ [rightExit]
        , OpenBlock joinId []
        , resultAtom
        , final
        )

{- | Lower a conditional expression to a two-way branch over a result slot.

Exactly one arm is evaluated. The slot is bound before the branch with the
neutral literal of its type and each arm overwrites it on its own path, so
the join block reads an initialized value from either predecessor without a
phi node. The neutral value is never observable: no path reaches the join
without passing through one of the two assignments.
-}
atomizeConditional ::
    PrepState ->
    OpenBlock ->
    CoreExpression ->
    CoreExpression ->
    CoreExpression ->
    Type ->
    ([CorePrepBlock], OpenBlock, CorePrepAtom, PrepState)
atomizeConditional state open condition whenTrue whenFalse valueType =
    let (conditionBlocks, conditionOpen, conditionAtom, afterCondition) = atomize state open condition
        (booleanOpen, predicate, afterBoolean) = booleanizeAtom afterCondition conditionOpen conditionAtom
        resultId = nextTemporary afterBoolean
        resultName = ResolvedName (SymbolId resultId) (Identifier ("$conditional" ++ show resultId))
        initializedOpen =
            appendInstruction
                booleanOpen
                (CorePrepBind resultName valueType True (CorePrepCopy (neutralAtom valueType)))
        trueId = nextBlock afterBoolean
        falseId = trueId + 1
        joinId = falseId + 1
        afterReservation =
            afterBoolean
                { nextTemporary = resultId + 1
                , nextBlock = joinId + 1
                }
        header = closeBlock initializedOpen (CorePrepBranch predicate trueId falseId)
        (trueBlocks, trueExit, afterTrue) = prepareArm afterReservation trueId whenTrue
        (falseBlocks, falseExit, afterFalse) = prepareArm afterTrue falseId whenFalse
        prepareArm armState armId arm =
            let (armBlocks, armOpen, armAtom, afterArm) = atomize armState (OpenBlock armId []) arm
                assigned = appendInstruction armOpen (CorePrepAssign resultName armAtom)
             in (armBlocks, closeBlock assigned (CorePrepJump joinId), afterArm)
     in ( conditionBlocks ++ [header] ++ trueBlocks ++ [trueExit] ++ falseBlocks ++ [falseExit]
        , OpenBlock joinId []
        , CorePrepVariable resultName valueType
        , afterFalse
        )

-- | Literal that initializes a storage slot before its first real assignment.
neutralAtom :: Type -> CorePrepAtom
neutralAtom valueType
    | valueType == boolType = CorePrepLiteral (CoreBoolean False) valueType
    | otherwise = zeroAtom valueType

{- | Zero of a numeric type, spelled as the native adapter spells its slot
initializer: a floating zero is a floating literal, not an integer payload
under a floating type.
-}
zeroAtom :: Type -> CorePrepAtom
zeroAtom valueType
    | isCoreFloatingType valueType = CorePrepLiteral (CoreFloating "0") valueType
    | otherwise = CorePrepLiteral (CoreInteger 0) valueType

atomizeMany :: PrepState -> OpenBlock -> [CoreExpression] -> ([CorePrepBlock], OpenBlock, [CorePrepAtom], PrepState)
atomizeMany state open [] = ([], open, [], state)
atomizeMany state open (value : remaining) =
    let (closed, continued, atom, after) = atomize state open value
        (laterBlocks, finalOpen, atoms, final) = atomizeMany after continued remaining
     in (closed ++ laterBlocks, finalOpen, atom : atoms, final)

atomizeCaptures ::
    PrepState ->
    OpenBlock ->
    [CoreCapture] ->
    ([CorePrepBlock], OpenBlock, [CorePrepCapture], PrepState)
atomizeCaptures state open [] = ([], open, [], state)
atomizeCaptures state open (capture : remaining) =
    let (closed, continued, atom, afterValue) = atomize state open (coreCaptureValue capture)
        prepared =
            CorePrepCapture
                (coreCaptureMode capture)
                (coreCaptureName capture)
                (coreCaptureType capture)
                atom
        (laterBlocks, finalOpen, laterCaptures, final) = atomizeCaptures afterValue continued remaining
     in (closed ++ laterBlocks, finalOpen, prepared : laterCaptures, final)
