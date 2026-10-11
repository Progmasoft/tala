<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Visual X# project files

## Discovery

Each project has one `BUILD.kts`. Project discovery walks from the requested location toward the filesystem root until
it finds that file. Split module scripts, compatibility setters, and separate project-state files are not supported.

## Minimal project

```kotlin
project {
  name = "Example"
  version = "0.1.0"
  stability = Stability.DEV
  description = "An example application"
  authors("ExamplePublisher")
}

sources {
  executable {
    name = "Example"
    srcDir = "Sources"
    entry = "Example.Main"
  }
}
```

Every executable requires `sources.executable.entry`. The entry is a namespace-qualified class, not a function name. The final
segment is the class name and is not restricted to `Main` or `Program`: `Namespace.Program`, `Namespace.Namespace.Program`,
and `Company.Tool.Bootstrap` are valid. A trailing namespace such as `Namespace.` is invalid. The selected class must declare
a parameterless `public static void Main()` method. Entry resolution uses namespace and type identity; it never derives a
file path from the entry. File names and directory layout do not have to match namespace segments.

The `project` block has a publication-sensitive completeness rule. When `sources.viget.push` is `true`, `name`, `version`,
`stability`, `description`, and at least one author are required. When pushing is disabled, the block may be absent, complete, or contain any useful
subset; private and internal builds are not forced to invent release metadata.

```kotlin
project {
  name = "InternalTool"
}

sources {
  executable {
    entry = "Company.Internal.Tool"
  }
  viget {
    push = false
  }
}
```

## Compiler settings

```kotlin
compiler {
  version = "latest"
  standard = "latest"
  backend = Backend.LLVM
  buildMode = BuildMode.DEBUG
  warnings = Warnings.MEDIUM
  werror = false
  wexperimental = false
  wshadow = false
  wundef = true

  unsafe {
    typeSafeFormat = true
    xppOptimizationPasses = true
    xmmOptimizationPasses = true
  }

  llvm {
    optLevel = LlvmOptLevel.O0
    compiler = LlvmCompiler.AOT
    lto = LlvmLto.NONE
  }
}
```

`typeSafeFormat = true` is the default strict policy: compile-time-known format strings used by formatted Console APIs
must match their argument types. `false` selects the looser C-compatible policy. The name describes strict type safety;
it is not an opt-in to permissive formatting.

## Sources and tests

```kotlin
sources {
  executable {
    name = "Example"
    srcDir = "Sources"
    entry = "Example.Main"
    exclude("Generated/**")
  }

  library {
    name = "ExampleLibrary"
    viPkgType(ViPkgType.VXSLIB, ViPkgType.STATICLIB)
    srcDir = "LibrarySources"
    namespace = "Example.Library"
  }

  test("unit") {
    testDir = "Tests/Unit"
    framework = "tests"
    exclude("Fixtures/**")
  }

  test("integration") {
    testDir = "Tests/Integration"
  }

  viget {
    push = false
    exclude("build/**")
  }
}
```

Source roots must stay inside the project root. The Kotlin runtime validates the configured roots and forwards them with
their exclusion policy; it does not walk the roots or create a `.vxs` file list. Source discovery and namespace-based entry
resolution belong to the compiler. Exclusions accept project-relative glob patterns. Each executable or library target's
`exclude`, each named
test suite's `exclude`, and `sources.viget.exclude` have no implicit pattern: their plan value is `null` until an
`exclude(...)` declaration is present.

The Haskell source loader recursively discovers files whose extension is exactly `.vxs`, sorts project-relative paths
deterministically, and de-duplicates files reached through overlapping roots. Compilation decodes every selected file as
strict UTF-8 before lexing. Tool-only source enumeration does not decode file contents: Visual Formatter owns its configured
input and output encodings instead. A configured root or filesystem link that escapes the project root is an error in both
routes. Exclusions are evaluated
against normalized project-relative paths: `*` and `?` stay within one path segment, while a complete `**` segment may span
zero or more directories.

Physical files are compilation units, not modules. Files with the same namespace are merged before Renamer and Name
Resolution, regardless of their names or directory locations. Duplicate types across those files are diagnosed as duplicate
namespace declarations. All discovered namespaces are checked through CorePrep; the namespace named by `entry` selects the
Core module passed to the native pipeline. Cross-namespace imports and multi-module native linking remain separate compiler
work.

Test suites have case-sensitive Visual X# identifiers and retain their own root, framework, and exclusion policy across the
typed project plan and native compiler boundary. A suite defaults to `Tests/<suite-name>` when `testDir` is omitted. Duplicate
suite names are configuration errors; suites are never flattened into one anonymous test directory.

## Project plugins

Plugins are declared in a top-level preamble so the host can resolve them before Kotlin compiles the rest of the project
script:

```kotlin
plugins {
  plugin("Progmasoft") {
    name = "CMake"
    version = "0.1.0"
  }
}
```

Production Kotlin DSL plugin JARs use
`https://viget.progmasoft.com/dslplugins/<Publisher>/<Name>/`. The catalog's version-index and JAR filename layout are not
yet connected to this runtime. ViGet is the only remote source; there is no configurable repository list. The host currently
loads installed artifacts from the project-local `.visual-xsharp/plugins` cache, which is not another repository. A plugin
JAR contains
`META-INF/visual-xsharp-plugin.properties` and exactly one matching `ProjectPlugin` service. The runtime validates the
coordinate, exact requested version, plugin API version, safe Kotlin imports, and SHA-256 identity before
activation. An adjacent `<plugin.jar>.sha256` file makes the expected digest explicit; the digest is checked again in the
Kotlin process before service loading.

Plugins can register named DSL extensions, contribute deterministic plan metadata, and run finalization hooks. Extension
name collisions and descriptor/service identity mismatches are errors. Plugins are trusted build logic with full JVM and
filesystem access; this infrastructure intentionally does not sandbox or restrict them.

A project can explicitly load a local Kotlin plugin JAR without introducing another repository:

```kotlin
plugins {
  localPlugin {
    path = "plugin.jar"
  }
}
```

The path is project-relative, must remain inside the project root, and must end in `.jar`. Publisher, name, version, and API
identity still come from the verified JAR descriptor rather than the file name or project declaration.

DSL plugins do not have a stability field. `stability` is neither optional nor accepted in hosted or local plugin
declarations, descriptors, plans, or lockfiles.

## Dependencies

Dependencies use exact `Publisher.Name` coordinates and exact semantic versions:

```kotlin
dependencies {
  dependency("Publisher") {
    name = "Name"
    version = "1.2.3"
    stability = Stability.STABLE
  }
}
```

Optional dependencies name a feature and record whether that feature is enabled. The current runtime validates the typed
publisher, package name, stability, and exact version declarations, detects conflicts, and writes that direct manifest to the
lock database. It does not call this a resolved dependency graph. A complete transitive package solver and network package
client are separate implementation work.

Standard-library namespaces are not repeated as package dependencies.

A local Visual X# package is an explicit file source, not a repository coordinate:

```kotlin
dependencies {
  localDependency {
    path = "dependency.vipkg"
  }
}
```

Test-only package files use their own `localTestDependency` declaration and remain separate from production dependencies:

```kotlin
dependencies {
  localTestDependency {
    path = "TestDependency.vipkg"
  }
}
```

The project-relative path must stay inside the project root and use `.vipkg`. The declaration is preserved separately in the
plan and lockfile; it is not misreported as a solved or downloaded ViGet dependency.

Visual X# packages are distinct from Kotlin DSL plugins. They are Visual X#-authored `.vipkg` artifacts cataloged under
`https://viget.progmasoft.com/<Publisher>/<Name>/`; dependency solving and registry transport remain separate work.

ViGet is the one hosted registry. These fixed paths do not create a Gradle-like `repositories` block, and the project DSL
does not accept arbitrary remote repository URLs. Publisher identity is the case-sensitive Progmasoft Account name.

## Lock file

Project evaluation writes `Visual.XSharp.Lockfile.sqlite3`. It is a binary SQLite database, not a text or JSON lock file.
Ordinary evaluation never emits a textual copy. Use the separate Visual XSharp Dumpfile Creator when a reviewable or
replayable SQL representation is needed:

```powershell
vxdc -Projectfile .\Visual.XSharp.kts -Output .\Project.sqlite3.dump
```

VXDC evaluates the named project, refreshes its binary lockfile, validates the lockfile format, and writes deterministic
UTF-8 SQL. The output contains schema and quoted row data inside a transaction and can be replayed by SQLite. Its name must
be supplied explicitly, but VXDC does not impose a filename extension. It refuses to overwrite the binary lockfile with
text.

## Additional blocks

The DSL also supports:

- `outdirs` for Debug and Release output directories;
- `targets` for target triples;
- `project.authors(...)` and `project.defaultFeatures(...)` for publication metadata;
- `pml` for PML enablement; and
- `workspaces` for named project paths.

`panic("message")` immediately aborts project-script evaluation. Because the evaluator emits the plan, source registry, and
lock only after the script returns normally, a panic does not start Visual X# compilation and does not emit partial project
state.

`eprint(value)` and `eprintln(value)` mirror Kotlin's standard output helpers but write to standard error. Both accept
nullable values; `eprintln` appends the platform line separator.

Author declarations are case-sensitive Progmasoft Account names and belong to the project block:

```kotlin
project {
  authors("Leitwolf", "Helmut")
}
```

## Evaluation lifecycle

Project evaluation is an ordered operation rather than serialization of an arbitrary object graph:

1. the native driver discovers the exact `BUILD.kts`;
2. the plugin preamble is parsed early enough to resolve trusted Kotlin plugin JARs;
3. the full script executes with the project DSL;
4. typed scopes validate and produce an immutable plan;
5. plugin finalizers add deterministic extension metadata;
6. the SQLite lockfile is refreshed; and
7. the native driver consumes the plan and starts the requested compiler/tool route.

The plan transport is an implementation boundary, not a second user manifest. Projects do not contain `MANIFEST.TOML`, and
`.vipkg` packages keep the project script at their root as `BUILD.kts` rather than under an extra `XSHARP/`
directory. Test source files are not included in a published `.vipkg`.

Plugin code is trusted build logic with full JVM access. Safety comes from exact identity, contained local paths, descriptor
and service agreement, API-version checks, digest verification, deterministic model validation, and explicit failure—not
from a sandbox that changes Kotlin semantics.

## Output directories and artifact names

Debug and Release output directories are independent DSL values. The defaults are `build/debug` and `build/release`.
The command-line `-Emit` option selects the artifact kind; artifact choice is deliberately not stored in the project DSL.
The chosen output directory continues to come from the evaluated project mode.

Binary emission creates one `<project-or-entry>.vxse`. The project output naming contract for source-owned emissions is to
flatten source stems inside the selected output directory: `Sources/MyApp/Main.vxs` becomes `build/debug/Main.o` for a
debug object build. The original source directory is not reproduced below `build/debug`; multiple sources produce multiple
objects/assembly files, and equal stems are diagnosed as ambiguous instead of overwriting one another.

The project route is connected: source ownership is retained through Xmm, then each source is lowered to its own object or
assembly. All source outputs are planned and generated before existing destinations are replaced. A failure during parsing,
verification, target lowering, or collision checking leaves the previous output set untouched. The compiler does not delete
unrelated or stale sibling files; it replaces only artifacts named by the current source catalog. Explicit `-File` builds
remain separate and emit a sibling artifact. See [Project native artifacts](PROJECT-ARTIFACTS.md) for the exact transaction
and recovery behavior.

## Case sensitivity and paths

Language identifiers, test-suite names, package coordinates, plugin coordinates, targets, and canonical CLI values are
case-sensitive. Filesystem containment is evaluated after canonicalization, so a path that textually begins with the project
directory but resolves outside it is rejected.

Use forward-slash-style project-relative patterns in exclusions. The evaluator preserves null when no `exclude(...)` call is
present; an explicit empty list and the absence of an exclusion policy must not be conflated by transports or plugins.
