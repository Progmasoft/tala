/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.cli

import com.github.ajalt.mordant.rendering.AnsiLevel
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
  private class Fixture(
    val root: Path,
    val recorder: TerminalRecorder = TerminalRecorder(),
  ) : Processes {
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

  private fun fixture(
    recorder: TerminalRecorder = TerminalRecorder(),
    block: Fixture.() -> Unit,
  ) {
    val root = Files.createTempDirectory("tazel-command-").toRealPath()
    try {
      Fixture(root, recorder).block()
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
    assertEquals(ExitCode.FAILURE, run("build", "-p", "Kti"))
    assertTrue(recorder.stderr().contains("did you mean --vipkg Kit?"))
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
  fun aDumpGoesToTheFileThatPathNamesInAFolderThatExists() = fixture {
    demo()
    assertEquals(ExitCode.SUCCESS, run("lock", "resolve"))

    assertEquals(ExitCode.SUCCESS, run("lock", "create-dump", "--path", "Locks.txt"))
    assertTrue(root.resolve("Locks.txt").readText().contains("BEGIN TRANSACTION;"))

    write("dumps/.keep")
    assertEquals(ExitCode.SUCCESS, run("lock", "create-dump", "--path", "dumps/Locks.sql"))
    assertTrue(root.resolve("dumps/Locks.sql").readText().contains("COMMIT;"))

    assertEquals(ExitCode.FAILURE, run("lock", "create-dump", "--path", "missing/Locks.sql"))
    assertTrue(recorder.stderr().contains("does not exist"))
    assertTrue(Files.notExists(root.resolve("missing")))

    assertEquals(ExitCode.FAILURE, run("lock", "create-dump", "--path", "dumps"))
    assertTrue(recorder.stderr().contains("is a folder"))
  }

  @Test
  fun aDumpNeedsALockfile() = fixture {
    demo()
    assertEquals(ExitCode.FAILURE, run("lock", "create-dump"))
    assertTrue(recorder.stderr().contains("tazel lock resolve"))
  }

  private fun Fixture.graphDemo() =
    write(
      "BUILD.kts",
      """
        project {
          name = "Demo"
          defaultFeatures("Json")
        }
        sources { executable { entry = "Demo.Program" } }
        dependencies {
          dependency("Publisher") {
            name = "Name"
            version = "1.0.0"
          }
          dependency("Publisher") {
            name = "Json"
            version = "1.1.0"
            feature = "Json"
          }
          dependency("Publisher") {
            name = "Toml"
            version = "2.0.0"
            stability = Stability.BETA
            feature = "Toml"
            defaultFeatures = false
            feature("Inline") { enabled = true }
          }
          localDependency { path = "Local.vipkg" }
          testDependency("Publisher") {
            name = "Name"
            version = "2.0.0"
          }
        }
        """,
    )

  /** What the last command printed on standard output after [before] characters. */
  private fun Fixture.printedSince(before: Int) =
    recorder.stdout().substring(before).replace(Regex("\u001B\\[[0-9;]*m"), "").trimEnd()

  @Test
  fun aGraphShowsTheDependenciesWithTheFeaturesThatAreOn() = fixture {
    graphDemo()
    assertEquals(ExitCode.SUCCESS, run("lock", "graph"))
    assertTrue(Files.isRegularFile(root.resolve(ProjectLockFile.FILE_NAME)))
    assertTrue(recorder.stderr().contains("Locked"))
    assertEquals(
      """
      Demo
      ├── Publisher.Json 1.1.0 [by feature Json]
      ├── Publisher.Name 1.0.0
      ├── Local.vipkg (local)
      └── [test]
          └── Publisher.Name 2.0.0
      """
        .trimIndent(),
      printedSince(0),
    )

    var before = recorder.stdout().length
    assertEquals(ExitCode.SUCCESS, run("lock", "graph", "--all-features"))
    assertTrue(
      printedSince(before)
        .contains(
          "├── Publisher.Toml 2.0.0 (beta) [features: Inline; no default features; by feature Toml]"
        )
    )

    before = recorder.stdout().length
    assertEquals(ExitCode.SUCCESS, run("lock", "graph", "--depth", "0"))
    assertEquals("Demo", printedSince(before))
  }

  @Test
  fun aGraphInvertedOrOfDuplicatesShowsWhoDependsOnAPackage() = fixture {
    graphDemo()
    val expected =
      """
      Publisher.Name 1.0.0
      └── Demo

      Publisher.Name 2.0.0
      └── Demo [test]
      """
        .trimIndent()
    assertEquals(ExitCode.SUCCESS, run("lock", "graph", "-i", "Publisher.Name"))
    assertEquals(expected, printedSince(0))

    var before = recorder.stdout().length
    assertEquals(ExitCode.SUCCESS, run("lock", "graph", "--duplicates"))
    assertEquals(expected, printedSince(before))

    before = recorder.stdout().length
    assertEquals(ExitCode.SUCCESS, run("lock", "graph", "--invert", "Local.vipkg"))
    assertEquals("Local.vipkg (local)\n└── Demo", printedSince(before))

    assertEquals(ExitCode.FAILURE, run("lock", "graph", "-i", "Publisher.Nmae"))
    assertTrue(recorder.stderr().contains("no project here depends on Publisher.Nmae"))
    assertTrue(recorder.stderr().contains("did you mean --invert Publisher.Name?"))
  }

  @Test
  fun aGraphInvertedByProjectNameLooksForTheProjectBelowTheDirectory() = fixture {
    write(
      "Libraries/Lib/BUILD.kts",
      """
      project {
        name = "MyPackage"
        version = "1.2.0"
      }
      sources { library { namespace = "MyPackage" } }
      """,
    )
    // Not a valid project file: were the folder looked into, the command would fail.
    write(".hidden/BUILD.kts", "project { name = \"MyPackage\" }")
    demo(
      "App",
      "App",
      """
      dependencies {
        dependency("Publisher") {
          name = "MyPackage"
          version = "1.2.0"
        }
      }
      """,
    )
    demo(
      "Tool",
      "Tool",
      "dependencies { localTestDependency { path = \"Vendor/MyPackage.vipkg\" } }",
    )

    assertEquals(ExitCode.SUCCESS, run("lock", "graph", "-i", "MyPackage"), recorder.stderr())
    assertEquals(
      """
      MyPackage 1.2.0 (Libraries/Lib)
      ├── App as Publisher.MyPackage 1.2.0
      └── Tool as Vendor/MyPackage.vipkg (local) [test]
      """
        .trimIndent(),
      printedSince(0),
    )

    assertEquals(ExitCode.FAILURE, run("lock", "graph", "-i", "MyPakcage"))
    assertTrue(recorder.stderr().contains("has the name MyPakcage"))
    assertTrue(recorder.stderr().contains("did you mean --invert MyPackage?"))
  }

  @Test
  fun aLockedGraphLeavesTheLockfileAsItIs() = fixture {
    graphDemo()
    assertEquals(ExitCode.FAILURE, run("lock", "graph", "--locked"))
    assertTrue(recorder.stderr().contains("does not exist, and --locked leaves it as it is"))
    assertTrue(Files.notExists(root.resolve(ProjectLockFile.FILE_NAME)))

    assertEquals(ExitCode.SUCCESS, run("lock", "resolve"))
    val lockfile = root.resolve(ProjectLockFile.FILE_NAME)
    val written = Files.getLastModifiedTime(lockfile)
    assertEquals(ExitCode.SUCCESS, run("lock", "graph", "--locked"))
    assertEquals(written, Files.getLastModifiedTime(lockfile))

    demo()
    assertEquals(ExitCode.FAILURE, run("lock", "graph", "--locked"))
    assertTrue(recorder.stderr().contains("does not record what the project declares"))
  }

  @Test
  fun aGraphOfAWorkspaceHasARootForEveryMember() = fixture {
    write("BUILD.kts", "workspace { members(\"Server\", \"Client\") }")
    demo(
      "Server",
      "Server",
      """
      dependencies {
        dependency("Publisher") {
          name = "Name"
          version = "1.0.0"
        }
      }
      """,
    )
    demo(
      "Client",
      "Client",
      """
      dependencies {
        dependency("Publisher") {
          name = "Name"
          version = "1.2.0"
        }
        dependency("Publisher") {
          name = "Other"
          version = "1.0.0"
        }
      }
      """,
    )
    assertEquals(ExitCode.SUCCESS, run("lock", "graph"))
    assertEquals(
      "Server\n└── Publisher.Name 1.0.0\n\nClient\n├── Publisher.Name 1.2.0\n└── Publisher.Other 1.0.0",
      printedSince(0),
    )
    val before = recorder.stdout().length
    assertEquals(ExitCode.SUCCESS, run("lock", "graph", "-d"))
    assertEquals(
      "Publisher.Name 1.0.0\n└── Server\n\nPublisher.Name 1.2.0\n└── Client",
      printedSince(before),
    )
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
  fun aProgressBarIsDrawnOnlyWhereTheTerminalCanShowOne() {
    val interactive =
      TerminalRecorder(
        ansiLevel = AnsiLevel.TRUECOLOR,
        outputInteractive = true,
        inputInteractive = true,
        supportsAnsiCursor = true,
      )
    StepProgress.start(Terminal(terminalInterface = interactive), "Building", 3).use {
      assertTrue(it.drawing)
      it.working("Demo")
      it.done()
    }
    StepProgress.start(Terminal(terminalInterface = TerminalRecorder()), "Building", 3).use {
      assertFalse(it.drawing)
    }
    StepProgress.start(Terminal(terminalInterface = interactive), "Building", 0).use {
      assertFalse(it.drawing)
    }
  }

  @Test
  fun anInteractiveBuildStillEndsWithTimedStatusLines() =
    fixture(
      TerminalRecorder(
        ansiLevel = AnsiLevel.TRUECOLOR,
        outputInteractive = true,
        inputInteractive = true,
        supportsAnsiCursor = true,
      )
    ) {
      demo()
      write("Sources/Main.tala")
      assertEquals(ExitCode.SUCCESS, run("build"))
      assertTrue(recorder.stdout().contains("Compiling"))
      assertTrue(Regex("""Finished.*build.*in \d+\.\d\ds""").containsMatchIn(recorder.stdout()))
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
