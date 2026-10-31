<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Scalar pipeline

This document describes how fixed-width scalar values travel through the
implemented compiler. It complements the source-language rules in
[Numeric types](NUMERIC-TYPES.md) by concentrating on stage boundaries,
verification, serialization, and native lowering.

## Design goals

The scalar pipeline has five non-negotiable properties:

1. A Tala type has the same width on every development host.
2. Literal parsing never narrows through a host `Int`, `long`, or `double`.
3. Every serialized value carries enough type information to reconstruct it.
4. Each IR verifier independently rejects an invalid type/payload pair.
5. LLVM receives signedness, width, and floating semantics explicitly.

The implementation therefore avoids C and C++ ABI assumptions. Tala
`int` is 64-bit even on a platform where C++ `int` is 32-bit, and Tala
`long` remains 32-bit even where a native `long` has another width.

## Canonical catalog

| Source spelling | Core kind | Family | Bits | LLVM form |
| --- | --- | --- | ---: | --- |
| `bool` | `Bool` | boolean | 8 storage / 1 condition | `i1` condition |
| `char` | `Character` | character | 32 | `i32` |
| `byte` | `Int8` | signed integer | 8 | `i8` |
| `short` | `Int16` | signed integer | 16 | `i16` |
| `long` | `Int32` | signed integer | 32 | `i32` |
| `int` | `Int64` | signed integer | 64 | `i64` |
| `longint` | `Int128` | signed integer | 128 | `i128` |
| `ubyte` | `UInt8` | unsigned integer | 8 | `i8` |
| `ushort` | `UInt16` | unsigned integer | 16 | `i16` |
| `ulong` | `UInt32` | unsigned integer | 32 | `i32` |
| `uint` | `UInt64` | unsigned integer | 64 | `i64` |
| `ulongint` | `UInt128` | unsigned integer | 128 | `i128` |
| `sfloat` | `Float16` | floating point | 16 | half |
| `lfloat` | `Float32` | floating point | 32 | float |
| `float` | `Float64` | floating point | 64 | double |
| `double` | `Float128` | floating point | 128 | fp128 |

Signed and unsigned integers share LLVM bit-vector types. Signedness remains
part of the Core, CorePrep, Xpp, and Xmm type and selects the LLVM instruction
for division, remainder, ordering comparisons, and extension.

## Frontend ownership

The Haskell frontend owns source spelling and target selection. The lexer
recognizes the complete token without converting it to a machine value. The
parser retains literal structure, and TypeChecker applies a declared target
or the language default.

Range checks use arbitrary-precision `Integer`. This is important for
`longint` and `ulongint`, whose endpoints cannot be represented by a signed
64-bit host value. A literal that is one greater than `ulongint` maximum is
still represented accurately long enough to produce a range diagnostic.

Floating-point spellings remain decimal text through the frontend. This
prevents an early binary64 rounding step from changing a `double` literal
before LLVM converts it to fp128.

## Core floating constant folding

The verified Core optimizer folds literal floating arithmetic without using
the compiler host's `float` or `double`. It decodes the retained decimal text
as an exact integer ratio, rounds the result once to the operand's declared
format using round-to-nearest, ties-to-even, and emits a short decimal spelling
that round-trips to that same format. The mapping is `sfloat` → binary16,
`lfloat` → binary32, `float` → binary64, and `double` → binary128.

The current foldable set is addition, subtraction, multiplication, division,
remainder, unary negation, numeric comparisons, and logical truth conversion.
Rounded division (`//`) first computes the quotient in the source floating
format, then rounds that quotient to the nearest integer with exact halves
away from zero, matching the existing operator contract. Operations involving
NaN and infinity follow IEEE unordered comparison and arithmetic outcomes;
signed zero, subnormals, underflow, and overflow are retained in the folded
literal. A rounded integer result is folded only when it fits the Core result
type.

Power and transcendental operations remain explicit. The optimizer does not
reinterpret a NaN payload, evaluate arbitrary calls, or use a host-dependent
approximation. Core verification runs before optimization and again afterward,
and every output literal must pass the same scalar spelling and type checks.
The Criterion `Core/ConstantFoldFloating` group measures verified default
optimization over increasing expression sizes; `FloatingOptimizerTests`
covers all four widths, rounding boundaries, special values, and verifier
acceptance.

## Core representation

Core uses a structured literal variant:

- `monostate` for the no-result ABI marker;
- `bool` for canonical boolean constants;
- `IntegerLiteral` for every integer and character width;
- `FloatingLiteral` for every floating width; and
- UTF-32 text for `String`.

`IntegerLiteral` contains a sign bit and an unsigned big-endian magnitude.
Zero has an empty magnitude and is never negative. Leading zero bytes are not
canonical. These rules make the representation independent of endianness and
make equality deterministic.

Compatibility alternatives for the historical signed 32-bit and 64-bit
payloads remain readable in the in-memory variant. Current Core v10 and CorePrep
v8 producers use the structured representation for the complete scalar
catalog.

`FloatingLiteral` contains a validated ASCII spelling. Accepted finite forms
have decimal digits, an optional point, and an optional decimal exponent.
`nan` and `inf`, with an optional sign, are also explicit forms. Locale commas,
hexadecimal floats, digit separators, and whitespace are rejected here.

## Core verification

Core verification is not a substitute for TypeChecker. It is a trust boundary
for modules loaded from artifacts or produced by another frontend.

For each constant, the verifier checks:

- that the payload alternative matches the declared Core type;
- that an integer magnitude is canonical;
- that the value fits the declared signed or unsigned width;
- that a character is nonnegative and fits 32 bits;
- that floating spelling follows the transport grammar; and
- that text is paired only with `String`.

Primitive verification then checks operand and result types. Arithmetic
operands must use one matching numeric type. Relational operations consume a
matching numeric pair and produce `bool`. Logical operands may use distinct
numeric types; CorePrep compares each numeric operand with a same-typed zero so
Xpp, Xmm, and LLVM receive canonical booleans. Numeric branch conditions use
the same conversion.

## Core wire v10

Core wire v10 writes a distinct type tag for every catalog member and retains
the project source ownership introduced in Core v6. It adds structured loop
statement tags without changing scalar payloads. Integer
payloads contain:

1. a literal tag;
2. one byte for the sign;
3. a little-endian unsigned 32-bit byte count; and
4. a big-endian magnitude of that length.

Floating payloads contain a literal tag, a little-endian unsigned 32-bit text
length, and ASCII bytes. String payloads continue to use their text encoding
rather than the numeric bound.

The default maximum numeric payload is 4096 bytes. That bound is intentionally
larger than all current scalar widths but protects decoders before semantic
range checking. A decoder rejects unknown versions, unknown tags, invalid sign
bytes, over-limit lengths, truncated payloads, and trailing bytes.

The Core decoder accepts only version 8. Versions 2 through 7 are rejected
before body decoding; no older tag is reinterpreted under the current schema.

## CorePrep adaptation

CorePrep is an internal adapter between functional Core and the native codegen
IRs. It is not a user-selectable `--emit` format. CorePrep preserves the full
scalar type and literal payload while making evaluation order, basic blocks,
and branch conditions explicit.

Numeric boolean context is lowered before or during CorePrep construction.
The resulting branch receives a boolean atom rather than asking Xpp or LLVM to
repeat source-language truthiness rules.

CorePrep has its own verifier and wire-v6 codec. Its tags and payload rules
match Core where the models overlap, but the magic and structural records are
separate. This prevents a Core document from being accepted as CorePrep merely
because both carry scalar constants.

## Xpp and Xmm

Xpp receives verified CorePrep. It preserves type identity while adapting the
control-flow model for native passes. Xmm is the final compiler-owned native
IR before LLVM.

Both verifiers repeat the following invariants:

- literal payload and declared type agree;
- arithmetic has matching numeric operand and result types;
- integer-only operations do not accept floating values;
- comparison results are boolean;
- block targets and symbol uses are valid; and
- return atoms match their function result type.

The repetition is intentional. Each pass may later be consumed independently,
and a failed invariant should be reported at the first corrupted boundary.

## LLVM lowering

The backend maps type widths directly. Integer constants are created from the
canonical magnitude with `APInt`; they are not first converted to `uint64_t`.
Negative constants apply two's-complement negation at the requested bit width.
Floating constants are created from preserved spelling with LLVM's arbitrary
precision floating support.

Instruction selection depends on the scalar family:

| Operation | Signed integer | Unsigned integer | Floating point |
| --- | --- | --- | --- |
| division | `sdiv` | `udiv` | `fdiv` |
| remainder | `srem` | `urem` | `frem` |
| less/greater | signed `icmp` | unsigned `icmp` | ordered `fcmp` |
| equality | `icmp` | `icmp` | ordered `fcmp` |
| rounded division | nearest quotient, halves away from zero | nearest quotient, halves upward | `round(fdiv)` then signed `int` conversion |

Rounded division `//` (named `FloorDivide` in the IR for historical
reasons) rounds to the nearest integer with halves away from zero; it does
not floor. Signed and unsigned integer lowering compares the exact remainder against
half the divisor without converting through floating point. Floating rounded
division calls the LLVM round intrinsic on the quotient and converts that
rounded value to the signed 64-bit `int` result.

## Failure ownership

| Failure | Owning layer |
| --- | --- |
| malformed source spelling | Lexer/parser |
| literal outside selected target | TypeChecker |
| invalid Core constant | Core verifier |
| malformed or excessive transport | wire decoder |
| invalid explicit control flow | CorePrep verifier |
| corrupted native operation | Xpp/Xmm verifier |
| unsupported target capability | LLVM backend |

Later layers may defend the same invariant, but diagnostics should identify
the earliest owning layer whenever the normal pipeline is used.

## Test ownership

Haskell scalar codec and verifier cases live beside the Haskell driver tests.
Native cross-stage scalar tests live in `Talac/Driver/Tests`. Core-only
golden documents live in `Talac/Core/Tests`, and LLVM instruction tests live
in `Talac/Backend/LLVM/Tests`.

The suite covers every catalog type, signed and unsigned endpoints, malformed
floating spellings, noncanonical integer magnitudes, numeric payload limits,
Core/CorePrep round trips, Xpp/Xmm retention, and LLVM type/instruction choice.

## Extension checklist

A future scalar addition is incomplete until all of these are updated:

1. source type catalog and target-aware literal selection;
2. Haskell Core and CorePrep models;
3. native public Core type model;
4. Core and CorePrep verifiers;
5. both wire type-tag tables and both literal codecs;
6. Xpp and Xmm verifiers;
7. LLVM type, constant, and operation lowering;
8. cross-language boundary tests; and
9. public implementation documentation.

Adding only a parser spelling or only an LLVM type is not a connected feature.
