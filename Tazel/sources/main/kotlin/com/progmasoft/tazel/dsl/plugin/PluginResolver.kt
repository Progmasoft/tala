/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl.plugin

import com.progmasoft.api.tazel.dsl.plugin.PROJECT_PLUGIN_API_VERSION
import com.progmasoft.tazel.dsl.ProjectConfigurationException
import com.progmasoft.tazel.dsl.requireModuleSegment
import com.progmasoft.tazel.dsl.requirePackageVersion
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.security.MessageDigest
import java.util.Properties
import java.util.concurrent.ConcurrentHashMap
import java.util.jar.JarFile
import kotlin.io.path.extension
import kotlin.streams.toList

object PluginResolver {
  private const val DESCRIPTOR = "META-INF/tazel-plugin.properties"
  private val indexCache = ConcurrentHashMap<String, CachedIndex>()

  fun resolve(
    root: Path,
    requests: List<PluginRequest>,
  ): List<ResolvedPlugin> {
    if (requests.isEmpty()) return emptyList()
    val cache = root.resolve(".tazel/plugins").toAbsolutePath().normalize()
    val candidates =
      if (Files.isDirectory(cache)) index(cache).groupBy(ResolvedPlugin::coordinate) else emptyMap()
    return requests.map { request ->
      if (request.isLocal) resolveLocal(root, request)
      else select(request, candidates[request.coordinate].orEmpty())
    }
  }

  internal fun clearCache() = indexCache.clear()

  private fun resolveLocal(root: Path, request: PluginRequest): ResolvedPlugin {
    val projectRoot = root.toAbsolutePath().normalize()
    val artifact = projectRoot.resolve(request.path!!).normalize()
    if (!artifact.startsWith(projectRoot)) {
      throw ProjectConfigurationException(
        "local plugin path escapes the project root: ${request.path}"
      )
    }
    if (
      !Files.isRegularFile(artifact, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(artifact)
    ) {
      throw ProjectConfigurationException("local plugin JAR does not exist: ${request.path}")
    }
    val realRoot = projectRoot.toRealPath()
    val realArtifact = artifact.toRealPath()
    if (!realArtifact.startsWith(realRoot)) {
      throw ProjectConfigurationException(
        "local plugin path escapes the project root: ${request.path}"
      )
    }
    return inspect(realRoot, realArtifact).copy(requestCoordinate = request.coordinate)
  }

  private fun index(root: Path): List<ResolvedPlugin> {
    val fingerprint = directoryFingerprint(root)
    val key = root.toString()
    indexCache[key]
      ?.takeIf { it.fingerprint == fingerprint }
      ?.let {
        return it.plugins
      }
    val plugins =
      Files.walk(root)
        .use { paths ->
          paths
            .filter { path -> Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) }
            .filter { path -> path.extension.equals("jar", ignoreCase = true) }
            .map { path -> inspect(root, path) }
            .toList()
        }
        .sortedWith(compareBy(ResolvedPlugin::coordinate, ResolvedPlugin::version))
    indexCache[key] = CachedIndex(fingerprint, plugins)
    return plugins
  }

  private fun directoryFingerprint(root: Path): Long =
    Files.walk(root).use { paths ->
      paths
        .filter { Files.isRegularFile(it, LinkOption.NOFOLLOW_LINKS) }
        .mapToLong { path ->
          Files.size(path) xor Files.getLastModifiedTime(path, LinkOption.NOFOLLOW_LINKS).toMillis()
        }
        .reduce(0L) { left, right -> left xor right }
    }

  private fun inspect(
    root: Path,
    artifact: Path,
  ): ResolvedPlugin {
    val normalized = artifact.toAbsolutePath().normalize()
    if (!normalized.startsWith(root) || Files.isSymbolicLink(normalized)) {
      throw ProjectConfigurationException("plugin artifact escapes its configured root: $artifact")
    }
    val properties = Properties()
    JarFile(normalized.toFile(), true).use { jar ->
      val entry =
        jar.getJarEntry(DESCRIPTOR)
          ?: throw ProjectConfigurationException("plugin artifact has no $DESCRIPTOR: $artifact")
      jar.getInputStream(entry).use(properties::load)
    }
    val publisher =
      requireModuleSegment(properties.required("publisher", artifact), "plugin publisher")
    val name = requireModuleSegment(properties.required("name", artifact), "plugin name")
    val version = requirePackageVersion(properties.required("version", artifact))
    val apiVersion =
      properties.required("apiVersion", artifact).toIntOrNull()
        ?: throw ProjectConfigurationException("plugin '$publisher.$name' has invalid API version")
    if (apiVersion != PROJECT_PLUGIN_API_VERSION) {
      throw ProjectConfigurationException(
        "plugin '$publisher.$name' requires API $apiVersion; runtime provides $PROJECT_PLUGIN_API_VERSION"
      )
    }
    val imports =
      properties
        .getProperty("imports", "")
        .split(',')
        .map(String::trim)
        .filter(String::isNotEmpty)
        .onEach(::requireSafeImport)
        .distinct()
    val digest = sha256(normalized)
    verifySidecar(normalized, digest)
    return ResolvedPlugin(
      publisher,
      name,
      version,
      apiVersion,
      digest,
      imports,
      normalized,
    )
  }

  private fun select(
    request: PluginRequest,
    candidates: List<ResolvedPlugin>,
  ): ResolvedPlugin {
    val matching = candidates.filter { plugin ->
      request.version == null || plugin.version == request.version
    }
    if (matching.isEmpty()) {
      val requestedVersion = request.version?.let { " version $it" }.orEmpty()
      throw ProjectConfigurationException(
        "plugin '${request.coordinate}'$requestedVersion is not installed in the project plugin cache"
      )
    }
    val selected =
      matching.maxWithOrNull { left, right ->
        val versionOrder = compareVersions(left.version, right.version)
        if (versionOrder != 0) versionOrder else left.sha256.compareTo(right.sha256)
      }!!
    return if (selected.requestCoordinate == request.coordinate) selected
    else selected.copy(requestCoordinate = request.coordinate)
  }

  private fun compareVersions(
    left: String,
    right: String,
  ): Int {
    val leftParts = left.substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
    val rightParts = right.substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
    repeat(maxOf(leftParts.size, rightParts.size)) { index ->
      val comparison = leftParts.getOrElse(index) { 0 }.compareTo(rightParts.getOrElse(index) { 0 })
      if (comparison != 0) return comparison
    }
    return left.compareTo(right)
  }

  private fun requireSafeImport(value: String) {
    if (!value.matches(Regex("[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*(?:\\.\\*)?"))) {
      throw ProjectConfigurationException("plugin descriptor contains unsafe import '$value'")
    }
  }

  private fun verifySidecar(
    artifact: Path,
    actual: String,
  ) {
    val sidecar = artifact.resolveSibling("${artifact.fileName}.sha256")
    if (!Files.exists(sidecar)) return
    if (!Files.isRegularFile(sidecar, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(sidecar)) {
      throw ProjectConfigurationException("plugin checksum is not a regular file: $sidecar")
    }
    val expected = Files.readString(sidecar).trim().substringBefore(' ').lowercase()
    if (!expected.matches(Regex("[0-9a-f]{64}")) || expected != actual) {
      throw ProjectConfigurationException("plugin checksum mismatch: $artifact")
    }
  }

  internal fun sha256(path: Path): String {
    val digest = MessageDigest.getInstance("SHA-256")
    Files.newInputStream(path).use { input ->
      val buffer = ByteArray(64 * 1024)
      while (true) {
        val count = input.read(buffer)
        if (count < 0) break
        digest.update(buffer, 0, count)
      }
    }
    return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
  }

  private fun Properties.required(
    name: String,
    artifact: Path,
  ): String =
    getProperty(name)?.trim()?.takeIf(String::isNotEmpty)
      ?: throw ProjectConfigurationException("plugin descriptor '$artifact' requires '$name'")

  private data class CachedIndex(
    val fingerprint: Long,
    val plugins: List<ResolvedPlugin>,
  )
}
