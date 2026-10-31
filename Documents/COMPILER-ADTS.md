<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Compiler ADT policy

Tala uses LLVM ADTs where their ownership, allocation, and lookup behavior matches a compiler workload. This is a
targeted implementation policy, not a requirement to replace every C++ standard-library container. Public IR models keep
ordinary owning C++ types so they remain independent of a particular backend library.

## Current use

| ADT | Compiler role |
| --- | --- |
| `llvm::ArrayRef` | Non-owning, read-only statement ranges inside Core verification |
| `llvm::SmallVector` | Short-lived closure capture and lifted-parameter type lists in Xpp and Xmm |
| `llvm::DenseMap` | Storage engine behind the full-range compiler identity map |
| `llvm::BitVector` | Packed dataflow lattice storage behind the bounds-safe `DenseBitSet` contract |
| `llvm::StringRef` | Non-owning diagnostic codes and fixed type-name views |
| `llvm::SmallString` | Stack-first diagnostic assembly buffer |
| `llvm::Twine` | Immediate diagnostic message concatenation before ownership is taken |
| `llvm::APInt` | Exact-width integer lowering in the LLVM backend |

The compiler continues to use `std::vector` for owning IR sequences, artifact models, and values that cross component
boundaries. It uses `std::span` in the callable contract because that contract is a backend-independent C++ API.

## Full-range identity maps

LLVM's default integral `DenseMapInfo` reserves two key values for empty and tombstone buckets. Tala symbol IDs,
virtual registers, block IDs, and wire identities are unsigned domain values. A container must not silently make two
otherwise representable IDs unusable or reinterpret malformed input before a verifier can diagnose it.

`Progmasoft::Tala::ADTs::DenseIdMap<Id, Value>` wraps `llvm::DenseMap` with a tagged internal key. Bucket state is separate
from the identity value, so zero, the maximum value, and the value immediately below the maximum all remain distinct map
keys. Its deliberately small API provides:

- explicit capacity reservation;
- pointer-returning lookup without default construction;
- duplicate-aware emplacement;
- insert-or-assign for verifier environments; and
- callback iteration that exposes only the original identity and mapped value.

`DenseIdSet<Id>` uses the same representation and duplicate semantics. Verifiers use it for parameter, closure-local,
and block catalogs. Tests exercise the complete unsigned boundary that a raw integral `llvm::DenseMap` cannot represent.

## Packed dataflow facts

`Progmasoft::Tala::Analysis::DenseBitSet` remains the project contract used by definite initialization, ownership flow, and
liveness. Its storage is `llvm::BitVector`, but the wrapper intentionally retains behavior LLVM does not promise as the
compiler-facing API:

- out-of-range `Test`, `Set`, and `Reset` are conservative rather than assertion-driven;
- binary operations require exactly equal universes and report mismatches with exceptions;
- set indices are materialized in deterministic ascending order; and
- callers do not depend on LLVM word layout or mutable iterators.

This separation permits LLVM storage improvements without changing analysis semantics or public fact objects.

## Boundary rules

Use an LLVM ADT when all of these conditions hold:

1. The code is native compiler implementation, not a stable language or wire contract.
2. The ADT has a measurable or structural fit: inline storage, dense lookup, packed bits, or non-owning views.
3. Key sentinels, lifetime rules, and invalid-input behavior are compatible or protected by a project adapter.
4. The Bazel target declares the LLVM dependency instead of relying on a transitive include path.
5. Focused component tests cover boundary values and malformed input.

Do not expose `Twine` beyond the immediate call that consumes it; it does not own referenced text. Do not retain an
`ArrayRef` or `StringRef` beyond the lifetime of its source. Do not replace owning IR vectors with views. Do not use a raw
integral `DenseMap` for user-, wire-, symbol-, block-, or register-controlled identities.

## Build and test ownership

The ADT contract lives under `Talac/Headers/Progmasoft/Tala/ADTs/`. Its focused Catch3 binary is
`//Talac/ADTs/Tests:adt_tests`. Dataflow wrapper behavior remains in
`//Talac/Analysis/Tests:definite_initialization_tests`; Core, Xpp, and Xmm verifier suites protect semantic equivalence
after container changes.

LLVM ADTs use LLVMSupport allocation and error hooks and are therefore not purely header-only. Bazel dependencies must use
the configured LLVM component archive rather than importing headers alone. The repository's LLVM discovery keeps that
link portable across Windows ClangCL and the supported macOS hosts.
