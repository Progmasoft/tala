/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tala.analyzer.config

/** Compiler frontend boundary at which editor analysis stops. */
enum class AnalysisMode {
  /** Tokenizes and parses source documents. */
  SYNTAX,

  /** Runs syntax analysis and name/type semantic checks. */
  SEMANTIC,

  /** Runs the complete currently connected frontend through CorePrep. */
  FULL,
}

/** Immutable switches controlling diagnostic producers and refresh events. */
data class DiagnosticsConfiguration(
  /** Enables compiler diagnostics. */
  val compiler: Boolean,
  /** Enables talalint diagnostics. */
  val linter: Boolean,
  /** Recomputes diagnostics after document edits. */
  val onChange: Boolean,
  /** Recomputes diagnostics after document saves. */
  val onSave: Boolean,
)

/** Immutable project-wide analysis settings. */
data class WorkspaceConfiguration(
  /** Includes dependency sources in workspace indexing when supported. */
  val indexDependencies: Boolean
)

/** Immutable concurrency settings. */
data class PerformanceConfiguration(
  /** Requested worker count, where zero means automatic runtime selection. */
  val workerThreads: Int
)

/**
 * Immutable configuration produced by the typed analyzer DSL.
 *
 * Instances are snapshots: subsequent mutations to a DSL scope do not alter a built value.
 */
data class AnalyzerConfiguration(
  /** Analyzer tool version or the `latest` selector. */
  val version: String,
  /** Frontend analysis boundary. */
  val analysisMode: AnalysisMode,
  /** Diagnostic sources and update events. */
  val diagnostics: DiagnosticsConfiguration,
  /** Enables editor type hints. */
  val inlayHints: Boolean,
  /** Enables editor formatting support. */
  val formatting: Boolean,
  /** Workspace source and dependency policy. */
  val workspace: WorkspaceConfiguration,
  /** Analyzer concurrency policy. */
  val performance: PerformanceConfiguration,
)

/** Thrown when a DSL value is invalid or cannot be represented by the analyzer model. */
class AnalyzerConfigurationException(message: String) : IllegalArgumentException(message)
