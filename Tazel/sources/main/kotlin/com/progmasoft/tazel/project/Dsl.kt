/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

@DslMarker annotation class TalaKts

@TalaKts
class CompilerScope internal constructor(private val settings: CompilerSettings) {
  var version: String
    get() = settings.version
    set(value) {
      settings.version = requireText(value, "compiler version")
    }

  var standard: String
    get() = settings.standard
    set(value) {
      val normalized = requireText(value, "language standard")
      if (normalized != "latest" && normalized != "26") {
        throw ProjectConfigurationException("language standard must be 26 or latest")
      }
      settings.standard = normalized
    }

  var backend: Backend
    get() = settings.backend
    set(value) {
      settings.backend = value
    }

  var buildMode: BuildMode
    get() = settings.buildMode
    set(value) {
      settings.buildMode = value
    }

  var werror: Boolean
    get() = settings.warningsAsErrors
    set(value) {
      settings.warningsAsErrors = value
    }

  var warnings: Warnings
    get() = com.progmasoft.tazel.project.Warnings.valueOf(settings.warningLevel.name)
    set(value) {
      settings.warningLevel = WarningLevel.valueOf(value.name)
    }

  var wexperimental: Boolean
    get() = settings.experimentalWarnings
    set(value) {
      settings.experimentalWarnings = value
    }

  var wshadow: Boolean
    get() = settings.shadowWarnings
    set(value) {
      settings.shadowWarnings = value
    }

  var wundef: Boolean
    get() = settings.undefinedWarnings
    set(value) {
      settings.undefinedWarnings = value
    }

  fun unsafe(block: UnsafeCompilerScope.() -> Unit) {
    UnsafeCompilerScope(settings).apply(block)
  }

  fun llvm(block: LlvmCompilerScope.() -> Unit) {
    LlvmCompilerScope(settings).apply(block)
  }
}

@TalaKts
class UnsafeCompilerScope internal constructor(private val settings: CompilerSettings) {
  var xppOptimizationPasses: Boolean
    get() = settings.xppOptimizationPasses
    set(value) {
      settings.xppOptimizationPasses = value
    }

  var xmmOptimizationPasses: Boolean
    get() = settings.xmmOptimizationPasses
    set(value) {
      settings.xmmOptimizationPasses = value
    }

  var typeSafeFormat: Boolean
    get() = settings.typeSafeFormat
    set(value) {
      settings.typeSafeFormat = value
    }
}

@TalaKts
class LlvmCompilerScope internal constructor(private val settings: CompilerSettings) {
  var optLevel: LlvmOptLevel
    get() =
      settings.llvmOptLevel
        ?: if (settings.buildMode == BuildMode.DEBUG) LlvmOptLevel.O0 else LlvmOptLevel.O3
    set(value) {
      settings.llvmOptLevel = value
    }

  var compiler: LlvmCompiler
    get() = settings.llvmCompiler
    set(value) {
      settings.llvmCompiler = value
    }

  var lto: LlvmLto
    get() = settings.llvmLto
    set(value) {
      settings.llvmLto = value
    }
}

class ProjectContext internal constructor(val host: Host = detectHost()) {
  private var identity: ProjectIdentity? = null
  private val authors = mutableListOf<String>()
  private val defaultFeatures = mutableListOf<String>()
  private val dependencies = mutableListOf<PackageDependency>()
  private val optionalDependencies = mutableListOf<OptionalPackageDependency>()
  private val dependencyFeatures = mutableListOf<PackageFeatureSelection>()
  private val localDependencies = mutableListOf<LocalPackageDependency>()
  private var releaseOutputDirectory = "build/release"
  private var debugOutputDirectory = "build/debug"
  private val targets = mutableListOf<String>()
  private val workspaces = mutableListOf<Workspace>()
  private var pmlEnabled = true
  private var pushSources = false
  private var pushExcludes: List<String>? = null
  private val executables = mutableListOf<ExecutableSourceTarget>()
  private val libraries = mutableListOf<LibrarySourceTarget>()
  private val testSuites = mutableListOf<TestSuite>()
  private val compilerSettings = CompilerSettings()

  val projectName: String?
    get() = identity?.name

  internal fun configureIdentity(
    name: String?,
    stability: String?,
    version: String?,
    description: String?,
    configuredAuthors: List<String>,
    configuredDefaultFeatures: List<String>,
  ) {
    if (identity != null) throw ProjectConfigurationException("project may be configured only once")
    identity =
      ProjectIdentity(
        name?.let { requireText(it, "project name") },
        stability?.let { requireText(it, "project stability") },
        version?.let { requireText(it, "project version") },
        description?.let { requireText(it, "project description") },
      )
    authors += configuredAuthors.map { requireModuleSegment(it, "project author") }.distinct()
    defaultFeatures += configuredDefaultFeatures.map(::requireFeatureName).distinct()
  }

  internal fun configureOutputDirectories(
    release: String,
    debug: String,
  ) {
    releaseOutputDirectory = requireText(release, "release output directory")
    debugOutputDirectory = requireText(debug, "debug output directory")
  }

  internal fun configureTargets(values: List<String>) {
    targets.clear()
    targets += values.distinct()
  }

  internal fun configureWorkspaces(values: List<Workspace>) {
    workspaces.clear()
    workspaces += values.distinctBy(Workspace::name)
  }

  internal fun configurePml(enabled: Boolean) {
    pmlEnabled = enabled
  }

  internal fun configurePublishing(
    push: Boolean,
    excludes: List<String>?,
  ) {
    pushSources = push
    pushExcludes = excludes?.distinct()
  }

  internal fun configureSourceTargets(
    executableTargets: List<ExecutableSourceTarget>,
    libraryTargets: List<LibrarySourceTarget>,
  ) {
    executables.clear()
    executables += executableTargets
    libraries.clear()
    libraries += libraryTargets
  }

  fun dependencies(block: DependenciesScope.() -> Unit) {
    val scope = DependenciesScope().apply(block)
    val validated =
      validateDependencies(
        dependencies + scope.required,
        optionalDependencies + scope.optional,
        dependencyFeatures + scope.selections,
        localDependencies + scope.local,
      )
    dependencies.clear()
    dependencies += validated.required
    optionalDependencies.clear()
    optionalDependencies += validated.optional
    dependencyFeatures.clear()
    dependencyFeatures += validated.features
    localDependencies.clear()
    localDependencies += validated.local
  }

  internal fun configureTestSuites(suites: List<TestSuite>) {
    val duplicates = suites.groupingBy(TestSuite::name).eachCount().filterValues { it > 1 }.keys
    if (duplicates.isNotEmpty()) {
      throw ProjectConfigurationException(
        "test suite names must be unique: ${duplicates.sorted().joinToString()}"
      )
    }
    testSuites.clear()
    testSuites += suites
  }

  fun compiler(block: CompilerScope.() -> Unit) {
    CompilerScope(compilerSettings).apply(block)
  }

  fun build(): ProjectPlan {
    if (executables.isEmpty() && libraries.isEmpty()) {
      throw ProjectConfigurationException(
        "sources requires at least one executable or library target"
      )
    }
    val project = identity
    if (pushSources) {
      val missingFields = buildList {
        if (project?.name == null) add("name")
        if (project?.version == null) add("version")
        if (project?.stability == null) add("stability")
        if (project?.description == null) add("description")
        if (authors.isEmpty()) add("authors")
      }
      if (missingFields.isNotEmpty()) {
        throw ProjectConfigurationException(
          "sources.viget.push requires every project field; missing: ${missingFields.joinToString()}"
        )
      }
    }
    val dependencyManifest =
      validateDependencies(
        dependencies,
        optionalDependencies,
        dependencyFeatures,
        localDependencies,
      )
    val plan =
      ProjectPlan(
        project,
        authors.toList(),
        defaultFeatures.toList(),
        dependencyManifest.required,
        dependencyManifest.optional,
        dependencyManifest.features,
        dependencyManifest.local,
        releaseOutputDirectory,
        debugOutputDirectory,
        targets.toList(),
        workspaces.toList(),
        pmlEnabled,
        pushSources,
        pushExcludes,
        executables.toList(),
        libraries.toList(),
        testSuites.toList(),
        compilerSettings,
        emptyList(),
      )
    return PluginRuntime.finish(plan)
  }
}

internal fun requireText(
  value: String,
  field: String,
): String {
  if (value.isBlank()) throw ProjectConfigurationException("$field cannot be empty")
  return value
}

internal fun requireModuleSegment(
  value: String,
  field: String,
): String {
  val name = requireText(value, field)
  if (!name.matches(Regex("[A-Za-z_][A-Za-z0-9_]*"))) {
    throw ProjectConfigurationException("$field must be one case-sensitive X# identifier: $name")
  }
  return name
}

internal object ProjectRuntime {
  private var context = ProjectContext()

  fun reset() {
    PluginRuntime.reset()
    context = ProjectContext()
  }

  fun configureIdentity(
    name: String?,
    stability: String?,
    version: String?,
    description: String?,
    authors: List<String>,
    defaultFeatures: List<String>,
  ) = context.configureIdentity(name, stability, version, description, authors, defaultFeatures)

  fun configureOutputDirectories(
    release: String,
    debug: String,
  ) = context.configureOutputDirectories(release, debug)

  fun configureTargets(values: List<String>) = context.configureTargets(values)

  fun configureWorkspaces(values: List<Workspace>) = context.configureWorkspaces(values)

  fun configurePml(enabled: Boolean) = context.configurePml(enabled)

  fun configurePublishing(
    push: Boolean,
    excludes: List<String>?,
  ) = context.configurePublishing(push, excludes)

  fun configureSourceTargets(
    executables: List<ExecutableSourceTarget>,
    libraries: List<LibrarySourceTarget>,
  ) = context.configureSourceTargets(executables, libraries)

  fun dependencies(block: DependenciesScope.() -> Unit) = context.dependencies(block)

  fun configureTestSuites(suites: List<TestSuite>) = context.configureTestSuites(suites)

  fun compiler(block: CompilerScope.() -> Unit) = context.compiler(block)

  fun build() = context.build()

  val projectName
    get() = context.projectName

  val host
    get() = context.host
}

val OS
  get() = ProjectRuntime.host.os
val FAMILY
  get() = ProjectRuntime.host.family
val ARCH
  get() = ProjectRuntime.host.architecture
val LINUX
  get() = OperatingSystem.LINUX
val MACOS
  get() = OperatingSystem.MACOS
val WINDOWS: Any
  get() = OperatingSystem.WINDOWS
val FREEBSD
  get() = OperatingSystem.FREEBSD
val OPENBSD
  get() = OperatingSystem.OPENBSD
val NETBSD
  get() = OperatingSystem.NETBSD
val UNIX
  get() = OperatingSystemFamily.UNIX
val BSD
  get() = OperatingSystemFamily.BSD
val X86_64
  get() = Architecture.X86_64
val AARCH64
  get() = Architecture.AARCH64
val ARMV7H
  get() = Architecture.ARMV7H
val RISCV64
  get() = Architecture.RISCV64

fun cfg(condition: Boolean) = condition

fun panic(message: String): Nothing = throw ProjectAbort(message)

fun eprint(message: Any?) = System.err.print(message)

fun eprintln(message: Any?) = System.err.println(message)

fun dependencies(block: DependenciesScope.() -> Unit) = ProjectRuntime.dependencies(block)

fun compiler(block: CompilerScope.() -> Unit) = ProjectRuntime.compiler(block)
