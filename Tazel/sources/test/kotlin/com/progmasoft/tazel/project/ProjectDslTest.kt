/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.io.ByteArrayOutputStream
import java.io.PrintStream
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class ProjectDslTest {
  @BeforeTest
  fun resetRuntime() {
    ProjectRuntime.reset()
  }

  @AfterTest
  fun clearProperties() {
    System.clearProperty("talac.project.root")
    System.clearProperty("talac.project.output")
    System.clearProperty("talac.project.sources")
  }

  @Test
  fun acceptsAnyNamespaceQualifiedEntryClassName() {
    sources {
      executable { entry = "Demo.Main" }
    }
    val plan = ProjectRuntime.build()

    assertNull(plan.identity)
    assertEquals(listOf("Sources"), plan.executables.map { it.srcDir })
    assertEquals("Demo.Main", plan.executables.single().entry)
    assertEquals(BuildMode.DEBUG, plan.compiler.buildMode)
    assertEquals(LlvmOptLevel.O0, effectiveOptLevel(plan.compiler))
    assertTrue(plan.compiler.xppOptimizationPasses)
    assertTrue(plan.compiler.xmmOptimizationPasses)

    listOf("Namespace.Program", "Namespace.Namespace.Program", "Company.Tool.Bootstrap").forEach {
      entry ->
      ProjectRuntime.reset()
      sources { executable { this.entry = entry } }
      assertEquals(entry, ProjectRuntime.build().executables.single().entry)
    }
  }

  @Test
  fun modelsExecutableEntryAndLibraryNamespaceSeparately() {
    project { name = "Artifacts" }
    sources {
      executable {
        name = "Tool"
        entry = "Artifacts.Program"
      }
      library {
        name = "Runtime"
        namespace = "Artifacts.Runtime"
        viPkgType(ViPkgType.TALALIB, ViPkgType.STATICLIB)
      }
    }

    val plan = ProjectRuntime.build()
    assertEquals("Artifacts.Program", plan.executables.single().entry)
    assertEquals("Artifacts.Runtime", plan.libraries.single().namespace)
    assertEquals(
      listOf(ViPkgType.TALALIB, ViPkgType.STATICLIB),
      plan.libraries.single().viPkgTypes,
    )
    assertFalse(PlanWriter.write(plan).contains("\"emit\""))
  }

  @Test
  fun permitsAnyProjectFieldSubsetWhenPublishingIsDisabled() {
    project { name = "PrivateCompiler" }
    sources { executable { entry = "PrivateCompiler.Main" } }

    val plan = ProjectRuntime.build()
    assertEquals(ProjectIdentity("PrivateCompiler", null, null), plan.identity)

    val projectDocument =
      Json.parseToJsonElement(PlanWriter.write(plan)).jsonObject.getValue("project").jsonObject
    assertEquals("PrivateCompiler", projectDocument.getValue("name").jsonPrimitive.content)
    assertEquals("null", projectDocument.getValue("version").toString())
    assertEquals("null", projectDocument.getValue("stability").toString())

    ProjectRuntime.reset()
    project {
      version = "0.3.1"
      stability = Stability.DEV
    }
    sources { executable { entry = "Internal.Tool" } }
    assertEquals(ProjectIdentity(null, "DEV", "0.3.1"), ProjectRuntime.build().identity)
  }

  @Test
  fun requiresEveryProjectFieldWhenPublishingIsEnabled() {
    fun rejectionFor(block: ProjectScope.() -> Unit): ProjectConfigurationException {
      ProjectRuntime.reset()
      project(block)
      sources {
        viget { push = true }
        executable { entry = "Published.Main" }
      }
      return assertFailsWith { ProjectRuntime.build() }
    }

    assertTrue(
      rejectionFor {}.message.orEmpty().contains("name, version, stability, description, authors")
    )
    assertTrue(rejectionFor { name = "Published" }.message.orEmpty().contains("version, stability"))
    assertTrue(
      rejectionFor {
          name = "Published"
          version = "1.0.0"
        }
        .message
        .orEmpty()
        .contains("stability")
    )
  }

  @Test
  fun rejectsMissingOrUnqualifiedEntry() {
    assertFailsWith<ProjectConfigurationException> { ProjectRuntime.build() }

    assertFailsWith<ProjectConfigurationException> {
      sources { executable { entry = "Main" } }
    }

    ProjectRuntime.reset()
    assertFailsWith<ProjectConfigurationException> {
      sources { executable { entry = "Namespace." } }
    }
  }

  @Test
  fun panicAbortsProjectEvaluationBeforeEmission() {
    val abort = assertFailsWith<ProjectAbort> { panic("unsupported host configuration") }

    assertEquals("unsupported host configuration", abort.message)
  }

  @Test
  fun configuresRenewedProjectAndCompilerSurface() {
    project {
      name = "Compiler"
      version = "0.3.0"
      stability = Stability.NIGHTLY
      description = "Compiler project"
      authors("Leitwolf")
      defaultFeatures("TOML")
    }
    compiler {
      version = "0.3.0"
      standard = "26"
      backend = Backend.LLVM
      buildMode = BuildMode.RELEASE
      werror = true
      warnings = Warnings.ALL
      wexperimental = true
      wshadow = true
      wundef = false
      unsafe {
        xppOptimizationPasses = false
        xmmOptimizationPasses = false
        typeSafeFormat = false
      }
      llvm {
        optLevel = LlvmOptLevel.OG
        compiler = LlvmCompiler.ORC
        lto = LlvmLto.THIN
      }
    }
    outdirs {
      release = "out/release"
      debug = "out/debug"
    }
    targets { target("x86_64-pc-windows-msvc", "aarch64-apple-darwin") }
    pml { enabled = false }
    workspaces { workspace("core") { path = "./Core" } }
    sources {
      viget {
        push = true
        exclude("build/**")
      }
      executable {
        srcDir = "Source"
        exclude("Generated/**")
        entry = "Compiler.Main"
      }
      test("unit") {
        testDir = "Tests/Unit"
        exclude("Fixtures/**")
        framework = "tests"
      }
      test("integration") { framework = "integration-tests" }
    }

    val plan = ProjectRuntime.build()
    assertEquals(
      ProjectIdentity("Compiler", "NIGHTLY", "0.3.0", "Compiler project"),
      plan.identity,
    )
    assertEquals(listOf("Leitwolf"), plan.authors)
    assertEquals(listOf("TOML"), plan.defaultFeatures)
    assertEquals(LlvmCompiler.ORC, plan.compiler.llvmCompiler)
    assertEquals(LlvmLto.THIN, plan.compiler.llvmLto)
    assertEquals(listOf("x86_64-pc-windows-msvc", "aarch64-apple-darwin"), plan.targets)
    assertEquals(listOf(Workspace("core", "./Core")), plan.workspaces)
    assertFalse(plan.pmlEnabled)
    assertTrue(plan.pushSources)
    assertEquals(listOf("build/**"), plan.pushExcludes)
    assertEquals(listOf("Generated/**"), plan.executables.single().exclude)
    assertEquals(
      listOf(
        TestSuite("unit", "Tests/Unit", "tests", listOf("Fixtures/**")),
        TestSuite("integration", "Tests/integration", "integration-tests", null),
      ),
      plan.testSuites,
    )
  }

  @Test
  fun derivesLlvmOptimizationFromBuildMode() {
    sources { executable { entry = "Debug.Main" } }
    assertEquals(LlvmOptLevel.O0, effectiveOptLevel(ProjectRuntime.build().compiler))

    ProjectRuntime.reset()
    compiler { buildMode = BuildMode.RELEASE }
    sources { executable { entry = "Release.Main" } }
    assertEquals(LlvmOptLevel.O3, effectiveOptLevel(ProjectRuntime.build().compiler))
  }

  @Test
  fun planWriterPublishesOnlyRenewedCatalog() {
    project {
      name = "Plan"
      version = "1.0.0"
      stability = Stability.STABLE
    }
    sources { executable { entry = "Plan.Main" } }
    val text = PlanWriter.write(ProjectRuntime.build())

    assertTrue(text.startsWith("{\"format\":\"tala-project-plan\",\"version\":5"))
    assertTrue(text.contains("\"entry\":\"Plan.Main\""))
    assertTrue(text.contains("\"xmmOptimizationPasses\":true"))
    assertFalse(text.contains("module"))
    assertFalse(text.contains("\"variables\""))
    assertFalse(text.contains("XLIL"))
  }

  @Test
  fun planWriterUsesTypedJsonEncodingAndDeterministicPluginMaps() {
    sources { executable { entry = "Codec.Main" } }
    val plugin =
      PluginPlanEntry(
        publisher = "Progmasoft",
        name = "Codec",
        version = "1.0.0",
        apiVersion = PROJECT_PLUGIN_API_VERSION,
        sha256 = "b".repeat(64),
        extensions = listOf("zeta", "alpha"),
        contributions = linkedMapOf("zeta" to "last", "alpha" to "first"),
      )
    val plan =
      ProjectRuntime.build().let { original ->
        original.copy(
          executables =
            listOf(original.executables.single().copy(entry = "Quoted.\"Main\"\nClass")),
          plugins = listOf(plugin),
        )
      }
    val text = PlanWriter.write(plan)
    val document = Json.parseToJsonElement(text).jsonObject

    assertEquals(
      "Quoted.\"Main\"\nClass",
      document
        .getValue("sources")
        .jsonObject
        .getValue("executables")
        .jsonArray
        .single()
        .jsonObject
        .getValue("entry")
        .jsonPrimitive
        .content,
    )
    val encodedPlugin = document.getValue("plugins").jsonArray.single().jsonObject
    assertFalse("stability" in encodedPlugin)
    assertEquals(
      listOf("alpha", "zeta"),
      encodedPlugin.getValue("extensions").jsonArray.map { it.jsonPrimitive.content },
    )
    assertEquals(
      listOf("alpha", "zeta"),
      encodedPlugin.getValue("contributions").jsonObject.keys.toList(),
    )
    assertEquals(text, PlanWriter.write(plan))
  }

  @Test
  fun excludeDefaultsRemainNullAcrossEverySourceSection() {
    sources { executable { entry = "Defaults.Main" } }
    val plan = ProjectRuntime.build()

    assertNull(plan.pushExcludes)
    assertNull(plan.executables.single().exclude)
    assertTrue(plan.testSuites.isEmpty())
    val sourceDocument =
      Json.parseToJsonElement(PlanWriter.write(plan)).jsonObject.getValue("sources").jsonObject
    assertEquals("null", sourceDocument.getValue("viget").jsonObject.getValue("exclude").toString())
    assertEquals(
      "null",
      sourceDocument
        .getValue("executables")
        .jsonArray
        .single()
        .jsonObject
        .getValue("exclude")
        .toString(),
    )
    assertEquals(emptyList(), sourceDocument.getValue("tests").jsonArray)
  }

  @Test
  fun testSuitesKeepIndependentIdentityFrameworkRootsAndNullableExcludes() {
    sources {
      executable { entry = "Suites.Main" }
      test("unit") {
        framework = "tests"
        exclude("Fixtures/**", "Generated/**")
      }
      test("integration") { testDir = "Verification/Integration" }
    }

    assertEquals(
      listOf(
        TestSuite("unit", "Tests/unit", "tests", listOf("Fixtures/**", "Generated/**")),
        TestSuite("integration", "Verification/Integration", null, null),
      ),
      ProjectRuntime.build().testSuites,
    )
  }

  @Test
  fun rejectsDuplicateOrInvalidTestSuiteNames() {
    assertFailsWith<ProjectConfigurationException> {
      sources {
        executable { entry = "Suites.Main" }
        test("unit") {}
        test("unit") {}
      }
    }

    ProjectRuntime.reset()
    assertFailsWith<ProjectConfigurationException> {
      sources {
        executable { entry = "Suites.Main" }
        test("unit tests") {}
      }
    }
  }

  @Test
  fun stderrHelpersPreservePrintAndPrintlnSemantics() {
    val output = ByteArrayOutputStream()
    val previous = System.err
    try {
      System.setErr(PrintStream(output, true, Charsets.UTF_8))
      eprint("problem")
      eprintln(7)
      eprintln(null)
    } finally {
      System.setErr(previous)
    }
    assertEquals(
      "problem7${System.lineSeparator()}null${System.lineSeparator()}",
      output.toString(Charsets.UTF_8),
    )
  }

  @Test
  fun emitsSourceRootsWithoutSearchingForEntryFile() {
    val root = Files.createTempDirectory("tala-project-")
    val output = Files.createTempFile("tala-sources-", ".bin")
    try {
      Files.createDirectories(root.resolve("Sources"))
      Files.createDirectories(root.resolve("Tests/Unit"))
      Files.createDirectories(root.resolve("Tests/Integration"))
      Files.createDirectories(root.resolve("Sources/Unrelated/Layout"))
      Files.writeString(
        root.resolve("Sources/Unrelated/Layout/not-the-entry-name.txt"),
        "not source",
      )
      sources {
        executable { entry = "Demo.Main" }
        test("unit") {
          testDir = "Tests/Unit"
          framework = "tests"
          exclude("Fixtures/**")
        }
        test("integration") { testDir = "Tests/Integration" }
      }
      targets { target("x86_64-pc-windows-msvc") }
      System.setProperty("talac.project.root", root.toString())
      System.setProperty("talac.project.output", "sources0")
      System.setProperty("talac.project.sources", output.toString())

      ProjectOutput.emit(ProjectRuntime.build())
      val records = readRecords(output)
      assertEquals("tala-sources-v6", records[0])
      assertEquals("build/debug", records[16])
      assertEquals("1", records[17])
      assertEquals("1", records[18])
      assertEquals("0", records[19])
      assertEquals("2", records[20])
      assertEquals("x86_64-pc-windows-msvc", records[21])
      assertEquals("Main", records[22])
      assertEquals("Demo.Main", records[23])
      assertTrue(records[24].endsWith("Sources"))
      assertEquals("0", records[25])
      assertEquals("unit", records[26])
      assertEquals("tests", records[27])
      assertTrue(records[28].endsWith("Tests\\Unit") || records[28].endsWith("Tests/Unit"))
      assertEquals("1", records[29])
      assertEquals("Fixtures/**", records[30])
      assertEquals("integration", records[31])
      assertEquals("", records[32])
      assertTrue(
        records[33].endsWith("Tests\\Integration") || records[33].endsWith("Tests/Integration")
      )
      assertEquals("0", records[34])
      assertFalse(records.any { it.endsWith(".tala") })
    } finally {
      root.toFile().deleteRecursively()
      Files.deleteIfExists(output)
    }
  }

  @Test
  fun keepsCfgHostPredicates() {
    assertTrue(cfg(true))
    assertFalse(cfg(false))
    assertTrue(OS.toString().isNotBlank())
    assertTrue(FAMILY.toString().isNotBlank())
    assertTrue(ARCH.toString().isNotBlank())
    assertEquals(
      OperatingSystemFamily.BSD,
      Host(OperatingSystem.FREEBSD, OperatingSystemFamily.BSD, Architecture.X86_64).family,
    )
    assertFalse(OperatingSystemFamily.BSD == OperatingSystemFamily.UNIX)
    assertTrue(setOf(OperatingSystemFamily.BSD, OperatingSystemFamily.UNIX).size == 2)
  }

  private fun effectiveOptLevel(settings: CompilerSettings): LlvmOptLevel =
    settings.llvmOptLevel
      ?: if (settings.buildMode == BuildMode.DEBUG) LlvmOptLevel.O0 else LlvmOptLevel.O3

  private fun readRecords(path: java.nio.file.Path): List<String> =
    Files.readAllBytes(path).toString(Charsets.UTF_8).split('\u0000').dropLastWhile(String::isEmpty)
}
