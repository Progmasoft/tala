<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Changelog

## Unreleased

### Optimization levels

- `--opt-level=s` and `-Os` optimize without growing the code, and
  `--opt-level=z` and `-Oz` make it as small as LLVM can (LLVM's `Os` and
  `Oz` pipelines).
- `--opt-level=g` runs the optimizations of level `1`, which keep a program
  easy to debug, as Clang's `-Og` does. It ran none before, like `0`.

## 0.1.0 - 2026-10-18

### The numbering starts again

Tala restarts its version at 0.1.0. The numbers up to 0.6.0 were inherited
from the projects Tala grew out of, X# and Visual X#. Their tags and releases
stay as they were. From now on a release of the compiler repository is tagged
`tala-<version>`, and the Haskell packages, `talac --version` and the bundle
carry the same number. The language and the compiler did not change
because of the new number: Tala 0.1.0 accepts what 0.6.0 accepted.

### Packages

- `tala-tooling` is the one compiler package that talafmt, talalint and
  tala-analyzer depend on. It re-exports the six modules they use.
- The shared library talac loads, its C ABI and the frontend fuzzer moved to
  `tala-frontend-host`, which is not published. `tala-syntax`,
  `tala-frontend`, `tala-core`, `tala-compiler` and `tala-tooling` carry the
  metadata, bounds and license files that Hackage asks for.

### Building and testing

- On Linux the compiler builds with libc++ against an LLVM 22.1.6 built with
  libc++, which the helpers download and check against a recorded digest.
- The official hosts are the ones the workflows test: Windows 10/11 (tested on
  Windows Server 2025), macOS 26 Tahoe on Apple silicon and Ubuntu 26.04 LTS.
  macOS 15, macOS on Intel and Fedora 43 are no longer tested.
- A pull request that changes nothing the native build reads skips the native
  jobs.
- The fuzzing workflow adds AFL++ with CmpLog over the wire and command-line
  targets. The Go helpers present the programs they start as steps.
- OSV-Scanner checks the locked dependencies. Every pinned action names its
  exact version.

## Before 0.1.0

The releases up to 0.6.0 used the numbering inherited from X# and Visual X#.
Their notes are in [CHANGELOG-PREVIOUS.md](CHANGELOG-PREVIOUS.md).
