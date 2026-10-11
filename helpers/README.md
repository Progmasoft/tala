<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Visual X# developer helpers

This is an independent Go module, `github.com/Progmasoft/visual-xsharp/helpers`.
It contains developer applications and reusable implementation packages, not
compiler runtime code or another build system. Bazel owns the native graph,
Cabal owns Haskell packages, and Gradle owns Kotlin components.

## Package layout

```text
helpers/
├── go.mod, go.sum          independently pinned dependency graph
├── cmd/
│   ├── develop/            native build, test, fuzz, bundle, and cleanup
│   ├── githelper/          guarded staging, commit, and push
│   ├── prebuild/           required toolchain checks and installation
│   ├── optional-packages/  optional example and comparison toolchains
│   ├── repo-info/          read-only checkout and tool availability report
│   ├── verify-helpers/     module-wide developer-tool quality gates
│   ├── verify-docs/        strict Doxygen and Haddock API documentation checks
│   ├── verify-examples/    example inventory and source-file contracts
│   └── verify-benchmarks/  benchmark report/index consistency
└── internal/
    ├── development/       host, process, build, bundle, fuzz, and release logic
    └── repository/        shared checkout-boundary discovery
```

Each command has its own tests. Shared behavior is decomposed by responsibility
and tested at package level rather than by artificial source/test file pairs.
The module does not import compiler implementation code.

## Run from the checkout

The root `go.work` selects `./helpers`; there is deliberately no root `go.mod`.
Use Go 1.26 or newer, matching the module's language version:

```powershell
go run ./helpers/cmd/prebuild check
go run ./helpers/cmd/repo-info
go run ./helpers/cmd/repo-info --json
go run ./helpers/cmd/develop --help
go run ./helpers/cmd/develop doctor
go run ./helpers/cmd/develop test
go run ./helpers/cmd/develop fuzz-stress --asan
go run ./helpers/cmd/verify-helpers
go run ./helpers/cmd/verify-examples
go run ./helpers/cmd/verify-benchmarks
go run ./helpers/cmd/verify-docs
```

Every command of this module defines its command line with Cobra: generated
`--help` / `-h`, typed flags, and argument validation. None uses the compiler
CLI's `-Help` spelling, and none parses `os.Args` itself. `verify-benchmarks`
and `verify-examples` take the checkout as `--root`; their earlier `-Root` and
`-Help` are rejected. `prebuild` and `optional-packages` take `check` or
`install` as a command, spelled in lower case, and print their help when no
command is given. An invocation a command does not understand fails before
it reads, probes or installs anything; each command has tests that hold that.

Compiler options, Visual.XSharp.kts evaluation, and user project configuration
are not parsed by these developer tools.

### Diagnostics without changing the machine

`repo-info` reports the checkout root, host architecture, branch, revision,
tracked-change status, and availability of required developer executables.
`--root` may name any location inside the checkout. It deliberately does not
dump environment variables, Git remotes, credential configuration, process
stderr, or tokens. Git queries have a bounded timeout.

The JSON report is intended for local diagnostic automation. Paths can identify
the local user or filesystem layout; review it before posting publicly.
An absent executable is reported as unavailable, not automatically installed.
Availability is not a version-compatibility guarantee; use `prebuild check`
and `develop doctor` for deeper toolchain validation.

### Build arguments and sanitizers

```powershell
go run ./helpers/cmd/develop build -- --jobs=4
go run ./helpers/cmd/develop sanitize address -- --jobs=4
go run ./helpers/cmd/develop bundle
```

Only build-oriented commands forward arguments after `--` to Bazel.
Private `--config` is rejected because the helper selects host and sanitizer
profiles. Unknown subcommands, invalid flags, and positional argument mistakes
fail before tool discovery or build execution. `fuzz-stress --asan=false`
uses Cobra's Boolean parsing rather than treating any token as enabled.

### Installation is explicit

```powershell
go run ./helpers/cmd/prebuild install
go run ./helpers/cmd/optional-packages check
go run ./helpers/cmd/optional-packages install
```

Check operations do not install packages. Install operations retain platform
selection and skip already available tools. Optional comparison-language tools
are not compiler development requirements.

### Guarded Git workflow

From the repository being updated:

```powershell
go run ./helpers/cmd/githelper uncom
go run ./helpers/cmd/githelper update "Describe the change and validation"
```

This command stages, commits, and pushes; it is never invoked by a build.
It excludes ignored and generated paths, keeps local generated files on disk,
and does not force-push. Review the worktree before using `update`.
For other repositories, install the executable and run `githelper` there.

## Independent module development

```powershell
go -C helpers build ./...
go -C helpers test ./...
go -C helpers vet ./...
go -C helpers mod verify
go -C helpers test ./internal/development
```

These also work without the root workspace by setting `GOWORK=off`.
Installed commands discover the checkout through their current directory;
this is not a relocatable packaged compiler SDK.

To install all developer command binaries explicitly:

```powershell
go -C helpers install ./cmd/...
```

Go places executables in `GOBIN`, or its standard Go binary directory when
`GOBIN` is unset. Add that directory to PATH separately if desired.
Building multiple commands with `go build ./...` checks packages without
depositing executables in the source tree.

## Quality and dependency boundaries

`verify-helpers` checks:

- the exact module identity and absence of an obsolete root module;
- regular, non-symlink Go source files with the project SPDX headers;
- the 1,500-line source-file limit and tests for every package;
- gofmt, downloaded module integrity, go vet, and all package tests.

The gate never changes dependency versions or formats files automatically.
Tests inject process runners, so argument-validation tests do not install
packages, compile the compiler, or invoke destructive cleanup.

Cobra and its transitive modules are pinned in `go.mod` and `go.sum`.
Renovate proposes its version updates and Dependabot reports its vulnerabilities; CodeQL builds all packages for Go extraction.
Coverage measures the entire module in one profile, including internal logic.
Use a standalone module gate when checking a dependency upgrade, and commit
the updated module manifest and checksum file together.

Add a command only when it owns useful, testable developer behavior. Move
repeated logic into a focused internal package; do not copy another command's
main file or introduce a second orchestration graph.
