/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl.plugin

import com.progmasoft.tazel.dsl.ProjectConfigurationException
import com.progmasoft.tazel.dsl.TazelDsl
import com.progmasoft.tazel.dsl.requireLocalArtifactPath
import com.progmasoft.tazel.dsl.requireModuleSegment
import com.progmasoft.tazel.dsl.requirePackageVersion

@TazelDsl
class PluginDeclarationScope internal constructor(private val publisher: String) {
  var name: String? = null
  var version: String? = null

  internal fun request() = hostedPluginRequest(publisher, name, version)
}

@TazelDsl
class LocalPluginScope internal constructor() {
  var path: String? = null

  internal fun request() = localPluginRequest(path)
}

@TazelDsl
class PluginsScope internal constructor() {
  private val requests = mutableListOf<PluginRequest>()

  /** A plugin of ViGet, named by its publisher and its `name`. */
  fun plugin(
    publisher: String,
    block: PluginDeclarationScope.() -> Unit,
  ) = add(PluginDeclarationScope(publisher).apply(block).request())

  /** A plugin JAR of the project directory; its name and version come from its descriptor. */
  fun localPlugin(block: LocalPluginScope.() -> Unit) =
    add(LocalPluginScope().apply(block).request())

  private fun add(request: PluginRequest) {
    if (requests.any { it.coordinate == request.coordinate }) {
      throw ProjectConfigurationException(
        "plugin '${request.coordinate}' is declared more than once"
      )
    }
    requests += request
  }

  internal fun apply() = requests.forEach(PluginRuntime::declare)
}

fun plugins(block: PluginsScope.() -> Unit) = PluginsScope().apply(block).apply()

internal fun localPluginRequest(path: String?) =
  PluginRequest(
    publisher = LOCAL_PLUGIN_PUBLISHER,
    name = null,
    version = null,
    path = requireLocalArtifactPath(path, "jar", "local plugin path"),
  )

internal fun hostedPluginRequest(
  publisher: String,
  name: String?,
  version: String?,
) =
  PluginRequest(
    requireModuleSegment(publisher, "plugin publisher"),
    requireModuleSegment(
      name ?: throw ProjectConfigurationException("plugin name is required"),
      "plugin name",
    ),
    version?.let(::requirePackageVersion),
  )
