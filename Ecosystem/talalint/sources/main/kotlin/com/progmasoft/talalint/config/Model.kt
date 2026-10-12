/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talalint.config

enum class Severity {
  OFF,
  INFO,
  WARNING,
  ERROR,
}

enum class DiagnosticOrder {
  SOURCE,
  SEVERITY,
  RULE,
}

enum class UnknownRulePolicy {
  IGNORE,
  WARNING,
  ERROR,
}

enum class DeprecatedRulePolicy {
  IGNORE,
  WARNING,
  ERROR,
}

enum class BaselineMode {
  OFF,
  READ,
  UPDATE,
}

data class FixesConfiguration(
  val emitSuggestions: Boolean,
  val applySafe: Boolean,
  val applyUnsafe: Boolean,
)

data class AnalysisConfiguration(
  val generatedFiles: Boolean,
  val inactiveDirectiveBranches: Boolean,
  val followProjectDependencies: Boolean,
  val wholeProgram: Boolean,
)

data class RulePolicyConfiguration(
  val unknownRulePolicy: UnknownRulePolicy,
  val deprecatedRulePolicy: DeprecatedRulePolicy,
)

data class SuppressionConfiguration(
  val requireReason: Boolean,
  val reportUnused: Boolean,
  val reportDuplicate: Boolean,
)

data class BaselineConfiguration(val mode: BaselineMode, val newCodeOnly: Boolean)

data class RuleGroupConfiguration(val rules: Map<String, Severity>) {
  operator fun get(rule: String): Severity? = rules[rule]
}

data class ParameterizedRuleConfiguration(
  val severity: Severity,
  val integers: Map<String, Int> = emptyMap(),
  val strings: Map<String, List<String>> = emptyMap(),
)

/** Immutable configuration produced by the typed linter DSL. */
data class LinterConfiguration(
  val version: String,
  val defaultSeverity: Severity,
  val maxDiagnostics: Int,
  val diagnosticOrder: DiagnosticOrder,
  val showRuleId: Boolean,
  val showExplanationUrl: Boolean,
  val fixes: FixesConfiguration,
  val analysis: AnalysisConfiguration,
  val rules: RulePolicyConfiguration,
  val suppressions: SuppressionConfiguration,
  val baseline: BaselineConfiguration,
  val ruleGroups: Map<String, RuleGroupConfiguration>,
  val parameterizedRules: Map<String, ParameterizedRuleConfiguration>,
  val stringSettings: Map<String, List<String>>,
) {
  fun severity(group: String, rule: String): Severity? = ruleGroups[group]?.get(rule)
}

class LinterConfigurationException(message: String) : IllegalArgumentException(message)
