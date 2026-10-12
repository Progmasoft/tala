/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talafmt.config

import java.io.File
import kotlin.script.experimental.annotations.KotlinScript
import kotlin.script.experimental.api.ScriptCompilationConfiguration
import kotlin.script.experimental.api.ScriptDiagnostic
import kotlin.script.experimental.api.ScriptEvaluationConfiguration
import kotlin.script.experimental.api.baseClass
import kotlin.script.experimental.api.defaultImports
import kotlin.script.experimental.api.valueOrNull
import kotlin.script.experimental.host.toScriptSource
import kotlin.script.experimental.jvm.dependenciesFromCurrentContext
import kotlin.script.experimental.jvm.jvm
import kotlin.script.experimental.jvmhost.BasicJvmScriptingHost

@KotlinScript(
  fileExtension = "Formatter.kts",
  compilationConfiguration = FormatterScriptCompilationConfiguration::class,
)
abstract class FormatterScript : FormatterScope()

object FormatterScriptCompilationConfiguration :
  ScriptCompilationConfiguration({
    baseClass(FormatterScript::class)
    defaultImports("com.progmasoft.talafmt.config.*")
    jvm { dependenciesFromCurrentContext(wholeClasspath = true) }
  })

class FormatterEvaluationException(message: String) : IllegalArgumentException(message)

fun evaluateFormatterScript(script: File): FormatterConfiguration {
  val result =
    BasicJvmScriptingHost()
      .eval(
        script.toScriptSource(),
        FormatterScriptCompilationConfiguration,
        ScriptEvaluationConfiguration.Default,
      )
  val instance = result.valueOrNull()?.returnValue?.scriptInstance as? FormatterScript
  if (instance != null) return instance.build()

  val diagnostics =
    result.reports
      .filter { it.severity >= ScriptDiagnostic.Severity.ERROR }
      .joinToString("; ") { it.message }
      .ifBlank { "script evaluation did not produce a formatter configuration" }
  throw FormatterEvaluationException(diagnostics)
}
