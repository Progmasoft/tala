/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.driver

import com.progmasoft.tazel.dsl.CompilerSettings

/** What one run of the compiler leaves behind. */
enum class Emit(
  val value: String,
  val extension: String?,
) {
  /** A program of the host; its extension is the host's and is not written here. */
  EXECUTABLE("executable", null),

  /** The record of a check: every verifier ran and no code was generated. */
  METADATA("metadata", ".talameta"),
}

/**
 * The arguments of one compiler run.
 *
 * Every setting of the project is written out, the ones at their default too: what the compiler
 * does then follows from the project file alone and not from the defaults of the compiler that
 * happens to be installed.
 */
fun compilerArguments(
  settings: CompilerSettings,
  entry: String,
  emit: Emit,
  inputs: List<String>,
): List<String> = buildList {
  add("--entry=$entry")
  add("--emit=${emit.value}")
  add("--standard=${settings.standard}")
  add("--codegen-backend=${settings.backend.name.lowercase()}")
  add("--warnings=${settings.warnings.name.lowercase()}")
  if (settings.shadowWarnings) add("--warnings=shadow")
  add("--warnings-as-errors=${settings.warningsAsErrors}")
  add("--opt-level=${settings.effectiveOptLevel.name.removePrefix("O").lowercase()}")
  add("--xpp-optimization-passes=${settings.xppOptimizationPasses}")
  add("--xmm-optimization-passes=${settings.xmmOptimizationPasses}")
  add("--llvm-compiler=${settings.llvmCompiler.name.lowercase()}")
  add("--llvm-lto=${settings.llvmLto.name.lowercase()}")
  if (settings.llvmArguments.isNotEmpty()) {
    add("--llvm-args=${settings.llvmArguments.joinToString(",")}")
  }
  // A source may be named like an option; after "--" the compiler reads only inputs.
  add("--")
  addAll(inputs)
}
