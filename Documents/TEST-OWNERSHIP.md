<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Test ownership

Tests in the Tala monorepo live beside the component whose contract they
protect. There is no repository-wide `tests/` bucket. This layout keeps Bazel
labels, fixtures, and review ownership aligned with production boundaries.

## Directory model

| Component | Test root | Primary responsibility |
| --- | --- | --- |
| Artifact paths | `Talac/Artifact/Tests` | normalized source identity and portable path validation |
| CLI | `Talac/Cli/Tests` | commands, options, precedence, diagnostics |
| Core | `Talac/Core/Tests` | Core model, verifier, artifacts, golden wire |
| Driver | `Talac/Driver/Tests` | connected stage and end-to-end compiler flow |
| LLVM backend | `Talac/Backend/LLVM/Tests` | LLVM IR, object, and native artifact lowering |
| Haskell frontend | package-local `test/` trees | lexer through CorePrep semantics |

A new component creates its own `Tests` directory when it gains tests. It does
not add files to a common fallback directory.

## Choosing the owner

Choose the narrowest component capable of observing the contract. A CLI token
classification belongs to CLI tests even if the command eventually starts the
compiler. A Core decoder limit belongs to Core tests. A scalar value crossing
Core, CorePrep, Xpp, and Xmm belongs to Driver integration tests because no
single model owns the whole route.

Backend tests may construct Xmm directly when testing instruction selection.
They should use the full driver only when artifact coordination is itself the
subject of the test.

## Unit and integration boundaries

Component-local tests may still have different scopes:

- a unit test exercises a model, parser, verifier, or helper without starting
  another component;
- a boundary test checks one producer/consumer pair;
- an integration test crosses several compiler stages; and
- a process test executes a shipped binary and validates streams, exit code,
  and artifact behavior.

The directory is selected by contract ownership, not by the testing framework
or the number of stages involved.

## Fixture ownership

Fixtures follow their tests. Core wire golden files live below
`Talac/Core/Tests/Fixtures`. The driver tests build their programs in the test
itself, and the bundle smoke test compiles `Examples/HelloWorld`. Retired
intermediate examples, their readers and the source fixtures of the former
project driver are removed rather than retained as a second pipeline.

Do not create a common fixture directory merely because two components use the
same file today. If the file represents a stable boundary, the producer owns
the canonical copy and consumers depend on that target. If it is just input,
small intentional duplication is preferable to hidden cross-component test
ownership.

Generated fixtures must be clearly marked and reproducible. Verification may
create temporary outputs, but those outputs are removed before a change is
committed.

## Bazel packages

Each native `Tests` directory is a Bazel package with private default
visibility. Public production targets may be dependencies of tests; test
binaries do not become production dependencies.

Representative labels are:

```text
//Talac/Artifact/Tests:source_path_tests
//Talac/Cli/Tests:cli_parser_tests
//Talac/Cli/Commands/Tests:execution_status_tests
//Talac/Cli/Commands/Tests:cli_command_tests
//Talac/Cli/Commands/Tests:executable_run_tests
//Talac/Runtime/Text/Tests:text_runtime_tests
//Talac/Core/Tests:core_pipeline_tests
//Talac/Driver/Tests:closure_pipeline_tests
//Talac/Driver/Tests:project_artifact_tests
//Talac/Driver/Tests:scalar_pipeline_tests
//Talac/Backend/LLVM/Tests:llvm_backend_tests
```

Targets list source files explicitly. Broad recursive globs are not used to
make every new file part of an unrelated test binary.

## Golden wire documents

A golden artifact includes the wire version in its filename. Its comment also
states the contract and version, and its header bytes must agree. A schema
change updates the writer, reader, verifier, cross-language tests, and golden
file in one change.

Tests must not silently regenerate a golden file before comparing it. A writer
round trip and a stable-byte comparison answer different questions and both
are valuable.

## Cross-language tests

The Haskell and C++ implementations require independent checks. A Haskell
round trip can pass when its writer and reader share the same wrong tag. Native
golden decoding and native round trips catch a different class of defect.

For a wire change, cover at least:

1. Haskell writer and reader round trips;
2. C++ writer and reader round trips;
3. versioned golden bytes;
4. unsupported old and future versions;
5. malformed and truncated input; and
6. semantic verification after decode.

## Test naming

Names describe behavior and boundary, not implementation trivia. Prefer
`Core wire v7 rejects a noncanonical integer magnitude` over `test decode 7`.
Use tags where the framework supports them so scalar, verifier, wire, and LLVM
groups can be selected without changing ownership.

## Failure diagnostics

A test failure should identify the relevant value, source spelling, type, or
expected instruction. Table-driven loops capture the case before assertions.
Avoid one assertion that combines many unrelated conditions and hides the
actual boundary that failed.

Negative tests check stable diagnostic codes or error categories where those
are public compiler contracts. They do not depend on incidental prose unless
the prose itself is the CLI contract under test.

## Platform-sensitive tests

Native artifact tests state their toolchain requirements. LLVM discovery uses
the configured toolchain environment rather than a machine-specific absolute
path in source or Bazel files. Windows tests use ClangCL and C++20 according to
the repository toolchain configuration.

Filesystem tests use exact `.tala` case rules and avoid assumptions about the
current working directory. Paths should derive from declared Bazel data,
package-local fixtures, or the source file location when the test is only
built and run from a checkout.

## Required local gates

Run the narrow target while developing, then the component set affected by the
change. A scalar pipeline change normally runs:

```powershell
cabal test all
bazelisk build //Talac/Cli/Tests:cli_parser_tests `
  //Talac/Cli/Commands/Tests:execution_status_tests `
  //Talac/Driver/Tests:closure_pipeline_tests `
  //Talac/Driver/Tests:scalar_pipeline_tests `
  //Talac/Core/Tests:core_pipeline_tests `
  //Talac/Backend/LLVM/Tests:llvm_backend_tests
```

The LLVM target requires the repository-supported LLVM discovery environment.
No path to one developer's LLVM installation belongs in committed build
metadata.

## Review checklist

Before completing a test change, verify that:

- the test is located beside the owning component;
- fixtures are below that component's test root;
- production code does not depend on a test target;
- Bazel sources and dependencies are explicit;
- success and important rejection paths are covered;
- error assertions use stable categories;
- moved paths are removed from docs, workflows, and REUSE metadata;
- no root `tests/` directory has been recreated; and
- generated build outputs are absent from the working tree.

This structure makes the monorepo read as a collection of independently owned
compiler components while preserving one connected toolchain.
