<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# First-class callable ABI

This document defines the native boundary for invoking a Tala callable
value. It complements the lexical capture rules in
[Closure pipeline](CLOSURE-PIPELINE.md) and the ownership rules in
[AARC ABI](AARC-ABI.md). The contract begins after Haskell closure conversion:
CorePrep has already lifted callable bodies and ordered their captures.

## Two kinds of callees

Xpp and Xmm preserve a distinction that source syntax intentionally hides:

- a direct function symbol identifies a function declared in the module; and
- a callable local contains an AARC-managed closure environment.

Both are called with the same source expression, but they are not interchangeable
backend values. A direct symbol lowers to a normal LLVM function reference. A
callable local lowers to a data register, from which the backend loads an invoke
thunk. Treating every function-typed symbol as a module function loses captured
state and is therefore invalid.

The callable type contains only public parameters and the public result. Visual
X# spells a no-result callable with `void`; the native model's historically
named `unit` value is a private no-result marker, not a source-language type.

## Lifted target contract

A lifted target receives parameters in this order:

1. one hidden parameter for every capture, in canonical capture order;
2. every source-visible callable parameter, in declaration order.

Its result must equal the public callable result. The shared callable contract
checks the capture prefix, public suffix, and result before LLVM lowering. Xpp
and Xmm use the same helper so a serialized stage cannot exploit a disagreement
between verifiers.

For a source callable conceptually equivalent to `int(int)` with two captures,
the shapes are:

```text
public callable: (int) -> int
lifted target:   (Capture0, Capture1, int) -> int
invoke thunk:    (Environment*, int) -> int
```

The environment layout is private to the closure creation site. A caller never
derives capture count, type, or ownership from the lifted target.

## Environment layout

The closure object is allocated through the AARC runtime. Its payload begins
with an invoke-thunk pointer followed by capture slots:

```text
+--------------------------+
| invoke thunk pointer     |
+--------------------------+
| capture 0 storage        |
+--------------------------+
| capture 1 storage        |
+--------------------------+
| ...                      |
+--------------------------+
```

The first field is not the lifted target. Storing the lifted target there would
force every indirect call site to know how many hidden arguments to synthesize.
The thunk owns that adaptation and gives every callable value one uniform public
calling convention.

Each creation site receives a private thunk and private destructor. LLVM may
merge equivalent private functions later, but Xmm does not rely on that
optimization for correctness.

## Invocation sequence

An indirect call performs these operations in order:

1. load the closure payload from the callable register;
2. load the thunk pointer from payload field zero;
3. call the thunk with the payload pointer followed by public arguments;
4. place a value result in the declared destination, or produce no destination
   for a source `void` call.

The thunk then:

1. loads capture slots from the environment;
2. performs any required non-owning upgrades;
3. appends public arguments;
4. calls the lifted target;
5. balances temporary ownership; and
6. returns the lifted result.

The caller keeps the closure alive for the duration of invocation. A later
liveness pass may make that ownership edge explicit, but it must not shorten the
lifetime across the thunk call.

## Capture ownership during a call

Strong captures are borrowed while the closure is alive. Their environment
slots already own the captured objects, so retaining every invocation would add
unnecessary atomic traffic.

Weak captures are upgraded with `tala_aarc_lock_weak`. Unowned captures are loaded
with `tala_aarc_load_unowned`. Each successful operation returns a temporary
strong reference, which the thunk releases after the lifted call. A nullable
weak result remains nullable according to source semantics. Unowned failure
behavior remains the responsibility of the runtime contract; the thunk must not
turn it into an unchecked raw pointer access.

Scalar captures are copied inline. The ownership verifier rejects weak or
unowned storage for a scalar before code generation.

The closure destructor is independent of invocation. It releases strong capture
slots, releases weak/unowned control handles, and never calls the invoke thunk.

## Verification boundary

Before lowering, the module must prove all of the following:

- a direct callee resolves to a declared function;
- an indirect callee resolves to initialized register storage;
- the callee type is callable and has a result component;
- public argument count and types match the callable signature;
- a closure's lifted target exists;
- capture modes and capture operands have equal counts;
- the lifted target has at least the capture-prefix arity;
- every hidden capture type matches its target parameter;
- every public parameter matches the remaining target suffix; and
- the lifted target result matches the public callable result.

Malformed Xpp must fail at the Xpp verifier. Malformed Xmm, including an artifact
loaded from disk, must fail independently at the Xmm verifier. LLVM lowering is
not a recovery mechanism and does not guess missing callable metadata.

## Optimization rules

An optimizer may devirtualize a callable only when it proves the exact closure
creation site and preserves capture ownership. Function type equality alone is
not proof of target identity.

It may inline a thunk and lifted target together, remove unused scalar captures,
or elide balanced temporary ownership when the runtime proof remains valid. It
must not reorder a weak/unowned upgrade after the lifted call, release a
temporary before the call completes, or expose the environment layout as a
public ABI.

Direct calls remain eligible for ordinary LLVM inlining. Indirect calls retain
their typed function signature so LLVM can validate argument and result ABI even
with opaque pointers.

## Current limits

This slice provides native indirect invocation for closure values already
present in CorePrep, and for methods used as values, which become closures
without captures in Xpp. A callable parameter is borrowed and a callable
result is owned; the placement pass of [Ownership flow](OWNERSHIP-FLOW.md)
writes the retains and releases. It does not complete whole-program escape
analysis, cross-module callable ABI stability, exception cleanup around
upgraded captures, or the future cycle collector.

The planned cycle collector combines concurrent Bacon–Rajan processing with
trial deletion and remains disabled by default. Callable environments preserve
explicit ownership metadata so that future candidate discovery does not require
reconstructing captures from LLVM IR.

## Regression expectations

The native suite must cover direct versus register callee classification,
zero-capture and captured callables, public argument forwarding, value and
`void` results, malformed capture prefixes, malformed public suffixes, result
mismatch, payload thunk storage, typed indirect LLVM calls, and non-owning
temporary balancing.

Any future wire-format change must round-trip the same distinction. Tests must
assert semantic fields and verifier outcomes rather than rely only on a textual
LLVM snapshot.
