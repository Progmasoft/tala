/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.lock

import com.progmasoft.tazel.dsl.DependencyDeclaration
import com.progmasoft.tazel.dsl.DependencyManifest
import com.progmasoft.tazel.dsl.DependencyScope
import com.progmasoft.tazel.dsl.LocalPackageDependency
import com.progmasoft.tazel.dsl.PackageDependency
import com.progmasoft.tazel.dsl.ProjectConfigurationException
import com.progmasoft.tazel.dsl.Stability
import com.progmasoft.tazel.dsl.coordinate
import com.progmasoft.tazel.dsl.plugin.PluginPlanEntry
import com.progmasoft.tazel.dsl.requireDependencyCoordinate
import com.progmasoft.tazel.dsl.validateDependencies
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.sql.Connection
import java.sql.DriverManager

/** What a lockfile records: the dependencies of the project and the plugins that evaluated it. */
data class LockedProject(
  val dependencies: DependencyManifest,
  val plugins: List<LockedPlugin>,
)

data class LockedPlugin(
  val publisher: String,
  val name: String,
  val version: String,
  val apiVersion: Int,
  val sha256: String,
) {
  companion object {
    fun of(plugin: PluginPlanEntry) =
      LockedPlugin(
        plugin.publisher,
        plugin.name,
        plugin.version,
        plugin.apiVersion,
        plugin.sha256,
      )
  }
}

/** The lockfile of a project: `LOCK.sqlite3`, an SQLite database beside the project file. */
object ProjectLockFile {
  const val FILE_NAME = "LOCK.sqlite3"
  const val DUMP_FILE_NAME = "LOCK.dump"
  private const val FORMAT_VERSION = 4

  fun write(
    root: Path,
    project: LockedProject,
  ) {
    val validated = validateDependencies(project.dependencies)
    Files.createDirectories(root)
    val temporary = Files.createTempFile(root, ".tazel-lock-", ".sqlite3")
    try {
      DriverManager.getConnection("jdbc:sqlite:${temporary.toAbsolutePath()}").use { connection ->
        connection.autoCommit = false
        try {
          createSchema(connection)
          writeMetadata(connection)
          writePackages(connection, validated.declarations)
          writeLocalPackages(connection, validated.local)
          writePlugins(connection, project.plugins)
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

  fun read(path: Path): LockedProject =
    DriverManager.getConnection("jdbc:sqlite:${path.toAbsolutePath()}").use { connection ->
      requireFormatVersion(connection)
      LockedProject(readPackages(connection), readPlugins(connection))
    }

  /** True when [path] is a lockfile of this format that records exactly [project]. */
  fun isCurrent(
    path: Path,
    project: LockedProject,
  ): Boolean {
    if (!Files.isRegularFile(path)) return false
    val expected =
      project.copy(
        dependencies = validateDependencies(project.dependencies),
        plugins = project.plugins.sortedWith(pluginOrder),
      )
    return try {
      read(path) == expected
    } catch (_: ProjectConfigurationException) {
      false
    } catch (_: java.sql.SQLException) {
      false
    }
  }

  private val pluginOrder = compareBy(LockedPlugin::publisher, LockedPlugin::name)

  private fun createSchema(connection: Connection) {
    connection.createStatement().use { statement ->
      statement.execute(
        """
        CREATE TABLE local_packages (
          path TEXT NOT NULL,
          scope TEXT NOT NULL CHECK(scope IN ('BUILD', 'TEST')),
          PRIMARY KEY(path, scope)
        ) WITHOUT ROWID
        """
          .trimIndent()
      )
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
          scope TEXT NOT NULL CHECK(scope IN ('BUILD', 'TEST')),
          stability TEXT NOT NULL,
          version TEXT NOT NULL,
          feature TEXT,
          default_features INTEGER NOT NULL CHECK(default_features IN (0, 1)),
          PRIMARY KEY(name, scope)
        ) WITHOUT ROWID
        """
          .trimIndent()
      )
      statement.execute(
        """
        CREATE TABLE package_features (
          package_name TEXT NOT NULL,
          scope TEXT NOT NULL,
          feature TEXT NOT NULL,
          enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
          PRIMARY KEY(package_name, scope, feature),
          FOREIGN KEY(package_name, scope) REFERENCES packages(name, scope)
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

  private fun writePackages(
    connection: Connection,
    declarations: List<DependencyDeclaration>,
  ) {
    connection
      .prepareStatement(
        "INSERT INTO packages(name, scope, stability, version, feature, default_features) " +
          "VALUES (?, ?, ?, ?, ?, ?)"
      )
      .use { statement ->
        declarations.forEach { declaration ->
          statement.setString(1, declaration.dependency.coordinate)
          statement.setString(2, declaration.scope.name)
          statement.setString(3, declaration.dependency.stability.name)
          statement.setString(4, declaration.dependency.version)
          statement.setString(5, declaration.feature)
          statement.setInt(6, if (declaration.defaultFeatures) 1 else 0)
          statement.addBatch()
        }
        statement.executeBatch()
      }
    connection
      .prepareStatement(
        "INSERT INTO package_features(package_name, scope, feature, enabled) VALUES (?, ?, ?, ?)"
      )
      .use { statement ->
        declarations.forEach { declaration ->
          declaration.features.forEach { (feature, enabled) ->
            statement.setString(1, declaration.dependency.coordinate)
            statement.setString(2, declaration.scope.name)
            statement.setString(3, feature)
            statement.setInt(4, if (enabled) 1 else 0)
            statement.addBatch()
          }
        }
        statement.executeBatch()
      }
  }

  private fun writeLocalPackages(
    connection: Connection,
    dependencies: List<LocalPackageDependency>,
  ) {
    connection.prepareStatement("INSERT INTO local_packages(path, scope) VALUES (?, ?)").use {
      statement ->
      dependencies.forEach { dependency ->
        statement.setString(1, dependency.path)
        statement.setString(2, dependency.scope.name)
        statement.addBatch()
      }
      statement.executeBatch()
    }
  }

  private fun writePlugins(
    connection: Connection,
    plugins: List<LockedPlugin>,
  ) {
    connection
      .prepareStatement(
        "INSERT INTO plugins(publisher, name, version, api_version, sha256) VALUES (?, ?, ?, ?, ?)"
      )
      .use { statement ->
        plugins.sortedWith(pluginOrder).forEach { plugin ->
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

  private fun readPlugins(connection: Connection): List<LockedPlugin> =
    connection
      .prepareStatement(
        "SELECT publisher, name, version, api_version, sha256 FROM plugins ORDER BY publisher, name"
      )
      .use { statement ->
        statement.executeQuery().use { rows ->
          buildList {
            while (rows.next()) {
              add(
                LockedPlugin(
                  rows.getString(1),
                  rows.getString(2),
                  rows.getString(3),
                  rows.getInt(4),
                  rows.getString(5),
                )
              )
            }
          }
        }
      }

  private fun readPackages(connection: Connection): DependencyManifest {
    val features = linkedMapOf<Pair<String, String>, MutableMap<String, Boolean>>()
    connection
      .prepareStatement("SELECT package_name, scope, feature, enabled FROM package_features")
      .use { statement ->
        statement.executeQuery().use { rows ->
          while (rows.next()) {
            features
              .getOrPut(rows.getString(1) to rows.getString(2), ::linkedMapOf)[rows.getString(3)] =
              rows.getInt(4) == 1
          }
        }
      }
    val declarations =
      connection
        .prepareStatement(
          "SELECT name, scope, stability, version, feature, default_features FROM packages"
        )
        .use { statement ->
          statement.executeQuery().use { rows ->
            buildList {
              while (rows.next()) {
                val name = rows.getString(1)
                val scope = rows.getString(2)
                val coordinate = requireDependencyCoordinate(name).split('.')
                add(
                  DependencyDeclaration(
                    PackageDependency(
                      coordinate[0],
                      coordinate[1],
                      rows.getString(4),
                      enumOf<Stability>(rows.getString(3), "stability"),
                    ),
                    enumOf<DependencyScope>(scope, "scope"),
                    rows.getString(5),
                    rows.getInt(6) == 1,
                    features[name to scope].orEmpty(),
                  )
                )
              }
            }
          }
        }
    val local =
      connection.prepareStatement("SELECT path, scope FROM local_packages").use { statement ->
        statement.executeQuery().use { rows ->
          buildList {
            while (rows.next()) {
              add(
                LocalPackageDependency(
                  rows.getString(1),
                  enumOf<DependencyScope>(rows.getString(2), "scope"),
                )
              )
            }
          }
        }
      }
    return validateDependencies(DependencyManifest(declarations, local))
  }

  private inline fun <reified T : Enum<T>> enumOf(
    text: String,
    field: String,
  ): T =
    enumValues<T>().firstOrNull { it.name == text }
      ?: throw ProjectConfigurationException("$FILE_NAME holds an unknown $field '$text'")

  private fun replace(source: Path, target: Path) {
    try {
      Files.move(source, target, ATOMIC_MOVE, REPLACE_EXISTING)
    } catch (_: AtomicMoveNotSupportedException) {
      Files.move(source, target, REPLACE_EXISTING)
    }
  }

  internal fun requireFormatVersion(connection: Connection) {
    val version =
      try {
        connection
          .prepareStatement("SELECT value FROM metadata WHERE key = 'format_version'")
          .use { statement ->
            statement.executeQuery().use { rows ->
              if (rows.next()) rows.getString(1).toIntOrNull() else null
            }
          }
      } catch (_: java.sql.SQLException) {
        null
      }
    if (version != FORMAT_VERSION) {
      throw ProjectConfigurationException(
        "$FILE_NAME is not of lockfile format $FORMAT_VERSION; renew it with tazel lock resolve"
      )
    }
  }
}
