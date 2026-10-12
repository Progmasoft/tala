/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dc

import com.progmasoft.tazel.project.ProjectConfigurationException
import com.progmasoft.tazel.project.ProjectLockFile
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.sql.Connection
import java.sql.DriverManager

/** Writes a deterministic, replayable SQL representation of a Tala lock database. */
object LockfileDump {
  fun write(
    lockfile: Path,
    output: Path,
  ) {
    val source = lockfile.toAbsolutePath().normalize()
    val target = output.toAbsolutePath().normalize()
    if (!Files.isRegularFile(source)) {
      throw ProjectConfigurationException("lockfile does not exist: $source")
    }
    if (source == target) {
      throw ProjectConfigurationException("dump output cannot overwrite the binary lockfile")
    }

    val parent = target.parent
    Files.createDirectories(parent)
    val temporary = Files.createTempFile(parent, ".tala-dump-", ".tmp")
    try {
      DriverManager.getConnection("jdbc:sqlite:$source").use { connection ->
        ProjectLockFile.requireFormatVersion(connection)
        Files.newBufferedWriter(temporary, StandardCharsets.UTF_8).use { writer ->
          writer.appendLine("-- Tala lockfile SQL dump")
          writer.appendLine("PRAGMA foreign_keys=OFF;")
          writer.appendLine("BEGIN TRANSACTION;")
          readTables(connection).forEach { table ->
            writer.appendLine(terminate(table.schema))
            writeRows(connection, table.name) { statement -> writer.appendLine(statement) }
          }
          writer.appendLine("COMMIT;")
        }
      }
      replace(temporary, target)
    } finally {
      Files.deleteIfExists(temporary)
    }
  }

  private data class Table(
    val name: String,
    val schema: String,
  )

  private fun readTables(connection: Connection): List<Table> =
    connection
      .prepareStatement(
        "SELECT name, sql FROM sqlite_schema " +
          "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      )
      .use { statement ->
        statement.executeQuery().use { rows ->
          buildList {
            while (rows.next()) add(Table(rows.getString(1), rows.getString(2)))
          }
        }
      }

  private fun writeRows(
    connection: Connection,
    table: String,
    emit: (String) -> Unit,
  ) {
    val columns = readColumns(connection, table)
    if (columns.isEmpty()) return
    val quotedTable = quoteIdentifier(table)
    val projection = columns.joinToString(", ") { "quote(${quoteIdentifier(it)})" }
    val ordering = columns.joinToString(", ") { quoteIdentifier(it) }
    connection.prepareStatement("SELECT $projection FROM $quotedTable ORDER BY $ordering").use {
      statement ->
      statement.executeQuery().use { rows ->
        while (rows.next()) {
          val values = columns.indices.joinToString(",") { index -> rows.getString(index + 1) }
          emit("INSERT INTO $quotedTable VALUES($values);")
        }
      }
    }
  }

  private fun readColumns(
    connection: Connection,
    table: String,
  ): List<String> =
    connection.createStatement().use { statement ->
      statement.executeQuery("PRAGMA table_info(${quoteIdentifier(table)})").use { rows ->
        buildList {
          while (rows.next()) add(rows.getString("name"))
        }
      }
    }

  private fun quoteIdentifier(value: String) = "\"${value.replace("\"", "\"\"")}\""

  private fun terminate(sql: String): String {
    val normalized = sql.replace("\r\n", "\n").trimEnd()
    return if (normalized.endsWith(';')) normalized else "$normalized;"
  }

  private fun replace(
    source: Path,
    target: Path,
  ) {
    try {
      Files.move(source, target, ATOMIC_MOVE, REPLACE_EXISTING)
    } catch (_: AtomicMoveNotSupportedException) {
      Files.move(source, target, REPLACE_EXISTING)
    }
  }
}
