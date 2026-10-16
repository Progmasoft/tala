/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.cli

import com.github.ajalt.mordant.rendering.TextColors.brightCyan
import com.github.ajalt.mordant.rendering.TextColors.brightRed
import com.github.ajalt.mordant.rendering.TextStyles.bold
import com.github.ajalt.mordant.rendering.TextStyles.dim
import com.github.ajalt.mordant.rendering.Widget
import com.github.ajalt.mordant.table.verticalLayout
import com.github.ajalt.mordant.terminal.Terminal
import com.github.ajalt.mordant.widgets.Text
import com.progmasoft.tazel.driver.SystemProcesses
import com.progmasoft.tazel.driver.Toolchain
import com.progmasoft.tazel.dsl.detectHost
import java.nio.file.Path
import kotlin.system.exitProcess

/** The version the JAR of Tazel was built as; a run from loose classes has none. */
internal fun tazelVersion(): String =
  Tazel::class.java.`package`?.implementationVersion ?: "development"

/** What each command takes after its name; shared by the help of one command. */
private val usage =
  mapOf(
    CommandName.CHECK to "[selection]",
    CommandName.BUILD to "[selection]",
    CommandName.RUN to "[selection] [-- program arguments]",
    CommandName.TEST to "[selection]",
    CommandName.LOCK_CREATE_DUMP to "[--path File]",
    CommandName.INSTALL to "[--global | -g] Publisher.Name",
    CommandName.HELP to "[command]",
    CommandName.FMT to "[-- talafmt options]",
    CommandName.LINT to "[--workspace | selection] [-- talalint options]",
  )

private const val SELECTION_HELP =
  "A selection names what the command works on; without one it works on everything.\n" +
    "  --vipkg, -p Name        only the ViPkg of this name\n" +
    "  --executable, -e Name   only the executable of this name\n" +
    "  --library, -l Name      only the library of this name\n" +
    "Each flag may be written several times."

/** The help as Mordant renders it: a title, the usage, and the commands as a table. */
internal fun helpWidget(topic: CommandName?): Widget {
  if (topic != null) return Text(helpText(topic))
  return verticalLayout {
    cell((bold + brightCyan)("Tazel") + ", the build system and package manager of Tala.")
    cell("")
    cell(bold("usage") + ": tazel <command> [arguments]")
    cell("")
    cell(bold("commands") + ":")
    // Aligned lines rather than a table: a table wraps a long summary into a second row and can
    // cut a command name short on a narrow terminal, and a command name must stay whole.
    val width = CommandName.entries.maxOf { it.words.length }
    CommandName.entries.forEach {
      cell("  " + (bold + brightCyan)(it.words.padEnd(width)) + "  " + it.summary)
    }
    cell("")
    cell(dim("tazel help <command> explains one command."))
  }
}

internal fun helpText(topic: CommandName?): String {
  if (topic != null) {
    val arguments = usage[topic]
    val line = listOfNotNull("tazel", topic.words, arguments).joinToString(" ")
    val selection = if (arguments.orEmpty().contains("selection")) "\n\n$SELECTION_HELP" else ""
    return "usage: $line\n\n${topic.summary.replaceFirstChar(Char::uppercase)}.$selection"
  }
  val width = CommandName.entries.maxOf { it.words.length }
  val commands =
    CommandName.entries.joinToString("\n") { "  ${it.words.padEnd(width)}  ${it.summary}" }
  return "Tazel, the build system and package manager of Tala.\n\n" +
    "usage: tazel <command> [arguments]\n\n" +
    "commands:\n$commands\n\n" +
    "tazel help <command> explains one command."
}

/**
 * Prints an error, and under it the hint of what was probably meant when there is one. Both go to
 * standard error.
 */
internal fun reportError(
  terminal: Terminal,
  message: String,
  hint: String? = null,
) {
  terminal.println((bold + brightRed)("error") + ": " + message, stderr = true)
  if (hint != null) terminal.println((bold + brightCyan)(" hint") + ": " + hint, stderr = true)
}

fun main(arguments: Array<String>) {
  val terminal = Terminal()
  val exitCode =
    when (val parsed = parseCommandLine(arguments.toList())) {
      is ParseResult.Rejected -> {
        reportError(terminal, parsed.message, parsed.hint)
        ExitCode.USAGE
      }
      is ParseResult.Parsed -> {
        val host = detectHost()
        Tazel(
            terminal,
            Path.of("").toAbsolutePath(),
            host.os,
            Toolchain(host.os),
            SystemProcesses,
            tazelVersion(),
          )
          .run(parsed.command)
      }
    }
  exitProcess(exitCode)
}
