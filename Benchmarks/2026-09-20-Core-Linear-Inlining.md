<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Core linear-body inlining reconnaissance

## Purpose

This record establishes the first local smoke result for capture-avoiding
linear-body inlining. It is a harness validation and a rough latency reference,
not a release performance claim. The short sample was intentionally run before
the complete repository benchmark gate so semantic and fixture mistakes could
be found cheaply.

## Environment

- Date: 2026-09-20
- Operating system: Windows
- Architecture: x86_64
- GHC: 9.10.3
- Cabal: 3.16.1
- Compiler language edition: GHC2024
- Criterion: package constraint `>= 1.6.4 && < 1.7`
- Build profile: Cabal optimized (`-O2`)
- Sample limit: 0.1 seconds
- Fixture size: 8 callers

CPU model, power state, background load, and thermal state were not controlled.
Those omissions are acceptable for a smoke run but prohibit comparing this
number with another machine or treating a small delta as a regression.

## Command

Run from `Talac/`:

```powershell
cabal bench tala-core:core-benches --enable-benchmarks `
  --benchmark-options="--match pattern Core/InlineLinearBody/8 --time-limit 0.1"
```

## Fixture

The module contains one pure helper with:

1. one `int` parameter;
2. an immutable multiply binding;
3. an immutable add binding depending on the first local; and
4. a final return of the second local.

Each caller supplies a non-trivial primitive expression. Inlining must therefore
allocate one fresh argument let plus two fresh local lets per call. Function and
local identities are globally disjoint before optimization. The fixture grows
real verifier, effect-graph, symbol-inventory, cloning, and report work rather
than padding an ignored byte buffer.

The timed action calls `optimizeCoreWith`. It includes:

- input Core verification;
- interprocedural effect inference;
- candidate discovery;
- complete module symbol inventory;
- fresh identity allocation;
- argument and local let construction;
- fixed-point convergence;
- output Core verification; and
- structural digest consumption of the result and inline reports.

Fixture construction is performed by Criterion `env` outside the measured
action.

## Result

```text
benchmarking Core/InlineLinearBody/8
time                 347.2 us   (306.3 us .. 400.5 us)
mean                 404.0 us   (358.5 us .. 460.5 us)
std dev              115.8 us   (86.10 us .. 163.9 us)
variance introduced by outliers: 97% (severely inflated)
```

The benchmark completed successfully and consumed a verified optimized module.
The high outlier percentage is expected evidence that the 0.1-second window is
too short for a stable comparison. No throughput or complexity conclusion is
drawn from this sample.

## Acceptance interpretation

The useful outcome is binary: the production pipeline can repeatedly optimize
the scalable fixture without a verifier failure, identity collision, retained
malformed call, or benchmark harness crash. The measured magnitude is plausible
for a complete optimizer invocation over this small fixture, but it is not a
budget.

Before using this case for performance decisions:

1. run all four sizes (`8`, `32`, `128`, and `256`);
2. use Criterion's normal sampling duration;
3. repeat on the same host and power policy;
4. inspect allocation and effect-inference profiles if scaling bends; and
5. record the complete environment with the result.

Correctness remains owned by the component test suite. The benchmark must not
grow alternate optimizer logic, skip verification, or use fixture-only compiler
entry points to improve its number.
