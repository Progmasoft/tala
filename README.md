<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Tala

Tala is an experimental native programming language and compiler project. This repository contains the compiler,
project DSL, runtime components, language examples, tests, and supporting developer tools.

The repository is under an architectural transition. The production `.tala` route now uses the Haskell lexer-through-Core
frontend and hands a verified `TACR` Core artifact to the C++20 CorePrep-to-Xpp-to-Xmm-to-LLVM pipeline. The previous C
lexer/parser, semantic tree, macro, HIR/MIR duplicate, Rust FFI session bridge, and DIMCLI dependency have been removed.
The retired Rust implementation and all project-owned C implementation files have also been removed; the maintained
compiler is Haskell through CorePrep and C++20 from Xpp onward.

## The name

The name comes from Tagalog and Sanskrit. In Tagalog *tala* is a bright star; in Sanskrit *tāla* is a beat, the measure
that keeps music in time. Tazel, the build system and package manager, joins Tala and Bazel.

Through version 0.2.8 the project went by the code name X#. Its first real name was Visual X#, which risked being taken
for the unrelated xBase language X#. Tala is the final name; earlier release notes keep the names they were written
with.

## Intended compiler pipeline

```text
.tala source
→ Haskell Lexer
→ Haskell Parser
→ Parsed AST
→ Renamer
→ Name Resolution
→ Resolved AST
→ Type Checker
→ Typed AST
→ Desugarer
→ Core
→ Core optimizations
→ CorePrep
→ C++20 Xpp
→ Xpp optimizations
→ C++20 Xmm
→ Xmm optimizations
→ LLVM bitcode
→ native object and .vxse executable
```

Core, CorePrep, Xpp, and Xmm are target-independent. Their public artifact extensions are `.core`, `.xpp`, and `.xmm`;
normal compilation keeps intermediate data in memory unless explicit emission is requested.

## Supported development environments

The official native development hosts are Windows 10/11, macOS 15 Sequoia, macOS 26 Tahoe, Ubuntu 26.04 LTS, and Fedora 43 (N-1 as of September 2026). All hosts use:

- Bazelisk for the production C++20 graph;
- an LLVM development package containing headers, libraries, and `llvm-config`;
- GHC 9.10 or newer and Cabal for the GHC2024 Haskell frontend;
- JDK 25 and the Kotlin runner for the project DSL.

Windows uses standalone ClangCL/LLD plus Windows SDK and MSVC CRT/STL development files. macOS uses Clang/LLD plus the
Apple SDK supplied by the Xcode Command Line Tools. Ubuntu and Fedora use Clang/LLD with their LLVM development and
system link packages. Visual Studio and Xcode IDEs are not required.

Repository configuration does not contain a machine-specific LLVM installation path. Set `LLVM_ROOT` or put
`llvm-config` on `PATH`.

On a new supported machine, the Go bootstrap can report or install the host toolchain:

```powershell
go run ./helpers/cmd/prebuild check
go run ./helpers/cmd/prebuild install
```

Windows installation uses exact winget package identities, including Temurin JDK 25, plus the official GHCup bootstrap. macOS uses Homebrew and the
Xcode Command Line Tools installer. Ubuntu/Fedora use apt/dnf and GHCup; enable Adoptium's signed repository before
installing Temurin 25 on Linux. The Windows SDK/CRT workload supplies link resources only; Tala still selects
ClangCL and LLD. Open a new terminal after installation, then run `go run ./helpers/cmd/develop doctor`.

## Build

Initialize the recursive submodules first:

```powershell
git submodule update --init --recursive
```

The portable developer command detects the host, checks its toolchain, and keeps Bazel's private configuration names out of
the normal workflow:

```powershell
go run ./helpers/cmd/develop doctor
go run ./helpers/cmd/develop version 0.5.1
go run ./helpers/cmd/develop build
go run ./helpers/cmd/develop test
go run ./helpers/cmd/develop benchmark
go run ./helpers/cmd/develop bundle
```

The same commands run from macOS and Linux terminals. Direct `bazelisk build //Talac/...` remains supported and selects the host
configuration automatically; ordinary builds never need `--config`. The Bazel graph discovers LLVM from `LLVM_ROOT` or
`llvm-config` and does not store a machine-specific installation path.

`bundle` is the reproducible local path from a checkout to a usable compiler layout. It builds the C++20 `talac` driver with
Bazel, builds its private Haskell `tala-frontend` shared library with Cabal, stages the driver, REPL, and library under
`dist/tala-<version>-<platform>-<arch>/`, and verifies that the staged pair can compile and run a real `.tala`
program as a `.vxse`. The ignored `dist/` tree also contains `LICENSE.txt`, `PATENTS`, the current Progmasoft exception and
patent-grant texts, and `SHA256SUMS`. See [Building](Documents/BUILDING.md#local-compiler-bundle) for the layout and
verification contract.

`benchmark` builds optimized Google Benchmark binaries for the C++20 Core, CorePrep, Xpp, and Xmm layers, then runs the
matching Criterion suite over the Haskell Core representations and wire codecs. Benchmark sources live beside the component
they measure; methodology and recorded baselines live under [Benchmarks](Benchmarks/README.md).

## Command-line status

The compiler executable is `talac`. Its C++20 command parser uses one typed schema for command scope, option arity, duplicate
rejection, defaults, and value conversion; it has no third-party CLI dependency. For `.tala`, `check` runs the Haskell
frontend and the complete in-memory Core/CorePrep/Xpp/Xmm/LLVM validation route. `build` produces a native `.vxse` by
default; `-Emit core|object|assembly|llvmll|llvmbc` selects another supported artifact. `run` builds and executes the
native binary. Public bounded Xpp/Xmm v3 readers and writers support verified forward pipeline resumption.
CorePrep wire bytes are never accepted under the public `.core` extension.

`tala-frontend` is an implementation library, not a second user-facing compiler command. The C++20 driver loads it beside
`talac` and calls through a versioned C11 ABI; no frontend child process or temporary Core handoff is involved.

The reliable single-file validation form is:

```powershell
.\bazel-bin\Talac\Cli\talac.exe check -File .\path\to\Main.tala
```

From a directory containing `BUILD.kts`, project validation uses the configured source roots and namespace-qualified
entry directly:

```powershell
.\path\to\talac.exe check
.\path\to\talac.exe build -Emit core
.\path\to\talac.exe format
.\path\to\talac.exe lint
```

The compiler recursively discovers case-sensitive `.tala` files, applies project-relative exclusions, merges files by
declared namespace, validates every namespace, and selects the configured entry class. It does not require namespace and
directory layouts to match.

Project-wide `format` and `lint` reuse that compiler-owned source discovery. They require the separately installed Visual
Formatter and talalint packages, respectively; the compiler does not embed either tool.

See [CLI](Documents/CLI.md) for the exact accepted surface and implementation status.

## Project files

A Tala project uses one `BUILD.kts` file. `sources.executable.entry` names a namespace-qualified class; its final
segment is a class name and need not be `Main` or `Program`. The selected class must provide a parameterless
`public static void Main()` method; a top-level runtime function is not an entry point.
The entry is resolved from namespace and type identity. It does not name a source file, and source file names or directory
layout do not have to mirror the namespace. The Kotlin runtime passes source roots and exclusions to the compiler without
walking the project for `.tala` files. The Haskell frontend now owns that discovery, strict UTF-8 decoding, deterministic
ordering, exclusion matching, namespace merge, and entry validation.

```kotlin
project {
  name = "Example"
  version = "0.1.0"
  stability = Stability.DEV
}

sources {
  executable {
    name = "Example"
    srcDir = "Sources"
    entry = "Example.Main"
  }
}
```

See [Project files](Documents/PROJECT_FILES.md) for the current Kotlin DSL.

The binary project lockfile can be inspected without changing the normal project-evaluation output. The separate `tadc`
tool evaluates `BUILD.kts` and writes deterministic, replayable SQL to the requested output path. TADC does not
require a particular output filename extension.

## Language specification examples

The [Spec](Spec/README.md) directory contains 24 topic-oriented `.tala` example suites. They record current language design
intent, including valid and invalid fragments, but they are not concatenated applications and must not be treated as a claim
that every rule is already implemented by `talac`.

The [Tala EBNF](Grammar/tala.ebnf) summarizes the concrete syntax, while the
[TextMate grammar](Grammar/tala.tmLanguage.json) provides matching editor token scopes for `.tala` files. Semantic
restrictions remain defined by `Spec/`, not by syntax highlighting.

The [comparative programs](Examples/README.md) provide ten complete examples side by side in Tala, C# 13, C++20,
and Java 21. The C# and Java variants are educational comparisons and do not add compiler-development prerequisites.

## Documentation

- [Documentation index](Documents/README.md)
- [Architecture](Documents/ARCHITECTURE.md)
- [Compiler pipeline](Documents/COMPILER-PIPELINE.md)
- [Implementation status](Documents/IMPLEMENTATION.md)
- [Building](Documents/BUILDING.md)
- [Testing](Documents/TESTING.md)
- [CLI](Documents/CLI.md)
- [Project files](Documents/PROJECT_FILES.md)
- [Diagnostics](Documents/DIAGNOSTICS.md)
- [Ecosystem tools](Documents/ECOSYSTEM.md)
- [Specification guide](Documents/SPECIFICATION.md)
- [Repository layout](Documents/MONOREPO.md)
- [Contributor onboarding](Documents/Contributing/README.md)

## License

Project-owned source files use `MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1`. The exception permits static and
dynamic linking with independent components under licenses of their choice, including proprietary licenses, without
removing MPL-2.0 obligations from covered files or modifications to those files. See `LICENSE.txt`,
`LICENSES/AdditionRef-Progmasoft-Exception-1.1.txt`, `PATENTS`,
`LICENSES/AdditionRef-Progmasoft-Patent-Grant-1.1.txt`, and `NOTICE.txt`.
