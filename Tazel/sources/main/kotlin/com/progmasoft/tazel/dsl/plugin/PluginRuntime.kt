/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl.plugin

import com.progmasoft.api.tazel.dsl.plugin.ProjectPlugin
import com.progmasoft.api.tazel.dsl.plugin.ProjectPluginContext
import com.progmasoft.tazel.dsl.ProjectConfigurationException
import com.progmasoft.tazel.dsl.ProjectPlan
import com.progmasoft.tazel.dsl.requireModuleSegment
import com.progmasoft.tazel.dsl.requireText
import java.nio.file.Path

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

  internal fun activate(
    plugins: List<ResolvedPlugin>,
    implementations: List<ProjectPlugin>,
    projectRoot: Path,
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
