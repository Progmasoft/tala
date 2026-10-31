<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Evaluation by need

Tala is a lazy language with call-by-need evaluation. A value is computed
when it is first needed and at most once, and a value that is never needed is
never computed. Effects are not lazy: they happen where they are written. The
source has no notation for either; the compiler tells the two apart. The rules
are in `Spec/Language/Evaluation.tala`.

This document says how much of that the compiler implements and how. It is an
implementation reference, not the definition of the language.

## What is implemented

The value of a local binding is computed by need when all of the following
hold:

- its type is `bool`, a numeric type or an enum;
- the binding is never assigned after it is declared;
- no closure captures it;
- its initializer is built from names, literals, operators, tests,
  conditionals and calls, with no store, no transfer of control and no block.

That holds in the body of a method and in the body of a callable alike.

Such a value is computed by the first read that is reached, and by no later
one. A binding whose initializer is never read computes nothing, so a division
by zero or a call that never returns in it does nothing.

An argument of a call that names a method directly is passed by need when all
of the following hold:

- the type of the parameter is `bool`, a numeric type or an enum;
- the method is not certain to need the parameter before it does anything
  else that can be observed;
- the argument has no effect, and it may fail, may run without end, or reads a
  value that is itself computed by need.

Such an argument is computed when the method first needs it, at most once
however often the method reads it and however many methods it is handed
through, and not at all when no method needs it. When the caller needs the
same value, whoever needs it first computes it for both.

Everything else is computed where it is written, as before. That is correct
for an expression with an effect and a restriction of the implementation for
the rest; see "What is pending".

## How a binding is deferred

The frontend lowers a deferred binding without any new form of Core. The
binding declares three kinds of local:

- the local itself, with a neutral value;
- a flag that is false until the value has been computed;
- a copy of each variable the initializer reads that is assigned anywhere in
  the function, taken where the binding stands.

Every read of the local is lowered to a test of the flag that, when the flag
is false, evaluates the initializer, stores the value and sets the flag,
followed by a read of the local. The initializer is lowered at each read, over
the copies, so it means what its variables held at the binding however late it
runs. The stages after the frontend see ordinary locals, stores and branches.

The body of a method is lowered twice. The first lowering evaluates every
binding in place and is kept only for what it shows: which locals are assigned
after their binding and which a closure captures. The second lowering defers.

An expression written as a statement of its own, and a value assigned to the
discard, are evaluated: the statement is the need. That is the rule of the
language, example 12 of the specification file, not a restriction.

## Output is an effect

A store shows in the expression that makes it. Console output does not:
`int x = Log(1);` writes only because of what the body of `Log` does. The
frontend therefore finds the methods a call of which may write, from all
methods of the program together, and an expression that contains such a call
is evaluated where it stands: its binding computes its value in place, and as
an argument it is computed at the call. Examples 15 and 16 of the
specification file state the rule, and `CONSOLE-IO.md` describes the analysis
and what it errs on.

## How an argument is passed by need

A value that one function hands to another cannot live in a flag and a slot of
a frame: the other function cannot reach the frame. It lives in a *suspended
computation*, a callable without parameters that computes the value the first
time it is called and returns the remembered value every time after. Core has
one primitive for it, `Memoize`: its operand is a callable without parameters
whose result is `bool` or numeric, and its result is a callable of the same
type that calls the operand at most once. Every copy of the result shares the
one remembered value. `CORE-IR.md` has the operation and `AARC-ABI.md` the
object it becomes.

The frontend decides per method which parameters are passed by need. A
parameter of a type that can be suspended is passed by need unless the first
thing the method does that can be observed needs it. Statements that only
bind values without effects, or evaluate expressions that can neither fail nor
run without end, are passed over on the way to that first thing; a call does
not need an argument it passes by need itself, so the answer for one method
depends on the others and is computed for all of them together until it no
longer changes.

A method keeps the function it always had, with every parameter a value. A
method with a parameter by need gets a second function beside it, named after
the method with `$need` and a number, that takes a suspended computation in
the place of each such parameter. It is lowered from the same body, and a read
of such a parameter calls its computation. It is lowered only when some call
asks for it.

A call uses the second function when at least one argument is worth
suspending. For each parameter that is passed by need it passes:

- the suspended computation of the argument, created at the call, when the
  argument is handed on by need. It takes the values of the variables the
  argument reads as they are at the call, so the argument means what it meant
  there however late it is computed;
- the computation itself, when the argument is the name of a value that is
  already suspended. That is how a value handed through several methods is
  still computed once;
- a callable that returns the value, computed at the call, for any other
  argument.

Every other call uses the function the method always had and computes its
arguments at the call, which costs nothing and cannot be told apart.

A local whose value may be handed on by need is suspended in a computation of
its own instead of a flag and a slot, and every read of the local calls it.
That is what lets the caller and the method share one computation.

A suspended computation is not free. It is two objects of the runtime, a
closure over what the argument reads and the callable that remembers its
result, and in generated code a function for the argument and an entry the
closure is called through. A program whose calls pass many arguments that are
themselves calls is several times larger than it was when arguments were
values, and takes correspondingly longer to compile. One object and no
function of its own for a computation that only calls a method is possible
and pending.

## Where laziness cannot be observed

Deferring a value costs a flag and a test at each read. The compiler computes
a value where its binding stands, with neither, in two cases in which no
program can tell:

- the initializer cannot fail and cannot run without end, and reads no value
  that is itself deferred: it does not call and does not divide;
- the statement after the binding is certain to read the value: the
  expression that statement evaluates first reads it outside the right side of
  `&&` and `||` and outside the branches of a conditional.

In the second case one thing differs: when the value and an operand evaluated
before it in that statement both fail, the value fails first. The language
leaves that open. Example 13 of `Spec/Language/Evaluation.tala` says that
whether a program fails is determined and which of several failures one
statement meets is not, and that a value which runs without end counts as one
that cannot be computed. The order of statements and of effects is
determined. The same rule covers a value that an expression is certain to
read more than once, which is computed ahead of that expression.

A call needs the arguments it passes as values and does not need the ones it
passes by need, so the second case does not count a read that stands in an
argument passed by need.

The same reasoning decides which parameters are passed as values: one that the
method is certain to need first is computed at the call.

## What is pending

These are parts of the language the compiler does not implement yet. None is a
restriction of the language.

| Pending | Today |
| --- | --- |
| an argument of a call through a callable | computed at the call: a callable takes values |
| an argument that a closure of the method captures | computed when the method is entered, because a closure takes the values of its captures when it is created |
| arguments of other types by need: `String`, callables, objects | computed at the call |
| arguments of a method of a template | computed at the call |
| results returned by need | a returned value is computed before the method returns |
| values of other types by need: `String`, callables, objects | computed where they are written |
| a variable that is assigned again | the binding and every assignment are computed in place |
| a binding that a closure captures | computed in place |
| every value by need as a suspended computation | a value that stays in one function is a flag and a slot in its frame; only a value that may be handed on is a suspended computation |
| the computation of a value by need stated once | every read carries it; see below |
| effects other than stores, transfers of control and console output | none exist in the implemented subset: it has no input and no shared state |

A read of a value by need carries the computation of that value, guarded by
its flag, because the frame of one function is all a value by need has
today. An expression that is certain to read such a value more than once
computes it once ahead of itself, so a chain of values of which each reads
the one before it several times grows with its length. Reads that stand in
different branches of one expression are not certain and each carries the
computation: `int b = (c ? a : 0) + (d ? a : 1);` holds the computation of
`a` twice, and a chain of such bindings doubles with every link. That is a
cost in compile time and code size, never in what a program computes. A value
that is suspended does not have it: a read of it is one call.

## Values that cannot be computed

Example 14 of the specification file names the values that have none: an
integer quotient or remainder by zero, with `/`, `//` and `%`, and a shift by
an amount that is negative or not less than the width of the shifted value. A
program that needs one stops.

LLVM gives the instructions for these operations no meaning on such operands.
Without a check an optimizer is free to delete the computation and what
depends on it, and it did: a program that divided by zero and needed the
quotient ran on as if it had not. The backend therefore precedes each such
instruction with a check that stops the program with a trap. The check is a
small internal function that is always inlined, so it costs one comparison
where the operand is unknown and nothing where it is known.

The least value of a signed type divided by minus one is not such a value.
Its quotient does not fit the type, which generated code treats as it treats a
sum or a product that does not fit: the result wraps, to the least value
again, with remainder zero. The processor's own division instruction would
stop the program, so the backend carries that one division out with a divisor
of one. The language has not fixed what a result that does not fit is; this
is the behaviour of the backend, pinned by `ComputabilityExecutionTests.cpp`.
The reference Core evaluator of the tests computes with unbounded integers and
does not wrap.

A program that stops this way ends with the status the operating system gives
a process that executed an instruction the processor refuses. A diagnostic
that names the failure is pending.

## Verification

`LazyEvaluationTests.hs` observes laziness through what tells a computed value
from one that was not: a division by zero, a call that never returns, and the
number of steps a program takes in the reference Core evaluator, which is how
"at most once" is checked, for a value the caller and a method share as well.
`MemoizeTests.hs` has the rules of the remembering callable and its evaluation.
`source_feature_smoke` runs the same programs through LLVM in both pipeline
modes, where a division by zero that was computed would end the process and a
call that never returns would never end, and checks after each program that no
object of the runtime is left behind. `executable_run_tests` builds programs
into native executables and runs them as processes: a program that passes
arguments by need, one that needs a quotient by zero and stops, and one that
creates and releases two million suspended computations.
