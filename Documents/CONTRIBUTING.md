<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Contributing

New contributors should start with the [contributor guide](Contributing/README.md). It covers checkout, toolchain setup,
finding the right component, focused tests, review preparation, and the pull-request workflow. This page records the
cross-component rules that apply to every change.

## Preserve architectural ownership

- Add frontend behavior through CorePrep in Haskell.
- Add Xpp/Xmm and native middle-end behavior in C++20.
- Keep LLVM details inside the backend.
- Keep compiler implementation work in its owning Haskell or C++20 layer. Rust and project-owned C compiler trees are
  retired and must not be recreated as parallel implementations.

## Language and API changes

- Use the `.tala` source extension; an executable takes the usual extension of the host.
- Do not introduce top-level runtime functions as entry points.
- Do not change public API names incidentally during implementation work.
- Fix spelling errors wherever they occur, including API spellings.
- Keep public documentation in en-US English.
- Do not expose internal planning notes in public files.

## Native files

- C++-only headers use `.hpp`.
- C++ implementation files use `.cpp` and compile as C++20.
- Project-owned `.c` implementation files are not accepted. A narrow C11 `.h` header is permitted for a stable external
  ABI such as `AARC.h`; its implementation remains C++20. OS and LLVM C headers may also be included where their platform
  APIs require them.
- C++ namespaces, classes, and functions use PascalCase. The canonical C++ root is `Tala`.
- C++ local variables use camelCase, constants use `kPascalCase`, and macros use `UPPER_SNAKE_CASE`.
- The `tala_aarc_*` runtime entry points are an intentional stable C ABI implemented in C++; do not generalize that
  exception into a C implementation layer.

The checked-in `.clang-format` profile is the mechanical C++20 style authority and requires LLVM/Clang 23.1.0. It uses
four-space Allman layout, return types on their own line, system includes before project includes, indented namespace
bodies, leading continuation operators, west-const spelling, right-aligned pointer/reference declarators, and an 80-column
limit. Run it only on project-owned C/C++ files; never reformat `third_party/` or generated sources.

The style profile does not replace the Tala naming contract above. In particular, do not rename existing functions
to camelCase or introduce storage/pointer prefixes from an external style guide. Public API naming changes remain explicit
architecture decisions rather than formatting work.

For design choices not expressible mechanically, prefer include-what-you-use, value/RAII ownership, explicit structured
runtime errors, early returns, references for required observers, pointers for nullable observers, and synchronization
owned by the state it protects. Exceptions must not cross stable ABI or C boundaries.

## Size and decomposition

Implementation, test, build, configuration, and internal source files must not exceed 1500 lines. Split files by responsibility
before they reach the limit. Public topic-oriented `Spec/` suites are exempt.

Decomposition follows behavior, not arbitrary line slices. A parser can separate tokens, grammar families, recovery, and
diagnostic construction; an IR can separate model, lowering, optimization, verification, and wire I/O; a CLI can separate
schema, conversion, combination validation, help rendering, and dispatch. Avoid a generic `Utils` file that becomes a new
monolith.

## Source comments

Comments should explain invariants, ownership, lifetime, protocol limits, non-obvious language semantics, and the reason for
a workaround. Public APIs and wire formats need enough commentary that a later change cannot accidentally weaken their
contract.

Do not narrate obvious syntax. A useful comment answers one of these questions:

- Why is validation repeated here?
- Which stage owns this identity or type?
- What prevents a stale artifact from being executed?
- Why must ordering remain deterministic?
- Which resource or Unicode limit protects this allocation?
- What upstream issue makes a narrow workaround necessary, and when can it be removed?

Keep comments current with code. Removing or redesigning the behavior includes updating its explanatory comment and tests.

## Change workflow

1. Read the owning public specification and current implementation before choosing a design.
2. Inspect the complete affected model, verifier, lowering, tests, and build target; do not patch only the first search hit.
3. Implement the behavior in the stage that owns it.
4. Add focused positive and negative tests at that stage.
5. Exercise the next representation/process boundary when the data crosses one.
6. Update public documentation when a connected surface, default, artifact, or limitation changes.
7. Run formatting, targeted tests, integrated tests, stale-name scans, and `git diff --check`.
8. Remove only regenerated output created by the work; preserve unrelated local changes.
9. Review the final diff; maintainers can use the Go update helper with a detailed en-US message. External contributors
   normally push their own branch and open a pull request.
10. Inspect every GitHub workflow triggered by the pushed commit.

If the working tree is already dirty, distinguish the user's changes from the current task. Do not reset, overwrite, or fold
unrelated work into a mechanical rewrite merely to make the status shorter.

## Public documentation

Public documentation lives under `Documents/`; language design examples live under `Spec/`. Use en-US English, repository-
relative links, and the current public vocabulary. Internal notes and private paths are not cited from public files.

Mark behavior as connected, implemented, partial, registered, planned, or legacy. Avoid future-tense prose that sounds like a
current guarantee. Command examples must use the case-sensitive spelling accepted by the CLI, and artifact examples must not
expose CorePrep as a public file.

When renaming a document or directory, update root/component READMEs, `Spec/` links, changelog references where they describe
the maintained path, and any legacy component guide that linked to the old location. Scan for the old spelling after the move.

## Verification

Run the checks appropriate to the changed ownership boundary:

- Haskell: keep every component on the repository-wide `GHC2024` edition, then run `cabal build all`, `cabal test all`,
  and `cabal check`.
- Kotlin: `Tazel\gradlew.bat -p Tazel test`.
- Native: `go run ./helpers/cmd/develop test` on an official Windows 10/11, macOS 26 Tahoe or Ubuntu 26.04 LTS host.
- Sanitizers: `go run ./helpers/cmd/develop sanitize address`; macOS also exposes `undefined` and `thread`.
- C/C++ style: LLVM 23.1.0 `clang-format --dry-run --Werror` over project-owned `.cpp`, `.hpp`, `.hh`, and `.h` files.
- C/C++ static analysis: `go run ./helpers/cmd/develop tidy` runs `clang-tidy` with the repository configuration over
  every first-party translation unit, and `go run ./helpers/cmd/develop analyze` runs the Clang Static Analyzer over
  the same units.
- Documentation: link scan, spelling scan, and `git diff --check`.

Initialize recursive submodules before native configuration. Do not store machine-specific LLVM or toolchain paths in tracked
configuration.

## Commits

Use the repository Go helper for normal updates:

```powershell
go run ./helpers/cmd/githelper start feature/name
go run ./helpers/cmd/githelper update "Detailed change description"
go run ./helpers/cmd/githelper sync
go run ./helpers/cmd/githelper push
```

| Command | Effect |
| --- | --- |
| `start <branch>` | create a topic branch from the remote default branch; needs a clean work tree |
| `update [message]` | stage every change, commit, and push the current branch; `--message-file` reads the message from a file, `--dry-run` only reports the scope, `--no-push` only commits |
| `push` | push existing commits, such as a merge, without creating a commit |
| `sync` | fetch and merge the remote default branch into the current branch; it does not push, so the merged tree can be tested first |
| `status` | show the upstream and default-branch distance and the uncommitted changes |
| `clean` | remove generated and ignored files from the index without committing |

The helper excludes generated and local-only paths, applies recursive submodule file-mode hygiene, and never forces a push.
`update` refuses to commit on the default branch unless `--allow-default-branch` is given, and prints the staged scope by
top-level directory before it commits. The commit message is committed as written. It is a maintainer convenience, not a
requirement for external contributors.

The commit message should state the user-visible or architectural outcome and the verification performed, not merely “update
files.” Generated output, caches, local credentials, internal service state, and ignored nested-repository content remain out
of the root commit.
