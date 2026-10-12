/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.lock

import com.progmasoft.tazel.dsl.DependencyDeclaration
import com.progmasoft.tazel.dsl.DependencyManifest
import com.progmasoft.tazel.dsl.LocalPackageDependency
import com.progmasoft.tazel.dsl.PackageDependency
import com.progmasoft.tazel.dsl.ProjectConfigurationException
import com.progmasoft.tazel.dsl.Stability
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
    val root = Files.createTempDirectory("tazel-dump-")
    try {
      val project =
        LockedProject(
          DependencyManifest(
            listOf(
              DependencyDeclaration(
                PackageDependency("Publisher", "Core", "0.3.1", Stability.STABLE)
              ),
              DependencyDeclaration(
                PackageDependency("Publisher", "Trace", "0.3.1", Stability.BETA),
                feature = "Tracing",
                features = mapOf("Spans" to true),
              ),
            ),
            listOf(LocalPackageDependency("packages/o'neil.vipkg")),
          ),
          emptyList(),
        )
      ProjectLockFile.write(root, project)
      val first = root.resolve("first.dump")
      val second = root.resolve("second.dump")

      LockfileDump.write(root.resolve(ProjectLockFile.FILE_NAME), first)
      LockfileDump.write(root.resolve(ProjectLockFile.FILE_NAME), second)

      val text = first.readText()
      assertEquals(text, second.readText())
      assertTrue(text.startsWith("-- Tala lockfile SQL dump\nPRAGMA foreign_keys=OFF;\n"))
      assertTrue(text.contains("CREATE TABLE metadata"))
      assertTrue(text.contains("INSERT INTO \"metadata\" VALUES('format_version','4');"))
      assertTrue(
        text.contains("INSERT INTO \"local_packages\" VALUES('packages/o''neil.vipkg','BUILD');")
      )
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
      assertEquals(project, ProjectLockFile.read(restored))
    } finally {
      root.toFile().deleteRecursively()
    }
  }

  @Test
  fun rejectsBinaryLockfileAsItsOwnOutput() {
    val root = Files.createTempDirectory("tazel-dump-overwrite-")
    try {
      ProjectLockFile.write(root, LockedProject(DependencyManifest(emptyList()), emptyList()))
      val lockfile = root.resolve(ProjectLockFile.FILE_NAME)
      assertFailsWith<ProjectConfigurationException> { LockfileDump.write(lockfile, lockfile) }
      assertFailsWith<ProjectConfigurationException> {
        LockfileDump.write(root.resolve("absent.sqlite3"), root.resolve("out.dump"))
      }
    } finally {
      root.toFile().deleteRecursively()
    }
  }
}
