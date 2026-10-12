/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.driver

import com.progmasoft.tazel.dsl.BuildMode
import com.progmasoft.tazel.dsl.CompilerSettings
import com.progmasoft.tazel.dsl.LlvmLto
import com.progmasoft.tazel.dsl.OperatingSystem
import com.progmasoft.tazel.dsl.OptLevel
import com.progmasoft.tazel.dsl.ProjectConfigurationException
import com.progmasoft.tazel.dsl.Warnings
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SourceFilesTest {
  private val exact = SourceFiles(ignoreCase = false)

  private fun inTree(
    vararg files: String,
    block: (Path) -> Unit,
  ) {
    val root = Files.createTempDirectory("tazel-sources-").toRealPath()
    try {
      files.forEach { file ->
        val path = root.resolve(file)
        Files.createDirectories(path.parent)
        Files.writeString(path, "")
      }
      block(root)
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun globsStayInsideSegmentsUnlessTheyAreDoubleStars() {
    assertTrue(exact.matches("Sources/**/*.tala", "Sources/Main.tala"))
    assertTrue(exact.matches("Sources/**/*.tala", "Sources/Talac/Parser.tala"))
    assertTrue(exact.matches("Sources/Generated/**", "Sources/Generated/Nested/File.tala"))
    assertTrue(exact.matches("Sources/?ain.tala", "Sources/Main.tala"))
    assertTrue(exact.matches("./Sources\\*.tala", "Sources/Main.tala"))
    assertFalse(exact.matches("Sources/*.tala", "Sources/Nested/Main.tala"))
    assertFalse(exact.matches("Tests/**", "Sources/Tests/Main.tala"))
    assertFalse(exact.matches("Sources/Main.tala", "Sources/main.tala"))
    assertTrue(SourceFiles(ignoreCase = true).matches("Sources/Main.tala", "Sources/main.tala"))
  }

  @Test
  fun findsSourcesInAStableOrderAndLeavesOtherFilesAlone() =
    inTree(
      "Sources/Zeta.tala",
      "Sources/Alpha.tala",
      "Sources/Nested/Deep/Unit.tala",
      "Sources/Notes.txt",
      "Sources/Old.TALA",
      "Elsewhere/Outside.tala",
    ) { root ->
      assertEquals(
        listOf("Sources/Alpha.tala", "Sources/Nested/Deep/Unit.tala", "Sources/Zeta.tala"),
        exact.discover(root, "Sources", emptyList(), "srcDir"),
      )
    }

  @Test
  fun exclusionsPruneFilesAndWholeDirectories() =
    inTree(
      "Sources/Main.tala",
      "Sources/Generated/A.tala",
      "Sources/Generated/Deep/B.tala",
      "Sources/Tests/C.tala",
      "Sources/Draft.tala",
    ) { root ->
      assertEquals(
        listOf("Sources/Main.tala"),
        exact.discover(
          root,
          "Sources",
          listOf("Sources/Generated", "Sources/Tests/**", "Sources/Dr*.tala"),
          "srcDir",
        ),
      )
    }

  @Test
  fun rejectsADirectoryThatIsMissingOrOutsideTheProject() =
    inTree("Sources/Main.tala") { root ->
      assertFailsWith<ProjectConfigurationException> {
        exact.discover(root, "Missing", emptyList(), "srcDir")
      }
      assertFailsWith<ProjectConfigurationException> {
        exact.discover(root, "../", emptyList(), "srcDir")
      }
    }

  @Test
  fun writesEverySettingOfTheProjectOntoTheCompilerLine() {
    assertEquals(
      listOf(
        "--entry=Demo.Program",
        "--emit=executable",
        "--standard=26",
        "--codegen-backend=llvm",
        "--warnings=medium",
        "--warnings-as-errors=false",
        "--opt-level=0",
        "--xpp-optimization-passes=true",
        "--xmm-optimization-passes=true",
        "--llvm-compiler=aot",
        "--llvm-lto=none",
        "--",
        "Sources/Main.tala",
      ),
      compilerArguments(
        CompilerSettings(),
        "Demo.Program",
        Emit.EXECUTABLE,
        listOf("Sources/Main.tala"),
      ),
    )
    val tuned =
      CompilerSettings(
        buildMode = BuildMode.RELEASE,
        warnings = Warnings.ALL,
        warningsAsErrors = true,
        shadowWarnings = true,
        xmmOptimizationPasses = false,
        llvmLto = LlvmLto.THIN,
        llvmArguments = listOf("-time-passes", "-print-after-all"),
      )
    val arguments = compilerArguments(tuned, "Demo.Program", Emit.METADATA, listOf("A.tala"))
    assertTrue(
      arguments.containsAll(
        listOf(
          "--emit=metadata",
          "--warnings=all",
          "--warnings=shadow",
          "--warnings-as-errors=true",
          "--opt-level=3",
          "--xmm-optimization-passes=false",
          "--llvm-lto=thin",
          "--llvm-args=-time-passes,-print-after-all",
        )
      )
    )
    assertEquals(
      "--opt-level=g",
      compilerArguments(CompilerSettings(optLevel = OptLevel.OG), "A.B", Emit.METADATA, emptyList())
        .single { it.startsWith("--opt-level") },
    )
  }

  @Test
  fun findsAToolByItsVariableThenItsInstallationThenThePath() =
    inTree("home/bin/talac", "elsewhere/talac", "elsewhere/talafmt", "custom/my-talac") { root ->
      val path = root.resolve("elsewhere").toString()
      val installed = Toolchain(OperatingSystem.LINUX, mapOf("PATH" to path), root.resolve("home"))
      assertEquals(root.resolve("home/bin/talac"), installed.find(Tool.TALAC))
      assertEquals(root.resolve("elsewhere/talafmt"), installed.find(Tool.TALAFMT))
      assertNull(installed.find(Tool.TALALINT))
      assertTrue(
        assertFailsWith<ProjectConfigurationException> { installed.require(Tool.TALALINT) }
          .message
          .orEmpty()
          .contains("TAZEL_TALALINT")
      )

      val custom = root.resolve("custom/my-talac").toString()
      val configured =
        Toolchain(OperatingSystem.LINUX, mapOf("TAZEL_TALAC" to custom), root.resolve("home"))
      assertEquals(Path.of(custom), configured.find(Tool.TALAC))
      val broken = Toolchain(OperatingSystem.LINUX, mapOf("TAZEL_TALAC" to "$custom-absent"), null)
      assertNull(broken.find(Tool.TALAC))

      assertNull(Toolchain(OperatingSystem.WINDOWS, mapOf("Path" to path), null).find(Tool.TALAC))
      assertEquals(".exe", executableExtension(OperatingSystem.WINDOWS))
      assertEquals("", executableExtension(OperatingSystem.MACOS))
    }
}
