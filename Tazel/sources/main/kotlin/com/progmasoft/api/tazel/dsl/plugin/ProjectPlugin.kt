/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.api.tazel.dsl.plugin

import com.progmasoft.tazel.dsl.ProjectPlan
import java.nio.file.Path

/** The version of this API; a plugin built for another one is not loaded. */
const val PROJECT_PLUGIN_API_VERSION = 1

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
