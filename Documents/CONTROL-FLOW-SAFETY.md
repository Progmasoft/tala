<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Control-flow safety

This document describes the compiler contracts that keep expression evaluation
order and local storage initialization sound between Core, CorePrep, Xpp, and
Xmm. It documents implemented compiler behavior, not new source-language
syntax. The language rules remain in `Spec/`.

## Why this boundary exists

Core is a typed tree. A Core expression can contain another expression, and a
statement can contain a whole expression tree. Xpp and Xmm are block-oriented
IRs. Their operands are atoms, their instructions execute in order, and their
terminators choose the next block.

That difference is useful, but it creates two failure modes if the boundary is
treated as a mechanical tree flattening operation:

1. an expression whose semantics include conditional evaluation can become an
   eager sequence of instructions; and
2. a storage identity can be known to the module while still lacking a value
   on one path that reaches a read.

CorePrep owns the first problem. The common definite-initialization analysis
and the Xpp/Xmm verifiers own the second.

## Stage responsibilities

### Core

Core preserves typed source semantics after name resolution, type checking,
desugaring, and optimization. Logical conjunction and disjunction are still
represented as typed primitive expressions at this stage. Their presence in a
tree does not grant later stages permission to evaluate both operands.

Core verification checks symbol identity, type consistency, mutability, calls,
returns, and control-flow completeness at the tree level. It does not assign
basic-block identities and does not perform the storage-oriented predecessor
intersection described below.

### CorePrep

CorePrep converts nested expressions to atoms and ordered instructions. It is
an internal compiler adapter. It is not a user-selectable output format and
does not have an `--emit` mode.

Ordinary expressions append instructions to an open block. Logical `&&` and
`||` are different: atomizing either operation closes the current block,
creates a conditional region, and returns a new open join block to the caller.
This lets logical expressions appear anywhere another expression may appear,
including:

- binding initializers;
- assignment values;
- return values;
- conditions;
- call targets;
- call arguments; and
- closure capture initializers.

The continuation is explicit. A caller never assumes that atomizing an
expression leaves it in the block where atomization began.

### Xpp

Xpp has symbolic storage and explicit blocks. Its verifier first builds a
complete storage catalog from parameters and definitions. Catalog membership
answers “does this identity exist and what is its type?” It does not answer
“does this storage contain a value on this path?”

After structural and type checks, the verifier translates the function to the
common definite-initialization model. A read of existing but uninitialized
storage produces `TAP1041` before Xmm lowering.

Direct function identities are not local storage reads. A closure held in a
local symbol is a storage read even though its type is callable. This
distinction prevents false positives for direct calls without hiding an
uninitialized closure value.

### Xmm

Xmm assigns virtual registers and is the final verified input to LLVM
lowering. Register types are cataloged from parameters and all
result-producing instructions before bodies are checked. Consequently, a
function's block vector may be serialized or optimized in any order without
changing whether a register identity is known.

The Xmm verifier then applies definite initialization using CFG edges. A read
of a known register with no value on every incoming path produces `TAL1045`.
Undefined registers and incompatible register types remain separate errors.

### LLVM lowering

LLVM lowering consumes verified Xmm. It may rely on these facts:

- every register operand names declared storage;
- every reachable register read has a dominating initialization in the
  storage-oriented sense defined here;
- branch targets exist;
- branch conditions have Boolean type; and
- block vector order is presentation order, never execution order.

The lowering layer must still construct valid LLVM IR and run LLVM
verification. The earlier contract narrows the possible failures; it does not
replace LLVM's verifier.

## Short-circuit lowering

### Conjunction

For `left && right`, CorePrep performs the following logical transformation:

```text
current:
    leftValue = evaluate left
    leftBool = booleanize leftValue
    result = false
    branch leftBool, evaluateRight, join

evaluateRight:
    rightValue = evaluate right
    rightBool = booleanize rightValue
    result = rightBool
    jump join

join:
    continue with result
```

If `leftBool` is false, control reaches the join without entering the right
region. The pre-branch `false` seed is therefore the correct result and also
makes `result` initialized on every join predecessor.

### Disjunction

For `left || right`, the seed and branch edges change:

```text
current:
    leftValue = evaluate left
    leftBool = booleanize leftValue
    result = true
    branch leftBool, join, evaluateRight

evaluateRight:
    rightValue = evaluate right
    rightBool = booleanize rightValue
    result = rightBool
    jump join

join:
    continue with result
```

If `leftBool` is true, control reaches the join immediately. The right operand
is not evaluated and the seeded result remains true.

### Booleanization

Core can retain a numeric condition. CorePrep makes native branching explicit
by converting a numeric atom to a comparison against zero. Boolean atoms pass
through unchanged.

Booleanization occurs separately for the left and right operands. In
particular, converting the right operand must remain inside the right-hand
region. Hoisting its comparison to the header would evaluate data derived from
the right operand on a short-circuited path.

### Nested expressions

Nested logical expressions compose because atomization returns both closed
blocks and an open continuation. For example, the right operand of an outer
conjunction may itself produce a header, right region, and join. The outer
operation connects its assignment to the inner operation's returned join,
not to the block where the inner operation started.

Every generated logical expression owns:

- one mutable Boolean result identity;
- one seed before its first branch;
- one conditional assignment in its right-hand region;
- one right-hand entry block; and
- one join block.

Generated symbol identities and block identities are allocated from shared
function preparation state. Nested expressions therefore cannot accidentally
reuse an outer result or block.

### Effects

Calls, closure creation, and later effectful operations in the right operand
must be located only in the right-hand region. This is the observable purpose
of short-circuit lowering. Merely computing the correct final Boolean while
executing both operands is not conforming behavior.

Optimizations may remove a region only when the Core optimizer has proved the
corresponding path unreachable without changing effects. CorePrep itself does
not speculate the right operand.

## Definite initialization

### Storage catalog versus flow facts

The analysis deliberately separates declarations from initialization:

- `declarations` contains every storage identity whose type and ownership are
  known;
- `initiallyInitialized` contains parameters and any other values supplied by
  the external entry edge;
- an instruction read refers to one or more declared identities;
- an instruction write initializes one declared identity after its reads; and
- a terminator may read storage but cannot initialize a successor.

This separation allows diagnostics to distinguish an unknown identity from a
known local read too early.

### Access order

Reads at an access point occur before its optional write. This matters for
self-referential definitions and updates. An instruction equivalent to
`destination = destination + 1` requires `destination` to be initialized
before the instruction begins, even though the instruction writes it before
the next instruction.

Each access retains its original instruction index and whether it represents
a terminator. Stage verifiers can therefore report a stable location without
reconstructing it after data-flow analysis.

### Reachability

Reachability starts at the function entry and follows only valid successor
targets. Reads in unreachable blocks do not represent executions and do not
produce read-before-initialization errors.

Unreachable blocks remain visible in returned facts with `reachable == false`
and empty entry/exit sets. Structural errors in those blocks are still owned
by the stage verifier. Ignoring an unreachable read is not permission to
ignore malformed IR.

### Forward must analysis

Definite initialization is a forward must analysis. A storage identity is
initialized on entry to a block only if it is initialized on exit from every
reachable predecessor.

For a non-entry block `B`:

```text
IN[B]  = intersection of OUT[P] for each reachable predecessor P
OUT[B] = IN[B] union writes performed by B
```

The entry block has an external predecessor that supplies exactly the initial
set:

```text
IN[entry] = initiallyInitialized
```

Backedges to the entry cannot enlarge that seed. Otherwise a write late in a
loop could make a read on the function's first invocation appear safe.

### Fixed-point initialization

Reachable non-entry blocks begin at the lattice top: all declared storage is
tentatively initialized. Repeated predecessor intersection can only remove
facts, and a block's local writes add the same facts on each iteration. The
finite storage set guarantees convergence.

Starting a must analysis at the empty set would be safe but imprecise for
loops: mutually reachable blocks could never discover values established by a
preheader. Starting at top and descending computes the greatest fixed point
consistent with the entry seed.

### Diamonds

Consider a branch with two successors that join:

```text
entry -> truePath  -> join
      -> falsePath -> join
```

If only `truePath` writes `value`, then `value` is absent from `IN[join]` and a
read in `join` is rejected. If both paths write it, the intersection retains
it. An unreachable predecessor is excluded because it cannot contribute an
execution reaching the join.

This is exactly the property used by CorePrep's short-circuit result seed: the
seed occurs before the branch, so both successors inherit initialization even
though only the right-hand region overwrites the value.

### Loops

A value initialized in a loop preheader remains initialized through the body,
backedge, and exits. A value written only in the body is not initialized on the
first body entry. The predecessor intersection preserves that difference.

Self-loops follow the same rule. If the entry edge reaches a self-loop with no
value, a write later in that same block cannot satisfy a read earlier in the
block.

### Determinism

The analysis uses block identities and explicit successor edges. The order of
blocks in a vector has no semantic meaning. This is required because wire
decoders, optimizers, debugging tools, and tests may choose different stable
presentation orders.

Observable block facts are sorted by block identity. Storage identities within
entry and exit facts are also sorted. Stable output keeps tests and diagnostics
reproducible without leaking hash-table iteration order.

## CFG canonicalization after CorePrep

Xpp and Xmm share a target-independent control-flow analysis instead of each
stage reconstructing reachability from container order. The adapter exposes
only block identities and ordered successor identities, so it can be reused by
symbolic Xpp and register-based Xmm without weakening either stage's verifier.

The common result contains two deliberately different views of the graph:

- semantic traversal follows the terminator's declared successor order; and
- observable predecessor, successor, and block-fact collections are sorted by
  identity for reproducible diagnostics and tests.

This distinction matters for branches. Canonical block layout may place the
false destination before the true destination, but the branch operands and
their meaning remain unchanged.

### Conservative trampoline threading

An empty block whose only terminator is an unconditional jump is a trampoline.
Xpp and Xmm may redirect an incoming edge through a chain of such blocks. A
block containing even one instruction is not a trampoline: its work may have
effects, define storage, or carry ownership operations that must execute.

Threading uses explicit cycle detection. A self-loop or a multi-block jump
cycle is retained rather than followed indefinitely. Missing targets are also
left for the owning verifier to diagnose; canonicalization never invents a
replacement destination.

After redirection, a conditional branch whose true and false destinations are
identical becomes an unconditional jump. The condition no longer selects
observable control flow at Xpp/Xmm, and condition-producing instructions remain
in place unless a separate effect-aware pass proves they are dead.

### Reachable layout

Once edges are canonical, unreachable blocks are removed and the remaining
blocks are placed in reverse postorder from the explicit function entry. This
does not define execution order; terminators still do that. It provides a
stable presentation that keeps serialized artifacts and backend iteration
independent of the order in which an earlier producer happened to append
blocks.

The pass is idempotent. Running it repeatedly neither renumbers identities nor
changes an already canonical graph.

### Deterministic Xmm registers

Virtual-register identities must not depend on block presentation. Xmm reserves
parameter registers first in declaration order because that order is part of
the function ABI. It then reserves result-producing local symbols in ascending
`SymbolId` order before lowering any instruction or terminator.

Operand-only identities are still rejected by verification when they do not
name a parameter or definition. Their encounter order cannot perturb valid
local destinations. Consequently, decoding the same Xpp graph with a different
block vector order produces the same parameter and local register mapping.

## Structural issues

The common analysis can report the following model-level issues:

| Issue | Meaning |
| --- | --- |
| `DuplicateBlock` | Two block records use the same identity. |
| `MissingEntry` | The declared entry identity has no block. |
| `MissingTarget` | A successor edge names no block. |
| `DuplicateDeclaration` | Storage is declared more than once. |
| `UnknownInitialStorage` | The external seed names undeclared storage. |
| `UnknownReadStorage` | An access reads undeclared storage. |
| `UnknownWriteStorage` | An access writes undeclared storage. |
| `ReadBeforeInitialization` | Reachable declared storage is read before every incoming path initializes it. |

Xpp and Xmm already own richer structural diagnostics, so their adapters use
the common result primarily for `ReadBeforeInitialization`. The other issue
kinds make the common API independently testable and safe for future analyses
that construct its model directly.

## Diagnostic ownership

`TAP1041` means that Xpp symbolic storage exists and has a valid type, but its
value is unavailable on at least one reachable path. The diagnostic identifies
the function, block, and instruction or terminator position.

`TAL1045` is the equivalent Xmm virtual-register failure. Reaching it after a
verified Xpp module generally indicates a lowering or optimization bug. It is
still checked because Xmm is a serializable boundary and native APIs can build
or decode Xmm independently.

Neither diagnostic should be replaced by “undefined symbol/register.” An
undefined identity is a catalog failure. Conflating it with flow state makes
both compiler bugs harder to locate.

## Testing contract

### CorePrep tests

CorePrep tests must assert structure as well as final type:

- no eager `CoreLogicalAnd` or `CoreLogicalOr` primitive remains;
- the branch condition is Boolean;
- the result seed has the correct value;
- the right operand assigns the result only in its region;
- all targets exist and generated identities are unique;
- nested expressions return the correct continuation; and
- the CorePrep verifier accepts the produced module.

A test that checks only the final Boolean type does not detect accidental eager
evaluation.

### Common analysis tests

The component-owned analysis suite covers straight-line code, access order,
diamonds, nested joins, loops, entry backedges, unreachable blocks, malformed
models, deterministic fact ordering, and shuffled block vectors.

Tests assert returned boundary facts where possible. A single diagnostic can
show that one example failed, but facts show why the fixed point reached that
decision.

### Xpp and Xmm tests

Stage suites construct their actual IR types and verify stage diagnostics.
They cover parameters, instruction operands, terminators, joins, loops,
unreachable blocks, and block reordering. Xpp additionally distinguishes
direct function identities from callable local storage. Xmm additionally
checks that register type discovery is block-order independent.

### Required local commands

Focused native builds are:

```text
bazelisk build //Talac/Analysis/Tests:definite_initialization_tests
bazelisk build //Talac/Codegen/Xpp/Tests:xpp_verifier_tests
bazelisk build //Talac/Codegen/Xmm/Tests:xmm_verifier_tests
```

The Haskell frontend suite is:

```text
cd Compiler
cabal test tala-compiler-tests --test-show-details=direct
```

Repository-wide verification remains required before publishing a compiler
change. Focused commands shorten iteration; they do not replace the full gate.
`go run ./helpers/cmd/develop test` builds and executes all three programs as part
of the native repository gate.

## Review checklist

When changing expression lowering:

1. Identify whether the expression can close the current block.
2. Thread the returned continuation through its parent expression.
3. Keep conditional effects inside their conditional region.
4. Ensure every generated result is initialized on all join predecessors.
5. Verify nested use in calls, bindings, assignments, returns, conditions, and
   captures.

When adding or changing an Xpp/Xmm instruction:

1. Classify every operand as a storage read, literal, or direct identity.
2. Classify the destination as absent or a post-read write.
3. Preserve the source instruction index in the common model.
4. Add terminator reads when the instruction influences control flow or return.
5. Test the operation before and after initialization.
6. Test it in a joined CFG where one predecessor omits the write.

When changing CFG representation:

1. Keep execution order in edges, not container order.
2. Make entry identity explicit.
3. Reject missing targets before native lowering.
4. Preserve unreachable blocks without treating them as executions.
5. Re-run permutation tests and loop fixed-point tests.

## Non-goals

This analysis is not a replacement for:

- source-level definite assignment rules that may later provide earlier and
  more user-oriented diagnostics;
- ownership-state analysis for strong, weak, or unowned AARC values;
- lifetime, liveness, or move analysis;
- dominance calculation for SSA construction;
- Core effect analysis;
- LLVM IR verification; or
- the planned Concurrent Bacon-Rajan and trial-deletion cycle collector.

The model is intentionally small so Xpp and Xmm share one correct answer to a
specific question: on every reachable path to this read, has this storage
already received a value?
