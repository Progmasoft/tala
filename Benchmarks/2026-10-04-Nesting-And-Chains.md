<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Nesting depth, long chains and nested loops

## Scope

This record holds three sets of measurements taken before and after one
change set:

- the stack each native Core stage needs per level of nesting, in an ordinary
  build and in an AddressSanitizer and UndefinedBehaviorSanitizer build;
- the time of the Haskell Core operations that grew faster than their input:
  the loop fixed point of the integer analysis on nested loops, and wire
  encoding, CorePrep lowering and CorePrep verification on `else if` chains
  and on sequences of `if` statements;
- the time of `talac check` on whole programs of those shapes, and of the
  sanitized `source_fuzz_smoke` program.

"Before" is commit `5ffdbdff` for the Criterion measurements and `main` at
`d9bd54e4` for `talac check` and the smoke program. "After" is commit
`35d9c1ab`. The stack tables and the operator chain table name their
revisions themselves; "now" is the working tree this file is committed with.

## Environment

- Date: 2026-10-04
- OS: Windows NT 10.0.26200, x86-64
- CPU: Intel Core i5-3210M @ 2.50 GHz
- GHC 9.10.3, Cabal `-O2` for Criterion; clang-cl 22.1.8 for the native code
- Native build: the default configuration of `develop build`; sanitizer
  build: `develop sanitize address-undefined`

## Stack per level of nesting

`//Talac/Support/Tests:stack_probe` builds a Core module of a given shape
and depth and runs one stage on a thread whose stack has a given size; the
process is ended by the operating system when the stack is too small. The
smallest size that completes was found by bisection, to within 0.5 percent or
4 KiB, at depths 64, 256, 1024 and 4096, and the table gives the slope
between the two largest depths measured. Windows rounds a stack to 64 KiB, so
small totals are coarse and the slopes are the meaningful figures.

```powershell
go -C helpers run ./cmd/develop build -- //Talac/Support/Tests:stack_probe
bazel-bin/Talac/Support/Tests/stack_probe.exe statements 1024 decode 708
```

The shapes are `statements`, an `if` nested in an `if`; `operands`, an
addition whose second operand is an addition; `expressions`, an addition
whose first operand is an addition; and `chain`, an `else if` chain. The
first two are nesting that every stage recurses along. The last two are
chains, which are as deep in the tree as they are long. `pipeline` is
`Pipeline::ConsumeCore`, the whole native route from Core bytes to LLVM.

Three revisions were measured: `5ffdbdff`, before any of this work;
`35d9c1ab`, after the frames of the reader, the verifier and the adapter were
reduced; and the working tree this file is committed with, in which chains
are walked in a loop by every stage, modules are released from a list, and
the reader reads every expression into its place. KiB of stack per level:

| Shape | Stage | `5ffdbdff` | `35d9c1ab` | Now | Now, sanitizers |
| --- | --- | ---: | ---: | ---: | ---: |
| statements | wire writer | 0.67 | 0.67 | 0.67 | 2.05 |
| statements | wire reader | 14.8 | 0.65 | 0.65 | 1.59 |
| statements | Core verifier | 1.70 | 0.67 | 0.67 | 1.70 |
| statements | CorePrep adapter | 3.81 | 0.31 | 0.31 | 1.17 |
| statements | pipeline | 14.9 | 0.67 | 0.67 | 1.67 |
| operands | wire writer | | 0.19 | 0.19 | 0.62 |
| operands | wire reader | | 7.13 | 0.37 | 1.06 |
| operands | Core verifier | | 0.91 | 0.91 | 2.52 |
| operands | CorePrep adapter | | 1.94 | 1.94 | 3.39 |
| operands | pipeline | | 7.13 | 1.94 | 3.39 |
| expressions | wire writer | 0.83 | 0.83 | 0 | not measured |
| expressions | wire reader | 10.6 | 0.42 | 0 | not measured |
| expressions | Core verifier | 2.34 | 0 | 0 | not measured |
| expressions | CorePrep adapter | 4.35 | 0 | 0 | not measured |
| expressions | pipeline | 10.6 | 0.42 | 0 | not measured |
| chain | wire reader | 0.38 | 0.38 | 0 | not measured |
| chain | CorePrep adapter | 0.25 | 0 | 0 | not measured |
| chain | pipeline | 0.38 | 0.38 | 0 | not measured |

A zero means the stage completed on the smallest stack at every depth
measured: up to 1024 additions and 4096 links, and, for the working tree,
20000 of each on 512 KiB in every stage. An empty cell was not measured: the
`operands` shape was added to the probe after `5ffdbdff`, and until then the
cost of nesting in a second operand had been taken, wrongly, to be that of
the `expressions` shape. The sanitizer build is AddressSanitizer with
UndefinedBehaviorSanitizer.

Totals that follow from the slopes, for the whole native pipeline:

| Input | `5ffdbdff` | Now | Now, sanitizers |
| --- | ---: | ---: | ---: |
| statements nested 256 deep, the frontend limit | 3.7 MiB | 0.2 MiB | 0.4 MiB |
| operands nested 1024 deep, the frontend limit | | 1.9 MiB | 3.4 MiB |
| statements nested 4096 deep, the wire limit, writer | 2.7 MiB | 2.7 MiB | 8.2 MiB |
| operands nested 4000 deep, near the wire limit | | 7.6 MiB | 13.3 MiB |
| sum of 20000 operands | crash | under 0.1 MiB | not measured |
| `else if` chain of 20000 links | crash | under 0.1 MiB | not measured |

The largest stack any measured stage needs on input the limits admit is
therefore 13.3 MiB, in a sanitizer build at the depth limit of the wire
codec, and 3.4 MiB at the limits of the frontend, against the 256 MiB the
compiler thread reserves. The adapter is now the stage that costs most per
level of real nesting. Copying a module still recurses once per level; the
pipeline copies only the bodies of closures.

## Committed stack of whole compilations

The slopes above come from one native stage at a time on synthetic Core. The
figures in this section are from whole compilations of source text: the
frontend and every native stage run on one thread, as in `talac`, and the
stack that thread committed is read at the end.

What is measured is the committed stack, not the bytes in use. It is an upper
bound on the deepest the thread's stack pointer went, rounded up to whole
pages, and it includes the guard page; it is not an exact high-water mark of
the bytes used. It counts only the thread's own stack. Memory that a build
keeps elsewhere for what would be stack frames is not in it: when
AddressSanitizer's use-after-return detection is active, it moves frames to
a fake stack on the heap, and those frames would be missing here. The
sanitizer builds measured ran with `halt_on_error=1:strict_string_checks=1`
and otherwise the defaults of the runtime, which on Windows leave that
detection off, so their figures are of instrumented frames on the real
stack; they say nothing about a run with the detection on. Measured
figures and figures derived from them are kept apart below: a derived figure
is called extrapolated where it appears.

```powershell
go -C helpers run ./cmd/develop build -- //Talac/Fuzzing:source_stack_probe
bazel-bin/Talac/Fuzzing/source_stack_probe.exe program.tala 262144
```

The second argument is the reservation in KiB; 262144 is the 256 MiB of the
compiler thread. Windows commits a page of a stack when it is first touched.
Every program is one method; its conditions differ at every
level, so that the optimizer cannot remove the nesting before the native
stages see it. "Limit" is the deepest the frontend accepts: a statement at
level 256, an expression at level 1024. Committed stack, KiB:

| Program | Ordinary build | ASan and UBSan |
| --- | ---: | ---: |
| `return value + 1;` | 72 | 76 |
| 255 nested `if`, limit | 196 | 464 |
| 255 nested `while`, limit | 172 | 416 |
| 255 nested `for`, limit | 176 | 416 |
| 255 nested `do`/`while`, limit | 168 | 416 |
| 255 nested `guard` blocks, limit | 188 | 464 |
| 255 nested `match` arms, limit | 196 | 464 |
| 255 nested `while` whose condition stores, limit | 172 | 416 |
| 255 nested blocks used as values, limit | 784 | 1348 |
| 256 nested `if`, rejected with `TAP0039` | 32 | 36 |
| 1023 additions nested to the right, limit | 2004 | 3484 |
| 1023 nested calls, limit | 2572 | 4720 |
| conditional chain of 1022 tests, limit | 548 | 1504 |
| 1023 unary operators, limit | 72 | 76 |
| 1024 additions nested to the right, rejected with `TAP0040` | 32 | 40 |
| sum of 7000 operands | 72 | 76 |
| 3000 comparisons joined by `&&` | 72 | 76 |
| `else if` chain of 1400 links | 68 | 76 |
| `match` of 2000 arms | 72 | 76 |

The harness accepts at most 64 KiB of source, which bounds the chains
measured here; `talac check` itself was run on a sum of 50000 operands and on an
`else if` chain of 4000 links. The frontend adds almost nothing: Haskell code
runs on stacks of its own, and a program the frontend rejects commits 32 to
40 KiB. Chains commit what the smallest program does.

The most any program at the frontend limits committed is 2.5 MiB in an
ordinary build and 4.6 MiB under the sanitizers, for nested calls, which cost
2.5 and 4.6 KiB per level. Those are measurements. A function can combine a
statement nest with an expression nest at its bottom; adding the two worst
rows gives about 3.0 MiB and 5.2 MiB, which is derived, not measured.

### What the lowering adds

Core nesting per source level, counted on the unoptimized Core of each
construct nested 100 deep. Statement depth counts bodies, with an `else if`
chain as one level; expression depth counts every child except the first
operand of a primitive.

| Source, 100 levels | Core statement depth | Core expression depth |
| --- | ---: | ---: |
| `if`, `while`, `for`, `do`/`while`, `guard`, `match` arm | 100 | 1 |
| block statement | 0 | 1 |
| `while` whose condition stores | 101 | 1 |
| `do`/`while` whose condition stores | 102 | 1 |
| blocks used as values, pure | 0 | 101 |
| blocks used as values that hold statements | 100 | 1 |
| additions nested to the right, nested calls | 0 | 100 |
| conditional chain | 0 | 101 |
| unary operators | 0 | 1 |
| right operands that store | 0 | 101 |
| `&&` whose right operands store, 200 expression levels | 101 | 2 |
| sum of 100 operands, `else if` chain of 100, `match` of 100 arms | 0 or 1 | 1 |

The lowering adds at most two levels to a nest. It can turn a level of one
kind into a level of the other: a block used as a value is an expression
level when it is pure and a statement level when it holds statements, and a
short-circuit operator whose right operand stores becomes a conditional
statement. Core from a function at the frontend limits therefore has at most
about 256 + 1024 levels of either kind, inside the 4096 the wire codecs
admit.

### Beyond the frontend limits

Core that does not come from this frontend is bounded by the wire codecs at
4096 levels of each kind; deeper input is rejected by the reader before it is
walked. Measured near that bound with the stack probe: 8.2 MiB for 4096
nested statements in the writer and 13.3 MiB for 4000 nested operands in the
adapter, both under the sanitizers. Nested calls were not measured at that
depth; from their slope of 4.6 KiB they would need about 18.4 MiB, and a
function that nests both kinds to the bound about 27 MiB. That last figure is
an extrapolation, not a measurement.

### Reserve and commit

The compiler thread reserves 256 MiB of address space and commits what it
touches. `talac check` on this branch and on `main`, which has no compiler
thread, one process and eight at once; MiB, the largest of the processes
except where summed:

| Program | Build | Processes | Peak virtual size | Peak commit | Commit, summed | Wall, s |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| small program | `main` | 1 | 4295.8 | 30.9 | 30.9 | 1.03 |
| | `main` | 8 | 4294.8 | 30.9 | 247.1 | 0.28 |
| | now | 1 | 4550.1 | 31.0 | 31.0 | 0.25 |
| | now | 8 | 4552.1 | 31.0 | 247.7 | 0.32 |
| 1023 nested calls | `main` | 1 | 4309.8 | 44.9 | 44.9 | crash |
| | now | 1 | 4568.1 | 50.5 | 50.5 | 0.50 |
| | now | 8 | 4567.1 | 50.4 | 403.3 | 1.43 |
| sum of 50000 operands | now | 1 | 5101.8 | 582.9 | 582.9 | 13.3 |
| | now | 8 | 5112.9 | 593.8 | 4673.7 | 34.8 |

The reservation shows as 256 MiB of virtual size and as nothing else: the
commit of a small program is the same with and without it, alone and eight
at once. What a compilation commits is its heap; the stack is at most a few
megabytes of it. The first `main` row includes a cold start. Concurrency
inside one process was not measured, because the compiler has one compiler
thread per process.

### What the measurements do and do not support

The figures above are from one machine: Windows, x86-64, clang-cl, an
ordinary build and an AddressSanitizer build with UndefinedBehaviorSanitizer.
Frame sizes differ between compilers and ABIs, so one shape was measured on
the other platforms as well, in CI, on commit `a0b435a3`.

### The other platforms

`source_execution_smoke` compiles all of its programs on one compiler
thread and prints what that thread committed at the end. The largest of its
programs for the stack is 1023 calls nested in each other's arguments, the
worst shape of the table above, so the figure is the committed stack at the
expression limit. Each figure is one run on a hosted CI runner, in KiB:

| Platform | Ordinary build | ASan and UBSan | TSan |
| --- | ---: | ---: | ---: |
| Windows Server, x86-64, clang-cl | 2580 | 4736 | not run |
| Ubuntu 26.04, x86-64, clang | 2588 | 3060 | 2880 |
| Fedora 43, x86-64, clang | 2588 | 3060 | not run |
| macOS 15, arm64, clang | 2480 | 5536 | 2752 |
| macOS 26, arm64, clang | 2480 | 5536 | 2768 |

On Windows the figure is the committed part of the stack allocation, guard
page included; on Linux and macOS it is the resident pages of the stack
mapping. The Windows row agrees with the 2572 and 4720 KiB measured by hand
for the same shape. The ordinary builds are within 5 percent of each other
on three operating systems and two architectures. The Linux sanitizer figure
is lower than the others because the sanitizer runtime moves frames to a
fake stack on the heap by default there, which this figure leaves out, as
said above; it is not evidence that the sanitized compiler needs less stack
on Linux. The largest figure on any platform is 5536 KiB, 2.1 percent of the
256 MiB reservation. MemorySanitizer builds were not measured, and the
shapes other than nested calls were measured on Windows only.

Against these figures a reservation of 64 MiB would be about 12 times the
largest commit at the frontend limits under the sanitizers and about 2.4
times the extrapolated worst case of wire-fed Core. That is an argument for
a smaller reservation, not a decision: it rests on one extrapolation, the
cost of a reservation was measured to be address space only, and the values
in the code are unchanged.

## Haskell Core operations

```powershell
Set-Location Compiler
cabal bench tala-core:core-benches --enable-benchmarks --benchmark-options="--match pattern NestedLoop Chain Sequence --time-limit 0.1"
```

Criterion estimates, one run of each revision. The sample limit is short and
the ranges are wide, so only the orders of magnitude and the growth per
doubling are meaningful.

`Core/NestedLoopIntegerFacts`: the optimizer on loops nested to the given
depth.

| Depth | Before | After |
| ---: | ---: | ---: |
| 2 | 251 us | 244 us |
| 4 | 876 us | 326 us |
| 8 | 14.2 ms | 650 us |
| 12 | 276 ms | 659 us |
| 16 | 4.89 s | 907 us |

Before, four more levels multiplied the time by about 18. The analysis
repeated the fixed point of an inner loop on every pass over the loop around
it. It now iterates only loops that hold at most one further level of loops
and treats what a deeper loop assigns as unknown, which is sound.

`else if` chains and sequences of `if` statements of the given length:

| Benchmark | Size | Before | After |
| --- | ---: | ---: | ---: |
| `Core/EncodeChain` | 256 | 78.9 ms | 1.72 ms |
| | 512 | 289 ms | 5.01 ms |
| | 1024 | 968 ms | 14.9 ms |
| | 2048 | 4.95 s | 60.0 ms |
| `CorePrep/PrepareChain` | 256 | 23.8 ms | 1.94 ms |
| | 512 | 101 ms | 4.22 ms |
| | 1024 | 460 ms | 9.15 ms |
| | 2048 | 2.20 s | 20.2 ms |
| `CorePrep/PrepareSequence` | 256 | 3.60 ms | 3.21 ms |
| | 512 | 7.18 ms | 6.16 ms |
| | 1024 | 31.0 ms | 14.9 ms |
| | 2048 | 46.7 ms | 32.4 ms |
| `CorePrep/VerifyChain` | 256 | 11.2 ms | 1.36 ms |
| | 512 | 46.7 ms | 3.35 ms |
| | 1024 | 160 ms | 6.34 ms |
| | 2048 | 746 ms | 15.1 ms |
| `CorePrep/VerifySequence` | 256 | 16.4 ms | 1.85 ms |
| | 512 | 58.5 ms | 4.21 ms |
| | 1024 | 209 ms | 7.95 ms |
| | 2048 | 788 ms | 17.8 ms |

Lowering and verification now double with the input. Encoding a chain still
grows by a factor of three to four per doubling, from a base about fifty
times lower than before; the cause was not investigated.

## Whole programs

`talac check -File` on one method of the given shape, one run each, wall time
in seconds. `crash` is a stack overflow without a diagnostic.

| Program | Size | Before | After |
| --- | ---: | ---: | ---: |
| `else if` chain | 500 | 1.40 | 0.64 |
| | 1000 | 2.52 | 1.28 |
| | 2000 | crash | 3.30 |
| | 4000 | crash | 10.4 |
| sequence of `if` statements | 500 | 0.76 | 0.70 |
| | 1000 | 1.51 | 1.32 |
| | 2000 | 3.58 | 2.79 |
| | 4000 | 12.0 | 7.11 |
| nested `for` loops | 8 | 0.19 | 0.17 |
| | 14 | 1.06 | 0.13 |
| | 50 | more than 120 | 0.28 |
| | 255 | more than 120 | 3.72 |
| `match` arms | 500 | 0.74 | 0.65 |
| | 1000 | 1.65 | 1.36 |
| | 2000 | 3.95 | 3.41 |

Chains of operators, which the expression nesting limit rejected above 1024
operands until this change, on `35d9c1ab` with the limit lifted and on the
working tree:

| Program | Size | Limit lifted only | Now |
| --- | ---: | ---: | ---: |
| sum of operands | 5000 | 2.45 | 1.23 |
| | 20000 | 30.4 | 4.57 |
| | 50000 | 198 | 9.37 |
| comparisons joined by `&&` | 100 | 3.68 | not measured |
| | 200 | 47.6 | 1.13 |
| | 800 | more than 120 | 1.75 |
| | 3000 | not measured | 5.60 |

The `&&` figures of the first column are the same on `main`: 3.66 seconds
for 100 comparisons. Constant propagation asked the integer facts about
every node of an expression, and the CorePrep lowering collected symbol
identities by appending lists; both are fixed, and the facts are consulted
only for conditions of at most 256 nodes.

The time still grows faster than the program between 2000 and 4000
statements: by 3.1 for the chain and by 2.5 for the sequence. Earlier
per-stage timing placed that growth in the frontend before Core and in the
native stages after CorePrep; it is not addressed here.

## Sanitized smoke program

`source_fuzz_smoke` built with AddressSanitizer and
UndefinedBehaviorSanitizer, run by hand on the same machine:

| Revision | Wall time | Programs compiled for the execution tables |
| --- | ---: | --- |
| `main` at `d9bd54e4` | 291 s | one for every run |
| one program for every distinct body | 204 s | 134 for 237 runs |
| after: up to eight small bodies in a program | 160 s | 237 runs in fewer programs |

In the last measurement the expression table takes 23 seconds, the branching
table with its four large programs 36 seconds, and the 342 generated
differential programs, which this change does not touch, 98 seconds.

`main` exceeds the 240-second watchdog of `develop sanitize` on this machine.
No run was removed, and the large programs are run on more arguments than on
`main`: every run of a body is now a call in the one program compiled for
that body, which returns a bit for each run whose value differs from the expected
one and must return zero in both pipeline modes. Changing one expected value
by hand makes the smoke program fail and name the run.
