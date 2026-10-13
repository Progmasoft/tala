/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.driver

import com.progmasoft.tazel.dsl.OperatingSystem
import com.progmasoft.tazel.dsl.ProjectConfigurationException
import java.io.File
import java.nio.file.Files
import java.nio.file.Path

/** The programs Tazel starts. Each is a separate program; Tazel only passes arguments to it. */
enum class Tool(
  val command: String,
  val environment: String,
) {
  TALAC("talac", "TAZEL_TALAC"),
  TALAFMT("talafmt", "TAZEL_TALAFMT"),
  TALALINT("talalint", "TAZEL_TALALINT"),
}

/** The extension the host gives an executable file. */
fun executableExtension(os: OperatingSystem) = if (os == OperatingSystem.WINDOWS) ".exe" else ""

/**
 * Finds the tools of a Tala installation.
 *
 * A tool is looked for in three places, in this order: the path its environment variable names, the
 * installation Tazel itself runs from, and the directories of `PATH`.
 */
class Toolchain(
  private val os: OperatingSystem,
  private val environment: Map<String, String> = System.getenv(),
  private val home: Path? = installationHome(),
) {
  fun find(tool: Tool): Path? {
    val fileName = tool.command + executableExtension(os)
    variable(tool.environment)?.let { configured ->
      return Path.of(configured).takeIf(Files::isRegularFile)
    }
    val installed = listOfNotNull(home?.resolve("bin"), home)
    val searched = variable("PATH").orEmpty().split(File.pathSeparatorChar)
    return (installed + searched.filter(String::isNotEmpty).map(Path::of))
      .map { it.resolve(fileName) }
      .firstOrNull(Files::isRegularFile)
  }

  fun require(tool: Tool): Path =
    find(tool)
      ?: throw ProjectConfigurationException(
        variable(tool.environment)?.let { "${tool.environment} names no file: $it" }
          ?: "${tool.command} was not found beside tazel or on PATH; " +
            "set ${tool.environment} to its path"
      )

  // Windows spells the same variable "Path" or "PATH".
  private fun variable(name: String) =
    environment.entries
      .firstOrNull { it.key.equals(name, ignoreCase = os == OperatingSystem.WINDOWS) }
      ?.value
      ?.takeIf(String::isNotBlank)
}

/** The directory above the `lib` directory that holds the JAR of Tazel, when it runs from one. */
internal fun installationHome(): Path? =
  try {
    val location = Path.of(Toolchain::class.java.protectionDomain.codeSource.location.toURI())
    location.takeIf { it.toString().endsWith(".jar") }?.parent?.parent
  } catch (_: Exception) {
    null
  }
