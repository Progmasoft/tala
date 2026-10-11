<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Compiler benchmarks

Visual X# keeps microbenchmarks next to the implementation they measure and keeps recorded results in this directory.
The first benchmark surface covers the target-independent Core-through-Xmm pipeline, including the boundary shared by
the Haskell frontend and C++20 native pipeline:

- `Compiler/Core/Benches` measures native Core verification, VXCR encoding, VXCR decoding, and CorePrep preparation;
- `Compiler/Core/CorePrep/Benches` measures native CorePrep verification and VXCP encoding/decoding;
- `Compiler/Codegen/Xpp/Benches` measures Xpp verification, optimization, and artifact encoding/decoding;
- `Compiler/Codegen/Xmm/Benches` measures Xpp-to-Xmm lowering plus Xmm verification, optimization, and artifact codecs;
- `Compiler/Haskell/Core/Benches` measures the equivalent Haskell Core and CorePrep operations with Criterion.
- `Interactive/Benches` measures one production CorePrep-to-Xmm-to-LLVM lowering, ORC module-add/invoke, and resource-reset cycle.
- `Compiler/Driver/Benches` measures project source-output planning and staged native-artifact replacement independently of
  frontend and LLVM lowering.

Run every benchmark from the repository root:

```powershell
go run ./helpers/cmd/develop benchmark
```

The command builds native benchmarks with Bazel's optimized configuration. Criterion uses the package's `-O2` benchmark
stanza. Bazel options may be appended after `--`, but platform configuration remains owned by the developer command.
The command has options of its own, written before `--`:

| Flag | Meaning |
| --- | --- |
| `--output DIR` | also write the times to `DIR` as a result set |
| `--filter REGEX` | run only the native benchmarks whose name matches |
| `--repetitions N` | run each native benchmark `N` times, 1 to 100, and report the median |
| `--native-only`, `--haskell-only` | leave the other half out |

A result set is a directory with one Google Benchmark JSON file for each native program and one Criterion CSV file,
`haskell.csv`. Two commands read it and start nothing:

```powershell
go run ./helpers/cmd/develop benchmark --output results/before --repetitions 5
go run ./helpers/cmd/develop benchmark-report results/before --markdown before.md
go run ./helpers/cmd/develop benchmark-compare results/before results/after --threshold 10
```

`benchmark-report` prints a result set as a Markdown table. `benchmark-compare` sets a candidate against a baseline: a
benchmark is slower or faster when its time moved by more than the threshold, in percent (10 unless given), and
unchanged inside it. The command fails when a benchmark is slower; `--informational` reports without failing. A
benchmark only one of the two sets has is listed as added or removed and never fails the comparison. With repetitions
the median is compared, which one slow run does not move.

Two result sets are comparable only when they were made on the same machine under the same load. Times from different
machines measure the machines.

Individual binaries and Criterion selectors remain available for focused investigations:

```powershell
bazelisk run -c opt //Compiler/Core/Benches:core_benches -- --benchmark_filter=CoreEncode
bazelisk run -c opt //Compiler/Core/CorePrep/Benches:coreprep_benches -- --benchmark_filter=Decode
bazelisk run -c opt //Compiler/Codegen/Xpp/Benches:xpp_benches -- --benchmark_filter=Optimize
bazelisk run -c opt //Compiler/Codegen/Xmm/Benches:xmm_benches -- --benchmark_filter=Lower
bazelisk run -c opt //Compiler/Driver/Benches:project_artifact_benches -- --benchmark_filter=PlanProjectSourceOutputs
Set-Location Compiler
cabal bench visual-xsharp-core:core-benches --enable-benchmarks --benchmark-options="--match Core/Encode"
```

## Recording policy

A committed result is a baseline, not a universal performance promise. Each result must identify the commit, host,
processor, operating system, compiler/runtime versions, build mode, and exact command. Compare results only on the same
machine with similar power and thermal conditions. Close background work, use an optimized build, and retain the raw
per-size observations rather than publishing only the fastest case.

Continuous integration compiles both harnesses and performs short smoke runs. It deliberately does not fail a change on
elapsed-time thresholds: shared runners vary too much for a stable regression gate. A future dedicated runner may add
statistical comparisons once it can provide fixed CPU frequency, warm-up policy, and historical storage.

## Recorded results

- `2026-09-13-Windows-x86_64.md` is the first complete Core-through-Xmm baseline.
- `2026-09-13-Native-Liveness.md` records the Xpp/Xmm optimizer follow-up after native liveness integration.
- `2026-09-14-Native-Dataflow.md` records the verifier/encoder follow-up after worklist scheduling and packed lattices.
- `2026-09-14-Dense-Liveness.md` records dense backward-liveness and retention-only optimizer results.
- `2026-09-20-Core-Linear-Inlining.md` records the first smoke and latency reference for capture-avoiding linear-body inlining.
- `2026-09-20-Core-Verifier-Environment.md` records removal of the quadratic per-function global-environment copy.
- `2026-09-23-Core-Floating-Folding.md` records the nested binary64 constant-folding workload.
- `2026-09-24-Core-Integer-Folding.md` records the repeated 128-bit integer constant-folding workload.
- `2026-09-24-Core-Integer-Flow.md` records guarded-division and contradictory-path integer-fact workloads.
- `2026-09-24-VXSI-ORC.md` records the first Visual X# Interactive native-cell/JIT lifecycle baseline.
- `2026-09-27-Project-Artifacts.md` records per-source planning and staged output costs on a Windows development host.
- `2026-09-27-Loop-Comparisons.md` records the loop-unrolling comparison and a compiler-owned CorePrep loop workload.
- `2026-09-28-Core-Loop-Integer-Flow.md` records loop-header widening and loop-carried Core fact costs.
- `2026-10-04-Nesting-And-Chains.md` records the stack the native Core stages use per level of nesting, and the cost
  of nested loops and of long `else if` chains, before and after they were reduced.
- `2026-10-07-Many-Methods.md` records the compile time of a class by its number of methods, which grew with the
  square of that number in five places, before and after.
