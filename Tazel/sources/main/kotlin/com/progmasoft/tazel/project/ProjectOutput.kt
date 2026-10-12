/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path

object ProjectOutput {
  private const val REGISTRY_VERSION = "tala-sources-v6"

  fun emit(plan: ProjectPlan) {
    val root = projectRoot()
    val resolved = resolveRoots(root, plan)
    ProjectLockFile.write(
      root,
      validateDependencies(
        plan.requiredDependencies,
        plan.optionalDependencies,
        plan.dependencyFeatures,
        plan.localDependencies,
      ),
      plan.plugins,
    )
    when (System.getProperty("talac.project.output", "plan")) {
      "plan" -> println(PlanWriter.write(plan))
      "resolve" -> Unit
      "sources0" -> writeRegistry(plan, resolved)
      else -> throw ProjectConfigurationException("unknown project output mode")
    }
  }

  private data class ResolvedRoots(
    val executables: List<ResolvedExecutableTarget>,
    val libraries: List<ResolvedLibraryTarget>,
    val tests: List<ResolvedTestSuite>,
  )

  private data class ResolvedExecutableTarget(
    val declaration: ExecutableSourceTarget,
    val root: Path,
  )

  private data class ResolvedLibraryTarget(
    val declaration: LibrarySourceTarget,
    val root: Path,
  )

  private data class ResolvedTestSuite(
    val declaration: TestSuite,
    val root: Path,
  )

  private fun resolveRoots(
    root: Path,
    plan: ProjectPlan,
  ): ResolvedRoots {
    return ResolvedRoots(
      plan.executables.map { target ->
        ResolvedExecutableTarget(
          target,
          validateRoot(root, target.srcDir, "sources.executable('${target.name}').srcDir"),
        )
      },
      plan.libraries.map { target ->
        ResolvedLibraryTarget(
          target,
          validateRoot(root, target.srcDir, "sources.library('${target.name}').srcDir"),
        )
      },
      plan.testSuites.map { suite ->
        ResolvedTestSuite(
          suite,
          validateRoot(root, suite.testDir, "sources.test('${suite.name}').testDir"),
        )
      },
    )
  }

  private fun validateRoot(
    root: Path,
    configuredRoot: String,
    setting: String,
  ): Path {
    val normalized = configuredRoot.replace('\\', '/')
    val relative = Path.of(normalized)
    if (relative.isAbsolute || normalized.split('/').any { it == ".." }) {
      throw ProjectConfigurationException("$setting escapes the project root: $configuredRoot")
    }
    val directory = root.resolve(relative).normalize()
    if (!directory.startsWith(root) || !Files.isDirectory(directory)) {
      throw ProjectConfigurationException("$setting directory does not exist: $directory")
    }
    return directory
  }

  private fun writeRegistry(
    plan: ProjectPlan,
    project: ResolvedRoots,
  ) {
    val configuredOutput = System.getProperty("talac.project.sources")?.takeIf(String::isNotBlank)
    val output = configuredOutput?.let { Files.newOutputStream(Path.of(it)) } ?: System.out
    try {
      val compiler = plan.compiler
      val optLevel =
        compiler.llvmOptLevel
          ?: if (compiler.buildMode == BuildMode.DEBUG) LlvmOptLevel.O0 else LlvmOptLevel.O3
      // The DSL exports roots and exclusion policy, not a snapshot of .tala files.
      // Namespace resolution and source discovery are compiler responsibilities;
      // neither file names nor directory layout define the entry type.
      listOf(
          REGISTRY_VERSION,
          compiler.version,
          compiler.standard,
          compiler.backend.name.lowercase(),
          compiler.buildMode.name.lowercase(),
          compiler.warningLevel.name.lowercase(),
          compiler.warningsAsErrors.toString(),
          compiler.experimentalWarnings.toString(),
          compiler.shadowWarnings.toString(),
          compiler.undefinedWarnings.toString(),
          compiler.typeSafeFormat.toString(),
          compiler.xppOptimizationPasses.toString(),
          compiler.xmmOptimizationPasses.toString(),
          optLevel.name.removePrefix("O").lowercase(),
          compiler.llvmCompiler.name.lowercase(),
          compiler.llvmLto.name.lowercase(),
          if (compiler.buildMode == BuildMode.DEBUG) {
            plan.debugOutputDirectory
          } else {
            plan.releaseOutputDirectory
          },
          plan.targets.size.toString(),
          project.executables.size.toString(),
          project.libraries.size.toString(),
          project.tests.size.toString(),
        )
        .forEach { writeRecord(output, it) }
      plan.targets.forEach { writeRecord(output, it) }
      project.executables.forEach { target ->
        writeRecord(output, target.declaration.name)
        writeRecord(output, target.declaration.entry)
        writeRecord(output, target.root.toString())
        writeRecord(output, target.declaration.exclude.orEmpty().size.toString())
        target.declaration.exclude.orEmpty().forEach { writeRecord(output, it) }
      }
      project.libraries.forEach { target ->
        writeRecord(output, target.declaration.name)
        writeRecord(output, target.declaration.namespace.orEmpty())
        writeRecord(output, target.root.toString())
        writeRecord(output, target.declaration.viPkgTypes.size.toString())
        target.declaration.viPkgTypes.forEach { writeRecord(output, it.name.lowercase()) }
        writeRecord(output, target.declaration.exclude.orEmpty().size.toString())
        target.declaration.exclude.orEmpty().forEach { writeRecord(output, it) }
      }
      project.tests.forEach { suite ->
        writeRecord(output, suite.declaration.name)
        writeRecord(output, suite.declaration.framework.orEmpty())
        writeRecord(output, suite.root.toString())
        writeRecord(output, suite.declaration.exclude.orEmpty().size.toString())
        suite.declaration.exclude.orEmpty().forEach { writeRecord(output, it) }
      }
      output.flush()
    } finally {
      if (configuredOutput != null) output.close()
    }
  }

  private fun projectRoot(): Path {
    val configured =
      System.getProperty("talac.project.root")?.takeIf(String::isNotBlank)
        ?: throw ProjectConfigurationException("project root is not configured")
    return Path.of(configured).toAbsolutePath().normalize()
  }

  private fun writeRecord(
    stream: java.io.OutputStream,
    value: String,
  ) {
    stream.write(value.toByteArray(StandardCharsets.UTF_8))
    stream.write(0)
  }
}
