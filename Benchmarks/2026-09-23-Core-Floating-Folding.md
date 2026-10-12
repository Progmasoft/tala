# Core floating constant-fold benchmark

## Environment

- Date: 2026-09-23
- Host: Windows x64
- GHC: 9.10.3, optimized Cabal profile
- Compiler package: 0.3.9
- Harness: Criterion, `--time-limit 1 --resamples 100`
- Workload: verified Core modules with nested binary64 addition; each optimizer run includes exact-ratio parsing,
  target rounding, shortest round-trip spelling, and fixed-point verification.

## Command

Run from `Talac/`:

```powershell
cabal bench tala-core:core-benches --enable-benchmarks --benchmark-options="--match prefix Core/ConstantFoldFloating --time-limit 1 --resamples 100"
```

## Results

| Floating additions | Criterion `time` estimate | 95% interval | Mean |
| ---: | ---: | ---: | ---: |
| 8 | 785.5 μs | 762.9–798.3 μs | 811.5 μs |
| 32 | 5.201 ms | 4.746–5.446 ms | 5.864 ms |
| 128 | 27.43 ms | 23.84–30.89 ms | 25.81 ms |
| 512 | 107.5 ms | 95.67–118.0 ms | 107.3 ms |

The 128-to-512 estimate rises about 3.9× for 4× as many additions. This is a first measurement of a newly introduced
workload, not a before/after comparison; it should not be read as a cross-machine performance guarantee. CPU model,
power state, and background load were not controlled. Criterion reported moderate outlier variance for the 8-, 128-, and
512-node samples and severe variance for the 32-node sample.
