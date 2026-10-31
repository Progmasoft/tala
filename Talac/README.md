<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Tala compiler

Buildable Tala compiler project.

This project owns the C++20 compiler CLI and Core-to-LLVM driver, the Haskell source-set loader and lexer-through-CorePrep
frontend, compatibility libraries, and compiler tests. Project roots are discovered and merged
by namespace in Haskell rather than mapped from entry names to file paths. Alongside semantic tokens, the syntax package
exports a lossless source-fragment model for tools that must preserve exact comment, escape, and raw-string spelling. The
public driver has no DIMCLI dependency. The retired C lexer/parser and their duplicate semantic pipeline are not part of this
project anymore.

See the [compiler pipeline](../Documents/COMPILER-PIPELINE.md), [architecture](../Documents/ARCHITECTURE.md), and
[building guide](../Documents/BUILDING.md) for component ownership and supported workflows.
The native AARC verifier is described in [ownership-flow verification](../Documents/OWNERSHIP-FLOW.md).
Shared dominance, loop, and control-dependence facts are described in
[native control-structure analysis](../Documents/CONTROL-STRUCTURE-ANALYSIS.md).

## Native structural analysis boundary

Xpp and Xmm do not infer control flow from block-vector order. Their terminators are adapted to the shared
`ControlFlowGraph`, then analyzed through one deterministic dominance implementation. Native passes can query:

- reachable predecessor and successor sets;
- dominators and immediate dominators;
- post-dominators and immediate post-dominators for terminating functions;
- dominance and post-dominance frontiers;
- natural-loop headers, latches, members, exits, and nesting depth;
- irreducible cyclic regions which cannot safely use natural-loop assumptions;
- branch-edge-sensitive control dependence.

Malformed graphs retain diagnostics, but they never authorize transformation. A function without a reachable exit has no
usable post-dominance or control-dependence proof. Optimizers must also keep structural facts separate from effect, type,
definite-initialization, and ownership proofs.

The shared layer is deliberately independent from LLVM. Backend blocks and LLVM dominance utilities are later consumers,
not the source of Xpp/Xmm semantics. This lets the compiler reject or transform malformed native IR before LLVM objects
exist and keeps the CorePrep-to-native boundary target-independent.

### Adding a structural transformation

When a pass changes an edge, it invalidates its current structural result. The pass must analyze the rewritten function
again before making another dominance-sensitive decision. It must also:

1. require a valid CFG result;
2. decline unavailable post-dominance instead of treating empty facts as proof;
3. handle or explicitly skip every reported irreducible region;
4. retain the controlling successor identity when consuming control dependence;
5. run the owning stage verifier after rewriting.

Natural-loop records intentionally preserve one latch per back edge. A pass which wants a merged loop for one header may
union member and exit sets, but it must retain all original latch identities. This avoids silently losing a back edge while
preparing future preheaders or ownership cleanups.

### Testing expectations

New control-flow behavior needs tests at two levels. The generic analysis suite proves graph-theoretic behavior without IR
details. The Xpp or Xmm suite then proves that the owning terminator adapter produces those exact facts. Tests should vary
block presentation order and use non-dense identities whenever ordering or indexing mistakes are plausible.

Do not add a second local dominance implementation to an optimizer. Extend the shared analysis contract when a genuinely
new structural fact is required, and keep the result deterministic enough to compare directly in regression tests.
