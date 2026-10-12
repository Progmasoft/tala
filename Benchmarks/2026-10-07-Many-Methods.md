<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Compile time by number of methods

## Scope

The time of `talac check` on one class with many small methods grew with the
square of their number: 1000 methods took 4 seconds and 4000 took 73. This
record holds the measurements that located the cause in five places, and the
same measurements after each was changed.

"Before" is commit `805b0659`. "After" is the working tree this file is
committed with.

## Environment

- Date: 2026-10-07
- OS: Windows NT 10.0.26200, x86-64
- CPU: Intel Core i5-3210M @ 2.50 GHz
- GHC 9.10.3; clang-cl 22.1.8 for the native code
- Native build: the default configuration of `develop build`

Other programs ran on the machine during the measurements, and single runs
of one program differed by up to a factor of two. Where a figure is the best
of several runs, the table says so.

## Programs

Each program is one class in one file. `methods` has the given number of
static methods of the form `public static int M7(_ int n) { return n + 7; }`
and one method that returns a local. `sequence` has one method with the
given number of statements `if (n > 7) { t += 1; }`.

## Whole programs

`talac check -File`, wall time in seconds.

| Program | Size | Before, one run | After, best of five |
| --- | ---: | ---: | ---: |
| `methods` | 1000 | 4.28 | 1.35 |
| | 2000 | 16.3 | 2.85 |
| | 4000 | 73.4 | 4.78 |
| | 8000 | not measured | 10.1 |
| `sequence` | 4000 | 5.85 | 6.06, best of two |

After the change the time of `methods` doubles with the input, at about 1.25
milliseconds for each method. `sequence` is not affected; it was measured to
confirm that.

## Where the time went

### Native stages

The native stages were timed in the compiler itself, with a clock around each
stage that was added for the measurement and is not part of the change. Times
in milliseconds for `methods`.

| Stage | 1000 before | 2000 before | 1000 after | 2000 after | 4000 after | 8000 after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Core decode | 52 | 65 | 45 | not recorded | 117 | 236 |
| Core verify | 29 | 35 | 24 | not recorded | 66 | 133 |
| CorePrep prepare | 26 | 43 | 28 | not recorded | 76 | 149 |
| CorePrep verify | 3860 | 14388 | 25 | 40 | 74 | 149 |
| Xpp lower | 13 | 16 | 12 | not recorded | 30 | 62 |
| Xpp optimize | 96 | 145 | 104 | not recorded | 295 | 579 |
| Xpp ownership placement | 77 | 126 | 68 | not recorded | 251 | 511 |
| Xpp verify | 136 | 218 | 108 | 211 | 425 | 854 |
| Xmm lower | 31 | 28 | 14 | not recorded | 56 | 113 |
| Xmm optimize | 79 | 142 | 78 | not recorded | 286 | 570 |
| LLVM lower | 583 | 734 | 387 | 695 | 1340 | 2728 |

The native CorePrep verifier took 14.4 of the 17.7 seconds of the run with
2000 methods. For every function it entered every function of the module
into a table of its own, building the function type of each, and it searched
the whole module for closures that capture into the function. The table and
the captures are now collected once for the module.

`//Talac/Core/CorePrep/Benches:coreprep_benches` has the case
`VerifyFunctions` for this. After the change, on modules of functions that
return a constant:

| Functions | Time |
| ---: | ---: |
| 64 | 0.80 ms |
| 256 | 2.55 ms |
| 1024 | 6.77 ms |
| 4096 | 28.1 ms |

Google Benchmark fits these to linear time with a deviation of 5 percent.
The case was not run on the verifier as it was before.

### Frontend stages

The Haskell stages were timed by a program that runs each stage of the
library on a source file and forces its whole result by rendering it as
text. Rendering is part of every figure, so the figures are larger than the
stages are in the compiler; they are comparable with one another. Seconds,
for `methods` with 8000 methods.

| Stage | Before | After |
| --- | ---: | ---: |
| lexing and parsing | 2.91 | 2.75 |
| renaming, name resolution and type checking | 6.54 | 0.61 |
| Core verification | 1.03 | 0.31 |
| CorePrep lowering, which verifies its input first | 2.73 | 0.84 |

Four places took time with the square of the number of members:

- The renamer kept the names in scope as a list of pairs, so every lookup
  and every check for a duplicate walked all members of the type. Renaming
  alone took 3.91 seconds for 8000 methods; with a map it takes 0.4 for
  methods of the same number that return their parameter.
- The type checker compared every method with every earlier member to find
  two overloads with the same parameters. It now compares a method with the
  earlier methods of its own name. Type checking took 4.30 seconds for 8000
  methods with empty bodies and takes 0.28.
- The Haskell Core verifier looked every function up in the list of source
  owners.
- The CorePrep lowering appended the functions lifted out of closures to
  the list of functions still waiting, once for every function, also when
  there were none; each step then took time with the number of functions
  before it.

## What is not addressed

`sequence` still takes more than twice as long for twice as many statements
between 2000 and 4000; that growth was recorded in
`2026-10-04-Nesting-And-Chains.md` and is unchanged. Lexing and parsing are
the largest frontend stage after this change and were not examined.
