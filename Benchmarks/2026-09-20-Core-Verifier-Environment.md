<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Core verifier environment lookup — 2026-09-20

This result records a same-host investigation of native Core verification. It is a development baseline, not a portable
performance guarantee.

## Environment

- source: working tree based on `a73b03a` (Tala 0.3.8)
- host: Windows x86-64, Intel Core i5-3210M at 2.50 GHz, 4 logical CPUs
- compiler: ClangCL 22.1.8, C++20
- build: Bazel `-c opt`
- harness: Google Benchmark, five repetitions, aggregate-only report, 0.05-second minimum per case

## Finding

Each `FunctionVerifier` copied the complete module function environment before checking one function. A module containing
N small functions therefore copied an N-entry hash table N times. The focused baseline classified `CoreVerify` as
quadratic (`1784 N^2`) and reached approximately 471.5 ms at 512 functions.

The verifier now retains one const reference to the global function catalog and keeps only local parameters and bindings
in its mutable environment. Lookup is local-first and then global, preserving duplicate-symbol, assignment, type, and
spelling diagnostics without copying the catalog.

## Repeated result

| Functions | Before mean | After mean | Improvement |
| ---: | ---: | ---: | ---: |
| 8 | 147 µs | 59.0 µs | 2.5x |
| 16 | 420 µs | 128 µs | 3.3x |
| 64 | 5.68 ms | 388 µs | 14.6x |
| 256 | 101.9 ms | 1.62 ms | 62.9x |
| 512 | 471.5 ms | 3.75 ms | 125.7x |

Google Benchmark now classifies the series as linear (`7114 N`, 12% RMS). A subsequent complete benchmark run measured
5.09 ms for the non-repeated 512-function case while concurrently exercising all other native benchmark programs; the
focused repeated result above is the comparison baseline.

## Validation

The optimization is guarded by the native Core suite and the complete Haskell compiler suite. The same test pass also
added direct pattern coverage across parsing, type checking, Core/CorePrep wire round trips, Xpp/Xmm type-test verification,
LLVM lowering, and the AARC exact-type runtime ABI.
