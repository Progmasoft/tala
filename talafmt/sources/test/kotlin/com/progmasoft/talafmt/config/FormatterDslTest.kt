/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talafmt.config

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FormatterDslTest {
  @Test
  fun exposesCanonicalDefaults() {
    val configuration = formatterConfiguration()

    assertEquals("latest", configuration.version)
    assertEquals(120, configuration.columnLimit)
    assertEquals(BraceStyle.ALLMAN, configuration.braceStyle)
    assertEquals(LineEnding.AUTO, configuration.line.ending)
    assertEquals(Encoding.UTF_8, configuration.encoding.input)
    assertTrue(configuration.spacing.beforeAssignmentOps)
    assertFalse(configuration.tabs.useChars)
  }

  @Test
  fun snapshotsEveryNestedScope() {
    val configuration = formatterConfiguration {
      version = "0.1.0"
      columnLimit = 100
      braceStyle = BraceStyle.STROUSTRUP
      tabs {
        width = 8
        useChars = true
      }
      spacing {
        beforeParens { afterControlStmts = true }
        inParens { inFunctionCall = true }
        afterComma = false
      }
      line { ending = LineEnding.CRLF }
      sorting { autosort = true }
      encoding {
        output = Encoding.UTF_16
        emitByteOrderMark = true
      }
    }

    assertEquals(8, configuration.tabs.width)
    assertTrue(configuration.spacing.beforeParens.afterControlStmts)
    assertTrue(configuration.spacing.inParens.inFunctionCall)
    assertFalse(configuration.spacing.afterComma)
    assertEquals(LineEnding.CRLF, configuration.line.ending)
    assertTrue(configuration.sorting.autosort)
    assertEquals(Encoding.UTF_16, configuration.encoding.output)
    assertTrue(configuration.encoding.emitByteOrderMark)
  }

  @Test
  fun rejectsInvalidScalarValuesAtSnapshotBoundary() {
    assertFailsWith<FormatterConfigurationException> {
      formatterConfiguration { indentWidth = 0 }
    }
    assertFailsWith<FormatterConfigurationException> {
      formatterConfiguration { version = "development" }
    }
  }

  @Test
  fun evaluatesTheRealKotlinReceiver() {
    val directory = Files.createTempDirectory("talafmt-script-").toFile()
    try {
      val script = File(directory, "talafmt.kts")
      script.writeText(
        """
        val wide = 16
        indentWidth = wide / 2
        encoding {
          input = Encoding.UTF_16
          output = if (wide == 16) Encoding.UTF_32 else Encoding.UTF_8
          emitByteOrderMark = true
        }
        """
          .trimIndent()
      )

      val configuration = evaluateFormatterScript(script)
      assertEquals(8, configuration.indentWidth)
      assertEquals(Encoding.UTF_16, configuration.encoding.input)
      assertEquals(Encoding.UTF_32, configuration.encoding.output)
      assertTrue(configuration.encoding.emitByteOrderMark)
    } finally {
      directory.deleteRecursively()
    }
  }
}
