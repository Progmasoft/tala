<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Native loop comparison

`LoopSum` is a deliberately small cross-language executable. The C++, Haskell, Rust, and Fortran sources accept the same
algorithm selector and iteration count, calculate the sum from one through that count, and print a checksum. `baseline`
has one serial accumulator. `unrolled` processes four values per condition check with four independent accumulators,
then handles the tail. `formula` uses the arithmetic-series identity and is an algorithmic control, not an equivalent
measurement of loop code generation. Fortran is a free-form `.f90` source compiled in Fortran 2023 mode with
`-std=f2023`. The checksum makes incorrect or optimized-away work visible.

This compares generated machine code for a narrow integer loop, not compiler quality in general. It does not compare
Visual X# with these compilers, does not measure Visual X# compilation, and does not replace the project-owned C++20
Google Benchmark and Haskell Criterion suites. Keep compiler flags, CPU power state, count, and warm-up policy identical.

## Build commands

Run from the repository root after the toolchains are installed. On Windows, macOS, Ubuntu 26.04 LTS and Fedora 43,
`go run ./helpers/cmd/optional-packages install` installs the .NET 10 SDK and GNU Fortran, and adds `rustc`/`rust-std` to
the active rustup toolchain when one is already installed. It can install the rustup manager with no default toolchain,
but it never installs or selects a Rust toolchain. `check` reports whether those tools and components are available.
The comparative benchmark requires Clang++, GHC, Rust, and GNU Fortran, not the .NET SDK.

```powershell
clang++ -std=c++20 -O3 -DNDEBUG Benchmarks/Comparative/LoopSum.cpp -o $env:TEMP/loop-sum-clang.exe
ghc -O2 -Wall Benchmarks/Comparative/LoopSum.hs -o $env:TEMP/loop-sum-ghc.exe
rustc --edition=2024 -C opt-level=3 -C debuginfo=0 Benchmarks/Comparative/LoopSum.rs -o $env:TEMP/loop-sum-rust.exe
gfortran -std=f2023 -O3 -DNDEBUG Benchmarks/Comparative/LoopSum.f90 -o $env:TEMP/loop-sum-fortran.exe
```

Each executable accepts `baseline|unrolled|formula` and an optional positive count no greater than 4,294,967,295. The
default count is 50,000,000 and the expected checksum is `1250000025000000`. Run all algorithms and repeat each process
several times; report medians and the raw observations rather than selecting the fastest isolated sample. Use the same
explicit count for every language.

## Result recording

`../` stores committed machine results. Record exact compiler versions, command lines, OS build, processor, power mode,
per-run wall time, and checksum. A toolchain that cannot link on the host is marked unavailable; a compile-time or
partial result is not presented as a runtime comparison.
