/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.nio.file.Files
import java.sql.DriverManager
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DependencyDslTest {
  @BeforeTest
  fun resetRuntime() {
    ProjectRuntime.reset()
  }

  @Test
  fun resolvesPublisherNameCoordinates() {
    dependencies {
      dependency("Publisher") {
        name = "Name"
        version = "1.2.3"
        stability = Stability.STABLE
      }
    }
    sources { executable { entry = "Demo.Main" } }

    val dependency = ProjectRuntime.build().requiredDependencies.single()
    assertEquals(PackageDependency("Publisher", "Name", "1.2.3", Stability.STABLE), dependency)
  }

  @Test
  fun acceptsEveryRenewedStability() {
    Stability.entries.forEach { stability ->
      ProjectRuntime.reset()
      dependencies {
        dependency("Publisher") {
          name = "Package"
          version = "1.0.0"
          this.stability = stability
        }
      }
      sources { executable { entry = "Demo.Main" } }
      assertEquals(
        stability,
        ProjectRuntime.build().requiredDependencies.single().stability,
      )
    }
  }

  @Test
  fun keepsOptionalFeatureDisabledByDefault() {
    dependencies {
      dependency("Publisher") {
        name = "Toml"
        version = "1.0.0"
        optional = "TOML"
        feature("TOML") { enabled = false }
      }
    }
    sources { executable { entry = "Demo.Main" } }
    val plan = ProjectRuntime.build()

    assertTrue(plan.requiredDependencies.isEmpty())
    assertEquals(
      "Publisher.Toml",
      plan.optionalDependencies.single().dependency.coordinate,
    )
    assertFalse(plan.dependencyFeatures.single().enabled)
  }

  @Test
  fun recordsEnabledOptionalFeatureWithoutPretendingToSolveRegistryGraph() {
    dependencies {
      dependency("Publisher") {
        name = "Toml"
        version = "1.0.0"
        optional = "TOML"
        feature("TOML") { enabled = true }
      }
    }
    sources { executable { entry = "Demo.Main" } }
    val plan = ProjectRuntime.build()

    assertEquals(
      "Publisher.Toml",
      plan.optionalDependencies.single().dependency.coordinate,
    )
    assertTrue(plan.dependencyFeatures.single().enabled)
  }

  @Test
  fun validatesDependencyCoordinatesAndVersions() {
    assertFailsWith<ProjectConfigurationException> {
      dependencies {
        dependency("bad.publisher") {
          name = "Name"
          version = "1.0.0"
        }
      }
    }
    ProjectRuntime.reset()
    assertFailsWith<ProjectConfigurationException> {
      dependencies {
        dependency("Publisher") {
          name = "bad-name"
          version = "1.0.0"
        }
      }
    }
    ProjectRuntime.reset()
    assertFailsWith<ProjectConfigurationException> {
      dependencies {
        dependency("Publisher") {
          name = "Name"
          version = "latest"
        }
      }
    }
  }

  @Test
  fun rejectsConflictingCoordinates() {
    assertFailsWith<ProjectConfigurationException> {
      dependencies {
        dependency("Publisher") {
          name = "Name"
          version = "1.0.0"
        }
        dependency("Publisher") {
          name = "Name"
          version = "2.0.0"
        }
      }
    }
  }

  @Test
  fun recordsLocalViPkgWithoutTreatingItAsAViGetCoordinate() {
    dependencies { dependency("local") { path = "packages/dependency.vipkg" } }
    sources { executable { entry = "Demo.Program" } }
    val plan = ProjectRuntime.build()

    assertTrue(plan.requiredDependencies.isEmpty())
    assertEquals("packages/dependency.vipkg", plan.localDependencies.single().path)
    val document = PlanWriter.write(plan)
    assertTrue(document.contains("\"source\":\"local\""))
    assertTrue(document.contains("\"path\":\"packages/dependency.vipkg\""))

    val root = Files.createTempDirectory("tala-local-lock-")
    try {
      ProjectLockFile.write(
        root,
        DependencyManifest(emptyList(), emptyList(), emptyList(), plan.localDependencies),
      )
      assertEquals(
        plan.localDependencies,
        ProjectLockFile.read(root.resolve(ProjectLockFile.FILE_NAME)).local,
      )
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun rejectsUnsafeOrMismatchedLocalDependencyPaths() {
    assertFailsWith<ProjectConfigurationException> {
      dependencies { dependency("local") { path = "../dependency.vipkg" } }
    }
    assertFailsWith<ProjectConfigurationException> {
      dependencies { dependency("local") { path = "dependency.jar" } }
    }
    assertFailsWith<ProjectConfigurationException> {
      dependencies {
        dependency("Publisher") {
          name = "Name"
          version = "1.0.0"
          path = "dependency.vipkg"
        }
      }
    }
  }

  @Test
  fun writesBinaryLockfileWithoutDump() {
    val root = Files.createTempDirectory("tala-lock-")
    try {
      dependencies {
        dependency("Publisher") {
          name = "Name"
          version = "1.0.0"
        }
      }
      sources { executable { entry = "Demo.Main" } }
      val plan = ProjectRuntime.build()
      ProjectLockFile.write(
        root,
        validateDependencies(
          plan.requiredDependencies,
          plan.optionalDependencies,
          plan.dependencyFeatures,
        ),
      )
      val lock = root.resolve(ProjectLockFile.FILE_NAME)

      assertTrue(Files.isRegularFile(lock))
      assertFalse(Files.exists(root.resolve("LOCK.dump")))
      DriverManager.getConnection("jdbc:sqlite:$lock").use { connection ->
        connection.createStatement().use { statement ->
          statement.executeQuery("SELECT name, version FROM packages").use { rows ->
            assertTrue(rows.next())
            assertEquals("Publisher.Name", rows.getString("name"))
            assertEquals("1.0.0", rows.getString("version"))
          }
        }
      }
      val restored = ProjectLockFile.read(lock)
      assertEquals(
        PackageDependency("Publisher", "Name", "1.0.0", Stability.STABLE),
        restored.required.single(),
      )
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun planContainsViGetDependencyShape() {
    dependencies {
      dependency("Publisher") {
        name = "Name"
        version = "0.1.0"
        stability = Stability.BETA
      }
    }
    sources { executable { entry = "Demo.Main" } }
    val text = PlanWriter.write(ProjectRuntime.build())

    assertTrue(text.contains("\"publisher\":\"Publisher\""))
    assertTrue(text.contains("\"name\":\"Name\""))
    assertTrue(text.contains("\"stability\":\"BETA\""))
    assertFalse(text.contains("Progmasoft.Tala.JSON"))
  }
}
