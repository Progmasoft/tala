<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Numeric types and literals

Tala defines scalar widths as language properties. They do not depend on
the host compiler, operating system, or CPU word size.

## Scalar catalog

| Source type | Representation | Family |
|---|---:|---|
| `char` | `u32` | character |
| `bool` | `u8` | boolean |
| `byte` | `i8` | signed integer |
| `short` | `i16` | signed integer |
| `long` | `i32` | signed integer |
| `int` | `i64` | signed integer |
| `longint` | `i128` | signed integer |
| `ubyte` | `u8` | unsigned integer |
| `ushort` | `u16` | unsigned integer |
| `ulong` | `u32` | unsigned integer |
| `uint` | `u64` | unsigned integer |
| `ulongint` | `u128` | unsigned integer |
| `sfloat` | `f16` | floating point |
| `lfloat` | `f32` | floating point |
| `float` | `f64` | floating point |
| `double` | `f128` | floating point |

The familiar C-family names intentionally do not imply C-family widths. In
particular, Tala `long` is 32-bit and `int` is 64-bit.

## Integer literals

Decimal, hexadecimal, and binary spellings are accepted. Octal spellings do
not exist. An apostrophe may separate digits only when both adjacent
characters are valid digits for the selected radix.

```tala
26
1'000'000
0xFF'EE
0b1010'1100
```

Malformed spellings are rejected as one token, producing one diagnostic at
the literal rather than misleading follow-up name tokens.

```tala
0o377
0x'FF
0b1010'
1''000
1_000
```

An integer literal without a target has type `int`. The compiler does not
silently widen it when the value exceeds `int`. A declared integer target
selects the literal representation directly when the value fits.

```tala
byte small = 100;
long normal = 2'000'000'000;
longint large = 9'223'372'036'854'775'808;
```

Unary `-` is an operator, not part of the token. Constant evaluation can
therefore admit a signed type's minimum value as a negated magnitude without
weakening lexical rules.

## Floating-point literals

An untargeted floating-point literal has type `float`. A floating target
selects `sfloat`, `lfloat`, `float`, or `double`; suffixes are neither needed
nor supported.

```tala
sfloat compact = 1.5;
lfloat single = 1.5;
float normal = 1.5;
double extended = 1.5;
```

Scientific notation accepts `e` or `E` and an optional exponent sign.
Apostrophes may separate mantissa digits, but never exponent digits.

```tala
1e3
2E-4
1'000.250'000
```

The frontend preserves normalized decimal spelling instead of rounding it
through the host's `Double`. Target APFloat conversion remains owned by the
native lowering boundary.

## Character literals

`char` stores a `u32`. A literal can contain several values; they are packed
left to right, and the packed result must fit in 32 bits.

```tala
char first = 'A';
char pair = 'AB';
char four = 'ABCD';
char escaped = 'A\n';
```

The normative ASCII results are:

```text
'A'    = 0x00000041
'AB'   = 0x00004142
'ABC'  = 0x00414243
'ABCD' = 0x41424344
```

Normal escapes, variable hexadecimal escapes, and four- or eight-digit
Unicode escapes are decoded before packing. Invalid Unicode scalars and
packed values wider than `u32` are compile-time errors.

## Boolean numeric context

Boolean targets and conditions accept numeric values. Zero means `false`;
every nonzero value means `true`.

```tala
bool disabled = 0;
bool enabled = 1;

if (-1) {
    -- The branch is taken.
}
```

The Typed AST retains the numeric expression type. CorePrep makes conversion
explicit as `value != 0`, so a native branch always receives a canonical
boolean atom.

## `void` and the internal no-result marker

`void` is the only source spelling for a function that returns no value.
Tala has no source-language `unit` type and does not admit `unit` in a
declaration, type argument, cast, or callable signature.

The current native Core ABI historically names its private no-result marker
`unit`. The compiler erases source `void` to that marker once, at the Typed AST
to Core boundary. Tools must render it as `void` at a source-facing boundary;
the implementation name is never a second language type.

## Current artifact boundary

Lexer, parser, target-aware type checking, Core verification, constant
integer operations, and CorePrep boolean normalization understand this scalar
model. Core and CorePrep wire v6 transport the complete fixed-width catalog,
structured arbitrary-width integer magnitudes, and preserved floating
spellings. Xpp and Xmm retain those types, and LLVM lowers them without a
host-width conversion. See [Scalar pipeline](SCALAR-PIPELINE.md) for the
connected stage-by-stage contract.

## Diagnostics and constant expressions

Range validation uses unbounded compiler integers before a target
representation is selected. It is therefore independent of the Haskell host
word size and catches both a literal that does not fit and a constant
expression whose folded result does not fit.

```tala
byte valid = 100 + 27;
byte overflow = 100 + 28; -- compile-time error
```

Division, rounded division, and remainder by a constant zero are diagnosed by
the type-checking pipeline. Nonconstant arithmetic remains available for
later Core optimization and native lowering.

Compile-time integer evaluation is exact but bounded to magnitudes below
`2^65536`. This deterministic resource ceiling applies to intermediate
compile-time calculations, including template values; it is not a source
integer width and does not change the built-in scalar ranges above. An
expression that exceeds the ceiling receives a compile-time diagnostic instead
of forcing the compiler to allocate an unbounded integer. Power uses bounded
exponentiation, and shifts check their amount before converting it to a host
index. The Core optimizer separately leaves any operation it cannot safely
fold as an explicit Core primitive.

The exact accepted interval is symmetric and excludes both endpoints:

| Compile-time integer | Accepted? |
|---|---|
| `2^65536 - 1` | Yes |
| `2^65536` | No |
| `1 - 2^65536` | Yes |
| `-2^65536` | No |

For example, the resource boundary is independent of the destination type:
`2 ** 65535` is a bounded compile-time integer value, while `2 ** 65536`
exceeds the evaluator's magnitude ceiling before a narrow destination-range
check is attempted. Conversely, `0 ** 9223372036854775807` remains inexpensive
and exact because the evaluator handles the zero-base identity without
constructing an exponent-sized intermediate. The same identity behavior is
used when fixed-array dimensions are evaluated from template syntax.

This ceiling applies to intermediate results as well as source literals. The
compiler checks multiplication's minimum possible result width before building
an oversized product, then checks the exact value for products near the limit.
Exponentiation reuses that guard at each step instead of first constructing the
final power. The check is shared by ordinary constant diagnostics and generic
template values such as fixed `System.Array` dimensions; their diagnostic codes
remain specific to their respective contexts.

The limit is intentionally not a promise that every in-range compile-time
expression has constant-time cost. It is a deterministic upper bound on integer
magnitude and intermediate allocation, with exponentiation by squaring and
preflight shift/multiply checks preventing work proportional to a huge exponent
or shift distance. It does not alter runtime arithmetic, choose a wider source
type, or authorize an implicit conversion. Fixed-width Core folding still
requires its own operand-width and result-range proof.

The semantic rule engine is separate from diagnostic construction. Analyzer
and other compiler clients can therefore ask the same questions—whether a
type is valid in boolean context, whether two operand types agree, or which
target a literal selects—without duplicating TypeChecker messages.

## Operator typing

Arithmetic does not use a hidden C-style usual-arithmetic-conversions step.
Two computed operands must already have the same scalar type. A target may
select the type of a literal, but it does not silently convert an existing
binding of another width or signedness.

```tala
long left = 1;
long right = 2;
long sum = left + right; // valid

int wide = 2;
int invalid = left + wide; // invalid: long and int differ
```

Arithmetic operators preserve the operand scalar type. Relational and
equality operators produce `bool`. Logical operators accept values valid in
boolean numeric context and also produce `bool`.

Integer bitwise complement (`!`) also preserves the operand type and uses that
type's declared width. For example, `!0` has value `255` when its selected
type is `ubyte`; it does not sign-extend an unbounded host integer into the
unsigned result.

| Operator class | Operand contract | Result |
|---|---|---|
| unary `+` | numeric | operand type |
| unary `-` | signed integer or floating point | operand type |
| logical `not` / `!` | bool or numeric | `bool` |
| `+`, `-`, `*`, `/`, `//`, `%` | matching numeric types | operand type |
| `<`, `<=`, `>`, `>=` | matching numeric types | `bool` |
| `==`, `\=` | matching types | `bool` |
| `&&`, `||` | bool or numeric context | `bool` |

No table entry grants an implicit signed/unsigned, integer/floating, or
narrow/wide conversion. Such conversions require their own language surface
and are not inferred by this implementation.

The Core verifier repeats these invariants after desugaring. This second check
is intentional: Core can be loaded from an artifact or produced by another
frontend, so native lowering must not rely only on the source TypeChecker.

## Determinism

Literal interpretation is deterministic across development hosts:

- radix and separator checks operate on source characters;
- integer range checks use unbounded compiler arithmetic;
- scalar widths come from the Tala catalog;
- floating spelling is preserved until target lowering;
- character packing is defined by value order, not platform endianness;
- source `void` is separated from the native resultless ABI marker.

These rules ensure that a project analyzed on Windows produces the same
frontend decisions as the same project analyzed on another supported host.
