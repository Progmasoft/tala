<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Command-line interfaces

Tala ships several programs, and each does one job:

| Program | Job | Written in |
| --- | --- | --- |
| `talac` | the compiler: sources or artifacts in, one artifact out | C++20 |
| `tali` | Tala Interactive, the REPL | C++20 |

Talac knows nothing about projects, dependencies, packages, formatting or linting.

Every command line is read by a parser written by hand for that program. A line that is accepted becomes a typed value,
and no later stage looks at the argument text again. No program uses a command-line library.

Exit codes are shared: `0` success, `1` the work failed (a rejected program, a project that is wrong), `2` the command line
itself was wrong.

## `talac`

```text
talac <input>... [options]
```

```powershell
talac Program.tala --entry=Namespace.Program
.\Program.exe
```

The output is written beside the first input, under that input's name. An executable takes the usual extension of the
host: `.exe` on Windows, none elsewhere.

Several inputs are one program: `talac Main.tala Helper.tala --entry=Demo.Program`. All inputs are of the same kind.

A long option takes its value after `=`: `--emit=core`. A short option takes it joined or after `=`: `-O2`, `-O=2`,
`-tx86_64-pc-windows-msvc`. Not every long option has a short one. `--` ends the options; everything after it is an input.
Names and values are case-sensitive.

| Option | Values | Default |
| --- | --- | --- |
| `--version`, `-v` | prints the version of the compiler | |
| `--help`, `-h` | prints the help | |
| `--entry=` | a namespace-qualified class, `Namespace.Program` | none |
| `--standard=` | `26` | `26` |
| `--target=`, `-t` | an LLVM target triple | the target of the host |
| `--sysroot=` | the system root of the target, for what the build links | the linker's |
| `--incremental=` | a directory that keeps an object per source between builds | off |
| `--static-talart-library=` | `true`, `false`: link TalaRT into the output instead of beside it | `false` |
| `--warnings-as-errors=` | `true`, `false` | `false` |
| `--warnings=` | `none`, `low`, `medium`, `all`, and `shadow` | `medium` |
| `--codegen-backend=` | `llvm` | `llvm` |
| `--opt-level=`, `-O` | `0`, `1`, `2`, `3`, `g`, `s`, `z` | `2` |
| `--llvm-compiler=` | `aot`, `orc` | `aot` |
| `--llvm-lto=` | `fat`, `thin`, `none` | `none` |
| `--llvm-args=` | arguments for LLVM, separated by commas | none |
| `--xpp-optimization-passes=` | `true`, `false` | `true` |
| `--xmm-optimization-passes=` | `true`, `false` | `true` |
| `--emit=` | `executable`, `object`, `core`, `xpp`, `xmm`, `assembly`, `llvm-ir`, `llvm-bitcode`, `metadata` | `executable` |
| `--build=` | `tala`, `object`, `core`, `xpp`, `xmm`, `llvm-ir`, `llvm-bitcode` | `tala` |
| `--vipkg-type=` | `executable`, `staticlib`, `cdylib`, `talalib` | `executable` |
| `--header` | with `--vipkg-type=staticlib` or `cdylib`: also write a C header | off |
| `--test` | build the runner of the `[Fact]` methods instead of a program | off |

### Entry

`--entry` names the class whose parameterless `public static void Main()` starts the program. It is required when
anything is built from Tala sources, and it cannot be written for a library type. An artifact input (`.core`, `.xpp`,
`.xmm`, `.o`) already carries its entry, so `--entry` is rejected there.

Another class of the program may have a `Main` as well; it is an ordinary method. That also holds in a test build, so a
program is tested together with its own `Main`.

A check is the exception. `--emit=metadata` builds nothing, so one source is checked as it stands, with or without a
class that has `Main`:

```text
talac Helper.tala --emit=metadata
```

Several sources are one program, and a program is lowered from its entry, so a check of several sources still needs
`--entry`.

### Linking for another target

Talac links executables itself: LLD's COFF, ELF and Mach-O linkers are linked into it. The target, not the host, decides
how:

| Target | Linker | TalaRT, shared | TalaRT, archive |
| --- | --- | --- | --- |
| Windows (`x86_64`, `aarch64`) | LLD's `lld-link`, on every host, with nothing from the host | `talart.dll` | `talart.lib` |
| the host's own system, architecture and C library | LLD, with the command line `clang` gives for its linker | `libtalart.so`, `libtalart.dylib` | `libtalart.a` |
| another Linux, macOS or BSD target | LLD, with the command line `clang --target=<triple> -fuse-ld=lld` gives | `libtalart.so`, `libtalart.dylib` | `libtalart.a` |

A Linux, macOS or BSD executable needs the start-up objects and the C library of its target, whose places a C compiler
knows. Talac asks `clang` for the command line of its linker (`-###`), which runs nothing, and runs that command line with
LLD. When no `clang` is on `PATH`, a target of the host is linked by `cc` and its own linker instead. Import libraries for
Windows are written by talac too.

TalaRT of the host stands beside talac. TalaRT of another target stands in `runtimes/<triple>/` beside it, under the
normalized triple, for example `runtimes/aarch64-unknown-linux-gnu/libtalart.so`; a program that calls nothing of TalaRT
links without it. A Windows executable needs nothing else: it imports kernel32, or TalaRT, through an import library talac
writes for the target's machine. A Linux, macOS or BSD target also needs its C library, which `--sysroot` names.

```text
talac Program.tala --entry=Demo.Program --target=x86_64-pc-windows-msvc
talac Program.tala --entry=Demo.Program --target=aarch64-unknown-linux-gnu --sysroot=/opt/sysroots/arm64
```

`clang`, and `cc` where no `clang` is found, are looked up on `PATH`; no linker is.

### TalaRT

TalaRT, the Tala runtime, has a shared library and an archive. By default what a build
links takes TalaRT from the shared library: talac copies it beside the output, a Windows executable imports it from there,
and a Linux, macOS or BSD executable finds it there through its run path (`$ORIGIN`, `@executable_path`), so the two move
together. `--static-talart-library=true` links the archive into the output instead, which then needs no file beside it.

TalaRT and the Tala Standard Library are the runtime library and the standard library of talac in the sense of the
Progmasoft Linking Exception, Version 2.0: a program may carry them, beside it or inside it, under the terms of the
program, with no notice.
An installation that has only the archive links the archive either way.

The option concerns every output the build links: executables today, and `staticlib`, `cdylib` and `talalib` when they
are built. A build that links nothing, such as `--emit=metadata`, reads it without effect. A program never links the Tala
frontend: the frontend is part of the compiler, and only talac and tali load it.

A library that carries TalaRT keeps it to itself. `--vipkg-type=staticlib --static-talart-library=true` will make a
static library whose copy of TalaRT is isolated: its symbols are local to the library, so the library links beside TalaRT
or beside another such library without a clash, and each copy keeps its own state. A `cdylib` with TalaRT's archive exports
only its own C interface. Without `--static-talart-library=true`, a library refers to the one shared TalaRT and needs no
isolation.

### Incremental builds

`--incremental=<directory>` builds an executable from one object per source and keeps the objects in the directory. The next
build lowers only the sources whose object would differ:

```text
talac Sources/*.tala --entry=Demo.Program --incremental=.objects
talac: linked native executable 'Sources/Main.exe', 1 of 13 sources recompiled
```

An object is known by a key made of the code of the source, after the frontend and the Xpp and Xmm passes, the signatures of
the functions it calls in other sources, the target, the optimization level and the compiler itself. So a comment or a blank
line recompiles nothing, a changed body recompiles its source alone, and a changed signature also recompiles the sources
that call it. The objects of earlier builds are removed, so one directory serves one program.

A new function recompiles its own source: the objects use symbols made from the source and the name of each function, which
other functions leave alone. The frontend still reads all sources. LLVM optimizes each source alone: calls between sources
are not inlined, so use it for development builds rather than for releases.

`--incremental` needs `--emit=executable` and Tala sources.

### System root

`--sysroot=<path>` hands the linker driver a system root: the directory that holds the C library, its start-up objects
and, for macOS, the SDK of the target. It is written as `--sysroot=<path>` on the command line of `cc`, which clang and GCC
both read. It concerns whatever the build links; a build that links nothing reads it without effect. The path must be a
directory. A Windows output links no system library, only TalaRT and an import library talac writes, so `--sysroot` is
refused when the target is Windows, whichever host talac runs on.

```text
talac Program.tala --entry=Demo.Program --sysroot=/opt/sysroots/ubuntu-26.04-arm64
```

### Tests

`--test` builds the sources as tests. `Fact` holds in their `#if` conditions, and the executable is a runner the compiler
writes: its entry calls every static `[Fact]` method in source order, prints `PASS` or `FAIL` and the name of each, and
ends with the totals. A false `#expect` prints its place and condition, and for a comparison the value of each operand, and
the test goes on. The runner exits with `1` when a test failed and `0` otherwise.

```text
talac Sources/Math.tala Tests/MathTests.tala --test
```

```text
PASS Math.Adds
Tests/MathTests.tala:9:9: expectation failed: Math.Clamp(50, 0, 10) == 9
    Math.Clamp(50, 0, 10) is 10
FAIL Math.Clamps (1 failed expectation)
2 tests, 1 passed, 1 failed
```

A test build has no `--entry`: the runner is its entry. A `[Fact]` method is static, takes no parameters and returns
`void`; a fact of an instance method, of a template class, or facts in more than one namespace are not compiled yet. A
build without `--test` compiles a `[Fact]` method as an ordinary method and leaves out what only `#if Fact` selects.

### Warnings

`--warnings` is the one option that may be written more than once, because it sets two independent things: a level and the
`shadow` warning. `shadow` reports a local that hides a name of an outer scope. No level turns it on, `all` included; it is
asked for by name:

```text
talac Program.tala --entry=Demo.Program --warnings=all,shadow
talac Program.tala --entry=Demo.Program --warnings=all --warnings=shadow
```

A command line holds at most one level and at most one `shadow`. `none` and `shadow` cannot be written together. `shadow`
alone keeps the level at `medium`.

### Inputs and outputs

`--build` says what the inputs are and `--emit` says what to write. The output cannot be an earlier stage than the input.

| `--emit` | Written |
| --- | --- |
| `executable` | a program of the host |
| `object` | `<name>.o` |
| `core`, `xpp`, `xmm` | the verified intermediate artifact of that stage |
| `assembly` | the assembly LLVM generates |
| `llvm-ir`, `llvm-bitcode` | `<name>.ll`, `<name>.bc` |
| `metadata` | `<name>.talameta` |

CorePrep is an internal stage. It has no `--emit` value and no file extension.

`--emit=metadata` checks a program without building it: every verifier runs and no code is generated. A program that is
rejected leaves no file, and an object input cannot be checked. The record is UTF-8 text with one field per line:

```text
talameta 1
compiler 0.1.0
entry Demo.Program
input Sources/Main.tala
input Sources/Helper.tala
```

`entry` is absent when the input carries its own and when a check of one source named none. `input` appears once per
input, as written on the command line, with `/`.

### Not implemented yet

An option the compiler reads but cannot carry out is refused by name with exit code `2`. Nothing is silently ignored.

- `--vipkg-type=staticlib`, `cdylib` and `talalib`, and `--header`
- `--llvm-compiler=orc`
- `--llvm-lto=fat` and `thin`
- `--llvm-args`
- `--build=llvm-ir` and `llvm-bitcode`
- `--warnings=shadow`: the option is read, the warning itself is not in the frontend yet

### The frontend library

Talac loads the Haskell frontend from a shared library beside the executable: `tala-frontend.dll`,
`libtala-frontend.dylib` or `libtala-frontend.so`. It is an implementation library, not a second command.

## `tali`

```text
tali                          # opens the REPL
tali --eval "<expression>"    # evaluates one expression and exits
tali --help | -h
```

See [Tala Interactive](INTERACTIVE.md).
