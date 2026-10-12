/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dc

import com.progmasoft.tazel.project.DependencyManifest
import com.progmasoft.tazel.project.LocalPackageDependency
import com.progmasoft.tazel.project.OptionalPackageDependency
import com.progmasoft.tazel.project.PackageDependency
import com.progmasoft.tazel.project.PackageFeatureSelection
import com.progmasoft.tazel.project.ProjectConfigurationException
import com.progmasoft.tazel.project.ProjectLockFile
import com.progmasoft.tazel.project.Stability
import java.nio.file.Files
import java.sql.DriverManager
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class LockfileDumpTest {
  @Test
  fun writesDeterministicReplayableSqlText() {
    val root = Files.createTempDirectory("tala-tadc-")
    try {
      val manifest =
        DependencyManifest(
          required = listOf(PackageDependency("Progmasoft", "Core", "0.3.1", Stability.STABLE)),
          optional =
            listOf(
              OptionalPackageDependency(
                "Tracing",
                PackageDependency("Progmasoft", "Trace", "0.3.1", Stability.BETA),
              )
            ),
          features = listOf(PackageFeatureSelection("Progmasoft.Trace", "Tracing", true)),
          local = listOf(LocalPackageDependency("packages/o'neil.vipkg")),
        )
      ProjectLockFile.write(root, manifest)
      val first = root.resolve("first.sqlite3.dump")
      val second = root.resolve("second.sqlite3.dump")

      LockfileDump.write(root.resolve(ProjectLockFile.FILE_NAME), first)
      LockfileDump.write(root.resolve(ProjectLockFile.FILE_NAME), second)

      val text = first.readText()
      assertEquals(text, second.readText())
      assertTrue(text.startsWith("-- Tala lockfile SQL dump\nPRAGMA foreign_keys=OFF;\n"))
      assertTrue(text.contains("CREATE TABLE metadata"))
      assertTrue(text.contains("INSERT INTO \"metadata\" VALUES('format_version','3');"))
      assertTrue(text.contains("INSERT INTO \"local_packages\" VALUES('packages/o''neil.vipkg');"))
      assertTrue(text.endsWith("COMMIT;\n"))

      val restored = root.resolve("restored.sqlite3")
      DriverManager.getConnection("jdbc:sqlite:$restored").use { connection ->
        connection.createStatement().use { statement ->
          val sql = StringBuilder()
          text.lineSequence().forEach { line ->
            if (sql.isEmpty() && (line.isEmpty() || line.startsWith("--"))) return@forEach
            sql.appendLine(line)
            if (line.trimEnd().endsWith(';')) {
              statement.execute(sql.toString())
              sql.setLength(0)
            }
          }
          assertTrue(sql.isEmpty(), "dump must end on a complete SQL statement")
        }
      }
      assertEquals(manifest, ProjectLockFile.read(restored))
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun rejectsBinaryLockfileAsItsOwnOutput() {
    val root = Files.createTempDirectory("tala-tadc-overwrite-")
    try {
      ProjectLockFile.write(root, DependencyManifest(emptyList(), emptyList(), emptyList()))
      val lockfile = root.resolve(ProjectLockFile.FILE_NAME)
      assertFailsWith<ProjectConfigurationException> { LockfileDump.write(lockfile, lockfile) }
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun parsesCaseSensitiveOptionsWithoutRestrictingTheOutputExtension() {
    val root = Files.createTempDirectory("tala-tadc-command-")
    try {
      val project = root.resolve("BUILD.kts")
      Files.writeString(project, "sources { executable { entry = \"Example.Main\" } }")
      val command =
        parseTadcCommand(
          arrayOf("-Projectfile", project.toString(), "-Output", "Example.lock-report")
        )
      assertEquals(project.toFile().canonicalFile, command.projectFile)
      assertEquals("Example.lock-report", command.output.toString())
      assertEquals(
        "dump.json",
        parseTadcCommand(arrayOf("-Projectfile", project.toString(), "-Output", "dump.json"))
          .output
          .toString(),
      )
      assertFailsWith<ProjectConfigurationException> {
        parseTadcCommand(
          arrayOf("-projectfile", project.toString(), "-Output", "Example.lock-report")
        )
      }
    } finally {
      root.toFile().deleteRecursively()
    }
  }
}
