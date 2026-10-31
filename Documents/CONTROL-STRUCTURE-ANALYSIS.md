<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Native control-structure analysis

The native compiler has one structural control-flow model shared by Xpp and Xmm. It computes reachability, dominance,
post-dominance, dominance frontiers, natural loops, irreducible regions, and edge-sensitive control dependence before a
transformation relies on those facts. The analysis lives below either IR so the two lowering stages cannot accidentally
assign different meanings to the same block graph.

This document describes an implementation contract. It does not add source-language syntax and it is not a promise that
every analysis result will become a user-selectable optimization.

The result is intentionally inspectable: tests and later optimization reports can explain the exact structural proof
without scraping a debug dump or depending on LLVM's internal object identity.

## Why this layer exists

Simple block traversal answers only whether a block can be reached. It cannot safely answer questions such as:

- whether a definition executes before every use;
- where a value needs a future merge operation;
- whether moving an instruction out of a loop changes how often it executes;
- whether an instruction executes only after a particular branch edge;
- whether a cycle has one natural header;
- whether a block is guaranteed to execute after another block;
- whether an optimization remains legal when a function has several returns.

Local block order is not evidence for any of these properties. Blocks may be decoded, scheduled, or serialized in a
different vector order without changing the program. All structural results therefore derive from block identities and
explicit terminator edges.

## Ownership

`Talac/Analysis/ControlFlow.cpp` validates the graph and provides canonical reachability, predecessor, successor,
preorder, and reverse-postorder facts. `Talac/Analysis/Dominance.cpp` consumes that result and adds structural facts.
`Talac/Analysis/ControlDependence.cpp` derives edge-sensitive execution dependence from post-dominance.

Xpp and Xmm each own only a small adapter:

```text
Xpp terminator ─┐
                ├─> ControlFlowGraph ─> DominanceResult ─> ControlDependenceResult
Xmm terminator ─┘
```

The adapters deliberately map their own terminator enums with explicit switches. Enum ordinal equality is not a hidden
stage ABI. `Return` and `Unreachable` have no successors, `Jump` has one successor, and `Branch` records true then false.
Traversal may preserve that semantic branch order, while all set-valued public facts are sorted by numeric block identity.

## Graph validity

The structural result retains the underlying `ControlFlowResult`. Duplicate blocks, a missing entry, and missing targets
remain visible as control-flow issues. Analysis can describe the valid portion of malformed input for diagnostics, but
`validForTransformation()` is false. A transforming pass must not use partial facts as proof.

The first record for a duplicate block identity is canonical, matching the base CFG policy. Invalid targets are diagnosed
and excluded from traversal. Unreachable blocks remain in fact tables so diagnostics can identify them, but they receive no
fabricated dominator, post-dominator, frontier, loop, or control-dependence claims.

## Dominance

A block `A` dominates block `B` when every path from the function entry to `B` passes through `A`. Dominance is reflexive:
every reachable block dominates itself. Strict dominance excludes that reflexive case.

For one entry block, the equations are:

```text
Dom(entry) = { entry }
Dom(block) = { block } ∪ intersection(Dom(predecessor))
```

Only reachable predecessors participate. The implementation solves the finite set lattice to a fixed point; it does not
use an arbitrary iteration limit. Set contents and observable fact records are sorted. Sparse 32-bit block identities are
keys, never indexes into a block-sized vector.

The immediate dominator is the deepest strict dominator. Entry has no immediate dominator. The resulting parent relation
is a tree even when the CFG contains joins and cycles.

### Example: diamond

```text
       entry
       /   \
    left   right
       \   /
        join
```

`entry` dominates every block. Neither arm dominates `join`, because the other path avoids it. The immediate dominator of
`join` is `entry`.

## Dominance frontier

The dominance frontier of block `A` contains blocks where paths dominated by `A` meet paths not strictly dominated by
`A`. In the diamond, `join` is in the frontier of both arms. The entry and join have empty frontiers.

This is the structural input for future merge placement and sparse data-flow construction. A pass must still establish the
value-specific facts it needs; membership in a frontier alone does not authorize inserting or deleting an instruction.

Frontiers are calculated from reachable predecessors and immediate-dominator parents. A join with fewer than two distinct
reachable predecessors adds nothing. Duplicate CFG edges do not produce duplicate frontier entries.

## Post-dominance

A block `A` post-dominates block `B` when every terminating path from `B` passes through `A`. The equations run backward
from every reachable exit:

```text
PostDom(exit) = { exit }
PostDom(block) = { block } ∪ intersection(PostDom(successor))
```

A reachable block with no successors is an exit. Several returns are represented as several roots; the implementation does
not invent a public virtual block identity. Consequently a branch whose arms terminate at different exits may have no
immediate post-dominator even though each arm has useful private post-dominance facts.

If a function has no reachable exit, post-dominance is unavailable. The same applies when any reachable block belongs to a
closed region from which no exit can be reached, even if another branch returns. Empty post-dominator sets in that state
mean “not proven,” not “nothing post-dominates this block.” The query API returns false and control-dependence
transformations must decline the graph. This conservative rule prevents an infinite cycle from looking like a successfully
analyzed returning function.

Post-dominance frontier is the reverse counterpart of dominance frontier. It identifies the branch sites on which an
execution region depends.

## Natural loops

An edge from `latch` to `header` is a back edge when `header` dominates `latch`. Its natural loop contains the header,
latch, and every reachable predecessor found by walking backward from the latch until the header boundary.

Each result records:

- the header identity;
- the latch identity, preserving which back edge created the loop;
- sorted member identities;
- sorted unique target blocks reached by edges leaving the member set.

Keeping a result per back edge is intentional. A header may have multiple latches, and a later transformation may need to
split or redirect only one of those edges. Per-block `loopDepth` counts containing natural-loop records, while
`loopHeaders` is unique and sorted. Thus two latches can increase depth while still naming one header. Consumers which need
a canonical merged loop must merge records explicitly and retain the original latches.

Nested loops naturally produce several containing records. A block in an inner loop is also a member of the outer natural
loop when the outer back-edge predecessor walk reaches it.

## Irreducible regions

Not every cyclic CFG is a natural loop. A reachable cyclic strongly connected component is irreducible when no member
dominates every member. The common example is a two-block cycle entered through both blocks.

The analysis finds strongly connected components iteratively, avoiding native call-stack depth as an accepted-IR limit.
An irreducible record contains sorted members and the members with incoming edges from outside the component. A self-loop
or reducible SCC with a dominating header is not reported as irreducible.

Irreducible control flow remains representable. This result is a capability boundary: an optimization that assumes a
natural header must skip or first structurally normalize the region. It must not choose the lowest block identity as a
synthetic header.

## Control dependence

Control dependence answers whether a block executes only because a particular branch outcome was selected. Results retain
three identities:

```text
(controller block, selected successor, dependent block)
```

The successor identity matters. Future predicate placement, profile feedback, and diagnostic explanations may distinguish
true and false arms even when both are controlled by the same branch block.

For every multi-successor controller edge which does not post-dominate its source, analysis walks the immediate
post-dominator chain from that successor up to the controller's immediate post-dominator. Every visited block is dependent
on that exact edge. Duplicate records are removed and the public edge list is lexicographically sorted.

Per-block summaries provide unique sorted direct-controller and direct-dependent identities. Transitive dependence is
obtained by walking controllers; it is not flattened into each record. A block can still have several direct controllers
when distinct control edges govern it. The converged join following a normal diamond is not dependent on either arm. Loop headers may be dependent on
their own continue edge because revisiting the header requires that edge; this is expected and useful to loop-aware passes.

Control dependence is unavailable when post-dominance is unavailable. It may still contain an underlying malformed graph,
but `validForTransformation()` requires both a valid CFG and available post-dominance.

## Determinism

The following are never semantic inputs:

- the order of blocks in an IR vector;
- hash-table iteration order;
- numeric density of block identities;
- duplicate presentation of the same edge.

Depth-first traversal retains declared successor order only for preorder and reverse-postorder layout. Dominator sets,
parents, frontiers, exits, loops, SCC regions, dependence edges, and block fact tables are deterministic. Tests reverse
block vectors, vary branch successor order, use sparse identities, and exercise deep graphs.

## Complexity and limits

The current fixed-point solver favors auditability and deterministic behavior over an asymptotically specialized
Lengauer–Tarjan implementation. This is appropriate for the current CorePrep-to-Xmm function sizes and makes malformed
graphs easier to diagnose. The API isolates the algorithm so a faster implementation can replace it without changing Xpp
or Xmm semantics.

Set memory grows with reachable blocks in one function, not with the maximum numeric block identity. Traversal and SCC
discovery are iterative. Tests include deep acyclic and cyclic inputs to ensure native recursion depth is not a hidden
resource boundary.

## Transformation rules

A native optimization using these facts must:

1. analyze the current function after structural rewrites which changed edges;
2. require `validForTransformation()`;
3. treat absent post-dominance as unknown;
4. decline irreducible regions unless it explicitly supports them;
5. keep value/type/effect/ownership proofs separate from structural proofs;
6. re-run the stage verifier after rewriting;
7. preserve block and source identity needed by diagnostics.

Dominance does not prove purity. Post-dominance does not prove that moving a potentially failing operation is safe.
Natural-loop membership does not prove loop invariance. Control dependence does not prove that two expressions can be
reordered. Those properties remain owned by effect, ownership, definite-initialization, type, and value analyses.

## Validation

The focused native suite covers:

- singleton, linear, diamond, nested-diamond, multi-exit, and non-terminating graphs;
- reflexive and strict dominance/post-dominance queries;
- immediate parent selection and both frontier directions;
- unreachable and malformed blocks;
- self loops, while-shaped loops, multiple latches, nested loops, and loop exits;
- reducible versus irreducible SCCs;
- edge-sensitive, nested, early-return, and loop control dependence;
- presentation-order, successor-order, duplicate-edge, sparse-identity, and depth invariants;
- Xpp and Xmm adapter agreement after lowering.

Run the portable native gate rather than invoking compiler-specific flags directly:

```powershell
go run ./helpers/cmd/develop test
```

The gate builds the C++20 implementation with the supported standalone LLVM/ClangCL toolchain on Windows and the
corresponding Clang toolchain on supported macOS hosts.
