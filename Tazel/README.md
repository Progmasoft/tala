<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Tazel

Tazel is the build system and package manager of Tala. The name joins Tala and Bazel.

This Java 25/Kotlin component evaluates the single `BUILD.kts` project file used by `talac`. It resolves source roots,
compiler settings, targets, dependencies, named test suites, and publication metadata into the native compiler plan. It has
no standalone launcher: `talac` invokes its main class directly from the bundled JVM classpath. `tadc` remains a separate
command and shares the same libraries.

Production Kotlin DSL plugin JARs use
`https://viget.progmasoft.com/dslplugins/<Publisher>/<Name>/`. ViGet is the only remote source. The current host skeleton
loads installed JARs from the project-local `.tazel/plugins` cache; this cache is not a second repository. It reads
the `plugins` preamble before evaluating the script, verifies descriptor compatibility and artifact identity, then loads
`ProjectPlugin` services. Plugins are trusted project code and run with full JVM access; the runtime does not impose a
sandbox or permission model.

Explicit `plugin("local") { path = "plugin.jar" }` declarations load a project-relative JAR while retaining descriptor and
digest verification. Explicit `dependency("local") { path = "dependency.vipkg" }` declarations record a project-relative
Tala package separately from ViGet coordinates.

Split project scripts and separate module scripts are not supported. Project discovery walks from the requested path toward
the filesystem root until it finds `BUILD.kts`.

Dependency resolution writes `LOCK.sqlite3` as binary SQLite data. Human-readable dumps belong to the
separate `tadc` tool and are not emitted during ordinary project evaluation.

Run the component tests with:

```text
.\gradlew.bat check
```

For the complete DSL contract, publishing completeness rules, local artifacts, lockfile lifecycle, and CLI precedence, see
[Tala project files](../Documents/PROJECT_FILES.md).
