/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.io.Serializable
import java.nio.file.Path

const val PROJECT_PLUGIN_API_VERSION = 1

data class PluginRequest(
  val publisher: String,
  val name: String?,
  val version: String?,
  val path: String? = null,
) : Serializable {
  val coordinate: String
    get() = if (isLocal) "local:$path" else "$publisher.$name"

  val isLocal: Boolean
    get() = publisher == "local"
}

data class ResolvedPlugin(
  val publisher: String,
  val name: String,
  val version: String,
  val apiVersion: Int,
  val sha256: String,
  val imports: List<String>,
  val artifact: Path,
  val requestCoordinate: String = "$publisher.$name",
) {
  val coordinate: String
    get() = "$publisher.$name"
}

data class PluginPlanEntry(
  val publisher: String,
  val name: String,
  val version: String,
  val apiVersion: Int,
  val sha256: String,
  val extensions: List<String>,
  val contributions: Map<String, String>,
) : Serializable {
  val coordinate: String
    get() = "$publisher.$name"
}

/**
 * A project plugin runs with the same JVM permissions as the project evaluator. This API does not
 * sandbox plugin code; integrity and compatibility checks happen before activation.
 */
interface ProjectPlugin {
  val publisher: String
  val name: String
  val version: String
  val apiVersion: Int
    get() = PROJECT_PLUGIN_API_VERSION

  fun apply(context: ProjectPluginContext)
}

interface ProjectPluginContext {
  val projectRoot: Path

  fun registerExtension(name: String)

  fun contribute(
    key: String,
    value: String,
  )

  fun onFinalize(action: (ProjectPlan) -> Unit)
}
