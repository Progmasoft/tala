<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Core linear-body inlining

## Purpose

The Core inliner removes selected direct-call boundaries before CorePrep. It is
an interprocedural optimizer, not a source macro expander: names are already
resolved, types are already checked, and every decision uses `SymbolId`
identity rather than source spelling.

The pass supports more than a single returned expression. A candidate may have
a straight-line prefix of immutable bindings and evaluation statements followed
by exactly one return. That body can be represented without a control-flow
graph by nested `CoreLet` expressions. The result remains ordinary verified
Core and follows the same CorePrep path as expression-local sequencing emitted
by the desugarer.

The implementation is intentionally narrower than a CFG inliner. It does not
copy branches, loops, mutable locals, assignments, exception regions, ownership
regions, or multiple return paths. Those forms need block cloning, exit joining,
and ownership-aware cleanup placement rather than a larger expression rewrite.

## Pipeline position

One optimizer iteration runs the relevant stages in this order:

```text
verified Core
    |
    v
interprocedural effect inference
    |
    v
linear-body inlining
    |
    v
constant propagation and folding
    |
    v
effect inference for the rewritten call graph
    |
    v
control-flow simplification
    |
    v
effect inference for the rewritten control flow
    |
    v
dead-code elimination
```

Inlining runs before constant folding so copied primitives immediately expose
new folding opportunities. The complete sequence is a bounded fixed point.
Pure call chains can therefore collapse over successive iterations without the
inliner recursively expanding a candidate while it is being copied.

## Candidate contract

A function becomes a candidate only when every condition below holds:

1. effect inference produced a report for the function;
2. its transitive classification is exactly `PureEffect`;
3. it is not a member of a recursive strongly connected component;
4. its body is a linear prefix followed by one final return;
5. every binding in the prefix is immutable;
6. the estimated expression form is within the configured node budget.

The accepted body grammar is:

```text
InlineBody  := InlineStep* CoreReturn
InlineStep  := immutable CoreBind
             | CoreEvaluate
```

The grammar is structural. A return followed by another statement is not a
final return and is rejected. A body with no return is rejected by the Core
verifier before optimization. A branch is rejected even when constant
propagation could later select one side. Keeping candidate discovery independent
of speculative simplification makes the safety proof local and reproducible.

`CoreEvaluate` is accepted only because the whole function was proven pure.
The evaluation is still retained in the expanded expression. This preserves
the exact Core evaluation structure and avoids making candidate discovery
depend on a later dead-code pass.

## Argument evaluation

Inlining must preserve eager call semantics. Naive textual substitution fails
in two directions:

- a parameter read twice duplicates an effectful argument;
- an unused parameter erases an effectful argument.

Tala solves both by distinguishing trivial and non-trivial arguments.

Variables and literals are trivial. Copying a variable read or a literal has no
observable evaluation, so they may be substituted directly. Every other
argument receives a fresh `CoreLet` binder before the copied body. Parameter
references point to that binder.

For a call conceptually shaped as:

```text
Combine(ProduceLeft(), ProduceRight())
```

the expansion has this evaluation shape:

```text
let $left  = ProduceLeft()  in
let $right = ProduceRight() in
    copied body
```

The outer-to-inner let order is the original left-to-right argument order.
Each non-trivial argument is evaluated once even when the callee ignores it,
reads it repeatedly, or returns before a later expression would otherwise use
it. Calls, primitive trees, possible failures, and closure allocations all keep
their evaluation boundary.

The candidate itself must be pure, but the caller's argument need not be pure.
This distinction is essential. Callee purity permits body copying; argument
let-binding preserves caller behavior.

## Statement conversion

An immutable binding:

```text
final int doubled = value * 2;
```

becomes an expression-local binding:

```text
CoreLet freshLocal int (value * 2) remainingBody resultType
```

Bindings are nested in source order. Each initializer sees substitutions for
parameters and earlier locals. The returned expression sees all preceding
locals. A pure evaluation statement becomes a `CoreLet` with a compiler-owned
synthetic binder; its result is intentionally unused, while its evaluation
remains ordered before the rest of the body.

This representation needs no new wire opcode. `CoreLet` already has stable Core
wire support, verification, constant propagation, liveness traversal, and
CorePrep lowering. CorePrep emits the value operation followed by a binding and
continues atomizing the body in the same open block.

## Capture avoidance

Resolved identity is semantic. Copying a callee-local `SymbolId` into two call
sites would make unrelated values look identical to later analysis. It could
also collide with an existing caller binder.

Before rewriting starts, the pass inventories every symbol observed in the
module:

- function definitions;
- function parameters;
- statement binding definitions;
- assignment targets;
- variable references;
- expression-local let definitions;
- closure capture definitions and initializers;
- closure parameters, bodies, and body-local definitions.

Fresh allocation starts one above the largest observed numeric id. Uses are
included as well as definitions. Verified Core cannot have dangling uses, but
this stronger rule also keeps transformation behavior safe and deterministic
for partially built test fixtures.

Every copied local, generated argument binder, evaluation binder, nested
`CoreLet`, closure capture, closure parameter, and closure-local binding receives
a fresh id. References are rewritten through a lexical substitution environment.
Closure capture initializers are cloned in the outer environment; the closure
body then uses the fresh capture and parameter environment. Branch-local
environments do not escape their branches.

Generated spellings begin with `$inline.` and contain a role, source spelling,
and numeric id. The spelling exists for diagnostics and debugging only.
Correctness depends exclusively on the fresh `SymbolId`.

## Size budget

`optimizerMaximumInlineExpressionNodes` bounds growth. Values below one are
normalized to one. Two checks are used:

1. candidate discovery records a conservative estimate containing parameter,
   step, and result nodes;
2. call rewriting counts the fully expanded expression, including actual
   arguments and generated lets.

The second check matters because one small identity function can receive a very
large argument. If either check exceeds the limit, the original call is kept.
Fresh-id state from a discarded expansion is not committed, so rejected calls
do not create gaps or affect later deterministic output.

The budget is a compile-time and code-growth guard, not a profitability model.
Future cost modeling may include call frequency, backend target costs, ownership
traffic, or profile data. Such policy can refine the limit without weakening
the current semantic contract.

## Effect relationship

Effect inference is the authority for candidate purity. A candidate is rejected
when it allocates, may fail, makes an unknown or indirect call, or may diverge.
Known direct callees contribute transitively. Recursive SCCs are divergence
barriers even if their local expressions look pure.

This produces several deliberate outcomes:

- a helper returning a closure is not a candidate because closure construction
  allocates;
- a helper dividing by an unconstrained value is not a candidate because it may
  fail;
- a helper invoking a callable parameter is not a candidate because the call is
  unknown;
- a non-recursive helper calling another proven-pure helper may be a candidate;
- an effectful argument passed to a pure identity helper may still be inlined,
  because the argument is retained behind a let.

Disabling interprocedural effects also disables inlining. Running the inliner
with a separate local purity approximation would give optimizer passes two
conflicting definitions of observability.

## Verification boundaries

The optimizer verifies its input before running and verifies its result after
the fixed point. Linear-inlining tests additionally take rewritten modules
through `prepareCore` and the CorePrep verifier. These checks cover:

- binding type agreement;
- result type agreement;
- positive and defined symbol identity;
- non-colliding copied locals;
- coherent copied references;
- CorePrep atomization of generated let chains;
- valid blocks and register use after preparation.

The inliner does not modify function declarations or remove candidates.
Declaration order, function symbols, callable types, and module identity remain
stable.

## Reports

Every enabled iteration emits one `InlineReport` with:

- total candidate count;
- expression-only candidate count;
- statement-body candidate count;
- pure non-linear bodies rejected by shape;
- rewritten direct calls;
- calls skipped by the size budget;
- generated argument lets;
- generated local lets;
- generated evaluation lets;
- total fresh alpha-renamed symbols.

Expression and statement candidate counts sum to the total. Generated-let
counts describe successful expansions only; a budget-rejected speculative
expansion does not leak counters. Reports are retained per fixed-point iteration
alongside ordinary `PassReport` metrics.

## Test matrix

The component-owned Haskell suites cover:

- expression-only compatibility;
- one and several immutable locals;
- local dependency order;
- literal and variable substitution;
- primitive, direct-call, failing, allocating, repeated, and unused arguments;
- left-to-right multi-argument evaluation;
- evaluation statement ordering;
- rejection of mutation, assignment, branches, early returns, and missing
  returns;
- fresh allocation above the complete module inventory;
- disjoint identities at separate call sites;
- nested `CoreLet` freshening;
- typed report counters;
- candidate and expanded-size limits;
- Core verification, CorePrep construction, and CorePrep verification;
- deterministic and idempotent fixed-point output;
- structural symbol inventory for expression lets and closures.

## Deliberate non-goals

The current pass does not implement:

- CFG or loop inlining;
- multiple-return joining;
- mutable local promotion;
- ownership cleanup relocation;
- exception-region cloning;
- virtual or indirect-call devirtualization;
- cross-module body import;
- profile-guided profitability;
- removal of now-unreferenced function declarations.

The next semantic expansion should be a CFG inliner only after Core has explicit
ownership and exception-region rules sufficient to prove cleanup placement.
Increasing the accepted statement grammar without that model would trade a
clear safety boundary for accidental backend behavior.

## Maintainer invariants

Changes to this pass should preserve the following invariants independently of
whether the current test fixtures happen to expose them.

### Identity

- Never derive freshness from function symbols alone.
- Never reuse a callee parameter or local id in the caller.
- Never compare source spelling to decide whether two values are identical.
- Never let speculative, rejected expansion advance committed fresh state.
- Keep separate expansions disjoint even when their source body is identical.
- Preserve function declaration identity and order.

### Evaluation

- Traverse a call's callee before its arguments.
- Traverse arguments from left to right.
- Bind every non-trivial actual exactly once.
- Retain a non-trivial actual even when its formal parameter is unused.
- Do not duplicate a non-trivial actual when its formal parameter is repeated.
- Keep linear body steps in their original source order.
- Do not classify allocation or failure as harmless merely because the copied
  callee is pure.

### Scope

- Clone a let initializer in the environment before that let is introduced.
- Clone later linear steps in the environment containing earlier fresh locals.
- Clone closure capture initializers in the enclosing environment.
- Clone closure bodies in an environment extended with fresh captures and
  fresh parameters.
- Keep branch-local definitions from escaping a branch while cloning nested
  closure bodies.
- Rewrite assignment targets only when they refer to a cloned local identity.

### Types

- Preserve declared parameter and local types on generated lets.
- Preserve expression result types; do not infer them again in the optimizer.
- Require the expanded expression type to equal the original call result type.
- Let the Core verifier reject unresolved or inconsistent types before any
  output reaches CorePrep.
- Do not encode fresh-id policy into a type spelling or a wire field.

### Budgets and reports

- Count both the candidate estimate and final expanded tree.
- Include generated argument and body lets in the final count.
- Treat a non-positive configured budget as the minimum budget of one node.
- Count report events only for the iteration in which they occur.
- Keep report categories additive and unambiguous.
- Do not use benchmark results to silently widen the semantic candidate set.

## Diagnosing a failed expansion

When an expected call remains, inspect the boundaries in this order:

1. verify that Core accepted the input module;
2. inspect the function's solved effect and recursive-SCC flag;
3. confirm the body ends in exactly one final return;
4. check that every prefix binding is immutable;
5. compare the candidate estimate with the configured node limit;
6. compare the fully expanded tree with the same limit;
7. confirm direct callee identity resolves to the candidate symbol; and
8. confirm original and expanded result types are equal.

When output verification fails, first compare every generated id with
`maximumCoreSymbolValue` of the input. Then inspect the lexical substitution
environment around the first undefined reference. A missing earlier-local
mapping usually indicates statement order was reversed; a closure-only failure
usually indicates capture initializers and body scope were cloned under the
same environment when they require different ones.

When behavior changes but verification succeeds, inspect generated argument
lets before optimizer simplification. A missing let can erase an unused failure
or allocation; two copies of one argument can duplicate a call. CorePrep output
is useful for confirming actual instruction order, but the semantic bug belongs
to Core if the incorrect order already exists in the let chain.
