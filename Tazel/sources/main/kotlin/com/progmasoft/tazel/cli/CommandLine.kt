/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.cli

/**
 * The targets a command works on. Empty lists mean every target of that kind; a command line that
 * names any target works on the named ones only.
 */
data class TargetSelection(
  val viPkgs: List<String> = emptyList(),
  val executables: List<String> = emptyList(),
  val libraries: List<String> = emptyList(),
) {
  val isEverything: Boolean
    get() = viPkgs.isEmpty() && executables.isEmpty() && libraries.isEmpty()
}

/** A package of ViGet as it is written on the command line: `Publisher.Name`. */
data class PackageCoordinate(
  val publisher: String,
  val name: String,
) {
  override fun toString() = "$publisher.$name"
}

/** The commands of Tazel by the words that select them. */
enum class CommandName(val words: String, val summary: String) {
  CHECK("check", "check the sources of the project without writing an executable"),
  BUILD("build", "build the targets of the project"),
  RUN("run", "build the executables of the project and run them"),
  TEST("test", "build and run the test suites of the project"),
  LOCK_RESOLVE("lock resolve", "resolve the dependencies and renew LOCK.sqlite3"),
  LOCK_CREATE_DUMP(
    "lock create-dump",
    "write the lockfile as text, to LOCK.dump unless --path names a file",
  ),
  UPDATE("update", "update the dependencies of the system and of the project"),
  INSTALL("install", "download a package from ViGet into the project"),
  VIPKG_CREATE("vipkg create", "write a local .vipkg for every target"),
  VIGET_PUSH("viget push", "build, test and publish the package to ViGet for the first time"),
  VIGET_UPDATE("viget update", "build, test and publish a new version of the package"),
  VERSION("version", "print the version of Tazel"),
  HELP("help", "print this help, or the help of one command"),
  FMT("fmt", "format the sources of the project with talafmt"),
  LINT("lint", "lint the sources of the project with talalint"),
}

/** One invocation of Tazel after its words became values. */
sealed interface Command {
  val name: CommandName

  data class Check(val targets: TargetSelection) : Command {
    override val name = CommandName.CHECK
  }

  data class Build(val targets: TargetSelection) : Command {
    override val name = CommandName.BUILD
  }

  /** [programArguments] are what follows `--`; they are handed to the program unread. */
  data class Run(
    val targets: TargetSelection,
    val programArguments: List<String>,
  ) : Command {
    override val name = CommandName.RUN
  }

  data class Test(val targets: TargetSelection) : Command {
    override val name = CommandName.TEST
  }

  data object LockResolve : Command {
    override val name = CommandName.LOCK_RESOLVE
  }

  /**
   * [path] is the file to write, as written after `--path`; LOCK.dump beside the project file when
   * absent. Its folder has to exist already.
   */
  data class LockCreateDump(val path: String? = null) : Command {
    override val name = CommandName.LOCK_CREATE_DUMP
  }

  data object Update : Command {
    override val name = CommandName.UPDATE
  }

  /** [global] installs for the system and not for the project. */
  data class Install(
    val coordinate: PackageCoordinate,
    val global: Boolean,
  ) : Command {
    override val name = CommandName.INSTALL
  }

  data object ViPkgCreate : Command {
    override val name = CommandName.VIPKG_CREATE
  }

  data object ViGetPush : Command {
    override val name = CommandName.VIGET_PUSH
  }

  data object ViGetUpdate : Command {
    override val name = CommandName.VIGET_UPDATE
  }

  data object Version : Command {
    override val name = CommandName.VERSION
  }

  /** [topic] is the command whose help was asked for; the general help when absent. */
  data class Help(val topic: CommandName?) : Command {
    override val name = CommandName.HELP
  }

  /** [toolArguments] are what follows `--`; they are handed to talafmt unread. */
  data class Fmt(val toolArguments: List<String>) : Command {
    override val name = CommandName.FMT
  }

  /**
   * [workspace] lints every member of the workspace. [toolArguments] are what follows `--`; they
   * are handed to talalint unread.
   */
  data class Lint(
    val workspace: Boolean,
    val targets: TargetSelection,
    val toolArguments: List<String>,
  ) : Command {
    override val name = CommandName.LINT
  }
}

/** The outcome of reading a command line: a command, or the reason there is none. */
sealed interface ParseResult {
  data class Parsed(val command: Command) : ParseResult

  /** [hint] suggests what was probably meant, when a word looks like a typo of a real one. */
  data class Rejected(
    val message: String,
    val hint: String? = null,
  ) : ParseResult
}

/**
 * Reads the arguments of one invocation, the program name excluded.
 *
 * The parser is written by hand so that every accepted line is a value of [Command] and nothing
 * else: there is no table of strings a later stage would have to interpret again. An option takes
 * its value from the next argument, `--vipkg Name`; `--` ends the arguments Tazel reads.
 */
fun parseCommandLine(arguments: List<String>): ParseResult {
  if (arguments.isEmpty()) return ParseResult.Parsed(Command.Help(null))
  val reader = ArgumentReader(arguments)
  return try {
    ParseResult.Parsed(reader.command())
  } catch (problem: CommandLineProblem) {
    ParseResult.Rejected(problem.message ?: "the command line could not be read", problem.hint)
  }
}

private class CommandLineProblem(
  message: String,
  val hint: String?,
) : Exception(message)

private fun reject(
  message: String,
  hint: String? = null,
): Nothing = throw CommandLineProblem(message, hint)

/** The hint for [word] among [candidates], written as [spell] spells the match. */
private fun hint(
  word: String,
  candidates: Iterable<String>,
  spell: (String) -> String = { it },
): String? = closestTo(word, candidates)?.let { didYouMean(word, spell(it)) }

/** The first word of every command, in the order of the help. */
private val commandWords = CommandName.entries.map { it.words.substringBefore(' ') }.distinct()

private val selectionFlags = listOf("--vipkg", "-p", "--executable", "-e", "--library", "-l")

/** The flags that select targets, shared by every command that takes them. */
private class SelectionBuilder {
  val viPkgs = mutableListOf<String>()
  val executables = mutableListOf<String>()
  val libraries = mutableListOf<String>()

  /** True when [flag] was one of the selection flags and its value was taken from [reader]. */
  fun take(
    flag: String,
    reader: ArgumentReader,
  ): Boolean {
    val destination =
      when (flag) {
        "--vipkg",
        "-p" -> viPkgs
        "--executable",
        "-e" -> executables
        "--library",
        "-l" -> libraries
        else -> return false
      }
    val value = reader.value(flag)
    if (!isTargetName(value)) reject("$flag takes the name of a target, and '$value' is not one")
    if (value in destination) reject("$flag $value is written twice")
    destination += value
    return true
  }

  fun build() = TargetSelection(viPkgs.toList(), executables.toList(), libraries.toList())
}

private class ArgumentReader(private val arguments: List<String>) {
  private var position = 0

  private fun hasNext() = position < arguments.size

  private fun next() = arguments[position++]

  /** The argument after a flag that takes a value. */
  fun value(flag: String): String {
    if (!hasNext()) reject("$flag requires a value")
    val value = next()
    if (value.startsWith("-")) reject("$flag requires a value, and '$value' is an option")
    return value
  }

  /** Everything after `--`, or nothing when the line ended before one. */
  private fun passThrough(): List<String> {
    val rest = arguments.subList(position, arguments.size).toList()
    position = arguments.size
    return rest
  }

  private fun finish(command: CommandName) {
    if (hasNext()) reject("'${next()}' is not an argument of tazel ${command.words}")
  }

  /** The second word of a command of two words. */
  private fun action(
    first: String,
    vararg actions: String,
  ): String {
    val choices = actions.joinToString(" or ") { "tazel $first $it" }
    if (!hasNext()) reject("tazel $first needs an action: $choices")
    val action = next()
    if (action !in actions) {
      reject(
        "'$action' is not an action of tazel $first; write $choices",
        hint(action, actions.asList()) { "tazel $first $it" },
      )
    }
    return action
  }

  fun command(): Command =
    when (val word = next()) {
      "check" -> Command.Check(selection(CommandName.CHECK))
      "build" -> Command.Build(selection(CommandName.BUILD))
      "run" -> run()
      "test" -> Command.Test(selection(CommandName.TEST))
      "lock" ->
        when (action("lock", "resolve", "create-dump")) {
          "resolve" -> Command.LockResolve.also { finish(CommandName.LOCK_RESOLVE) }
          else -> lockCreateDump()
        }
      "update" -> Command.Update.also { finish(CommandName.UPDATE) }
      "install" -> install()
      "vipkg" -> {
        action("vipkg", "create")
        Command.ViPkgCreate.also { finish(CommandName.VIPKG_CREATE) }
      }
      "viget" ->
        when (action("viget", "push", "update")) {
          "push" -> Command.ViGetPush.also { finish(CommandName.VIGET_PUSH) }
          else -> Command.ViGetUpdate.also { finish(CommandName.VIGET_UPDATE) }
        }
      "version" -> Command.Version.also { finish(CommandName.VERSION) }
      "help" -> help()
      "fmt" -> fmt()
      "lint" -> lint()
      else ->
        reject(
          "'$word' is not a command of tazel; write tazel help for the commands",
          if (word == "--help" || word == "-h") didYouMean(word, "tazel help")
          else hint(word, commandWords) { "tazel $it" },
        )
    }

  private fun lockCreateDump(): Command {
    var path: String? = null
    while (hasNext()) {
      when (val argument = next()) {
        "--path" -> {
          if (path != null) reject("--path is written twice")
          path = value("--path")
          if (path.isBlank()) reject("--path takes the name of a file, and it is empty")
        }
        else ->
          reject(
            "'$argument' is not an argument of tazel lock create-dump",
            hint(argument, listOf("--path")),
          )
      }
    }
    return Command.LockCreateDump(path)
  }

  /** A command whose only arguments select targets. */
  private fun selection(command: CommandName): TargetSelection {
    val selection = SelectionBuilder()
    while (hasNext()) {
      val flag = next()
      if (!selection.take(flag, this)) {
        reject("'$flag' is not an argument of tazel ${command.words}", hint(flag, selectionFlags))
      }
    }
    return selection.build()
  }

  private fun run(): Command {
    val selection = SelectionBuilder()
    while (hasNext()) {
      val flag = next()
      if (flag == "--") return Command.Run(selection.build(), passThrough())
      if (!selection.take(flag, this)) {
        reject(
          "'$flag' is not an argument of tazel run; program arguments follow '--'",
          hint(flag, selectionFlags),
        )
      }
    }
    return Command.Run(selection.build(), emptyList())
  }

  private fun install(): Command {
    var coordinate: PackageCoordinate? = null
    var global = false
    while (hasNext()) {
      when (val argument = next()) {
        "--global",
        "-g" -> {
          if (global) reject("--global is written twice")
          global = true
        }
        else -> {
          if (argument.startsWith("-")) {
            reject(
              "'$argument' is not an option of tazel install",
              hint(argument, listOf("--global", "-g")),
            )
          }
          if (coordinate != null)
            reject("tazel install takes one package, and '$argument' is a second")
          coordinate = packageCoordinate(argument)
        }
      }
    }
    return Command.Install(
      coordinate ?: reject("tazel install needs a package: tazel install Publisher.Name"),
      global,
    )
  }

  private fun help(): Command {
    if (!hasNext()) return Command.Help(null)
    val words = passThrough().joinToString(" ")
    val topic =
      CommandName.entries.firstOrNull { it.words == words }
        ?: reject(
          "'$words' is not a command of tazel; write tazel help for the commands",
          hint(words, CommandName.entries.map { it.words }) { "tazel help $it" },
        )
    return Command.Help(topic)
  }

  private fun fmt(): Command {
    if (!hasNext()) return Command.Fmt(emptyList())
    val argument = next()
    if (argument != "--") {
      reject("'$argument' is not an argument of tazel fmt; options of talafmt follow '--'")
    }
    return Command.Fmt(passThrough())
  }

  private fun lint(): Command {
    val selection = SelectionBuilder()
    var workspace = false
    var toolArguments = emptyList<String>()
    while (hasNext()) {
      val flag = next()
      if (flag == "--") {
        toolArguments = passThrough()
        break
      }
      if (flag == "--workspace") {
        if (workspace) reject("--workspace is written twice")
        workspace = true
      } else if (!selection.take(flag, this)) {
        reject(
          "'$flag' is not an argument of tazel lint; options of talalint follow '--'",
          hint(flag, selectionFlags + "--workspace"),
        )
      }
    }
    val targets = selection.build()
    if (workspace && !targets.isEverything) {
      reject("--workspace lints every member; it cannot be combined with a selection of targets")
    }
    return Command.Lint(workspace, targets, toolArguments)
  }
}

private val identifier = Regex("[A-Za-z_][A-Za-z0-9_]*")

/** A target is named like the declaration it comes from: one case-sensitive identifier. */
internal fun isTargetName(text: String) = identifier.matches(text)

private fun packageCoordinate(text: String): PackageCoordinate {
  val parts = text.split('.')
  if (parts.size != 2 || parts.any { !identifier.matches(it) }) {
    reject("a package is written Publisher.Name, and '$text' is not")
  }
  return PackageCoordinate(parts[0], parts[1])
}
