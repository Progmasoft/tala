<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Validate a contribution

No single command covers the whole repository. Start with the test owned by the changed component, then run the next
producer/consumer boundary and the integrated gate appropriate to the change. Record the exact command and outcome in
your pull request. A test that could not run because a tool is missing is **not** a passing test.

The full target and fixture map is in [Testing](../TESTING.md) and [Test ownership](../TEST-OWNERSHIP.md). The commands
below are from the repository root unless a preceding `cd` changes directory.

## Cheap preflight for every PR

```text
git status --short
git diff --check
git diff --stat
git submodule status --recursive
```

Look for generated output, private configuration, accidentally modified submodules, unrelated edits, and paths in a
different nested Git repository. Review the actual diff—not just test totals. A documentation-only PR still needs link,
spelling, and claim checks against current source and public `Spec/` examples.

## Native C++20 and Interactive

First run `go run ./helpers/cmd/develop doctor`; it checks the host and LLVM development tree. During implementation, use
the smallest Bazel target that observes your change, for example:

```text
bazelisk build //Talac/Cli/Tests:cli_parser_tests
bazelisk build //Talac/Codegen/Xpp/Tests:xpp_verifier_tests
bazelisk build //Talac/Backend/LLVM/Tests:llvm_backend_tests
bazelisk build //Interactive/Tests:interactive_tests
```

Bazel `build` compiles a test target; it does not execute that target. Before a native compiler PR is ready for review,
run the portable repository gate:

```text
go run ./helpers/cmd/develop test
```

This builds the compiler and executes 16 native suites: 15 Catch3-based programs plus the C11 AARC ABI caller. Run
`go run ./helpers/cmd/develop sanitize address` for ownership, lifetime, or unsafe-memory changes. On macOS, `undefined`
and `thread` are additional supported sanitizer modes. If a test crosses Haskell Core into native Xpp/Xmm, run the
Haskell gate too; native tests alone cannot validate frontend semantics. Decoder changes also need the separate
[wire mutation smoke](../FUZZING.md), which is not part of the 16 `develop.go test` suites.
For untrusted decoder changes, run `go run ./helpers/cmd/develop fuzz` as well; it exercises a real coverage-guided
libFuzzer driver with a temporary seed corpus and preserves crashes for regression tests.

Use LLVM/Clang **23.1.0** `clang-format` on changed project-owned C/C++ files, then check them again:

```text
clang-format -i Talac/Codegen/Xpp/YourChangedFile.cpp
clang-format --dry-run --Werror Talac/Codegen/Xpp/YourChangedFile.cpp
```

Replace the example path with your files. Do not reformat `third_party/`, generated code, or an entire component merely
because a local formatter defaults differently. The 80-column `.clang-format` profile is mechanical style, not a request
to rename public APIs.

## Haskell frontend, Core, and CorePrep

From `Talac/`:

```text
cabal build all
cabal test all
```

Run `cabal check` for each affected package; the [building guide](../BUILDING.md#language-layer-tests) shows a PowerShell
loop for the complete Haskell workspace. A lexer, parser, symbol, type, Core, or wire change usually affects multiple
packages. Include malformed input and source spans where the contract requires them. For a wire change, test both Haskell
and C++ readers/writers, version rejection, golden bytes, and post-decode verification; a symmetric round trip on one
side can hide a shared bug.

## Kotlin project system and ecosystem tools

On Windows, run the pinned project wrapper rather than a machine-global Gradle:

```text
.\Tazel\gradlew.bat -p Tazel test
```

If a DSL plan reaches the native driver, add a bridge or process-level check in addition to the Kotlin model test. For
Analyzer, Formatter, or Linter work, run `cabal build all` and `cabal test all` from that project's directory, then its
Kotlin Gradle tests; [Testing](../TESTING.md#analyzer-formatter-and-linter) gives the component commands. These tools have
separate workflows and release lines.

The current GitHub Kotlin gates use the Windows wrapper. A macOS contributor should use the Gradle version pinned in
`Tazel/gradle/wrapper/gradle-wrapper.properties` for an equivalent local run, or explicitly report that the
Kotlin gate could not run locally; do not present an unverified macOS wrapper command as a pass.

## Go tooling and documentation

For changes to repository Go commands, run the paired source-file tests:

```text
go -C helpers test ./cmd/develop
go -C helpers test ./cmd/githelper
```

For documentation, verify repository-relative links, current command spelling, component ownership, and whether the
document describes connected code or intended design. Run `git diff --check`. Do not cite private planning files as
public authority or change a `Spec/` example merely to match an incomplete implementation.

## Continuous integration

The repository has separate Compiler Tier 1/2/3, Language Layers, Haskell Coverage, Component Coverage, CodeQL,
Benchmarks, Analyzer, Formatter, Linter, and Coverage-Guided Fuzzing workflows. Find the jobs for your commit and inspect the final status of
each triggered workflow. See [Code scanning and coverage](../COVERAGE-AND-SECURITY.md) for report ownership and limits.
Different operating systems and sanitizer configurations catch failures that one local host cannot. A missing workflow
is not automatically green; check its trigger before claiming coverage. If CI fails, identify the job and first failing
command, reproduce the relevant gate locally, and report the fix in the PR. Avoid treating a blind rerun as verification.
