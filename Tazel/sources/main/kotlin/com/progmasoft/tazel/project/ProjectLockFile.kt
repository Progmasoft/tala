/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.sql.Connection
import java.sql.DriverManager

object ProjectLockFile {
  const val FILE_NAME = "LOCK.sqlite3"
  private const val FORMAT_VERSION = 3

  fun write(
    root: Path,
    manifest: DependencyManifest,
    plugins: List<PluginPlanEntry> = emptyList(),
  ) {
    val validated =
      validateDependencies(manifest.required, manifest.optional, manifest.features, manifest.local)
    Files.createDirectories(root)
    val temporary = Files.createTempFile(root, ".tala-lock-", ".sqlite3")
    try {
      DriverManager.getConnection("jdbc:sqlite:${temporary.toAbsolutePath()}").use { connection ->
        connection.autoCommit = false
        try {
          createSchema(connection)
          writeMetadata(connection)
          writePackages(connection, validated)
          writeFeatures(connection, validated.features)
          writeLocalPackages(connection, validated.local)
          writePlugins(connection, plugins)
          connection.commit()
        } catch (error: Exception) {
          connection.rollback()
          throw error
        }
      }
      replace(temporary, root.resolve(FILE_NAME))
    } finally {
      Files.deleteIfExists(temporary)
    }
  }

  fun read(path: Path): DependencyManifest {
    val connectionUrl = "jdbc:sqlite:${path.toAbsolutePath()}"
    return DriverManager.getConnection(connectionUrl).use { connection ->
      requireFormatVersion(connection)
      readPackages(connection)
    }
  }

  fun readPlugins(path: Path): List<PluginPlanEntry> =
    DriverManager.getConnection("jdbc:sqlite:${path.toAbsolutePath()}").use { connection ->
      requireFormatVersion(connection)
      connection
        .prepareStatement(
          "SELECT publisher, name, version, api_version, sha256 FROM plugins ORDER BY publisher, name"
        )
        .use { statement ->
          statement.executeQuery().use { rows ->
            buildList {
              while (rows.next()) {
                add(
                  PluginPlanEntry(
                    rows.getString(1),
                    rows.getString(2),
                    rows.getString(3),
                    rows.getInt(4),
                    rows.getString(5),
                    emptyList(),
                    emptyMap(),
                  )
                )
              }
            }
          }
        }
    }

  private fun createSchema(connection: Connection) {
    connection.createStatement().use { statement ->
      statement.execute("CREATE TABLE local_packages (path TEXT PRIMARY KEY) WITHOUT ROWID")
      statement.execute(
        "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID"
      )
      statement.execute(
        """
        CREATE TABLE plugins (
          publisher TEXT NOT NULL,
          name TEXT NOT NULL,
          version TEXT NOT NULL,
          api_version INTEGER NOT NULL,
          sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
          PRIMARY KEY(publisher, name)
        ) WITHOUT ROWID
        """
          .trimIndent()
      )
      statement.execute(
        """
        CREATE TABLE packages (
                  name TEXT NOT NULL,
                  stability TEXT NOT NULL,
                  version TEXT NOT NULL,
                  optional_feature TEXT NOT NULL,
                  required INTEGER NOT NULL CHECK(required IN (0, 1)),
                  PRIMARY KEY(name, optional_feature),
                  CHECK((required = 1 AND optional_feature = '') OR (required = 0 AND optional_feature != ''))
                ) WITHOUT ROWID
        """
          .trimIndent()
      )
      statement.execute(
        """
        CREATE TABLE package_features (
                  package_name TEXT NOT NULL,
                  feature TEXT NOT NULL,
                  enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
                  PRIMARY KEY(package_name, feature),
                  FOREIGN KEY(package_name, feature) REFERENCES packages(name, optional_feature)
                ) WITHOUT ROWID
        """
          .trimIndent()
      )
    }
  }

  private fun writeMetadata(connection: Connection) {
    connection
      .prepareStatement("INSERT INTO metadata(key, value) VALUES ('format_version', ?)")
      .use { statement ->
        statement.setString(1, FORMAT_VERSION.toString())
        statement.executeUpdate()
      }
  }

  private fun writePackages(connection: Connection, manifest: DependencyManifest) {
    connection
      .prepareStatement(
        "INSERT INTO packages(name, stability, version, optional_feature, required) VALUES (?, ?, ?, ?, ?)"
      )
      .use { statement ->
        manifest.required.forEach { dependency ->
          statement.setString(1, dependency.coordinate)
          statement.setString(2, dependency.stability.name)
          statement.setString(3, dependency.version)
          statement.setString(4, "")
          statement.setInt(5, 1)
          statement.addBatch()
        }
        manifest.optional.forEach { declaration ->
          statement.setString(1, declaration.dependency.coordinate)
          statement.setString(2, declaration.dependency.stability.name)
          statement.setString(3, declaration.dependency.version)
          statement.setString(4, declaration.feature)
          statement.setInt(5, 0)
          statement.addBatch()
        }
        statement.executeBatch()
      }
  }

  private fun writeFeatures(connection: Connection, features: List<PackageFeatureSelection>) {
    connection
      .prepareStatement(
        "INSERT INTO package_features(package_name, feature, enabled) VALUES (?, ?, ?)"
      )
      .use { statement ->
        features.forEach { feature ->
          statement.setString(1, feature.packageName)
          statement.setString(2, feature.feature)
          statement.setInt(3, if (feature.enabled) 1 else 0)
          statement.addBatch()
        }
        statement.executeBatch()
      }
  }

  private fun writeLocalPackages(
    connection: Connection,
    dependencies: List<LocalPackageDependency>,
  ) {
    connection.prepareStatement("INSERT INTO local_packages(path) VALUES (?)").use { statement ->
      dependencies.forEach { dependency ->
        statement.setString(1, dependency.path)
        statement.addBatch()
      }
      statement.executeBatch()
    }
  }

  private fun writePlugins(
    connection: Connection,
    plugins: List<PluginPlanEntry>,
  ) {
    connection
      .prepareStatement(
        "INSERT INTO plugins(publisher, name, version, api_version, sha256) VALUES (?, ?, ?, ?, ?)"
      )
      .use { statement ->
        plugins.sortedBy(PluginPlanEntry::coordinate).forEach { plugin ->
          statement.setString(1, plugin.publisher)
          statement.setString(2, plugin.name)
          statement.setString(3, plugin.version)
          statement.setInt(4, plugin.apiVersion)
          statement.setString(5, plugin.sha256)
          statement.addBatch()
        }
        statement.executeBatch()
      }
  }

  private fun readPackages(connection: Connection): DependencyManifest {
    val required = mutableListOf<PackageDependency>()
    val optional = mutableListOf<OptionalPackageDependency>()
    connection
      .prepareStatement(
        "SELECT name, stability, version, optional_feature, required FROM packages ORDER BY name, optional_feature"
      )
      .use { statement ->
        statement.executeQuery().use { rows ->
          while (rows.next()) {
            val coordinate = requireDependencyCoordinate(rows.getString(1)).split('.')
            val dependency =
              PackageDependency(
                coordinate[0],
                coordinate[1],
                rows.getString(3),
                Stability.valueOf(rows.getString(2)),
              )
            if (rows.getInt(5) == 1) {
              required += dependency
            } else {
              optional += OptionalPackageDependency(rows.getString(4), dependency)
            }
          }
        }
      }
    val features =
      connection
        .prepareStatement(
          "SELECT package_name, feature, enabled FROM package_features ORDER BY package_name, feature"
        )
        .use { statement ->
          statement.executeQuery().use { rows ->
            buildList {
              while (rows.next()) add(
                PackageFeatureSelection(rows.getString(1), rows.getString(2), rows.getInt(3) == 1)
              )
            }
          }
        }
    val local =
      connection.prepareStatement("SELECT path FROM local_packages ORDER BY path").use { statement
        ->
        statement.executeQuery().use { rows ->
          buildList {
            while (rows.next()) add(LocalPackageDependency(rows.getString(1)))
          }
        }
      }
    return validateDependencies(required, optional, features, local)
  }

  private fun replace(source: Path, target: Path) {
    try {
      Files.move(source, target, ATOMIC_MOVE, REPLACE_EXISTING)
    } catch (_: AtomicMoveNotSupportedException) {
      Files.move(source, target, REPLACE_EXISTING)
    }
  }

  internal fun requireFormatVersion(connection: Connection) {
    val version =
      connection.prepareStatement("SELECT value FROM metadata WHERE key = 'format_version'").use {
        statement ->
        statement.executeQuery().use { rows ->
          if (rows.next()) rows.getString(1).toIntOrNull() else null
        }
      }
    if (version != FORMAT_VERSION) {
      throw ProjectConfigurationException("unsupported LOCK.sqlite3 format version '$version'")
    }
  }
}
