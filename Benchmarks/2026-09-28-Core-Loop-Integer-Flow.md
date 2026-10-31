<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Core loop integer-flow benchmark

## Scope

This first measurement records the optimizer cost after adding loop-carried
integer facts, interval widening, and separate break/continue/return edges. It
is a new workload; there is no prior same-fixture baseline and these numbers do
not claim a speedup.

Each fixture contains the requested number of Core functions. Every function
has a pre-test `while`, a post-test `do/while`, and a `for` loop with a mutable
integer, a conditional transfer, and an update. Fixture construction occurs
before Criterion samples. The timed operation runs the production optimizer,
including Core verification, loop fact summaries, effect inference, constant
propagation, and fixed-point orchestration.

## Environment and command

- Date: 2026-09-28
- OS: Windows NT 10.0.26200.0, x86-64
- CPU: Intel Core i5-3210M @ 2.50 GHz
- GHC: 9.10.3
- Optimization: Cabal `-O2`
- Criterion sample limit: 0.1 seconds per case
- Fixture sizes: 8, 32, 128, 512, and 1024 functions

```powershell
Set-Location Compiler
cabal bench tala-core:core-benches --enable-benchmarks --benchmark-options="--match prefix Core/LoopIntegerFacts --time-limit 0.1"
```

## Measurements

Criterion's estimate and reported range are shown per complete module
optimization. The largest case's lower bound was `NaN`; that estimate is
retained as a warning rather than repaired or presented as a reliable interval.

| Functions (3 loops each) | Estimate | Criterion range | Outlier variance |
| ---: | ---: | ---: | ---: |
| 8 | 3.181 ms | 2.791–3.484 ms | 48% |
| 32 | 13.30 ms | 11.89–15.58 ms | 36% |
| 128 | 160.9 ms | 60.02–251.5 ms | 74% |
| 512 | 254.5 ms | 146.0–321.7 ms | 19% |
| 1024 | 636.5 ms | NaN–981.5 ms | 23% |

## Interpretation and follow-up

The 128-function and 1024-function observations are too noisy for a useful
scaling claim, and the 128-function estimate is especially outlier-sensitive.
The larger module still completed the timed optimizer path, but this is not
evidence that the solver is fast enough for every project. Re-run with repeated
process-level measurements on a controlled host before comparing revisions.
If a same-host follow-up shows disproportionate growth, profile repeated loop
summary construction across constant propagation, effect inference, and
liveness before weakening the analysis or increasing the convergence cap.

CI compiles this Criterion target and performs a smoke run; elapsed time is not
a shared-runner pass/fail threshold.
