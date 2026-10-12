/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl.plugin

import java.nio.file.Path

// A hosted publisher is an identifier, so this spelling can never name one.
internal const val LOCAL_PLUGIN_PUBLISHER = "<local>"

data class PluginRequest(
  val publisher: String,
  val name: String?,
  val version: String?,
  val path: String? = null,
) {
  val coordinate: String
    get() = if (isLocal) "local:$path" else "$publisher.$name"

  val isLocal: Boolean
    get() = publisher == LOCAL_PLUGIN_PUBLISHER
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
) {
  val coordinate: String
    get() = "$publisher.$name"
}
