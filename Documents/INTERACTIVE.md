<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Tala Interactive

Tala Interactive is the expression-oriented REPL distributed as `tali`. It is a user of the compiler, not a second
language implementation: source cells enter the maintained Haskell frontend and then follow the production native
pipeline. The public compiler remains the Talac command.

## Invocation

```text
tali
tali --eval "5 + 5"
tali --help
```

`tali` is a program of its own; the compiler has no command that starts it.

The repository's native bundle stages Talac, `tali`, and the private `tala-frontend` shared library together. `tali`
loads the shared library beside its own executable. The library is not a user-facing compiler, and an unrelated copy on
`PATH` cannot override it.

Its command-line grammar is deliberately small:

| Form | Behavior |
| --- | --- |
| `tali` | Start the line-oriented REPL. |
| `tali --eval <expression>` | Compile, execute, print, and exit after one expression. |
| `tali --help`, `tali -h` | Print the REPL command and result-ABI help. |

Options are case-sensitive. The command accepts one `--eval` argument, so quote expressions containing spaces in the
invoking shell. Empty expressions, extra arguments, unknown flags, and a missing expression are errors. One-shot failures
return nonzero; successful scalar and `void` evaluations return zero.

## Interactive commands

Every non-command input line is treated as one complete Tala expression. REPL commands begin with `:` and are not
passed to the language parser:

| Command | Effect |
| --- | --- |
| `:help` | Print supported invocation forms, commands, and current scalar ABI limits. |
| `:type <expression>` | Run the frontend and stop after verified Xmm; do not add or invoke a JIT module. |
| `:history` | Print the most recent successfully evaluated expressions. |
| `:reset` | Remove all session JIT modules and symbols, clear `taliPrevious` and history, and restart cell numbering. |
| `:quit` | Exit successfully. |
| EOF | Exit successfully, including Ctrl+D/Ctrl+Z in the interactive terminal. |

An unrecognized colon-prefixed line reports a command error and leaves the session available. A source diagnostic also
leaves the session available; one malformed cell does not terminate the REPL. Empty lines are ignored. The history stores
at most 256 successful evaluation inputs, not failed expressions or `:type` queries. Reset removes its entries.

The current input contract is one source expression per line with a 1 MiB maximum. The REPL drains and rejects an
overlong line without retaining its contents. It does not accumulate incomplete multi-line declarations or
provide a command to define classes/functions for later cells. Use a `.tala` source file compiled with `talac` for declarations,
projects, entry-point execution, or input that requires more than one expression in a cell.

## Cell compilation

For each line, the host constructs a small source unit in memory whose final expression is inside a class method. The
generated namespace contains a monotonically increasing cell identity. This gives the ordinary resolver and Core symbol
machinery a proper class/function identity without adding top-level functions or a parser special case for REPL input.

The host calls the private Haskell `tala-frontend` shared library through its versioned C11 ABI. The frontend parses,
resolves, type-checks, and desugars the generated source, then lends verified Core bytes to a synchronous callback; the host
copies them into owned memory before running the production C++ pipeline. Source and Core stay in memory, without a
frontend child process or temporary source/Core file:

```text
generated source
→ Haskell Lexer / Parser / Renamer / Name Resolution / Type Checker / Desugarer
→ verified Core
→ CorePrep adapter and verifier
→ Xpp lowering, optimization, and verification
→ Xmm lowering, optimization, and verification
→ LLVM module verification and bitcode
→ ORC LLJIT module addition, symbol lookup, and typed invocation
```

No REPL-specific arithmetic evaluator exists. Unsupported syntax, unresolved names, type errors, invalid Core, failed
lowering, JIT loading errors, and unsupported invocation types fail through their owning stage. `:type` uses the same source
front end and type checker but stops at Xmm; it reports the return type without creating JIT code or executing the
expression.

The frontend is a shared library initialized once by the `tali` process. Every cell uses the same typed C11 callback
boundary and maintained Haskell passes; no duplicate parser or shortcut around semantic analysis is embedded in the REPL.

## Session model

One `tali` process owns one LLVM ORC `LLJIT`. Each successful executable cell receives a unique namespace and function
symbol and is added to the same JIT session. The frontend work and LLVM lowering happen per cell; the target machine,
execution session, and process symbol resolver are initialized once.

The current model carries one value between cells through a generated `taliPrevious` local binding. This is an ordinary
case-sensitive Tala identifier, not a new language feature: bare `_` is reserved for discard and wildcard syntax in
`Spec/`. The REPL does not persist AST declarations, user locals, or arbitrary object graphs. When a value can be
represented exactly as a source literal of its original type, the next cell declares `taliPrevious` with that original
type and spelling. This means the next cell still receives fresh name resolution, type checking, Core verification, and
lowering. A wider or non-scalar result remains printable where supported but is not silently narrowed into the binding.

`taliPrevious` is absent before the first successful value-producing cell. Evaluating `void` clears it. A failure does
not replace a previous successful value. A `:type` query does not execute and does not change the last value. `:reset`
clears the previous value, successful history, cell counter, and ORC resource trackers; it does not exit or reconstruct
the OS process.

The JIT API accepts only bounded, verified LLVM bitcode. Each added module receives its own ORC resource tracker. The
session serializes add, lookup, invocation, and reset operations with a mutex so a future host embedding cannot race an
ORC mutation. Module addition failures preserve modules already loaded. Reset removes trackers in reverse insertion order;
if ORC reports a removal failure, the command reports it instead of claiming the session was cleared.

## Result ABI

The frontend determines the Tala type. The host passes that exact type to the invocation boundary, which selects a
matching zero-argument native function-pointer signature. It never invokes generated code through an `int64_t` fallback.

Current callable results are:

| Tala result | Host payload | Can feed `taliPrevious` into the next cell? |
| --- | --- | --- |
| `void` | no payload | No; clears the previous value. |
| `bool` | `bool` | Yes. |
| `char` | `char32_t` | Yes, using an escaped Unicode scalar literal. |
| Signed integer through 64 bits | `std::int64_t` with retained source type | Yes, if its source-width range is preserved. |
| Unsigned integer through 64 bits | `std::uint64_t` with retained source type | Yes, if its source-width range is preserved. |
| `sfloat` / 16-bit float | Not yet callable | No. |
| `lfloat` / 32-bit float | `double` payload containing the exact `float` result | Yes, via a round-tripping 32-bit literal. |
| `float` / 64-bit float | `double` | Yes, via a round-tripping 64-bit literal. |
| `longint`, `ulongint`, `double`, aggregates, strings, closures | Not yet callable | No. |

The names and widths in this table follow the compiler's scalar catalog; they are not C# or C++ aliases. In particular,
`long` is the Tala 32-bit signed scalar and `int` is its 64-bit signed scalar. The REPL does not invent a second type
mapping.

There is currently no declared Tala to platform ABI for arbitrary aggregates or user functions. The JIT surface
therefore invokes only a generated zero-parameter cell function with a supported scalar or `void` result. Extending it to
objects, closures, strings, exceptions, or user-provided parameters requires a stable language ABI and ownership contract;
passing a guessed C++ struct layout is not an acceptable shortcut.

## In-memory ownership and runtime safety

Generated cell text is passed directly to the Haskell frontend. Its strict `ByteString` owns encoded Core until the
synchronous callback returns; the C++ receiver copies that bounded buffer before the frontend call completes and passes
the copy through the same Core wire verifier used by file-based compiler paths. Neither a temporary `.tala` nor `.core` file
is created.

The shared-library path for `tala-frontend` comes from the running `tali` image. Initialization happens outside loader-lock
callbacks; shutdown occurs only after synchronous calls have finished. A missing frontend, malformed source, failed library
load, invalid Core, failed module lookup, or unsupported ABI produces a diagnostic and never a success result.

JIT execution runs in-process. As with any compiler REPL, evaluating untrusted programs can execute arbitrary native code
with the current user's authority. `tali` intentionally does not claim to provide a sandbox, process isolation, memory
quota, or security boundary.

On Windows the ORC session links each object into one contiguous memory reservation. Win64 unwind tables use
image-relative relocations that the runtime linker can apply only when no section of an object lies below the lowest one;
with separately mapped sections the operating system chooses that order, and some address layouts abort linking with
"relocation requires an ordered section layout". The failure is layout dependent and was observed once in a hosted
AddressSanitizer run; it has not been reproduced locally, so the reservation removes the cause rather than a
demonstrated repeatable failure. Other hosts keep LLJIT's default linking layer.

## Build and verify

The native targets belong to the repository root, matching the feature's ownership tree:

```text
Interactive/
├── Headers/Progmasoft/Tala/Interactive/
├── Runtime/
├── Tests/
└── Benches/
```

Build the executable, its test, the C++ CLI parser test, and ORC backend tests with:

```powershell
bazelisk build //Interactive:tali `
  //Interactive/Tests:interactive_tests `
  //Talac/Cli/Tests:cli_parser_tests `
  //Talac/Backend/LLVM/Tests:llvm_backend_tests
```

On Windows, execute the generated test binaries directly from PowerShell rather than relying on Bazel's POSIX shell test
launcher. The root `helpers/cmd/develop/main.go test` command includes the Interactive and ORC suites in the complete native matrix.
The bundle command additionally builds the Cabal frontend, stages all three executables, and performs these integration
checks:

1. run `tali --eval "5 + 5"` with the staged `tali` discoverable only through the bundle `PATH`;
2. check that both dispatch and direct one-shot evaluation return a typed `10` result;
3. verify the no-`tali`-on-`PATH` diagnostic and prove the working-directory decoy is ignored;
4. start the no-argument REPL with piped input, reject and drain an overlong line, then keep reading;
5. type-check, evaluate a previous-cell binding, recover from a failed type check, inspect history, and reset JIT symbols;
6. verify the old binding is gone after reset, the history cap/order is correct, and the process exits on `:quit`.

The component benchmark in `Interactive/Benches/` measures a representative CorePrep-to-Xmm-to-LLVM cell lower, ORC
module-add, native invocation, and resource-reset cycle. It excludes the Haskell process startup and terminal rendering, so
it is not a measure of end-to-end interactive latency. Use the bundle smoke test to check functionality, and use the
optimized Google Benchmark job for comparable native timing.

## Extension checklist

Before extending the interactive surface:

1. Read the current language contract in `Spec/`; do not add REPL-only syntax.
2. Keep source parsing and type checking in the maintained Haskell frontend.
3. Keep Core, CorePrep, Xpp, Xmm, LLVM, and wire verification at their existing ownership boundaries.
4. Add a result representation only after specifying its exact host ABI and failure behavior.
5. Preserve the original signedness, width, and floating precision when generating `taliPrevious`.
6. Make reset release generated code and symbols, not only user-visible state.
7. Bound source and artifact sizes before allocation or JIT insertion.
8. Test both direct `tali` parsing and argument-transparent `tali` dispatch.
9. Include bundle-level frontend/JIT smoke coverage for newly connected behavior.
10. Run the benchmark in an optimized profile and report host/compiler details before comparing numbers.

Do not introduce a private expression evaluator, a second grammar, source-to-C++ translation, or implicit object-layout
assumptions to make a demo appear to work. A feature is connected only when the generated program traverses the real
frontend and verified compiler pipeline.
