/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dc

import com.progmasoft.tazel.project.ProjectConfigurationException
import com.progmasoft.tazel.project.ProjectLockFile
import com.progmasoft.tazel.project.discoverProject
import com.progmasoft.tazel.project.evaluateWithKotlin
import com.progmasoft.tazel.project.requireSupportedJava
import java.io.File
import java.nio.file.Path
import kotlin.system.exitProcess

private const val TADC_USAGE = "usage: tadc -Projectfile BUILD.kts -Output <file>"

internal data class TadcCommand(
  val projectFile: File,
  val output: Path,
)

internal fun parseTadcCommand(args: Array<String>): TadcCommand {
  var projectFile: File? = null
  var output: Path? = null
  var index = 0
  while (index < args.size) {
    val option = args[index]
    if (option != "-Projectfile" && option != "-Output") {
      throw ProjectConfigurationException("unknown TADC option '$option'\n$TADC_USAGE")
    }
    if (index + 1 >= args.size) {
      throw ProjectConfigurationException("missing value for TADC option '$option'\n$TADC_USAGE")
    }
    val value = args[index + 1]
    when (option) {
      "-Projectfile" -> {
        if (projectFile != null) {
          throw ProjectConfigurationException("duplicate TADC option '-Projectfile'")
        }
        projectFile = File(value)
      }
      "-Output" -> {
        if (output != null) throw ProjectConfigurationException("duplicate TADC option '-Output'")
        output = Path.of(value)
      }
    }
    index += 2
  }

  val project =
    projectFile
      ?: throw ProjectConfigurationException(
        "missing required TADC option '-Projectfile'\n$TADC_USAGE"
      )
  val destination =
    output
      ?: throw ProjectConfigurationException("missing required TADC option '-Output'\n$TADC_USAGE")
  if (project.name != "BUILD.kts" || !project.isFile) {
    throw ProjectConfigurationException("-Projectfile must name an existing BUILD.kts file")
  }
  return TadcCommand(project.canonicalFile, destination)
}

fun main(args: Array<String>) {
  try {
    requireSupportedJava()
    val command = parseTadcCommand(args)
    val project = discoverProject(command.projectFile)
    val status = evaluateWithKotlin(command.projectFile, "resolve")
    if (status != 0) exitProcess(status)
    LockfileDump.write(project.root.toPath().resolve(ProjectLockFile.FILE_NAME), command.output)
    println("tadc: wrote '${command.output.toAbsolutePath().normalize()}'")
  } catch (error: ProjectConfigurationException) {
    System.err.println("tadc: ${error.message}")
    exitProcess(1)
  } catch (error: java.sql.SQLException) {
    System.err.println("tadc: SQLite dump failed: ${error.message}")
    exitProcess(1)
  }
}
