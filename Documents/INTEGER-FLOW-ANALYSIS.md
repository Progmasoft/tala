# Core Integer Flow Analysis

This document describes the integer facts shared by Core effect inference,
constant propagation, and dead-code elimination. It is an implementation
contract for the Haskell Core optimizer, not a source-language specification.
The source language's integer types, overflow behavior, and operator semantics
remain defined by `Spec/`.

The Haskell Core package exposes `Progmasoft.Tala.Core.Optimizer.IntegerFacts`
so compiler tooling can inspect the same sound facts used by the optimizer.
`LoopFactSummary` reports distinct header, condition, body, update, normal-exit,
and return states; consumers should not reconstruct loop edges from statement
syntax. Transfer helpers are conservative and are not an execution engine or
a replacement for Core verification.

The analysis answers deliberately narrow questions. Most importantly, it can
prove that an integer divisor is nonzero on a reachable path, and it can prove
that an integer condition is already true or false. It does not attempt to
prove arbitrary predicates, evaluate calls at compile time, or replace the
type checker.

## Why one shared analysis exists

An optimizer can otherwise disagree with itself in subtle ways. Effect
inference might mark a guarded division harmless while dead-code elimination
still preserves it, or constant propagation might remove a contradictory
branch while liveness continues to treat its assignments as reachable.

The shared `IntegerFacts` module gives all three clients the same answers for:

- the current reachable state;
- the interval known for each integer symbol;
- whether that interval excludes zero;
- the state on each side of a condition;
- the state after assignments, calls, and joins; and
- whether the condition has no feasible true or false edge.

Consumers may ask different questions of the facts, but they must not invent a
second interpretation of a guard or assignment. A future analysis can extend
the abstract domain, provided it preserves this single-source relationship and
updates the verifier-backed regression matrix.

## State model

An analysis state is either reachable with a map of symbol facts, or
unreachable. Unreachability is the bottom element: it represents a control-flow
edge for which no value can exist, not an unknown value.

For one integer symbol, the abstract value contains three independent pieces:

| Component | Meaning | Example |
| --- | --- | --- |
| Lower bound | Every represented value is at least this integer | `x > 4` gives `x >= 5` |
| Upper bound | Every represented value is at most this integer | `x <= 8` gives `x <= 8` |
| Zero excluded | Zero is not one of the represented values | `x != 0` |

The bounds are optional in the general representation. Core integer types
currently have finite ranges, so a variable with no path-specific fact can
still start from its type range. Keeping bounds optional allows the transfer
functions to express incomplete information without selecting an arbitrary
host-sized sentinel.

The zero-exclusion bit is not redundant with the interval. For example, the
interval `[-9, 9]` plus zero exclusion expresses `x < 0 || x > 0`; replacing it
with a single interval alone would lose the proof needed by division.

An exact value is an interval whose lower and upper bounds are equal. Exact
zero is not zero-excluded. An interval is contradictory if its lower bound is
greater than its upper bound, or if it contains only zero while also excluding
zero. Applying a contradictory fact makes that path unreachable.

## Initial facts from types

For a signed integer type with width `w`, the seed interval is:

```text
[-2^(w-1), 2^(w-1)-1]
```

For an unsigned integer type with width `w`, it is:

```text
[0, 2^w-1]
```

Both include zero. Floating-point, Boolean, applied, unresolved, or otherwise
non-integer types do not receive integer facts. The optimizer obtains widths,
signedness, and representability from the shared Core scalar catalog; it does
not duplicate the type spelling table.

Type ranges are useful even before a comparison is seen. An unsigned integer
cannot be less than zero, so that edge is unreachable. This is a semantic fact
about the already typed Core value, not a guess based on a variable name or a
source annotation.

## Refinement from conditions

`refineConditionFacts` receives the desired truth value. It returns the facts
valid only on that edge. This distinction is essential: a proof from a true
edge must not leak onto its false edge.

### Direct truthiness

For an integer-valued condition, the true edge excludes zero and the false
edge fixes the value to zero. The condition is known true when the interval
cannot contain zero; it is known false when the value is exactly zero.

For logical negation, the requested truth value is inverted and refinement
continues through the nested expression. No alternate source spelling for
logical NOT is implied by this Core rule.

### Comparison with an integer literal

Given an integer variable `x` and literal `c`, the analysis translates a
comparison into a bound, an exact value, or zero exclusion. The true and false
edges use complementary predicates:

| Predicate on `x` | True-edge refinement | False-edge refinement |
| --- | --- | --- |
| `x == c` | `x = c` | if `c = 0`, exclude zero |
| `x != c` | if `c = 0`, exclude zero | `x = c` |
| `x < c` | `x <= c-1` | `x >= c` |
| `x <= c` | `x <= c` | `x >= c+1` |
| `x > c` | `x >= c+1` | `x <= c` |
| `x >= c` | `x >= c` | `x <= c-1` |

Reversed operands are normalized by reversing the relation. For example,
`0 < x` is treated as `x > 0`; the operator itself is not rewritten in Core.

The analysis intersects each new constraint with the type-seeded or existing
interval. It does not overwrite a stronger fact with a weaker one. An
impossible intersection yields bottom immediately.

### Comparisons between variables

When both operands are integer variables, equality true intersects their
current abstract values. If either value is known nonzero, equality transfers
that exclusion to both symbols. Equality false can represent the special case
where one side is exactly zero by excluding zero from the other side. The
domain cannot express “not this arbitrary nonzero integer,” so it deliberately
does not claim such a fact.

Ordering comparisons transfer bounds from one side to the other. For example,
`x < y` implies `x <= upper(y)-1` and `y >= lower(x)+1` when those source bounds
are known. A missing source bound produces no invented constraint. The false
edge of `x < y` is treated as `x >= y`, not as `x > y`.

These transfers are interval-safe but not relationally complete. The domain
does not retain a permanent symbolic relation such as `x-y < 4`. If the
independent interval facts cannot establish a result, the answer is unknown.

Comparisons can also be folded without refining an edge. Two disjoint intervals
prove inequality; ordered interval endpoints prove an ordering; exact values
use the primitive's ordinary integer relation. Every such proof depends only
on verified Core types and tracked facts.

## Short-circuit logical operators

The logical transfer follows the evaluation paths of short-circuit operators.
The right operand is reached only when the left operand has the required
short-circuit value.

For `A && B`:

```text
true  = refine B true  (refine A true  input)
false = join(refine A false input,
             refine B false (refine A true input))
```

For `A || B`:

```text
true  = join(refine A true input,
             refine B true (refine A false input))
false = refine B false (refine A false input)
```

These equations preserve facts guaranteed by every feasible route to a result.
They do not evaluate an operand on a route where the language would short
circuit it. If an operand invokes a callable, current facts are conservatively
invalidated at that call boundary; a later predicate may establish new facts.

### Logical expressions used as values

Short-circuit transfer also applies when `&&` or `||` is nested in an ordinary
expression, not only when it directly controls a `CoreIf`. The expression
effect analyzer visits the left operand first, asks whether its value is known,
and visits the right operand only on a feasible evaluation path.

For `false && (1 / 0)`, the integer division is not evaluated. The complete
expression is therefore discardable if the left operand itself is pure. For
`true || (1 / 0)`, the same rule applies. Conversely, an unknown left operand
means the right side may execute and its effect must be included.

For `x \= 0 && 24 / x`, the right operand is evaluated only after the left
operand is true. The right-side division sees the nonzero fact and does not
introduce a local divide-by-zero effect. This does not make the full logical
expression pure if either operand calls, allocates, or has another effect.

After a complete logical value expression, facts are joined from all feasible
evaluation paths. A call on one path can invalidate facts at the join even
when a separate short-circuit path skips the call. A call proven unreachable
by a constant left operand does not invalidate the post-expression state.

These rules keep expression effects, condition refinement, and forward
statement facts consistent. Otherwise a dead `CoreEvaluate` could be retained
because an unreachable right operand was treated as eager, or a mutable fact
could incorrectly survive a call that actually ran.

## Joining control-flow paths

At a join, unreachable states are identities: joining one unreachable branch
with one reachable branch returns the reachable state. Joining two reachable
states forms an interval hull for symbols known on both sides. The joined
interval contains all values from either path.

Zero exclusion survives a join only if each reachable input proves nonzero.
For example:

```text
if (flag) { x = 2; } else { x = -3; }
```

joins to an interval containing `[-3, 2]` with zero excluded. Joining `x = 0`
with `x = 2` cannot retain zero exclusion. If a symbol has no path fact on one
side, path-only bounds are dropped rather than assumed true everywhere.

This join is intentionally coarse. It can lose a disjoint range such as
`x <= -2 || x >= 2`, but it never narrows the set of possible values. The
independent zero-exclusion property preserves the most important disjoint
fact for guarded integer division without requiring a set-of-intervals domain.

## Arithmetic transfer

The analysis derives result intervals for integer addition, subtraction,
multiplication, and unary negation when all operand bounds are available.
Multiplication considers all endpoint products. The result is accepted only
when both endpoints are representable in the result Core integer type.

If arithmetic may overflow or the analysis lacks an endpoint, it returns an
unknown fact instead of applying modular, saturating, or host-language integer
behavior. The language's overflow contract remains authoritative; this pass
does not choose one.

For multiplication, zero is excluded when both operand facts exclude zero.
For addition and subtraction, the interval endpoints themselves may prove
zero-exclusion. These arithmetic rules are conservative. They do not use
algebraic identities that require assumptions about overflow.

For a known interval `[L, U]` and exact literal `c`, the transfer shapes are:

| Operation | Candidate result interval |
| --- | --- |
| `x + c` | `[L+c, U+c]` |
| `x - c` | `[L-c, U-c]` |
| `x * c` | `[min(L*c, U*c), max(L*c, U*c)]` |
| `-x` | `[-U, -L]` |

The implementation uses the general endpoint operation for binary ranges,
including cases where both operands vary. It considers all four endpoint
pairs for multiplication; the one-variable table is only an explanatory
specialization. The candidate interval is checked against the Core result
type before it is recorded.

Examples for small signed `int` ranges:

| Known input | Expression | Derived fact | Divide safe? |
| --- | --- | --- | --- |
| `1 <= x <= 4` | `x * 2` | `[2, 8]` | Yes |
| `8 <= x <= max` | `x - 5` | `[3, max-5]` | Yes |
| `1 <= x <= 4` | `x - 2` | `[-1, 2]` | No |
| `1 <= x <= 4` | `x * 0` | `[0, 0]` | No |
| Full `int` range | `x + 2` | Unknown if endpoint overflows | No proof |

The last row is intentionally not represented as an unbounded or wrapped
result. If one endpoint cannot be evaluated under the verified Core type, the
transfer returns unknown for the entire expression. It does not retain only
the endpoint that happened to fit.

An assignment transfers the right-hand-side value fact to the assigned symbol
after evaluating the expression. Assigning zero replaces a previous
nonzero fact. Assigning a known nonzero literal establishes a fresh fact. An
unknown expression forgets the old value instead of retaining stale bounds.

## Calls, closures, and evaluation order

Expression effects and integer facts are computed in left-to-right evaluation
order. A call may mutate a captured mutable cell. Until Core includes a
verified read/write summary for such state, a call invalidates every tracked
fact. This is broader than necessary but sound.

A closure body is deferred and is not traversed as an eager call. Capture
initializers do execute during closure construction, so their effects are
combined in source order. Closure-body analysis begins with its own parameters
and conditions; facts from the enclosing function are not silently imported
through a closure boundary.

This is a deliberate boundary, not an assertion that all calls mutate all
state. A future mod/ref summary may preserve facts for proven-disjoint symbols,
but it must identify global, captured, aliased, and indirect state before
weakening the invalidation rule.

## Statement flow

Bindings evaluate their initializers, then associate a fact with the new
symbol. Assignments evaluate the right-hand side and replace the symbol fact.
Returns transfer effects in their value and make the following statement
sequence unreachable.

An `if` first accounts for condition effects, then derives separate input facts
for the true and false bodies. Each body is processed independently. At the
join, only bodies that can continue contribute facts. If both bodies terminate,
the continuation is bottom. If only one body terminates, only the other body
reaches the continuation.

The optimizer's Core verifier is responsible for structural validity, such as
return completeness and symbol ownership. Integer flow does not excuse an
invalid tree and does not synthesize a missing return.

### Loop dataflow and widening

Structured Core loops are solved before their facts are handed to optimizer
clients. A pre-test `while` and `for` join the incoming state with the body
back-edge at the condition header. A `do/while` instead analyzes its first
body execution from the incoming state, then joins the true condition edge
back at the body header. Consequently a post-test loop preserves the fact that
its body executes at least once, while a pre-test loop preserves the possibility
that its body executes zero times.

The loop body transfer tracks four edge classes independently: normal
completion, `break`, `continue`, and `return`. Branch joins merge matching
classes only. The nearest loop consumes its own `break` and `continue`; nested
loops return their normal exit facts to the enclosing body without allowing an
inner transfer to escape. Returns remain separate and never enter the loop
back-edge or the normal exit. This separation is required for cases such as a
`break` that establishes zero: treating it as an induction edge would lose a
real zero-valued exit, while treating a `continue` as an exit could invent one.

For a `while`, `continue` rejoins at the condition. For a `do/while`, it also
reaches the condition rather than skipping it. For a `for`, a body's normal
completion or `continue` reaches the update sequence, and only the update's
normal completion or `continue` returns to the condition. A body's `break`
skips the update. Break exits from both the body and update are joined with the
condition-false edge. These rules mirror the already-lowered Core shape; this
analysis does not reconstruct source syntax or alter loop semantics.

At each header, the analysis first forms an ascending join with the newly
computed back-edge. Expanding lower and upper endpoints are widened to unknown;
stable endpoints remain. A symbol absent from either side is forgotten, and
zero exclusion remains only when both sides establish it. Therefore a counter
such as `index = index + 1` does not require one compiler analysis round for
each runtime iteration. The loop solver has a fixed transfer-round limit of
eight. If it is reached, the solver recomputes the summary from the reachable
top state, discarding path-specific constraints that may not have converged.
That fallback is deliberately less precise, never a partially converged narrow
answer.

The exit state is the join of all reachable break edges and the condition's
false edge. For example:

```text
int index = 0;
while (index < 17) {
    index = index + 1;
}
if (index < 17) {
    return 24 / index;
}
```

The widened header still lets the false edge establish `index >= 17`, so the
post-loop branch is unreachable. The optimizer does not substitute an
arbitrary interval endpoint for `index`; it only folds the predicate that the
interval proves. A call in the loop condition or body invalidates mutable
facts using the same call-boundary rule as non-loop code.

All consumers use the same summary. Constant propagation receives separate
condition, body, update, and exit facts. Effect inference inspects the loop's
condition, body, and update at their corresponding inputs, and carries only
normal exit facts to the following statement. Liveness uses the shared
statement transfer, so its forward snapshots agree with the optimizer's
condition and assignment reasoning. Loop divergence remains conservatively
observable; proving an interval exit does not by itself prove that every
concrete execution terminates.

### Summary shape and solver equations

`LoopFactSummary` deliberately exposes program points rather than one merged
"loop fact". Its fields have distinct meanings:

| Field | Program point | Unreachable representation |
| --- | --- | --- |
| `loopHeaderFacts` | Entry to a pre-test condition, or entry to a do-loop body, after widening | `UnreachableFacts` when no iteration can be entered |
| `loopConditionFacts` | Immediately before a condition is evaluated | Bottom when every body path returns, breaks, or otherwise fails to reach the condition |
| `loopBodyFacts` | Body input after the true condition edge; do-loops use their mandatory entry state | Bottom when a pre-test condition has no true edge |
| `loopUpdateFacts` | `for` update input after body normal/continue paths are joined | Bottom when there is no update point or it has no incoming edge |
| `loopExitFacts` | Normal completion after joining false-condition and break edges | Bottom when no concrete normal exit is represented |
| `loopReturnFacts` | Return paths leaving the loop body or update | Bottom when no return edge exists |
| `loopFixedPointIterations` | Number of transfer rounds used by the summary | Zero for an unreachable input |
| `loopAnalysisWidened` | Whether the bounded conservative fallback was selected | False for an unreachable input |

For `while` and `for`, let `H0` be the state before the first condition,
`T(H)` and `F(H)` the condition's true and false refinements, and `Body(T)`
the four-edge transfer of the body. A while loop's next back-edge is the join
of body normal and continue states. A for loop sends that join through the
update first, then uses update normal and continue as the back-edge. Each
header round is:

```text
H0 = input
Hn+1 = widen(Hn, join(Hn, backEdge(Hn)))
```

The condition's false edge is not sent around the loop. The stable summary's
normal exit is:

```text
join(F(H), bodyBreak(H), updateBreak(H))
```

The update-break term is unreachable for a while loop and for an update that
cannot break. Body returns and update returns are joined into the return field,
never into the normal exit. For a while loop, `backEdge(H)` is body normal
joined with body continue. For a for loop, it is update normal joined with
update continue; update input is body normal joined with body continue.

A do-loop has a different recurrence because the condition follows the body:

```text
B(H) = body transfer from H
C(H) = join(B(H).normal, B(H).continue)
Hn+1 = widen(Hn, join(Hn, refineTrue(condition, C(H))))
exit = join(B(H).break, refineFalse(condition, C(H)))
```

`B(H).return` becomes the summary's return state. A body break bypasses the
condition. A body continue reaches it. If all body paths return or break, the
condition input is bottom and contributes neither a false exit nor a back-edge.

These equations are intentionally stated in terms of the Core edge categories.
They are also a review aid: when modifying transfer code, compare each record
field with the exact equation instead of treating `join` as interchangeable
across header, update, and exit points. In particular, `join(Unreachable, S)`
is `S`; using bottom as an identity is correct only after a path is proven
infeasible.

Widening is applied after the ordinary path join. For each symbol that remains
present on both sides, a lower bound is retained only if it has not expanded
downward; an upper bound is retained only if it has not expanded upward. Zero
exclusion is intersected across rounds. A missing symbol on either side means
that no loop-wide fact is available for it. This order matters: widening only
the most recently observed back-edge could discard the initial state, while
returning an un-widened join after the round cap could expose a narrow state
that omitted a later iteration.

The cap fallback runs the loop transfer once from `emptyIntegerFacts`. That
state is reachable top for this domain: it claims no path-specific interval or
zero-exclusion fact. Any candidate that survives a subsequent condition or
assignment transfer is established from the current loop's syntax and remains
valid for all incoming values. The fallback is therefore safe for subsequent
optimization, but it may miss facts that a more powerful convergent analysis
could establish. It does not change the compiler's runtime loop limit because
it is only an analysis iteration bound.

### Review checklist for loop-transfer changes

Before changing the recurrence or edge join, verify each of these cases
independently rather than relying on one incrementing-counter example:

1. A false first condition reaches the pre-test loop exit with the original
   state; no body assignment may leak from an infeasible edge.
2. A do-loop body executes even when its condition is a literal false value.
3. A body break exits without executing the remaining body statements or a
   for-update.
4. A while continue returns to the while condition.
5. A do-while continue still evaluates the do-while condition.
6. A for continue executes the update before the next condition check.
7. A break in an update exits after earlier update statements have run.
8. Returns are observed by effect analysis but never joined into the normal
   exit or the loop back-edge.
9. A nested break or continue is consumed by the inner loop only.
10. A call on one feasible condition path invalidates facts at the join, while
    a short-circuited call on an infeasible path does not run.
11. Arithmetic whose result may overflow drops the derived interval before it
    can influence a later condition.
12. Every concrete normal exit remains inside the reported interval, including
    exits caused by `break` rather than the loop condition.

Use different expected values on break, continue, update, and false-condition
paths. If all paths assign the same value, an accidental join between edge
classes may look correct. The hand-written fixtures use exact values for that
reason; generated counter cases add breadth but do not replace those focused
examples.

Avoid asserting that the abstract exit equals one concrete result. Widening,
interval hulls, and imprecise calls can legitimately retain values that no
execution of a particular fixture reaches. The soundness direction is
containment: a reachable concrete value must not be excluded by the abstract
summary. Precision tests are separate and should name the exact property being
preserved, such as an exact zero after a mandatory body assignment.

### Cost model and benchmark cautions

One solver round traverses the loop condition, body, and—when present—update.
At each branch or loop exit, symbol maps are joined. For a map with `S` facts,
the current ordered-map representation makes a join proportional to the
represented symbols rather than the numeric width of their intervals. A
changing interval typically widens after one expansion, but nested loops can
cause their own solver to run during each outer transfer. The eight-round cap
is a safety bound for analysis work, not an expected average.

Optimizer passes call the shared analysis at different program points. This
keeps the facts valid after each pass changes the tree, but it can repeat loop
summary construction during constant propagation, effect inference, and
liveness. Do not add a cross-pass cache keyed only by a loop's syntax: the same
loop can receive different incoming facts after a preceding assignment, branch
rewrite, or call. Any future memoization must include the complete input state
and a tree identity valid for exactly one immutable pass snapshot.

The Criterion `LoopIntegerFacts` group deliberately measures complete
optimizer runs on functions containing three loop forms. Its result includes
verification, the surrounding pipeline, and function-level bookkeeping; it is
not a microbenchmark of `widenIntegerFacts` alone. A change to the abstract
domain should also inspect guarded-division and contradictory-path groups so
an apparent loop improvement does not hide a regression in non-loop facts.
For noisy results, use repeated same-host process runs and preserve the exact
toolchain/build metadata. Shared CI runners are compile/smoke checks, not
statistical performance gates.

## Effect inference and dead-code elimination

Integer division, rounded division `//`, and remainder over integer types can fail
when the divisor is zero. Without a proof, their local effect remains
`FailureEffect`; a dead result must therefore remain observable. A literal
nonzero divisor is immediately safe. A variable divisor is safe only when the
current facts prove it nonzero.

The effect analyzer carries facts through each body and evaluates primitive
children in order. The proof concerns only the local divide-by-zero failure. It
does not erase a call, allocation, or failure in the dividend or divisor
expression.

Dead-code elimination receives facts at the exact statement location. It can
remove a dead expression or binding only when the fact-aware effect is
`PureEffect`. Assignments update the forward fact snapshot even while liveness
is solved backward. This pairing prevents liveness from discarding a
failure-capable divide that effect inference has not proved safe.

The forward snapshot is conservative around branches and calls. It does not
change the liveness lattice or turn an effectful expression into a pure one by
looking at a different program point.

## Constant propagation

Constant propagation uses path facts to simplify conditions and eliminate
unreachable arms. It still uses its existing immutable-literal environment for
substituting values. Range facts are not substituted as constants: a fact such
as `x >= 5` does not justify replacing `x` with `5`.

When a condition is known under the current path state, only its reachable arm
is retained. A contradiction can make a nested path unreachable, and that
bottom state remains local to the branch. Facts are recomputed as passes run;
no proof cache is stored across a structural rewrite.

## Soundness obligations

Every new transfer must meet all of these conditions:

1. It describes every concrete value reachable on the modeled path.
2. Its integer range agrees with the verified Core result type.
3. It does not depend on host `Int` width or overflow behavior.
4. It respects left-to-right child evaluation and short-circuit reachability.
5. It invalidates facts when effects may mutate their source values.
6. It does not allow unreachable-path facts to enter a reachable join.
7. It keeps effectful children observable even when a local proof succeeds.
8. It remains deterministic across map insertion orders.
9. It leaves malformed Core rejection to the verifier rather than repairing it.
10. It has both positive and negative tests at the pass boundary it changes.

If a transfer cannot prove its premise, it must return unknown. False negatives
may leave optimization opportunities unused; false positives can erase a
runtime failure or change observable behavior.

## Regression coverage

The compiler test suite checks the abstract interpreter at several levels:

- direct true and false edges for all six integer comparisons;
- comparisons written with either operand order;
- a generated literal boundary matrix around negative, zero, and positive
  values;
- variable-to-variable equality and ordering with either operand order;
- generated relational cases where the other symbol is constrained to an
  exact boundary value;
- short-circuit conjunction and disjunction on both result edges;
- nested contradictory branches and redundant comparisons;
- mutable assignments before and after a guard;
- branch joins with common or conflicting assignments;
- calls in conditions, values, and guarded bodies;
- signed and unsigned type-range seeds;
- arithmetic result ranges and overflow fallback;
- all failure-capable integer division primitives;
- closure-body isolation;
- loop-header convergence and widening for `while`, `do/while`, and `for`;
- exact zero-iteration and mandatory-first-iteration behavior;
- break, continue, return, and nested-loop edge ownership;
- loop update ordering after normal body completion and `continue`;
- calls and possibly overflowing induction arithmetic inside loops;
- generated small counter loops checked through post-loop predicates;
- source-to-Core regressions through the real frontend pipeline; and
- optimized Core verifier acceptance and fixed-point behavior.

The loop matrix has two complementary layers. `LoopFlowTests` observes
optimizer output and direct summaries for named cases: mandatory do-loop entry,
all three continue destinations, body/update breaks, call invalidation,
overflow loss, return isolation, nested-loop ownership, and convergence bounds.
`LoopFlowOracleTests` contains a deliberately small concrete executor for
generated, side-effect-free Core programs. It checks 125 while, 125 do/while,
and 125 for combinations over small counter starts, limits, and break points.
The concrete final integer must be a member of the abstract exit interval; the
test does not require equality, because sound interval analysis is allowed to
over-approximate.

The test executor models only integer and Boolean literals/locals, addition,
integer comparisons, short-circuit Boolean operators, branches, nested
structured loops, and explicit loop transfers. Its generated additions remain
far inside the `int` range. A call, unsupported primitive, malformed Core
expression, or exhausted execution fuel fails the oracle instead of being
treated as a valid value. Separate return fixtures check `loopReturnFacts` so
that a concrete return is not incorrectly required to appear in the normal
exit. Non-terminating fixtures check the opposite boundary: a continue-only
cycle must not manufacture a normal exit merely because the abstract header is
reachable.

This finite executor is a test oracle for transfer containment, not a second
language runtime. It intentionally does not model overflow, call effects,
closures, floating-point behavior, or external state. Those dimensions remain
covered by optimizer-specific tests and the language/runtime test suites.

Generated cases use an independent integer comparison oracle to decide whether
the selected edge excludes zero. The oracle is intentionally simple and does
not call the abstract interpreter. This avoids making the implementation its
own test oracle.

Source-level regressions ensure the behavior is not limited to synthetic Core.
They check that guarded dead integer division disappears, unguarded dead
division remains, assigning zero invalidates a guard, and an impossible source
branch does not survive optimization.

## Worked path traces

The following traces use `S` for the current reachable state, `⊥` for an
unreachable edge, `I(x)` for the integer fact of symbol `x`, and `join` for the
control-flow hull. They describe Core analysis behavior rather than introducing
new source syntax.

### Guarded divide

Starting at a function entry with parameter `x`:

```text
S0 = { I(x) = typeRange(int) }
true(x \= 0, S0)  = { I(x) = typeRange(int) ∩ nonzero }
effect(24 / x, trueState) = PureEffect
false(x \= 0, S0) = { I(x) = 0 }
effect(24 / x, falseState) = FailureEffect
```

The effect of the complete `if` combines only the statements actually present
on each edge. The true-edge proof does not rewrite the false-edge state and
does not assert that all executions of `24 / x` are safe.

### Literal comparisons at zero

For a signed integer `x`, a true edge `x > 0` produces a positive lower bound.
A true edge `x < 0` produces a negative upper bound. Both prove nonzero. The
complementary edges `x <= 0` and `x >= 0` do not by themselves prove nonzero,
because zero remains a possible value.

The complements become useful in an enclosing condition. Under `x != 0`, the
false edge of `x <= 0` narrows `x` to a positive value; the false edge of
`x >= 0` narrows it to a negative value. This is why each comparison's true
and false edges must be represented separately instead of assigning one
coarse fact to the entire branch.

### Disjunction false edge

For `if (x == 0 || y == 0) ... else ...`, the else edge exists only if both
comparisons are false. Transfer is sequential on that edge:

```text
after left false:  x excludes zero
after right false: x excludes zero, y excludes zero
```

The right comparison cannot add a new fact to the path where the left
comparison was true; that path already belongs to the then edge. This is the
short-circuit rule behind safe use of `x` in the else body.

### Common fact at a join

Suppose `x` is already nonzero, then both branch arms assign a nonzero value:

```text
if (choose) { x = 7; } else { x = -1; }
```

The outgoing interval contains both assignments and zero exclusion survives:

```text
I(x) = [-1, 7] \ {0}
```

If one assignment changes to `x = 0`, the interval hull still includes both
values but the zero-exclusion bit is cleared. The resulting divide remains
failure-capable. Tests exercise both variants so a future join optimization
cannot accidentally keep a fact from only one side.

### Impossible integer interval

The condition `x > 11 && x < 12` yields these refinements on the true edge:

```text
after x > 11: x >= 12
after x < 12: x <= 11
intersection: empty
```

The state becomes bottom before the body is analyzed for continuation. A return
or failure expression reachable only inside that body does not contribute to
the function's reachable effect. The false edge remains reachable and is
joined normally.

### Safe arithmetic result

If the current facts establish `1 <= x <= 4`, then multiplication by the
literal two has endpoint products `2` and `8`. Both are representable in `int`,
so a binding of `x * 2` receives `[2, 8]`; division by that binding is safe.

For subtraction, if the path establishes `x >= 8`, then `x - 5` has a positive
lower bound. The upper endpoint is computed from the type's actual maximum,
not the build host's `Int` maximum. Both endpoints must fit the Core result
type. If the interval could overflow, arithmetic facts are dropped.

### Equality between variables

For `y != 0 && x == y`, the left true edge establishes zero exclusion for `y`.
Equality true intersects `x` and `y`'s possible values; the common value cannot
be zero. `x` therefore inherits the nonzero fact and a divide by `x` is safe.

For `y == 0 && x != y`, the second comparison is evaluated only when `y` is
exactly zero. Its true edge excludes zero from `x`. This uses the representable
zero-exclusion property, not an unsupported arbitrary-value disequality.

### Ordering between variables

If `y >= 0` and `x > y`, the first condition gives a nonnegative lower bound
for `y`; the second transfers a strict greater-than bound to `x`. The result
is `x >= 1`, which proves a safe divisor.

Similarly, `y > 0` and the false edge of `x < y` establish `x >= y > 0`. The
false edge is important: negating `x < y` gives `x >= y`, not `x > y`.
Inclusive/exclusive boundaries are covered by generated tests rather than
being inferred from a few hand-picked examples.

### Call invalidation

For a path that proves `x != 0`, executes an unknown call, then divides by `x`:

```text
S0 = type ranges
S1 = refine x != 0 true S0
S2 = transfer call S1 = empty facts
effect(24 / x, S2) = FailureEffect
```

This remains true even if the call currently appears pure to the effect
classifier. Call purity and memory-effect summaries are distinct analyses; the
integer transfer must not assume that a pure return value implies no writes to
captured mutable state.

### Proven local effect versus child effects

For `call() / x` under `x != 0`, the local divide-by-zero effect is absent, but
the call effect remains. The expression is not discardable. The analysis
combines the local primitive effect with every child effect instead of using a
safe-divisor proof to replace the full expression effect with pure.

Likewise, if a divisor expression contains a call, that call remains visible.
The fact about the final divisor concerns only whether the division itself can
fail; it cannot erase evaluation of the expression that produced the divisor.

## Review checklist for changes

When reviewing a new condition transfer, compare both edges against a small
concrete set of integer values around its boundary. Include negative values,
zero, positive values, and both signed endpoints when representable. Verify
that the true edge and the false edge partition the concrete values exactly.

When reviewing a new join, construct these cases explicitly:

1. both arms assign the same exact value;
2. both arms assign distinct nonzero values;
3. one arm assigns zero;
4. one arm has no fact and one has a path-specific interval;
5. the first arm is unreachable;
6. the second arm is unreachable; and
7. both arms terminate before the continuation.

When reviewing arithmetic, include a result strictly inside the type range,
one result equal to each representable endpoint, and the first result beyond
each endpoint. A lost fact is acceptable on uncertainty; an out-of-range fact
is not.

When reviewing calls, test a call before a guard and a call after a guard, a
call nested in a primitive child, a call in a short-circuit right operand, a
deferred call inside a closure body, and an eager closure capture initializer.
These positions have different execution behavior and must not share one
blind recursive rule.

When reviewing effect changes, test the same expression as a return value, a
live binding, a dead binding, a dead evaluation, and both branch arms. A proof
that allows removal of a dead result does not permit changing a returned or
otherwise live value.

The `IntegerFlowTests` suite currently owns generated Core-level boundary and
comparison matrices. `CoreOptimizerSourceTests` owns real frontend-to-Core
regressions. Keep those responsibilities separate: synthetic trees isolate a
transfer, while source tests validate parser, type, symbol, and lowering
integration together.

## Diagnostic workflow for an unexpected rewrite

When an optimizer test removes an expression unexpectedly, do not begin by
loosening the test or adding a one-off exception. Trace the value from typed
source into Core and identify the first stage whose state differs from the
expected concrete execution.

1. **Check the source contract.** Confirm the operator, integer type, and
   overflow rule in the public `Spec/` material. An optimizer test must not
   silently redefine those rules.
2. **Inspect typed Core.** Verify the primitive kind, operand order, result
   type, and symbol identity. A parser or resolver mismatch is not an integer
   flow bug.
3. **Write a concrete witness.** Choose one input value that reaches the
   allegedly removed expression. Evaluate the predicate and arithmetic with
   source semantics. If no concrete value reaches it, the rewrite may be valid.
4. **Trace both condition edges.** Record the initial type range, each
   constraint, and the resulting interval. Do not inspect only the edge that
   contains the divide.
5. **Inspect joins.** List every feasible predecessor and identify which
   properties all predecessors share. A fact established by only one arm must
   not survive a reachable join.
6. **Inspect effects separately.** A nonzero proof removes only the local
   integer divide-by-zero failure. Calls, allocations, and effects in operand
   expressions remain visible.
7. **Inspect the exact dead-code location.** Confirm that liveness says the
   value is dead and that fact-aware discardability says its full evaluation
   is pure at that exact program point.
8. **Run the Core verifier.** A successful optimization must still produce
   well-formed Core with valid symbol ownership and complete returns.
9. **Run the source pipeline test.** A constructor-only regression cannot
   validate parser, type checker, renamer, and desugarer integration.
10. **Re-run the fixed point.** Verify idempotence and confirm that the result
    does not oscillate between passes.
11. **Check a negative neighbor.** Change one boundary value or branch arm so
    zero becomes reachable. The failure-capable expression must then remain.
12. **Measure only after correctness.** Run the targeted Criterion workload
    after the new behavior is verified; do not use a faster benchmark result
    to justify an unsound fact.

This sequence narrows the ownership boundary before changing code. It also
keeps syntax, typing, symbol allocation, Core transfer, effect inference, and
dead-code elimination independently reviewable.

## Failure patterns and their owners

| Symptom | First owner to inspect | Expected conservative behavior |
| --- | --- | --- |
| Guarded divide remains | Core facts, then effect analysis | Keep it if the selected edge still admits zero |
| Unguarded dead divide disappears | Fact propagation or effect analysis | Preserve it as a failure-capable evaluation |
| Assignment fails to clear a guard | Statement transfer | Replace the old symbol fact with the assigned value fact |
| Call fails to clear a guard | Expression transfer | Forget facts until call mutation summaries exist |
| Only one branch's range survives | Join operation | Intersect guarantees by taking a hull and common zero exclusion |
| Impossible edge remains reachable | Constraint intersection | Mark bottom only when the interval intersection is empty |
| Safe arithmetic is not recognized | Arithmetic transfer | Accept only bounded, representable results |
| Overflowing arithmetic is called safe | Arithmetic transfer | Drop the result fact when either endpoint does not fit |
| Logical right side contributes too early | Short-circuit refinement | Reach it only on the language-defined edge |
| Safe divisor erases a nested call | Effect composition | Combine child effects with the local primitive effect |
| Facts cross closure ownership | Closure boundary | Analyze deferred body independently from eager captures |
| Core test passes but source test fails | Frontend integration | Preserve the failure and inspect typed Core identities/types |
| Optimized output fails verification | Rewrite or verifier boundary | Reject the result; do not bypass validation |

The table is a triage aid, not a substitute for the transfer definitions. If a
symptom crosses several owners, add the smallest test at each boundary before
changing the pipeline.

## Invariant map across optimizer passes

| Component | Fact responsibility | Must not take ownership of |
| --- | --- | --- |
| Scalar catalog | Width, signedness, integer representability | Path-specific control flow |
| Integer facts | Bounds, zero exclusion, reachability, transfer | Source type checking or effect policy |
| Constant propagation | Literal substitution and branch selection | Range-to-constant substitution |
| Effect inference | Failure/call/allocation/divergence classification | Removing a value on its own |
| Liveness | Whether a produced symbol value is read later | Declaring an expression pure |
| Control-flow simplification | Remove proven unreachable structure | Reordering observable evaluations |
| Core verifier | Structural and symbol validity | Repairing optimizer mistakes silently |
| CorePrep | Adapt verified Core to explicit control flow | Repeating Core optimizer reasoning |

The optimizer remains understandable when each pass consumes the same proof
facts but retains a narrow mutation responsibility. If two passes both decide
whether the same expression is discardable, move that decision to the shared
effect interface rather than duplicating it.

## Test result interpretation

The generated matrices intentionally contain many scenarios behind one
aggregate Boolean in addition to individually named edge tests. A matrix failure
should report the operator, boundary, desired edge, and operand orientation;
otherwise the failing concrete example is difficult to reproduce.

The literal comparison oracle and variable-relation oracle answer a concrete
question: does every integer value satisfying that selected predicate edge
exclude zero? The arithmetic oracle enumerates a small concrete interval and
checks whether the operation's results are all nonzero. These oracles are not
general theorem provers; their finite input domains are chosen to cover
operator boundaries systematically while keeping each test deterministic.

When adding a generated case, retain a handwritten example for the semantic
rule and a negative neighbor for its safety boundary. Generated density should
broaden coverage, not make the suite impossible to understand from its named
tests.

The whole-program source matrix intentionally shares one compiled module. Each
method has a unique name and parameter identity, and the optimizer preserves
function order. This keeps the pipeline test broad without paying for a full
compiler startup for every predicate. If the compiler changes declaration
ordering, update the test to match a stable function identity rather than
relying on list position.

## Benchmark interpretation

The Criterion cases `GuardedIntegerEffects` and `ContradictoryIntegerPaths`
build verified Core-shaped fixtures before measurement. The timed operation is
the production optimizer on an increasing number of guarded statements. One
fixture proves a repeated divisor safe; the other supplies an impossible
integer interval to a sequence of expressions.

`LoopIntegerFacts` measures the production optimizer on functions containing
pre-test, post-test, and `for` loops with changing integer locals, conditional
`break`/`continue` edges, and update statements. It complements the CorePrep
loop benchmark: this group measures abstract interpretation and optimizer
convergence, while CorePrep measures CFG preparation. The fixture count grows
by function, and construction stays outside the timed Criterion sample.

Results describe one machine and one compiler build. They are useful for
detecting asymptotic regressions and comparing revisions on the same host, but
they are not portable latency promises. Fixture construction, terminal output,
and module serialization are not included in the measured function. Existing
Core verifier and encoding benchmarks remain separate so those costs are not
misattributed to integer flow.

When benchmark complexity grows faster than the number of statements, inspect
fact-map copying, nested branch recursion, repeated expression traversal, and
effect inference fixed points before weakening the analysis. A faster result
must retain the generated comparison matrix and source-pipeline tests.

## Intentional limitations

The current domain does not represent:

- arbitrary congruences or bit masks;
- multiple disjoint intervals beyond zero exclusion;
- symbolic affine relations between unrelated values;
- floating-point ranges or NaN predicates;
- array bounds, pointer provenance, or object identity;
- call-specific mutation summaries;
- path-sensitive loop values beyond intervals and zero exclusion;
- path probabilities or target-specific branch costs; or
- proof facts across compilation units.

These are independent design choices. They should not be smuggled into integer
fact transfer as special cases. A richer domain should state its precision,
complexity, convergence behavior, and effect interaction explicitly before it
is integrated into constant propagation or code generation.
