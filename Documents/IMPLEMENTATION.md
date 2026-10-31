<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Implementation status

## Summary

Tala now has one production source route for the implemented language subset. The C++20 Talac driver starts the private
Haskell frontend, receives bounded verified Core, and continues through CorePrep, Xpp, Xmm, and LLVM. The old C lexer/parser,
macro, HIR/MIR, and C-to-Rust syntax-packet route has been removed rather than retained as a fallback.

## Status vocabulary

| State | Meaning in this document |
| --- | --- |
| Connected | reachable through a supported command and covered by the owning tests |
| Implemented | code and focused tests exist, although the public route may stop earlier |
| Partial | a deliberately bounded subset is connected and unsupported cases fail explicitly |
| Registered | a public spelling/model exists, but execution reports that it is not connected |
| Planned | design direction only; programs cannot depend on it |
| Legacy | retained outside the production graph; no new compiler behavior belongs there |

The distinction matters most for the specification. A language rule can be designed in `Spec/`, modeled in an AST, and
still remain unavailable in native emission because a later representation has no layout or ABI contract.

## Haskell frontend

The Haskell package exposes separate modules for:

- AST;
- lexer and parser;
- renamer and name resolution;
- type checker;
- desugarer;
- Core specialization-demand discovery and graph validation;
- Core and Core optimization;
- CorePrep and CorePrep verification; and
- pipeline diagnostics and orchestration.

The current language slice covers namespace and class declarations, member methods, typed and inferred local bindings,
assignments, compound assignments, the discard statement, calls, returns, conditionals, conditional and truthy-coalescing
expressions over `bool` and numeric values, core operator precedence, entry-point validation, and basic CorePrep control flow.
Assignment, compound assignment and `++` are also expressions over named locals: `a = b = 10`, `(value += 5)`, `a++`. There
is no decrement operator; `--` always starts a comment. A `while` or classic `for` loop is an expression when a
`break value;` supplies its value. `match` is a statement and an expression over one or more `bool` or numeric subjects,
with literal, wildcard and binding patterns and guards; `if` is also an expression over two value blocks;
`guard (condition) else { ... }` runs its block when the condition is false; and a `{ ... }` at the start of a
statement is a nested block with its own scope. Null coalescing `??` and `??=`, storage
targets other than a named local, loop, conditional and match values that are not `bool`, numeric or an enum, the
`null` pattern, type patterns over class hierarchies, and bindings in conditions are not implemented. `return`,
`break` and `continue` out of a block used as a value are implemented, in loop bodies, loop headers and loops used as
expressions; "Pending branching and loop forms" below lists what is still owed.
It does not yet implement the complete language catalog in `Spec/`.

Core optimization is connected, verifier-guarded, and fixed-point driven. It performs immutable literal propagation,
exact range-checked integer/boolean folding, target-width IEEE floating-point folding, conservative algebraic identities, known/identical branch simplification,
unreachable-code removal, interprocedural effect inference, bounded capture-avoiding linear-body inlining, and
effect-aware liveness across functions and closure bodies. The inliner accepts immutable binding/evaluation prefixes,
preserves arbitrary eager arguments exactly once with fresh `CoreLet` identities, and verifies the result through
CorePrep. Unknown, recursive, allocating, and possibly failing callees remain explicit. Typed per-pass, effect, and
inlining reports expose before/after metrics, generated lets, alpha-renaming, and convergence. Floating folding uses
exact ratios and target rounding; floating `//` lowers to the specified integer result across Core, CorePrep, Xpp, Xmm,
and LLVM. Transcendental folding, CFG/mutable-body inlining, and speculative optimization remain unimplemented.

Project compilation now enters the Haskell frontend as source roots plus project-relative exclusion patterns. The frontend
owns recursive `.tala` discovery, strict UTF-8 decoding, canonical root containment, overlapping-root de-duplication, and
stable path ordering. Each physical file is parsed independently. Files declaring the same namespace are merged before the
Renamer, so duplicate declarations and cross-file members share one semantic namespace without requiring directory names to
mirror namespace segments.

Every discovered namespace passes through Renamer, Name Resolution, Type Checker, Desugarer, Core verification,
specialization-demand planning, Core optimization, Core
verification, CorePrep, and CorePrep verification. The configured namespace-qualified class then selects the one Core module
sent over the current private C ABI boundary. Cross-namespace imports and a multi-module Core link unit remain later
semantic work; an unrelated namespace is validated but is not silently folded into the entry namespace.

### Frontend coverage boundaries

The connected frontend is strongest around scalar expressions, local control flow, calls, callable literals through
CorePrep, namespace merging, and entry validation. Fixed-width integer/radix/separator behavior, character packing, numeric
boolean context, source `void`, stable `SymbolId` identity, and constant range checks are represented before Core emission.

### Pending branching and loop forms

These are parts of the specified language that the frontend recognizes and
rejects with a diagnostic that says so, or that fail in a later stage. They
are owed work, not rules: none of them is a restriction of the language, and
the specification is not changed to match them.

| Pending | Specified by | Today | Needs |
| --- | --- | --- | --- |
| a binding in the condition of `if`, `guard` or `while`, as in `guard (auto user = Find()) else { return; }` | `Spec/Language/Decls.tala`, examples 190 to 192 | `TAP0035` | optional values |
| evaluation by need beyond local bindings of scalar type: arguments, results, other types, assigned and captured variables | `Spec/Language/Evaluation.tala` | computed where they are written; see [Evaluation by need](EVALUATION.md) | thunks as values in the IR and the runtime |
| a call that does not return as a way of leaving a `guard` block or a block used as a value | example 297 | every call is assumed to return, so the block is taken to complete: `TAT0061` or `TAT0046` | a way to know that a call does not return; how that is expressed in the language is not decided here |
| a `match` over a subject that may be null | example 304 | `TAT0055` | nullable subjects |
| an enum declared inside a class | the nested declarations of section 9 | `TAP0006` | qualified type names |
| `enum class`, the enum with payloads | section 8 | not parsed | the object model |
| type patterns over class hierarchies | examples 198 to 203 | `TAT0057` | class hierarchies |

Implemented and verified through native execution, unoptimized and
optimized: `return`, `break` and `continue` out of a block used as a value,
in loop bodies; `break` and `continue` in a loop condition; `break` and
`continue` in a `for` update clause; a `break` that carries a value out of a
block used as a value to a loop used as an expression; `return` out of a
loop used as an expression, directly and from a block used as a value; an
`if` or `match` expression none of whose branches completes; classic enums,
with their numbering, member values computed from earlier members, their
comparison and `match` over them, complete
without a catch-all arm when every value is named; calls of
methods whose return type is inferred, in the same class, in another class,
through chains of such methods and through mutual recursion; the inference
of a callable's return type from returns inside its expressions; and
callables created inside callables, called, returned and kept, with the
AARC runtime that owns them.

The full `Spec/` catalog is not implemented. Object/value layout, the complete standard-library surface, cross-namespace
imports, template declaration cloning and constraint selection, exception lowering, ownership runtime operations, generators, FFI, assembly, and
many advanced declaration forms require additional semantic and native work. Unsupported forms must produce frontend or
backend diagnostics; they must not be approximated with C-family behavior.

## C++20 middle end

The repository contains:

- verified Haskell and C++20 Core models with a shared bounded `TACR` `.core` codec contract;
- a native Core semantic verifier and Core-to-CorePrep adapter that atomizes expressions and constructs explicit CFGs;
- matching bounded Haskell and C++20 internal CorePrep wire codecs;
- recursive type, symbol spelling, qualified-name, and UTF-32 string preservation;
- canonical project source catalogs and per-function ownership validated from Core through Xmm;
- RAM-only CorePrep transport; no CorePrep file extension, reader, writer, CLI input, or emit option exists;
- structural and semantic native CorePrep verifiers;
- CorePrep-to-Xpp lowering;
- Xpp control-flow, self-copy, and liveness-based dead `Define Copy` optimization;
- shared directional worklist scheduling, dense definite-initialization facts, and packed AARC ownership states;
- an Xpp-owned verifier for module/function identity, storage declarations, typed operands, and CFG targets;
- Xpp ownership placement: explicit retains and releases for every AARC value, and closures for methods used as values;
- Xpp-to-Xmm lowering; and
- Xmm virtual-register move and dead materialization optimization;
- an Xmm-owned verifier with register, signature, call, operand, result, and control-flow diagnostics, exposed through the
  existing LLVM verification API for compatibility;
- C++20 Xmm-to-LLVM lowering for the implemented scalar, call, branch, jump, and return operations;
- LLVM O0/O1/O2/O3 pass-pipeline selection followed by module verification;
- Unicode-scalar `String` constants materialized as AARC objects;
- matching case-sensitive Haskell and native nominal catalogs with recursive constructed-type ownership classification;
- AARC object headers, strong/weak/unowned runtime calls, and closure payload destructors; and
- in-memory LLVM IR and bitcode serialization with explicit `.ll`/`.bc` writers.

The production frontend boundary uses public `TACR` Core. The internal `TACP` codec remains tested for in-process and golden
contract coverage, but the CLI does not expose CorePrep. Bounded `TAPP` and `TAMM` v7 codecs now own public Xpp/Xmm disk
artifacts and forward-only pipeline resumption. LLVM target-machine emission and typed C++20 LLD invocation produce `.o`,
`.asm`, and executables. Project object and assembly requests produce one flattened output per source in the selected
entry namespace; each owner boundary verifies the source catalog, and the driver replaces the set through a recoverable
same-filesystem transaction. Remaining work includes cross-namespace Haskell name resolution and a multi-module Core link
unit.

### Native coverage matrix

| Capability | Status | Boundary |
| --- | --- | --- |
| bounded TACR v10 decode | connected | C++20 Core reader, closure records, template arguments, source ownership, and scalar payload validation |
| native Core semantic verification | connected | `Talac/Core` |
| Core-to-CorePrep atomization/CFG | connected | dedicated adapter |
| CorePrep structural/semantic verification | connected | native CorePrep verifier |
| Xpp lowering/optimization/verification | connected | C++20 Xpp packages |
| Xmm lowering/optimization/verification | connected | C++20 Xmm packages |
| fixed-width scalar/call/branch/return LLVM lowering | connected for verified Xmm | LLVM backend |
| LLVM IR and bitcode output | connected | `.ll` and `.bc` writers |
| target object and assembly output | connected for supported values | target machine |
| the executable link | connected for supported values | entry bridge plus typed LLD driver |
| closure object ABI | connected | Xpp/Xmm, LLVM, and AARC runtime boundary |
| callable that remembers its result | connected | Core, CorePrep, Xpp, Xmm and LLVM carry `Memoize`; the frontend produces it for arguments passed by need |
| runtime calls | connected | one operation with a catalog of functions in Core, CorePrep, Xpp, Xmm and LLVM |
| console output, string concatenation and equality | connected | `Console.Print`, `Println`, `Printf`, `Printfn`, the four `Error` forms and `Format`; see [Console output and strings](CONSOLE-IO.md) |
| the runtime in a native executable | connected | `tala-runtime.lib` on Windows, without a C runtime, and `libtala-runtime.a` on Linux and macOS, over the C library; the ownership and text runtime, linked with every executable |
| integer division by zero and shifts outside the width | connected | a check before the instruction stops the program |
| recursive constructed-type classification | Haskell/native semantic models complete, process connection pending | frontend and Core nominal catalogs |
| Xpp/Xmm disk codecs | connected | bounded v7 `TAPP`/`TAMM` readers and writers |
| project per-source object/assembly emission | connected for the selected namespace | source ownership through CorePrep, Xpp, and Xmm |
| TCI `-Header` | registered and rejected explicitly | export/ABI semantics and a header writer are not connected |

## Retired Rust and C implementations

The duplicate Rust compiler core and project-owned C implementation have been removed. They are not supported production
layers, reference trees, CI gates, or fallback routes. New compiler behavior is implemented once in the owning Haskell or
C++20 layer. The AARC runtime's `extern "C"` entry points remain intentionally: generated LLVM code calls that small,
versioned ABI, while its implementation, ownership, and tests are C++20.

## CLI and project evaluation

The compiler reads its command line with a typed schema written by hand: option arity, duplicate rejection, defaults, and
value conversion. It has no command-line library and knows nothing about projects.

Known gaps include:

- Core input can be checked through LLVM and can emit `.ll`, `.bc`, `.o`, `.asm`, or a native executable;
- explicit Core, Xpp, and Xmm emission from source is connected;
- Xpp and Xmm inputs decode, verify, optionally optimize, and continue forward without CorePrep exposure;
- package publication and installation require a ViGet client not linked into this build;
- cross-namespace imports and the multi-module Core link unit are not connected yet; and
- project-wide per-source object/assembly emission and named test-suite execution remain intentionally unavailable rather
  than violating their output contracts or routing through the removed frontend.

## Artifact and command matrix

| Input | `check` | Core emit | LLVM IR/BC | object/assembly | binary/run |
| --- | --- | --- | --- | --- | --- |
| explicit `.tala` | connected | connected | connected subset | connected subset | connected subset |
| project source set | connected | connected | connected subset | per-source route pending | binary connected subset |
| public `.core` | connected | not a conversion target | connected subset | connected subset | connected subset |
| `.xpp` | connected | not an earlier conversion target | connected subset | connected subset | connected subset |
| `.xmm` | connected | not an earlier conversion target | connected subset | connected subset | connected subset |
| object | not accepted | no | no | already native | build-only handling |

“Connected subset” means the route itself is real and never falls back to removed code. A source using a type or operation
without a native layout still fails before producing a misleading artifact.

## Data that is intentionally not duplicated

- Namespace identity is not encoded by directories.
- The compiler does not read project files or expand source globs; its caller names every input.
- CorePrep is not serialized as a public project artifact.
- The compiler does not contain formatter/linter rule configuration.
- JVM support does not own an Xmm reader/writer.
- Standard-library namespaces are not repeated as package dependencies.
- The native driver does not shell-join LLD arguments or use DIMCLI.

## Verification

GitHub CI runs:

- Haskell build, behavior tests, and package checks;
- Windows ClangCL Bazel build and native CLI contract tests; and
- patch hygiene checks.
