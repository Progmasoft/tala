<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Native dataflow engine

The native compiler shares a deterministic worklist scheduler and compact
lattice storage across Xpp and Xmm analyses. This layer begins after CorePrep;
it does not replace the Haskell frontend's type checking or Core validation.

## Control-flow ownership

`AnalyzeControlFlow` remains the single owner of block identity, valid edges,
reachability, predecessor sets, and reverse postorder. Dataflow clients adapt
their stage model into that graph once and consume the resulting facts. They do
not independently infer execution order from a block vector.

The scheduler supports two directions:

- forward passes evaluate in reverse postorder and notify successors after an
  output fact changes; and
- backward passes evaluate in postorder and notify predecessors after an input
  fact changes.

Every reachable block enters the initial queue exactly once. A pending identity
is coalesced, so a diamond cannot add its join block repeatedly before that
block is evaluated. Unknown and unreachable identities cannot be scheduled.
Loops are handled by ordinary change notification rather than recursion.

The scheduler reports block evaluations, change notifications, total schedules,
and peak pending blocks. These counters are not compiler semantics. They exist
so tests can enforce an algorithmic bound without comparing noisy wall-clock
timings.

## Dense lattice storage

Analysis identities are often sparse. Xpp symbols are 64-bit and Xmm virtual
registers are 32-bit, but neither range should determine an allocation size.
Each analysis first builds a sorted catalog from the identities that actually
occur, then maps those identities to dense positions.

`DenseBitSet` stores 64 positions per machine word and provides bounded test,
set, reset, union, intersection, subtraction, count, and ordered enumeration.
Unused bits in the final word are always masked. Binary operations reject
different universe sizes rather than truncating one operand.

The catalog preserves the public identity. A symbol such as
`0xFFFF'FFFF'FFFF'FFF0` occupies one dense position; it does not request an
allocation proportional to its numeric value. Materialized facts translate
positions back to sorted stage identities.

## Definite initialization

Definite initialization is a forward must analysis. Its top value contains all
declared storage. A join intersects reachable predecessor outputs; therefore a
storage remains initialized only when every executable incoming path has
written it. The entry block is always seeded from parameters and other explicit
initial values because a loop backedge cannot initialize the first invocation.

One bit represents each declared Xpp symbol or Xmm register. Intersection and
copy operations therefore process 64 declarations at once. Reads are still
validated at exact instruction or terminator locations after the fixed point is
known. Unknown reads, unknown writes, duplicate declarations, malformed edges,
and reads before initialization retain their existing diagnostics.

## Ownership flow

Ownership is a forward may-state analysis. Each handle can carry any union of
five states: absent, strong, weak, unowned, and consumed. A predecessor join
must retain every possible state because one unsafe incoming path is sufficient
to reject a later observation or release.

The implementation uses five dense bit sets in structure-of-arrays form. A
join combines 64 handles per operation for each state bit. `Define`, `Forget`,
`Observe`, and `Consume` retain the established AARC transfer behavior:

- define replaces all states with one live handle kind;
- forget replaces all states with absent;
- observe validates but does not mutate a token; and
- consume moves the requested live kind to consumed.

A join containing both a valid and invalid state reports a path-state mismatch.
Consumed-only misuse reports use-after-consume, and another live kind reports a
kind mismatch. Absent-only reads remain owned by definite initialization so one
source defect does not produce two competing diagnostics.

## Liveness

Liveness uses the same scheduler in the backward direction. A block exit is the
union of successor entry sets. A retained write kills its destination before
its operands become live. A stage-approved removable write whose destination
is dead contributes neither a result nor operand reads.

The Xpp and Xmm opcode policies remain outside the shared engine. The scheduler
can determine that a result is unused, but only the owning stage can decide
whether removing the instruction preserves traps, calls, allocation, explicit
discard, and AARC effects.

Sparse Xpp symbols and Xmm virtual registers are catalogued once and represented
as dense positions during the fixed point. Analysis clients still receive
sorted stage identities. Optimizers explicitly request retention-only results:
they consume reachability and the retained bit for each instruction, but do not
pay to expand unused live-on-entry, live-on-exit, live-before, and live-after
vectors.

## Materialized and validation-only results

Analysis APIs materialize sorted per-block facts by default. This is appropriate
for tests, diagnostics tooling, and future passes that consume boundary facts.
Production Xpp and Xmm verifiers need only issues. They request validation-only
mode, which runs the same fixed point and exact access validation but does not
expand a dense state into a full identity vector for every block.

This distinction is observable only in the returned `facts` collection. Issue
codes, locations, validity, and worklist statistics are identical. It prevents
an otherwise linear verification from spending quadratic output space on facts
that the caller immediately discards.

## Complexity and regression policy

Long acyclic analysis tests use 1,024 blocks and assert one initial evaluation
per reachable block. Loop tests use a bounded evaluation count rather than
assuming one pass. Dense-set tests cross several 64-bit word boundaries and use
sparse maximum-width identities.

The Google Benchmark fixtures remain the wall-clock complement to these
structural tests. On the 2026-09-14 Windows reference host, the 256-block Xpp
verification fell from the original 1.18 seconds to 7.18 milliseconds. Xmm
verification fell from 1.20 seconds to 7.36 milliseconds. The fitted Xpp
verification curve is linear; Xmm is near-linear and currently fits `N log N`.
Exact observations and environment caveats are recorded under `Benchmarks/`.
