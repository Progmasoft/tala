<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Artifact wire contracts

Tala uses bounded binary documents at compiler stage boundaries. They are
compiler artifacts rather than source formats. Core, Xpp, and Xmm are public
`-Emit`/`-Build` choices; CorePrep remains a private adapter contract.

## Contract families

| Contract | Magic | Current version | Producer | Consumer |
| --- | --- | ---: | --- | --- |
| Core | `TACR` | 10 | Haskell frontend | native Core reader |
| CorePrep | `TACP` | 8 | CorePrep adapter | native pipeline tools |
| Xpp | `TAPP` | 7 | verified CorePrep-to-Xpp lowering | Xmm lowering or artifact tools |
| Xmm | `TAMM` | 7 | verified Xpp-to-Xmm lowering | LLVM backend or artifact tools |

The contracts have related scalar encodings but separate structural schemas.
Their magic values must never be treated as aliases.

Core and CorePrep have a Haskell producer. Xpp and Xmm are C++20-owned
contracts on both sides of their codec. This distinction does not weaken the
reader boundary: an artifact loaded from disk is untrusted and is verified
again before the next lowering stage.

## General encoding rules

- Multibyte counts and identifiers are little-endian.
- Integer literal magnitude bytes are big-endian.
- Every variable-size field is checked before allocation.
- The reader must consume the whole input.
- Unknown enum tags are errors, not extension records.
- An unsupported version fails before body decoding.
- A producer emits only its declared current version.

These rules keep decoder behavior deterministic and make corrupt artifacts
fail locally instead of reaching a later compiler pass.

## Decoder limits

A limit is part of the decode API rather than a global mutable setting. The
current contracts bound modules, functions, parameters, statements, blocks,
instructions, operands, text bytes, numeric bytes, and nesting depth where the
model is recursive.

Callers may reduce limits for a constrained context. Increasing a limit does
not relax semantic checks: an integer that passes the byte-count bound must
still fit its declared scalar width.

## Source ownership

Core v6 introduced, and Core v8 retains, the physical project source catalog
and the source owner of each function. CorePrep v6 and Xpp/Xmm v5 also carry
this provenance. The catalog is ordered exactly like the frontend's
deterministic project-relative source set.
source set. A source with no declarations remains in the catalog so project
object and assembly builds still produce an output for that compilation unit.

Every source identity is a non-empty, slash-separated relative path ending in
the exact lowercase `.tala` extension. Empty segments, `.` and `..`, a leading
separator, backslashes, colons, embedded NUL, and non-scalar Unicode values are
rejected. Verifiers do not normalize malformed input: accepting an alias would
let two different wire documents refer to the same source file.

Each function owner must name one exact entry in the module catalog. Core,
CorePrep, Xpp, and Xmm independently check this relationship because each
representation can be decoded or embedded without having passed through its
producer. Single-file and legacy in-memory clients may omit the catalog and
function owner; the project output planner requires a complete catalog and
rejects an incomplete project artifact before lowering or writing files.

The metadata is diagnostic and build provenance, not part of `SymbolId` or
function identity. Reordering or renaming a file changes its owner metadata but
does not change semantic symbol identity. Closure lifting preserves the
enclosing declaration's owner, and a compiler-generated helper inherits the
source that caused its emission.

## Scalar type tags

Wire v5 introduced explicit tags for unit/no-result, boolean, string, function,
named, variable, character, every signed and unsigned integer width, and every
floating width. Wire v6 added source ownership, and Core v8 retains both that
metadata and the scalar catalog while adding loop statement tags.
A decoder reconstructs the exact type; it does not infer width from the literal
byte count.

That separation is required because the same magnitude can inhabit several
types and because signedness affects native instruction selection even when
the bit pattern is identical.

### Core scalar tags (introduced in v5)

The native and Haskell Core codecs retain these assignments in version 10. This
table is an implementation-maintenance aid, not a user extension API.

| Tag | Type | Tag | Type |
| ---: | --- | ---: | --- |
| 0 | no-result/unit marker | 11 | `longint` |
| 1 | `bool` | 12 | `ubyte` |
| 2 | compatibility `int` slot | 13 | `ushort` |
| 3 | `String` | 14 | `ulong` |
| 4 | named type | 15 | `uint` |
| 5 | function type | 16 | `ulongint` |
| 6 | type variable | 17 | `sfloat` |
| 7 | `char` | 18 | `lfloat` |
| 8 | `byte` | 19 | `float` |
| 9 | `short` | 20 | `double` |
| 10 | `long` | | |

The compatibility entry retains an in-memory historical slot. It does not
create another source spelling, and new numeric values still carry their exact
declared scalar type.

### CorePrep scalar tags (introduced in v5)

CorePrep retains historical `int` and `long` positions before the extended
catalog. Versions 6 and 7 change none of these tags; assignments
must therefore not be copied blindly from Core:

| Tag | Type | Tag | Type |
| ---: | --- | ---: | --- |
| 0 | no-result/unit marker | 11 | `ushort` |
| 1 | `bool` | 12 | `ulong` |
| 2 | `int` | 13 | `uint` |
| 3 | `long` | 14 | `ulongint` |
| 4 | `String` | 15 | `sfloat` |
| 5 | function type | 16 | `lfloat` |
| 6 | named type | 17 | `float` |
| 7 | type variable | 18 | `double` |
| 8 | `char` | 19 | `byte` |
| 9 | `longint` | 20 | `short` |
| 10 | `ubyte` | | |

The distinct table is one reason magic and version are verified before any
type record is decoded.

## Ordered template arguments

Core and CorePrep encode named-type arguments as typed values rather than
treating every argument as another type. Their current format retains that
ordered sum; Core v8 and CorePrep v6 also carry source provenance. Each argument
starts with a kind tag and is decoded in source order:

| Tag | Argument payload |
| ---: | --- |
| 0 | recursive type argument |
| 1 | arbitrary-precision integer value |
| 2 | Boolean value |
| 3 | Unicode scalar character value |
| 4 | resolved compile-time value parameter |

The order is semantic. `Matrix<int, 4>` and `Matrix<4, int>` cannot share an
artifact identity, even if a malformed declaration would later reject both.
Readers therefore build one ordered sum rather than parallel type and value
vectors.

Integer and character values use the same canonical sign/magnitude payload
rules as integer literals. A character receives an additional Unicode-scalar
check. Boolean values use exactly one zero-or-one byte. Parameter values carry
both positive `SymbolId` and diagnostic spelling; spelling alone is never the
identity.

Named types recursively consume the configured type-depth budget only for type
arguments. A value argument is a leaf. Its integer magnitude still consumes
the numeric-byte budget, and its parameter spelling consumes the text-scalar
budget.

The Xpp and Xmm shared type encoder uses the same semantic model with its own
stage-local record layout. Version 5 adds source provenance while retaining
the ordered template-argument representation. The formats are not byte
aliases: only their validation rules and in-memory type model are shared.

### Array encodings

The three array forms remain structurally distinct:

| Source family | Named identity | Arguments |
| --- | --- | --- |
| `[]T` | built-in `[]` marker | `type(T)` |
| `[T]` | `System.Array` | `type(T)` |
| `[T; N]` | `System.Array` | `type(T), value(integer N)` |

Fixed and dynamic `System.Array` are overloads of one public family. The wire
does not invent a `FixedArray` class name. The built-in `[]T` representation is
not rewritten to `System.Array`, because the language specification gives it a
different role.

## Core loop statement tags

Core wire v7 kept the existing statement tags 0 through 4 and appended
explicit loop-control records; v8 retains them unchanged. The tag is followed by each field in the order
shown; nested statement lists use the ordinary bounded statement-vector
encoding.

| Tag | Statement | Payload order |
| ---: | --- | --- |
| 5 | `CoreWhile` | condition, body |
| 6 | `CoreDoWhile` | body, condition |
| 7 | `CoreFor` | condition, body, update |
| 8 | `CoreBreak` | none |
| 9 | `CoreContinue` | none |

These records preserve source control flow until CorePrep creates explicit
blocks and edges. `break` and `continue` carry no value or target identifier:
the enclosing loop nesting determines their target, and both the Haskell and
native Core verifiers reject a control statement without an active loop.
The `for` update list is separate from the body so `continue` reaches updates
before the condition is evaluated again. A `do/while` condition follows the
body because it is evaluated after every entered body, including on the first
iteration.

## Core expression tags

Every Core expression starts with one tag byte. A primitive is followed by its
primitive tag; then every expression writes its result type, and the remaining
payload follows in the order shown.

| Tag | Expression | Payload order after the result type |
| ---: | --- | --- |
| 0 | `CoreVariable` | symbol |
| 1 | `CoreLiteral` | literal payload |
| 2 | `CoreApply` | callee, argument vector |
| 3 | `CorePrimitive` | operand vector |
| 4 | `CoreClosure` | capture vector, parameter vector, return type, body |
| 5 | `CoreLet` | symbol, binding type, value, body |
| 6 | `CoreConditional` | test, first arm, second arm |

Core wire v8 added tag 6. Its three children have fixed positions, so the
record carries no count: a shorter payload is a truncation, never a smaller
conditional. Each child counts one level against the expression depth limit.
Among the operands of a primitive only those after the first do: the first
operand is at the level of the primitive, so a chain of operators, which
nests in that operand as deep as it is long, is one level, and the readers
and the writers walk it in a loop. The reader does not check that the arms
agree with the result type; that is the Core verifier's rule and runs on every
decoded module.

The native reader and writer also bound the nesting of statement bodies, with
the same default of 4096 levels. A function body is level 1, and a branch, a
loop body and a closure body are each one level below the statement or
expression that holds them. A false branch that holds exactly one conditional
statement is an `else if`: the reader and the writer walk such a chain in a
loop, and its links share one level. An empty body costs no level. Input that
nests deeper is rejected with a limit error before it is walked. The limit is
a property of the reader, not of the format: it changes no byte of a valid
document, and the Haskell codec, whose stack grows on demand, does not need
it.

CorePrep, Xpp, and Xmm have no conditional-expression record. The expression
is lowered to blocks, a branch, and assignments to one slot before CorePrep is
serialized, so their versions did not change.

### The remembering operation

Core v9, CorePrep v7, Xpp v6 and Xmm v6 add one operation: a callable that
remembers its result, `Memoize`. It is not a new record. It is one more value
of the operation field every stage already writes, with one operand and a
result, and it takes the next free tag of each catalog:

| Contract | Field | Tag |
| --- | --- | ---: |
| Core | primitive | 24 |
| CorePrep | operation | 27 |
| Xpp | opcode | next after the type test |
| Xmm | opcode | next after the type test |

A reader of an earlier version does not know the tag, which is why all four
versions changed together: a document that holds the operation must not be
read as one that cannot. The readers check only that the tag is known. That
the operand is a callable without parameters whose result is `bool` or
numeric, and that the result has the operand's type, is the rule of each
stage's verifier, which runs on every decoded module.

### The runtime call

Core v10, CorePrep v8, Xpp v7 and Xmm v7 add one more operation: a call of a
function of the runtime. Like the remembering operation it is a value of the
operation field every stage already writes, and it takes the next free tag:

| Contract | Field | Tag |
| --- | --- | ---: |
| Core | primitive | 25 |
| CorePrep | operation | 28 |
| Xpp | opcode | next after the remembering operation |
| Xmm | opcode | next after the remembering operation |

The operation has no field of its own. Its first operand is an integer
literal of type `int`, the identity of the function; the operands after it
are the arguments. The identities are those of the runtime catalog:

| Identity | Function | Arguments | Result |
| ---: | --- | --- | --- |
| 1 | join two strings | `String`, `String` | `String` |
| 2 | a signed integer as text | signed integer | `String` |
| 3 | an unsigned integer as text | unsigned integer | `String` |
| 4 | a Boolean as text | `bool` | `String` |
| 5 | a character as text | `char` | `String` |
| 6 | `%d` and `%x` of a signed integer | flags, width, precision, signed integer | `String` |
| 7 | `%u` and `%x` of an unsigned integer | flags, width, precision, unsigned integer | `String` |
| 8 | `%f` | flags, width, precision, floating-point number | `String` |
| 9 | `%s` | flags, width, precision, `String` | `String` |
| 10 | `%c` | flags, width, precision, `char` | `String` |
| 11 | the line terminator of the platform | none | `String` |
| 12 | write to the console | `String`, target | none |
| 13 | whether two strings are equal | `String`, `String` | `bool` |

Flags, a width, a precision and a target are of type `int`. A signed or an
unsigned integer argument is of any width up to 64 bits, and a floating-point
argument of any up to 64. An identity is never reused or renumbered: a new
function takes the next number, and the document versions change with it,
because an older reader does not know the function.

The readers check that the tag is known and decode the operands as they
decode any others. That the first operand names a function, and that the
arguments and the result are the ones that function has, is the rule of each
stage's verifier.

### Version transition

Versions are strict, not feature-negotiated. Core readers accept only version
10, CorePrep readers accept only version 8, and Xpp/Xmm readers accept only
version 7. Every older or future version fails at the version field before
body decoding. The compiler does not
guess whether a document happens to contain only fields from an older schema.
Recompile the owning source or regenerate the intermediate artifact with the
current compiler.

Golden fixtures cover the header transition, while mixed type/value round-trip
tests cover payload ordering, negative arbitrary-precision integers, Boolean
values, Unicode characters, and unresolved value-parameter identities.

## Integer payloads

The payload is sign plus normalized unsigned magnitude. Canonical rules are:

- zero has no magnitude bytes;
- zero is never negative;
- a nonzero magnitude does not start with `00`;
- sign is encoded only as `00` or `01`; and
- magnitude order is most significant byte first.

Examples:

| Value | Sign | Magnitude |
| ---: | --- | --- |
| `0` | `00` | empty |
| `1` | `00` | `01` |
| `-1` | `01` | `01` |
| `255` | `00` | `ff` |
| `256` | `00` | `01 00` |

The payload itself is unbounded in meaning and bounded in transport. The type
verifier decides whether it fits `byte`, `int`, `longint`, or another target.

### Integer rejection order

Readers reject structural defects before applying the declared type range:

1. a sign byte other than zero or one;
2. a byte count above the caller's numeric limit;
3. insufficient bytes for the declared count;
4. negative zero or a leading-zero magnitude;
5. a payload alternative that does not match the scalar family; and
6. a mathematical value outside the declared width.

This ordering keeps hostile length fields from allocating memory and keeps
semantic diagnostics separate from transport corruption.

## Floating payloads

Floating values are transported as ASCII spelling. The format permits decimal
finite values and explicit lowercase `nan`/`inf` forms. The decoder validates
ASCII and grammar before constructing the IR literal.

Preserving spelling avoids host floating conversion and retains enough input
for LLVM to round directly to half, float, double, or fp128.

The transport grammar is deliberately smaller than a future source grammar
might be. Source separators are normalized away before Core, and target suffix
policy is already resolved by TypeChecker. The wire carries a semantic number
spelling rather than the original token text.

## Text payloads

Names and string literals are distinct fields with their own size accounting.
String decoding must reject invalid encoded text rather than replacing it.
Symbol identity never depends only on spelling: resolved symbol identifiers
remain part of the structural records.

## Core document order

A Core document contains:

1. magic and version;
2. qualified module name;
3. ordered project-relative source catalog;
4. function count;
5. each resolved function symbol and its source owner;
6. parameters and their types;
7. return type; and
8. ordered Core statements and expressions.

Expression records include their result type. The verifier checks that the
recorded type agrees with constants, variables, applications, and primitives.

## CorePrep document order

A CorePrep document contains:

1. magic and version;
2. qualified module name;
3. function count;
4. resolved function metadata;
5. explicit entry block identifier;
6. blocks, instructions, and operands; and
7. one terminator per block.

CorePrep serializes the adapter model after evaluation order and control flow
are explicit. It retains the ordered source catalog and a source owner on each
function, including lifted closure functions. It must not be exposed as a
stable package or CLI artifact.

## Xpp and Xmm common scalar records

Xpp and Xmm share a C++20 artifact support layer for types, literals, Unicode
text, qualified names, and resolved symbols. They do not share instruction or
control-flow records. Reusing only scalar records prevents a generic object
serializer from erasing which stage owns an invariant.

The v2 Xpp/Xmm type tag catalog follows the native Core type model exactly:

| Tag | Type | Tag | Type |
| ---: | --- | ---: | --- |
| 0 | no-result/unit marker | 11 | `uint` |
| 1 | `bool` | 12 | `ulongint` |
| 2 | `char` | 13 | `sfloat` |
| 3 | `byte` | 14 | `lfloat` |
| 4 | `short` | 15 | `float` |
| 5 | `int` | 16 | `double` |
| 6 | `long` | 17 | `String` |
| 7 | `longint` | 18 | function type |
| 8 | `ubyte` | 19 | named type |
| 9 | `ushort` | 20 | type variable |
| 10 | `ulong` | | |

Literal tags are independent of the type tag:

| Tag | Payload |
| ---: | --- |
| 0 | unit/no-result |
| 1 | boolean byte |
| 2 | canonical sign plus integer magnitude |
| 3 | validated ASCII floating spelling |
| 4 | Unicode-scalar string |

The reader validates the literal against its separately encoded type before
returning a stage model. Legacy host-width integer alternatives accepted by
the in-memory model are normalized to the canonical arbitrary-width payload
when written; decoding never recreates a host-width alternative.

## Xpp document order

An Xpp v7 document contains:

1. `TAPP`, version, and zero reserved flags;
2. qualified module name;
3. ordered source catalog;
4. ordered resolved functions with their source owner;
5. parameter symbols/types, return type, and entry block;
6. ordered blocks and instructions;
7. instruction effect, opcode, destination, result type, and operands;
8. closure function identity and capture modes; and
9. one typed terminator with explicit CFG targets per block.

The instruction effect preserves definition, store, and discard as distinct
operations. A destination of zero is therefore meaningful only for discard.
The codec does not derive effect from the opcode or fabricate storage.

Xpp function operands carry stable symbol identity plus their callable type.
They are not serialized as storage reads. Closure targets similarly occupy a
dedicated symbol field rather than an untyped extra operand.

## Xmm document order

An Xmm v7 document contains:

1. `TAMM`, version, and zero reserved flags;
2. qualified module name;
3. ordered source catalog;
4. ordered functions, resolved function identity, and source owner;
5. parameter virtual registers and a parallel ordered type vector;
6. return type and entry block;
7. blocks and instructions;
8. opcode, destination register, result type, explicit has-result bit, values,
   closure function, and capture modes; and
9. a typed terminator with CFG targets.

Xmm values have three disjoint tags: data register, immediate, and function.
This prevents a direct function call from consuming a virtual register or an
immediate from being interpreted as register zero. Parameter register/type
vectors remain separate because the ABI cannot be reconstructed from first
instruction use.

## Public conversion routes

The CLI connects the public stage artifacts without exposing CorePrep:

```powershell
talac build -File Main.tala -Emit xpp
talac build -Build xpp -File Main.xpp -Emit xmm
talac check -Build xmm -File Main.xmm
talac build -Build xmm -File Main.xmm -Emit llvmll
```

An artifact can move forward or be rewritten at its current stage. It cannot
be raised back to an earlier representation: Xmm cannot emit Xpp or Core, and
Xpp cannot emit Core. `check` writes nothing and continues through the next
connected verification/lowering boundary. `build` replaces the selected
output only after the input has decoded and verified successfully.

Stage optimization flags apply at the owning boundary. A loaded Xpp/Xmm
document is verified before optimization, optimized only when enabled, and
verified again before serialization or forward lowering.

## Compatibility policy

The version field describes the entire schema. Core v6 and CorePrep v6 added
project source catalogs and per-function ownership; Core v7 additionally added
structured `while`, `do/while`, classic `for`, `break`, and `continue` records,
Core v8 adds the conditional expression record, and Core v9 with CorePrep v7
adds the remembering operation.
Xpp/Xmm began independently at
version 1; version 5 retains the explicit ownership operations,
template values, and type-test operation, and adds source catalogs and function
owners, version 6 adds the remembering operation, and their current
version 7, with Core v10 and CorePrep v8, adds the runtime call.
The intermediate versions remain strict historical contracts; their
documents are not guessed or accepted by the current readers. Every current
reader rejects earlier and future versions for its own magic.

If migration is needed later, it should be implemented as an explicit reader
for the old version followed by model conversion. The current decoder must not
guess which schema produced an ambiguous tag.

Golden documents are named with their version and live beside the component
that owns the contract test. Changing the current version requires changing
both implementations and golden expectations in the same commit.

## Error behavior

Decode errors carry a stable category and a byte offset. Useful categories
distinguish at least:

- invalid magic;
- unsupported version;
- unexpected end of input;
- unknown tag;
- invalid scalar literal;
- invalid text;
- configured limit exceeded; and
- trailing bytes.

The decoder does not print. The CLI or embedding caller owns presentation and
exit behavior.

## Security properties

Artifacts are untrusted input even when generated by a local frontend. A
decoder must validate lengths before reserving memory, avoid recursive work
beyond its configured depth, detect count multiplication overflow, and never
use unchecked partial list operations.

Semantic verification runs after structural decode and before lowering. A
successfully decoded module is not automatically a valid module.

## Deterministic production

Writers preserve declaration and instruction order established by the owning
IR. They do not serialize pointer values, hash-map iteration order, host-sized
integers, native endianness, or locale-dependent number formatting.

Equivalent verified input therefore produces equivalent bytes on supported
development hosts.

## Test matrix

Every contract revision should cover:

- a minimal golden document;
- round trips for every type tag;
- minimum and maximum integer values for every width;
- negative values and zero canonicalization;
- representative finite and special floating spellings;
- non-ASCII text where permitted;
- each truncated field boundary;
- every unknown tag family;
- old and future version rejection;
- each configurable limit; and
- trailing-byte rejection.

Cross-language tests are essential for Core/CorePrep. Xpp/Xmm instead require
stage-crossing tests: lowered output, codec round trip, verifier, and the next
lowering owner must all agree. A codec-only equality test can preserve a model
bug just as easily as a single-language Core round trip.

When one side changes a tag, a golden-byte test should fail before a large
module reaches LLVM. When one side changes only a verifier rule, the same bytes
may decode, but semantic verification must reject the module consistently.

## Change checklist

Before changing a wire contract:

1. identify the owning IR change;
2. decide whether the change requires a version increment;
3. update Haskell and C++ tag tables together;
4. update writer and reader limits;
5. update structural and semantic verifiers;
6. add cross-language boundary cases;
7. replace versioned golden documents;
8. update the public implementation documents; and
9. remove generated artifacts after local verification.

The wire format follows the compiler model. It must not become a second,
independent language specification.
