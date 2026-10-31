<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Native liveness and dead-code elimination

Tala performs target-independent native liveness analysis after CorePrep.
The analysis is shared by Xpp and Xmm, while each stage retains ownership of
the opcode policy that decides whether an unused result may be removed.

## Why liveness is shared

Xpp identifies values by 64-bit `SymbolId`. Xmm identifies them by 32-bit
virtual registers. Both representations nevertheless answer the same control-
flow question:

> Can an execution starting after this instruction still read this storage?

The shared analysis widens both identities to a 64-bit storage key. It consumes
only block identity, explicit successor edges, ordered reads, and an optional
write. It does not import Xpp or Xmm types, opcodes, ownership rules, or wire
records.

The result exposes deterministic facts for every reachable block and access:

- the live set on block entry and exit;
- the live set immediately before and after each instruction;
- the original instruction index and terminator marker; and
- whether a stage-marked removable write is retained.

Observable facts are sorted by storage identity. Block vector order is only a
presentation detail and cannot change the fixed point.

## Backward fixed point

Liveness is a backward may analysis. A block exit contains the union of all
reachable successor entry sets. Instructions are then transferred in reverse
execution order:

1. a retained write kills its destination;
2. its reads become live;
3. an instruction without a write is always retained; and
4. a removable write is dropped when its destination is not live afterward.

When a removable write is dropped, its operands are not added to the live set.
This distinction removes an entire unused producer chain in one fixed-point
result. Treating the reads of an already-dead instruction as live would require
one optimizer iteration per instruction and would turn a long chain into a
quadratic pass.

Loops converge through monotone set union. The entry block is not special for
backward liveness: a backedge may legitimately keep a loop-carried value live.
Malformed control flow remains diagnostic, and unreachable blocks receive
conservative non-removal facts. Optimizers therefore never obtain permission
to rewrite malformed or unreachable input from fabricated liveness evidence.

## Xpp policy

The Xpp adapter distinguishes direct function symbols from local closure
storage. A direct callee is callable identity rather than a storage read;
function-typed local symbols remain ordinary live values.

The first connected elimination rule is deliberately narrow. Only a `Define`
`Copy` may be removed when its destination is dead. The following operations
remain observable:

- `Store`, because it mutates an existing source-language location;
- `Discard`, because it preserves explicit evaluation;
- calls and closure allocation;
- arithmetic whose exact trap behavior has not been proven removable; and
- every strong, weak, and unowned ownership operation.

This policy allows unused literal and copy chains to disappear without using
dead-code elimination as an implicit exception or AARC rewrite.

## Xmm policy

Xmm applies the same facts to virtual registers. A result-producing
`LoadImmediate` or `Move` is removable when its register is dead. Instructions
without a result are observable even when their opcode also has a pure
result-producing form. Calls, arithmetic, closure construction, and ownership
operations are retained.

The narrower Xmm model does not make Xpp facts authoritative. An `.xmm`
artifact can enter the pipeline directly, so Xmm constructs and applies its own
liveness model before LLVM lowering.

## Optimizer ordering

Both native optimizers use this order until it stabilizes:

1. remove blocks absent from reachable control-flow traversal;
2. remove dead stage-approved materializations;
3. resolve empty jump trampolines with a memoized path walk; and
4. repeat when an instruction or edge change exposed more cleanup.

Self-copies and self-moves remain a separate no-op rule. Trampoline resolution
does not invoke dominance, post-dominance, loop, or control-dependence analysis;
those are proof systems for transformations that need them. Reachability alone
is sufficient here, and using the complete structural analysis made long jump
chains unnecessarily quadratic.

Cycles are not collapsed to an invented representative. Every edge inside an
empty trampoline cycle is preserved, while an acyclic prefix may be shortened
to the cycle entry. A pass therefore cannot turn a non-returning region into a
returning one.

## Correctness boundary

Liveness is permission, not validation. The production pipeline verifies a
stage before optimization and verifies the optimized result again. The shared
analysis additionally rejects malformed CFG input, and the stage adapters
decline elimination when that result is invalid.

Regression coverage includes dead and live producer chains, observable stores
and discard evaluation, branch unions, loop-carried values, unreachable blocks,
block-order independence, malformed edges, trampoline chains, cycles,
idempotence, and post-optimization Xpp/Xmm verification.

The benchmark suites under each stage measure fresh by-value modules. The
2026-09-13 follow-up measurement changed both Xpp and Xmm optimizer growth from
quadratic to linear for the chain fixture; the exact host results are recorded
under `Benchmarks/`.
