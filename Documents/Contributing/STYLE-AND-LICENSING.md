<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Source style, comments, and licensing

Read the surrounding code and the [cross-component contribution contract](../CONTRIBUTING.md) before introducing a new
pattern. This page gives external contributors the high-impact rules that formatting tools cannot infer.

## Names and file ownership

- The canonical C++ namespace root is `Tala`; classes, functions, and namespace components use PascalCase.
  Locals use camelCase, constants `kPascalCase`, and macros `UPPER_SNAKE_CASE`.
- C++20 implementation files use `.cpp`; C++-only headers use `.hpp`. A small C11 `.h` is allowed only for an actual
  stable external ABI such as AARC, with `extern "C"` guards for C++ callers and a C++20 implementation. Do not add a
  project-owned `.c` runtime or revive the retired C compiler route.
- Public compiler headers live under `Talac/Headers/Progmasoft/Tala/` and are included as `Tala/...`.
  Haskell module names follow their existing `Tala.*` ownership; renewed Kotlin package names use
  `com.progmasoft.tala.*`.
- Tests and fixtures live next to their owning component, not in a new root `tests/` bucket. Build targets list their
  owned sources explicitly; do not add a broad recursive glob merely to avoid editing a BUILD file.
- The repository's Go developer tooling lives in `helpers/`. Do not add a second build graph or a new scripting language for
  a routine project command.

The checked-in `.clang-format` file requires LLVM/Clang 23.1.0, uses an 80-column limit, and controls mechanical C++
formatting—not API naming. Haskell uses the repository's Fourmolu configuration. Kotlin formatting is owned by its
component's Gradle checks. Do not reformat vendored Catch3 or another dependency as part of a compiler PR.

## Comments that preserve contracts

Comment the reason a later maintainer could accidentally break an invariant: symbol identity ownership, AARC lifetime,
protocol bounds, source-position rules, wire versioning, deterministic ordering, or why a narrow toolchain workaround
exists. Doxygen documents public C++ interfaces; Haddock documents public Haskell modules and non-obvious contracts.
Keep comments adjacent to the rule they explain and update them when behavior changes. A comment that merely restates
`if` or a function name adds noise rather than context.

For a stable format or ABI, document what consumers may rely on and what remains private. Do not expose LLVM types in
target-independent Core/Xpp/Xmm interfaces. Exceptions must not escape a stable C ABI. State ownership of allocated
resources and failure paths in code and tests.

## Size, decomposition, and generated files

Implementation, test, build, configuration, and internal source files have a 1500-line maximum; 750 lines or fewer is
a useful design target, not a requirement to split coherent code prematurely. Topic-oriented public `Spec/` suites are
exempt. Divide files by behavior—model, verifier, optimization, lowering, diagnostics, or wire I/O—not by arbitrary
line numbers or a catch-all `Utils` module.

Do not commit Bazel output, Cabal `dist-newstyle`, Gradle caches, generated website files, credentials, local paths, or
private service state. Check `git status --short` before staging. The root `.gitattributes` documents line-ending
exceptions; avoid a whole-file LF/CRLF rewrite in a focused PR. Do not delete another contributor's generated output
unless your task created it and you have identified the exact path.

## Copyright and third-party material

The root repository declares MPL-2.0 with the Progmasoft Linking Exception 1.1 for original source and a separate
Progmasoft Patent Grant; read [`LICENSE.txt`](../../LICENSE.txt), [`PATENTS`](../../PATENTS), and the exact texts in
[`LICENSES/`](../../LICENSES/) before changing license-bearing files. Match the SPDX header of nearby project-owned
files. Public documentation and examples are also source files for attribution purposes.

Third-party code retains its own copyright and license. Do not paste code from an incompatible source, erase an upstream
notice, or relicense a submodule by changing a parent `NOTICE.txt` line. If a change genuinely needs new third-party
material, explain its origin, license, build impact, and why an existing dependency is insufficient. The separate Catch3
repository has both Catch2-derived and Progmasoft-authored portions; keep that distinction intact.

This guide is project workflow information, not legal advice. If the licensing or patent status of proposed code is
unclear, ask before submitting that material.
