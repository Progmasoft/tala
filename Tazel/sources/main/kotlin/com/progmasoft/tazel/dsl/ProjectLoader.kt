/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl

import com.progmasoft.api.tazel.dsl.plugin.ProjectPlugin
import com.progmasoft.tazel.dsl.plugin.PluginPreamble
import com.progmasoft.tazel.dsl.plugin.PluginResolver
import com.progmasoft.tazel.dsl.plugin.PluginRuntime
import com.progmasoft.tazel.dsl.plugin.ResolvedPlugin
import java.net.URLClassLoader
import java.nio.file.Files
import java.nio.file.Path
import java.util.ServiceLoader
import kotlin.script.experimental.api.ResultValue
import kotlin.script.experimental.api.ResultWithDiagnostics
import kotlin.script.experimental.api.ScriptCompilationConfiguration
import kotlin.script.experimental.api.ScriptDiagnostic
import kotlin.script.experimental.api.ScriptEvaluationConfiguration
import kotlin.script.experimental.api.compilerOptions
import kotlin.script.experimental.api.defaultImports
import kotlin.script.experimental.host.toScriptSource
import kotlin.script.experimental.jvm.baseClassLoader
import kotlin.script.experimental.jvm.dependenciesFromClassContext
import kotlin.script.experimental.jvm.jvm
import kotlin.script.experimental.jvm.updateClasspath
import kotlin.script.experimental.jvmhost.BasicJvmScriptingHost

private const val MINIMUM_JAVA = 25

/**
 * The names a project file can have, in the order they are looked for. The first one that exists is
 * the project file; the others are not read. All of them hold the same Kotlin script.
 */
val PROJECT_FILE_NAMES = listOf("BUILD.kts", "BUILD.tzl", "BUILD.tazel", "BUILD", "Tazel.build")

/** A project file and the directory it describes. */
data class ProjectLocation(
  val root: Path,
  val file: Path,
)

/** A project file after its script ran. */
data class LoadedProject(
  val location: ProjectLocation,
  val plan: ProjectPlan,
)

internal fun isSupportedJavaFeature(actual: Int) = actual >= MINIMUM_JAVA

internal fun requireSupportedJava() {
  val actual = Runtime.version().feature()
  if (!isSupportedJavaFeature(actual)) {
    throw ProjectConfigurationException("JRE 25 or newer is required; found Java $actual")
  }
}

/** The project file of [directory] itself, when it has one. */
fun projectFileIn(directory: Path): ProjectLocation? {
  val root = directory.toAbsolutePath().normalize()
  // Windows and macOS would find "build.kts" for "BUILD.kts"; the names are case-sensitive, so
  // the directory is listed and its entries are compared as they are spelled.
  val names =
    try {
      Files.newDirectoryStream(root).use { entries ->
        entries.filter(Files::isRegularFile).map { it.fileName.toString() }.toSet()
      }
    } catch (_: java.io.IOException) {
      return null
    }
  val name = PROJECT_FILE_NAMES.firstOrNull(names::contains) ?: return null
  return ProjectLocation(root, root.resolve(name))
}

/** The project that [start] belongs to: its own, or the nearest one of a directory above it. */
fun discoverProject(start: Path): ProjectLocation {
  var directory: Path? = start.toAbsolutePath().normalize()
  while (directory != null) {
    projectFileIn(directory)?.let {
      return it
    }
    directory = directory.parent
  }
  throw ProjectConfigurationException(
    "no project file found from ${start.toAbsolutePath().normalize()}; " +
      "a project has one of ${PROJECT_FILE_NAMES.joinToString()}"
  )
}

/**
 * Runs project files. The script of a project is compiled and run inside Tazel itself, so a machine
 * needs no Kotlin installation beside it.
 */
class ProjectLoader(private val compilerVersion: String = "unknown") {
  private val host = BasicJvmScriptingHost()

  fun load(location: ProjectLocation): LoadedProject {
    requireSupportedJava()
    val source =
      try {
        Files.readString(location.file)
      } catch (error: java.io.IOException) {
        throw ProjectConfigurationException(
          "${location.file} could not be read as UTF-8 text: ${error.message}"
        )
      }
    val plugins = PluginResolver.resolve(location.root, PluginPreamble.parse(source))
    val pluginLoader =
      URLClassLoader(
        plugins.map { it.artifact.toUri().toURL() }.toTypedArray(),
        ProjectLoader::class.java.classLoader,
      )
    // The model a script fills is one object, so two scripts are never run at once.
    synchronized(ProjectRuntime) {
      ProjectRuntime.reset(compilerVersion)
      try {
        PluginRuntime.activate(
          plugins,
          ServiceLoader.load(ProjectPlugin::class.java, pluginLoader).toList(),
          location.root,
        )
        run(location, source, plugins, pluginLoader)
        return LoadedProject(location, ProjectRuntime.build())
      } finally {
        pluginLoader.close()
      }
    }
  }

  private fun run(
    location: ProjectLocation,
    source: String,
    plugins: List<ResolvedPlugin>,
    pluginLoader: ClassLoader,
  ) {
    val imports =
      listOf("com.progmasoft.tazel.dsl.*", "com.progmasoft.tazel.dsl.plugin.plugins") +
        plugins.flatMap(ResolvedPlugin::imports)
    val compilation = ScriptCompilationConfiguration {
      defaultImports(imports.distinct())
      compilerOptions.append("-jvm-target", MINIMUM_JAVA.toString())
      jvm {
        dependenciesFromClassContext(ProjectLoader::class, wholeClasspath = true)
        updateClasspath(plugins.map { it.artifact.toFile() })
      }
    }
    val evaluation = ScriptEvaluationConfiguration { jvm { baseClassLoader(pluginLoader) } }
    val fileName = location.file.fileName.toString()
    // The script host tells a script by its extension; every project file is the same script.
    val scriptName = if (fileName.endsWith(".kts")) fileName else "$fileName.kts"
    val result = host.eval(source.toScriptSource(scriptName), compilation, evaluation)
    val errors =
      result.reports.filter {
        it.severity == ScriptDiagnostic.Severity.ERROR ||
          it.severity == ScriptDiagnostic.Severity.FATAL
      }
    if (result is ResultWithDiagnostics.Failure || errors.isNotEmpty()) {
      throw ProjectConfigurationException(
        errors.ifEmpty { result.reports }.joinToString("\n") { describe(location, it) }
      )
    }
    val value = (result as ResultWithDiagnostics.Success).value.returnValue
    if (value is ResultValue.Error) {
      when (val error = value.error) {
        is ProjectConfigurationException -> throw error
        is ProjectAbort ->
          throw ProjectConfigurationException("${location.file.fileName}: ${error.message}")
        else ->
          throw ProjectConfigurationException(
            "${location.file.fileName} failed: ${error.message ?: error.javaClass.name}"
          )
      }
    }
  }

  private fun describe(
    location: ProjectLocation,
    report: ScriptDiagnostic,
  ): String {
    val start = report.location?.start
    val position = if (start == null) "" else ":${start.line}:${start.col}"
    return "${location.file.fileName}$position: ${report.message}"
  }
}
