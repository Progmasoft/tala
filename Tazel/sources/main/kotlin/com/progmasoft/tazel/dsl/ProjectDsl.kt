/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl

@TazelDsl
class ProjectScope internal constructor() {
  var name: String? = null
  var version: String? = null
  var stability: Stability? = null
  var description: String? = null
  private val authors = mutableListOf<String>()
  private val defaultFeatures = mutableListOf<String>()

  fun authors(vararg values: String) {
    authors += values
  }

  fun defaultFeatures(vararg values: String) {
    defaultFeatures += values
  }

  internal fun apply() {
    // Publication is configured later in many project files, so completeness
    // cannot be decided while this block is evaluated. Preserve every supplied
    // value and enforce the publication contract once the whole model is built.
    ProjectRuntime.configureIdentity(
      ProjectIdentity(name, stability, version, description),
      authors,
      defaultFeatures,
    )
    projectView = this
  }
}

// What the last `project` block wrote, for a project file that reads it back afterwards.
private var projectView: ProjectScope? = null

internal fun forgetProjectView() {
  projectView = null
}

@TazelDsl
class ExecutableSourcesScope internal constructor() {
  var name: String? = null
  var srcDir: String = "Sources"
  var entry: String? = null
  internal var excludes: MutableList<String>? = null

  fun exclude(vararg patterns: String) {
    val configured = excludes ?: mutableListOf<String>().also { excludes = it }
    patterns.forEach { configured += requireText(it, "executable source exclude") }
  }

  internal fun build(defaultName: String?): ExecutableSourceTarget {
    val targetName =
      requireModuleSegment(
        name
          ?: defaultName
          ?: throw ProjectConfigurationException(
            "sources.executable.name is required when the project has no name"
          ),
        "executable name",
      )
    val targetEntry =
      entry ?: throw ProjectConfigurationException("sources.executable.entry is required")
    requireQualifiedTypeName(targetEntry, "sources.executable.entry")
    return ExecutableSourceTarget(
      targetName,
      requireProjectDirectory(srcDir, "sources.executable.srcDir"),
      excludes?.distinct(),
      targetEntry,
    )
  }
}

@TazelDsl
class LibrarySourcesScope internal constructor() {
  var name: String? = null
  var srcDir: String = "Sources"
  var namespace: String? = null
  internal var excludes: MutableList<String>? = null
  private val packageTypes = mutableListOf(ViPkgType.TALALIB)

  fun viPkgType(vararg values: ViPkgType) {
    if (values.isEmpty()) {
      throw ProjectConfigurationException("sources.library.viPkgType requires at least one type")
    }
    packageTypes.clear()
    packageTypes += values.distinct()
  }

  fun exclude(vararg patterns: String) {
    val configured = excludes ?: mutableListOf<String>().also { excludes = it }
    patterns.forEach { configured += requireText(it, "library source exclude") }
  }

  internal fun build(defaultName: String?): LibrarySourceTarget {
    val targetName =
      requireModuleSegment(
        name
          ?: defaultName
          ?: throw ProjectConfigurationException(
            "sources.library.name is required when the project has no name"
          ),
        "library name",
      )
    return LibrarySourceTarget(
      targetName,
      packageTypes.toList(),
      requireProjectDirectory(srcDir, "sources.library.srcDir"),
      excludes?.distinct(),
      namespace?.let { requireNamespaceName(it, "sources.library.namespace") },
    )
  }
}

@TazelDsl
class TestSourcesScope internal constructor(suiteName: String) {
  var testDir: String = "Tests/$suiteName"
  internal var excludes: MutableList<String>? = null

  fun exclude(vararg patterns: String) {
    val configured = excludes ?: mutableListOf<String>().also { excludes = it }
    patterns.forEach { configured += requireText(it, "test source exclude") }
  }
}

@TazelDsl
class ViGetSourcesScope internal constructor() {
  var push: Boolean = false
  internal var excludes: MutableList<String>? = null

  fun exclude(vararg patterns: String) {
    val configured = excludes ?: mutableListOf<String>().also { excludes = it }
    patterns.forEach { configured += requireText(it, "ViGet source exclude") }
  }
}

@TazelDsl
class ProjectSourcesScope internal constructor() {
  private val executables = mutableListOf<ExecutableSourcesScope>()
  private val libraries = mutableListOf<LibrarySourcesScope>()
  private val tests = linkedMapOf<String, TestSourcesScope>()
  private var viget: ViGetSourcesScope? = null

  fun executable(block: ExecutableSourcesScope.() -> Unit) {
    executables += ExecutableSourcesScope().apply(block)
  }

  fun library(block: LibrarySourcesScope.() -> Unit) {
    libraries += LibrarySourcesScope().apply(block)
  }

  fun test(
    name: String,
    block: TestSourcesScope.() -> Unit,
  ) {
    val suiteName = requireModuleSegment(name, "test suite name")
    if (suiteName in tests) {
      throw ProjectConfigurationException("test suite '$suiteName' may be configured only once")
    }
    tests[suiteName] = TestSourcesScope(suiteName).apply(block)
  }

  fun viget(block: ViGetSourcesScope.() -> Unit) {
    if (viget != null)
      throw ProjectConfigurationException("sources.viget may be configured only once")
    viget = ViGetSourcesScope().apply(block)
  }

  internal fun apply() {
    val projectName = ProjectRuntime.projectName
    val executableTargets = executables.map { it.build(projectName) }
    val libraryTargets = libraries.map { it.build(projectName) }
    if (executableTargets.isEmpty() && libraryTargets.isEmpty()) {
      throw ProjectConfigurationException(
        "sources requires at least one executable or library target"
      )
    }
    requireUniqueTargetNames(executableTargets.map(ExecutableSourceTarget::name), "executable")
    requireUniqueTargetNames(libraryTargets.map(LibrarySourceTarget::name), "library")
    ProjectRuntime.configureSourceTargets(executableTargets, libraryTargets)
    ProjectRuntime.configureTestSuites(
      tests.map { (name, suite) ->
        TestSuite(
          name = name,
          testDir = requireProjectDirectory(suite.testDir, "sources.test(\"$name\").testDir"),
          exclude = suite.excludes?.distinct(),
        )
      }
    )
    viget?.let { publishing ->
      ProjectRuntime.configurePublishing(publishing.push, publishing.excludes)
    }
  }
}

@TazelDsl
class OutputDirectoriesScope internal constructor() {
  var release: String = "build/release"
  var debug: String = "build/debug"

  internal fun apply() {
    ProjectRuntime.configureOutputDirectories(release, debug)
  }
}

@TazelDsl
class TargetsScope internal constructor() {
  private val values = mutableListOf<String>()

  fun target(vararg triples: String) {
    triples.forEach { value ->
      val target = requireText(value, "target triple")
      if (!target.matches(Regex("[A-Za-z0-9_+.]+(?:-[A-Za-z0-9_+.]+){2,}"))) {
        throw ProjectConfigurationException("invalid target triple: $target")
      }
      values += target
    }
  }

  internal fun apply() {
    ProjectRuntime.configureTargets(values)
  }
}

@TazelDsl
class PmlScope internal constructor() {
  var enabled: Boolean = true

  internal fun apply() {
    ProjectRuntime.configurePml(enabled)
  }
}

@TazelDsl
class WorkspaceScope internal constructor() {
  private val members = mutableListOf<String>()
  private val defaultMembers = mutableListOf<String>()
  private val excluded = mutableListOf<String>()

  /** The directories of the member projects, relative to this project file. */
  fun members(vararg paths: String) {
    members += paths.map { requireMemberPath(it, "workspace member") }
  }

  /** The members a command works on when it is run at the root without a selection. */
  fun defaultMembers(vararg paths: String) {
    defaultMembers += paths.map { requireMemberPath(it, "workspace default member") }
  }

  /** Directories that are no members even when [members] names them. */
  fun exclude(vararg paths: String) {
    excluded += paths.map { requireMemberPath(it, "workspace exclude") }
  }

  internal fun apply() {
    val unknown = defaultMembers.filterNot(members::contains)
    if (unknown.isNotEmpty()) {
      throw ProjectConfigurationException(
        "workspace default members must be members: ${unknown.joinToString()}"
      )
    }
    ProjectRuntime.configureWorkspace(
      Workspace(members.distinct(), defaultMembers.distinct(), excluded.distinct())
    )
  }
}

// "./Server", "Server" and "Server/" name one member, so they are kept as one spelling.
private fun requireMemberPath(
  value: String,
  field: String,
): String {
  val path = requireText(value, field).replace('\\', '/').trimEnd('/')
  val segments = path.split('/').filter { it.isNotEmpty() && it != "." }
  if (segments.isEmpty()) {
    throw ProjectConfigurationException("$field cannot be the workspace root itself: $value")
  }
  if (path.startsWith('/') || Regex("^[A-Za-z]:").containsMatchIn(path)) {
    throw ProjectConfigurationException("$field must be relative to the project file: $value")
  }
  return segments.joinToString("/")
}

fun project(block: ProjectScope.() -> Unit) = ProjectScope().apply(block).apply()

/** The `project` block as it was written, for a project file that reads it back. */
val project: ProjectScope
  get() = projectView ?: throw ProjectConfigurationException("project is read before it is written")

fun sources(block: ProjectSourcesScope.() -> Unit) = ProjectSourcesScope().apply(block).apply()

fun outdirs(block: OutputDirectoriesScope.() -> Unit) =
  OutputDirectoriesScope().apply(block).apply()

fun targets(block: TargetsScope.() -> Unit) = TargetsScope().apply(block).apply()

fun pml(block: PmlScope.() -> Unit) = PmlScope().apply(block).apply()

fun workspace(block: WorkspaceScope.() -> Unit) = WorkspaceScope().apply(block).apply()

private fun requireQualifiedTypeName(value: String, field: String): String {
  val entry = requireText(value, field)
  if (!entry.matches(Regex("[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)+"))) {
    throw ProjectConfigurationException("$field must be a qualified type name: $entry")
  }
  return entry
}

private fun requireNamespaceName(value: String, field: String): String {
  val namespace = requireText(value, field)
  if (!namespace.matches(Regex("[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*"))) {
    throw ProjectConfigurationException("$field must be a namespace name: $namespace")
  }
  return namespace
}

private fun requireUniqueTargetNames(names: List<String>, kind: String) {
  val duplicates = names.groupingBy { it }.eachCount().filterValues { it > 1 }.keys.sorted()
  if (duplicates.isNotEmpty()) {
    throw ProjectConfigurationException(
      "$kind target names must be case-sensitively unique: ${duplicates.joinToString()}"
    )
  }
}
