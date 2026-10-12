<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Project source planning and artifact replacement

This baseline measures the new driver-owned source planner and the batch writer
that stages and replaces project object files. It is a local Windows
development measurement from the worktree based on `d4b7aab2`; the 0.4.0
changes were not committed when it ran.

## Environment

| Field | Value |
| --- | --- |
| OS | Windows 10 Pro, build 26200 |
| CPU | Intel Core i5-3210M @ 2.50 GHz; 2 cores / 4 logical processors |
| LLVM / ClangCL | 22.1.8 |
| Bazel | 9.2.0 |
| Language mode | C++20 |
| Build profile | `-c opt` |
| Benchmark library | Google Benchmark, repository-pinned module |
| Date | 2026-09-27 |

## Operation

`PlanProjectSourceOutputs` validates project-relative UTF-32 source paths,
checks duplicate source identities and flattened portable basenames, then
returns one `.o` name per source. The benchmark prepares catalogs with 1, 4,
16, and 64 entries before timing the planner.

`CommitProjectArtifactBatch` writes or replaces batches of 1, 4, 16, or 64
sibling object files. Each payload is 4 KiB. After the first iteration creates
the scratch output directory, later iterations also exercise replacement of
existing outputs. The measured loop includes staging, flush/close, backup
renames, installation renames, and transaction cleanup. It excludes LLVM
lowering and source discovery.

Command:

```powershell
bazelisk run -c opt //Talac/Driver/Benches:project_artifact_benches -- `
  --benchmark_min_time=0.5s --benchmark_repetitions=5 `
  --benchmark_report_aggregates_only=true
```

## Results

The median is reported because one-time host activity affects wall-clock time.
The five-repetition run also measured the following CPU-time coefficient of
variation: planning 6.69%, 7.04%, 4.37%, and 1.91%; replacement 10.46%, 4.26%,
3.92%, and 5.65% for increasing sizes.

| Sources / files | Planning median wall | Planning median CPU | Replacement median wall | Replacement median CPU |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0.925 µs | 0.921 µs | 6.499 ms | 5.859 ms |
| 4 | 3.384 µs | 3.376 µs | 14.176 ms | 13.338 ms |
| 16 | 14.245 µs | 14.300 µs | 48.330 ms | 43.199 ms |
| 64 | 60.298 µs | 61.384 µs | 189.874 ms | 151.042 ms |

The planner's fitted linear coefficient was about 952 ns per source with 4%
RMS error. The batch writer's fitted CPU coefficient was about 2.43 ms per file
with 10% RMS error; filesystem work dominates this measurement and varies by
host. This is a first feature baseline, not a before/after speedup claim or a
cross-machine guarantee. Compare future runs only on the same host with the
same optimized command and similar system load.

## Validation

The native project-artifact suite passes 1,558 assertions covering path and
basename validation, flattening collisions, Unicode, device names, safe
replacement, rollback, symlinks, and preservation of unrelated outputs. The
benchmark is a measurement aid; the suite remains the correctness authority.
