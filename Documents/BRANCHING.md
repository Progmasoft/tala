<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Match, if expressions, guard and nested blocks

This page describes what the compiler implements today for `match`, for `if`
used as an expression, for `guard` and for a block written as a statement:
what is accepted, in what order things are evaluated, and where the
implemented subset ends. It describes an implementation and is not the
language contract: the language is defined by `Spec/`, here
`Spec/Language/Decls.tala`, sections 31 and 32, and where this page and the
specification differ the specification is right and the compiler is wrong.
Where the specification is silent, what the compiler does today is a state of
the implementation and not a decision about the language. The diagnostics are
listed in [Diagnostics](DIAGNOSTICS.md); the lowering is described in
[Core IR](CORE-IR.md).

## Match

```talac
int kind = match (code), (strict) {
    (0), (_) -> 10,
    (1), (true) -> 20,
    (int other), (_) if other < 0 -> 0 - other,
    (_), (_) -> { int rest = code - 1; rest + 30 }
};
```

- Every subject has its own parentheses, and every arm has one pattern for
  each subject. Parentheses around a pattern are optional.
- The subjects are evaluated once, left to right, before any arm is tested.
- The arms are tested in source order. The first arm whose patterns accept
  the subjects and whose guard holds is selected; exactly one body runs.
- A guard, `pattern if condition ->`, is evaluated only when the patterns of
  its arm accept. A guard that is false passes the subjects on to the arms
  after it. A guard is `bool` or numeric; a numeric guard holds when it is
  not zero.
- The body is an expression or a block. The comma after an arm is optional,
  as in the grammar. An expression body is parsed like every expression, so
  a parenthesized pattern that follows it without a comma is read as the
  argument list of a call of the body; the arrow that then follows is
  reported as `TAP0038`, which says what was read.

### Patterns

| Pattern | Accepts | Notes |
| --- | --- | --- |
| a literal, `1`, `-1`, `true`, `'a'` | the value equal to it | typed from its subject and checked against its range; a `-` may precede a numeric literal only |
| `_` | every value | |
| `Type name` | every value of the subject's type | binds the value of the subject as a local of its arm |
| `Type _` | every value of the subject's type | binds nothing |

A binding is in scope in the guard and the body of its own arm only. It is an
ordinary local: it may be assigned, and assigning it does not change the
subject. Two arms may bind the same name; one arm may not bind a name twice, and a binding may
not reuse a name that is already in scope. A bare name is not a pattern: a
binding always states its type.

`null` and type patterns that name another type than their subject's are
parsed and rejected, because reference subjects and class hierarchies are
not implemented. Enum case patterns such as `.Ready` are implemented; see
"Limits of the implemented subset" below.

### Statement and expression

A `match` at the start of a statement is the statement form. It needs no
terminator. Its block bodies are statement blocks of the enclosing body: they
may `return`, and inside a loop they may `break` and `continue`. An expression
body is evaluated for its effect and must have one. When no arm accepts,
nothing happens.

Anywhere else a `match` is an expression, and so is a `match` that is the
last item of a block used as a value:

- every arm yields a value, and all arms have one type;
- an arm made only of untyped numeric literals takes its type from the place
  that receives the match, and without one from the first arm that has a
  type;
- some arm must accept whatever the subjects are. That is established by an
  arm without a guard whose patterns are all `_` or type patterns, or, when
  every subject is a `bool`, by arms without guards that accept every
  combination of `true` and `false` between them. No other set of literals
  counts as complete.

In both forms an arm that can never be selected is an error: an earlier arm
without a guard accepts everything it accepts.

## If as an expression

```talac
int larger = if (first > second) { first } else { second };
```

An `if` in operand position is an expression. Both blocks are required, the
`else` branch is a block and not another `if`, and each block ends with an
expression that has no semicolon; that expression is the value of the block.
Only the selected block runs. The two blocks have one type. An `if` at the
start of a statement is the `if` statement, as before, with one exception: as
the last item of a block used as a value, an `if` whose two blocks both end
with a value is the value of that block.

```talac
int sign = if (value < 0) { 0 - 1 } else { if (value > 0) { 1 } else { 0 } };
```

## Blocks used as values

The blocks of an `if` expression and the block bodies of the arms of a match
expression are blocks used as values. Statements before the final expression
run in order, and names declared in the block end with it.

A block may leave instead of yielding a value:

```talac
int size = if (count > 0) { count * 2 } else { return 0; };

while (index < limit) {
    index += 1;
    total += match (index) { 3 -> { continue; }, 7 -> { break; }, int n -> n };
}
```

`return` leaves the enclosing method and carries its return type, also from
inside a loop used as an expression. Where the return type of a callable is
inferred, the returns in its value blocks count like the others; the returns
of a nested callable are its own. `break` and `continue` target the nearest
loop around the expression and need one. A `break` may carry a value to a
loop used as an expression, exactly as a `break` statement in its body does.
A block that cannot complete normally has no final expression and no value;
the expression has the type of the blocks that complete. Such a block is
lowered as its statements alone: nothing is stored for it.

A value block may also stand in the condition or the update clause of a
loop. Both belong to their loop, as examples 79 to 83 of
`Spec/Language/Iteration.tala` state. A `break` in either leaves that loop,
with the effects of the condition or the update up to it. A `continue` in
the condition abandons the rest of the condition and evaluates it again,
without running the body or, in a `for`, the update; a condition that always
continues is an endless loop. A `continue` in the update clause ends the
update, and the condition is tested next. A callable is not inside the loops
around the place that creates it.

```talac
while (if (index >= limit) { break; } else { true }) { index += 1; }

for (int i = 0; i < 6; i += if (skip) { skip = false; continue; } else { 1 }) { }
```

An expression none of whose blocks completes is valid and never yields a
value:

```talac
int result = if (known) { return code; } else { return 0; };
```

Whether an expression completes is a fact about control flow that the
compiler keeps apart from types (`Progmasoft.Tala.Completion`); there is no
type for it in the language. What would have received the value, here the
binding, is not held to a type and is not lowered: the statement becomes the
conditional over the two `return` statements, with no result slot and no
placeholder, and the statements after it, which are never reached, are
checked but not lowered. The same holds for such an expression as an
operand, an argument, a condition or a returned value: the operands that are
evaluated before it keep their effects, and nothing after it is evaluated.

## Guard

```talac
guard (count > 0) else {
    return 0;
}
```

The block runs when the condition is false. It must not complete normally on
any path, so the statements after the guard run only when the condition held.
That is decided from the control flow of the block, by the rule given under
`TAT0061` in [Diagnostics](DIAGNOSTICS.md): `return`, `break` and `continue`
leave, and so do an `if` both of whose blocks leave, a loop that cannot end,
and a statement `match` that always selects an arm and all of whose arms
leave. A call is assumed to return.

## Nested blocks

A `{` at the start of a statement opens a nested block. Its statements run in
order, and the names it declares are in scope only inside it, so two blocks
side by side may declare the same name. A nested block may not redeclare a
name that is in scope around it.

## Limits of the implemented subset

- Subjects and results of `match`, and results of `if` expressions, are
  `bool` or numeric. Other types need storage rules for the result slot that
  the backend does not have yet. A value of a template type parameter is
  rejected for the same reason.
- A `match` over a classic enum uses case patterns, `.Member`. The pattern
  accepts the value of the member, so two members with one value are one
  case and the second arm for it can never be selected (`TAT0053`). The
  match accepts every value, and needs no `_` arm, when its arms without
  guards name every value of the enum; with several subjects, every
  combination of the values of enums and `bool` subjects, up to 256
  combinations.
- Parts of these forms that the specification has and the compiler does not
  implement yet are listed, with their diagnostics, under "Pending branching
  and loop forms" in [Implementation status](IMPLEMENTATION.md).
- A type pattern over a scalar subject names the type of the subject itself;
  no numeric conversion is applied, so `long n` does not match an `int`.
- `match` and `guard` are reserved words.
- A match may have any number of arms: it is lowered to one chain of
  conditionals, the shape of an `else if` chain, which every stage walks in
  a loop. The body of an arm is one statement level below its match however
  many arms the match has. See the nesting limits in
  [Diagnostics](DIAGNOSTICS.md).
- In the body of a method, a closure or a property, which may also end with
  an expression, an `if` or a `match` in last position is still the
  statement form.

## Where it is implemented and tested

| Concern | Location |
| --- | --- |
| grammar | `Progmasoft.Tala.Parser.Match` and the statement and primary-expression dispatch of `Progmasoft.Tala.Parser` |
| scoping of pattern bindings and nested blocks | `Progmasoft.Tala.Resolver.Renamer` |
| typing rules | `Progmasoft.Tala.TypeChecker.Branching` |
| lowering to Core | `Progmasoft.Tala.Desugarer.Branching` |
| grammar, typing, lowered shapes, evaluation | `BranchingTests.hs`, with the programs of `BranchingEvaluationCases.hs` |
| match against the `if` chain it stands for | `BranchingOracleTests.hs` |
| diagnostic positions, damaged input, templates | `BranchingDiagnosticTests.hs` |
| native execution in both pipeline modes | `Talac/Fuzzing/BranchingExecutionCases.cpp` |
| generated programs with an independent host model | shape 13 of `Talac/Fuzzing/SourceFuzz.cpp` |
