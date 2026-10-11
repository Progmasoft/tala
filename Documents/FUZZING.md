<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Compiler fuzzing and sanitizer campaigns

Fuzzing complements specification examples, component tests and IR verifiers.
A passing campaign is evidence about its inputs and duration, not a proof of
memory safety or complete language coverage.

## Independent targets and oracles

| Target | Input and checks | Coverage ownership |
| --- | --- | --- |
| `wire_fuzzer` | Core, private CorePrep transport, Xpp and Xmm; bounded decoding, semantic verification and equal encode/decode round trips | First-party C++ codecs and verifiers |
| `lexer_fuzzer` | Arbitrary bytes through the frontend lexer ABI; complete token/diagnostic evaluation | Native ABI bridge, not GHC-generated lexer branches |
| `parser_fuzzer` | Arbitrary bytes through syntax analysis; complete AST/diagnostic evaluation | Native ABI bridge, not GHC-generated parser branches |
| `source_llvm_fuzzer` | Arbitrary source through Core/CorePrep, Xpp/Xmm verification and LLVM lowering | First-party C++ pipeline |
| `differential_fuzzer` | Generated arithmetic and control flow compiled with native optimizers disabled/enabled and compared with an independent evaluator | First-party C++ pipeline and JIT bridge |
| `cli_fuzzer` | NUL-separated arguments through the typed command-line parser; two parses must produce equal typed models, leave `argv` unchanged, attach a diagnostic to every rejection and select a command on every acceptance | First-party C++ CLI parser |
| `project_fuzzer` | Evaluator registry records, both raw and as one mutated field of a valid document; decoding must be deterministic and a source-requiring decode may only accept what the permissive decode accepts | First-party C++ registry decoder; no evaluator process or filesystem access |
| `repl_fuzzer` | Up to eight operations on one persistent session: arithmetic cells checked against an independent accumulator, type queries that must not change history, failed-cell rollback and reset | First-party C++ session and JIT bridge |
| `ownership_fuzzer` | One to four threads racing weak locks, unowned loads and weak copies against the final strong release; the payload must be destroyed exactly once, never resurrected and never read after destruction | AARC runtime |
| `frontend-fuzz` | Lexer, parser and source-to-CorePrep stages mutated in-process with GHC HPC tick feedback | GHC-compiled frontend modules; no native sanitizer |

The differential oracle independently evaluates one generated program per
input: a bounded arithmetic expression, a classic `for` loop with `continue`
and `break`, a `do`/`while` loop, an `if`/`else` over that expression, a
`while` loop preceded by its own initializers, a recursion that terminates
only because `||` and `&&` skip their right operands, a recursion and a
division that are defined only because a conditional expression evaluates one
arm, a loop built from truthy coalescing and compound assignments, a chain
of nested conditionals, assignments and increments used as operands, loop
conditions that store, stores in lazily evaluated operands, or loops used as
expressions. The expected value is computed
by ordinary host code in the harness, never by a second compiler path. It
compiles the source once, lowers the same verified Core with Xpp/Xmm
optimizations both disabled and enabled, executes both verified
artifacts through ORC, and compares all three results. Agreement between the
two optimizer settings is not accepted by itself: both consume the same
Core-to-CorePrep adapter, so a defect there makes them agree on the same wrong
or non-terminating program. This detects miscompiles within that generated
subset; it is not an oracle for arbitrary Visual X#
programs. Invalid source is a normal rejection, whereas internal failures and
verified-model inconsistencies fail the campaign.

### CorePrep parity

The frontend lowers its optimized Core to CorePrep, and the native pipeline
lowers the same Core again with its own adapter. Only the native result
reaches Xpp, and both lowerings are well formed, so a divergence is a
miscompile that no later verifier can see. Every source that the frontend
accepts in `source_llvm_fuzzer`, `differential_fuzzer` and `source_fuzz_smoke`
is therefore checked for parity: the testing entry of the frontend delivers
the Core and CorePrep buffers of one compilation, the harness runs the native
adapter on that Core, and the two CorePrep modules must be structurally equal.

Both modules are compared in a canonical form. Reachable blocks are ordered
depth first from the entry, true edge before false edge, and `$`-prefixed
generated symbols are renamed in first-use order while keeping their kind.
Source symbols, types, literals, operations, operand and instruction order,
and edge roles are compared exactly; blocks unreachable from the entry are
ignored. `Compiler/Fuzzing/Tests/coreprep_parity_tests` pins what the
comparison may and may not ignore. Reintroducing the for-loop update defect
makes the smoke fail in this check before any generated code runs.

Parity proves that the two lowerings agree, not that either is correct. The
executable oracle below remains the check against an independent expectation.

Arbitrary source and generated arithmetic use separate corpora and equal
per-target time budgets. This lets source mutations reach native lowering
without repeatedly creating two ORC sessions for unrelated generated code.
The differential generator consumes at most 33 bytes: 31 expression selectors,
one shape byte and one trip-count byte. Its 64-byte input limit keeps
mutations near the bytes that influence the program.

GHC frontend code and prebuilt LLVM dependencies do not receive Clang native
coverage instrumentation. Running `lexer_fuzzer` or `parser_fuzzer` must not be
presented as coverage-guided exploration of the Haskell implementation.

`frontend-fuzz` is the separate feedback engine for that code. It is a Cabal
executable built with `--enable-coverage` in its own `dist-fuzz-coverage`
build directory, so it never shares package state with the ordinary frontend
build. It resets the HPC counters before each input, keeps an input when it
reaches a tick of a `Visual.XSharp.*` module that no earlier input reached,
and refuses to run when the production modules carry no ticks. Mutations are
deterministic for a recorded seed, inputs are limited to 8192 bytes and five
seconds, and the runtime heap is limited to 512 MiB. A Haskell exception or a
timeout writes the exact input as `failure.seed` and fails the campaign;
`frontend-fuzz STAGE --replay FILE` replays it. This engine has no sanitizer
and reports tick coverage, which is not comparable with libFuzzer edge
coverage.

## Run a campaign

From the repository root:

```powershell
go run ./helpers/cmd/develop fuzz
go run ./helpers/cmd/develop fuzz-stress
```

Both commands use combined ASan/UBSan on owned native code and verify that the
runtime can start a clean process and diagnose intentional use-after-free and
signed-overflow violations. Merely linking a sanitizer is insufficient.
Dependencies retain their own compile flags. `fuzz` defaults to 30 seconds per
target; `fuzz-stress` defaults to 900. Set `VXS_FUZZ_SECONDS` to an integer from
1 through 3600 to override either duration. CI uses 90 seconds per target for
bounded campaigns and 900 for scheduled stress campaigns.

Each setting of a campaign is also a flag of `fuzz`, `fuzz-stress` and
`fuzz-thread`, and a flag that is given replaces its variable for that run:

| Flag | Variable | Meaning |
| --- | --- | --- |
| `--seconds N` | `VXS_FUZZ_SECONDS` | time budget of each target, 1 to 3600 |
| `--jobs N` | `VXS_FUZZ_JOBS` | targets to run at once, 1 to 64 |
| `--corpus DIR` | `VXS_FUZZ_CORPUS` | directory that keeps the corpus between runs |
| `--target NAME` | `VXS_FUZZ_TARGETS` | run this target only; repeat the flag, or separate names with commas in the variable |

`go run ./helpers/cmd/develop fuzz-targets` lists the targets with the limits
each runs under, and the names a selection may use: the corpus name of a
target, its program name, or `haskell` for the Haskell feedback campaign.
`--json` writes the same list for a script. A selection narrows what is run,
not what is built or smoke-tested: the smoke programs are the precondition of
every campaign. A name the inventory does not have, a duration or a job count
outside its range, and a target without threads given to `fuzz-thread` are
refused before anything is built.

```powershell
go run ./helpers/cmd/develop fuzz --target parser --target source --seconds 120
go run ./helpers/cmd/develop fuzz --target haskell
```

Targets are independent processes with their own corpus, artifact directory
and report entry, so the helper can run several at once. Concurrency is not
free evidence: a campaign is worth the inputs it executes inside its time
budget, and on a two-core, four-thread host two concurrent targets executed
40 to 90 percent fewer inputs each. The default is therefore one job per four
logical processors, at most four, which is one target at a time on such a host
and on four-vCPU CI runners. Set `VXS_FUZZ_JOBS` to an integer from 1 through
64 on a host with spare cores. Two targets with a 4096 MiB RSS limit never
overlap, the three HPC stages follow the same setting, and the ThreadSanitizer
campaign always runs one target at a time because its targets start their own
threads. Time budgets, RSS limits, per-input timeouts and watchdogs are
identical at every job count.

Most local wall-clock time is compilation, not fuzzing. The plain, sanitizer
and fuzz configurations share one Bazel output tree, and each switch would
otherwise recompile every owned translation unit. Outside CI the helper adds a
persistent content-addressed Bazel disk cache under the user cache directory
(`visual-xsharp/bazel-disk-cache`, limited to 8 GiB). It is keyed by each
action's full command line and inputs, so no instrumentation or check changes.
`VXS_BAZEL_DISK_CACHE` selects another absolute directory, or `off` for a cold
measurement.

Each campaign has a 30-second per-input timeout and a finite input length:

| Target | Maximum input bytes | RSS limit (MiB) |
| --- | ---: | ---: |
| Wire | 16384 | 768 |
| Lexer | 65536 | 1024 |
| Parser | 65536 | 1536 |
| Source/LLVM | 65536 | 4096 |
| Differential | 64 | 4096 |
| CLI | 16384 | 768 |
| Project registry | 65536 | 768 |
| REPL | 64 | 4096 |
| Ownership | 64 | 768 |

ASan intentionally retains freed allocations in quarantine. Fuzz-only settings
bound this cache to 64 MiB, with a 256 KiB thread-local cache; the nonzero
use-after-free detection window remains active. These settings do not disable
the RSS limit or make an OOM successful. Ordinary sanitizer suites keep their
normal quarantine settings.

## Corpus synchronization and reports

Wire seeds come from production writers, so format-version changes do not leave
handwritten supposedly valid documents behind. Every other target has
versioned seeds under `Compiler/Fuzzing/Corpus/<target>/`; a target without
that directory fails the campaign instead of starting from nothing. Set `VXS_FUZZ_CORPUS` to retain mutation
corpora across local runs. Updated versioned seeds are added without overwriting
older discovered inputs; conflicting contents under a stable hash fail closed.

GitHub Actions restores a per-platform corpus cache and saves a unique cache
version for each run. It also uploads campaign artifacts on success or failure.
Reports contain the target, duration, RSS limit, selected sanitizer, native
coverage ownership and result. Structured reports also include executed inputs,
average executions per second, new corpus entries, slowest input time and peak
RSS from libFuzzer's final counters. A successful process without a complete
final report or with zero executed inputs fails the campaign gate. Failed
processes retain their original logs even if final counters are unavailable.
Failed work directories are preserved for diagnosis; successful CI reports
are retained for artifact upload.

Keep the exact failing input, compiler version, command and report. Replay a
single input with the same instrumented executable, for example:

```powershell
.\bazel-bin\Compiler\Fuzzing\wire_fuzzer.exe -runs=1000 PATH_TO_FAILURE
```

Use the matching Clang runtime environment, as the developer helper does. A
fixed-input replay is not a new fuzz campaign. Minimize a reproducible defect,
then add a focused regression at the owning component before changing the
implementation. A campaign-level RSS failure may require investigating the
whole corpus and sanitizer cache rather than just the final input.

## Deterministic smoke and merge gates

`wire_fuzz_smoke` exercises 1024 deterministic mutations of each of four valid
documents. It runs independently of libFuzzer and does not claim guided
coverage. `source_fuzz_smoke` checks valid-source lowering and then runs the
differential oracle on every generated program shape at trip counts 0 through
11, once with a zero and once with a nonzero generated expression, before
mutation campaigns begin. `source_execution_smoke` runs the programs of
`BranchingExecutionCases.cpp`, and `source_expression_smoke` those of
`ExpressionExecutionCases.cpp` and
`LeavingExecutionCases.cpp`: assignments,
increments and loops used as values, and `match`, `if` expressions and
`guard`, each with a hand-written result that both native pipeline modes must
return. Those tables are transcribed from the evaluation tables of
`AssignmentExpressionTests.hs`, `LoopExpressionTests.hs` and
`BranchingTests.hs`, where the same programs are checked against a reference
Core evaluator. `BranchingExecutionCases.cpp` also runs a match of 200 arms on
seven subjects, from its first arm to the catch-all, an `else if` chain of
300 links, which the native stages after Core walk in a loop, on five
subjects, and programs at the nesting limits of the frontend: 255 nested
`if` statements, entered and not entered, 1023 calls nested in each other's
arguments, and a sum of 1024 operands. The nested calls are the shape that
costs most compiler stack for each level. `source_execution_smoke` ends by
printing `compiler stack committed: N KiB`, the stack its compiler thread
committed for all of its programs, so that the figure can be read from the
log of any platform that reports it: Windows, Linux and macOS.

A body that several runs share is compiled once, and up to eight small
bodies share a program. `ExecutionCases.cpp` puts each body in a method of
its own and calls it once for each run from one further method, which
compares every result with its expected value and returns a distinct bit for
each run that differs; the program must return zero from both
pipeline modes, and a result that is not zero names the runs that failed.
Compiling dominates the cost of these cases under sanitizers, and the smoke
program has a process watchdog, so the runs of a body are not worth a
compilation each.

`source_feature_smoke` runs the tables that are written by hand for single
features: methods with inferred return types, evaluation by need, arguments
passed by need and classic enums. A program that passes an argument by need
creates objects of the runtime, so each of those runs alone under the
allocation check described below. It also compiles programs that own
closures while control leaves through a block used as a value, so that the
ownership verifiers of Xpp and Xmm see those paths, and runs a hand-written
table of closures: created, called, nested, returned and alive across loop
transfers. A closure calls the AARC runtime, and the JIT resolves a runtime
symbol in the process that hosts it, so this program links the runtime and
exports its entry points. The other fuzz programs do not link it. Each
closure program runs alone, and the runtime must hold no more allocations
after it than before it, so a closure or a capture that is not released
fails the program that leaked on every platform, not only where a leak
sanitizer runs.

The branching and leaving tables are generated. Their cases are written in
`Compiler/Fuzzing/Cases/Selection.cases` and `Leaving.cases`: a body, its
runs and the value each run must return, written by hand from the language
rules. `go -C helpers run ./cmd/execution-cases generate` writes the rows
under `Compiler/Fuzzing/Generated` and the Haskell module
`BranchingEvaluationCases.hs` from them, and `check` fails when a committed
table differs; the helper tests and CI run that check. One source keeps the
two tables equal. It does not make them independent: a wrong expectation in
a case file is wrong in both. The independent checks are the hand-written
tables that do not come from these files, `ExpressionExecutionCases.cpp` and
the inferred-return table of `SourceFeatureSmoke.cpp`, the oracle tests of
`BranchingOracleTests.hs`, which compare each `match` with the `if` chain it
stands for, and the differential generator with its host model.

The tables are a program of their own because each smoke program is one
deterministic check under one process watchdog. As one program, in the
fuzzing configuration, the tables took 107 seconds and the differential
sweep 107 seconds of a 221 second run, which left no margin under the 240
second watchdog on a loaded machine; a passing second attempt was not a
fix. The watchdog is unchanged, and no case was removed. Measured on the
same Windows machine in the same configuration after the split, three runs
each: `source_execution_smoke` takes 77 to 110 seconds, of which in the run
that was broken down 23 were the expression table, 35 the branching table,
17 the leaving table and 2 the ownership programs; `source_fuzz_smoke` takes
100 to 105 seconds, of which 98 are the differential sweep. Other work ran
on the machine during these runs, so the spread is not the programs' own.
In an ordinary build each takes about 7 seconds.

The feature tables became a third program for the same reason. With the
tables for evaluation by need and enums, `source_execution_smoke` ran past
the watchdog in the fuzzing configuration. Apart, on the same Windows
machine in that configuration with nothing else running,
`source_execution_smoke` takes 91 seconds, of which 24 are the expression
table, 45 the branching table and 22 the leaving table, and
`source_feature_smoke` takes 45 seconds, of which 28 are the closure
programs. The watchdog is unchanged, and no case was removed.

`source_console_smoke` runs programs that write: console output, the
conversions of a format, and the joining and comparing of strings. Each is
compiled from source in both pipeline modes and run under the JIT with the
runtime library this program links, whose output goes to a sink instead of
the streams of the process. What a program wrote is compared with text
written by hand, and the runtime must hold no more allocations after a
program than before it, because every string is one of its objects.

The expression and leaving tables became a fourth program,
`source_expression_smoke`, when arguments came to be passed by need. Every
run of a body passes its inputs as calls, so that no stage can fold them, and
each such argument is now a suspended computation: two objects, a function
for its body and an entry it is called through. The programs of the three
tables grew with that. In an ordinary build they took 27 seconds together
where they had taken 7, and 344 seconds in the fuzzing configuration, past
the watchdog with every case passing. Three changes brought the ordinary
build to 21 seconds: a module has one entry, one destructor and one metadata
record for the callables that remember a result of one type, where it had
them for each such callable; a closure that owns nothing has no destructor;
and the native Core verifier no longer copies every visible definition for
each branch and each closure, which had made its time grow with the square
of a function's size. That was not enough for the fuzzing configuration, so
the tables are two programs. The watchdog is unchanged, and no case was
removed. What an argument by need costs in generated code is a cost of the
current lowering, listed in `EVALUATION.md`.

The source fuzz targets and the source smoke programs run the compiler on the
compiler stack, as `vxs` does, because an input nested up to the frontend's
limits does not fit on the default stack of a process. `Corpus/source` has
permanent seeds for deep nesting, for nesting at and one level beyond each
limit, for long `else if` and operator chains, which are not nesting, for
negative constant patterns, and for blocks used as values that leave with
`return`, `break` and `continue`.

The differential generator selects one of fourteen program shapes from the
byte after its generated expression, modulo the shape count. Adding a shape
therefore changes which shape an existing seed selects, so the seeds in
`Corpus/differential` are rewritten together with the count: each is a leaf
selector, a shape byte and a limit byte, and its name states the shape it is
meant to reach. Set
`VXS_FUZZ_TRACE=1` to print each generated source with its reference and
optimized LLVM IR.

Neither smoke program nor the HPC engine has libFuzzer's per-input timeout, and
a miscompiled generated loop does not return. The developer helper therefore
bounds every smoke, libFuzzer and HPC process as a whole: 240 seconds for a
smoke program, the campaign duration plus 90 seconds for a libFuzzer target and
plus 300 seconds for the HPC engine. On expiry it terminates the complete
process tree and reports a watchdog failure. Build tools are not bounded by
this watchdog. Do not run a smoke binary directly without an external time
limit when investigating a suspected hang.

## ThreadSanitizer campaign

AddressSanitizer and ThreadSanitizer cannot share one executable.
`go run ./helpers/cmd/develop fuzz-thread` builds only the targets that start
their own threads, currently `ownership_fuzzer`, with libFuzzer and
ThreadSanitizer, proves that the runtime reports an intentional data race, and
then runs a bounded campaign with the same corpus, limits and report checks.
The command fails on Windows, where Clang has no ThreadSanitizer runtime; it
never reports a skipped run as success. The fuzzing workflow runs it on macOS
and native Ubuntu. The Fedora container job does not run it for the
shadow-memory reason given below.

Compiler Tier 1/2/3 run complete native suites with ASan/UBSan. Tier 1 macOS
and Tier 2 native Ubuntu additionally run separate TSan suites. Fedora Tier 3
runs inside a GitHub Actions container; the current TSan runtime cannot reserve
its shadow memory under that host/container ASLR layout, so Fedora does not
claim TSan coverage. The native Linux TSan gate remains required in Tier 2.
Windows does not have a supported Clang TSan runtime; it is not represented by
a fabricated passing TSan job.
Stable aggregate required checks reject failed, cancelled or skipped host jobs.
The scheduled long campaign supplements rather than replaces the bounded PR
gate. Workflow declarations alone do not enforce merging: repository branch
protection must require these actual checks.

## Remaining coverage boundaries

The harnesses above are evidence about the inputs they ran, not proofs:

- the CLI, project and REPL oracles check determinism, rollback and a small
  arithmetic model. They do not model every option interaction, lockfile
  refresh, project evaluation or REPL declaration form;
- the differential generator covers integer arithmetic, three loop forms,
  one conditional statement, guarded recursion through short-circuit operators
  and through conditional expressions, truthy coalescing, five compound
  assignment operators, assignment and increment expressions, and loop
  expressions. Each of those shapes is one fixed program per trip count; the
  generator does not compose them. Closures, other scalar types,
  ownership and templates have no generated-program oracle here; their
  executable checks live in the component test suites;
- `ownership_fuzzer` varies thread count and iteration count, not arbitrary
  interleavings, and its ThreadSanitizer campaign does not run on Windows or in
  the Fedora container;
- HPC feedback is expression-tick coverage of the frontend, without
  memory-safety instrumentation, and its mutator is byte- and token-level, not
  grammar-aware;
- CorePrep parity only covers programs the mutators and the fixed smoke
  sources reach. Closures and templates have no deterministic parity source
  yet, and parity cannot detect a defect both lowerings share;
- prebuilt LLVM and the GHC runtime are not instrumented by any campaign.

Expand these deliberately instead of equating a green workflow with completion
of the entire security program.
