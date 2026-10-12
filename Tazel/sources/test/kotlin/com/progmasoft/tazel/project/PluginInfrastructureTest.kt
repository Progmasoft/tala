/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.sql.DriverManager
import java.util.jar.JarEntry
import java.util.jar.JarOutputStream
import kotlin.io.path.outputStream
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame

class PluginInfrastructureTest {
  @BeforeTest
  fun reset() {
    ProjectRuntime.reset()
    PluginResolver.clearCache()
  }

  @AfterTest
  fun cleanupProperties() {
    System.clearProperty("talac.project.root")
    System.clearProperty("talac.project.output")
    System.clearProperty("talac.project.pluginManifest")
    ProjectRuntime.reset()
  }

  @Test
  fun parsesPluginPreambleWithoutExecutingProjectCode() {
    val requests =
      PluginPreamble.parse(
        """
        // plugins { plugin("Ignored") { name = "Comment" } }
        val raw = ${"\"\"\""}plugins { plugin("Ignored") { name = "RawString" } }${"\"\"\""}
        val character = '}'
        plugins {
          plugin("Progmasoft") {
            name = "CMake"
            version = "1.2.3"
          }
        }
        panic("must not execute")
        """
          .trimIndent()
      )

    assertEquals(
      PluginRequest("Progmasoft", "CMake", "1.2.3"),
      requests.single(),
    )
  }

  @Test
  fun rejectsDuplicateAndUnsafeDeclarations() {
    assertFailsWith<ProjectConfigurationException> {
      PluginPreamble.parse(
        "plugins { plugin(\"Progmasoft\") { name=\"CMake\" }; plugin(\"Progmasoft\") { name=\"CMake\" } }"
      )
    }
    assertFailsWith<ProjectConfigurationException> {
      PluginPreamble.parse("plugins { plugin(\"../bad\") { name=\"CMake\" } }")
    }
    assertFailsWith<ProjectConfigurationException> {
      PluginPreamble.parse(
        "plugins { plugin(\"Progmasoft\") { name=\"CMake\"; stability=Stability.STABLE } }"
      )
    }
  }

  @Test
  fun resolvesExplicitLocalPluginJarByItsVerifiedDescriptor() {
    val root = Files.createTempDirectory("tala-local-plugin-")
    try {
      val artifact = createPluginJar(root)
      val request = PluginRequest("local", null, null, artifact.fileName.toString())
      val resolved = PluginResolver.resolve(root, listOf(request)).single()

      assertEquals("Progmasoft.Fixture", resolved.coordinate)
      assertEquals("local:${artifact.fileName}", resolved.requestCoordinate)
      assertEquals(
        request,
        PluginPreamble.parse("plugins { plugin(\"local\") { path = \"${artifact.fileName}\" } }")
          .single(),
      )
      val manifest = root.resolve("plugins.manifest")
      PluginManifest.write(manifest, listOf(resolved))
      assertEquals(
        resolved.requestCoordinate,
        PluginManifest.read(manifest).single().requestCoordinate,
      )
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun rejectsUnsafeOrMismatchedLocalPluginPaths() {
    assertFailsWith<ProjectConfigurationException> {
      PluginPreamble.parse("plugins { plugin(\"local\") { path = \"../plugin.jar\" } }")
    }
    assertFailsWith<ProjectConfigurationException> {
      PluginPreamble.parse("plugins { plugin(\"local\") { path = \"plugin.vipkg\" } }")
    }
    assertFailsWith<ProjectConfigurationException> {
      PluginPreamble.parse(
        "plugins { plugin(\"Progmasoft\") { name = \"CMake\"; path = \"plugin.jar\" } }"
      )
    }
  }

  @Test
  fun resolvesDescriptorAndVerifiesOptionalChecksum() {
    val root = Files.createTempDirectory("tala-plugin-resolver-")
    try {
      val directory = Files.createDirectories(root.resolve(".tazel/plugins"))
      val artifact = createPluginJar(directory, version = "1.2.3")
      Files.writeString(artifact.resolveSibling("${artifact.fileName}.sha256"), sha256(artifact))

      val resolved =
        PluginResolver.resolve(
          root,
          listOf(PluginRequest("Progmasoft", "Fixture", "1.2.3")),
        )

      assertEquals("Progmasoft.Fixture", resolved.single().coordinate)
      assertEquals(listOf("com.progmasoft.tazel.project.*"), resolved.single().imports)
      assertEquals(64, resolved.single().sha256.length)
      assertSame(
        resolved.single(),
        PluginResolver.resolve(
            root,
            listOf(PluginRequest("Progmasoft", "Fixture", "1.2.3")),
          )
          .single(),
      )
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun rejectsChecksumMismatchAndApiMismatch() {
    val root = Files.createTempDirectory("tala-plugin-integrity-")
    try {
      val directory = Files.createDirectories(root.resolve(".tazel/plugins"))
      val artifact = createPluginJar(directory)
      Files.writeString(artifact.resolveSibling("${artifact.fileName}.sha256"), "0".repeat(64))
      assertFailsWith<ProjectConfigurationException> {
        PluginResolver.resolve(root, listOf(PluginRequest("Progmasoft", "Fixture", null)))
      }
      Files.delete(artifact.resolveSibling("${artifact.fileName}.sha256"))
      Files.delete(artifact)
      createPluginJar(directory, apiVersion = 99)
      PluginResolver.clearCache()
      assertFailsWith<ProjectConfigurationException> {
        PluginResolver.resolve(root, listOf(PluginRequest("Progmasoft", "Fixture", null)))
      }
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun activatesLifecycleAndRejectsExtensionCollisions() {
    val root = Files.createTempDirectory("tala-plugin-runtime-")
    try {
      val first = resolved(root, "First")
      val second = resolved(root, "Second")
      val firstPlugin =
        fixturePlugin("First") { context ->
          context.registerExtension("native")
          context.contribute("enabled", "true")
        }
      val secondPlugin = fixturePlugin("Second") { context -> context.registerExtension("native") }

      assertFailsWith<ProjectConfigurationException> {
        PluginRuntime.activate(listOf(first, second), listOf(firstPlugin, secondPlugin), root)
      }

      ProjectRuntime.reset()
      PluginRuntime.activate(listOf(first), listOf(firstPlugin), root)
      PluginRuntime.declare(PluginRequest("Progmasoft", "First", "1.0.0"))
      sources { executable { entry = "Demo.Main" } }
      val plan = ProjectRuntime.build()
      assertEquals(listOf("native"), plan.plugins.single().extensions)
      assertEquals("true", plan.plugins.single().contributions["enabled"])
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun lockfilePersistsResolvedPluginIdentityAndDigest() {
    val root = Files.createTempDirectory("tala-plugin-lock-")
    try {
      val plugin =
        PluginPlanEntry(
          "Progmasoft",
          "CMake",
          "1.0.0",
          PROJECT_PLUGIN_API_VERSION,
          "a".repeat(64),
          listOf("cmake"),
          mapOf("generator" to "Ninja"),
        )
      ProjectLockFile.write(
        root,
        DependencyManifest(emptyList(), emptyList(), emptyList()),
        listOf(plugin),
      )
      val restored = ProjectLockFile.readPlugins(root.resolve(ProjectLockFile.FILE_NAME)).single()
      assertEquals(plugin.coordinate, restored.coordinate)
      assertEquals(plugin.sha256, restored.sha256)
      DriverManager.getConnection("jdbc:sqlite:${root.resolve(ProjectLockFile.FILE_NAME)}").use {
        connection ->
        connection.createStatement().use { statement ->
          statement.executeQuery("PRAGMA table_info(plugins)").use { rows ->
            val columns = buildList {
              while (rows.next()) add(rows.getString("name"))
            }
            assertFalse("stability" in columns)
          }
        }
      }
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun manifestRejectsArtifactChangedAfterResolution() {
    val root = Files.createTempDirectory("tala-plugin-manifest-")
    try {
      val directory = Files.createDirectories(root.resolve(".tazel/plugins"))
      val artifact = createPluginJar(directory)
      val resolved =
        PluginResolver.resolve(
          root,
          listOf(PluginRequest("Progmasoft", "Fixture", null)),
        )
      val manifest = root.resolve("plugins.manifest")
      PluginManifest.write(manifest, resolved)
      Files.writeString(artifact, "replaced")

      assertFailsWith<ProjectConfigurationException> { PluginManifest.read(manifest) }
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  private fun createPluginJar(
    directory: Path,
    version: String = "1.0.0",
    apiVersion: Int = PROJECT_PLUGIN_API_VERSION,
  ): Path {
    val path = directory.resolve("fixture-$version.jar")
    JarOutputStream(path.outputStream()).use { jar ->
      jar.putNextEntry(JarEntry("META-INF/tala-plugin.properties"))
      jar.write(
        """
        publisher=Progmasoft
        name=Fixture
        version=$version
        apiVersion=$apiVersion
        imports=com.progmasoft.tazel.project.*
        """
          .trimIndent()
          .toByteArray()
      )
      jar.closeEntry()
    }
    return path
  }

  private fun resolved(
    root: Path,
    name: String,
  ) =
    ResolvedPlugin(
      "Progmasoft",
      name,
      "1.0.0",
      PROJECT_PLUGIN_API_VERSION,
      "a".repeat(64),
      emptyList(),
      root.resolve("$name.jar"),
    )

  private fun fixturePlugin(
    name: String,
    action: (ProjectPluginContext) -> Unit,
  ) =
    object : ProjectPlugin {
      override val publisher = "Progmasoft"
      override val name = name
      override val version = "1.0.0"

      override fun apply(context: ProjectPluginContext) = action(context)
    }

  private fun sha256(path: Path): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(path))
    return digest.joinToString("") { "%02x".format(it) }
  }
}
