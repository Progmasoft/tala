<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# AARC object and ownership ABI

This document describes the first executable Automatic Atomic Reference Counting
(AARC) contract shared by type classification, Xpp, Xmm, LLVM, and the native
runtime. It covers ordinary acyclic lifetime management. The optional concurrent
cycle collector is a later layer, combines Bacon–Rajan processing with trial
deletion, and is disabled by default.

## Storage classification

| Language family | Storage class | Identity and null |
| --- | --- | --- |
| scalar primitives and source `void`/the internal no-result marker | trivial value | no identity; non-null |
| `data`, `type`, classic `enum` | CoW value | value semantics; non-null |
| `class`, `data class`, `enum class`, `object`, interface | AARC reference | identity-bearing; nullable |
| arrays, `String`, callable values | AARC reference | identity-bearing; nullable |

A CoW value may share an internal allocation. That detail does not give it
reference identity and does not turn assignment into aliasing. `StorageClass`
and `NominalKind` in `Tala/Core/Ownership.hpp` form the canonical native
table. A named type without declaration metadata stays `Unresolved`; spelling is
never used to guess its ABI.

Constructed nominal types are classified recursively after template substitution.
A reference declaration remains an AARC reference regardless of its arguments. A
CoW declaration remains a value only when every type argument, at every nesting
depth, is a value; one `String`, callable, or reference nominal argument makes the
complete constructed type an AARC reference. Compile-time value arguments affect
specialization identity but do not affect storage classification. An unresolved
type parameter, missing declaration, or malformed type argument keeps a would-be
CoW result `Unresolved` rather than guessing an ABI.

Argument order cannot change that answer. Classification inspects the complete
argument list before propagating an unresolved sibling, so both `A<T, String>`
and `A<String, T>` are known AARC references. `Unresolved` wins only when no
reference appears anywhere in the constructed type tree.

The Haskell frontend and native Core each have an explicit nominal catalog keyed
by case-sensitive qualified name. Both reject empty and duplicate names and never
overwrite an earlier declaration family. Their classifiers therefore handle
shapes such as `A<B<C>>` without deriving ownership from source spelling.
Serializing the resolved frontend catalog into Core remains a separate connection
step; consumers without it must retain their conservative unresolved boundary.

## Object header and destruction

Every dynamic AARC payload has a runtime-private `ObjectHeader`. A back-pointer
immediately before the aligned payload locates the header from a strong object
pointer. The header contains the ABI version, atomic lifecycle state, atomic
strong and weak counts, immutable metadata, live payload pointer, and allocation
base. Its C++ atomic layout and payload offset are implementation details; the
public C ABI never exposes or allows callers to allocate this header.

The weak count includes one implicit entry while the strong count is non-zero.
The last strong release changes the state from `Alive` to `Destroying`, invokes
the type destructor exactly once, clears the live payload, publishes `Destroyed`,
and drops the implicit weak entry. The last weak or unowned handle then reclaims
the combined allocation. A destructor releases fields owned by its payload but
does not free its own header.

`TypeMetadata` fixes payload size, alignment, ABI version, flags, destructor, and
diagnostic type name. Allocation rejects incompatible metadata and invalid
alignment before creating an object.

## C11 boundary and C++ implementation

`Talac/Headers/Progmasoft/Tala/Runtime/AARC.h` is the language-neutral ABI
contract. It is valid C11, uses `<stdint.h>`, `<stddef.h>`, and `<stdbool.h>`,
wraps declarations in `#ifdef __cplusplus` / `extern "C"`, and declares the
metadata layout and unmangled runtime entry points. C translation units do not
include C++ namespaces, `std::atomic`, templates, or exceptions. Weak and
unowned values use distinct opaque handle types; clients may copy or release
them only through the declared functions.

`AARC.hpp` is the optional C++ convenience surface. It reuses the C metadata
layout and adds the compiler-facing `TypeIdentity`, typed handle wrappers, and
namespaced operations. `Talac/Runtime/AARC/Internal.hpp` alone defines the
atomic object header, while `Runtime.cpp` implements both surfaces in C++20.
Destructor callbacks crossing the C boundary must not throw. Metadata remains
immutable and must outlive the object allocations that refer to it.

The `aarc_c_abi_tests` target compiles an actual `.c` translation unit with
`/std:c11` on Windows or `-std=c11` on macOS, then links it to the C++20 runtime.
It checks ABI version discovery, stable metadata use, strong/weak/unowned
retention and copying, destruction ordering, and UTF-32 string validation. This
keeps C limited to the ABI contract and test caller; there is no C runtime
implementation to maintain.

## Strong, weak, and unowned ABI

Generated code targets unmangled C entry points:

| Entry point | Contract |
| --- | --- |
| `tala_aarc_abi_version` | reports the runtime's metadata and function ABI version |
| `tala_aarc_allocate` | creates a payload with one strong owner and one implicit weak entry |
| `tala_aarc_retain_strong` | returns the same live payload with one added strong owner |
| `tala_aarc_release_strong` | releases an owner and destroys on the last release |
| `tala_aarc_make_weak` | creates a control handle that does not keep the payload alive |
| `tala_aarc_copy_weak` | creates an independent reference to an existing weak handle |
| `tala_aarc_lock_weak` | returns a nullable, newly retained strong result |
| `tala_aarc_release_weak` | releases a weak control handle |
| `tala_aarc_make_unowned` | creates a non-owning handle that keeps only the header alive |
| `tala_aarc_copy_unowned` | creates an independent reference to an existing unowned handle |
| `tala_aarc_load_unowned` | returns a nullable, newly retained strong result |
| `tala_aarc_release_unowned` | releases an unowned control handle |

Weak lock and unowned load use compare/exchange on a non-zero strong count. A
state check followed by a raw pointer load would race the last release, so both
successful operations deliberately upgrade their result to a balanced strong
reference.

## Xpp, Xmm, and LLVM

Xpp and Xmm wire version 7 preserve `RetainStrong`, `ReleaseStrong`, `MakeWeak`,
`LockWeak`, `ReleaseWeak`, `MakeUnowned`, `LoadUnowned`, and `ReleaseUnowned`.
Producing operations preserve the operand's language type. Release operations
have no destination and carry `Unit` as the result marker. Both stage verifiers
reject scalar ownership, wrong arity, producing releases, and discarded loads.

`MakeClosure` creates a payload containing an invoke-thunk pointer followed by
ordered capture slots. LLVM emits a payload type, private metadata, a private
destructor, allocation, capture initialization, and a thunk whose first argument
is the environment. The thunk loads hidden captures and appends public call
arguments before invoking the lifted target. Strong AARC captures are borrowed
for the duration of a call because the closure keeps them alive. Weak and
unowned captures are upgraded to temporary strong references and released after
the lifted call. The generated destructor balances every owning/control slot.

`Memoize` creates an object of the same kind for a callable that remembers
its result. Its payload is an invoke-thunk pointer, a byte that says whether
the result is known, the result, and the computation:

```text
{ ptr invoke, i8 known, T result, ptr computation }
```

The thunk has the signature of a closure without parameters, so the object is
called exactly as a closure is and a caller cannot tell the two apart. It
returns the result when the byte is set; otherwise it calls the computation
through that object's own thunk, stores the result, sets the byte and returns.
The byte is set after the computation returns. The object takes a strong reference of its own to the
computation when it is created, and its destructor releases it. The result
slot holds a `bool` or a number and owns nothing.

String constants keep `i32` Unicode-scalar storage and call
`tala_aarc_string_literal`, which creates a `System.String` AARC object without
introducing UTF-8 storage.

## Current boundary

Retains and releases are placed for every AARC value of a function by the Xpp
ownership placement pass, described in [Ownership flow](OWNERSHIP-FLOW.md).
This slice does not collect cycles. A native executable is linked with the
runtime library; see "Native executables" below.
`Progmasoft::Tala::Runtime::Aarc::LiveAllocations` counts the
allocations whose storage has not been reclaimed; it is a C++ entry point for
tests and is not part of the C ABI. The future concurrent Bacon–Rajan plus
trial-deletion collector remains opt-in with `--cycle-collector=true`. The
ordinary acyclic path must not pay its cost when disabled, and no trial begins
when no candidate exists or the program has already broken the candidate cycle.

## Native executables

On Windows a native executable is linked without a C runtime. What its code
calls of the runtime, it finds in `tala-runtime.lib`, which the compiler links
from the directory of its own executable: the ownership runtime of this
document and the text and console runtime, as one object. On Linux and macOS
the library is `libtala-runtime.a`, and the executable is linked with the C
library of the system as well.

That object is built from the sources a host process links,
`Talac/Runtime/AARC` and `Talac/Runtime/Text`, in one translation unit
with the few things those sources take from a C runtime when there is one:
the non-throwing allocation functions, over the heap of the process, the
memory functions a compiler may call for a loop or an initialization, and the
tag object of the non-throwing forms. It is compiled without stack cookies
and without instrumentation of any kind, in a sanitizer build of the compiler
as well, because the programs it is linked into are not sanitizer builds.

An executable therefore has the whole ownership ABI: strong, weak and unowned
references, strings and type tests, counted with the same atomic operations
as in a host. It imports seven functions of kernel32 and nothing else. The
linker makes the import library for them from a list of names, so that
linking a program needs neither the libraries of a C runtime nor those of a
Windows SDK.

A program that calls nothing of the runtime takes nothing from the library.
When the library is not installed beside the compiler, such a program still
links, and any other fails with a diagnostic that names the library.

The native linker is the Windows one; executables on Linux and macOS are
pending, and with them the same library for those systems.
