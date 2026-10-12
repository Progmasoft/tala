<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Native liveness optimization follow-up — 2026-09-13

This follow-up uses the same Windows x86-64 host and optimized Google Benchmark
configuration as `2026-09-13-Windows-x86_64.md`. It measures the Xpp and Xmm
optimizer after shared backward liveness, stage-owned dead materialization
elimination, direct reachability cleanup, and memoized trampoline resolution.
The measured source tree was based on parent commit
`2910294ce85d4214eda8a681f90debf3c4ac428e`; the liveness implementation and
this result are one change.

Commands:

```text
bazelisk run -c opt //Talac/Codegen/Xpp/Benches:xpp_benches -- --benchmark_filter=Optimize --benchmark_min_time=0.05s
bazelisk run -c opt //Talac/Codegen/Xmm/Benches:xmm_benches -- --benchmark_filter=Optimize --benchmark_min_time=0.05s
```

## Xpp optimizer

| Blocks | Wall time | CPU time |
| ---: | ---: | ---: |
| 4 | 197 us | 209 us |
| 16 | 390 us | 387 us |
| 64 | 1.36 ms | 1.39 ms |
| 256 | 4.68 ms | 5.21 ms |

Google Benchmark fitted the result as `N` with 7% wall-time RMS. The original
256-block baseline was 61.8 ms and fitted `N^2`; the new wall time is about
13.2 times lower on this host.

## Xmm optimizer

| Blocks | Wall time | CPU time |
| ---: | ---: | ---: |
| 4 | 129 us | 117 us |
| 16 | 379 us | 419 us |
| 64 | 1.46 ms | 1.39 ms |
| 256 | 5.12 ms | 6.25 ms |

Google Benchmark fitted the result as `N` with 5% wall-time RMS. The original
256-block baseline was 63.1 ms and fitted `N^2`; the new wall time is about
12.3 times lower on this host.

## Interpretation

The fixture contains eight dead materializations per reachable block. The new
analysis removes the complete chain in one result. Once those instructions are
gone, memoized trampoline resolution shortens the exposed jump chain without
re-running dominance for a reachability-only transformation.

This is a behavioral benchmark, not a CI threshold. Host load, frequency
scaling, and allocator behavior can change absolute time. The durable result is
the measured complexity change and the optimizer regression suite that checks
the transformed model.
