/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.cli

import com.github.ajalt.mordant.terminal.Terminal
import com.github.ajalt.mordant.terminal.TerminalRecorder
import com.progmasoft.tazel.driver.Processes
import com.progmasoft.tazel.driver.Toolchain
import com.progmasoft.tazel.dsl.OperatingSystem
import com.progmasoft.tazel.lock.ProjectLockFile
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Runs whole commands against projects on disk. The tools are stand-ins: they record the command
 * line they were started with and leave the file the real tool would leave.
 */
class TazelTest {
  private class Fixture(val root: Path) : Processes {
    val recorder = TerminalRecorder()
    val commands = mutableListOf<Pair<List<String>, Path>>()
    var compilerExitCode = 0
    var programExitCode = 0

    init {
      listOf("talac", "talafmt", "talalint").forEach { tool ->
        Files.createDirectories(root.resolve("tools"))
        Files.writeString(root.resolve("tools/$tool"), "")
      }
    }

    fun write(
      file: String,
      text: String = "",
    ) {
      val path = root.resolve(file)
      Files.createDirectories(path.parent)
      Files.writeString(path, text.trimIndent())
    }

    fun tazel(directory: String = "."): Tazel =
      Tazel(
        Terminal(terminalInterface = recorder),
        root.resolve(directory).normalize(),
        OperatingSystem.LINUX,
        Toolchain(OperatingSystem.LINUX, mapOf("PATH" to root.resolve("tools").toString()), null),
        this,
        "1.2.3",
      )

    fun run(
      vararg arguments: String,
      directory: String = ".",
    ): Int {
      val parsed = parseCommandLine(arguments.toList())
      check(parsed is ParseResult.Parsed) { "not a command line: ${arguments.toList()}" }
      return tazel(directory).run(parsed.command)
    }

    /** The recorded command lines of one tool, without the path of the tool. */
    fun callsOf(tool: String) =
      commands.map { it.first }.filter { it.first().endsWith(tool) }.map { it.drop(1) }

    override fun run(
      command: List<String>,
      directory: Path,
    ): Int {
      commands += command to directory
      if (!command.first().endsWith("talac")) {
        return if (command.first().contains("tools")) 0 else programExitCode
      }
      if (compilerExitCode != 0) return compilerExitCode
      val first = command[command.indexOf("--") + 1].removeSuffix(".tala")
      val extension = if ("--emit=metadata" in command) ".talameta" else ""
      Files.writeString(directory.resolve(first + extension), "artifact of $first")
      return 0
    }

    override fun capture(command: List<String>) = "talac 0.5.2\n"
  }

  private fun fixture(block: Fixture.() -> Unit) {
    val root = Files.createTempDirectory("tazel-command-").toRealPath()
    try {
      Fixture(root).block()
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  private fun Fixture.demo(directory: String = ".", name: String = "Demo", extra: String = "") {
    write(
      "$directory/BUILD.kts",
      """
      project { name = "$name" }
      sources {
        executable {
          entry = "$name.Program"
          exclude("Sources/Generated")
        }
      }
      $extra
      """,
    )
    write("$directory/Sources/Main.tala")
    write("$directory/Sources/Helper.tala")
    write("$directory/Sources/Generated/Skipped.tala")
  }

  @Test
  fun buildsAnExecutableIntoTheOutputDirectoryOfTheProject() = fixture {
    demo()

    assertEquals(ExitCode.SUCCESS, run("build"))

    val call = callsOf("talac").single()
    assertEquals(listOf("Sources/Helper.tala", "Sources/Main.tala"), call.takeLast(2))
    assertTrue(call.containsAll(listOf("--entry=Demo.Program", "--emit=executable", "--")))
    assertEquals(root, commands.single().second)
    assertEquals("artifact of Sources/Helper", root.resolve("build/debug/Demo").readText())
    assertFalse(Files.exists(root.resolve("Sources/Helper")))
    assertTrue(Files.isRegularFile(root.resolve(ProjectLockFile.FILE_NAME)))
    assertTrue(recorder.stdout().contains("Compiling"))
  }

  @Test
  fun checksWithTheMetadataEmitAndTheCompilerOptionsOfTheProject() = fixture {
    demo(
      extra =
        """
        compiler {
          buildMode = BuildMode.RELEASE
          warnings = Warnings.ALL
          werror = true
        }
        outdirs { release = "out" }
        check(compiler.version == "0.5.2")
        """
    )

    assertEquals(ExitCode.SUCCESS, run("check", directory = "Sources"))

    val call = callsOf("talac").single()
    assertTrue(
      call.containsAll(
        listOf("--emit=metadata", "--warnings=all", "--warnings-as-errors=true", "--opt-level=3")
      )
    )
    assertTrue(Files.isRegularFile(root.resolve("out/Demo.talameta")))
  }

  @Test
  fun runsWhatItBuiltAndHandsTheExitCodeThrough() = fixture {
    demo()
    programExitCode = 7

    assertEquals(7, run("run", "--", "--flag", "value", directory = "Sources"))

    val program = commands.last()
    assertEquals(
      listOf(root.resolve("build/debug/Demo").toString(), "--flag", "value"),
      program.first,
    )
    assertEquals(root.resolve("Sources"), program.second)
  }

  @Test
  fun aRejectedProgramFailsTheCommandAndLeavesNoArtifact() = fixture {
    demo()
    compilerExitCode = 1

    assertEquals(ExitCode.FAILURE, run("build"))
    assertTrue(recorder.stderr().contains("talac rejected executable 'Demo'"))
    assertFalse(Files.exists(root.resolve("build")))
  }

  @Test
  fun reportsAProjectFileThatIsWrongOrMissing() = fixture {
    assertEquals(ExitCode.FAILURE, run("build"))
    assertTrue(recorder.stderr().contains("no project file found"))

    write("BUILD.kts", "sources { executable { entry = \"Unqualified\" } }")
    assertEquals(ExitCode.FAILURE, run("check"))
    assertTrue(recorder.stderr().contains("sources.executable.name is required"))
  }

  @Test
  fun refusesWhatTheCompilerCannotDoYet() = fixture {
    write(
      "BUILD.kts",
      """
      project { name = "Kit" }
      sources {
        executable { entry = "Kit.Program" }
        library { name = "Core" }
        test("Unit") {}
      }
      """,
    )
    write("Sources/Main.tala")

    assertEquals(ExitCode.SUCCESS, run("build"))
    assertTrue(recorder.stderr().contains("library 'Core' is skipped"))
    assertEquals(ExitCode.FAILURE, run("build", "--library", "Core"))
    assertTrue(recorder.stderr().contains("library 'Core' cannot be compiled"))
    assertEquals(ExitCode.FAILURE, run("build", "-e", "Absent"))
    assertTrue(recorder.stderr().contains("no executable is named Absent"))
    assertEquals(ExitCode.FAILURE, run("build", "-p", "Absent"))
    assertTrue(recorder.stderr().contains("no ViPkg is named Absent"))
    assertEquals(ExitCode.FAILURE, run("test"))
    assertTrue(recorder.stderr().contains("Kit.Unit"))

    listOf(
        listOf("update"),
        listOf("install", "Publisher.Name"),
        listOf("viget", "push"),
        listOf("viget", "update"),
        listOf("vipkg", "create"),
      )
      .forEach { assertEquals(ExitCode.FAILURE, run(*it.toTypedArray())) }
    assertTrue(recorder.stderr().contains("tazel viget push needs ViGet"))
  }

  @Test
  fun refusesToBuildAProjectWhoseDependenciesItCannotProvide() = fixture {
    demo(
      extra =
        """
        dependencies {
          dependency("Publisher") {
            name = "Name"
            version = "1.0.0"
          }
        }
        """
    )

    assertEquals(ExitCode.FAILURE, run("build"))
    assertTrue(recorder.stderr().contains("depends on Publisher.Name"))
    assertTrue(callsOf("talac").isEmpty())

    assertEquals(ExitCode.SUCCESS, run("lock", "resolve"))
    assertEquals(ExitCode.SUCCESS, run("lock", "create-dump"))
    assertTrue(root.resolve("LOCK.dump").readText().contains("'Publisher.Name','BUILD'"))
  }

  @Test
  fun aDumpNeedsALockfile() = fixture {
    demo()
    assertEquals(ExitCode.FAILURE, run("lock", "create-dump"))
    assertTrue(recorder.stderr().contains("tazel lock resolve"))
  }

  @Test
  fun aTestCommandWithoutSuitesSucceeds() = fixture {
    demo()
    assertEquals(ExitCode.SUCCESS, run("test"))
  }

  @Test
  fun handsToolArgumentsAndSourcesToTheFormatterAndTheLinter() = fixture {
    demo()
    write("Tests/Unit/Case.tala")
    write(
      "BUILD.kts",
      """
      project { name = "Demo" }
      sources {
        executable { entry = "Demo.Program" }
        test("Unit") {}
      }
      """,
    )

    assertEquals(ExitCode.SUCCESS, run("fmt", "--", "--check"))
    assertEquals(
      listOf(
        "--check",
        "--",
        "Sources/Generated/Skipped.tala",
        "Sources/Helper.tala",
        "Sources/Main.tala",
        "Tests/Unit/Case.tala",
      ),
      callsOf("talafmt").single(),
    )

    assertEquals(ExitCode.SUCCESS, run("lint", "-e", "Demo", "--", "--fix"))
    assertEquals(
      listOf(
        "--fix",
        "--",
        "Sources/Generated/Skipped.tala",
        "Sources/Helper.tala",
        "Sources/Main.tala",
      ),
      callsOf("talalint").single(),
    )
  }

  @Test
  fun aWorkspaceBuildsEveryMemberAndLintsItsDefaultOnes() = fixture {
    write(
      "BUILD.kts",
      """
      workspace {
        members("Server", "./Client", "Old")
        defaultMembers("Client")
        exclude("Old")
      }
      """,
    )
    demo("Server", "Server")
    demo("Client", "Client")

    assertEquals(ExitCode.SUCCESS, run("build"))
    assertEquals(
      listOf("--entry=Server.Program", "--entry=Client.Program"),
      callsOf("talac").map { it.first() },
    )
    assertTrue(Files.isRegularFile(root.resolve("Client/build/debug/Client")))

    assertEquals(ExitCode.SUCCESS, run("build", "--vipkg", "Server"))
    assertEquals(3, callsOf("talac").size)

    assertEquals(ExitCode.SUCCESS, run("lint"))
    assertEquals(listOf(root.resolve("Client")), commands.takeLast(1).map { it.second })
    assertEquals(ExitCode.SUCCESS, run("lint", "--workspace"))
    assertEquals(3, callsOf("talalint").size)

    // Inside a member, the member is the project.
    assertEquals(ExitCode.SUCCESS, run("check", directory = "Server/Sources"))
    assertEquals("--entry=Server.Program", callsOf("talac").last().first())
  }

  @Test
  fun aWorkspaceMemberNeedsAProjectFile() = fixture {
    write("BUILD.kts", "workspace { members(\"Missing\") }")
    assertEquals(ExitCode.FAILURE, run("build"))
    assertTrue(recorder.stderr().contains("workspace member 'Missing' has no project file"))
  }

  @Test
  fun printsItsVersionAndItsHelp() = fixture {
    assertEquals(ExitCode.SUCCESS, run("version"))
    assertTrue(recorder.stdout().contains("tazel 1.2.3"))
    assertEquals(ExitCode.SUCCESS, run("help"))
    assertTrue(CommandName.entries.all { recorder.stdout().contains(it.words) })
    assertEquals(ExitCode.SUCCESS, run("help", "lint"))
    assertTrue(recorder.stdout().contains("usage: tazel lint [--workspace | selection]"))
    assertTrue(helpText(CommandName.BUILD).contains("--executable, -e Name"))
    assertFalse(helpText(CommandName.VERSION).contains("selection"))
    assertEquals("development", tazelVersion())
  }
}
