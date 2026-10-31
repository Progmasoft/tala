<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Dense native liveness follow-up — 2026-09-14

This follow-up measures Xpp and Xmm optimization after the shared liveness
analysis moved from copied `unordered_set<uint64_t>` facts to a sorted sparse-ID
catalog backed by dense machine-word sets. Production optimizers request only
reachability and per-instruction retention decisions; complete block and
instruction live sets remain available to analysis clients and tests.

The comparison baseline is `2026-09-13-Native-Liveness.md`. Both measurements
used the same Windows x86-64 host, optimized Bazel configuration, fixture, and
four-point block-size series. The new values below are the mean of three runs.

Commands:

```text
bazelisk run -c opt //Talac/Codegen/Xpp/Benches:xpp_benches -- --benchmark_filter=Optimize --benchmark_min_time=0.05s --benchmark_repetitions=3 --benchmark_report_aggregates_only=true
bazelisk run -c opt //Talac/Codegen/Xmm/Benches:xmm_benches -- --benchmark_filter=Optimize --benchmark_min_time=0.05s --benchmark_repetitions=3 --benchmark_report_aggregates_only=true
```

| Stage | 4 blocks | 16 blocks | 64 blocks | 256 blocks | 2026-09-13 at 256 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Xpp optimize | 0.101 ms | 0.302 ms | 1.234 ms | 4.832 ms | 4.68 ms |
| Xmm optimize | 0.103 ms | 0.287 ms | 1.234 ms | 4.119 ms | 5.12 ms |

Xpp remains within ordinary host variance of the earlier result rather than
claiming an improvement. Xmm is about 19.6% faster at 256 blocks. Google
Benchmark continues to fit both series as `N`; the Xpp wall-time RMS was 3%
and the Xmm series retained a linear fit despite noisier small samples.

The primary gain is bounded representation: sparse 64-bit stage identities no
longer create one hash node per live fact at every block boundary. Tests cover
maximum-width identities, repeated reads, and several 64-bit word boundaries.
Skipping expanded live vectors is an explicit consumer choice and does not
alter reachability, retained-instruction decisions, or the default public fact
view.
