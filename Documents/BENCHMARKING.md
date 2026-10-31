<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Benchmarking the compiler

The benchmark suite answers narrowly scoped questions about compiler throughput. It does not time fixture construction,
file-system discovery, terminal output, or process startup. Native fixtures are prepared before Google Benchmark enters
its measured loop; Criterion fixtures are allocated through `env`. Decode benchmarks encode once and repeatedly decode
the stable byte document, while encode benchmarks retain a stable in-memory module.

The Criterion Core group also owns `InlineLinearBody`. Its fixtures contain one
pure two-local helper and a scalable set of callers with non-trivial primitive
arguments. The measured action uses the production verifier, effect solver,
capture-avoiding inliner, and fixed-point driver. It therefore observes fresh
symbol inventory, argument-let construction, local cloning, and report
assembly together. Fixture creation stays in `env`, and the digest consumes the
optimized tree plus report counts.

All scalable fixtures contain valid functions and blocks. Increasing the benchmark argument therefore increases real IR
work rather than padding input with ignored bytes. Each benchmark reports the logical function, block, instruction, or
byte throughput appropriate to its layer. Complexity fitting is enabled for native scalable cases so a result can expose
unexpected non-linear behavior without converting that observation into a correctness failure.

Xpp and Xmm fixtures use a reachable chain of basic blocks with eight definitions per block. Xpp optimization and Xmm
optimization receive a fresh by-value module for each iteration, matching their consuming production APIs. The lowering
case retains a stable Xpp module and measures production Xpp-to-Xmm conversion; artifact decode cases encode once before
the timer starts.

## Interpreting results

Use medians and distributions from repeated runs. A single number can move because of CPU boost, antivirus scanning,
debuggers, power policy, or another process. Treat a possible regression as a reason to profile, then reproduce it with
at least five repetitions on the same host:

```powershell
bazelisk run -c opt //Talac/Core/Benches:core_benches -- `
  --benchmark_repetitions=5 --benchmark_report_aggregates_only=true
```

Criterion performs sampling and regression analysis itself. Its HTML report is useful for local investigation, but the
generated report and Cabal build tree are not source artifacts and must not be committed. Recorded Markdown baselines
summarize the console result together with enough environment data to reproduce it.

Correctness tests remain authoritative. Benchmark helpers should use production public APIs, verify fixture creation
outside the timed loop, and consume results so the optimizer cannot erase measured work. Do not add alternate fast paths
that exist only for the benchmark.

For a quick linear-inlining smoke measurement:

```powershell
cabal bench tala-core:core-benches --enable-benchmarks `
  --benchmark-options="--match pattern Core/InlineLinearBody/8 --time-limit 0.1"
```

Use the complete developer benchmark command before publishing a baseline; the
smoke form verifies the harness and catches gross regressions but its short
sampling window is not suitable for release-to-release comparison.
