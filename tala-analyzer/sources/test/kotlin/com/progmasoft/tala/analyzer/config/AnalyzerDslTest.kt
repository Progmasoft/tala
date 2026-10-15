/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tala.analyzer.config

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class AnalyzerDslTest {
  @Test
  fun `defaults match the canonical analyzer configuration`() {
    val configuration = analyzerConfiguration()

    assertEquals("latest", configuration.version)
    assertEquals(AnalysisMode.FULL, configuration.analysisMode)
    assertEquals(DiagnosticsConfiguration(true, true, true, true), configuration.diagnostics)
    assertEquals(true, configuration.inlayHints)
    assertEquals(true, configuration.formatting)
    assertEquals(WorkspaceConfiguration(true), configuration.workspace)
    assertEquals(PerformanceConfiguration(0), configuration.performance)
  }

  @Test
  fun `nested scopes produce one immutable snapshot`() {
    val configuration = analyzerConfiguration {
      version = "0.1.0"
      analysisMode = AnalysisMode.SEMANTIC
      diagnostics {
        linter = false
        onChange = false
      }
      inlayHints = false
      workspace { indexDependencies = false }
      performance { workerThreads = 12 }
    }

    assertEquals("0.1.0", configuration.version)
    assertEquals(AnalysisMode.SEMANTIC, configuration.analysisMode)
    assertFalse(configuration.diagnostics.linter)
    assertFalse(configuration.diagnostics.onChange)
    assertFalse(configuration.inlayHints)
    assertFalse(configuration.workspace.indexDependencies)
    assertEquals(12, configuration.performance.workerThreads)
  }

  @Test
  fun `invalid scalar settings fail at the DSL boundary`() {
    assertFailsWith<AnalyzerConfigurationException> {
      analyzerConfiguration { performance { workerThreads = -1 } }
    }
    assertFailsWith<AnalyzerConfigurationException> {
      analyzerConfiguration { version = "development" }
    }
  }
}
