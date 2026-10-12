/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.ConcurrentHashMap
import kotlin.io.path.writeText
import kotlin.system.exitProcess

private const val MINIMUM_JAVA = 25

internal data class ProjectFiles(
  val root: File,
  val project: File,
)

private fun usage() =
  "internal talac project evaluator usage: evaluate [project-root]\n" +
    "       resolve [project-root]\n" +
    "       sources0 <project-root> <output-file>"

internal fun isSupportedJavaFeature(actual: Int) = actual >= MINIMUM_JAVA

internal fun requireSupportedJava() {
  val actual = Runtime.version().feature()
  if (!isSupportedJavaFeature(actual)) {
    throw ProjectConfigurationException("JRE 25 or newer is required; found Java $actual")
  }
}

private fun filesAt(root: File): ProjectFiles? {
  val project = root.resolve("BUILD.kts").takeIf(File::isFile) ?: return null
  return ProjectFiles(root, project)
}

internal fun discoverProject(input: File): ProjectFiles {
  if (input.isFile) {
    return filesAt(input.absoluteFile.parentFile.canonicalFile)
      ?: throw ProjectConfigurationException("no X# Kotlin project file found beside $input")
  }
  var root: File? = input.canonicalFile
  while (root != null) {
    filesAt(root)?.let { files ->
      return files
    }
    root = root.parentFile
  }
  throw ProjectConfigurationException("no X# Kotlin project file found from ${input.canonicalFile}")
}

private val runtimeClasspath: String by lazy {
  System.getProperty("java.class.path")
    .split(File.pathSeparator)
    .filter { entry -> File(entry).exists() }
    .joinToString(File.pathSeparator)
}

private data class CachedProjectScript(
  val size: Long,
  val modified: Long,
  val source: String,
  val requests: List<PluginRequest>,
)

private val projectScriptCache = ConcurrentHashMap<Path, CachedProjectScript>()

private fun prepareScript(script: File): CachedProjectScript {
  val path = script.toPath().toAbsolutePath().normalize()
  val size = Files.size(path)
  val modified = Files.getLastModifiedTime(path).toMillis()
  projectScriptCache[path]
    ?.takeIf { it.size == size && it.modified == modified }
    ?.let {
      return it
    }
  val source = script.readText()
  val prepared = CachedProjectScript(size, modified, source, PluginPreamble.parse(source))
  projectScriptCache[path] = prepared
  return prepared
}

internal fun kotlinCommand(
  environment: Map<String, String> = System.getenv(),
  osName: String = System.getProperty("os.name"),
): String {
  environment.entries
    .firstOrNull { it.key.equals("TALA_KOTLIN", ignoreCase = true) }
    ?.value
    ?.takeIf(String::isNotBlank)
    ?.let {
      return it
    }
  if (!osName.startsWith("Windows")) return "kotlin"
  val path =
    environment.entries.firstOrNull { it.key.equals("PATH", ignoreCase = true) }?.value
      ?: return "kotlin"
  return path
    .split(File.pathSeparatorChar)
    .asSequence()
    .map { directory -> File(directory, "kotlin.bat") }
    .firstOrNull(File::isFile)
    ?.absolutePath ?: "kotlin"
}

private fun runKotlin(
  script: File,
  root: File,
  output: String,
  sourcesOutput: Path?,
): Int {
  val directory = Files.createTempDirectory("tala-project-kts-")
  return try {
    val prepared = prepareScript(script)
    val resolvedPlugins = PluginResolver.resolve(root.toPath(), prepared.requests)
    val pluginManifest = directory.resolve("plugins.manifest")
    PluginManifest.write(pluginManifest, resolvedPlugins)
    val wrapped = directory.resolve(script.name)
    val suffix = "\nemitProject()\n"
    val imports =
      resolvedPlugins.flatMap(ResolvedPlugin::imports).distinct().joinToString("") { importName ->
        "import $importName\n"
      }
    wrapped.writeText(
      "import com.progmasoft.tazel.project.*\n" +
        imports +
        "PluginRuntime.activate()\n" +
        prepared.source +
        suffix
    )
    val kotlin = kotlinCommand()
    val properties =
      mutableListOf(
        "-Dtazel.project.root=${root.absolutePath}",
        "-Dtazel.project.output=$output",
        "-Dtazel.project.pluginManifest=$pluginManifest",
      )
    if (sourcesOutput != null) properties += "-Dtazel.project.sources=$sourcesOutput"
    val arguments = mutableListOf<String>()
    if (
      System.getProperty("os.name").startsWith("Windows") &&
        kotlin.endsWith(".bat", ignoreCase = true)
    ) {
      val kotlinHome = File(kotlin).canonicalFile.parentFile.parentFile
      arguments += File(System.getProperty("java.home"), "bin/java.exe").absolutePath
      arguments += "--enable-native-access=ALL-UNNAMED"
      arguments += properties
      arguments += "-Dkotlin.home=${kotlinHome.absolutePath}"
      arguments += "-cp"
      arguments += kotlinHome.resolve("lib/kotlin-runner.jar").absolutePath
      arguments += "org.jetbrains.kotlin.runner.Main"
    } else {
      arguments += kotlin
      arguments += properties
    }
    arguments +=
      listOf(
        "-classpath",
        (listOf(runtimeClasspath) + resolvedPlugins.map { it.artifact.toString() }).joinToString(
          File.pathSeparator
        ),
        "-howtorun",
        "script",
        wrapped.toString(),
      )
    try {
      ProcessBuilder(arguments)
        .apply { environment()["JAVA_HOME"] = System.getProperty("java.home") }
        .inheritIO()
        .start()
        .waitFor()
    } catch (error: java.io.IOException) {
      throw ProjectConfigurationException(
        "kotlin is required and could not be started: ${error.message}"
      )
    }
  } finally {
    directory.toFile().deleteRecursively()
  }
}

internal fun evaluateWithKotlin(
  input: File,
  output: String = "plan",
  sourcesOutput: Path? = null,
): Int {
  requireSupportedJava()
  val files = discoverProject(input)
  return runKotlin(files.project, files.root, output, sourcesOutput)
}

fun main(args: Array<String>) {
  val validEvaluate = args.size in 1..2 && args[0] == "evaluate"
  val validResolve = args.size in 1..2 && args[0] == "resolve"
  val validSources = args.size == 3 && args[0] == "sources0"
  if (!validEvaluate && !validResolve && !validSources) {
    System.err.println(usage())
    exitProcess(2)
  }
  val input = File(args.getOrElse(1) { "." })
  try {
    val status =
      if (args[0] == "evaluate") {
        evaluateWithKotlin(input)
      } else if (args[0] == "resolve") {
        evaluateWithKotlin(input, "resolve")
      } else {
        evaluateWithKotlin(input, "sources0", Path.of(args[2]))
      }
    exitProcess(status)
  } catch (error: ProjectConfigurationException) {
    System.err.println("talac: project evaluator: ${error.message}")
    exitProcess(1)
  }
}
