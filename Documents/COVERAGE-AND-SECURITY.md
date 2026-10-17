<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Code scanning and coverage

CodeQL and Codecov answer different questions. CodeQL analyzes supported source languages for potential defects and
security problems; Codecov collects lines executed by tests. Neither substitutes for component contract tests,
sanitizers, fuzzing, or review.

## CodeQL ownership

The [CodeQL workflow](../.github/workflows/codeql.yml) analyzes five supported surfaces independently:

| Language | Extraction |
| --- | --- |
| GitHub Actions | Workflow source, without a build |
| C/C++ | Project-owned source, without a build for every pull request and from a traced Bazel build for the default branch |
| Go | Manual builds of every command and internal package in helpers/ |
| Java/Kotlin | Manual Gradle compilation of Tazel, tala-analyzer, talafmt, and talalint |
| JavaScript/TypeScript | Editor integration source, without a build |

The configuration excludes `third_party/` and generated build output. Haskell is not a CodeQL-supported language; its
compiler packages retain Cabal tests, HPC coverage, and ordinary review instead of a misleading empty CodeQL job. The
workflow runs for pushes, pull requests, and a weekly schedule. A successful scan means the configured analysis
completed, not that the code is free of vulnerabilities. Review alerts in the repository's code-scanning interface.

C and C++ are analysed twice. The `c-cpp` job runs for every pull request without a build: the extractor reads the
sources and guesses how they would be compiled. That needs no LLVM on the runner and is quick, but the guess resolves
few includes. Measured on this repository, every native source reached the database, while 30 percent of the
`#include` directives were resolved, no compilation was free of errors and half of the expressions had a known type.
Such an analysis finds what can be seen in one file and little that depends on types or on calls.

The `c-cpp-traced` job is the analysis that compiles. CodeQL observes the compiler while Bazel compiles every native
target without a cache and without linking, so each source is read with the include paths, definitions and language
options it is really compiled with. It costs a full compilation, so it runs when the default branch changes, once a
week and on request, and for a pull request only when that carries the label `codeql-traced`. Its results are
recorded under a category of their own, `/language:c-cpp/build:traced`. Its first run resolved all 5 730 `#include`
directives, compiled all 179 compilations without an error and recorded 280 698 calls, where the analysis without a
build recorded 1 009. The job fails when fewer than 95 percent of the includes are resolved or fewer than 95 percent
of the compilations are free of errors.

Both jobs run [the same measurement](../.github/codeql/Measure-CppAnalysis.ps1). It compares the native sources the
repository owns under `Talac/` and `Interactive/` with the sources the CodeQL database holds and fails below
95 percent. It also writes the share of resolved includes and of compilations without errors, with the extractor's
own summary and telemetry, to the job summary and to the log.

## Dependency and additional quality analysis

[Renovate](../.github/renovate.json5) proposes version updates for GitHub Actions, Bazel module dependencies, all four
Gradle builds, the Go tooling module in `helpers/` and the VS Code extension. It looks once a week, takes a release a
week after it is published, opens one pull request for each kind of dependency, and rebases a pull request only when it
conflicts. It proposes reviewable pull requests; it does not auto-merge them. Cobra and its transitive dependencies
are version-pinned with module checksums. Cabal packages and pinned submodules need manual dependency review.

Dependabot no longer proposes version updates here, so that two bots do not open the same pull request. Its alerts
and its security updates stay enabled in the repository settings: a dependency with a known vulnerability is still
reported, and its fix is still proposed, by Dependabot. Neither bot replaces CodeQL.

[OSV-Scanner](../.github/workflows/osv-scanner.yml) matches the locked dependencies against the OSV database: the Go
helpers (`helpers/go.sum`) and the VS Code extension (`package-lock.json`). A pull request fails only on a
vulnerability it introduces. The run on `main` and the weekly run upload every known one to code scanning without
failing, so an advisory published after a merge is reported without turning `main` red. The Gradle builds have no
lock files and the Bazel and Cabal resolutions have no format OSV-Scanner reads, so those dependencies are not part
of this scan.

[Codacy configuration](../.codacy.yml) excludes third-party and generated output while retaining project-owned
implementation, tests, and CI. Codacy's GitHub application must be connected to the Progmasoft organization and this
repository added in Codacy before its hosted analysis runs. No Codacy API token is needed for hosted static analysis;
coverage remains with Codecov rather than being uploaded twice. Until the first Codacy analysis is visible, the
configuration is only prepared, not a verified scan.

Codacy reads C++ with pattern checkers, which look at one statement or one function body at a time. What depends on
the path taken through a function, a pointer that is null on one branch and dereferenced after the branches join, a
value that one path leaves unwritten, memory one path frees twice, is outside what they can see. The
[Clang Static Analyzer workflow](../.github/workflows/clang-static-analyzer.yml) covers that part: it runs
`develop analyze`, described in [BUILDING.md](BUILDING.md#static-analysis), for every pull request and for the default
branch, fails on a finding of a stable checker, and uploads every finding to code scanning under the category
`clang-static-analyzer`, where each is shown with the steps of its path.

## Codecov ownership

Coverage uploads carry separate flags so one component's result cannot be mistaken for another's:

| Flag | Producer | Report |
| --- | --- | --- |
| `haskell-frontend` | Instrumented Cabal compiler tests | HPC converted to LCOV |
| `native-cpp` | The native C++/Interactive suites on macOS | Clang source-based LCOV |
| `kotlin-project-system` | Tazel Gradle tests | JaCoCo XML |
| `kotlin-analyzer` | Analyzer Gradle tests | JaCoCo XML |
| `kotlin-formatter` | Formatter Gradle tests | JaCoCo XML |
| `kotlin-linter` | Linter Gradle tests | JaCoCo XML |
| `go-tools` | All helper command and internal package tests | Go cover profiles |

Each language has a status of its own on a pull request, for the whole of its sources and for the lines the pull request
changes: `haskell-frontend`, `native-cpp`, `kotlin` (the four Kotlin flags together) and `go-tools`, beside the figure
for the repository as a whole. [`codecov.yml`](../codecov.yml) gives each flag the paths it answers for, so a file is
never measured by a suite that does not own it. The statuses are informational: they show a fall and do not fail a
pull request. A flag whose suite did not run for a commit keeps its last figure.

The [Haskell coverage workflow](../.github/workflows/haskell-coverage.yml) still owns HPC conversion. The
[component coverage workflow](../.github/workflows/coverage.yml) owns the remaining reports. Both upload through
Codecov's GitHub OIDC path without a repository token. The native report is generated from the same native suite matrix as
`develop test`; it does not count a binary merely because it built. JaCoCo XML is generated after running the owning
tests, and Go profiles cover every package in the helper module.

To reproduce a Kotlin report locally, run `gradle -p Tazel test jacocoTestReport` (or replace the directory with
Analyzer, Formatter, or Linter). For native macOS coverage, run
`go run ./helpers/cmd/develop test -- --copt=-fprofile-instr-generate --copt=-fcoverage-mapping
--linkopt=-fprofile-instr-generate` with `LLVM_PROFILE_FILE` set to a writable path containing
`%p-%m`, then merge the raw profiles with `llvm-profdata` and export LCOV with `llvm-cov`. The CI workflow is the
authoritative command sequence. Coverage percentages measure the exercised files, not language-spec completeness or
correctness. A missing report or failed upload is a failing CI job, never zero coverage or an implicit pass.
