/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tala.analyzer.config

/**
 * Prevents nested analyzer configuration blocks from resolving outer-scope properties by accident.
 */
@DslMarker annotation class AnalyzerDsl

/** Configuration for compiler and linter diagnostics and their update triggers. */
@AnalyzerDsl
class DiagnosticsScope {
  /** Whether compiler diagnostics are requested. */
  var compiler: Boolean = true

  /** Whether talalint diagnostics are requested. */
  var linter: Boolean = true

  /** Whether diagnostics are refreshed while the document changes. */
  var onChange: Boolean = true

  /** Whether diagnostics are refreshed when the document is saved. */
  var onSave: Boolean = true

  /** Copies this mutable DSL scope into the immutable public configuration value. */
  internal fun snapshot() = DiagnosticsConfiguration(compiler, linter, onChange, onSave)
}

/** Configuration for project-wide analysis inputs. */
@AnalyzerDsl
class WorkspaceScope {
  /** Whether dependencies are included in workspace indexing. */
  var indexDependencies: Boolean = true

  /** Copies this mutable DSL scope into the immutable public configuration value. */
  internal fun snapshot() = WorkspaceConfiguration(indexDependencies)
}

/** Configuration for analyzer resource usage. */
@AnalyzerDsl
class PerformanceScope {
  /** Maximum worker count; zero asks the runtime to choose an appropriate value. */
  var workerThreads: Int = 0

  /** Validates resource settings and produces an immutable configuration value. */
  internal fun snapshot(): PerformanceConfiguration {
    if (workerThreads < 0) {
      throw AnalyzerConfigurationException(
        "performance.workerThreads must be zero or a positive integer"
      )
    }
    return PerformanceConfiguration(workerThreads)
  }
}

/**
 * Typed state for `tala-analyzer.kts`.
 *
 * This scope only defines defaults, validation, and an immutable snapshot. It does not discover,
 * compile, load, or execute Kotlin scripts; that evaluator boundary remains separate.
 */
@AnalyzerDsl
class AnalyzerScope {
  private val diagnosticsScope = DiagnosticsScope()
  private val workspaceScope = WorkspaceScope()
  private val performanceScope = PerformanceScope()

  /** Requested analyzer release, or `latest` to follow the installed release. */
  var version: String = "latest"

  /** Compiler phase at which document analysis stops. */
  var analysisMode: AnalysisMode = AnalysisMode.FULL

  /** Whether editor hosts should request inferred type hints. */
  var inlayHints: Boolean = true

  /** Whether editor hosts should request formatting support. */
  var formatting: Boolean = true

  /** Configures compiler/linter diagnostics and their refresh policy. */
  fun diagnostics(block: DiagnosticsScope.() -> Unit) = diagnosticsScope.apply(block)

  /** Configures workspace-wide analysis inputs. */
  fun workspace(block: WorkspaceScope.() -> Unit) = workspaceScope.apply(block)

  /** Configures analyzer worker limits. */
  fun performance(block: PerformanceScope.() -> Unit) = performanceScope.apply(block)

  /** Validates all nested scopes and returns an immutable configuration snapshot. */
  fun build() =
    AnalyzerConfiguration(
      validateAnalyzerVersion(version),
      analysisMode,
      diagnosticsScope.snapshot(),
      inlayHints,
      formatting,
      workspaceScope.snapshot(),
      performanceScope.snapshot(),
    )
}

/**
 * Builds a validated, immutable analyzer configuration from the Kotlin DSL.
 *
 * Each invocation uses a fresh scope, so mutable values from one project cannot leak into another.
 */
fun analyzerConfiguration(block: AnalyzerScope.() -> Unit = {}): AnalyzerConfiguration =
  AnalyzerScope().apply(block).build()

private val semanticVersion =
  Regex("(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?")

internal fun validateAnalyzerVersion(value: String): String {
  if (value == "latest" || semanticVersion.matches(value)) return value
  throw AnalyzerConfigurationException("version must be 'latest' or a semantic version: $value")
}
