/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talafmt.config

@DslMarker annotation class FormatterDsl

@FormatterDsl
class TabsScope {
  var width: Int = 4
  var useChars: Boolean = false

  internal fun snapshot() = TabsConfiguration(positive(width, "tabs.width"), useChars)
}

@FormatterDsl
class BeforeParensScope {
  var afterControlStmts: Boolean = false
  var afterFunctionDefinitionName: Boolean = false
  var afterFunctionDeclsName: Boolean = false
  var afterRequiresInClause: Boolean = false
  var beforeNonEmptyParentheses: Boolean = false

  internal fun snapshot() =
    BeforeParensConfiguration(
      afterControlStmts,
      afterFunctionDefinitionName,
      afterFunctionDeclsName,
      afterRequiresInClause,
      beforeNonEmptyParentheses,
    )
}

@FormatterDsl
class InParensScope {
  var inEmptyParentheses: Boolean = false
  var inConditionalStmts: Boolean = false
  var inFunctionCall: Boolean = false
  var inFunctionDecls: Boolean = false
  var inFunctionDefinition: Boolean = false

  internal fun snapshot() =
    InParensConfiguration(
      inEmptyParentheses,
      inConditionalStmts,
      inFunctionCall,
      inFunctionDecls,
      inFunctionDefinition,
    )
}

@FormatterDsl
class SpacingScope {
  private val beforeParensScope = BeforeParensScope()
  private val inParensScope = InParensScope()

  var beforeAssignmentOps: Boolean = true
  var beforeSemicolon: Boolean = false
  var beforeComma: Boolean = false
  var afterSemicolon: Boolean = true
  var afterComma: Boolean = true

  fun beforeParens(block: BeforeParensScope.() -> Unit) = beforeParensScope.apply(block)

  fun inParens(block: InParensScope.() -> Unit) = inParensScope.apply(block)

  internal fun snapshot() =
    SpacingConfiguration(
      beforeParensScope.snapshot(),
      inParensScope.snapshot(),
      beforeAssignmentOps,
      beforeSemicolon,
      beforeComma,
      afterSemicolon,
      afterComma,
    )
}

@FormatterDsl
class LineScope {
  var ending: LineEnding = LineEnding.AUTO
  var insertNewlineAtEof: Boolean = true

  internal fun snapshot() = LineConfiguration(ending, insertNewlineAtEof)
}

@FormatterDsl
class SortingScope {
  var enable: Boolean = true
  var autosort: Boolean = false

  internal fun snapshot() = SortingConfiguration(enable, autosort)
}

@FormatterDsl
class EncodingScope {
  var input: Encoding = Encoding.UTF_8
  var output: Encoding = Encoding.UTF_8
  var emitByteOrderMark: Boolean = false

  internal fun snapshot() = EncodingConfiguration(input, output, emitByteOrderMark)
}

/**
 * Typed state exposed as the receiver of `talafmt.kts`.
 *
 * Evaluation remains separate from the immutable model: one fresh receiver is created for every
 * script, and [build] validates the complete snapshot only after Kotlin execution succeeds.
 */
@FormatterDsl
open class FormatterScope {
  private val tabsScope = TabsScope()
  private val spacingScope = SpacingScope()
  private val lineScope = LineScope()
  private val sortingScope = SortingScope()
  private val encodingScope = EncodingScope()

  var version: String = "latest"
  var columnLimit: Int = 120
  var indentWidth: Int = 4
  var continuationIndentWidth: Int = 4
  var braceStyle: BraceStyle = BraceStyle.ALLMAN

  fun tabs(block: TabsScope.() -> Unit) = tabsScope.apply(block)

  fun spacing(block: SpacingScope.() -> Unit) = spacingScope.apply(block)

  fun line(block: LineScope.() -> Unit) = lineScope.apply(block)

  fun sorting(block: SortingScope.() -> Unit) = sortingScope.apply(block)

  fun encoding(block: EncodingScope.() -> Unit) = encodingScope.apply(block)

  fun build() =
    FormatterConfiguration(
      validateVersion(version),
      positive(columnLimit, "columnLimit"),
      positive(indentWidth, "indentWidth"),
      positive(continuationIndentWidth, "continuationIndentWidth"),
      tabsScope.snapshot(),
      braceStyle,
      spacingScope.snapshot(),
      lineScope.snapshot(),
      sortingScope.snapshot(),
      encodingScope.snapshot(),
    )
}

fun formatterConfiguration(block: FormatterScope.() -> Unit = {}): FormatterConfiguration =
  FormatterScope().apply(block).build()

private val semanticVersion =
  Regex("(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?")

internal fun validateVersion(value: String): String {
  if (value == "latest" || semanticVersion.matches(value)) return value
  throw FormatterConfigurationException("version must be 'latest' or a semantic version: $value")
}

internal fun positive(value: Int, field: String): Int {
  if (value > 0) return value
  throw FormatterConfigurationException("$field must be a positive integer")
}
