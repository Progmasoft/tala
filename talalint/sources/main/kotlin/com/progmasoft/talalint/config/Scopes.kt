/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talalint.config

import kotlin.properties.PropertyDelegateProvider
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

@DslMarker annotation class LinterDsl

@LinterDsl
abstract class RuleGroupScope {
  private val values = linkedMapOf<String, Severity>()

  protected fun severity(
    default: Severity
  ): PropertyDelegateProvider<Any?, ReadWriteProperty<Any?, Severity>> =
    PropertyDelegateProvider { _, property ->
      values[property.name] = default
      object : ReadWriteProperty<Any?, Severity> {
        override fun getValue(thisRef: Any?, property: KProperty<*>): Severity =
          values.getValue(property.name)

        override fun setValue(thisRef: Any?, property: KProperty<*>, value: Severity) {
          values[property.name] = value
        }
      }
    }

  internal fun snapshot(): RuleGroupConfiguration = RuleGroupConfiguration(values.toMap())
}

@LinterDsl
class FixesScope {
  var emitSuggestions: Boolean = true
  var applySafe: Boolean = false
  var applyUnsafe: Boolean = false

  internal fun snapshot() = FixesConfiguration(emitSuggestions, applySafe, applyUnsafe)
}

@LinterDsl
class AnalysisScope {
  var generatedFiles: Boolean = false
  var inactiveDirectiveBranches: Boolean = false
  var followProjectDependencies: Boolean = true
  var wholeProgram: Boolean = false

  internal fun snapshot() =
    AnalysisConfiguration(
      generatedFiles,
      inactiveDirectiveBranches,
      followProjectDependencies,
      wholeProgram,
    )
}

@LinterDsl
class RulesScope {
  var unknownRulePolicy: UnknownRulePolicy = UnknownRulePolicy.ERROR
  var deprecatedRulePolicy: DeprecatedRulePolicy = DeprecatedRulePolicy.WARNING

  internal fun snapshot() = RulePolicyConfiguration(unknownRulePolicy, deprecatedRulePolicy)
}

@LinterDsl
class SuppressionsScope {
  var requireReason: Boolean = false
  var reportUnused: Boolean = true
  var reportDuplicate: Boolean = true

  internal fun snapshot() = SuppressionConfiguration(requireReason, reportUnused, reportDuplicate)
}

@LinterDsl
class BaselineScope {
  var mode: BaselineMode = BaselineMode.OFF
  var newCodeOnly: Boolean = false

  internal fun snapshot() = BaselineConfiguration(mode, newCodeOnly)
}

@LinterDsl
abstract class ParameterizedRuleScope(private val field: String) {
  var severity: Severity = Severity.OFF

  protected fun positive(value: Int, parameter: String): Int {
    if (value > 0) return value
    throw LinterConfigurationException("$field.$parameter must be a positive integer")
  }
}

class MaximumIdentifierLengthScope : ParameterizedRuleScope("naming.maximumIdentifierLength") {
  var value: Int = 80

  internal fun snapshot() =
    ParameterizedRuleConfiguration(severity, integers = mapOf("value" to positive(value, "value")))
}

class MinimumIdentifierLengthScope : ParameterizedRuleScope("naming.minimumIdentifierLength") {
  var value: Int = 2
  var allowedShortNames: List<String> = listOf("i", "j", "x", "y", "T")

  internal fun snapshot() =
    ParameterizedRuleConfiguration(
      severity,
      integers = mapOf("value" to positive(value, "value")),
      strings = mapOf("allowedShortNames" to allowedShortNames.toList()),
    )
}

class LargeTypeBodyScope : ParameterizedRuleScope("declarations.largeTypeBody") {
  var maxMembers: Int = 50

  internal fun snapshot() =
    ParameterizedRuleConfiguration(
      severity,
      integers = mapOf("maxMembers" to positive(maxMembers, "maxMembers")),
    )
}

class TooManyParametersScope : ParameterizedRuleScope("declarations.tooManyParameters") {
  var maxParameters: Int = 8

  internal fun snapshot() =
    ParameterizedRuleConfiguration(
      severity,
      integers = mapOf("maxParameters" to positive(maxParameters, "maxParameters")),
    )
}

class ExcessiveNestingScope : ParameterizedRuleScope("maintenance.excessiveNesting") {
  init {
    severity = Severity.WARNING
  }

  var maxDepth: Int = 5

  internal fun snapshot() =
    ParameterizedRuleConfiguration(
      severity,
      integers = mapOf("maxDepth" to positive(maxDepth, "maxDepth")),
    )
}

class FunctionComplexityScope : ParameterizedRuleScope("maintenance.functionComplexity") {
  init {
    severity = Severity.WARNING
  }

  var maxComplexity: Int = 15

  internal fun snapshot() =
    ParameterizedRuleConfiguration(
      severity,
      integers = mapOf("maxComplexity" to positive(maxComplexity, "maxComplexity")),
    )
}

class FunctionLengthScope : ParameterizedRuleScope("maintenance.functionLength") {
  var maxStatements: Int = 100

  internal fun snapshot() =
    ParameterizedRuleConfiguration(
      severity,
      integers = mapOf("maxStatements" to positive(maxStatements, "maxStatements")),
    )
}

class TypeMemberCountScope : ParameterizedRuleScope("maintenance.typeMemberCount") {
  var maxMembers: Int = 50

  internal fun snapshot() =
    ParameterizedRuleConfiguration(
      severity,
      integers = mapOf("maxMembers" to positive(maxMembers, "maxMembers")),
    )
}
