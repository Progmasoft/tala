<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Loop and CorePrep measurements

These are local observations from one Windows development machine, not a compiler ranking or a CI threshold. The native
loop comparison measures a narrow integer sum, not Tala code generation. `baseline` is a serial accumulation;
`unrolled` processes four adjacent values through independent accumulators; `formula` checks the result with the
arithmetic-series identity and is deliberately excluded from the loop timing comparison. All measured runs returned the
same checksum, `20,000,000,100,000,000`, for `200,000,000` iterations.

## Host and method

- OS runtime: Windows NT 10.0.26200.0.
- CPU: Intel Core i5-3210M @ 2.50 GHz; Google Benchmark reported four logical CPUs.
- Active power scheme: a user-defined plan (`Özel Planım 1`); its frequency and sleep policy were not independently
  characterized.
- Clang++ 22.1.8, flags `-std=c++20 -O3 -DNDEBUG`.
- GHC 9.10.3, flags `-O2 -Wall`.
- rustc 1.99.0-nightly (2026-07-09), flags `--edition=2024 -C opt-level=3 -C debuginfo=0`.
- GNU Fortran 16.1.0, flags `-std=f2023 -O3 -DNDEBUG`.
- Each executable was warmed once for each algorithm. Five measured runs followed, with baseline and unrolled order
  alternated. A PowerShell stopwatch surrounds process launch, execution, and captured output; process-start overhead is
  therefore included equally and these values are not instruction-level timings. The reported value is the median of the
  five runs, with all raw observations retained below.

## Comparative integer loop

| Compiler | Baseline median | Unrolled median | Median change | Baseline runs (ms) | Unrolled runs (ms) |
| --- | ---: | ---: | ---: | --- | --- |
| Clang++ 22.1.8 | 15.889 ms | 15.850 ms | 0.25% faster | 18.516, 16.056, 15.653, 15.792, 15.889 | 16.068, 15.916, 15.850, 15.682, 15.832 |
| GHC 9.10.3 | 197.469 ms | 123.707 ms | 37.35% faster | 197.469, 191.183, 196.437, 203.998, 222.590 | 124.133, 122.266, 121.591, 127.014, 123.707 |
| rustc 1.99.0-nightly | 189.583 ms | 64.945 ms | 65.74% faster | 198.234, 192.351, 188.901, 189.583, 186.380 | 66.767, 64.383, 64.945, 64.223, 67.445 |
| GNU Fortran 16.1.0 | 158.582 ms | 96.526 ms | 39.13% faster | 159.406, 157.752, 156.028, 158.582, 162.582 | 96.526, 93.898, 100.175, 94.036, 108.282 |

The unrolled source is a meaningful win for the three toolchains whose baseline stayed on a more serial accumulation
path. Clang++'s baseline is already essentially tied with the manually unrolled variant on this host; treating the
0.25% difference as a useful win would overstate the measurement. The sensible default is therefore still the clearer
baseline loop unless a representative workload and repeated measurements show otherwise. `formula` was checked at
small boundary values and the largest accepted count, but was not timed as if it were the same algorithm.

The correctness checks covered counts 1, 2, 3, 4, 5, 10, 11, 99, and 100 for both loop forms; this exercises short
tails and divisibility boundaries. The overflow-safe formula also matched `9,223,372,034,707,292,160` at the maximum
accepted count, `4,294,967,295`. Long-running loop forms were intentionally not run at that maximum.

## Compiler-owned CorePrep workload

The native Google Benchmark `CorePrepareLoops/512` was run in optimized mode for five one-second repetitions. Its median
was `29.774 ms` wall time (`28.952 ms` CPU time), with a 3.02% wall-time coefficient of variation. Criterion's matching
Haskell workload, `CorePrep/PrepareLoops/512`, reported a median estimate of `50.92 ms`, but the interval was wide
(`22.13–83.08 ms`), standard deviation was `25.70 ms`, and outliers accounted for 84% of variance. The Haskell reading
is consequently recorded as noisy and should not be used for a cross-language performance claim. The benchmark source
and sizes are colocated with each implementation; their representations and harnesses are not identical enough to
interpret this as a language-speed comparison.

The native loop workload is a future same-host baseline for CorePrep changes; do not infer a regression from a single
machine's elapsed time. The shell-level cross-language measurements are exploratory. Re-run them with a controlled host,
repeat count, and the exact commands in `Comparative/README.md` before using them to justify a product decision.
