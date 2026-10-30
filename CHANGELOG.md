<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Changelog

## Unreleased

### Linking

- `--sysroot=<path>` names the system root the linker driver links an
  executable against on Linux, macOS and the BSDs. It needs
  `--emit=executable` and a directory; a Windows executable links no system
  library and refuses it.

### Tests

- `talac --test` builds the runner of the `[Fact]` methods of its sources. The
  runner calls every fact in source order, prints `PASS` or `FAIL` with the
  name of each and the totals, and exits with `1` when a test failed.
- `#expect condition;` checks a condition in test code. A false one prints the
  file, line and column and the text of the condition, and for a comparison
  the value of each operand that is not a literal; the test goes on and fails
  at its end. Each operand is evaluated once, for the comparison and the
  report alike. `#expect` outside a `[Fact]` method and outside `#if Fact` is
  an error (`TAP0044`), and so is `#expect` used as a value (`TAP0055`).
- `[Fact]` and `[Fact("name")]` mark a static, parameterless `void` method as a
  test (`TAE0015` to `TAE0020` for facts that cannot run).

### Conditional directives

- `#if`, `#elseif`, `#else` and `#endif` choose code for the target at the
  boundaries of declarations, members and statements, with `Fact`, `os(...)`,
  `family(...)`, `true`, `false`, `not`, `&&`, `||` and parentheses. Talac
  passes the target's operating system to the frontend.
- `#region` and `#endregion`, with an optional name that the closing directive
  may repeat.
- A directive that would split an expression, an unknown system or family, a
  misplaced `#elseif` or `#else` and an unclosed group are errors (`TAP0042`
  to `TAP0052` and `TAP0054`). `#define` and its symbols and the diagnostic directives are
  refused as not implemented yet (`TAP0053`, `TAP0047`).

### Runtime

- The runtime catalog gains `tala_test_fail`, `tala_test_end` and
  `tala_test_finish` (identities 14 to 16), and the runtime exports
  `tala_test_status`, which the process entry of a test build returns.

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
