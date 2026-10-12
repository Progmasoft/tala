/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl.plugin

import com.progmasoft.api.tazel.dsl.plugin.PROJECT_PLUGIN_API_VERSION
import com.progmasoft.api.tazel.dsl.plugin.ProjectPlugin
import com.progmasoft.api.tazel.dsl.plugin.ProjectPluginContext
import com.progmasoft.tazel.dsl.DependencyManifest
import com.progmasoft.tazel.dsl.ProjectConfigurationException
import com.progmasoft.tazel.dsl.ProjectRuntime
import com.progmasoft.tazel.dsl.sources
import com.progmasoft.tazel.lock.LockedPlugin
import com.progmasoft.tazel.lock.LockedProject
import com.progmasoft.tazel.lock.ProjectLockFile
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
  fun cleanup() {
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
          plugin("Publisher") {
            name = "CMake"
            version = "1.2.3"
          }
        }
        panic("must not execute")
        """
          .trimIndent()
      )

    assertEquals(
      PluginRequest("Publisher", "CMake", "1.2.3"),
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
      val request = localPluginRequest(artifact.fileName.toString())
      val resolved = PluginResolver.resolve(root, listOf(request)).single()

      assertEquals("Publisher.Fixture", resolved.coordinate)
      assertEquals("local:${artifact.fileName}", resolved.requestCoordinate)
      assertEquals(
        request,
        PluginPreamble.parse("plugins { localPlugin { path = \"${artifact.fileName}\" } }")
          .single(),
      )
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun rejectsUnsafeOrMismatchedLocalPluginPaths() {
    assertFailsWith<ProjectConfigurationException> {
      PluginPreamble.parse("plugins { localPlugin { path = \"../plugin.jar\" } }")
    }
    assertFailsWith<ProjectConfigurationException> {
      PluginPreamble.parse("plugins { localPlugin { path = \"plugin.vipkg\" } }")
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
          listOf(PluginRequest("Publisher", "Fixture", "1.2.3")),
        )

      assertEquals("Publisher.Fixture", resolved.single().coordinate)
      assertEquals(listOf("com.progmasoft.tazel.dsl.*"), resolved.single().imports)
      assertEquals(64, resolved.single().sha256.length)
      assertSame(
        resolved.single(),
        PluginResolver.resolve(
            root,
            listOf(PluginRequest("Publisher", "Fixture", "1.2.3")),
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
        PluginResolver.resolve(root, listOf(PluginRequest("Publisher", "Fixture", null)))
      }
      Files.delete(artifact.resolveSibling("${artifact.fileName}.sha256"))
      Files.delete(artifact)
      createPluginJar(directory, apiVersion = 99)
      PluginResolver.clearCache()
      assertFailsWith<ProjectConfigurationException> {
        PluginResolver.resolve(root, listOf(PluginRequest("Publisher", "Fixture", null)))
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
      PluginRuntime.declare(PluginRequest("Publisher", "First", "1.0.0"))
      sources {
        executable {
          name = "Demo"
          entry = "Demo.Main"
        }
      }
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
        LockedPlugin("Publisher", "CMake", "1.0.0", PROJECT_PLUGIN_API_VERSION, "a".repeat(64))
      ProjectLockFile.write(root, LockedProject(DependencyManifest(emptyList()), listOf(plugin)))
      val restored = ProjectLockFile.read(root.resolve(ProjectLockFile.FILE_NAME))
      assertEquals(listOf(plugin), restored.plugins)
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

  private fun createPluginJar(
    directory: Path,
    version: String = "1.0.0",
    apiVersion: Int = PROJECT_PLUGIN_API_VERSION,
  ): Path {
    val path = directory.resolve("fixture-$version.jar")
    JarOutputStream(path.outputStream()).use { jar ->
      jar.putNextEntry(JarEntry("META-INF/tazel-plugin.properties"))
      jar.write(
        """
        publisher=Publisher
        name=Fixture
        version=$version
        apiVersion=$apiVersion
        imports=com.progmasoft.tazel.dsl.*
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
      "Publisher",
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
      override val publisher = "Publisher"
      override val name = name
      override val version = "1.0.0"

      override fun apply(context: ProjectPluginContext) = action(context)
    }

  private fun sha256(path: Path): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(path))
    return digest.joinToString("") { "%02x".format(it) }
  }
}
