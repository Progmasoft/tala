/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.util.Base64
import java.util.ServiceLoader

object PluginManifest {
  fun write(
    path: Path,
    plugins: List<ResolvedPlugin>,
  ) {
    Files.writeString(
      path,
      plugins.joinToString("\n") { plugin ->
        listOf(
            plugin.publisher,
            plugin.name,
            plugin.version,
            plugin.apiVersion.toString(),
            plugin.sha256,
            plugin.imports.joinToString(","),
            plugin.artifact.toString(),
            plugin.requestCoordinate,
          )
          .joinToString("\t", transform = ::encode)
      },
    )
  }

  fun read(path: Path): List<ResolvedPlugin> =
    try {
      Files.readAllLines(path).filter(String::isNotBlank).mapIndexed(::readRecord)
    } catch (error: ProjectConfigurationException) {
      throw error
    } catch (error: Exception) {
      throw ProjectConfigurationException(
        "plugin manifest could not be read: ${error.message ?: error.javaClass.name}"
      )
    }

  private fun readRecord(index: Int, line: String): ResolvedPlugin {
    val fields = line.split('\t').map(::decode)
    if (fields.size != 8) {
      throw ProjectConfigurationException("invalid plugin manifest record ${index + 1}")
    }
    val publisher = requireModuleSegment(fields[0], "plugin publisher")
    val name = requireModuleSegment(fields[1], "plugin name")
    val version = requirePackageVersion(fields[2])
    val apiVersion = fields[3].toIntOrNull()
    if (apiVersion != PROJECT_PLUGIN_API_VERSION) {
      throw ProjectConfigurationException(
        "plugin '$publisher.$name' requires API ${fields[3]}; runtime provides $PROJECT_PLUGIN_API_VERSION"
      )
    }
    val expectedDigest = fields[4].lowercase()
    if (!expectedDigest.matches(Regex("[0-9a-f]{64}"))) {
      throw ProjectConfigurationException("plugin '$publisher.$name' has an invalid SHA-256 digest")
    }
    val imports = fields[5].split(',').filter(String::isNotEmpty)
    imports.forEach(::requireManifestImport)
    val artifact = Path.of(fields[6]).toAbsolutePath().normalize()
    if (!Files.isRegularFile(artifact) || Files.isSymbolicLink(artifact)) {
      throw ProjectConfigurationException("plugin artifact is not a regular file: $artifact")
    }
    if (PluginResolver.sha256(artifact) != expectedDigest) {
      throw ProjectConfigurationException("plugin '$publisher.$name' changed after it was resolved")
    }
    return ResolvedPlugin(
      publisher,
      name,
      version,
      apiVersion,
      expectedDigest,
      imports.distinct(),
      artifact,
      fields[7],
    )
  }

  private fun requireManifestImport(value: String) {
    if (!value.matches(Regex("[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*(?:\\.\\*)?"))) {
      throw ProjectConfigurationException("plugin manifest contains invalid import '$value'")
    }
  }

  private fun encode(value: String): String =
    Base64.getUrlEncoder()
      .withoutPadding()
      .encodeToString(value.toByteArray(StandardCharsets.UTF_8))

  private fun decode(value: String): String =
    String(Base64.getUrlDecoder().decode(value), StandardCharsets.UTF_8)
}

object PluginRuntime {
  private enum class Phase {
    EMPTY,
    ACTIVATING,
    CONFIGURING,
    FINALIZING,
    FINALIZED,
  }

  private var phase = Phase.EMPTY
  private var resolved = emptyList<ResolvedPlugin>()
  private val declared = linkedSetOf<String>()
  private val extensions = linkedMapOf<String, String>()
  private val contributions = linkedMapOf<String, LinkedHashMap<String, String>>()
  private val finalizers = mutableListOf<Pair<String, (ProjectPlan) -> Unit>>()

  fun activate() {
    val manifest =
      System.getProperty("talac.project.pluginManifest")?.takeIf(String::isNotBlank) ?: return
    activate(
      PluginManifest.read(Path.of(manifest)),
      ServiceLoader.load(ProjectPlugin::class.java).toList(),
    )
  }

  internal fun activate(
    plugins: List<ResolvedPlugin>,
    implementations: List<ProjectPlugin>,
    projectRoot: Path = configuredProjectRoot(),
  ) {
    checkPhase(Phase.EMPTY, "plugin runtime is already active")
    phase = Phase.ACTIVATING
    resolved = plugins
    val byCoordinate = implementations.groupBy { "${it.publisher}.${it.name}" }
    plugins.forEach { plugin ->
      val matches = byCoordinate[plugin.coordinate].orEmpty()
      if (matches.size != 1) {
        throw ProjectConfigurationException(
          "plugin '${plugin.coordinate}' must expose exactly one ProjectPlugin service; found ${matches.size}"
        )
      }
      val implementation = matches.single()
      if (
        implementation.version != plugin.version || implementation.apiVersion != plugin.apiVersion
      ) {
        throw ProjectConfigurationException(
          "plugin service '${plugin.coordinate}' does not match its verified descriptor"
        )
      }
      val context = Context(plugin.coordinate, projectRoot)
      try {
        implementation.apply(context)
      } catch (error: ProjectConfigurationException) {
        throw error
      } catch (error: Exception) {
        throw ProjectConfigurationException(
          "plugin '${plugin.coordinate}' failed during activation: ${error.message ?: error.javaClass.name}"
        )
      }
    }
    phase = Phase.CONFIGURING
  }

  fun declare(request: PluginRequest) {
    checkPhase(Phase.CONFIGURING, "plugins may be declared only while the project is configuring")
    val plugin =
      resolved.singleOrNull { it.requestCoordinate == request.coordinate }
        ?: throw ProjectConfigurationException(
          "plugin '${request.coordinate}' was not resolved by the host"
        )
    if (request.version != null && request.version != plugin.version) {
      throw ProjectConfigurationException(
        "plugin '${request.coordinate}' resolved to an unexpected version"
      )
    }
    if (!declared.add(request.coordinate)) {
      throw ProjectConfigurationException(
        "plugin '${request.coordinate}' is declared more than once"
      )
    }
  }

  fun requireExtension(
    name: String,
    publisher: String,
    plugin: String,
  ) {
    val expectedOwner = "$publisher.$plugin"
    val owner =
      extensions[name]
        ?: throw ProjectConfigurationException("plugin extension '$name' is not registered")
    if (owner != expectedOwner) {
      throw ProjectConfigurationException(
        "plugin extension '$name' belongs to '$owner', not '$expectedOwner'"
      )
    }
  }

  internal fun finish(plan: ProjectPlan): ProjectPlan {
    if (phase == Phase.EMPTY) return plan
    checkPhase(Phase.CONFIGURING, "plugin runtime cannot finalize from phase $phase")
    val missing = resolved.map(ResolvedPlugin::requestCoordinate).filterNot(declared::contains)
    if (missing.isNotEmpty()) {
      throw ProjectConfigurationException(
        "resolved plugins were not declared by the script: ${missing.joinToString()}"
      )
    }
    phase = Phase.FINALIZING
    finalizers.forEach { (owner, action) ->
      try {
        action(plan)
      } catch (error: Exception) {
        throw ProjectConfigurationException(
          "plugin '$owner' failed while finalizing the project: ${error.message ?: error.javaClass.name}"
        )
      }
    }
    val entries = resolved.map { plugin ->
      PluginPlanEntry(
        plugin.publisher,
        plugin.name,
        plugin.version,
        plugin.apiVersion,
        plugin.sha256,
        extensions.filterValues { it == plugin.coordinate }.keys.sorted(),
        contributions[plugin.coordinate]?.toSortedMap().orEmpty(),
      )
    }
    phase = Phase.FINALIZED
    return plan.copy(plugins = entries)
  }

  internal fun reset() {
    phase = Phase.EMPTY
    resolved = emptyList()
    declared.clear()
    extensions.clear()
    contributions.clear()
    finalizers.clear()
  }

  private fun checkPhase(
    expected: Phase,
    message: String,
  ) {
    if (phase != expected) throw ProjectConfigurationException(message)
  }

  private fun configuredProjectRoot(): Path {
    val root =
      System.getProperty("talac.project.root")?.takeIf(String::isNotBlank)
        ?: throw ProjectConfigurationException(
          "project root is not configured for plugin activation"
        )
    return Path.of(root).toAbsolutePath().normalize()
  }

  private class Context(
    private val owner: String,
    override val projectRoot: Path,
  ) : ProjectPluginContext {
    override fun registerExtension(name: String) {
      val normalized = requireModuleSegment(name, "plugin extension")
      val previous = extensions.putIfAbsent(normalized, owner)
      if (previous != null) {
        throw ProjectConfigurationException(
          "plugin extension '$normalized' is registered by both '$previous' and '$owner'"
        )
      }
    }

    override fun contribute(
      key: String,
      value: String,
    ) {
      val normalizedKey = requireText(key, "plugin contribution key")
      if (!normalizedKey.matches(Regex("[A-Za-z_][A-Za-z0-9_.-]{0,127}"))) {
        throw ProjectConfigurationException("invalid plugin contribution key '$normalizedKey'")
      }
      val normalizedValue = requireText(value, "plugin contribution value")
      val values = contributions.getOrPut(owner, ::linkedMapOf)
      if (values.putIfAbsent(normalizedKey, normalizedValue) != null) {
        throw ProjectConfigurationException(
          "plugin '$owner' contributed '$normalizedKey' more than once"
        )
      }
    }

    override fun onFinalize(action: (ProjectPlan) -> Unit) {
      finalizers += owner to action
    }
  }
}
