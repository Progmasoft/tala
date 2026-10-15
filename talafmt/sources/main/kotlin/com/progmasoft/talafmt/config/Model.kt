/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talafmt.config

enum class BraceStyle {
  ALLMAN,
  ATTACH,
  STROUSTRUP,
  WHITESMITHS,
}

enum class LineEnding {
  AUTO,
  CRLF,
  LF,
}

enum class Encoding {
  UTF_8,
  UTF_16,
  UTF_32,
}

data class TabsConfiguration(val width: Int, val useChars: Boolean)

data class BeforeParensConfiguration(
  val afterControlStmts: Boolean,
  val afterFunctionDefinitionName: Boolean,
  val afterFunctionDeclsName: Boolean,
  val afterRequiresInClause: Boolean,
  val beforeNonEmptyParentheses: Boolean,
)

data class InParensConfiguration(
  val inEmptyParentheses: Boolean,
  val inConditionalStmts: Boolean,
  val inFunctionCall: Boolean,
  val inFunctionDecls: Boolean,
  val inFunctionDefinition: Boolean,
)

data class SpacingConfiguration(
  val beforeParens: BeforeParensConfiguration,
  val inParens: InParensConfiguration,
  val beforeAssignmentOps: Boolean,
  val beforeSemicolon: Boolean,
  val beforeComma: Boolean,
  val afterSemicolon: Boolean,
  val afterComma: Boolean,
)

data class LineConfiguration(val ending: LineEnding, val insertNewlineAtEof: Boolean)

data class SortingConfiguration(val enable: Boolean, val autosort: Boolean)

data class EncodingConfiguration(
  val input: Encoding,
  val output: Encoding,
  val emitByteOrderMark: Boolean,
)

/** Immutable result of the formatter DSL. It contains configuration only. */
data class FormatterConfiguration(
  val version: String,
  val columnLimit: Int,
  val indentWidth: Int,
  val continuationIndentWidth: Int,
  val tabs: TabsConfiguration,
  val braceStyle: BraceStyle,
  val spacing: SpacingConfiguration,
  val line: LineConfiguration,
  val sorting: SortingConfiguration,
  val encoding: EncodingConfiguration,
)

class FormatterConfigurationException(message: String) : IllegalArgumentException(message)
