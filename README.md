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
→ native object and executable
```

Core, CorePrep, Xpp, and Xmm are target-independent. Their public artifact extensions are `.core`, `.xpp`, and `.xmm`;
normal compilation keeps intermediate data in memory unless explicit emission is requested.

## Supported development environments

The official native development hosts, the ones the workflows test, are Windows 10/11, macOS 26 Tahoe on Apple silicon, and Ubuntu 26.04 LTS. All hosts use:

- Bazelisk for the production C++20 graph;
- an LLVM development package containing headers, libraries, and `llvm-config`;
- GHC 9.10 or newer and Cabal for the GHC2024 Haskell frontend;
- JDK 25 for Tazel, the build system.

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
go run ./helpers/cmd/develop version 0.6.0
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
program. The ignored `dist/` tree also contains `LICENSE.txt`, `PATENTS`, the current Progmasoft exception and
patent-grant texts, and `SHA256SUMS`. See [Building](Documents/BUILDING.md#local-compiler-bundle) for the layout and
verification contract.

`benchmark` builds optimized Google Benchmark binaries for the C++20 Core, CorePrep, Xpp, and Xmm layers, then runs the
matching Criterion suite over the Haskell Core representations and wire codecs. Benchmark sources live beside the component
they measure; methodology and recorded baselines live under [Benchmarks](Benchmarks/README.md).

## Command line

Each program does one job. `talac` is the compiler: sources in, one artifact out. `tazel` is the build system and package
manager: it reads the project file and starts the compiler. `tali` is the REPL; `talafmt` and `talalint` format and lint.

Compile one file and run it:

```powershell
talac Program.tala --entry=Example.Program
.\Program.exe
```

`--entry` names the class whose parameterless `public static void Main()` starts the program. The executable is written
beside the source and takes the usual extension of the host. `--emit=core|xpp|xmm|object|assembly|llvm-ir|llvm-bitcode`
selects another artifact, and `--emit=metadata` checks a program without building it.

In a project, Tazel finds the sources and passes the compiler options of the project file:

```powershell
tazel check
tazel build
tazel run
tazel fmt -- --check
tazel lint -- --fix
```

Every command line is read by a parser written by hand that turns an accepted line into a typed value; no program uses a
command-line library. See [command-line interfaces](Documents/CLI.md) for every option and for what is not implemented
yet.

`tala-frontend` is an implementation library, not a second compiler command. `talac` loads it beside itself and calls
through a versioned C11 ABI; no frontend child process or temporary Core handoff is involved.

## Project files

A Tala project has one project file, a Kotlin script named `BUILD.kts` (or `BUILD.tzl`, `BUILD.tazel`, `BUILD`,
`Tazel.build`; the first that exists is used).

```kotlin
project {
  name = "Example"
  version = "0.1.0"
  stability = Stability.DEV
}

sources {
  executable {
    srcDir = "Sources"
    entry = "Example.Program"
  }
}
```

`sources.executable.entry` names a namespace-qualified class; its last segment is a class name and need not be `Main` or
`Program`. The class provides the parameterless `public static void Main()`; a top-level function is not an entry point.
The entry is found by namespace and class: it does not name a source file, and neither file names nor directories have to
mirror namespaces. Tazel collects every `.tala` file below `srcDir`, applies the exclusions of the project and hands the
files to the compiler as one program.

`LOCK.sqlite3` records the dependencies the project declares; `tazel lock create-dump` writes it as SQL text, to
`LOCK.dump` or to the file `--path` names.

See [project files](Documents/PROJECT_FILES.md) for the whole DSL.

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
