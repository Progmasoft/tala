/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talafmt.config

import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import kotlin.system.exitProcess

private const val PROTOCOL_VERSION = "talafmt-config-v1"

fun main(arguments: Array<String>) {
  if (arguments.size != 2) {
    System.err.println("internal talafmt configuration usage: <project-root> <output-file>")
    exitProcess(2)
  }

  try {
    val root = File(arguments[0]).canonicalFile
    val script = root.resolve("talafmt.kts")
    val configuration =
      if (script.isFile) evaluateFormatterScript(script) else formatterConfiguration()
    writeConfiguration(Path.of(arguments[1]), configuration)
  } catch (problem: Exception) {
    System.err.println("talafmt configuration: ${problem.message}")
    exitProcess(1)
  }
}

private fun writeConfiguration(
  output: Path,
  configuration: FormatterConfiguration,
) {
  Files.newOutputStream(output).use { stream ->
    listOf(
        PROTOCOL_VERSION,
        configuration.encoding.input.protocolName(),
        configuration.encoding.output.protocolName(),
        configuration.encoding.emitByteOrderMark.toString(),
      )
      .forEach { value ->
        stream.write(value.toByteArray(StandardCharsets.UTF_8))
        stream.write(0)
      }
  }
}

private fun Encoding.protocolName() = name.lowercase().replace('_', '-')
