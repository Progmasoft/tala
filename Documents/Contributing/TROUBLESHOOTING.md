<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Troubleshooting a contributor checkout

Start with the exact failing command and its first meaningful error. Run `go run ./helpers/cmd/prebuild check` and
`go run ./helpers/cmd/develop doctor` before changing project files to work around a local installation problem. The
[building guide](../BUILDING.md) has the full toolchain contract; this page highlights common first-checkout failures.

## A submodule directory is empty or Bazel cannot resolve Catch3

From the root checkout:

```text
git submodule update --init --recursive
git submodule status --recursive
```

The parent repository pins a specific Catch3 revision. Do not replace it with a global Catch2 package or change a
submodule commit merely to make one local cache work. Confirm your fork has fetched the parent commit containing the
gitlink. If network access blocks the public submodule, report that environmental failure separately from a compiler bug.

## LLVM, compiler, or platform headers are missing

The native graph requires a complete LLVM **development** installation, not only a runtime or `clang-cl` executable.
Set `LLVM_ROOT` to the installation prefix or put that installation's `llvm-config` on `PATH`. Do not point `LLVM_ROOT`
at `bin`, `include`, or `lib/cmake/llvm`, and do not commit the path into `MODULE.bazel`, `.bazelrc`, or a source file.

On Windows, ClangCL/LLD are the compiler/linker, but the Windows SDK and MSVC CRT/STL development files supply platform
headers and libraries. A missing SDK/CRT library is not a reason to switch the build to GCC or a Visual Studio bundled
compiler. Re-run the host preflight after installing a missing workload and open a fresh terminal so PATH changes apply.

On macOS, check the selected Xcode Command Line Tools SDK and `xcrun`. The full Xcode IDE is not required by the
repository. The native script selects the supported host configuration automatically; do not add an unexplained
`--config` to a public build recipe.

If linking fails with `tapi error: malformed file` and `unknown architecture` in a `.tbd` file, Homebrew's clang found
a Command Line Tools SDK that is newer than the selected linker. Homebrew's clang configuration files
(`$(brew --prefix)/etc/clang/*.cfg`) and a GHC installation can name that SDK by path, which overrides `SDKROOT`. Point
those references at `$(xcrun --show-sdk-path)`, the SDK of the selected developer directory, and run
`ghc-pkg recache --global` after changing GHC's package files; the macOS CI jobs do the same.

## Haskell or Kotlin uses the wrong toolchain

Maintained Haskell packages use `GHC2024`; a compiler older than the required GHC will reject the edition before a
source test runs. Check `ghc --version` and `cabal --version`, then use the versions in [Building](../BUILDING.md).

The Kotlin configuration DSLs require JDK 25. On Windows, use the pinned Gradle wrapper at the repository root and check
`java -version` in the same terminal. If the Gradle distribution cannot be downloaded, record the network or cache
error; do not commit a local binary or change the wrapper URL to an unreviewed mirror.

## Bazel builds a test but does not run it

`bazelisk build //...:some_tests` only produces the binary. On Windows, use
`go run ./helpers/cmd/develop test` for the complete native suite; the helper executes binaries directly so a POSIX shell
is not required for Bazel's ordinary `cc_test` launcher. A green `build` line is not evidence that assertions passed.

## A stale artifact or generated output affects a result

Check `git status --short`, the command's actual output path, and whether the artifact was produced by the current run.
Do not make a test depend on an old `bazel-*`, `dist-newstyle`, or Gradle output. `go run ./helpers/cmd/develop clean`
removes generated Bazel/Cabal/Gradle output; inspect its documented scope before running it, because it is not a Git
reset and should not be used to erase unrelated local work. Never delete broad directories outside the checkout as a
troubleshooting shortcut.

## A local pass and CI failure disagree

Compare OS, Clang/LLVM, GHC, JDK, feature flags, sanitizer mode, and the exact source commit. Inspect the first failing
CI job and reproduce its direct command. If the failure is in a submodule download or a service outage, show the
evidence; do not silently rerun until a red badge turns green. For a code failure, add or repair the owning test and
push a normal commit to your PR branch.

When asking for help, include the command, host/version, relevant sanitized log excerpt, and what preflight already
passed. Do not publish credentials, private projects, or full environment dumps containing secrets.
