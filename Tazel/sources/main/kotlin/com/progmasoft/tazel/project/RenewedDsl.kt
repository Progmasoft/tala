/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

@TalaKts
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
    if (
      name == null &&
        version == null &&
        stability == null &&
        description == null &&
        authors.isEmpty() &&
        defaultFeatures.isEmpty()
    )
      return

    // Publication is configured later in many project files, so completeness
    // cannot be decided while this block is evaluated. Preserve every supplied
    // value and enforce the publication contract once the whole model is built.
    ProjectRuntime.configureIdentity(
      name,
      stability?.name,
      version,
      description,
      authors,
      defaultFeatures,
    )
  }
}

@TalaKts
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
    val targetName = requireModuleSegment(name ?: defaultName ?: "Main", "executable name")
    val targetEntry =
      entry ?: throw ProjectConfigurationException("sources.executable.entry is required")
    requireQualifiedTypeName(targetEntry, "sources.executable.entry")
    return ExecutableSourceTarget(
      targetName,
      requireSourceDirectory(srcDir, "sources.executable.srcDir"),
      excludes?.map { requireText(it, "executable source exclude") }?.distinct(),
      targetEntry,
    )
  }
}

@TalaKts
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
    val targetName = requireModuleSegment(name ?: defaultName ?: "Library", "library name")
    val targetNamespace = namespace?.let { requireNamespaceName(it, "sources.library.namespace") }
    return LibrarySourceTarget(
      targetName,
      packageTypes.toList(),
      requireSourceDirectory(srcDir, "sources.library.srcDir"),
      excludes?.map { requireText(it, "library source exclude") }?.distinct(),
      targetNamespace,
    )
  }
}

@TalaKts
class TestSourcesScope internal constructor(private val suiteName: String) {
  var testDir: String = "Tests/$suiteName"
  var framework: String? = null
  internal var excludes: MutableList<String>? = null

  fun exclude(vararg patterns: String) {
    val configured = excludes ?: mutableListOf<String>().also { excludes = it }
    patterns.forEach { configured += requireText(it, "test source exclude") }
  }
}

@TalaKts
class ViGetSourcesScope internal constructor() {
  var push: Boolean = false
  internal var excludes: MutableList<String>? = null

  fun exclude(vararg patterns: String) {
    val configured = excludes ?: mutableListOf<String>().also { excludes = it }
    patterns.forEach { configured += requireText(it, "ViGet source exclude") }
  }
}

@TalaKts
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
          testDir = requireText(suite.testDir, "sources.test('$name').testDir"),
          framework = suite.framework?.let { requireText(it, "test suite '$name' framework") },
          exclude =
            suite.excludes?.map { requireText(it, "test suite '$name' exclude") }?.distinct(),
        )
      }
    )
    viget?.let { publishing ->
      ProjectRuntime.configurePublishing(publishing.push, publishing.excludes)
    }
  }
}

@TalaKts
class OutputDirectoriesScope internal constructor() {
  var release: String = "build/release"
  var debug: String = "build/debug"

  internal fun apply() {
    ProjectRuntime.configureOutputDirectories(release, debug)
  }
}

@TalaKts
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

@TalaKts
class PmlScope internal constructor() {
  var enabled: Boolean = true

  internal fun apply() {
    ProjectRuntime.configurePml(enabled)
  }
}

@TalaKts
class WorkspaceScope internal constructor(private val name: String) {
  var path: String? = null

  internal fun build(): Workspace {
    val configuredPath =
      path ?: throw ProjectConfigurationException("workspace '$name' requires path")
    return Workspace(name, requireText(configuredPath, "workspace path"))
  }
}

@TalaKts
class WorkspacesScope internal constructor() {
  private val values = mutableListOf<Workspace>()

  fun workspace(
    name: String,
    block: WorkspaceScope.() -> Unit,
  ) {
    val normalized = requireModuleSegment(name, "workspace name")
    values += WorkspaceScope(normalized).apply(block).build()
  }

  internal fun apply() {
    ProjectRuntime.configureWorkspaces(values)
  }
}

@TalaKts
class DependencyDeclarationScope internal constructor(private val publisher: String) {
  var name: String? = null
  var version: String? = null
  var stability: Stability = Stability.STABLE
  var optional: String? = null
  var path: String? = null
  private val features = linkedMapOf<String, Boolean>()

  fun feature(
    name: String,
    block: DependencyFeatureDeclarationScope.() -> Unit,
  ) {
    val normalized = requireFeatureName(name)
    features[normalized] = DependencyFeatureDeclarationScope().apply(block).enabled
  }

  internal fun applyTo(scope: DependenciesScope) {
    if (publisher == "local") {
      if (name != null || version != null || optional != null || features.isNotEmpty()) {
        throw ProjectConfigurationException(
          "local dependency accepts only path; package identity comes from the .vipkg manifest"
        )
      }
      scope.addLocal(requireLocalArtifactPath(path, "vipkg", "local dependency path"))
      return
    }
    if (path != null) {
      throw ProjectConfigurationException("ViGet dependency does not accept a local path")
    }
    val packageName =
      requireModuleSegment(
        name ?: throw ProjectConfigurationException("dependency requires name"),
        "dependency name",
      )
    val packageVersion =
      requirePackageVersion(
        version ?: throw ProjectConfigurationException("dependency requires version")
      )
    val optionalFeature = optional
    if (optionalFeature == null) {
      scope.add(packageDependency(publisher, packageName, stability, packageVersion))
    } else {
      val feature = requireFeatureName(optionalFeature)
      val dependency = packageDependency(publisher, packageName, stability, packageVersion)
      val enabled = features[feature] ?: false
      scope.addOptional(feature, dependency, enabled)
    }
  }
}

@TalaKts
class DependencyFeatureDeclarationScope internal constructor() {
  var enabled: Boolean = false
}

fun project(block: ProjectScope.() -> Unit) = ProjectScope().apply(block).apply()

fun sources(block: ProjectSourcesScope.() -> Unit) = ProjectSourcesScope().apply(block).apply()

fun outdirs(block: OutputDirectoriesScope.() -> Unit) =
  OutputDirectoriesScope().apply(block).apply()

fun targets(block: TargetsScope.() -> Unit) = TargetsScope().apply(block).apply()

fun pml(block: PmlScope.() -> Unit) = PmlScope().apply(block).apply()

fun workspaces(block: WorkspacesScope.() -> Unit) = WorkspacesScope().apply(block).apply()

fun DependenciesScope.dependency(
  publisher: String,
  block: DependencyDeclarationScope.() -> Unit,
) = DependencyDeclarationScope(publisher).apply(block).applyTo(this)

fun emitProject() = ProjectOutput.emit(ProjectRuntime.build())

private fun requireSourceDirectory(value: String, field: String): String {
  val directory = requireText(value, field).replace('\\', '/')
  if (directory.startsWith('/') || directory.split('/').any { it == ".." }) {
    throw ProjectConfigurationException("$field must stay inside the project root: $value")
  }
  if (directory.any { it in "*?" }) {
    throw ProjectConfigurationException("$field must name a directory, not a glob: $value")
  }
  return directory
}

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
