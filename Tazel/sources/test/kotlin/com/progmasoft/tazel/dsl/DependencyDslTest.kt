/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl

import com.progmasoft.tazel.lock.LockedProject
import com.progmasoft.tazel.lock.ProjectLockFile
import java.nio.file.Files
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

  private fun manifest(): DependencyManifest {
    sources {
      executable {
        name = "Demo"
        entry = "Demo.Main"
      }
    }
    return ProjectRuntime.build().dependencies
  }

  @Test
  fun readsEveryKindOfDependency() {
    dependencies {
      localDependency { path = "Dependency.vipkg" }
      dependency("Publisher") {
        name = "Name"
        version = "0.1.0"
        stability = Stability.STABLE
      }
      dependency("Publisher") {
        name = "Toml"
        version = "1.0.0"
        feature = "TOML"
        defaultFeatures = false
        feature("Serde") { enabled = true }
        feature("Legacy") {}
      }
      localTestDependency { path = "TestDependency.vipkg" }
      testDependency("Publisher") {
        name = "TestDep"
        version = "0.1.0"
        stability = Stability.BETA
      }
    }

    val result = manifest()
    assertEquals(
      listOf(
        DependencyDeclaration(PackageDependency("Publisher", "Name", "0.1.0", Stability.STABLE)),
        DependencyDeclaration(
          PackageDependency("Publisher", "Toml", "1.0.0", Stability.STABLE),
          feature = "TOML",
          defaultFeatures = false,
          features = mapOf("Legacy" to false, "Serde" to true),
        ),
        DependencyDeclaration(
          PackageDependency("Publisher", "TestDep", "0.1.0", Stability.BETA),
          DependencyScope.TEST,
        ),
      ),
      result.declarations,
    )
    assertEquals(
      listOf(
        LocalPackageDependency("Dependency.vipkg"),
        LocalPackageDependency("TestDependency.vipkg", DependencyScope.TEST),
      ),
      result.local,
    )
    assertFalse(result.isEmpty)
  }

  @Test
  fun aPackageMayServeTheBuildAndTheTestsSeparately() {
    dependencies {
      dependency("Publisher") {
        name = "Shared"
        version = "1.0.0"
      }
      testDependency("Publisher") {
        name = "Shared"
        version = "2.0.0"
      }
    }
    assertEquals(listOf("1.0.0", "2.0.0"), manifest().declarations.map { it.dependency.version })
  }

  @Test
  fun mergesRepeatedDeclarationsAndRejectsConflictingOnes() {
    repeat(2) {
      dependencies {
        dependency("Publisher") {
          name = "Name"
          version = "1.0.0"
        }
      }
    }
    assertEquals(1, manifest().declarations.size)

    assertFailsWith<ProjectConfigurationException> {
      dependencies {
        dependency("Publisher") {
          name = "Name"
          version = "2.0.0"
        }
      }
    }
  }

  @Test
  fun rejectsIncompleteOrMalformedDeclarations() {
    fun rejected(block: DependenciesScope.() -> Unit) {
      ProjectRuntime.reset()
      assertFailsWith<ProjectConfigurationException> { dependencies(block) }
    }
    rejected { dependency("Publisher") { version = "1.0.0" } }
    rejected { dependency("Publisher") { name = "Name" } }
    rejected {
      dependency("Publisher") {
        name = "Name"
        version = "1.0"
      }
    }
    rejected {
      dependency("bad publisher") {
        name = "Name"
        version = "1.0.0"
      }
    }
    rejected {
      dependency("Publisher") {
        name = "Name"
        version = "1.0.0"
        feature("Twice") {}
        feature("Twice") {}
      }
    }
    rejected { localDependency {} }
    rejected { localDependency { path = "../Outside.vipkg" } }
    rejected { localDependency { path = "Dependency.jar" } }
  }

  @Test
  fun theLockfileKeepsEveryDeclaration() {
    val root = Files.createTempDirectory("tazel-lock-")
    try {
      dependencies {
        localTestDependency { path = "packages/Test.vipkg" }
        dependency("Publisher") {
          name = "Toml"
          version = "1.0.0"
          feature = "TOML"
          defaultFeatures = false
          feature("Serde") { enabled = true }
        }
      }
      val project = LockedProject(manifest(), emptyList())
      val path = root.resolve(ProjectLockFile.FILE_NAME)
      assertFalse(ProjectLockFile.isCurrent(path, project))

      ProjectLockFile.write(root, project)

      assertEquals(project, ProjectLockFile.read(path))
      assertTrue(ProjectLockFile.isCurrent(path, project))
      assertFalse(
        ProjectLockFile.isCurrent(path, LockedProject(DependencyManifest(emptyList()), emptyList()))
      )
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun aFileOfAnotherFormatIsNotACurrentLockfile() {
    val root = Files.createTempDirectory("tazel-lock-foreign-")
    try {
      val path = root.resolve(ProjectLockFile.FILE_NAME)
      Files.writeString(path, "not a database")
      assertFalse(
        ProjectLockFile.isCurrent(path, LockedProject(DependencyManifest(emptyList()), emptyList()))
      )
    } finally {
      root.toFile().deleteRecursively()
    }
  }
}
