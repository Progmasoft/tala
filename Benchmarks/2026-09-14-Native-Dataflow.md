<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Native dataflow follow-up — 2026-09-14

This follow-up measures the verifier and encoder paths after moving definite
initialization, ownership flow, and liveness to the shared directional worklist.
Definite initialization uses one dense bit set; ownership uses five packed state
bit sets. Production verifiers suppress per-block fact materialization after
retaining the same diagnostics and fixed point.

The parent revision is `08035af136916dec1f66bd35f95948beec043bdf`. The host,
toolchain, fixtures, and limitations match the first Windows x86-64 baseline.
Google Benchmark used an optimized Bazel build and a minimum time of 0.05 seconds.

## Xpp

| Operation | 4 blocks | 16 blocks | 64 blocks | 256 blocks | Fit |
|---|---:|---:|---:|---:|---:|
| Verify | 104 µs | 379 µs | 1.70 ms | 7.18 ms | `N` |
| Encode | 105 µs | 325 µs | 1.44 ms | 6.61 ms | `N log N` |

The original 256-block baseline was 1.18 seconds for verification and 1.19
seconds for encoding. The new observations are approximately 164× and 180×
lower, respectively.

## Xmm

| Operation | 4 blocks | 16 blocks | 64 blocks | 256 blocks | Fit |
|---|---:|---:|---:|---:|---:|
| Verify | 84.8 µs | 334 µs | 1.53 ms | 7.36 ms | `N log N` |
| Encode | 103 µs | 336 µs | 1.46 ms | 7.07 ms | `N` |

The original 256-block baseline was 1.20 seconds for verification and 1.20
seconds for encoding. The new observations are approximately 163× and 170×
lower, respectively.

## Interpretation

The fixed-point scheduler is no longer a whole-graph rescan. Reverse postorder
and duplicate-free notifications evaluate an acyclic chain once per reachable
block. Dense word operations remove per-identity hash-table joins. Finally,
validation-only mode avoids constructing an expanding fact vector at every
block when the verifier needs only diagnostics.

These numbers are reconnaissance results, not CI timing thresholds. Correctness
is guarded separately by semantic fact tests, validation-only equivalence tests,
1,024-block worklist bounds, sparse 64-bit identity cases, word-boundary cases,
and the complete Xpp/Xmm verifier suites.
