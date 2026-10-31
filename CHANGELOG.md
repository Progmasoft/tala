<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Changelog

## Unreleased

### Compile times

- The frontend spends about half as long in garbage collection, with no more
  memory.

### Licensing

- Project files move to the Progmasoft Linking Exception, Version 2.0. Code talac
  generates, TalaRT and the standard library no longer put any duty on a program
  built with talac. Earlier releases can rely on Version 2.0 too.

### Incremental builds

- `--incremental=<directory>` keeps an object per source and lowers only the
  sources whose code, or the signature of what they call, changed. The sources
  that do change are lowered on several threads.

### Linking

- LLD's COFF, ELF and Mach-O linkers are linked into talac, which links
  executables itself. A Windows executable needs nothing from the host, and
  its import libraries are written by LLVM. For Linux, macOS and the BSDs
  talac takes the command line of the linker from `clang -###`, which knows
  where the target's C library is, and runs it with LLD; without `clang`, a
  target of the host is linked by `cc` as before. Building talac needs LLD's
  static libraries and headers: the LLVM release for Windows has them, the
  Linux toolchain carries them from revision 2, and on macOS they are built
  from the LLVM sources against Homebrew's LLVM, because Homebrew's `lld` has
  only shared libraries; `LLD_ROOT` names them where they are not beside
  LLVM.

- An executable is linked for its target rather than for the host: a Windows
  executable for the machine of the target from any host, and another Linux,
  macOS or BSD target through `clang --target=<triple>`. The runtime of another
  target is looked up in `runtimes/<triple>/` beside talac.

- `--sysroot=<path>` names the system root the linker driver links against
  on Linux, macOS and the BSDs; it must be a directory. A Windows target
  links no system library and refuses it, whatever the host.
- The Tala runtime is TalaRT: `talart.lib` and `libtalart.a` as archives,
  `talart.dll`, `libtalart.so` and `libtalart.dylib` as shared libraries.
  By default a program takes TalaRT from the shared library, which talac
  copies beside it and which it finds there through its run path or the
  Windows loader. `--static-talart-library=true` links the archive in
  instead.
- A Windows executable defines `_fltused` itself, so code that uses floating
  point links without TalaRT's archive.

### Tests

- A class other than the entry may have a `Main`: it is an ordinary method, and
  no longer stops the build with TAL2008. A test build of a program with a
  `Main` compiles for the same reason.
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

### Optimization levels

- `--opt-level=s` and `-Os` optimize without growing the code, and
  `--opt-level=z` and `-Oz` make it as small as LLVM can. As in Clang, both
  run the default pipeline over functions marked `optsize`, and `z` also
  `minsize`.
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
