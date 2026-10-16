/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.cli

import com.github.ajalt.mordant.rendering.TextColors.brightBlue
import com.github.ajalt.mordant.rendering.TextColors.brightGreen
import com.github.ajalt.mordant.rendering.TextColors.brightYellow
import com.github.ajalt.mordant.rendering.TextStyles.bold
import com.github.ajalt.mordant.terminal.Terminal
import com.progmasoft.tazel.driver.Emit
import com.progmasoft.tazel.driver.LoadedWorkspace
import com.progmasoft.tazel.driver.Processes
import com.progmasoft.tazel.driver.SelectedTargets
import com.progmasoft.tazel.driver.SourceFiles
import com.progmasoft.tazel.driver.Tool
import com.progmasoft.tazel.driver.Toolchain
import com.progmasoft.tazel.driver.UnknownTargetException
import com.progmasoft.tazel.driver.compilerArguments
import com.progmasoft.tazel.driver.displayName
import com.progmasoft.tazel.driver.executableExtension
import com.progmasoft.tazel.driver.loadWorkspace
import com.progmasoft.tazel.driver.select
import com.progmasoft.tazel.dsl.DependencyScope
import com.progmasoft.tazel.dsl.ExecutableSourceTarget
import com.progmasoft.tazel.dsl.LoadedProject
import com.progmasoft.tazel.dsl.OperatingSystem
import com.progmasoft.tazel.dsl.ProjectConfigurationException
import com.progmasoft.tazel.dsl.ProjectLoader
import com.progmasoft.tazel.dsl.coordinate
import com.progmasoft.tazel.dsl.discoverProject
import com.progmasoft.tazel.lock.LockedPlugin
import com.progmasoft.tazel.lock.LockedProject
import com.progmasoft.tazel.lock.LockfileDump
import com.progmasoft.tazel.lock.ProjectLockFile
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption.REPLACE_EXISTING

/** The exit codes of Tazel. A program run by `tazel run` hands its own code through. */
object ExitCode {
  const val SUCCESS = 0
  const val FAILURE = 1
  const val USAGE = 2
}

/** A command that stops with a message; the message is all the user needs to see. */
private class Stop(message: String) : Exception(message)

/**
 * Runs one command of Tazel.
 *
 * Tazel compiles nothing itself. It reads the project file, finds the sources and starts the
 * compiler, the formatter or the linter with the arguments the project asks for.
 */
class Tazel(
  private val terminal: Terminal,
  private val directory: Path,
  private val os: OperatingSystem,
  private val toolchain: Toolchain,
  private val processes: Processes,
  private val version: String,
) {
  private val sources = SourceFiles(ignoreCase = os == OperatingSystem.WINDOWS)

  fun run(command: Command): Int =
    try {
      when (command) {
        is Command.Check -> compile(command.targets, Emit.METADATA).let { ExitCode.SUCCESS }
        is Command.Build -> compile(command.targets, Emit.EXECUTABLE).let { ExitCode.SUCCESS }
        is Command.Run -> runPrograms(command)
        is Command.Test -> test(command.targets)
        Command.LockResolve -> lockResolve()
        is Command.LockCreateDump -> lockCreateDump(command.path)
        is Command.Fmt -> tool(Tool.TALAFMT, false, TargetSelection(), command.toolArguments)
        is Command.Lint ->
          tool(Tool.TALALINT, command.workspace, command.targets, command.toolArguments)
        Command.Version -> ExitCode.SUCCESS.also { terminal.println("tazel $version") }
        is Command.Help -> ExitCode.SUCCESS.also { terminal.println(helpText(command.topic)) }
        Command.Update,
        is Command.Install,
        Command.ViGetPush,
        Command.ViGetUpdate ->
          throw Stop(
            "tazel ${command.name.words} needs ViGet, and the ViGet client is not implemented yet"
          )
        Command.ViPkgCreate ->
          throw Stop(
            "tazel vipkg create is not implemented yet: the compiler cannot write a library, " +
              "so a .vipkg would have nothing to carry"
          )
      }
    } catch (stop: Stop) {
      fail(stop.message.orEmpty())
    } catch (unknown: UnknownTargetException) {
      fail(
        unknown.message.orEmpty(),
        unknown.names.firstNotNullOfOrNull { name ->
          closestTo(name, unknown.known)?.let { didYouMean(name, "${unknown.flag} $it") }
        },
      )
    } catch (problem: ProjectConfigurationException) {
      fail(problem.message.orEmpty())
    } catch (problem: java.sql.SQLException) {
      fail("${ProjectLockFile.FILE_NAME} could not be used: ${problem.message}")
    }

  private fun fail(
    message: String,
    hint: String? = null,
  ): Int {
    reportError(terminal, message, hint)
    return ExitCode.FAILURE
  }

  private fun status(
    verb: String,
    rest: String,
  ) = terminal.println((bold + brightGreen)(verb.padStart(STATUS_WIDTH)) + " " + rest)

  private fun warn(message: String) =
    terminal.println((bold + brightYellow)("warning") + ": " + message, stderr = true)

  private fun compilerVersion(): String =
    toolchain
      .find(Tool.TALAC)
      ?.let { processes.capture(listOf(it.toString(), "--version")) }
      ?.trim()
      ?.removePrefix("talac ")
      ?.takeIf(String::isNotBlank) ?: "unknown"

  private fun load(): LoadedWorkspace =
    loadWorkspace(ProjectLoader(compilerVersion()), discoverProject(directory))

  private fun locked(project: LoadedProject) =
    LockedProject(project.plan.dependencies, project.plan.plugins.map(LockedPlugin::of))

  /** Renews the lockfile of [project] when it no longer records what the project declares. */
  private fun keepLockCurrent(project: LoadedProject) {
    val path = project.location.root.resolve(ProjectLockFile.FILE_NAME)
    if (!ProjectLockFile.isCurrent(path, locked(project))) {
      ProjectLockFile.write(project.location.root, locked(project))
    }
  }

  /** The outputs of the executables that were compiled, in the order they were compiled. */
  private fun compile(
    selection: TargetSelection,
    emit: Emit,
  ): List<Path> {
    val workspace = load()
    val selected = select(workspace.all, selection)
    val compiler = toolchain.require(Tool.TALAC)
    val outputs = mutableListOf<Path>()
    for (targets in selected) {
      val project = targets.project
      keepLockCurrent(project)
      requireNoDependencies(project, DependencyScope.BUILD)
      refuseLibraries(targets, selection)
      for (executable in targets.executables) {
        outputs.add(compile(compiler, project, executable, emit))
      }
    }
    if (outputs.isEmpty()) throw Stop("the selection holds no executable to compile")
    status("Finished", if (emit == Emit.METADATA) "check" else "build")
    return outputs
  }

  private fun compile(
    compiler: Path,
    project: LoadedProject,
    target: ExecutableSourceTarget,
    emit: Emit,
  ): Path {
    val root = project.location.root
    val inputs =
      sources.discover(
        root,
        target.srcDir,
        target.exclude.orEmpty(),
        "the srcDir of executable '${target.name}'",
      )
    if (inputs.isEmpty()) {
      throw Stop("executable '${target.name}' has no .tala source in ${target.srcDir}")
    }
    val extension = emit.extension ?: executableExtension(os)
    status(
      if (emit == Emit.METADATA) "Checking" else "Compiling",
      "${target.name} " + brightBlue("(${project.displayName}, ${inputs.size} sources)"),
    )
    val arguments = compilerArguments(project.plan.compiler, target.entry, emit, inputs)
    val exitCode = processes.run(listOf(compiler.toString()) + arguments, root)
    if (exitCode != 0)
      throw Stop("talac rejected executable '${target.name}' (exit code $exitCode)")
    // The compiler writes beside its first input, under that input's name; the project decides
    // where artifacts live and what they are called, so the file is moved there.
    val written = root.resolve(inputs.first().removeSuffix(".tala") + extension)
    if (!Files.isRegularFile(written)) {
      throw Stop("talac reported success and left no $written")
    }
    val output = root.resolve(project.plan.outputDirectory).resolve(target.name + extension)
    Files.createDirectories(output.parent)
    Files.move(written, output, REPLACE_EXISTING)
    return output
  }

  private fun requireNoDependencies(
    project: LoadedProject,
    scope: DependencyScope,
  ) {
    val dependencies = project.plan.dependencies
    val names =
      dependencies.declarations.filter { it.scope == scope }.map { it.dependency.coordinate } +
        dependencies.local.filter { it.scope == scope }.map { it.path }
    if (names.isNotEmpty()) {
      throw Stop(
        "${project.displayName} depends on ${names.joinToString()}, and Tazel cannot hand a " +
          "dependency to the compiler yet"
      )
    }
  }

  private fun refuseLibraries(
    targets: SelectedTargets,
    selection: TargetSelection,
  ) {
    if (targets.libraries.isEmpty()) return
    val names = targets.libraries.joinToString { "'${it.name}'" }
    val reason = "the compiler cannot write a library yet"
    // A library that was asked for by name is the point of the command; one that merely sits in
    // the project beside an executable is passed over, and said so.
    if (selection.libraries.isNotEmpty() || targets.executables.isEmpty()) {
      throw Stop("library $names cannot be compiled: $reason")
    }
    warn("library $names is skipped: $reason")
  }

  private fun runPrograms(command: Command.Run): Int {
    val programs = compile(command.targets, Emit.EXECUTABLE)
    for (program in programs) {
      status("Running", program.toString())
      val exitCode = processes.run(listOf(program.toString()) + command.programArguments, directory)
      if (exitCode != 0) return exitCode
    }
    return ExitCode.SUCCESS
  }

  private fun test(selection: TargetSelection): Int {
    val workspace = load()
    val suites =
      select(workspace.all, selection).flatMap { targets ->
        targets.project.plan.testSuites.map { "${targets.project.displayName}.${it.name}" }
      }
    if (suites.isEmpty()) {
      status("Finished", "test: the selection declares no test suite")
      return ExitCode.SUCCESS
    }
    throw Stop(
      "test suites cannot run yet: Tala has no test framework to run " + suites.joinToString()
    )
  }

  private fun lockResolve(): Int {
    val workspace = load()
    for (project in listOf(workspace.root) + workspace.members) {
      ProjectLockFile.write(project.location.root, locked(project))
      status("Locked", project.location.root.resolve(ProjectLockFile.FILE_NAME).toString())
    }
    return ExitCode.SUCCESS
  }

  /**
   * Writes the lockfile as text: to [path], resolved against the directory Tazel runs in, or to
   * LOCK.dump beside the project file. The folder of the file has to exist; Tazel does not create
   * it, so a mistyped folder fails instead of leaving a dump somewhere unexpected.
   */
  private fun lockCreateDump(path: String?): Int {
    val root = discoverProject(directory).root
    val lockfile = root.resolve(ProjectLockFile.FILE_NAME)
    if (!Files.isRegularFile(lockfile)) {
      throw Stop("$lockfile does not exist; write it with tazel lock resolve")
    }
    val dump =
      if (path == null) root.resolve(ProjectLockFile.DUMP_FILE_NAME)
      else directory.resolve(path).toAbsolutePath().normalize()
    if (Files.isDirectory(dump)) {
      throw Stop("$dump is a folder; --path names the file to write, such as $dump/LOCK.dump")
    }
    val folder = dump.parent
    if (folder == null || !Files.isDirectory(folder)) {
      throw Stop("the folder $folder does not exist; create it first, Tazel does not make folders")
    }
    LockfileDump.write(lockfile, dump)
    status("Dumped", dump.toString())
    return ExitCode.SUCCESS
  }

  /** Starts the formatter or the linter once per ViPkg, on every source the ViPkg owns. */
  private fun tool(
    tool: Tool,
    wholeWorkspace: Boolean,
    selection: TargetSelection,
    toolArguments: List<String>,
  ): Int {
    val workspace = load()
    val projects =
      if (wholeWorkspace || !selection.isEverything) workspace.all else workspace.default
    val selected = select(projects, selection)
    val program = toolchain.require(tool)
    var result = ExitCode.SUCCESS
    for (targets in selected) {
      val files = sourcesOf(targets, includeTests = selection.isEverything)
      if (files.isEmpty()) continue
      status(
        if (tool == Tool.TALAFMT) "Formatting" else "Linting",
        "${targets.project.displayName} " + brightBlue("(${files.size} sources)"),
      )
      val exitCode =
        processes.run(
          listOf(program.toString()) + toolArguments + "--" + files,
          targets.project.location.root,
        )
      if (exitCode != 0) result = exitCode
    }
    return result
  }

  private fun sourcesOf(
    targets: SelectedTargets,
    includeTests: Boolean,
  ): List<String> {
    val root = targets.project.location.root
    val files = sortedSetOf<String>()
    targets.executables.forEach {
      files += sources.discover(root, it.srcDir, it.exclude.orEmpty(), "executable '${it.name}'")
    }
    targets.libraries.forEach {
      files += sources.discover(root, it.srcDir, it.exclude.orEmpty(), "library '${it.name}'")
    }
    if (includeTests) {
      targets.project.plan.testSuites
        .filter { Files.isDirectory(root.resolve(it.testDir)) }
        .forEach {
          files += sources.discover(root, it.testDir, it.exclude.orEmpty(), "test '${it.name}'")
        }
    }
    return files.toList()
  }

  private companion object {
    const val STATUS_WIDTH = 12
  }
}
