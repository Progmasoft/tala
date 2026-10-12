/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.io.Serializable

class OperatingSystem private constructor(val name: String) {
  override fun toString() = name

  companion object {
    val LINUX = OperatingSystem("LINUX")
    val MACOS = OperatingSystem("MACOS")
    val WINDOWS = OperatingSystem("WINDOWS")
    val FREEBSD = OperatingSystem("FREEBSD")
    val OPENBSD = OperatingSystem("OPENBSD")
    val NETBSD = OperatingSystem("NETBSD")
    val UNKNOWN = OperatingSystem("UNKNOWN")
    internal val REACTOS_HOST = OperatingSystem("REACTOS")
  }
}

// Families are exclusive values. The previous overlapping bit-mask equality made BSD
// compare equal to both BSD and UNIX, which violates equality transitivity and forced a
// constant hash code. Platform capabilities shared by UNIX-like systems belong in an
// explicit capability predicate when one is added, not in object equality.
enum class OperatingSystemFamily {
  UNIX,
  BSD,
  WINDOWS,
  UNKNOWN;

  companion object {
    internal fun forOperatingSystem(os: OperatingSystem) =
      when (os) {
        OperatingSystem.FREEBSD,
        OperatingSystem.OPENBSD,
        OperatingSystem.NETBSD -> BSD
        OperatingSystem.LINUX,
        OperatingSystem.MACOS -> UNIX
        OperatingSystem.WINDOWS,
        OperatingSystem.REACTOS_HOST -> WINDOWS
        else -> UNKNOWN
      }
  }
}

enum class Architecture {
  X86_64,
  AARCH64,
  ARMV7H,
  RISCV64,
  UNKNOWN,
}

enum class WarningLevel {
  ALL,
  MEDIUM,
  LOW,
  NONE,
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

enum class LlvmOptLevel {
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

data class Host(
  val os: OperatingSystem,
  val family: OperatingSystemFamily,
  val architecture: Architecture,
)

data class ProjectIdentity(
  val name: String?,
  val stability: String?,
  val version: String?,
  val description: String? = null,
) : Serializable

enum class ViPkgType {
  TALALIB,
  STATICLIB,
  CDYLIB,
}

data class ExecutableSourceTarget(
  val name: String,
  val srcDir: String,
  val exclude: List<String>?,
  val entry: String,
) : Serializable

data class LibrarySourceTarget(
  val name: String,
  val viPkgTypes: List<ViPkgType>,
  val srcDir: String,
  val exclude: List<String>?,
  val namespace: String?,
) : Serializable

data class Workspace(
  val name: String,
  val path: String,
) : Serializable

data class TestSuite(
  val name: String,
  val testDir: String,
  val framework: String?,
  val exclude: List<String>?,
) : Serializable

data class CompilerSettings(
  var warningLevel: WarningLevel = WarningLevel.MEDIUM,
  var warningsAsErrors: Boolean = false,
  var version: String = "latest",
  var standard: String = "latest",
  var backend: Backend = Backend.LLVM,
  var buildMode: BuildMode = BuildMode.DEBUG,
  var experimentalWarnings: Boolean = false,
  var shadowWarnings: Boolean = false,
  var undefinedWarnings: Boolean = true,
  var typeSafeFormat: Boolean = true,
  var xppOptimizationPasses: Boolean = true,
  var xmmOptimizationPasses: Boolean = true,
  var llvmOptLevel: LlvmOptLevel? = null,
  var llvmCompiler: LlvmCompiler = LlvmCompiler.AOT,
  var llvmLto: LlvmLto = LlvmLto.NONE,
) : Serializable

data class PackageDependency(
  val publisher: String,
  val name: String,
  val version: String,
  val stability: Stability,
) : Serializable

data class OptionalPackageDependency(
  val feature: String,
  val dependency: PackageDependency,
) : Serializable

data class PackageFeatureSelection(
  val packageName: String,
  val feature: String,
  val enabled: Boolean,
) : Serializable

data class LocalPackageDependency(val path: String) : Serializable

// This is the validated project declaration, not a solved registry graph. Transitive
// versions, artifact identities and repository metadata belong to the future resolver.
data class DependencyManifest(
  val required: List<PackageDependency>,
  val optional: List<OptionalPackageDependency>,
  val features: List<PackageFeatureSelection>,
  val local: List<LocalPackageDependency> = emptyList(),
) : Serializable

data class ProjectPlan(
  val identity: ProjectIdentity?,
  val authors: List<String>,
  val defaultFeatures: List<String>,
  val requiredDependencies: List<PackageDependency>,
  val optionalDependencies: List<OptionalPackageDependency>,
  val dependencyFeatures: List<PackageFeatureSelection>,
  val localDependencies: List<LocalPackageDependency>,
  val releaseOutputDirectory: String,
  val debugOutputDirectory: String,
  val targets: List<String>,
  val workspaces: List<Workspace>,
  val pmlEnabled: Boolean,
  val pushSources: Boolean,
  val pushExcludes: List<String>?,
  val executables: List<ExecutableSourceTarget>,
  val libraries: List<LibrarySourceTarget>,
  val testSuites: List<TestSuite>,
  val compiler: CompilerSettings,
  val plugins: List<PluginPlanEntry>,
)

internal val packageDependencyOrder =
  compareBy(
    PackageDependency::publisher,
    PackageDependency::name,
    PackageDependency::stability,
    PackageDependency::version,
  )

class ProjectConfigurationException(message: String) : IllegalArgumentException(message)

class ProjectAbort(message: String) : RuntimeException(message)

internal fun operatingSystemFromName(name: String): OperatingSystem {
  val osName = name.lowercase()
  return when {
    osName.contains("linux") -> OperatingSystem.LINUX
    osName.contains("mac") || osName.contains("darwin") -> OperatingSystem.MACOS
    osName.contains("reactos") -> OperatingSystem.REACTOS_HOST
    osName.contains("windows") -> OperatingSystem.WINDOWS
    osName.contains("freebsd") -> OperatingSystem.FREEBSD
    osName.contains("openbsd") -> OperatingSystem.OPENBSD
    osName.contains("netbsd") -> OperatingSystem.NETBSD
    else -> OperatingSystem.UNKNOWN
  }
}

internal fun detectHost(): Host {
  val architectureName = System.getProperty("os.arch", "").lowercase()
  val os = operatingSystemFromName(System.getProperty("os.name", ""))
  val family = OperatingSystemFamily.forOperatingSystem(os)
  val architecture =
    when (architectureName) {
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
  return Host(os, family, architecture)
}
