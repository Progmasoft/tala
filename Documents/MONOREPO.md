<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Repository layout

## Buildable components

```text
Interactive/     Tala Interactive (tali) source, owned public headers, tests, and LLJIT benchmarks
Talac/     Native talac driver, public headers, modular C++20 implementation, Haskell packages, and build support
Spec/         Public language-design example suites
third_party/  Pinned source dependencies
```

Compiler-owned public headers live physically under `Talac/Headers/Progmasoft/Tala/`. Bazel removes the physical
`Talac/Headers` prefix from consumers, so the stable include spelling remains `Tala/...`.
Tests and fixtures live below their owning component rather than in a root bucket. The superseded C23/LIL implementation
has been removed; current compiler code has no legacy include boundary.

## Compiler tree

The compiler is decomposed by ownership rather than stored in one `src` directory:

```text
Talac/
├── ADTs/                  focused tests for compiler-owned LLVM ADT adapters
├── Analysis/              shared native dataflow implementations and tests
├── Backend/LLVM/          verified Xmm-to-LLVM lowering and target emission
├── Build/Bazel/           toolchain discovery and narrow build support
├── Cli/
│   ├── Arguments/         typed command/option schema
│   └── Commands/          command dispatch
├── Codegen/Xpp/           Xpp lowering, optimization, and verification
├── Codegen/Xmm/           Xmm lowering, optimization, and verification
├── Core/                  native Core reader/verifier and CorePrep adapter
├── Driver/                connected Core-to-native coordination
├── Haskell/
│   ├── Syntax/            tokens and AST vocabulary
│   ├── Frontend/          Lexer through Desugarer
│   ├── Core/              Core/CorePrep, optimization, verification, codecs
│   ├── Driver/            source loading and verified CorePrep
│   ├── Tooling/           tala-tooling: the modules tools build on
│   └── Host/              the shared library talac loads, and the frontend fuzzer
├── Headers/Progmasoft/Tala/ public/native interface headers
└── Linker/                typed LLD execution
```

The directory names are architectural seams even though Talac is the only public compiler command. The current distribution
also stages the private Haskell `tala-frontend` shared library beside it; splitting native components does not create additional
publicly installed frontend/backend tools.

### Allowed dependency direction

```text
Cli -> Commands -> Driver / Linker
Driver -> Core -> Xpp -> Xmm -> LLVM backend
Haskell Driver -> Frontend -> Syntax
Haskell Driver -> Core
```

Reverse dependencies are avoided. LLVM does not call the CLI; Core does not depend on Xpp; Syntax does not depend on the
build system; public headers do not expose private LLVM handles. Shared code belongs in the narrowest package that does
not reverse this direction.

## Build ownership

Bazel owns top-level native orchestration. `helpers/cmd/develop/main.go` is a thin, portable user interface over that graph for
host discovery, suite execution, and sanitizers; it defines no targets or dependency edges of its own. Language-specific CI
jobs call Cabal directly, and the repository carries neither CMake configuration nor a second build graph such as
`just`.

## Nested repositories

The website and IDE are maintained as separate repositories beneath the local working directory. They are not part of the
root Git index or root Bazel graph.

## Generated directories

Build products, Cabal `dist-newstyle`, website distribution files, and local service state are
generated or local-only data and are not source ownership boundaries.

Typical disposable paths include `bazel-*`, `dist-newstyle`, `build`, website package-manager output,
IDE caches, and local service databases. Their presence must not influence source discovery, tests, release content, or
documentation claims.

## Specification ownership

`Spec/` is grouped by language responsibility:

```text
Spec/
├── Language/              syntax and core language behavior
├── StandardLibrary/       System surfaces and library contracts
├── Libraries/Databases/   provider and database APIs
└── Interop/               FFI and inline assembly boundaries
```

Each `.tala` file is a topic suite of independent examples. Its directory structure improves navigation and does not impose a
namespace-to-file mapping on the compiler.

## Repository boundaries

The root index contains the compiler, Interactive, the specification, tests, shared headers, and helpers. Local
website, IDE, and service directories may be nested beneath the checkout while remaining separate repositories or ignored
deployment state. A root change must not assume that committing the root automatically commits or deploys those children.

Go is the only implementation language for developer helpers. The independently
buildable `helpers/` module owns `cmd/<tool>/` entry points and responsibility-based
`internal/` packages. The root workspace selects this module without introducing
a root module or another compiler build graph. Helpers use Cobra where typed
subcommands and flags are needed. Bazel and Cabal retain build ownership.
See [Developer helpers](../helpers/README.md) for commands and package boundaries.

## Placement checklist

Before adding a directory or target, ask:

1. Which representation or user-facing product owns the behavior?
2. Which language is authoritative for that stage?
3. Does the new dependency follow the allowed direction?
4. Is this shipped source, a test, build support, generated output, or local deployment state?
5. Can the file remain under 1500 lines through responsibility-based decomposition?
6. Does a public header need the stable `Tala/...` include spelling?
7. Would the placement accidentally revive a retired compiler route or prototype name?

The goal is a monorepo made of coherent subprojects, not a flat directory and not several competing implementations of the
same semantic stage.
