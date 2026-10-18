<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Command-line interfaces

Tala ships several programs, and each does one job:

| Program | Job | Written in |
| --- | --- | --- |
| `talac` | the compiler: sources or artifacts in, one artifact out | C++20 |
| `tazel` | the build system and package manager: reads the project file and starts the others | Kotlin |
| `tali` | Tala Interactive, the REPL | C++20 |
| `talafmt` | the formatter | Haskell |
| `talalint` | the linter | Haskell |

Talac knows nothing about projects, dependencies, packages, formatting or linting. `tazel` compiles nothing: it starts
Talac, `talafmt` and `talalint` as separate programs and passes them arguments.

Every command line is read by a parser written by hand for that program. A line that is accepted becomes a typed value,
and no later stage looks at the argument text again. No program uses a command-line library.

Exit codes are shared: `0` success, `1` the work failed (a rejected program, a project that is wrong), `2` the command line
itself was wrong. `tazel run` hands through the exit code of the program it ran.

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
| `--warnings-as-errors=` | `true`, `false` | `false` |
| `--warnings=` | `none`, `low`, `medium`, `all`, and `shadow` | `medium` |
| `--codegen-backend=` | `llvm` | `llvm` |
| `--opt-level=`, `-O` | `0`, `1`, `2`, `3`, `g` | `2` |
| `--llvm-compiler=` | `aot`, `orc` | `aot` |
| `--llvm-lto=` | `fat`, `thin`, `none` | `none` |
| `--llvm-args=` | arguments for LLVM, separated by commas | none |
| `--xpp-optimization-passes=` | `true`, `false` | `true` |
| `--xmm-optimization-passes=` | `true`, `false` | `true` |
| `--emit=` | `executable`, `object`, `core`, `xpp`, `xmm`, `assembly`, `llvm-ir`, `llvm-bitcode`, `metadata` | `executable` |
| `--build=` | `tala`, `object`, `core`, `xpp`, `xmm`, `llvm-ir`, `llvm-bitcode` | `tala` |
| `--vipkg-type=` | `executable`, `staticlib`, `cdylib`, `talalib` | `executable` |
| `--header` | with `--vipkg-type=staticlib` or `cdylib`: also write a C header | off |

### Entry

`--entry` names the class whose parameterless `public static void Main()` starts the program. It is required when
anything is built from Tala sources, and it cannot be written for a library type. An artifact input (`.core`, `.xpp`,
`.xmm`, `.o`) already carries its entry, so `--entry` is rejected there.

A check is the exception. `--emit=metadata` builds nothing, so one source is checked as it stands, with or without a
class that has `Main`:

```text
talac Helper.tala --emit=metadata
```

Several sources are one program, and a program is lowered from its entry, so a check of several sources still needs
`--entry`.

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

## `tazel`

Tazel has a repository of its own, [Progmasoft/tazel](https://github.com/Progmasoft/tazel), and documents its command line there:
[The `tazel` command](https://github.com/Progmasoft/tazel/blob/main/Documents/CLI.md). It is also published at
[tazel.tala.run](https://tazel.tala.run/).

## `tali`

```text
tali                          # opens the REPL
tali --eval "<expression>"    # evaluates one expression and exits
tali --help | -h
```

See [Tala Interactive](INTERACTIVE.md).

## `talafmt`

```text
talafmt [options] <file>...
```

Without options `talafmt` formats each file in place and prints nothing.

| Option | Effect |
| --- | --- |
| `--check` | reports whether a file needs formatting; changes nothing |
| `--emit=files` | writes the formatted source over the file; the default |
| `--emit=stdout` | prints the formatted source; changes nothing |
| `--emit=coverage` | reports how much of the source was formatted; changes nothing |
| `--emit=checkstyle` | prints a Checkstyle report; changes nothing |
| `--emit=json` | prints the differences as JSON; changes nothing |
| `--help`, `-h` | prints the help |
| `--version`, `-v` | prints the version |

## `talalint`

```text
talalint [options] <file>...
```

`talalint` reports what it finds. `--fix` also applies the fixes that are safe to apply. `--help`, `-h`, `--version` and
`-v` work as they do for `talafmt`.

Both tools take several files, read `--` as the end of the options, and exit with `2` for a command line they cannot read.
