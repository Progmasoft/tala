/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl

import com.progmasoft.tazel.dsl.plugin.PluginPlanEntry

enum class OperatingSystem {
  LINUX,
  MACOS,
  WINDOWS,
  FREEBSD,
  OPENBSD,
  NETBSD,
  UNKNOWN,
}

enum class Architecture {
  X86_64,
  AARCH64,
  ARMV7H,
  RISCV64,
  UNKNOWN,
}

enum class Stability {
  STABLE,
  UNSTABLE,
  BETA,
  NIGHTLY,
  ALPHA,
  DEV,
}

enum class Backend {
  LLVM
}

enum class BuildMode {
  DEBUG,
  RELEASE,
}

enum class Warnings {
  ALL,
  MEDIUM,
  LOW,
  NONE,
}

enum class OptLevel {
  O0,
  O1,
  O2,
  O3,
  OG,
}

enum class LlvmCompiler {
  AOT,
  ORC,
}

enum class LlvmLto {
  FAT,
  THIN,
  NONE,
}

enum class ViPkgType {
  TALALIB,
  STATICLIB,
  CDYLIB,
}

/** A standard of the language, made by [talaStandardOf]. */
class TalaStandard internal constructor(val number: Int) {
  override fun equals(other: Any?) = other is TalaStandard && other.number == number

  override fun hashCode() = number

  override fun toString() = number.toString()
}

/** The standards the compiler knows; `26` is the only one so far. */
fun talaStandardOf(number: Int): TalaStandard {
  if (number != 26) throw ProjectConfigurationException("Tala standard $number does not exist")
  return TalaStandard(number)
}

data class Host(
  val os: OperatingSystem,
  val architecture: Architecture,
)

data class ProjectIdentity(
  val name: String?,
  val stability: Stability?,
  val version: String?,
  val description: String? = null,
)

data class ExecutableSourceTarget(
  val name: String,
  val srcDir: String,
  val exclude: List<String>?,
  val entry: String,
)

data class LibrarySourceTarget(
  val name: String,
  val viPkgTypes: List<ViPkgType>,
  val srcDir: String,
  val exclude: List<String>?,
  val namespace: String?,
)

/**
 * The members of a workspace as the project wrote them: directories relative to the project file,
 * each with a project file of its own.
 */
data class Workspace(
  val members: List<String>,
  val defaultMembers: List<String>,
  val exclude: List<String>,
)

data class TestSuite(
  val name: String,
  val testDir: String,
  val exclude: List<String>?,
)

data class CompilerSettings(
  var version: String = "unknown",
  var standard: TalaStandard = TalaStandard(26),
  var backend: Backend = Backend.LLVM,
  var buildMode: BuildMode = BuildMode.DEBUG,
  var warnings: Warnings = Warnings.MEDIUM,
  var warningsAsErrors: Boolean = false,
  var shadowWarnings: Boolean = false,
  var xppOptimizationPasses: Boolean = true,
  var xmmOptimizationPasses: Boolean = true,
  var optLevel: OptLevel? = null,
  var llvmCompiler: LlvmCompiler = LlvmCompiler.AOT,
  var llvmLto: LlvmLto = LlvmLto.NONE,
  var llvmArguments: List<String> = emptyList(),
) {
  /** The level the project wrote, or the one its build mode implies. */
  val effectiveOptLevel: OptLevel
    get() = optLevel ?: if (buildMode == BuildMode.DEBUG) OptLevel.O0 else OptLevel.O3
}

data class PackageDependency(
  val publisher: String,
  val name: String,
  val version: String,
  val stability: Stability,
)

/** Whether a dependency serves the targets of the project or only its test suites. */
enum class DependencyScope {
  BUILD,
  TEST,
}

/**
 * One `dependency` or `testDependency` block.
 *
 * [feature] names the feature of this project that brings the dependency in; a dependency without
 * one is always required. [defaultFeatures] and [features] choose among the features of the
 * dependency itself.
 */
data class DependencyDeclaration(
  val dependency: PackageDependency,
  val scope: DependencyScope = DependencyScope.BUILD,
  val feature: String? = null,
  val defaultFeatures: Boolean = true,
  val features: Map<String, Boolean> = emptyMap(),
)

data class LocalPackageDependency(
  val path: String,
  val scope: DependencyScope = DependencyScope.BUILD,
)

// This is the validated project declaration, not a solved registry graph. Transitive
// versions, artifact identities and repository metadata belong to the future resolver.
data class DependencyManifest(
  val declarations: List<DependencyDeclaration>,
  val local: List<LocalPackageDependency> = emptyList(),
) {
  val isEmpty: Boolean
    get() = declarations.isEmpty() && local.isEmpty()
}

data class ProjectPlan(
  val identity: ProjectIdentity?,
  val authors: List<String>,
  val defaultFeatures: List<String>,
  val dependencies: DependencyManifest,
  val releaseOutputDirectory: String,
  val debugOutputDirectory: String,
  val targets: List<String>,
  val workspace: Workspace?,
  val pmlEnabled: Boolean,
  val pushSources: Boolean,
  val pushExcludes: List<String>?,
  val executables: List<ExecutableSourceTarget>,
  val libraries: List<LibrarySourceTarget>,
  val testSuites: List<TestSuite>,
  val compiler: CompilerSettings,
  val plugins: List<PluginPlanEntry>,
) {
  /** The directory the build mode of the project writes its artifacts to. */
  val outputDirectory: String
    get() =
      if (compiler.buildMode == BuildMode.DEBUG) debugOutputDirectory else releaseOutputDirectory
}

class ProjectConfigurationException(message: String) : IllegalArgumentException(message)

class ProjectAbort(message: String) : RuntimeException(message)

internal fun operatingSystemFromName(name: String): OperatingSystem {
  val osName = name.lowercase()
  return when {
    osName.contains("linux") -> OperatingSystem.LINUX
    osName.contains("mac") || osName.contains("darwin") -> OperatingSystem.MACOS
    osName.contains("windows") -> OperatingSystem.WINDOWS
    osName.contains("freebsd") -> OperatingSystem.FREEBSD
    osName.contains("openbsd") -> OperatingSystem.OPENBSD
    osName.contains("netbsd") -> OperatingSystem.NETBSD
    else -> OperatingSystem.UNKNOWN
  }
}

internal fun architectureFromName(name: String): Architecture =
  when (name.lowercase()) {
    "amd64",
    "x86_64" -> Architecture.X86_64
    "aarch64",
    "arm64" -> Architecture.AARCH64
    "arm",
    "armv7",
    "armv7h" -> Architecture.ARMV7H
    "riscv64" -> Architecture.RISCV64
    else -> Architecture.UNKNOWN
  }

internal fun detectHost() =
  Host(
    operatingSystemFromName(System.getProperty("os.name", "")),
    architectureFromName(System.getProperty("os.arch", "")),
  )
