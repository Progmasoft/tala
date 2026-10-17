<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Tala project files

A project is described by one file, a Kotlin script that [Tazel](CLI.md#tazel) evaluates. Tazel reads it, finds the
sources it names and starts the compiler; the compiler itself never sees a project file.

## Discovery

A project file has one of five names. Tazel looks for them in this order and uses the first that exists; the others are
not read:

1. `BUILD.kts`
2. `BUILD.tzl`
3. `BUILD.tazel`
4. `BUILD`
5. `Tazel.build`

The names are case-sensitive on every host, and all five hold the same syntax. A command works on the project of the
current directory: the nearest directory, upward, that holds a project file.

The script is compiled and run inside Tazel. A machine needs a JRE 25 or newer and no Kotlin installation.

## Minimal project

```kotlin
project {
  name = "Example"
}

sources {
  executable {
    entry = "Example.Program"
  }
}
```

```powershell
tazel run
```

This compiles every `.tala` file below `Sources/` and writes `build/debug/Example.exe` (no extension outside Windows).

[`Tazel/BUILD.kts`](../Tazel/BUILD.kts) shows the whole DSL in one file. What is not in that file is not part of the DSL.

## `project`

```kotlin
project {
  name = "Example"
  version = "0.1.0"
  stability = Stability.STABLE // STABLE, UNSTABLE, BETA, NIGHTLY, ALPHA or DEV
  description = "A Tala project"
  authors("Leitwolf", "Helmut")
  defaultFeatures("TOML")
}
```

Every field is optional on its own. With `sources.viget.push = true`, `name`, `version`, `stability`, `description` and at
least one author are required; this is checked once the whole file has run, so the order of the blocks does not matter.
`name` is one identifier and `version` is an exact semantic version.

## `compiler`

```kotlin
compiler {
  standard = talaStandardOf(26)
  backend = Backend.LLVM
  buildMode = BuildMode.RELEASE
  werror = true
  warnings = Warnings.ALL
  wshadow = true
  xppOptimizationPasses = true
  xmmOptimizationPasses = true
  optLevel = OptLevel.O3

  llvm {
    compiler = LlvmCompiler.AOT
    lto = LlvmLto.NONE
    args("-time-passes")
  }
}
```

| Setting | Values | Default | Compiler option |
| --- | --- | --- | --- |
| `standard` | `talaStandardOf(26)` | `talaStandardOf(26)` | `--standard` |
| `backend` | `Backend.LLVM` | `LLVM` | `--codegen-backend` |
| `buildMode` | `BuildMode.DEBUG`, `RELEASE` | `DEBUG` | chooses the output directory and the default `optLevel` |
| `werror` | `true`, `false` | `false` | `--warnings-as-errors` |
| `warnings` | `Warnings.ALL`, `MEDIUM`, `LOW`, `NONE` | `MEDIUM` | `--warnings` |
| `wshadow` | `true`, `false` | `false` | `--warnings=shadow` |
| `xppOptimizationPasses` | `true`, `false` | `true` | `--xpp-optimization-passes` |
| `xmmOptimizationPasses` | `true`, `false` | `true` | `--xmm-optimization-passes` |
| `optLevel` | `OptLevel.O0`, `O1`, `O2`, `O3`, `OG` | `O0` for `DEBUG`, `O3` for `RELEASE` | `--opt-level` |
| `llvm.compiler` | `LlvmCompiler.AOT`, `ORC` | `AOT` | `--llvm-compiler` |
| `llvm.lto` | `LlvmLto.FAT`, `THIN`, `NONE` | `NONE` | `--llvm-lto` |
| `llvm.args(...)` | arguments for LLVM | none | `--llvm-args` |

Tazel writes every setting onto the compiler's command line, the ones at their default too, so a build follows from the
project file and not from the defaults of whichever compiler is installed. A setting the compiler cannot carry out yet is
refused by the compiler, by name; see the [compiler reference](CLI.md#not-implemented-yet).

No warning level turns `wshadow` on. `wshadow = true` with `Warnings.NONE` is a contradiction and is rejected.

`compiler.version` is the version of the compiler that will build the project. A project file reads it and cannot set it.

## `outdirs`, `targets` and `pml`

```kotlin
outdirs {
  release = "build/release"
  debug = "build/debug"
}

targets {
  target("x86_64-pc-windows-msvc", "aarch64-apple-darwin")
}

pml {
  enabled = true
}
```

Output directories are relative to the project file and stay inside the project. An artifact is named after its target:
`build/debug/<name>.exe` for a build, `build/debug/<name>.talameta` for a check.

`targets` lists the LLVM target triples the package is meant for; the default is the target of the host. `check`, `build`
and `run` compile for the host. `pml.enabled = false` is meant to close the Progmasoft Library (`Progmasoft.*`) to the
project; the setting is recorded, and the compiler has no option for it yet.

## `sources`

```kotlin
sources {
  viget {
    push = true
    exclude("build/**/*")
  }

  executable {
    name = "Example"
    srcDir = "Sources"
    exclude("Sources/Generated")
    entry = "Example.Program"
  }

  library {
    name = "ExampleLibrary"
    viPkgType(ViPkgType.TALALIB, ViPkgType.STATICLIB)
    srcDir = "Sources"
    namespace = "Example.Library"
  }

  test("Unit") {
    testDir = "Tests/Unit"
  }
}
```

A project has any number of executables and libraries. `name` defaults to the name of the project, so a target of a project
without a name has to name itself; names are case-sensitive and unique within their kind. `srcDir` defaults to `Sources`.

`entry` names a class by its namespace: `Example.Program`. That class provides the parameterless
`public static void Main()` that starts the program. The entry is found by namespace and class, not by file: neither file
names nor directories have to mirror namespaces. A library has no entry; `namespace` names its root namespace.
`viPkgType` is `TALALIB` unless the library says otherwise; `STATICLIB` and `CDYLIB` are the other kinds.

The sources of a target are every file below its `srcDir` whose name ends in `.tala`, written exactly so. Symbolic links
are not followed. `exclude` takes patterns relative to the project file, written with `/`:

- `*` and `?` match within one path segment;
- a segment that is `**` matches any number of segments;
- a pattern that names a directory excludes everything below it.

Patterns are compared the way the host compares file names: without regard to case on Windows, exactly elsewhere.

`test("Name")` declares a named test suite; a name is one identifier and may be declared once. `testDir` defaults to
`Tests/<name>`. Test sources and test artifacts never enter a `.vipkg`. `sources.viget.exclude` removes further files from
what is packaged.

## `dependencies`

```kotlin
dependencies {
  dependency("Publisher") {
    name = "Name"
    version = "1.2.3"
    stability = Stability.STABLE
  }

  dependency("Publisher") {
    name = "Toml"
    version = "1.0.0"
    feature = "TOML"
    defaultFeatures = false
    feature("Serde") { enabled = true }
  }

  localDependency { path = "Dependency.vipkg" }

  testDependency("Publisher") {
    name = "TestDep"
    version = "0.1.0"
  }

  localTestDependency { path = "TestDependency.vipkg" }
}
```

A dependency is a package of ViGet, written as a publisher, a name and an exact semantic version. `stability` defaults to
`STABLE`. The publisher is the case-sensitive name of a Progmasoft Account. ViGet is the only remote source: there is no
list of repositories and no way to name another one.

`feature = "TOML"` makes the dependency optional: it is brought in only when the feature `TOML` of this project is on.
`defaultFeatures` and `feature("Name") { enabled = true }` choose among the features of the dependency itself.

`localDependency` names a `.vipkg` inside the project directory. `testDependency` and `localTestDependency` serve the test
suites only. A package may be declared once per kind; two declarations of one package that differ are an error.

Tazel records the declarations and does not fetch them yet, so `check`, `build` and `run` refuse a project that declares a
dependency of the build. The namespaces of the standard library are not dependencies and are never declared.

## `workspace`

```kotlin
workspace {
  members("./Server", "../Shared", "Client")
  defaultMembers("./Server", "../Shared")
  exclude("OldProject")
}
```

Each member is a directory with a project file of its own, written relative to this project file. A project that only
gathers members needs no `sources`. `defaultMembers` are the members `tazel fmt` and `tazel lint` work on at the root;
`exclude` removes a directory from the members. See [workspaces](CLI.md#workspaces).

## `plugins`

Plugins extend the DSL. They are declared in a `plugins` block that Tazel reads before it compiles the rest of the file:

```kotlin
plugins {
  plugin("Progmasoft") {
    name = "CMake"
    version = "0.1.0"
  }

  localPlugin {
    path = "plugin.jar"
  }
}
```

A plugin of ViGet is found in the cache of the project, `.tazel/plugins`; fetching it from
`https://viget.progmasoft.com/dslplugins/tazel/<Publisher>/<Name>/` is not connected yet. A local plugin is a JAR inside the
project directory. Either way the JAR describes itself in `META-INF/tazel-plugin.properties` (publisher, name, version,
API version, the imports it adds to the project file) and provides exactly one `ProjectPlugin` service. Tazel checks the
coordinate, the version, the API version and the SHA-256 digest before it loads the plugin; a `<plugin>.jar.sha256` file
beside the JAR pins the expected digest. A plugin has no stability.

A plugin is written against the package `com.progmasoft.api.tazel.dsl.plugin`. It can register DSL extensions, contribute
metadata and run a hook once the project is complete. A plugin is trusted build logic: it runs with the full access of
the JVM, and Tazel does not sandbox it.

## Host values and helpers

| Name | Meaning |
| --- | --- |
| `OS` | the operating system Tazel runs on: `OperatingSystem.LINUX`, `MACOS`, `WINDOWS`, `FREEBSD`, `OPENBSD`, `NETBSD` or `UNKNOWN` |
| `ARCH` | its processor architecture: `Architecture.X86_64`, `AARCH64`, `ARMV7H`, `RISCV64` or `UNKNOWN` |
| `panic(message)` | stops the evaluation; the command fails with the message |
| `eprint(value)` | writes to the standard error stream |

```kotlin
if (OS == OperatingSystem.OPENBSD) panic("this project does not build on OpenBSD")
```

After its `project` and `compiler` blocks a project file can read back what it wrote: `project.name`,
`compiler.standard`, `compiler.version`.

## Lockfile

`LOCK.sqlite3`, beside the project file, is an SQLite database that records the dependencies the project declares and the
plugins that evaluated it. `tazel lock resolve` renews it; `check`, `build` and `run` renew it when it no longer matches
the project file. It records declarations, not a solved dependency graph.

`tazel lock create-dump` writes `LOCK.dump`: the same content as SQL text, deterministic and replayable by SQLite, for
review and for diffs.

## Tool configuration

`talafmt.kts`, `talalint.kts` and `tala-analyzer.kts` configure the formatter, the linter and the analyzer. Each tool uses
its defaults when its file is absent.
