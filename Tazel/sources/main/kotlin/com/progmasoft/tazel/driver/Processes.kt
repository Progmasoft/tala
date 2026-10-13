/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.driver

import com.progmasoft.tazel.dsl.ProjectConfigurationException
import java.nio.file.Path
import java.util.concurrent.TimeUnit

/** Starts the programs Tazel runs. A test replaces it to see the commands without running them. */
interface Processes {
  /** Runs [command] in [directory] on the streams of Tazel and returns its exit code. */
  fun run(
    command: List<String>,
    directory: Path,
  ): Int

  /** Runs [command] and returns what it wrote to its output, or null when it failed. */
  fun capture(command: List<String>): String?
}

object SystemProcesses : Processes {
  override fun run(
    command: List<String>,
    directory: Path,
  ): Int =
    try {
      ProcessBuilder(command).directory(directory.toFile()).inheritIO().start().waitFor()
    } catch (error: java.io.IOException) {
      throw ProjectConfigurationException(
        "${command.first()} could not be started: ${error.message}"
      )
    }

  override fun capture(command: List<String>): String? =
    try {
      val process =
        ProcessBuilder(command)
          .redirectErrorStream(true)
          .redirectInput(ProcessBuilder.Redirect.from(nullDevice()))
          .start()
      val output = process.inputStream.bufferedReader().readText()
      if (process.waitFor(30, TimeUnit.SECONDS) && process.exitValue() == 0) output else null
    } catch (_: java.io.IOException) {
      null
    }

  private fun nullDevice() =
    java.io.File(if (System.getProperty("os.name").startsWith("Windows")) "NUL" else "/dev/null")
}
