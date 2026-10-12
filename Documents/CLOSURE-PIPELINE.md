<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Closure compilation pipeline

Tala callable literals are first-class AARC reference values. A callable
literal combines executable behavior with an ordered captured environment. This
document describes how the compiler preserves that model from source to the
native backend boundary; the language specification remains authoritative for
source semantics.

## Source and AST

The Haskell lexer and parser accept typed, inferred, and zero-parameter forms:

```talac
\(int left, int right) -> left + right
\left, right -> left + right
\() -> 42
\ -> 42
```

Expression and block bodies remain distinct AST forms. Capture lists retain
source order and ownership:

```talac
[value] \ -> value
[weak owner] \ -> owner
[unowned owner] \ -> owner
[answer = Calculate()] \ -> answer
```

An empty list is meaningful: `[] \ -> 42` selects explicit capture mode with no
captures. It is not equivalent to omitting the list.

The AST records explicit/implicit mode, ordered captures, ownership, private
binding names, initializer expressions, parameters, body form, source span, and
the current stage annotation. It does not choose a heap layout.

## Renaming and resolution

Every callable parameter receives a fresh symbol. Every explicit capture also
receives a fresh symbol distinct from its outer binding. `[value]` is
materialized as an outer-scope read stored in a closure-private binding. This
makes captured-binding independence structural and prevents assignment inside
the closure from mutating the outer binding by accident.

Capture initializer expressions are resolved in the surrounding scope and in
source order. Their aliases become visible only inside the callable body.
Explicit capture mode restricts outer lookup to listed captures, so an omitted
binding produces a name-resolution diagnostic.

## Type checking and analysis

Explicit types remain ordinary parameter types. An inferred parameter receives
a symbol-backed type variable instead of a dynamic fallback. Expression bodies
use their expression type; block bodies use their final expression and explicit
returns. The resulting callable has a `FunctionType`.

Capture initializers are checked in the outer environment. Their type annotates
the private capture slot. Weak and unowned captures require an AARC reference
type, including `String`, callable, and resolved nominal references; primitive
non-owning captures are rejected.

The frontend also publishes a layout-neutral closure catalog. A summary records
lexical parent/children, source span, callable type, parameters, ordered
captures, alias/read/write facts, nested use, and whether the body calls or
returns. Analyzer and optimization passes can consume these facts without
duplicating AST traversal.

## Core

Core represents a closure as a typed expression containing ordered
`CoreCapture` entries, callable parameters, inferred return type, lowered body,
and public callable type. Each capture stores ownership mode, private symbol,
slot type, and creation-time value expression.

Implicit captures are discovered as free symbol reads after desugaring.
Parameters and callable-local bindings are removed, while remaining captures
keep stable first-use order.

Core verification checks signature consistency, capture initializer types,
symbol validity, parameter uniqueness, nested expressions, and return behavior.
Optimization recursively folds capture initializers and closure bodies without
reordering captures.

Core wire version 10 serializes ownership, captures, parameters, return type,
nested statements, and structured loop statements. Existing byte, count,
type-depth, and expression-depth limits also apply to closures.

The native TACR v10 reader and writer carry the same closure expression tag and
field order as the Haskell frontend. The C++ Core verifier validates capture
ownership, callable shape, nested body returns, and capture mutation before
CorePrep lifting. This keeps callable-containing `.tala` input on the ordinary
frontend-to-native path rather than relying on hand-built CorePrep fixtures.

## CorePrep closure conversion

CorePrep converts each closure by:

1. allocating a deterministic synthetic lifted-function symbol;
2. atomizing capture values from left to right;
3. emitting `CorePrepMakeClosure` with target and capture slots;
4. prepending hidden capture parameters to source parameters;
5. appending the lifted body to a module work queue;
6. processing that queue until nested closures are also lifted.

CorePrep verification checks callable result type, lifted target, capture atom
types, symbol validity, and non-owning restrictions. CorePrep wire v8 preserves
this lifted closure metadata. Xpp wire v3 gives closure creation a dedicated
operation tag; a function symbol is never encoded as a fake data operand. Xpp and
Xmm wire v7 also retain source catalog and function ownership metadata.

## Native C++ stages

The C++20 Xpp/Xmm decoders consume their version 7 contracts. Xpp retains the
lifted symbol, ordered operands, ownership vector, and callable result. Its
verifier checks the target's hidden parameter prefix against captures.

Xmm assigns registers to capture values while preserving the lifted target and
ownership modes. Its verifier repeats cross-function checks after register
lowering so malformed in-memory IR cannot bypass the wire verifier.

## LLVM boundary

LLVM emission uses the [AARC ABI](AARC-ABI.md) rather than inventing a raw
function-pointer approximation. `MakeClosure` now emits a typed payload, metadata,
allocation, capture initialization, and a destructor that balances strong, weak,
and unowned slots. Indirect invocation through the resulting closure pointer is
the remaining callable boundary; construction and destruction are connected.

A callable that remembers its result, `Memoize`, is a second producer of the
same kind of object: an invoke thunk first, and a destructor named by its
metadata. It is called and released through the same instructions as a
closure. `AARC-ABI.md` has its payload.

## Verification coverage

Tests cover delimiter and parameter forms, expression/block bodies, empty and
populated capture lists, aliases and order, duplicate/omitted captures, private
symbols, invocation checking, non-owning restrictions, implicit free-variable
discovery, nested conversion, Core/CorePrep verification, and the Core/CorePrep
v6 codecs.

Native tests independently verify codec symmetry and metadata preservation
through Xpp and Xmm. Each stage rejects malformed closures at the boundary it
owns instead of relying on a later backend failure.
