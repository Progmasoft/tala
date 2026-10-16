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
compiler 0.6.0
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

```text
tazel <command> [arguments]
```

`tazel` works on the project the current directory belongs to: the nearest directory, upward, that holds a
[project file](PROJECT_FILES.md).

| Command | What it does |
| --- | --- |
| `tazel check` | checks the sources without writing an executable |
| `tazel build` | builds the targets |
| `tazel run [-- arguments]` | builds the executables and runs them |
| `tazel test` | builds and runs the test suites |
| `tazel lock resolve` | resolves the dependencies and renews `LOCK.sqlite3` |
| `tazel lock create-dump` | writes `LOCK.dump`, the lockfile as text |
| `tazel update` | updates the dependencies of the system and of the project |
| `tazel install [--global \| -g] Publisher.Name` | downloads a package from ViGet into the project, or into the system |
| `tazel vipkg create` | writes a local `.vipkg` for every target, without testing or publishing |
| `tazel viget push` | builds, tests and publishes the package to ViGet for the first time |
| `tazel viget update` | builds, tests and publishes a new version of the package |
| `tazel fmt [-- options]` | formats the sources with `talafmt` |
| `tazel lint [--workspace] [-- options]` | lints the sources with `talalint` |
| `tazel version` | prints the version of Tazel |
| `tazel help [command]` | prints the help, or the help of one command |

`tazel check` starts Talac with `--emit=metadata` and the compiler options of the project file. `tazel build` starts it
with `--emit=executable` and moves the result into the output directory of the build mode, under the name of the target.

### Selecting targets

`check`, `build`, `run`, `test` and `lint` take a selection. Without one they work on everything.

```text
tazel build --vipkg Name          tazel build -p Name
tazel build --executable Name     tazel build -e Name
tazel build --library Name        tazel build -l Name
```

An option of `tazel` takes its value from the next argument. Each flag may be written several times, and the kinds may be
combined. `--vipkg` keeps the named ViPkgs; once `--executable` or `--library` is written, only named targets remain. A name
that selects nothing is an error.

### Passing arguments on

Everything after `--` goes, unread, to the program the command starts:

```text
tazel run -- --port 8080           # to the program that was built
tazel fmt -- --check               # to talafmt
tazel lint -- --fix                # to talalint
tazel lint --workspace -- --fix
```

### Workspaces

At the root of a workspace, `build`, `check`, `run` and `test` work on every member. `fmt` and `lint` work on the default
members when the workspace names some and on the root otherwise; `tazel lint --workspace` lints every member. Inside the
directory of a member, that member is the project.

### Finding the tools

A tool is looked for in three places, in this order: the path named by `TAZEL_TALAC`, `TAZEL_TALAFMT` or `TAZEL_TALALINT`;
the installation `tazel` runs from; the directories of `PATH`.

### Not implemented yet

These are refused by name with exit code `1`:

- library targets: the compiler cannot write a library yet. A library that sits beside an executable is skipped with a
  warning; a library selected by name is an error.
- projects with dependencies: nothing fetches a dependency or hands it to the compiler yet. `tazel lock resolve` still
  records what the project declares.
- `tazel test` when the selection declares a test suite: Tala has no test framework yet.
- `tazel vipkg create`, `tazel update`, `tazel install`, `tazel viget push` and `tazel viget update`.

`check`, `build` and `run` compile for the host. The `targets` of the project file are recorded and not built.

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
