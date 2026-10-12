# Core integer constant-fold benchmark

## Environment

- Date: 2026-09-24
- Host: Windows x64
- GHC: 9.10.3, optimized Cabal profile
- Compiler package: 0.3.9
- Harness: Criterion, `--time-limit 1 --resamples 100`
- Workload: verified Core modules with repeated 128-bit integer power, left shift, bitwise XOR, and addition. Fixture
  construction is outside the timed sample; each sample runs the default verified Core optimizer to its fixed point.

## Command

Run from `Talac/`:

```powershell
cabal bench tala-core:core-benches --enable-benchmarks --benchmark-options="--match prefix Core/ConstantFoldInteger --time-limit 1 --resamples 100"
```

## Results

| Integer operation groups | Criterion `time` estimate | 95% interval | Mean |
| ---: | ---: | ---: | ---: |
| 8 | 169.1 μs | 168.0–170.6 μs | 170.0 μs |
| 32 | 632.7 μs | 622.8–637.7 μs | 637.8 μs |
| 128 | 2.509 ms | 2.477–2.533 ms | 2.533 ms |
| 512 | 10.52 ms | 9.895–10.81 ms | 11.20 ms |
| 1024 | 27.28 ms | 23.97–35.67 ms | 25.28 ms |
| 2048 | 53.62 ms | 41.41–66.97 ms | 57.33 ms |

The 128-to-512 estimate rises about 4.2× for 4× as many operation groups; the 512-to-2048 estimate rises about 4.5× for
4× the groups. That is broadly near-linear for this fixture, but the 1024- and 2048-group samples have wide intervals and
moderately inflated variance. This is a new workload with no prior before/after baseline, so it does not establish a
speedup, asymptotic guarantee, or cross-machine promise. CPU model, power state, and background load were not controlled.

## Reading the measurement

Fixture construction and recursive AST setup run in Criterion's environment, outside the timed action. The timed action
still includes the production verification and fixed-point optimizer passes, including integer folding, type-aware refusal
of out-of-range fixed-width results, control-flow simplification, and final verification. It is therefore a compiler
pipeline cost, not a microbenchmark of a single Haskell multiplication.

The repeated expression chain is intentionally stable across input sizes. Each group builds a power, shifts it, XORs it
into the accumulated value, then adds one. This prevents the benchmark from measuring only one arithmetic primitive and
exercises the same pass sequencing that source-generated Core encounters. The fixture uses `ulongint`, so intermediate
growth eventually forces the optimizer to preserve operations rather than fold a mathematically unrepresentable result.

The 8-to-128 group range is repeatable with narrow confidence intervals. Larger fixtures show enough run-to-run spread
that they should be used as a regression signal only when the same host is quiet and the benchmark is repeated. A future
before/after comparison must use the exact same Cabal profile, Criterion options, and fixture generator; this record is
not a historical baseline for the earlier floating-fold or verifier workloads.
