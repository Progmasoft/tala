/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Encodes the versioned project plan consumed by the native project driver. */
object PlanWriter {
  private val encoder = Json { encodeDefaults = true }

  fun write(plan: ProjectPlan): String = encoder.encodeToString(ProjectPlanDocument.from(plan))
}
