<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Ownership-flow verification

Tala resolves source ownership before native lowering, but the Xpp and Xmm
layers still defend their own explicit AARC contract. A structurally valid
register is not necessarily a live object reference: it may hold a weak control
handle, an unowned control handle, or a strong handle that has already been
released. The ownership-flow verifier rejects those distinctions before LLVM
emits an unsafe runtime call or load.

This document describes compiler verification. It does not add source syntax,
change the source type system, or make CorePrep a public artifact.

## Stage boundary

Xpp introduces explicit ownership operations after CorePrep:

| Operation | Required input | Produced result | Input after operation |
| --- | --- | --- | --- |
| RetainStrong | live strong | live strong | live strong |
| ReleaseStrong | live strong | none | consumed |
| MakeWeak | live strong | live weak | live strong |
| LockWeak | live weak | live strong | live weak |
| ReleaseWeak | live weak | none | consumed |
| MakeUnowned | live strong | live unowned | live strong |
| LoadUnowned | live unowned | live strong | live unowned |
| ReleaseUnowned | live unowned | none | consumed |

Xmm preserves these operations while replacing symbolic storage with virtual
registers. Both stages use the same analysis model, but each owns its adapter
and diagnostic namespace. This prevents Xpp storage behavior from leaking into
the Xmm register model.

An ordinary AARC operand requires a live strong handle. Weak and unowned values
must first pass through LockWeak or LoadUnowned. A return of an AARC value also
observes a live strong handle because return transfers a usable reference to the
caller.

## Abstract state

For every tracked storage or register, the analysis records a set containing
one or more of these states:

- absent;
- live strong;
- live weak;
- live unowned; and
- consumed.

The set is intentional. At a control-flow join, choosing one predecessor would
make correctness depend on block order. Instead, the analysis unions all
reachable predecessor states. A strong value on one path and a consumed value
on another therefore remains strong plus consumed until a definition replaces
it.

Definitions replace the destination state. An AARC-producing instruction
defines its result as strong unless the operation specifically produces a weak
or unowned handle. A non-AARC definition forgets any ownership fact associated
with reused storage. Reads do not change state. A release converts only its
required live representation to consumed.

## Fixed-point behavior

The analysis runs forward over the function CFG:

    In[entry] = declared AARC parameters as strong; all others absent
    In[B]     = union(Out[P]) for every reachable predecessor P of B
    Out[B]    = transfer(B, In[B])

Entry facts do not include facts from an entry backedge. A value created during
a later loop iteration cannot initialize or resurrect the first entry
execution. Non-entry loops iterate until their state sets stop changing.

The internal lattice bottom used while the fixed point is forming is distinct
from absent. Treating a not-yet-visited predecessor as an actual absent path
would make results depend on traversal order. Regression coverage runs loops
with reversed block vectors to protect this distinction.

Only reachable blocks participate in semantic ownership diagnostics. Structural
verification still reports duplicate blocks, missing entries, and invalid
targets independently.

## Diagnostics

Xpp reserves these ownership diagnostics:

| Code | Meaning |
| --- | --- |
| TAP1042 | a released strong, weak, or unowned handle is used or released again |
| TAP1043 | an operation receives the wrong runtime handle representation |
| TAP1044 | incoming paths disagree about liveness or representation |

Xmm reports the equivalent conditions as TAL1046, TAL1047, and TAL1048. Every
issue carries the owning function, block, and instruction index. Return
diagnostics use the terminator position, which is the instruction count of its
block.

The analysis deliberately leaves absent-only reads to definite initialization.
That pass already has the precise diagnostic for a value that was never
defined on a path. Ownership handles the additional cases that remain after a
value is initialized.

## What the verifier guarantees

Before LLVM lowering, a successful Xpp/Xmm ownership check guarantees:

- no reachable explicit release consumes the same handle twice;
- no reachable ordinary operation or return observes a consumed handle;
- weak-only operations receive weak handles;
- unowned-only operations receive unowned handles;
- strong operations and ordinary AARC uses receive strong handles;
- a join cannot hide a release performed on only some paths; and
- block serialization order cannot select an ownership outcome.

The verifier does not prove leak freedom or decide whether a source-level
object graph contains a cycle. Writing the retains and releases is the job of
ownership placement, described next, whose output this verifier checks.
Concurrent Bacon-Rajan with trial deletion remains a future optional cycle
collector and does not weaken deterministic AARC verification.

## Ownership placement

CorePrep names values and does not say who releases them.
`Progmasoft::Tala::Xpp::PlaceOwnership` runs once, on the Xpp form lowered from
CorePrep and after the Xpp optimizer when that is enabled, and makes ownership
explicit. An Xpp artifact read from disk already carries the result and is not
placed again.

The convention is local to a function, so functions agree without looking at
each other:

| Value | Owner |
| --- | --- |
| parameter | the caller, for the duration of the call; the callee never releases it |
| result | the caller, which receives one reference and releases it |
| local | the function, from the definition to the last use on each path |
| strong capture | the closure, which takes its own reference when it is created and releases it in its destructor |
| computation of a callable that remembers its result | that callable, which takes its own reference when it is created and releases it in its destructor |

From that follow the operations the pass writes:

- a value is released after the instruction that uses it last, and directly
  after the instruction that defines it when nothing uses it;
- a value that dies on one edge of a branch and lives on another is released
  on the edge: at the top of the target when the target has no other
  predecessor, otherwise in a block of its own on that edge;
- a copy of a value that is used again becomes `RetainStrong`; a copy of a
  value that is not used again stays a copy and takes over the reference;
- a returned local leaves with its reference; a returned parameter is retained
  first, because the caller receives an owned result;
- a call whose owned result is discarded defines a symbol, so that the result
  can be released;
- an instruction that reads the symbol it writes reads the old value from a
  symbol of its own, which is released after the new value is stored;
- a parameter that the body assigns is copied into a local at a new entry
  block, with a reference of its own, so that a symbol is either borrowed or
  owned for the whole function.

A value is released after its last use rather than at the end of a source
scope. Xpp has no scopes, and a value that is live at a point has been defined
on every path to that point, so no release has to test whether there is
anything to release. Liveness is computed for the owned symbols alone, with
the analysis the optimizer uses.

A method that is named where a value is expected, rather than called, has no
closure object to point to. The pass creates a closure without captures at
that use; the callee of a direct call stays a method. Before this pass such a
value was the address of the method's code, and calling it read an invoke
pointer out of that code.

What the pass does not do: it does not break reference cycles, it keeps a
value alive until its last use and no longer, which is earlier than the end of
its source scope, and it knows no weak or unowned locals, because the frontend
produces those only as capture modes of a closure.

## Testing

Five layers protect the contract:

1. Talac/Analysis/Tests/OwnershipFlowTests.cpp tests the reusable state
   lattice, fixed point, malformed CFG handling, loops, joins, and deterministic
   facts.
2. Talac/Codegen/Xpp/Tests/OwnershipVerifierTests.cpp tests symbolic storage,
   direct function identities, strong/weak/unowned conversion, returns, and Xpp
   diagnostic codes.
3. Talac/Codegen/Xmm/Tests/OwnershipVerifierTests.cpp repeats the boundary
   cases for typed virtual registers and confirms the main Xmm verifier
   publishes ownership failures.
4. Talac/Codegen/Xpp/Tests/OwnershipPlacementTests.cpp runs the placed
   function on a reference-count model that knows nothing of the pass: along
   every path, taking each loop around once more than it must be entered, each
   reference must be released exactly once and nothing may be used after its
   last release. The model is first shown to reject a leak, a double release
   and a use after release.
5. `source_feature_smoke` runs closure programs through LLVM with the AARC
   runtime, one program at a time, and requires the runtime to hold no more
   allocations after a program than before it, in both pipeline modes. Without
   the placement pass that check fails on the first program. The programs
   that pass arguments by need are held to the same check: each suspended
   computation is two objects, one of which owns the other.

Tests construct a complete operation sequence. Merely asserting that an opcode
exists does not prove its handle precondition, result representation, or
control-flow lifetime.
