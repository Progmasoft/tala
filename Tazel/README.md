<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Tazel

Tazel is the build system and package manager of Tala. The name joins Tala and Bazel.

Tazel is a Kotlin program for the JVM (25 or newer). It reads the project file, finds the sources and starts the compiler,
the formatter or the linter as separate programs: `talac`, `talafmt` and `talalint`. It compiles nothing itself and shares
no code with them.

```powershell
tazel check
tazel build
tazel run -- arguments for the program
tazel fmt -- --check
tazel lint -- --fix
```

[Command-line interfaces](../Documents/CLI.md#tazel) lists every command and [Tala project files](../Documents/PROJECT_FILES.md)
describes the project file. [`BUILD.kts`](BUILD.kts) in this directory is the whole DSL in one file; a test evaluates it.

## Layout

| Package | Holds |
| --- | --- |
| `com.progmasoft.tazel.cli` | the command line: the typed parser, the commands, `main` |
| `com.progmasoft.tazel.dsl` | the project DSL, its model and the loader that evaluates a project file |
| `com.progmasoft.tazel.dsl.plugin` | the plugin host: preamble, resolution, verification, activation |
| `com.progmasoft.tazel.driver` | source discovery, compiler arguments, tool lookup, workspaces |
| `com.progmasoft.tazel.lock` | `LOCK.sqlite3` and `LOCK.dump` |
| `com.progmasoft.api.tazel.dsl.plugin` | the API a plugin is written against |

The command line is read by a parser written by hand; there is no command-line library. Terminal output goes through
Mordant. The project file is compiled and run inside Tazel by the embedded Kotlin scripting host, so no Kotlin installation
is needed beside the JRE.

## Building and testing

```powershell
.\gradlew.bat check          # format check and tests
.\gradlew.bat installDist    # build\install\tazel\bin\tazel(.bat)
```

Tazel finds a tool through `TAZEL_TALAC`, `TAZEL_TALAFMT` or `TAZEL_TALALINT`, then in the installation it runs from, then
on `PATH`. To try a development build against a compiler built by Bazel:

```powershell
$env:TAZEL_TALAC = "..\bazel-bin\Talac\Cli\talac.exe"
.\build\install\tazel\bin\tazel.bat build
```

The tests run whole commands against projects on disk with stand-in tools that record their command line, so they need no
compiler.
