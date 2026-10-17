<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Compiler architecture

## Target pipeline

```text
.tala source
→ Lexer
→ Parser
→ Parsed AST
→ Renamer
→ Name Resolution
→ Resolved AST
→ Type Checker
→ Typed AST
→ Desugarer
→ Core
→ Specialization Demand Planning
→ Core Optimizer
→ CorePrep
→ Xpp
→ Xpp Optimizer
→ Xmm
→ Xmm Optimizer
→ LLVM bitcode
→ object file
→ native executable
```

Stage ownership is deliberate:

- Lexer through CorePrep belongs to Haskell.
- Xpp, Xmm, and the native lowering boundary belong to C++20.
- LLVM types and handles belong only to the backend.
- The retired Rust and C implementation trees are absent from the build and source graph.
- AARC exposes a C11 `.h` ABI for stable metadata, opaque ownership handles, and unmangled symbols; its runtime and C++
  convenience API are implemented in C++20. This is a language boundary, not a retained C implementation layer.

## Component ownership

| Component | Language/build owner | Responsibility |
| --- | --- | --- |
| `Talac/Haskell/Syntax` | Haskell/Cabal | positioned tokens and parsed AST vocabulary |
| `Talac/Haskell/Frontend` | Haskell/Cabal | Lexer, Parser, Renamer, Name Resolution, Type Checker, and Desugarer |
| `Talac/Haskell/Core` | Haskell/Cabal | Core/CorePrep models, specialization-demand planning, optimization, verification, and codecs |
| `Talac/Haskell/Driver` | Haskell/Cabal | source loading, namespace merge, entry selection, and frontend process |
| `Talac/Haskell/Tooling` | Haskell/Cabal | `tala-tooling`: the modules the formatter, the linter and the analyzer build on, and nothing else |
| `Talac/Core` | C++20/Bazel | bounded Core reader, verifier, and CorePrep adapter |
| `Talac/Codegen/Xpp` | C++20/Bazel | CorePrep-to-Xpp lowering, optimization, and verification |
| `Talac/Codegen/Xmm` | C++20/Bazel | Xpp-to-Xmm lowering, optimization, and verification |
| `Talac/Backend/LLVM` | C++20/Bazel | verified Xmm lowering, LLVM optimization, serialization, and target emission |
| `Talac/Linker` | C++20/Bazel | typed LLD invocation and executable validation |
| `Talac/Cli` | C++20/Bazel | command schema, dispatch, output, and exit status |
| `Interactive/` | C++20/Bazel | `tali` REPL, isolated frontend cells, ORC LLJIT session, tests, and benchmarks |
| `Tazel/` | Kotlin/Gradle | `tazel`: project DSL, plugins, source discovery, SQLite lockfile, and the commands that start the tools |

This table is a dependency rule as well as a directory map. The frontend must not include LLVM concepts. LLVM must not parse
source syntax. The compiler must not know projects: Tazel finds the `.tala` files of a target and names them on the
compiler's command line. Each command line coordinates its owners but does not duplicate their semantic decisions.

## Frontend stages

The frontend does not use one mutable syntax tree for every pass. Parsed, renamed, resolved, and typed forms are distinct
types. Renaming assigns stable identities within lexical scope; name resolution binds references; type checking validates
expressions, calls, conditions, returns, and assignments; desugaring produces target-independent Core.

CorePrep converts nested Core expressions into explicit atoms and operations, then represents control flow with basic blocks
and terminators. A verifier rejects malformed symbols, blocks, branch targets, and unresolved types before native lowering.

Core optimization is a verified fixed-point pipeline rather than a single expression rewrite. Immutable literal propagation,
range-safe integer folding, effect-preserving branch cleanup, and declaration-aware backward liveness run before CorePrep.
Each enabled pass emits deterministic typed metrics, and the final tree is verified again. The detailed contracts are in
[Core IR](CORE-IR.md), [Core optimization](CORE-OPTIMIZER.md), and
[Core safe-expression inlining](CORE-INLINING.md).

Specialization-demand planning runs on verified Core before that optimization
pipeline. It is Haskell-owned because template identity, source semantics, and
future declaration selection must be settled before CorePrep and native Xpp.
The current graph closes concrete type dependencies and provides deterministic
emission order; it does not yet represent completed declaration cloning.

## Native middle end

Xpp is a target-independent typed representation consumed from verified CorePrep. Its stage verifier checks optimized
control flow, storage declarations, typed operands, call identity, and terminators before Xmm is constructed. Xmm then lowers
verified Xpp into a lower-level virtual-register model and verifies register storage, signatures, instruction shapes, calls,
results, and control flow before the backend boundary. Function identities, signatures, instruction result types, and the
distinction between function symbols and ordinary registers remain explicit across both stages. Lowering, optimization, and
verification are owned by separate Xpp/Xmm translation units and remain independent of LLVM.

Core has a shared versioned `TACR` binary contract and equivalent semantic verifiers in Haskell and C++20. The native reader
decodes a bounded `.core` document, verifies it, and applies a dedicated Core-to-CorePrep adapter before Xpp lowering. The
adapter atomizes nested calls and primitive expressions, creates deterministic temporary symbols, and makes branches and
joins explicit without optimizing or reconstructing types. Core, CorePrep, Xpp, and Xmm retain the ordered project source
catalog and the owner of each function, so project object and assembly builds can partition native definitions without
guessing from symbol names. CorePrep can also cross the in-process frontend boundary through the separate internal `TACP`
contract. Both transports enforce resource and Unicode-scalar limits. CorePrep exists only in RAM and has no file
extension, artifact API, CLI input, or emit option.

## Verification boundaries

Every representation is verified at the boundary that owns it:

```text
Typed AST --desugar--> Core --Core verifier--> TACR
TACR --bounded reader/Core verifier--> CorePrep --CorePrep verifier-->
Xpp --Xpp optimizer/verifier--> Xmm --Xmm optimizer/verifier-->
LLVM module --LLVM verifier--> target artifact
```

Verification is intentionally repeated across process and library boundaries. A `.core` file may come from the maintained
frontend or another producer; an embedding client may construct native IR directly; an optimizer may introduce an invalid
CFG even when its input was valid. No stage treats validation by an earlier, optional caller as proof.

Stable `SymbolId` identity is preserved from semantic binding through CorePrep and the native IRs. Human-readable spelling is
diagnostic metadata, not a replacement identity. Function symbols remain distinct from local values and Xmm registers.

## Backend

LLVM is the compiler backend. It consumes Xmm only after the Xmm-owned verifier succeeds and repeats that verifier through a
compatibility adapter for direct embedding clients. It then constructs an LLVM module, lowers supported scalar and
control-flow operations, runs the selected LLVM optimization pipeline, verifies the resulting module, and serializes LLVM IR
and bitcode in memory. Tala `String` constants retain Unicode scalar (`i32`) storage and are materialized through the
AARC string factory instead of a UTF-8 or embedded value-struct ABI. Object headers, closure destruction, and ownership
operations follow the [AARC ABI](AARC-ABI.md). LLVM types and handles do not escape the backend API.

The Bazel graph discovers LLVM through `LLVM_ROOT` or `llvm-config`. The renewed C++20 backend uses LLVM's C++ IR, bitcode, support,
new-pass-manager, target-machine, and native-code-generation libraries; LLVM C handles do not enter this pipeline. A target
machine emits COFF objects or target assembly from verified Xmm. The C++20 driver passes a typed argument vector directly
to LLD, without a shell or DIMCLI, and validates the resulting executable.

`Interactive/` reuses that same lowering route rather than interpreting AST nodes itself. Each input cell is wrapped in a
compiler-valid namespace and method, parsed and type-checked by the Haskell frontend process, then moved through verified
Core, CorePrep, Xpp, Xmm, LLVM bitcode, and one process-local ORC `LLJIT`. The JIT keeps explicit resource trackers so a REPL
reset removes code and symbols rather than merely forgetting the last displayed value. Only result types with a deliberate
host calling convention are invoked; aggregates are not guessed or coerced into machine integers.

## Entry point

Project entry selection names a namespace-qualified class. That class must contain:

```text
public static void Main()
```

The method has no parameters and returns `void`. Top-level runtime functions and integer-returning `Main` methods are not
valid project entry points.

Entry lookup starts from namespace/type identity in the complete discovered source set. It never derives a path such as
`Namespace/Main.tala`, and it never requires the final class name to be literally `Main` or `Program`. Those are conventional
class names only; the selected class may have another valid Tala name as long as its method contract is correct.

## Intermediate artifacts

The current public artifact names are:

```text
.core
.xpp
.xmm
```

Normal compilation keeps these representations in memory. Haskell writes real `.core` artifacts and C++20 consumes them
through the full verified pipeline. Explicit `.ll`, `.bc`, `.o`, and `.asm` emission is available after source or Core
input. Binary emission adds the platform entry bridge, writes a temporary object, links one executable, and removes the
temporary object. Bounded Xpp/Xmm v7 readers and writers support verified forward pipeline resumption.

## Process and temporary-file model

The private frontend library is located relative to `talac` in the build or installed layout. The current working directory
is project input, not an executable search mechanism. The driver owns in-memory Core buffers plus temporary link artifacts through scoped
cleanup objects so partial runs do not leak files or accidentally reuse an older artifact.

`tazel run` executes only the executable produced by its current successful build. A failed compile or link cannot fall through to
an executable left by a previous invocation. Tazel and the compiler are separate processes that share no memory and no
private format: Tazel passes arguments and reads the exit code.

## Extension points

The Kotlin project plugin API extends project configuration and deterministic plan metadata. It is trusted JVM build logic,
not a compiler backend API. A CMake DSL plugin may remain available for projects that need CMake integration even though the
Tala compiler itself uses Bazel.

Analyzer, Formatter, and Linter share frontend/source-policy contracts but remain independently versioned products. They do
not become compiler passes merely because `tazel fmt` and `tazel lint` dispatch them for a project.

## Architecture constraints

- One shipped `talac` command coordinates frontend and backend; frontend/backend are not separate user binaries.
- `tazel` starts `talac`, `talafmt` and `talalint` as programs; it is never linked into them and they never read a
  project file.
- CorePrep remains internal and cannot appear in `--emit` or `--build`.
- Public artifacts require an explicit, versioned reader/writer contract.
- Machine-specific LLVM installation paths never enter tracked files.
- Native C++ uses the LLVM C++ API and `Tala` naming for renewed code.
- New compiler behavior belongs to the maintained Haskell or C++20 owner; removed Rust and C routes are not restored.
