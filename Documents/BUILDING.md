<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Building Visual X#

The repository has one native build graph: Bazel. The portable Go developer command provides host detection, toolchain
diagnostics, native-suite execution, and sanitizer selection without becoming a second graph. Cabal and Gradle remain the
direct build interfaces for their Haskell and Kotlin ownership boundaries.

## Official hosts

Official Visual X# development is supported on:

- Windows 10 and Windows 11, using standalone LLVM `clang-cl` and LLD;
- macOS 15 Sequoia, using Clang/LLD and the Apple SDK; and
- macOS 26 Tahoe, using Clang/LLD and the Apple SDK;
- Ubuntu 26.04 LTS, using Clang/LLD and LLVM development packages; and
- Fedora 43 (the Fedora N-1 release as of September 2026), using Clang/LLD and LLVM development packages.

Bazel chooses `windows`, `macos`, or `linux` settings automatically. A developer does not pass an OS-specific `--config`.
Visual Studio-bundled compilers are not part of the Windows toolchain, and the full Xcode IDE is not a
macOS prerequisite.

Required tools:

- Bazelisk;
- Clang and LLD from an LLVM installation appropriate to the host;
- an LLVM development package containing LLVM headers, libraries, and `llvm-config`;
- GHC 9.10 or newer and Cabal; every maintained Haskell component uses the `GHC2024` edition;
- JDK 25; and
- the Kotlin command used by project-evaluator tests.

Windows additionally needs Windows SDK headers/import libraries and MSVC CRT/STL development files. These provide platform
headers and libraries only; ClangCL, LLD, and Bazelisk remain independent tools. macOS needs the Xcode Command Line Tools,
which provide `xcrun` and the selected Apple SDK. Linux needs the distribution's LLVM development and link packages.

## Host bootstrap

Inspect a machine without changing it:

```powershell
go run ./helpers/cmd/prebuild check
```

Install missing prerequisites on a supported host:

```powershell
go run ./helpers/cmd/prebuild install
```

On Windows the bootstrap uses exact winget package identifiers for Git, Go, Bazelisk, LLVM, and Eclipse Temurin JDK 25. GHCup has no
official winget package, so the script uses Haskell.org's documented non-interactive HTTPS PowerShell bootstrap and then
asks GHCup to select recommended GHC and Cabal releases. If Windows SDK or CRT/C++ link libraries are absent, it installs
the Build Tools workload solely for those headers and libraries; Bazel continues to select standalone ClangCL and LLD.

On macOS the bootstrap requires Homebrew, installs the corresponding formulas and Temurin JDK 25 cask, requests Xcode
Command Line Tools when missing, and delegates Haskell versions to GHCup. Homebrew's LLVM formula is keg-only; follow
Homebrew's printed shell guidance, open a new terminal, and use `LLVM_ROOT` for LLVM discovery rather than writing an
absolute path into the repository. On Ubuntu/Fedora, the bootstrap uses apt/dnf for native dependencies and the official
GHCup bootstrap for Haskell. Temurin 25 requires Eclipse Adoptium's signed package repository to be enabled first;
`prebuild.go` reports that prerequisite instead of silently substituting another JDK. Installation never edits tracked
build configuration.

After the host package manager finishes, start a new terminal and run both `prebuild.go check` and `develop.go doctor`.
Package-manager PATH changes cannot be injected back into the parent terminal that launched the bootstrap.

## LLVM discovery

Do not write a machine-specific LLVM path into the repository. Use one of these mechanisms:

- set `LLVM_ROOT` to an LLVM development installation prefix; or
- put the development package's `llvm-config` on `PATH`.

The Bazel repository rule fails during analysis if it cannot discover a complete LLVM development tree. It asks the
selected `llvm-config` for its actual include and library directories; these may live under `lib64` or a versioned
distribution path rather than immediately under `LLVM_ROOT`.

The preferred preflight is identical in PowerShell and Unix terminals:

```powershell
go run ./helpers/cmd/develop doctor
```

Doctor recognizes `LLVM_ROOT/bin/llvm-config` even when that directory is intentionally absent from global `PATH`. On
macOS it also validates the OS release and asks `xcrun` for the active SDK.

If `llvm-config` is intentionally not on `PATH`, verify that `LLVM_ROOT` names the installation prefix rather than its
`bin`, `include`, or `lib/cmake/llvm` child. The repository rule derives component paths from the prefix.

## Submodules

Initialize all nested dependencies before configuring:

```powershell
git submodule update --init --recursive
```

The native CLI uses its own typed C++20 command schema. Catch3 is the native test-framework submodule.

## Production C++20 build and tests

```powershell
go run ./helpers/cmd/develop build
go run ./helpers/cmd/develop test
```

`build` compiles `vxs`, `vxsi`, and 16 component-owned test targets (15 Catch3 suites plus the C11 AARC ABI contract).
`test` performs the same build and then executes each native program directly. This
avoids introducing Git Bash/MSYS solely for Bazel's POSIX-oriented `cc_test` launcher on Windows while retaining the same
suite set on macOS.

Before creating release artifacts, validate the exact cross-build-system version:

```powershell
go run ./helpers/cmd/develop version 0.5.1
```

The check compares `MODULE.bazel`, the changelog heading, the Haskell package, and the Kotlin project runtime using exact
release lines. If a Bazel-built `vxs` is available, its `version` output must agree as well. This Go command replaces the
retired root `release.java`; repository automation does not require a Java script runtime.

Useful component targets for incremental work are:

```powershell
bazelisk build //Compiler/Core:core
bazelisk build //Compiler/Codegen/Xpp:xpp
bazelisk build //Compiler/Codegen/Xmm:xmm
bazelisk build //Compiler/Backend/LLVM:llvm_backend
bazelisk build //Compiler/Linker:native_linker
bazelisk build //Compiler/Driver:core_pipeline
```

Bazel owns only the native graph. It does not replace Cabal for Haskell packages or Gradle for Kotlin configuration and
project evaluation.

## Language-layer tests

Haskell:

```powershell
Set-Location Compiler
cabal build all
cabal test all
Get-ChildItem Haskell -Filter *.cabal -Recurse | ForEach-Object {
  Push-Location $_.DirectoryName
  try { cabal check } finally { Pop-Location }
}
```

Kotlin:

```powershell
.\ProjectSystem\gradlew.bat -p ProjectSystem test
```

The repository wrapper pins the Gradle distribution used by the project. Use it instead of a machine-global Gradle command.
JDK 25 must be visible to the wrapper process. Kotlin Script Runner remains an external runtime requirement; it is not
embedded into `vxs`.

## Building the private frontend

The Haskell driver package produces the private frontend consumed by `vxs`. Build all compiler packages together so Cabal
selects one coherent local package set:

```powershell
Push-Location Compiler
try {
  cabal build all
} finally {
  Pop-Location
}
```

The Cabal package builds the Haskell frontend as `vxs-frontend.dll` on Windows, `libvxs-frontend.dylib` on macOS, and
`libvxs-frontend.so` on Linux. The native driver loads only the matching library beside its executable; it does not search
the project directory or accept an arbitrary library from `PATH`. The versioned C11 ABI is the only boundary, and a
synchronous callback copies output bytes into C++-owned memory before Haskell releases them.

## Local compiler bundle

Build and validate an install-shaped compiler directory with one command:

```powershell
go run ./helpers/cmd/develop bundle
```

The command performs both build-system steps deliberately: Bazel produces the C++20 `vxs` driver and Cabal produces the
Haskell frontend shared library. It then stages a fresh directory with this shape:

```text
dist/
`-- visual-xsharp-<version>-<platform>-<arch>/
    |-- vxs[.exe]
    |-- vxsi[.exe]
    |-- vxs-frontend.dll | libvxs-frontend.dylib | libvxs-frontend.so
    |-- LICENSE.txt
    |-- PATENTS
    |-- LICENSES/
    |   |-- AdditionRef-Progmasoft-Exception-1.1.txt
    |   `-- AdditionRef-Progmasoft-Patent-Grant-1.1.txt
    `-- SHA256SUMS
```

The brackets above describe the host suffix; they are not literal filename characters. The directory name records the
compiler version, host platform, and architecture so separately built bundles do not silently overwrite one another.
`dist/` is ignored generated output and is not committed.

The bundle contains two executables and one shared library. Users invoke `vxs`; the driver calls the adjacent
`vxs-frontend` library in-process through the versioned C ABI, and `vxsi` is the REPL executable that `vxs interactive`
locates on `PATH`. Do not move `vxs` without its matching library or place an unrelated library beside it.

Staging is not considered successful merely because both build systems returned zero. The bundle command invokes the
staged tools, checks the compiler version, compiles a real `.vxs` fixture to a `.vxse`, and executes that native program.
It also invokes `vxs interactive -Eval "5 + 5"` with only the staged bundle directory added to `PATH`, checks the result,
and opens/exits the no-argument REPL. It fails if either companion cannot be discovered, compilation does not produce the
expected executable, or a smoke program exits incorrectly. Finally it writes `SHA256SUMS` for all staged executables and
legal payloads. Consumers can use that manifest to
detect an incomplete or modified local bundle; it is an integrity record, not a code-signing substitute.

The legal payload is intentionally explicit. `LICENSE.txt` contains MPL-2.0, `PATENTS` identifies the applicable patent
terms, and the two versioned `1.1` files contain the current Progmasoft linking exception and patent grant. Historical
`1.0` texts in the repository are not staged as the current distribution terms.

## Build configuration

The native graph is configured by tracked Bazel files and a small environment discovery surface:

| Input | Purpose |
| --- | --- |
| `.bazelversion` | Bazelisk-selected Bazel version |
| `.bazelrc` | automatically selected Windows/ClangCL or macOS/Clang options |
| `MODULE.bazel` | module identity and native dependencies |
| `Compiler/Build/Bazel/llvm.bzl` | LLVM development-tree discovery |
| `LLVM_ROOT` | optional LLVM installation prefix |
| `PATH` | discovery of `clang-cl`, `lld-link`, `llvm-config`, and Bazelisk |

`fmt` is a normal Bazel module dependency used by the C++ CLI/driver. Progmasoft Catch3 is pinned through the recursive
`third_party/catch3` submodule and a local module override so native test sources do not depend on registry availability.
Each test target links both Catch3's compiled extensions and its Catch2-compatible runner-with-main target.

The rules_cc patch under `Compiler/Build/Bazel` is a narrow ClangCL toolchain workaround. It is not permission to accumulate
general third-party patches in the compiler tree; remove it when the selected upstream release contains the fix.

## Sanitizers

Do not memorize Bazel profile names or manually combine compile/link flags. Select the diagnostic by purpose:

```powershell
go run ./helpers/cmd/develop sanitize address
go run ./helpers/cmd/develop sanitize undefined
go run ./helpers/cmd/develop sanitize thread
```

AddressSanitizer and UndefinedBehaviorSanitizer are available on Windows, macOS, and Linux, alone or combined as
`address-undefined`. ThreadSanitizer is exposed on macOS and Linux; requesting it on Windows fails before a build and
explains the supported alternative. `go run ./helpers/cmd/develop sanitizers` lists every kind with the checker and the
Bazel configuration it selects on this host, or the reason the host does not have it; `--json` writes the list for a
script.

`go run ./helpers/cmd/develop sanitize all` runs every checker the host has, each once: the combined
`address-undefined` build, and `thread` where it exists. A kind that fails does not stop the ones after it, because the
checkers find different defects; the command prints a summary and fails if any kind did.

The command rebuilds all
native suites with matching compiler and linker instrumentation, sets fail-fast runtime options, identifies the exact suite
being executed, and returns a nonzero status at the first violation. It accepts `asan`, `ubsan`, and `tsan` as convenient
aliases.

Advanced Bazel options may follow a `--` separator, for example
`go run ./helpers/cmd/develop sanitize address -- --jobs=4`. Platform and sanitizer `--config` values are deliberately
owned by the command so compile and link instrumentation cannot accidentally diverge.

## Static analysis

```powershell
go run ./helpers/cmd/develop tidy
```

The command builds the native targets, asks Bazel for the compile action of every C++ source they depend on, and runs
`clang-tidy` with the repository's `.clang-tidy` over each first-party translation unit under `Compiler/`,
`Interactive/`, and `Benchmarks/`. Each unit is analyzed with the exact flags Bazel compiled it with, so there is no
second, hand-maintained compile database to drift. The build comes first because the analyzer needs generated and
fetched headers and, on Windows, the parameter files that hold the commands.

A finding belongs to the file it is reported in. Findings located in vendored or fetched dependency headers are counted
and printed as a total, but do not fail the run; a compiler error fails it wherever it is reported, because the unit
was then not analyzed. A first-party unit whose compile command is unavailable, an analyzer that exits unsuccessfully
without an attributable diagnostic, and an action graph without first-party sources all fail the run rather than
passing as clean. One analyzer process runs per logical processor; set `VXS_TIDY_JOBS` to change that. Bazel options
may follow a `--` separator.

The libFuzzer entry points and benchmark programs are outside the built target set and are not analyzed by this
command. The `Clang-Tidy` workflow runs it on Ubuntu for every pull request and push.

## Clean rebuilds

Generated trees are disposable. Prefer deleting only the build system's known output rather than source or workspace roots:

```powershell
bazelisk clean
Push-Location Compiler
try { cabal clean } finally { Pop-Location }
.\ProjectSystem\gradlew.bat -p ProjectSystem clean
```

For the native-only cleanup, `go run ./helpers/cmd/develop clean` performs an expunging Bazel clean.

Do not commit `bazel-*`, Cabal `dist-newstyle`, Gradle `.gradle`/`build`, IDE caches, local service state, or compiler-emitted
artifacts used only for smoke tests. Local compiler bundles below `dist/` are equally reproducible and disposable. Before
removing a large tree manually, resolve the exact absolute target and verify that it is a generated directory inside this
checkout.

## Troubleshooting

### LLVM development files are not found

An LLVM runtime installation containing only executables is insufficient. The native backend needs C++ headers, LLVM
libraries, bitcode/support/target components, and `llvm-config` metadata. Point `LLVM_ROOT` at a complete development prefix
or expose that prefix's `llvm-config` on `PATH`. Do not add `LLVM_DIR` with a personal absolute path to tracked files.

### Windows headers or CRT libraries are not found

ClangCL is the compiler, but Windows SDK and MSVC CRT/C++ development files still provide platform headers and import/static
libraries. Install those components and start a PowerShell environment that exposes their include and library directories.
The Visual Studio IDE and Visual Studio's compiler executable are not part of the Visual X# build contract.

### `clang_rt` or runtime DLL is missing

Treat a missing compiler runtime as a toolchain-layout problem. Confirm the selected ClangCL resource directory and the
runtime libraries shipped with the same LLVM version. Do not copy a random DLL beside every test executable or make a build
depend on a temporary directory.

### Private frontend is missing

Build the Haskell workspace and confirm the frontend is placed in the layout expected by `vxs`. Installing a same-named
command globally is not a supported fix because it could mismatch the Core wire contract.

For an install-shaped local layout, prefer `go run ./helpers/cmd/develop bundle`; it stages the matching Bazel and Cabal
outputs together and exercises frontend discovery before reporting success.

### `xs_lil.dll` or another retired library is requested

The production pipeline must not require retired compatibility DLLs. A request for one indicates a stale executable,
generated build tree, or old installation. Clean the owning generated output and rebuild the current Bazel/Cabal graph.

### Native test launcher requests a POSIX shell

Build the Catch3 test target with Bazel and execute the resulting `.exe` directly from PowerShell as shown above. A Git Bash
or fish installation is not a repository prerequisite.

### Link succeeds but `run` starts an old program

This is a compiler bug, not an accepted workflow. The current driver validates the artifact produced by the current
invocation. Capture the command, output path, and diagnostic, then add a native regression test; do not work around it by
pre-deleting unrelated source.

## File-size gate

Implementation, test, build, configuration, and internal source files must remain at or below 1500 lines. Topic-oriented
public `Spec/` example suites are exempt because each file aggregates independent examples.

See [Testing and verification](TESTING.md) for the full test matrix, workflow ownership, formatting checks, smoke tests, and
documentation validation.
