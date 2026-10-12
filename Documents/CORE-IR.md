<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Core intermediate representation

## Scope

Core is the last tree-shaped, target-independent representation in the Visual
X# frontend. It is produced by the Haskell Desugarer, optimized in Haskell, and
then adapted to CorePrep. Core is also the first public compiler artifact in
the pipeline: a verified module can be encoded as a bounded `.core` document.

Core is not source syntax. It contains resolved identities and checked types,
not unresolved identifiers, overload candidates, parser recovery nodes, or
source-level shorthand. It is also not a backend IR. It has no LLVM types,
target registers, calling conventions, object layout, or linker directives.

## Module model

A `CoreModule` contains:

- one qualified namespace name;
- the ordered, project-relative `.tala` source catalog; and
- an ordered list of Core functions, each retaining its physical source owner.

The current source driver emits one module per compiled namespace and selects
the configured entry namespace for the native boundary. Each Core module
retains the physical source units assigned to that namespace, even when a file
contributes no declarations, and records the source file that owns each
function. This is build provenance: it does not change the namespace-level
semantic module or `SymbolId` identity. Cross-namespace imports and a
multi-module link unit are later semantic work. The optimizer does not merge
namespaces or resolve an external name by spelling.

Source identities use canonical project-relative slash paths and the exact
`.tala` extension. They are validated at the Core boundary and then carried
through CorePrep, Xpp, and Xmm. Closure lifting retains the enclosing source
owner, so splitting native definitions never depends on reconstructing
ownership from function names or namespace spellings. The wire field order and
validation rules are specified in [Artifact wire contracts](ARTIFACT-WIRE.md).

An empty module name or an empty name segment is invalid. Module order is
deterministic and follows the frontend's stable declaration order.

## Symbol identity

Every function, parameter, binding, capture, assignment target, and variable
reference uses `ResolvedName`:

```text
ResolvedName
  SymbolId          semantic identity
  Identifier        diagnostic spelling
```

`SymbolId` zero is reserved as the native/wire “no symbol” sentinel. Real
semantic identities are positive. Negative values can occur only in an
incomplete resolution path and are rejected before Core becomes valid.

Spelling is not identity. Two scopes can use the same spelling with different
symbols, and a renamed source spelling can retain the same symbol. Optimizers,
codecs, and native adapters must compare `SymbolId` when binding or looking up
a value.

## Type model

Core reuses the resolved frontend `Type` model:

- named types with qualified names and ordered type-or-value template arguments;
- function types with ordered parameters and one result;
- resolved type variables; and
- `ErrorType`, which is forbidden in verified Core.

Named scalar types keep their Tala spelling. Core does not replace `int`
with an LLVM integer width or encode `String` as host bytes. Type lowering is a
later stage decision.

Source `void` is checked before Core. At the current boundary, resultless
functions use the historically named `unit` marker plus `CoreUnit` as the
explicit return marker. Tala has no source-language `unit` type. Source-
facing tools must spell the result `void` and keep this representation private.

### Template arguments

A named type argument is an ordered sum:

- `TypeTemplateArgument` recursively contains a resolved Core type; or
- `ValueTemplateArgument` contains a canonical compile-time integer, Boolean,
  character, or resolved value parameter.

This distinction is implemented before declaration cloning. Treating the
second argument of `System.Array<T, N>` as a type would make specialization
identity unsound and prevent `[T; N]` from reaching Core.

Concrete fixed-array size expressions are evaluated exactly by TypeChecker.
Host integer width is irrelevant. Division, rounded division `//`, and remainder by
zero are diagnosed; a negative or non-integer fixed size is rejected. Calls,
closures, strings, and floating values cannot enter fixed-array type syntax as
compile-time sizes.

The structural model exposes validation, metrics, parameter collection,
substitution, array-family classification, and a deterministic internal
identity renderer. Native code also owns a thread-safe specialization table.
The table interns only valid concrete types, starts identifiers above zero,
coalesces concurrent insertion races, and preserves insertion order in
snapshots.

These facilities now feed the connected Haskell specialization-demand pass.
After initial Core verification, it discovers concrete parameterized types at
every signature, statement, expression, and closure boundary, closes nested
dependencies to a fixed point, and derives child-before-parent processing
order. It does not claim that template declarations, constraints, packs, or
lazy members are fully instantiated by the current frontend.

The resulting demand graph is derived compiler state, not part of the `TACR`
schema. `FrontendArtifacts` retains it beside Core for the later declaration
cloner. Loading Core from disk reconstructs the same plan from structural type
identity rather than trusting serialized queue identifiers.

## Functions

A `CoreFunction` contains:

- a positive resolved function name;
- ordered resolved parameters and their types;
- one resolved return type; and
- an ordered statement body.

Function symbols are placed in the verifier environment before any function is
checked. Direct calls can therefore refer to a function declared later in the
module. Duplicate function symbols are invalid even if spellings differ.

Parameters are immutable Core storage. Their symbols must be unique within the
function and their types must be fully resolved.

A value-returning function must return on every reachable path represented by
the tree. A source `void` function still carries an explicit
`CoreReturn CoreUnit` after lowering; both `CoreUnit` and its type are private
no-result markers.

## Statements

Core has ten statement forms. The source frontend lowers structured iteration
into Core without prematurely expanding it into backend blocks; CorePrep owns
that control-flow conversion. Keeping loop shape here lets optimization and
verification reason about conditions, body execution, update order, and loop
control before basic-block construction.

### Bind

`CoreBind` introduces typed local storage with:

- a positive resolved name;
- a declared type;
- a mutability bit; and
- an initializer expression.

The initializer is evaluated before the name becomes available to following
statements. Its expression type must equal the declared type. A local symbol
cannot redefine a parameter, function, or earlier binding visible in the same
Core environment.

### Assign

`CoreAssign` writes an existing mutable binding. The target must be defined,
positive, and mutable. Its source expression must have exactly the declared
storage type.

Assignment is a statement, not a value expression. An optimizer may remove a
dead write only when it preserves evaluation effects of the right-hand side and
retains the storage declaration required by any surviving write.

No Core expression writes a local. Source expressions that do are lowered to
statements before Core; see "Source expressions that store" below.

### Return

`CoreReturn` terminates the current function or closure body with one explicit
expression. The expression type must equal the owning return type.

Statements physically present after a return are verified but are unreachable
and may be removed by control-flow simplification. Verification of unreachable
input prevents malformed hidden subtrees from crossing the public artifact
boundary.

### If

`CoreIf` contains one condition and independent ordered true and false statement
lists. Conditions accept `bool` or a numeric scalar. Numeric zero is false and
nonzero is true.

Bindings introduced inside a branch do not escape into the environment after
the `CoreIf`. CorePrep later turns this tree into explicit branch, jump, and join
blocks.

### Evaluate

`CoreEvaluate` evaluates an expression and discards its result. It represents
source call statements and preserves effects when an optimizer removes a dead
binding or branch wrapper.

A pure `CoreEvaluate` can be deleted. Calls and closure construction are
conservatively effectful and remain explicit.

### While

`CoreWhile` contains a condition followed by an ordered body. The condition is
evaluated before each body execution, so the body may execute zero times. Its
condition follows the same `bool` or numeric truth rule as `CoreIf`. The body
has a nested binding scope; its declarations do not escape the loop.

### Do/while

`CoreDoWhile` contains an ordered body followed by a condition. The body runs
before the first condition evaluation and therefore executes at least once
unless control returns or leaves the function from inside it. Each normal body
completion reaches the condition; `continue` reaches that same condition
directly.

### Classic for

`CoreFor` stores a condition, body, and update list separately. The source
initializer is lowered into the enclosing ordered statement stream before the
loop node, while its binding remains scoped to the loop in source semantics.
CorePrep emits the condition before the body, sends normal body completion and
`continue` through the update list, and then branches back to the condition.
The update list may be empty; it is still a distinct position in the
control-flow model.

### Break and continue

`CoreBreak` exits the innermost active loop. `CoreContinue` skips the remainder
of that iteration and reaches the loop's continuation point: the condition for
`while`, the trailing condition for `do/while`, or the update list for classic
`for`. These statements carry no source label or value. Core verification
tracks loop nesting independently for each function and closure body and rejects
either statement outside a loop. Nested loops push a new target pair, so an
inner transfer cannot accidentally jump to an outer loop.

The update list of a classic `for` is that loop's continuation point, so the
two transfers differ there. `CoreBreak` in an update list is valid and exits
the loop after the statements before it. `CoreContinue` placed directly in an
update list, including inside a `CoreIf` there, is rejected with `TAC1066`:
it has no later point of the same iteration to reach, and lowering it would
jump back to the start of the update without testing the condition. A loop
nested inside an update list has its own body and continuation point, so
`CoreContinue` is valid again inside it. A source `continue` in an update
clause ends the update, and the frontend lowers it without `CoreContinue`:
an update clause that holds one becomes a loop that runs once, its
statements followed by `CoreBreak`, and the `continue` becomes a `CoreBreak`
of that loop. A source `break` in an update clause is the Core `CoreBreak`
there; in an update clause that is wrapped it sets a flag bound before the
loop, and the loop is left after the wrapper when the flag is set. A source
`continue` in the condition of a `for` must not run the update, which the
Core `CoreContinue` of the loop would: such a condition is evaluated in a
loop of its own, which the `continue` repeats and which is left once the
condition has a result. In a `while` or `do`/`while` loop the condition
already stands at the top of the Core loop body, where `CoreContinue` does
what the source asks. The rule protects Core built or transformed by other
means.

A function that returns a value must not fall off the end of its body
(`TAC1005`). A body does not when every path returns or runs into a loop
that cannot be left: one whose condition is the literal `true` and that no
`CoreBreak` of its own body or update list leaves. A `CoreBreak` in a loop
nested inside it leaves only that loop. The Haskell and the native verifier
apply the same rule, and the native one decides it without recursing along
an `else if` chain.

Optimizer passes preserve the explicit loop form unless their rewrite proves
the replacement semantics, including effects and transfer edges. In
particular, a constant condition does not permit deleting an effectful body or
moving evaluation across a `break`, `continue`, or return. CorePrep consumes
the verified structure and materializes loop headers, exits, latches, and the
distinct `for` update block.

The Haskell CorePrep lowering and the native Core-to-CorePrep adapter must
build the same program. The source fuzz harness enforces this for every
accepted source by comparing both lowerings of one compilation in a canonical
form; see [Fuzzing](FUZZING.md#coreprep-parity). In particular they must build
the same loop shape:

- a `while` or `for` condition owns a dedicated header block. The statements
  that precede the loop stay in the incoming block, which jumps to the header
  once; every back-edge targets the header, never the incoming block;
- a numeric condition's canonicalizing `value != 0` comparison belongs to that
  header and is re-evaluated on every iteration;
- the `for` update region is entered by normal body completion and by
  `continue`, and every open tail of the update region jumps to the header.
  The region's own entry is its `continue` target but is not its successor;
- `&&` and `||` are control flow, not eager two-operand instructions. A
  Boolean result slot is initialized with the short-circuit value, the left
  operand selects a branch, and only the block on the evaluating edge computes
  the right operand and overwrites the slot. Calls, traps, and non-termination
  in the right operand therefore stay conditional. A short-circuit condition
  of a loop is evaluated starting at the loop header, so the loop's own
  body/exit branch may sit in the operator's join block;
- a conditional expression is control flow as well. Its result slot is bound
  before the branch with the neutral literal of its type (`false`, an integer
  zero, or a floating zero), the test selects one of two arm blocks, each arm
  block computes only its own operand and assigns the slot, and both jump to
  one join block that continues the surrounding expression. No path reaches
  the join without one of the two assignments, so the neutral value is never
  observable.

`LoopLoweringTests.cpp`, `ShortCircuitLoweringTests.cpp`, and
`ConditionalLoweringTests.cpp` under `Talac/Core/Tests/` assert these edges
exactly on the native adapter. `LoopExecutionTests.cpp`,
`ShortCircuitExecutionTests.cpp`, and `ConditionalExecutionTests.cpp` under
`Talac/Backend/LLVM/Tests/` execute each form through CorePrep, Xpp, Xmm,
and LLVM with both native optimizer settings and compare the result with host
code; the short-circuit and conditional programs guard a division or a
recursive call, so an eagerly evaluated operand traps or never returns instead
of merely producing the same value. A CorePrep, Xpp,
or Xmm verifier cannot reject a wrong back-edge by itself: a block that jumps
to itself is a well-formed control-flow graph.

Both lowerings bind a `CoreLet` value with the value's own operation rather
than through an extra copied temporary, so a let over a call is one call
instruction in either adapter.

Both lowerings also allocate generated symbols the same way. Temporaries,
condition, short-circuit and conditional slots, and lifted closure names come from one
counter that starts above every symbol identity in the whole module and is
never reset between functions. Identities are module-wide and CorePrep
verification rejects one identity with two spellings, so a counter seeded
from a single function would reuse another function's symbols.
`SymbolAllocationTests.cpp` covers this for multi-function modules and
closures.

### Source expressions that store

The source language has expressions that write a local: `a = b`, `a += b`,
`++a`, `a++`, and a loop used as an expression, whose `break value;`
supplies its result. Core has no such expression. The Desugarer lowers each of
them to a pair: statements that perform the stores, and a store-free
expression that reads the result. Every Core optimization may therefore keep
assuming that only `CoreAssign` and `CoreBind` change a local.

The statements run where the source evaluates the expression:

- Operands are evaluated left to right. When a later operand has statements,
  an earlier operand is bound to an immutable `$operand` temporary first,
  unless it is a literal or reads a local those statements do not assign. So
  `a + (a = 5)` reads `a` before the store, and `Next() + (a = 5)` calls
  `Next` before it.
- A postfix form keeps the previous value in `$previous`. A compound
  assignment whose right operand assigns its own target keeps the earlier
  target value in `$target`.
- A conditional result, the right operand of `&&` or `||`, and a coalescing
  fallback are evaluated lazily, so their statements move into a `CoreIf`
  that assigns a mutable `$selected` or `$logical` slot. A form with no
  storing operand keeps its expression lowering unchanged.
- A loop condition with statements moves to the top of the loop body as
  `if (condition) { } else { break; }` under an always-true header, so the
  statements run before every test, including the one after `continue`. A
  `for` keeps its update list in the update position. A `do`/`while` runs its
  body before the first test, which a mutable `$first` flag records.
- A loop expression binds a mutable `$loop` slot, runs its loop, and each
  `break value;` assigns the slot and then breaks. The type checker has
  established that the loop cannot end any other way.
- A block used as a value lowers to its statements followed by its final
  expression. An `if` expression is a conditional over two such blocks: when
  neither block has statements it stays one `CoreConditional`, otherwise it
  selects into a `$selected` slot like any conditional with storing operands.
- A `match` binds each subject once to an immutable `$subject` local, in
  source order, and then nests one `CoreIf` per arm: the test is the
  conjunction of `subject == literal` comparisons, the first branch is the
  body, and the second branch holds the arms after it. A pattern that accepts
  every value contributes no comparison, so a catch-all arm is its body
  without a test and ends the chain. A name bound by a type pattern is a
  mutable local initialized from its subject. All such locals are bound
  after the subjects and before the first test: binding an evaluated scalar
  has no effect of its own, every local has its own symbol, and the chain
  then holds nothing but tests and bodies.
- A guard is the last operand of the short-circuit conjunction that tests
  its arm, so it is evaluated only when the comparisons hold. A guard that
  stores into a local needs statements of its own; it is decided in a
  `$accepted` slot by the rule of `&&` with a storing right operand, and its
  statements stand before the conditional of its arm, inside the false
  branch of the arm before it.
- A match used as an expression binds a mutable `$matched` slot and every
  body assigns it. The statement form has no slot; its block bodies are
  statement blocks of the enclosing body, so a `break value;` in them stores
  into the slot of the enclosing loop expression.
- The arms form one chain: each arm is the false branch of the arm before
  it, which is the shape of an `else if` chain. Every stage walks that shape
  in a loop, so the lowering of a match is as deep as one arm, whatever the
  number of arms.
- `guard (condition) else { ... }` is `if (condition) { } else { ... }`.
- A block statement has no Core form: its statements join the enclosing
  sequence. Every local has its own symbol, so the names of the block cannot
  collide with later ones.

An `else if` has no Core form of its own either: it is a false branch that
holds exactly one nested conditional statement, so a chain of N links is N
levels of nesting. The native wire reader and writer, the native Core
verifier and the Core-to-CorePrep adapter recognize that shape and walk the
links in a loop instead of recursing, because recursion would use stack in
proportion to the length of the chain. The encoding, the verifier's checks
and the block numbering of CorePrep are those of the nested formulation; the
Haskell CorePrep lowering and the native adapter are compared on such chains
like on any other program.

Three shapes of expression nest as deep as an expression is long: a chain
of operators nests in the first operand of each primitive, a chain of
conditional expressions in each false arm, and a sequence of bindings in
each let body. The native wire reader walks all three in a loop; the Core
verifier and the adapter walk operator chains in a loop, and the adapter
also let bodies and conditional chains. The symbols, the blocks and the
checks are those of the nested formulation.

Other nesting is walked recursively, one level of recursion per level of
nesting, in the wire codec, the verifier and the adapter. The functions on
those paths are written to keep their frames small: a statement holds two
expressions by value and is large, so it is read into its place and built
by functions that return before the next level is entered, and diagnostics
and instructions are built outside the functions that recurse. Releasing a
module does not recurse along a chain either: the destructors of an
expression and of a statement move their operands and nested statements to a
list and release them from there. Copying a module still recurses once per
level; the pipeline copies only the bodies of closures.

Two bounds keep the recursion within the stack. The frontend rejects a
function body that nests statements more than 256 levels or expressions more
than 1024 levels deep, with a source position, before Core exists. The
native wire reader and writer bound statement bodies and expressions at 4096
levels each, so Core from a file is bounded as well. `talac`, `tali` and the
fuzz programs run the pipeline on a thread with 256 MiB of reserved stack,
`Tala/Support/CompilerStack.hpp`, instead of the stack the
operating system gives the process, which is one megabyte on Windows. A
program that hosts the pipeline on another thread must give it enough stack
or accept a lower depth. The stack each stage uses per level is measured
with `//Talac/Fuzzing:source_stack_probe`, which compiles a source file
and reports the stack the compilation committed, and
with `//Talac/Support/Tests:stack_probe`, which runs one stage on a stack
of a chosen size; the measurements are recorded in
`Benchmarks/2026-10-04-Nesting-And-Chains.md`.

`Progmasoft.Tala.Desugarer.Sequencing` and `Progmasoft.Tala.Desugarer.Branching`
hold these rules. Result slots are
initialized with a neutral literal of their type that no path can observe.
`AssignmentExpressionTests.hs`, `LoopExpressionTests.hs` and
`BranchingTests.hs` pin the shapes and run a reference Core evaluator,
`CoreInterpreter.hs`, on the unoptimized and on the optimized Core against
hand-written results. `BranchingOracleTests.hs` additionally compares
generated matches with the `if` chains they stand for. The same programs run
through CorePrep, Xpp, Xmm, LLVM and the ORC JIT in `source_execution_smoke`.

## Expressions

Every Core expression has a statically queryable type.

### Variable

`CoreVariable` refers to a resolved symbol and repeats the expected type. The
verifier checks both existence and exact agreement with the declaration. The
repeated type keeps consumers local and deterministic; they need not rerun type
inference to inspect an expression.

### Literal

`CoreLiteral` pairs a payload with its scalar type. Payload forms are:

- arbitrary-precision host `Integer`, range-checked against the Tala type;
- exact floating source spelling, validated without host rounding;
- Unicode scalar `String` content;
- boolean; and
- the internal `CoreUnit` no-result marker.

The payload and declared type must match. For example, an integer payload is
not valid merely because its number could later convert to a float.

### Apply

`CoreApply` contains a callee expression, ordered argument expressions, and a
result type. The callee must have a `FunctionType`. Argument count, argument
types, and result type must exactly match that function type.

Core does not encode overload selection or default arguments. Those decisions
must already be complete.

### Primitive

`CorePrimitive` represents the target-independent operator set:

- add, subtract, multiply, divide, floor divide, and remainder;
- less-than, less-equal, greater-than, greater-equal, equal, and not-equal;
- logical and/or; and
- arithmetic negate and logical not.

Arithmetic operands must be numeric and use the same type. Comparisons return
`bool`. Logical operands accept bool or numeric context and return `bool`.
Unary primitives take one operand; other primitives take two.

An integer quotient or remainder by zero, and a shift by an amount that is
negative or not less than the width of its left operand, have no value. Core
says nothing about them; the optimizer does not fold them, and generated code
stops when it reaches one. `EVALUATION.md` has the details.

#### Memoize

`CoreMemoize` is a unary primitive whose operand is a callable. It is how a
value by need is handed from one function to another; `EVALUATION.md` says
when the frontend produces it.

- The operand is a callable without parameters whose result is `bool` or
  numeric.
- The result is a callable of the same type. The first call of it calls the
  operand and remembers what it returned; every later call returns the
  remembered value and does not call the operand again.
- The result is a value like any other callable: it may be bound, passed,
  captured and returned, and every copy shares the one remembered value.

#### Runtime call

`CoreRuntimeCall` is a call of a function of the runtime: joining two
strings, a conversion of the output format grammar, a console write. It is
the one primitive whose arity depends on its first operand.

- The first operand is an integer literal of type `int`, the identity of the
  function in the runtime catalog. It is never a value that is computed: what
  a program calls is fixed when the program is compiled.
- The operands after it are the arguments, in the order the function takes
  them, and they are evaluated in that order.
- The type of the expression is the one the function returns: `String`,
  `bool` or no value.

The catalog is `Progmasoft.Tala.RuntimeCall` in the frontend and
`Tala/Core/RuntimeCall.hpp` in the native stages; `ARTIFACT-WIRE.md`
lists its rows. A call that names no function, has the wrong number of
arguments, an argument of a type its function does not take, or a type other
than the function's result is rejected: `TAC1075` by the Core verifiers,
`TAC0026` by the Haskell and `TAC1076` by the native CorePrep verifier,
`TAP1048` by Xpp and `TAL1054` by Xmm.

A console write is an effect. The optimizer treats it as a call of a function
it knows nothing about: it is not removed when nothing uses its result, not
repeated and not moved. The other runtime calls compute a string and nothing
else. The frontend produces the
primitive for `System.Console` and for `+`, `==` and `\=` on strings;
`CONSOLE-IO.md` says how.

The Core verifiers reject any other operand of a remembering callable with `TAC1073`. The native
CorePrep verifier reports `TAC1074` and the Haskell one `TAC0025`, the Xpp
verifier `TAP1047` and the Xmm verifier `TAL1053`; each of the last four also
requires the result to have the operand's type. The optimizer does not fold
the primitive, and `MemoizeTests.hs` pins that it neither repeats a remembered
computation nor turns one remembering callable into two.

### Let

`CoreLet` binds one immutable symbol to a value and evaluates a body with that
symbol in scope. The value is evaluated exactly once, before the body. The
binding is visible only in the body; the verifier rejects a read of the symbol
anywhere else, including the other arm of an enclosing conditional. Lowering
uses it wherever a source operand is read more than once but must be evaluated
once: pattern subjects, inlined call arguments, and the left operand of truthy
coalescing.

### Conditional

`CoreConditional` contains a test, a first arm, a second arm, and a result
type. The test is evaluated in Boolean context; then exactly one arm is
evaluated and becomes the value. The other arm is not evaluated at all: its
calls, traps, and non-termination do not happen.

The verifier requires:

- a test of `bool` or numeric type (`TAC1067`);
- both arms to have exactly the result type (`TAC1068`, `TAC1069`); and
- a `bool` or numeric result type (`TAC1070`).

The last rule is a storage rule, not a language rule. CorePrep materializes the
result in one slot that both arms assign; a slot that held an owned value would
need move and release rules that the backend does not define yet. The native
verifier additionally rejects an in-memory conditional that does not carry
exactly three operands (`TAC1071`); the wire reader cannot produce one.

Source `condition ? first : second` lowers to one `CoreConditional`. Source
`left ?: fallback` lowers to

```text
let $coalesceN = left in ($coalesceN ? $coalesceN : fallback)
```

so the left operand is evaluated once and is both the test and the first
result.

Analyses treat the two arms as alternative paths, not as a sequence:

- effect inference adds the test's effect to the effect of each arm that is
  feasible under the incoming integer facts; an arm excluded by a known test
  contributes nothing;
- integer facts are refined by the test on each edge, the arms are transferred
  separately, and the continuation keeps only the join of both results;
- constant folding replaces a conditional whose test is a literal by the
  selected arm, and folds inside both arms otherwise; and
- inlining rewrites a call inside an arm in place, so an inlined body stays
  behind the same test.

### Closure

`CoreClosure` contains:

- ordered captures;
- ordered callable parameters;
- a return type;
- a nested Core statement body; and
- a callable expression type.

Its expression type must be a `FunctionType` whose parameter and return types
match the closure declaration. A value-returning closure body must return on every
path.

## Captures

A Core capture records:

- strong, weak, or unowned capture mode;
- the resolved name visible inside the closure;
- its declared type; and
- the initializer evaluated in the enclosing environment.

Capture and parameter symbols must each be unique in their own lists. Capture
initializers cannot read the capture they are defining; they are verified in
the enclosing environment. The initializer type must equal the capture type.

Closure conversion in CorePrep lifts the nested body into a function and places
hidden capture parameters before explicit callable parameters. Core itself
retains the structured closure because it is the better boundary for capture
analysis and target-independent optimization.

## Scalar widths

Core integer validation uses these exact ranges:

| Type | Range |
| --- | --- |
| `char` | 0 through 2^32 - 1 |
| `byte` | -2^7 through 2^7 - 1 |
| `short` | -2^15 through 2^15 - 1 |
| `long` | -2^31 through 2^31 - 1 |
| `int` | -2^63 through 2^63 - 1 |
| `longint` | -2^127 through 2^127 - 1 |
| `ubyte` | 0 through 2^8 - 1 |
| `ushort` | 0 through 2^16 - 1 |
| `ulong` | 0 through 2^32 - 1 |
| `uint` | 0 through 2^64 - 1 |
| `ulongint` | 0 through 2^128 - 1 |

Floating types are `sfloat`, `lfloat`, `float`, and `double`. Their payload is
still exact normalized spelling in Core; Xpp/Xmm and LLVM own binary semantic
lowering.

## Verification boundary

`verifyCore` checks the complete module and accumulates diagnostics. It does not
stop after the first malformed statement. Diagnostic groups cover:

- module and function identity;
- resolved types;
- duplicate parameters, bindings, captures, and closure parameters;
- definite returns;
- binding and assignment storage rules;
- condition compatibility;
- variable lookup and type agreement;
- call signatures;
- primitive arity, operand, and result types;
- let binding types and scope;
- conditional test, arm, and result types;
- literal payload/range validity; and
- closure callable/capture contracts.

The verifier returns the original module on success. This makes it convenient
to compose at boundaries without introducing a second “verified Core” tree that
could drift from the wire and optimizer models.

## Optimization boundary

The Core optimizer runs only after verification and specialization-demand
planning, then verifies its result again. Planning observes checked Core before
dead-code elimination so optimization cannot erase the only evidence of an
invalid open or malformed specialization. Its passes may:
Its passes may:

- propagate immutable literal bindings;
- fold exact integer and boolean primitives;
- select known branches and the selected arm of a conditional with a literal
  test;
- remove unreachable statements;
- delete unused pure bindings, writes, and evaluations; and
- optimize nested closure bodies.

It may not change symbol identity, infer a missing type, ignore a malformed
call, lower a closure layout, or introduce backend concepts. See
[Core optimization](CORE-OPTIMIZER.md) for pass behavior and effect rules.

## CorePrep adaptation

CorePrep converts nested expression evaluation to atoms and operations. It:

- introduces deterministic temporary symbols;
- creates explicit basic blocks;
- translates `CoreIf` to branch/jump structure;
- translates short-circuit operators and conditional expressions to branches
  over a result slot;
- lifts closure bodies to functions;
- materializes closure creation operations; and
- verifies targets, definitions, operation types, and terminators.

CorePrep is internal and has no public file extension or `-Emit` option. It
exists to adapt tree-shaped Core to Xpp without forcing the Core optimizer or
native Xpp lowering to reconstruct evaluation order.

## Wire representation

Public `.core` files use the bounded `TACR` contract documented in
[Artifact wire](ARTIFACT-WIRE.md). The wire preserves:

- qualified names and identifier spellings;
- positive `SymbolId` values;
- recursive types within a depth budget;
- exact scalar payloads;
- statement and expression order;
- capture modes and callable types; and
- all function and closure bodies.

Readers enforce document, collection, string, numeric payload, and recursion
limits before constructing an accepted module. Decoding is followed by semantic
verification. A magic or version for another representation is not guessed or
accepted as Core.

## Determinism

Equal verified modules encode to equal bytes and optimize to equal trees under
equal options. Determinism relies on ordered module lists, ordered statements,
stable symbols, exact literal payloads, and bounded codecs.

Human-readable spellings are retained for diagnostics but never regenerated
from map iteration. Optimizer maps and sets affect lookup or membership only;
they do not reorder emitted declarations.

## Ownership rules for contributors

Change Core only when a source semantic needs a target-independent typed form.
Before extending it:

1. update the Core data model;
2. define expression typing and symbol ownership;
3. add verifier acceptance and rejection rules;
4. update the bounded wire format with an explicit version decision;
5. update the optimizer's effect, symbol, metric, and nested-expression walks;
6. update CorePrep adaptation and verification;
7. update the native Core reader/verifier if the form crosses `.core`;
8. add round-trip and malformed-document tests;
9. add frontend-to-Core and Core-to-CorePrep integration tests; and
10. document current native support without claiming a later stage is connected
    before its implementation exists.

Do not place source parser recovery nodes, project DSL settings, LLVM objects,
or target ABI state in Core. Those belong to their owning layers.
