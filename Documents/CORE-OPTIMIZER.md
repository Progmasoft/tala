<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Core optimization

## Purpose

The Core optimizer is the target-independent simplification boundary between
desugaring and CorePrep. It improves the semantic Core tree while names still
carry stable `SymbolId` identities and types still use the frontend type model.
It does not construct a control-flow graph, select a target instruction, infer
an ABI, or perform LLVM work.

The pipeline is designed around three rules:

1. accept only Core that passes the Core verifier;
2. preserve observable evaluation while simplifying values and control flow;
3. verify the final Core again before returning it to the compiler driver.

These checks are part of the optimizer API rather than assumptions made by its
callers. A tool loading a `.core` artifact receives the same safety boundary as
the normal source compiler.

## Position in the compiler

```text
Typed AST
   |
   v
Desugarer
   |
   v
Core verifier ---- rejects malformed symbols, types, calls, and returns
   |
   v
Core optimizer ---- effect inference, bounded inlining, constants, branches, liveness
   |
   v
Core verifier ---- rejects an invalid optimizer result
   |
   v
CorePrep ---------- atomization and explicit basic-block control flow
```

CorePrep is intentionally after optimization. A constant branch removed in
Core does not need blocks, temporaries, or jumps in CorePrep. Conversely, the
Core optimizer does not imitate CorePrep by introducing basic blocks early.

## Public entry points

The default compiler uses `defaultCoreOptimizer`. Embedding code that needs a
report can call `optimizeCoreWith defaultOptimizerOptions` and receive an
`OptimizationResult`.

The result contains:

- the verified optimized module;
- structural metrics before optimization;
- structural metrics after optimization;
- the number of fixed-point iterations;
- whether the pipeline converged within the configured limit; and
- a typed report for every enabled pass invocation;
- the final interprocedural effect report for every function; and
- one typed inlining report for every enabled fixed-point iteration.

The existing `CoreOptimizer` facade remains small. Its function returns only
the optimized module, which keeps ordinary compiler orchestration independent
of reporting details.

## Pass order

One iteration runs enabled passes in this order:

1. interprocedural effect inference;
2. bounded safe-expression inlining;
3. constant propagation and expression folding;
4. effect inference after structural rewriting;
5. control-flow simplification;
6. effect inference after branch rewriting; and
7. effect-aware dead-code elimination.

The order is deliberate. Effect inference establishes which direct calls are
safe candidates. Inlining can expose literals and primitive expressions.
Constant propagation can then fold those expressions and make a condition
known. Control-flow simplification can remove the branch. Liveness can finally
remove bindings that became unused after branch selection. Effects are
recomputed at the structural boundaries so no later pass relies on stale call
edges.

The complete sequence repeats until an iteration makes no structural change.
The default maximum is twelve iterations. A finite bound protects compiler
availability if a future rewrite accidentally oscillates. Reaching the bound
returns the last verified result and marks the report as not converged; it does
not hide the condition.

## Constant environment

Constant propagation uses a sequential environment keyed by `SymbolId`.
Spelling is never used as identity. This matters when local names shadow one
another or when two source scopes happen to use the same text.

Only immutable bindings whose value is already a literal enter the environment.
This restriction is conservative and intentional:

- duplicating a call could execute user code more than once;
- duplicating a closure could change allocation and ownership behavior;
- duplicating a large expression could grow the program;
- copying an expression across a write could observe different state; and
- a literal has no evaluation effect to duplicate.

A mutable binding never becomes a propagated constant. Assignment removes the
target from the current environment before later statements are simplified.
Branches receive the incoming literal environment independently. Only literal
bindings present with the same value on every path survive a merge. A separate
integer-fact environment tracks ranges and zero-ness; it is not a constant
environment and never substitutes a variable with an expression.

## Integer folding

Integer operations are evaluated with unbounded host `Integer` arithmetic and
materialized only when the result fits the declared Tala scalar type.
This separates computation from representation:

- `byte` is signed 8-bit;
- `short` is signed 16-bit;
- `long` is signed 32-bit;
- `int` is signed 64-bit;
- `longint` is signed 128-bit;
- `ubyte`, `ushort`, `ulong`, `uint`, and `ulongint` use matching unsigned
  widths; and
- `char` is an unsigned 32-bit scalar at the Core boundary.

An overflowing result remains an explicit primitive expression. The optimizer
does not wrap, saturate, or invent a diagnostic. The language's later checked
or unchecked arithmetic policy can therefore be implemented without first
undoing an incorrect fold.

The integer operations currently folded are:

| Core primitive | Compile-time rule |
| --- | --- |
| add | exact addition followed by range validation |
| subtract | exact subtraction followed by range validation |
| multiply | exact multiplication followed by range validation |
| divide | truncation toward zero when the divisor is nonzero |
| rounded divide | nearest integer, with exact halves away from zero |
| remainder | remainder paired with truncating division |
| negate | exact unary negation followed by range validation |
| power | bounded exponentiation by squaring; unsupported or overflowing results remain explicit |
| bit shifts | fold only nonnegative counts smaller than the operand width |
| bitwise complement | complement within the declared signed or unsigned width |
| comparisons | a boolean literal result |

Division, rounded division, and remainder by zero remain explicit. Removing them
would erase the later stage's required failure behavior.

## Path-sensitive integer facts

The full state model, transfer equations, operation boundaries, and contributor
obligations are documented in [Core integer flow analysis](INTEGER-FLOW-ANALYSIS.md).
The current Windows Criterion observations are recorded in
[Core integer flow benchmark](../Benchmarks/2026-09-24-Core-Integer-Flow.md).

The optimizer keeps a second, deliberately modest abstract environment while it
walks Core statements. It records facts keyed by `SymbolId`; source spelling,
lexical nesting, and declaration order are not identity. Each integer fact is
an interval plus an independent zero-exclusion bit:

```text
IntegerFact = [minimum .. maximum] × excludesZero
```

Either interval endpoint may be absent when no bound is known. Integer type
limits initialize an unconstrained variable's interval. A signed 64-bit `int`,
for example, begins at `[-2^63 .. 2^63 - 1]`; an unsigned 8-bit `ubyte` begins at
`[0 .. 255]`. This makes range reasoning respect Tala's scalar catalog
instead of the host's `Int` width.

The independent zero-exclusion bit matters for joins. If one arm establishes
`x > 0` and another establishes `x < 0`, the interval hull spans zero, but no
execution from either arm has `x == 0`. The merged fact therefore retains the
exclusion. In the opposite case, if one arm assigns zero and the other assigns
two, the merged interval contains zero and the exclusion is dropped.

### Refinement rules

An `if` condition is refined once for its true edge and once for its false edge.
The comparison operand order is normalized before applying constraints. For a
variable compared with an integer literal `k`, the transfer rules are:

| Condition | True-edge constraint | False-edge constraint |
| --- | --- | --- |
| `x == k` | `x` is exactly `k` | exclude zero when `k == 0`; otherwise retain a conservative interval |
| `x != 0` | exclude zero | `x` is exactly zero |
| `x != k`, `k != 0` | retain interval | `x` is exactly `k` |
| `x < k` | upper bound `k - 1` | lower bound `k` |
| `x <= k` | upper bound `k` | lower bound `k + 1` |
| `x > k` | lower bound `k + 1` | upper bound `k` |
| `x >= k` | lower bound `k` | upper bound `k - 1` |

For nonzero literals, the current domain does not retain arbitrary excluded
points. It intentionally represents `x != 0` because that is the proof needed
by integer division safety, and uses exact bounds for equality branches. An
unsupported exclusion loses optimization precision, never soundness.

Logical negation swaps the requested edge. The short-circuit path equations
are applied structurally:

```text
true(A && B)   = true(B, true(A, facts))
false(A && B)  = join(false(A, facts), false(B, true(A, facts)))
true(A || B)   = join(true(A, facts), true(B, false(A, facts)))
false(A || B)  = false(B, false(A, facts))
```

`join` keeps only facts valid on both feasible paths, widens interval endpoints
to their hull, and carries zero-exclusion only when each input proves it. This
is a may-value analysis: every concrete value that can reach a program point
must remain represented by its abstract interval and exclusion state.

### Unreachable paths

An interval whose lower bound exceeds its upper bound is contradictory. The
environment has an explicit unreachable element so a contradiction is not
confused with an empty set of facts. For example:

```text
if (x > 4 && x < 5) {
    return 24 / x;
} else {
    return 0;
}
```

Integer discreteness makes the true edge impossible. The effect analysis does
not charge the impossible divide, and constant/control-flow simplification may
select the false edge. At a join, unreachable is an identity: `join(bottom, x)`
is `x`. If both edges are unreachable, the enclosing continuation is
unreachable as well.

Truth queries use the same feasibility calculation as edge refinement. They
can prove a condition false because its true edge is impossible, or true
because its false edge is impossible. The optimizer does not invent values
when neither edge can be rejected.

### Transfer through statements and expressions

Bindings and assignments compute an abstract value for the right-hand side,
then install it for the destination symbol. A later assignment replaces the
previous interval; it never intersects a new assignment with an old value.
Return and evaluation statements transfer effects from their expressions but
do not create a value fact for another symbol. Statements after a terminating
return are outside the continuation.

The current arithmetic transfer supports interval-safe integer negation,
addition, subtraction, and multiplication when endpoint calculations fit the
destination Core type. When an endpoint overflows, an operand is unbounded, or
an operator has no approved transfer rule, the result becomes unknown. The
analysis is not a substitute for overflow semantics; retaining an unknown fact
prevents an arithmetic rewrite from silently establishing a proof.

Function calls clear the facts. Core does not yet encode complete read/write
sets for captured mutable storage or higher-order arguments. Clearing the whole
environment is more conservative than invalidating only visibly mentioned
locals, and prevents a call from making an earlier nonzero proof stale. Closure
bodies are deferred execution regions: capture initializer facts do not become
assumptions about state at a future invocation. Each closure body starts a new
fact environment and can establish its own guards.

### Safety boundary

The effect analysis supplies a nonzero proof only when the integer divisor is a
direct variable whose current path fact proves exclusion of zero. A literal
nonzero divisor continues to use the existing local proof. Proofs for one
operator do not erase evaluation effects of its operands; child effects are
combined independently and in Core evaluation order.

The analysis does not currently prove a divisor safe from floating facts,
bitwise patterns, arbitrary function summaries, relational facts between two
variables, or facts across a call. Unsupported forms remain potentially
failing. In particular, a comparison such as `x != y` cannot prove either
operand nonzero, and an `x != 9` true edge does not prove `x != 0`.

The corresponding effect rule is therefore:

```text
integer divide / floor-divide / remainder:
    nonzero literal divisor       -> no divide-by-zero effect
    path-proven nonzero variable  -> no divide-by-zero effect
    known zero or unknown divisor -> FailureEffect
```

The proof is recomputed from the current Core after every structural optimizer
pass. It is not serialized into Core, Xpp, Xmm, or the Core wire format, and it
does not become a user-visible language feature. The optimizer's output still
passes the ordinary Core verifier before it reaches CorePrep.

Integer power never asks the host to construct the full mathematical result
before checking its destination. The optimizer bounds each multiplication by
the Core result type and stops as soon as the result cannot fit. Bases `0`,
`1`, and `-1` are handled directly, so their result does not require a loop
proportional to a potentially untrusted exponent. A negative exponent or an
overflowing result stays as a primitive for the later stage to diagnose or
lower; folding does not invent a wraparound rule.

Core shift primitives accept an integer count in the operand's type, which can
be wider than the host `Int`. The optimizer checks the count against the
operand width before converting it to `Int` or allocating a shifted integer.
Negative and out-of-width counts remain explicit. This avoids both a host-width
truncation bug and work proportional to artifact-controlled shift counts.

Bitwise complement is evaluated at the declared scalar width. Signed types use
the corresponding two's-complement result; unsigned types mask away every bit
above the declared width. The shared integer layout catalog supplies width,
signedness, and range checks, so those facts cannot silently drift between
verification and optimization.

The frontend's constant-expression and template-value evaluators have a
separate 65,536-bit implementation ceiling. This is deliberately much wider
than any built-in scalar and bounds work on source expressions before a value
is narrowed to its declared type. It is not a runtime integer width. Power uses
exponentiation by squaring; shifts validate an arbitrary-precision count before
converting it to a host index. A nonconstant AST form stays nonconstant; it is
not treated as an evaluator failure. Multiplication uses operand bit lengths to
reject a product that cannot fit before building the full intermediate.

The accepted compile-time domain is the half-open interval
`(-2^65536, 2^65536)`. Values on either excluded edge produce an evaluation
diagnostic; they are never wrapped, clamped, or silently retyped. The bound
belongs only to compile-time work. Runtime integer types retain their declared
8-, 16-, 32-, 64-, and 128-bit ranges, and the Core optimizer continues to
preserve a fixed-width operation when folding would leave that range.

`IntegerEvaluation` is the single resource-policy module used by constant
diagnostics and template-value evaluation. The callers retain their own
diagnostic vocabularies, but share exact boundary checks, power, multiplication,
and shift behavior. This prevents a fixed-array size and an ordinary constant
expression from accepting different magnitudes merely because they enter
through different frontend APIs.

The multiplication guard uses a cheap mathematical lower bound before asking
GHC's arbitrary-precision `Integer` implementation to construct a product. If
the two operand bit lengths prove that the result must exceed 65,536 bits, the
operation fails immediately. Products near the boundary are still computed and
checked exactly; the lower bound cannot reject a valid edge result. Exponentiation
by squaring applies this same guard to every accumulated product and square.
The exact identities for bases `0`, `1`, and `-1` avoid exponent-sized work for
those results, including a very large exponent.

Left-shift evaluation checks the value's bit length plus the requested distance
before allocating the shifted integer. An already-zero value needs no shifted
result. Right shifts compare their arbitrary-precision count against the
maximum result width before any host-index conversion, so an enormous positive
count resolves to the sign fill (`0` or `-1`) rather than allocating a large
temporary or overflowing a machine-sized conversion. These are evaluator
resource protections; they do not change the optimizer's separate rule that a
fixed-width Core shift folds only when its count is valid for that operand.

Direct tests compare the reusable bounded operations against simple exact
oracles for dense small-input matrices, then exercise positive and negative
magnitudes around machine-word, byte, 128-bit, and 65,536-bit boundaries. A
second matrix compares constant-expression and template-value evaluator
outcomes across all binary and unary operators, including matching division,
negative-exponent, and resource-limit failures. Source-level tests also ensure
the same cases reach the intended type-checking diagnostic rather than escaping
to Core optimization.

The Criterion `Core/ConstantFoldInteger` workload combines bounded power,
left-shift, bitwise XOR, and addition in verified 128-bit Core expressions.
Its 8/32/128/512/1024/2048-operation-group Windows measurements are recorded separately from the
floating-fold workload in `Benchmarks/2026-09-24-Core-Integer-Folding.md`.

## Floating constants

The shared scalar module validates floating spellings, including exponents,
infinity, and NaN. Core folds basic floating literal arithmetic with exact
integer ratios and one target-width round-to-nearest, ties-to-even operation;
it never narrows through the host's `Double`. `sfloat`, `lfloat`, `float`, and
`double` use binary16, binary32, binary64, and binary128 respectively.

Addition, subtraction, multiplication, division, remainder, negation,
comparisons, numeric truth conversion, and floating `//` are supported. NaN
ordered comparisons remain false, NaN inequality remains true, and the
implementation retains signed zero, subnormal values, underflow, and overflow.
Floating `//` rounds the quotient to the source width before applying the
language's nearest-integer, halves-away-from-zero rule; its result type is the
language's signed 64-bit `int`. If the folded integer result does not fit that
Core type, the expression remains explicit.

Power, transcendental functions, arbitrary call evaluation, and NaN payload
rewrites remain unsupported. They require separate semantics and tests rather
than a host floating approximation.

Floating spellings use ASCII digits. Unicode decimal categories are not
accepted as wire-level numeric text even when a host character library labels
them as digits. This matches source token rules and keeps artifact validation
independent of locale.

Decimal parsing for folding strips insignificant leading and trailing zeroes
before constructing an exact integer ratio. It caps folded significant digits
at 512 and declines to fold exponents whose text exceeds the bounded parser
range. These are optimizer resource guards, not source or artifact validity
limits: the Core expression remains intact and is still checked normally. The
cap is deliberately much larger than binary128's shortest-round-trip decimal
precision, while avoiding unbounded big-integer work on externally supplied
Core literals.

## Algebraic identities

The optimizer recognizes identities that preserve type and evaluation:

```text
x + 0  -> x
0 + x  -> x
x - 0  -> x
x * 1  -> x
1 * x  -> x
x / 1  -> x
x // 1 -> x
```

`x % 1` becomes zero only when `x` is a variable or literal. Replacing an
arbitrary call or closure expression with zero would discard its effect.

Double arithmetic negation collapses when the nested and outer result types
agree. Double logical negation collapses only for a boolean operand. Tala
allows numeric values in boolean context, so `!!numericValue` performs a real
numeric-to-boolean conversion and must not become the original numeric value.

## Boolean folding

Logical primitives fold boolean literals. Numeric literals are also interpreted
using the language condition rule: zero is false and every nonzero value is
true. Comparison primitives produce `bool`, never the operand's numeric type.

These rules are checked by the Core verifier before optimization. The optimizer
therefore never needs to guess whether a string, closure, or unresolved value
is condition-compatible.

## Control-flow simplification

Known boolean and numeric conditions select a branch. Statements after an
unconditional return are removed. If both sides of an `if` always return, code
after that `if` is unreachable and is removed as well.

When two branches are structurally identical, the branch can be replaced by
its shared body. The condition is discarded only if it is pure. An effectful
condition is emitted as `CoreEvaluate` before the shared body.

The same preservation rule applies when both branches are empty:

```text
if effectfulCall() { } else { }
```

becomes:

```text
evaluate effectfulCall()
```

It does not disappear.

## Effect model

The optimizer uses a conservative ordered effect model:

| Effect | Current producers | Discardable when unused |
| --- | --- | --- |
| pure | literals, variables, pure primitives, proven direct calls | yes |
| failure | integer divide/remainder with an unproved divisor | no |
| allocation | closure construction and transitive allocating calls | no |
| call | indirect or unresolved Core application | no |
| divergence | recursive strongly connected call-graph component | no |

Primitive expressions inherit the strongest effect of their operands. A
module-local direct call uses the solved effect of its callee. Indirect and
unresolved calls remain unknown. Closure construction is allocation because it
can establish AARC ownership edges and later participate in destruction or
cycle handling. Recursive strongly connected components remain divergent until
the compiler has a separate termination proof.

The model is deliberately non-speculative. It proves enough purity for safe
dead-result removal and bounded inlining without turning optimizer guesses into
language semantics. See [Core effect analysis](CORE-EFFECT-ANALYSIS.md) for the
complete retention contract.

## Bounded linear-body inlining

Inlining uses solved effect reports rather than maintaining a second purity
model. A candidate must be pure, non-recursive, and have a straight-line body:
zero or more immutable bindings or evaluations followed by exactly one final
`CoreReturn`. Mutation, assignment, branches, early returns, and fallthrough
remain outside this expression-level pass.

The accepted statement prefix becomes nested `CoreLet` expressions. Each local
receives a fresh module-wide `SymbolId`, and later initializers plus the return
are rewritten through the new identity. This makes two expansions of one
helper independent to liveness, ownership, and CorePrep.

Variables and literals are safe direct substitutions. Primitive trees, calls,
possible failures, and closure allocations are instead bound to fresh argument
lets. Consequently each eager argument is evaluated once, from left to right,
even when a parameter is unused or read repeatedly. Callee purity controls body
eligibility; it does not require caller arguments to be pure.

Fresh allocation starts above every definition and use observed in the module,
including expression lets and closure-owned identities. Candidate estimation
and the fully expanded expression are both checked against the configured node
budget. A rejected speculative expansion commits neither fresh ids nor report
counters.

Rewriting walks expressions bottom-up. A nested pure call may become a literal
before its enclosing call is considered, while longer chains converge through
the optimizer's fixed-point loop. Generated Core is verified and follows the
ordinary `CoreLet` CorePrep lowering path. The detailed contract is documented
in [Core linear-body inlining](CORE-INLINING.md).

Inlining never deletes function declarations. Reachability and link-unit
pruning are separate decisions because exported visibility is not represented
by the current Core function model. Function order, name identity, and module
identity remain unchanged.

## Backward liveness

Dead-code elimination walks each statement list backward while carrying the set
of symbols needed by later statements.

For a binding:

- if the bound symbol is live, retain the binding and add symbols read by its
  initializer;
- if the symbol is dead and the initializer is pure, remove the binding; or
- if the symbol is dead and the initializer is effectful, replace the binding
  with `CoreEvaluate`.

Assignments follow the same principle. A write whose value is never read can
be removed when its right-hand side is pure. An effectful right-hand side is
preserved as an evaluation.

Returns reset liveness to the symbols read by the returned expression because
statements after a return are unreachable. Each branch is analyzed using the
live set required after the join; the incoming set is the union of the
condition and both branch requirements.

## Closure regions

A closure body is a separate liveness region. Values required after closure
construction in the enclosing function do not make similarly named closure
locals live. Capture initializers, however, execute in the enclosing region and
remain part of the closure expression's effect and symbol set.

Literal capture initializers may propagate into the closure body. Parameters
remove matching capture entries from that body environment, so a parameter
always shadows a captured constant with the same `SymbolId`.

Calls and nested closure allocations in a dead closure binding are retained.
The outer binding becomes `CoreEvaluate`; the closure body itself is still
optimized independently.

## Shared scalar facts

The verifier and optimizer import one canonical scalar-facts module. It owns:

- Core scalar spelling extraction;
- integer, floating, and numeric type catalogs;
- signed and unsigned integer range validation; and
- stable floating literal spelling validation.

This prevents a dangerous split where the optimizer creates a literal that the
verifier rejects, or the verifier accepts a type the optimizer accidentally
treats with a different width.

The scalar module is public within the Haskell package because codecs, artifact
tools, and focused tests also need the same contract. It is not a language-level
standard-library API.

## Metrics

Metrics count structural nodes, not estimated runtime cost:

- functions;
- statements;
- expressions;
- bindings;
- assignments;
- branches;
- calls; and
- closures.

Every enabled pass report stores metrics immediately before and after that pass.
Adjacent reports therefore form a continuous chain, including across fixed-point
iterations. Disabled passes produce no report entry.

Metrics are suitable for tests, diagnostics, and regression dashboards. They
are not a promise that fewer nodes always means faster code. A later cost model
can add target-independent estimates without changing existing counters.

## Reporting contract

Pass identity is represented by `OptimizationPass`, not by parsing a display
string. A `PassReport` includes:

- the one-based iteration number;
- the typed pass identity;
- metrics before the pass;
- metrics after the pass; and
- whether the Core module changed structurally.

Reports include stable compiler data only. They do not include timestamps,
machine paths, pointer values, or randomized identifiers, so equal inputs and
options produce equal reports.

## Options

`OptimizerOptions` currently controls:

- maximum fixed-point iterations;
- interprocedural effect inference;
- bounded safe-expression inlining;
- the maximum expanded inline expression node count;
- constant propagation;
- control-flow simplification; and
- dead-code elimination.

All passes are enabled by default, and the default inline expression budget is
twenty-four nodes. Options exist for compiler testing,
diagnostics, and controlled development. They are not currently public
build settings or CLI flags.

Setting the maximum below one still permits one iteration. This guarantees that
the optimizer has a deterministic result and report without introducing a
special zero-pass meaning. To preserve a module exactly, disable all passes.

## Determinism

The optimizer is deterministic:

- functions retain source order;
- statements retain order unless a proven rewrite removes them;
- maps are queried by stable `SymbolId`;
- liveness sets affect membership, not emitted ordering;
- no rewrite uses hash iteration to construct output; and
- reports contain no environment-dependent values.

Running the default optimizer on its own converged output produces the same
Core module. Idempotence is covered by focused tests.

## Failure behavior

Invalid input returns the Core verifier's diagnostics and no optimization is
attempted. A malformed result returns verifier diagnostics instead of reaching
CorePrep. The optimizer does not catch a diagnostic and continue with a partial
tree.

An iteration limit is different from invalid Core. The result remains verified
and is returned with `optimizationConverged = False`. Compiler policy may later
choose whether that report is informational, diagnostic, or fatal.

## Test strategy

Focused tests cover:

- every scalar family and representative range boundary;
- ASCII-only floating spelling validation;
- arithmetic, comparison, and logical constant folding;
- truncating division versus nearest-integer rounded division;
- zero divisors and overflow preservation;
- immutable propagation and mutable invalidation;
- algebraic identities and numeric boolean conversion;
- known, identical, empty, and effectful branches;
- unreachable statement removal;
- pure and effectful dead bindings, evaluations, and assignments;
- closure body regions, literal captures, and parameter shadowing;
- individually disabled passes;
- fixed-point convergence and iteration limits;
- metric and pass-report continuity;
- optimizer idempotence;
- input rejection; and
- final verifier acceptance.

Integration tests additionally compile Tala source through optimized Core
and CorePrep. They inspect unoptimized Core when the source-value contract is
the subject of the test, and optimized Core when dead-value removal is the
subject. This distinction prevents optimization progress from weakening lexer
or desugarer coverage.

## Deliberate non-goals

The current optimizer does not perform:

- arbitrary compile-time call evaluation;
- CFG, mutable, branching, multiple-return, or effectful function inlining;
- ownership-cleanup or exception-region relocation across an inline boundary;
- common-subexpression elimination;
- loop optimization;
- escape analysis;
- ownership insertion or deletion;
- closure environment layout;
- cross-module symbol resolution;
- CorePrep block optimization;
- Xpp or Xmm optimization; or
- target-specific lowering.

These are separate compiler decisions. Adding one requires an explicit semantic
contract, verifier coverage, and tests at the representation that owns it.

## Extension checklist

Before adding a Core rewrite:

1. state which source-level semantics justify it;
2. identify every evaluation that may be removed, duplicated, or reordered;
3. define behavior for overflow, division failure, NaN, and signed zero where
   relevant;
4. prove that `SymbolId` scope is preserved;
5. preserve closure capture and parameter shadowing rules;
6. add valid, invalid, boundary, and effectful tests;
7. ensure the output passes `verifyCore`;
8. ensure a second optimizer run is structurally identical;
9. document whether the pass changes metrics or reporting; and
10. confirm that CorePrep receives a simpler tree without taking ownership of
    the optimization itself.

Following this checklist keeps Core optimization substantial without turning it
into a second type checker, a premature backend, or an unsafe source rewriter.
