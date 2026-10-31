<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Building Tala

The repository has one native build graph: Bazel. The portable Go developer command provides host detection, toolchain
diagnostics, native-suite execution, and sanitizer selection without becoming a second graph. Cabal remains the direct
build interface for the Haskell packages.

## Official hosts

Official Tala development is supported on the hosts the workflows test:

- Windows 10 and Windows 11, using standalone LLVM `clang-cl` and LLD (CI tests it on Windows Server 2025);
- macOS 26 Tahoe on Apple silicon, using Clang/LLD and the Apple SDK; and
- Ubuntu 26.04 LTS, using Clang/LLD and libc++ from the distribution and LLVM built with libc++.

macOS 15 Sequoia, macOS on Intel and Fedora 43 are no longer tested by the workflows. The helpers still recognize them
(`develop`, `prebuild` and `develop llvm` keep their setup for Fedora 43), so a build there may work, but it is not an
official host.

Bazel chooses `windows`, `macos`, or `linux` settings automatically. A developer does not pass an OS-specific `--config`.
Visual Studio-bundled compilers are not part of the Windows toolchain, and the full Xcode IDE is not a
macOS prerequisite.

Required tools:

- Bazelisk;
- Clang and LLD from an LLVM installation appropriate to the host;
- an LLVM development tree containing LLVM headers, libraries, and `llvm-config`. On Linux it is LLVM built with
  libc++, which the developer helper downloads; see [LLVM discovery](#llvm-discovery);
- GHC 9.10 or newer and Cabal; every maintained Haskell component uses the `GHC2024` edition;

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

On Windows the bootstrap uses exact winget package identifiers for Git, Go, Bazelisk, LLVM, and Podman. GHCup has no
official winget package, so the script uses Haskell.org's documented non-interactive HTTPS PowerShell bootstrap and then
asks GHCup to select recommended GHC and Cabal releases. If Windows SDK or CRT/C++ link libraries are absent, it installs
the Build Tools workload solely for those headers and libraries; Bazel continues to select standalone ClangCL and LLD.

On macOS the bootstrap requires Homebrew, installs the corresponding formulas, requests Xcode
Command Line Tools when missing, and delegates Haskell versions to GHCup. Homebrew's LLVM formula is keg-only; follow
Homebrew's printed shell guidance, open a new terminal, and use `LLVM_ROOT` for LLVM discovery rather than writing an
absolute path into the repository. On Ubuntu, Debian 13 and Fedora, the bootstrap uses apt/dnf for native dependencies and the official
GHCup bootstrap for Haskell. Installation never edits tracked
build configuration.

After the host package manager finishes, start a new terminal and run both `prebuild.go check` and `develop.go doctor`.
Package-manager PATH changes cannot be injected back into the parent terminal that launched the bootstrap.

## LLVM discovery

Do not write a machine-specific LLVM path into the repository. Use one of these mechanisms:

- set `LLVM_ROOT` to an LLVM development installation prefix; or
- put the development package's `llvm-config` on `PATH`.

Linux builds with libc++, as macOS does, and the backend passes standard library types through LLVM's C++ API, so it
links an LLVM built with libc++ as well. The LLVM packages of Ubuntu and Fedora are built with libstdc++ and cannot be
used. Install Clang, LLD, libc++ and zstd from the distribution (`prebuild install` does), then let the helper fetch
LLVM:

```bash
go run ./helpers/cmd/develop llvm
```

It downloads LLVM 22.1.6 built with libc++ for the host from the toolchain release of the repository, refuses the
archive unless its SHA-256 is the one `helpers/internal/development/llvm_toolchain.go` records, unpacks it below
`TALA_LLVM_CACHE` (default: `tala/llvm` in the user cache directory) and prints its root. The build, test, sanitize,
fuzz and bundle commands do the same by themselves when `LLVM_ROOT` is not set, so a Linux checkout needs no LLVM
setting at all. The archives are built by the `LLVM with libc++` workflow, for x86-64 only so far; a published archive
is never replaced, and a rebuild is published under a new revision with new digests.

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

`build` compiles Talac, `tali`, and 16 component-owned test targets (15 Catch3 suites plus the C11 AARC ABI contract).
`test` performs the same build and then executes each native program directly. This
avoids introducing Git Bash/MSYS solely for Bazel's POSIX-oriented `cc_test` launcher on Windows while retaining the same
suite set on macOS.

Before creating release artifacts, validate the exact cross-build-system version:

```powershell
go run ./helpers/cmd/develop version 0.2.0
```

The check compares `MODULE.bazel`, the changelog heading, and the Haskell package using exact
release lines. If a Bazel-built Talac is available, its `version` output must agree as well. This Go command replaces the
retired root `release.java`; repository automation does not require a Java script runtime.

Useful component targets for incremental work are:

```powershell
bazelisk build //Talac/Core:core
bazelisk build //Talac/Codegen/Xpp:xpp
bazelisk build //Talac/Codegen/Xmm:xmm
bazelisk build //Talac/Backend/LLVM:llvm_backend
bazelisk build //Talac/Linker:native_linker
bazelisk build //Talac/Driver:core_pipeline
```

Bazel owns only the native graph. It does not replace Cabal for the Haskell packages.

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

embedded into Talac.

## Building the private frontend

The Haskell driver package produces the private frontend consumed by Talac. Build all compiler packages together so Cabal
selects one coherent local package set:

```powershell
Push-Location Talac
try {
  cabal build all
} finally {
  Pop-Location
}
```

The Cabal package builds the Haskell frontend as `tala-frontend.dll` on Windows, `libtala-frontend.dylib` on macOS, and
`libtala-frontend.so` on Linux. The native driver loads only the matching library beside its executable; it does not search
the project directory or accept an arbitrary library from `PATH`. The versioned C11 ABI is the only boundary, and a
synchronous callback copies output bytes into C++-owned memory before Haskell releases them.

## Local compiler bundle

Build and validate an install-shaped compiler directory with one command:

```powershell
go run ./helpers/cmd/develop bundle
```

The command performs both build-system steps deliberately: Bazel produces the C++20 Talac driver and Cabal produces the
Haskell frontend shared library. It then stages a fresh directory with this shape:

```text
dist/
`-- tala-<version>-<platform>-<arch>/
    |-- talac[.exe]
    |-- tali[.exe]
    |-- tala-frontend.dll | libtala-frontend.dylib | libtala-frontend.so
    |-- LICENSE.txt
    |-- PATENTS
    |-- LICENSES/
    |   |-- AdditionRef-Progmasoft-Exception-2.0.txt
    |   `-- AdditionRef-Progmasoft-Patent-Grant-1.1.txt
    `-- SHA256SUMS
```

The brackets above describe the host suffix; they are not literal filename characters. The directory name records the
compiler version, host platform, and architecture so separately built bundles do not silently overwrite one another.
`dist/` is ignored generated output and is not committed.

The bundle contains two executables and one shared library. Users invoke Talac; the driver calls the adjacent
`tala-frontend` library in-process through the versioned C ABI, and `tali` is the REPL executable.
Do not move Talac without its matching library or place an unrelated library beside it.

Staging is not considered successful merely because both build systems returned zero. The bundle command invokes the
staged tools, checks the compiler version, compiles a real `.tala` fixture to an executable, and executes that native program.
It also invokes `tali --eval "5 + 5"` with only the staged bundle directory added to `PATH`, checks the result,
and opens/exits the no-argument REPL. It fails if either companion cannot be discovered, compilation does not produce the
expected executable, or a smoke program exits incorrectly. Finally it writes `SHA256SUMS` for all staged executables and
legal payloads. Consumers can use that manifest to
detect an incomplete or modified local bundle; it is an integrity record, not a code-signing substitute.

The legal payload is intentionally explicit. `LICENSE.txt` contains MPL-2.0, `PATENTS` identifies the applicable patent
terms, and the two versioned files contain the current Progmasoft linking exception, Version 2.0, and patent grant,
Version 1.1. Historical texts of earlier versions in the repository are not staged as the current distribution terms.

## Build configuration

The native graph is configured by tracked Bazel files and a small environment discovery surface:

| Input | Purpose |
| --- | --- |
| `.bazelversion` | Bazelisk-selected Bazel version |
| `.bazelrc` | automatically selected Windows/ClangCL or macOS/Clang options |
| `MODULE.bazel` | module identity and native dependencies |
| `Talac/Build/Bazel/llvm.bzl` | LLVM development-tree discovery |
| `LLVM_ROOT` | optional LLVM installation prefix |
| `PATH` | discovery of `clang-cl`, `lld-link`, `llvm-config`, and Bazelisk |

`fmt` is a normal Bazel module dependency used by the C++ CLI/driver. Progmasoft Catch3 is pinned through the recursive
`third_party/catch3` submodule and a local module override so native test sources do not depend on registry availability.
Each test target links both Catch3's compiled extensions and its Catch2-compatible runner-with-main target.

The rules_cc patch under `Talac/Build/Bazel` is a narrow ClangCL toolchain workaround. It is not permission to accumulate
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
`clang-tidy` with the repository's `.clang-tidy` over each first-party translation unit under `Talac/`,
`Interactive/`, and `Benchmarks/`. Each unit is analyzed with the exact flags Bazel compiled it with, so there is no
second, hand-maintained compile database to drift. The build comes first because the analyzer needs generated and
fetched headers and, on Windows, the parameter files that hold the commands.

A finding belongs to the file it is reported in. Findings located in vendored or fetched dependency headers are counted
and printed as a total, but do not fail the run; a compiler error fails it wherever it is reported, because the unit
was then not analyzed. A first-party unit whose compile command is unavailable, an analyzer that exits unsuccessfully
without an attributable diagnostic, and an action graph without first-party sources all fail the run rather than
passing as clean. One analyzer process runs per logical processor; set `TALA_TIDY_JOBS` to change that. Bazel options
may follow a `--` separator.

```powershell
go run ./helpers/cmd/develop analyze
```

This runs the Clang Static Analyzer itself over the same translation units, each with the compiler and the command
Bazel compiles it with. The analyzer follows the paths through each function and reports the ones on which something
goes wrong: a null pointer that is dereferenced, a value read before it is written, memory freed twice or never.
`clang-tidy` already runs the analyzer's default checkers as one group among its own. This command adds the stable
checkers that have to be asked for, among them `security.ArrayBound`, `optin.cplusplus.UninitializedObject`,
`optin.cplusplus.VirtualCall` and the nullability checkers, and a set of checkers LLVM still develops. It prints the
steps of the path under each finding.

A finding of a stable checker fails the run. A finding of a checker in development, whose name begins with `alpha.`,
is printed under its own heading and does not: such a checker finds what no stable one looks for and is wrong more
often. Three groups are not run, because all they report on this code is wrong: the iterator checkers, which also
stop the analyzer in comparisons the test framework wraps, `alpha.security.ReturnPtrRange` and
`alpha.core.StoreToImmutable`. Checkers are renamed between LLVM releases, so the command asks the compiler which of
them it has and runs those.

Before the real run the command analyzes a six-line program with a null dereference every version of the analyzer
reports, with the same compiler, checkers and options, and stops unless that finding comes back. A clean result is
only worth believing from an analyzer that is known to report. A finding in a public header is attributed to the
header in the repository and not to the copy Bazel exposes below its output tree.

A finding is silenced by the comment that silences clang-tidy, with the name clang-tidy gives the checker:
`// NOLINTNEXTLINE(clang-analyzer-cplusplus.Move)` on the line before, or `// NOLINT(...)` on the line itself. One
comment answers both tools. Findings in dependency headers are counted and not reported, and a unit the analyzer
could not compile, or on which it stopped, fails the run, as for `tidy`.

`TALA_ANALYZE_JOBS` sets the number of analyzer processes, `TALA_ANALYZE_FILTER` limits the run to the units whose path
contains its value, and `TALA_ANALYZE_SARIF` names a file that receives every finding as SARIF, with the path of each
as a code flow.

The libFuzzer entry points and benchmark programs are outside the built target set and are not analyzed by this
command. The `Clang-Tidy` workflow runs it on Ubuntu for every pull request and push.

## Clean rebuilds

Generated trees are disposable. Prefer deleting only the build system's known output rather than source or workspace roots:

```powershell
bazelisk clean
Push-Location Talac
try { cabal clean } finally { Pop-Location }
```

For the native-only cleanup, `go run ./helpers/cmd/develop clean` performs an expunging Bazel clean.

Do not commit `bazel-*`, Cabal `dist-newstyle`, IDE caches, local service state, or compiler-emitted
artifacts used only for smoke tests. Local compiler bundles below `dist/` are equally reproducible and disposable. Before
removing a large tree manually, resolve the exact absolute target and verify that it is a generated directory inside this
checkout.

## Helper output

The Go helpers (`develop`, `githelper`, `cross-platform-test`, `prebuild`, `optional-packages`, `verify-docs`) show each
program they start as one step. How a step looks depends on where it runs:

| Where | What is shown |
| --- | --- |
| A terminal | A spinner with the step's name, its latest output line and its time; then a check mark and the time, or a cross and the last 40 lines of output. |
| GitHub Actions | The output inside a collapsible log group, an error annotation for a failed step, and the last 40 lines again after the group. |
| Anything else | The output as it is printed, between a `==>` line that names the step and one that gives its result. |

In a terminal the whole output of each step is kept in a log file under the user cache directory, `tala/helper-logs`,
one folder per run; a failed step and a step with warnings print the path of theirs. Folders older than seven days are
removed. A run of more than one step ends with a table of its steps, and on GitHub Actions the table is also added to the
job summary.

Package managers and `gh run watch` talk to the developer themselves, so their output is never held back. Git's output is
shown after each command, since it is the answer of that command. `TALA_HELPERS_OUTPUT` chooses the presentation:
`rich`, `plain` or `actions`.

## Troubleshooting

### LLVM development files are not found

An LLVM runtime installation containing only executables is insufficient. The native backend needs C++ headers, LLVM
libraries, bitcode/support/target components, and `llvm-config` metadata. Point `LLVM_ROOT` at a complete development prefix
or expose that prefix's `llvm-config` on `PATH`. Do not add `LLVM_DIR` with a personal absolute path to tracked files.

### Windows headers or CRT libraries are not found

ClangCL is the compiler, but Windows SDK and MSVC CRT/C++ development files still provide platform headers and import/static
libraries. Install those components and start a PowerShell environment that exposes their include and library directories.
The Visual Studio IDE and Visual Studio's compiler executable are not part of the Tala build contract.

### `clang_rt` or runtime DLL is missing

Treat a missing compiler runtime as a toolchain-layout problem. Confirm the selected ClangCL resource directory and the
runtime libraries shipped with the same LLVM version. Do not copy a random DLL beside every test executable or make a build
depend on a temporary directory.

### Private frontend is missing

Build the Haskell workspace and confirm the frontend is placed in the layout expected by Talac. Installing a same-named
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
