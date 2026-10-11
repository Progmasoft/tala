<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Testing and verification

Visual X# crosses Haskell, C++20, Kotlin, LLVM, and tool-specific boundaries. No single test command validates every layer.
This guide maps a change to the smallest meaningful local gate and the integrated workflows that protect the repository.

## Test principles

- Test an invariant where it is owned, then test the next boundary that consumes it.
- Prefer semantic assertions over snapshots of unstable internal formatting.
- Give malformed artifacts dedicated negative tests; do not rely only on parser rejection.
- Keep unit tests deterministic and independent of network services.
- Never make a passing test depend on an old generated artifact in `build`, `bazel-*`, `dist-newstyle`, or Gradle output.
- A registered-but-disconnected CLI route needs a test for its explicit rejection.
- A public language design example does not count as implementation coverage until an owning compiler test exercises it.

## Fast preflight

Run these before expensive language-layer checks:

```powershell
git diff --check
rg -n "d[o]cs/" README.md Documents Spec Compiler ProjectSystem Analyzer Formatter Linter
```

The second command is a migration/stale-link example rather than a permanent assertion that the text `docs` can never
occur. External names such as `docs.rs` are unrelated and must not be rewritten.

## Go repository checks

The independent module is `helpers/go.mod`, with module identity
`github.com/Progmasoft/visual-xsharp/helpers`. A root `go.work` selects it for
checkout commands; there is no root `go.mod`. Command entry points live under
`helpers/cmd/`; reusable developer logic lives under `helpers/internal/`.
Cobra provides the developer command tree and standard `--help` / `-h` behavior.
Its exact version and transitive dependencies are recorded in `go.mod` and `go.sum`.

`verify-helpers` checks every package's test presence, SPDX headers, file limits,
formatting, downloaded module integrity, static analysis, and package tests.
Tests inject process runners so they do not install tools or build the compiler.

```powershell
go run ./helpers/cmd/verify-helpers
go -C helpers test ./...
go -C helpers vet ./...
go -C helpers test ./internal/development
go run ./helpers/cmd/repo-info --json
go run ./helpers/cmd/verify-examples --root .
go run ./helpers/cmd/verify-benchmarks --root .
```

For module-only validation without the workspace, set `GOWORK=off` and run
`go -C helpers test ./...`. Module-wide coverage uses one profile containing
command packages and internal implementation packages; it does not substitute
entry-point file coverage for the developer implementation.

`verify_examples.go` checks that every program listed in `Examples/README.md`
has its directory and the expected Visual X#, C#, C++, Java, and Rust source
files, and that no unlisted program directory is left behind. `verify_benchmarks.go`
checks that root-level benchmark reports are indexed exactly once in
`Benchmarks/README.md`, with no missing, stale, or escaping paths. These are
read-only repository-integrity checks and also run in the Compiler Tier 1/2/3
workflows. A successful Go unit test is not a substitute for running each tool
against the checkout, because only the repository scan catches stale catalogs.

For a source change, inspect the diff and verify that no generated or local-only directory entered the index:

```powershell
git status --short
git diff --stat
git diff --name-only
```

## Haskell compiler packages

The Haskell workspace lives under `Compiler/` and contains separate Syntax, Frontend, Core, and Driver packages. From that
directory run:

```powershell
cabal build all
cabal test all
Get-ChildItem Haskell -Filter *.cabal -Recurse | ForEach-Object {
  Push-Location $_.DirectoryName
  try { cabal check } finally { Pop-Location }
}
```

Use focused package tests during development, but finish a frontend/Core change with the complete workspace tests. Changes
to tokens, AST shapes, symbols, types, Core, CorePrep, or their codecs commonly cross more than one package even when the
compiler error appears in only one module.

### What Haskell tests should cover

| Layer | Primary assertions |
| --- | --- |
| Lexer | token kind, literal decoding, source span, one-error recovery |
| Parser | grammar shape, precedence, delimiter recovery, invalid-form diagnostics |
| Renamer | stable fresh identities, scope, duplicate declarations, shadowing |
| Name Resolution | reference binding, ambiguity, explicit captures, namespace merge |
| Type Checker | inferred/declared types, calls, returns, operators, range errors, entry signature |
| Desugarer | semantic preservation and removal of source-only forms |
| Core | verifier invariants, optimizer preservation, wire round trips and limits |
| CorePrep | atomization order, CFG construction, verifier failures, internal wire symmetry |
| Driver | source discovery, exclusions, UTF-8, containment, project entry selection |

Golden bytes are appropriate for a versioned wire format. Pair them with semantic round-trip tests so a reader and writer
cannot change together and accidentally hide an incompatible format change.

## Native compiler tests

Initialize recursive submodules and make the standalone LLVM development environment available before building:

```powershell
git submodule update --init --recursive
go run ./helpers/cmd/develop doctor
go run ./helpers/cmd/develop test
```

The command executes 20 Catch3 binaries, one C11 ABI contract executable and
one source/differential fuzz smoke executable on
Windows 10/11, macOS Sequoia/Tahoe, Ubuntu 26.04 LTS, and Fedora 43. Bazel
selects the host configuration automatically; no public test instruction
requires `--config`.

Control-flow changes must exercise the stage that creates edges and every
storage-oriented consumer of those edges. Three component-owned suites make
that boundary explicit:

- `Compiler/Analysis/Tests/definite_initialization_tests` checks the shared
  reachability, initialization, and ownership fixed points;
- `Compiler/Codegen/Xpp/Tests/xpp_verifier_tests` checks symbolic storage,
  including direct-function versus closure-storage reads and explicit AARC handle lifetime; and
- `Compiler/Codegen/Xmm/Tests/xmm_verifier_tests` checks virtual-register
  initialization, strong/weak/unowned representation, and block-order independence.

The integrated developer command builds and executes all three. Focused Bazel
labels shorten iteration, but they do not replace the full native gate. See
[Control-flow safety](CONTROL-FLOW-SAFETY.md) for initialization equations and
[ownership-flow verification](OWNERSHIP-FLOW.md) for AARC lifetime equations.

Run native memory diagnostics through the same entry point:

```powershell
go run ./helpers/cmd/develop sanitize address-undefined
```

Windows, macOS and Linux support combined ASan/UBSan and their individual
`sanitize address` / `sanitize undefined` profiles. macOS and native Linux also
support the separate `sanitize thread` profile. Each profile verifies real
intentional failures before running the complete native suite set. See
[Fuzzing](FUZZING.md) for the Windows and Fedora TSan boundaries.

The Compiler Tier 1/2/3 workflows also run a separate deterministic wire-mutation
smoke target. It is separate from the component-owned `develop test` suite set.
Run it directly when a Core, CorePrep, Xpp, or Xmm decoder changes:

```powershell
bazelisk build //Compiler/Fuzzing:wire_fuzz_smoke
.\bazel-bin\Compiler\Fuzzing\wire_fuzz_smoke.exe
```

The separate `fuzzing.yml` workflow runs `go run ./helpers/cmd/develop fuzz`, a 90-second-per-target CI campaign with
ASan/UBSan on Windows, macOS, Ubuntu, and Fedora; scheduled stress runs use 900 seconds per target. See [Fuzzing](FUZZING.md) for coverage ownership, oracles, resource bounds, corpus,
crash artifacts, and current limits.

Use Bazel target boundaries to keep iteration focused:

```powershell
bazelisk build //Compiler/Core:core
bazelisk build //Compiler/ADTs/Tests:adt_tests
bazelisk build //Compiler/Codegen/Xpp:xpp
bazelisk build //Compiler/Codegen/Xmm:xmm
bazelisk build //Compiler/Analysis/Tests:definite_initialization_tests
bazelisk build //Compiler/Codegen/Xpp/Tests:xpp_verifier_tests
bazelisk build //Compiler/Codegen/Xmm/Tests:xmm_verifier_tests
bazelisk build //Compiler/Backend/LLVM:llvm_backend
bazelisk build //Compiler/Driver:core_pipeline
bazelisk build //Compiler/Core/Tests:core_pipeline_tests
bazelisk build //Compiler/Driver/Tests:closure_pipeline_tests
bazelisk build //Compiler/Driver/Tests:scalar_pipeline_tests
bazelisk build //Compiler/Backend/LLVM/Tests:llvm_backend_tests
bazelisk build //Compiler/Runtime/AARC/Tests:aarc_c_abi_tests
bazelisk build //Interactive:vxsi
bazelisk build //Interactive/Tests:interactive_tests
```

The exact label names are source-owned API. If a package is reorganized, update this guide and CI with the same change.

### Native framework decision

Progmasoft Catch3 is the native test framework. It retains Catch2-compatible discovery and assertions while adding
C++20 property checks, snapshots, and structured results in a separately compiled library. Test targets link both the
compatibility runner and `//src/Progmasoft:catch3`; using only the runner would silently omit Catch3's own features.
`DenseIdMap` has a deterministic generated-identity property test that exercises this additional surface. Google
Benchmark remains separate because statistically repeated timing is a different concern from correctness testing.

Catch3 is still early-stage and its runner remains Catch2-derived. Keep tests on supported public headers and measure
clean-build time and binary size before expanding use of the umbrella header. Death tests alone are not a migration goal:
compiler and runtime validation should normally return structured diagnostics rather than terminate the test process.

### Component-local ownership

Native tests do not live in a root `tests/` directory. The directory holding a
test identifies the contract that owns its maintenance:

| Test package | Contract |
| --- | --- |
| `Compiler/Cli/Tests` | command grammar, option scope, and output behavior |
| `Compiler/Analysis/Tests` | reusable CFG reachability and definite-initialization facts |
| `Compiler/Core/Tests` | Core model, verification, artifacts, and golden wire |
| `Compiler/Codegen/Xpp/Tests` | symbolic-storage verification at the Xpp boundary |
| `Compiler/Codegen/Xmm/Tests` | virtual-register verification at the Xmm boundary |
| `Compiler/Driver/Tests` | connected CorePrep, Xpp, and Xmm stage behavior |
| `Compiler/Backend/LLVM/Tests` | LLVM IR and native artifact lowering |
| `Compiler/Runtime/AARC/Tests` | C++ runtime invariants and a C11-only caller of the public ABI |
| `Interactive/Tests` | REPL input, bounded history, source bindings, and session behavior |

Fixtures follow the same rule. A Core golden document is stored below the Core
test package, while multi-file `.vxs` projects used by the connected pipeline
belong to Driver tests. Retired textual-intermediate fixtures are not kept in
the current source tree and are never an input promise for the CLI.

When a test crosses several components, choose the narrowest owner of the
asserted contract. For example, scalar preservation from CorePrep through Xmm
belongs to Driver; the exact LLVM `sdiv` versus `udiv` choice belongs to the
LLVM backend. This prevents integration suites from becoming an unowned common
bucket.

Test targets use private default visibility. Production libraries may be test
dependencies, but production targets must never depend on a `Tests` package.
See [Test ownership](TEST-OWNERSHIP.md) for fixture, naming, and review rules.

After moving a suite, scan build labels, workflow commands, documentation,
REUSE annotations, compile-time fixture paths, and generated manifests for the
old location. A successful compiler build alone does not prove the move is
complete: a release-only workflow or license scanner may still carry the stale
path. Remove an empty root directory instead of preserving it as a future
fallback.

### What native tests should cover

- CLI command and option scope, arity, typed values, defaults, duplicates, and contextual help;
- bounded Core/CorePrep decoding and malformed-document rejection;
- equality of Haskell and C++20 wire expectations;
- Core and CorePrep symbol/type/control-flow verification;
- deterministic Core-to-CorePrep adaptation;
- Xpp and Xmm lowering, optimizer preservation, and independent verifier failures;
- LLVM module construction and rejection of values with no layout contract;
- C11 header validity and C-to-C++ AARC metadata/opaque-handle compatibility;
- REPL source isolation, line draining, persistent value binding, reset, and history bounds;
- object/assembly extension checks and target-machine errors;
- typed LLD invocation and stale-executable prevention; and
- temporary-file cleanup on success and every failure exit.

Tests that construct Xpp or Xmm directly must still pass through that IR's verifier. Direct construction is a reason for
more boundary verification, not an exemption.

## Kotlin project system

Run the project evaluator and DSL tests with the repository wrapper:

```powershell
.\ProjectSystem\gradlew.bat -p ProjectSystem test
```

Project-system tests should distinguish script parsing, immutable model construction, validation, lockfile persistence, and
native plan transport. Important cases include:

- project discovery from nested directories;
- required and all-or-none project metadata rules;
- namespace-qualified entry validation without path guessing;
- null versus explicit exclusion state;
- contained local plugin and package paths;
- exact hosted coordinates and duplicate declarations;
- case-sensitive identifiers, versions, targets, and test suite names;
- plugin descriptor/service/digest validation;
- deterministic SQLite lockfile contents; and
- `panic` producing no partial plan, lock update, or compilation start.

Do not test the evaluator by searching for `.vxs` files in Kotlin. Source discovery belongs to the Haskell compiler driver.

## Analyzer, Formatter, and Linter

Each ecosystem project has an independent workflow and release line. Their Haskell and Kotlin layers are tested separately
because a configuration snapshot can be correct while formatting or lint semantics are wrong.

Typical local gates are:

```powershell
Set-Location Analyzer
cabal build all
cabal test all
.\gradlew.bat test

Set-Location ..\Formatter
cabal build all
cabal test all
.\gradlew.bat test

Set-Location ..\Linter
cabal build all
cabal test all
.\gradlew.bat test
```

Run commands from the project they belong to; do not assume one Gradle or Cabal workspace owns all three tools. Evaluator
integration is intentionally separate from the typed DSL model and must not be implied by model-only tests.

Formatter tests need parser-gated idempotence: formatting valid input twice must produce the same bytes as formatting it
once. Dry-run must not write, in-place mode must replace only the selected source, and malformed input must not be silently
rewritten.

Lossless-source tests independently assert exact reconstruction, CRLF-aware spans, protected-fragment classification,
delimiter-level termination, structural masks, and multi-line protected ranges. Formatter indentation tests must include
braces inside every protected fragment kind; a green ordinary block test alone is not evidence that literal payloads are
safe.

Linter tests should assert rule identity, severity, source range, explanation metadata, safe/unsafe fix classification, and
suppression behavior independently. A rule catalog entry is planned surface until an analysis implementation and focused
test exist.

Analyzer tests should keep syntax, semantic, and full analysis modes distinct and verify cancellation/stale-result behavior
when workspace support is connected.

## Formatting and static hygiene

Project-owned C and C++ sources use the checked-in `.clang-format` file and LLVM/Clang 23.1.0:

```powershell
$files = rg --files Compiler Interactive -g '*.cpp' -g '*.hpp' -g '*.hh' -g '*.h'
clang-format --dry-run --Werror $files
```

Do not include `third_party/` or generated sources. Haskell formatting follows `fourmolu.yaml`; Kotlin formatting must respect
the project sources and generated-code exclusions.

Every implementation, test, build, configuration, and internal source file outside the documented exceptions must remain at
or below 1500 lines. A simple review aid is:

```powershell
$extensions = '*.hs','*.cpp','*.hpp','*.hh','*.kt','*.kts','*.go','*.java'
Get-ChildItem Compiler,Interactive,ProjectSystem,Analyzer,Formatter,Linter,helpers -Recurse -File -Include $extensions |
  Where-Object { (Get-Content -LiteralPath $_.FullName).Count -gt 1500 } |
  Select-Object FullName
```

Treat any result as a decomposition task, not an invitation to minify the file.

## GitHub workflows

The repository currently separates twelve workflow ownership areas:

| Workflow | Responsibility |
| --- | --- |
| `compiler-tier1.yml` | Windows Server 2025/ClangCL surrogate and macOS 15/26 native suites, sanitizers, and fuzzing |
| `compiler-tier2.yml` | Ubuntu 26.04 LTS native suites and AddressSanitizer |
| `compiler-tier3.yml` | Fedora 43 container native suites and wire-mutation smoke |
| `fuzzing.yml` | Coverage-guided libFuzzer campaigns with crash-corpus artifacts on all four host families |
| `language-layers.yml` | Kotlin project system plus Haskell compiler layers |
| `haskell-coverage.yml` | Haskell coverage reporting |
| `coverage.yml` | Native C++, Kotlin, and Go coverage reports uploaded to Codecov |
| `codeql.yml` | CodeQL scanning for C/C++, Kotlin, Go, and GitHub Actions |
| `analyzer.yml` | Visual Analyzer layers |
| `formatter.yml` | Visual Formatter layers |
| `linter.yml` | Visual Linter layers |
| `benchmarks.yml` | Native and Haskell benchmark build and smoke coverage |

See [Code scanning and coverage](COVERAGE-AND-SECURITY.md) for language boundaries, report formats, Codecov flags, and
the limits of each signal.

GitHub has no hosted Windows 10/11 desktop runner. Tier 1 uses a Windows Server 2025 runner with the Windows/ClangCL
toolchain; that is a useful compatibility surrogate, not a claim that desktop Windows 10 and 11 were tested. Actual
desktop coverage needs separately maintained self-hosted runners.

After pushing a normal compiler or repository-wide change, inspect every workflow triggered by the commit:

```powershell
gh run list --commit (git rev-parse HEAD)
gh run watch <run-id> --exit-status
```

A workflow that did not start is not green. Confirm its trigger/path filters before concluding that the change was covered.
When one workflow fails, inspect the failing job and reproduce its direct command locally; do not rerun blindly until a
transient external failure is established.

## Artifact-level smoke tests

For a connected source subset, a useful end-to-end matrix is:

```powershell
vxs check -File .\Sources\Main.vxs
vxs build -File .\Sources\Main.vxs -Emit core
vxs build -File .\Sources\Main.vxs -Emit llvmll
vxs build -File .\Sources\Main.vxs -Emit llvmbc
vxs build -File .\Sources\Main.vxs -Emit object
vxs build -File .\Sources\Main.vxs -Emit assembly
vxs build -File .\Sources\Main.vxs
vxs run -File .\Sources\Main.vxs
```

Assertions should include file extension, nonempty artifact, replacement of an older artifact, no output from `check`, no
temporary object after binary linking, and propagation of the executed process status from `run`.

### Install-layout smoke test

The source-level matrix above can exercise programs directly from developer build trees. The distribution boundary has an
additional failure mode: the public driver and its matching private frontend may not have been staged together. Exercise
that boundary with:

```powershell
go run ./helpers/cmd/develop bundle
```

This is more than an archive or copy test. A passing run proves that the staged `vxs` reports the checkout's compiler
version, loads the adjacent private `vxs-frontend` shared library in-process, compiles a real `.vxs` source into a `.vxse`, and executes the result
successfully. It also proves that the bundle contains `LICENSE.txt`, `PATENTS`, the current `1.1` exception and patent-grant
texts, and a `SHA256SUMS` manifest covering the other staged files.

The output under `dist/visual-xsharp-<version>-<platform>-<arch>/` is ignored and reproducible. Do not treat an old bundle as
test input, copy a frontend from another checkout into it, or commit the generated directory. A release or packaging change
should start from a freshly staged bundle so version, wire contract, native driver, and legal materials are evaluated as one
unit.

The bundle smoke path also invokes `vxs interactive` with the staged directory prepended to `PATH`. `-Eval` must return the
expected result, `-Help` must reach `vxsi`, and a piped no-argument REPL transcript must type-check, evaluate, display
history, reset the ORC resource trackers, and evaluate the same symbol again. This verifies that the singular `vxs` command
finds its sibling REPL by `PATH` rather than a private absolute path or the current directory.

For focused local feedback, the REPL's owning tests can be built and run directly:

```powershell
bazelisk build //Compiler/Backend/LLVM/Tests:llvm_backend_tests `
  //Compiler/Cli/Tests:cli_parser_tests `
  //Interactive/Tests:interactive_tests
.\bazel-bin\Compiler\Backend\LLVM\Tests\llvm_backend_tests.exe
.\bazel-bin\Compiler\Cli\Tests\cli_parser_tests.exe
.\bazel-bin\Interactive\Tests\interactive_tests.exe
```

The LLVM suite checks native scalar-call ABI widths, invalid bitcode recovery, module lifetime, and reset; the AARC C11
executable verifies C header compilation and calls into the C++ runtime; the CLI suite checks transparent child-argument
forwarding; and the Interactive suite checks in-memory source construction, scalar bindings, bounded history, input
recovery, value formatting, and command parsing. The bundle test is the owning gate that loads the Haskell frontend shared
library and proves a real source expression completes the entire Core-to-ORC route without temporary source/Core files.

## Documentation verification

The `API Documentation` workflow runs Doxygen over the public C++ headers and Haddock over the four public Haskell
packages on every pull request and push. Doxygen warnings are errors; the Haddock gate checks each exported entity's
coverage and fails if any public declaration lacks documentation. Run the same check locally with:

```powershell
go run ./helpers/cmd/verify-docs
```

For documentation-only changes:

1. confirm every relative Markdown link resolves;
2. scan for old directory and artifact names;
3. verify that examples use the accepted case-sensitive CLI spelling;
4. check that planned behavior is marked planned;
5. keep public prose in en-US English; and
6. run `git diff --check`.

Documentation is part of the interface. A command example that the parser rejects or an old registry hostname is a defect,
even when no compiler source changed.
