/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import kotlinx.serialization.Serializable

private const val PROJECT_PLAN_FORMAT = "tala-project-plan"
private const val PROJECT_PLAN_VERSION = 5

/**
 * Stable wire representation of [ProjectPlan]. Keeping the transport schema separate from the
 * mutable DSL model prevents implementation-only fields from leaking into the native driver.
 */
@Serializable
internal data class ProjectPlanDocument(
  val format: String = PROJECT_PLAN_FORMAT,
  val version: Int = PROJECT_PLAN_VERSION,
  val project: ProjectIdentityDocument?,
  val compiler: CompilerDocument,
  val outdirs: OutputDirectoriesDocument,
  val targets: List<String>,
  val authors: List<String>,
  val defaultFeatures: List<String>,
  val pml: PmlDocument,
  val dependencies: List<DependencyDocument>,
  val plugins: List<PluginDocument>,
  val workspaces: List<WorkspaceDocument>,
  val sources: SourcesDocument,
) {
  companion object {
    fun from(plan: ProjectPlan): ProjectPlanDocument =
      ProjectPlanDocument(
        project = plan.identity?.let(ProjectIdentityDocument::from),
        compiler = CompilerDocument.from(plan.compiler),
        outdirs =
          OutputDirectoriesDocument(
            release = plan.releaseOutputDirectory,
            debug = plan.debugOutputDirectory,
          ),
        targets = plan.targets,
        authors = plan.authors,
        defaultFeatures = plan.defaultFeatures,
        pml = PmlDocument(enabled = plan.pmlEnabled),
        dependencies = dependenciesFrom(plan),
        plugins = plan.plugins.map(PluginDocument::from),
        workspaces = plan.workspaces.map(WorkspaceDocument::from),
        sources = SourcesDocument.from(plan),
      )

    private fun dependenciesFrom(plan: ProjectPlan): List<DependencyDocument> =
      buildList(
        plan.requiredDependencies.size +
          plan.optionalDependencies.size +
          plan.localDependencies.size
      ) {
        plan.requiredDependencies.mapTo(this, DependencyDocument::required)
        plan.optionalDependencies.mapTo(this) { declaration ->
          val enabled =
            plan.dependencyFeatures.any { selection ->
              selection.packageName == declaration.dependency.coordinate &&
                selection.feature == declaration.feature &&
                selection.enabled
            }
          DependencyDocument.optional(declaration, enabled)
        }
        plan.localDependencies.mapTo(this, DependencyDocument::local)
      }
  }
}

@Serializable
internal data class ProjectIdentityDocument(
  val name: String?,
  val version: String?,
  val stability: String?,
  val description: String?,
) {
  companion object {
    fun from(identity: ProjectIdentity) =
      ProjectIdentityDocument(
        identity.name,
        identity.version,
        identity.stability,
        identity.description,
      )
  }
}

@Serializable
internal data class CompilerDocument(
  val version: String,
  val standard: String,
  val backend: String,
  val buildMode: String,
  val warnings: String,
  val werror: Boolean,
  val wexperimental: Boolean,
  val wshadow: Boolean,
  val wundef: Boolean,
  val unsafe: UnsafeCompilerDocument,
  val llvm: LlvmDocument,
) {
  companion object {
    fun from(settings: CompilerSettings): CompilerDocument =
      CompilerDocument(
        version = settings.version,
        standard = settings.standard,
        backend = settings.backend.name.lowercase(),
        buildMode = settings.buildMode.name.lowercase(),
        warnings = settings.warningLevel.name.lowercase(),
        werror = settings.warningsAsErrors,
        wexperimental = settings.experimentalWarnings,
        wshadow = settings.shadowWarnings,
        wundef = settings.undefinedWarnings,
        unsafe =
          UnsafeCompilerDocument(
            xppOptimizationPasses = settings.xppOptimizationPasses,
            xmmOptimizationPasses = settings.xmmOptimizationPasses,
            typeSafeFormat = settings.typeSafeFormat,
          ),
        llvm =
          LlvmDocument(
            optLevel =
              (settings.llvmOptLevel
                  ?: if (settings.buildMode == BuildMode.DEBUG) LlvmOptLevel.O0
                  else LlvmOptLevel.O3)
                .name
                .lowercase(),
            compiler = settings.llvmCompiler.name.lowercase(),
            lto = settings.llvmLto.name.lowercase(),
          ),
      )
  }
}

@Serializable
internal data class UnsafeCompilerDocument(
  val xppOptimizationPasses: Boolean,
  val xmmOptimizationPasses: Boolean,
  val typeSafeFormat: Boolean,
)

@Serializable
internal data class LlvmDocument(
  val optLevel: String,
  val compiler: String,
  val lto: String,
)

@Serializable internal data class OutputDirectoriesDocument(val release: String, val debug: String)

@Serializable internal data class PmlDocument(val enabled: Boolean)

@Serializable
internal data class DependencyDocument(
  val source: String,
  val publisher: String? = null,
  val name: String? = null,
  val version: String? = null,
  val stability: String? = null,
  val path: String? = null,
  val optional: String? = null,
  val features: Map<String, Boolean> = emptyMap(),
) {
  companion object {
    fun required(dependency: PackageDependency) = from(dependency)

    fun local(dependency: LocalPackageDependency) =
      DependencyDocument(source = "local", path = dependency.path)

    fun optional(declaration: OptionalPackageDependency, enabled: Boolean) =
      from(
        dependency = declaration.dependency,
        optional = declaration.feature,
        features = mapOf(declaration.feature to enabled),
      )

    private fun from(
      dependency: PackageDependency,
      optional: String? = null,
      features: Map<String, Boolean> = emptyMap(),
    ) =
      DependencyDocument(
        source = "viget",
        publisher = dependency.publisher,
        name = dependency.name,
        version = dependency.version,
        stability = dependency.stability.name,
        optional = optional,
        features = features,
      )
  }
}

@Serializable
internal data class PluginDocument(
  val publisher: String,
  val name: String,
  val version: String,
  val apiVersion: Int,
  val sha256: String,
  val extensions: List<String>,
  val contributions: Map<String, String>,
) {
  companion object {
    fun from(plugin: PluginPlanEntry) =
      PluginDocument(
        publisher = plugin.publisher,
        name = plugin.name,
        version = plugin.version,
        apiVersion = plugin.apiVersion,
        sha256 = plugin.sha256,
        extensions = plugin.extensions.sorted(),
        contributions = plugin.contributions.toSortedMap(),
      )
  }
}

@Serializable
internal data class WorkspaceDocument(val name: String, val path: String) {
  companion object {
    fun from(workspace: Workspace) = WorkspaceDocument(workspace.name, workspace.path)
  }
}

@Serializable
internal data class SourcesDocument(
  val viget: ViGetSourcesDocument,
  val executables: List<ExecutableSourcesDocument>,
  val libraries: List<LibrarySourcesDocument>,
  val tests: List<TestSuiteDocument>,
) {
  companion object {
    fun from(plan: ProjectPlan) =
      SourcesDocument(
        viget = ViGetSourcesDocument(plan.pushSources, plan.pushExcludes),
        executables = plan.executables.map(ExecutableSourcesDocument::from),
        libraries = plan.libraries.map(LibrarySourcesDocument::from),
        tests = plan.testSuites.map(TestSuiteDocument::from),
      )
  }
}

@Serializable
internal data class ViGetSourcesDocument(val push: Boolean, val exclude: List<String>?)

@Serializable
internal data class ExecutableSourcesDocument(
  val name: String,
  val srcDir: String,
  val entry: String,
  val exclude: List<String>?,
) {
  companion object {
    fun from(target: ExecutableSourceTarget) =
      ExecutableSourcesDocument(target.name, target.srcDir, target.entry, target.exclude)
  }
}

@Serializable
internal data class LibrarySourcesDocument(
  val name: String,
  val viPkgTypes: List<String>,
  val srcDir: String,
  val namespace: String?,
  val exclude: List<String>?,
) {
  companion object {
    fun from(target: LibrarySourceTarget) =
      LibrarySourcesDocument(
        target.name,
        target.viPkgTypes.map { it.name.lowercase() },
        target.srcDir,
        target.namespace,
        target.exclude,
      )
  }
}

@Serializable
internal data class TestSuiteDocument(
  val name: String,
  val testDir: String,
  val framework: String?,
  val exclude: List<String>?,
) {
  companion object {
    fun from(suite: TestSuite) =
      TestSuiteDocument(suite.name, suite.testDir, suite.framework, suite.exclude)
  }
}
