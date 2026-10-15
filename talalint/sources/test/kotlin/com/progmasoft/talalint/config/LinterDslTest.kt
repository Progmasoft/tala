/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talalint.config

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LinterDslTest {
  @Test
  fun exposesCompleteCanonicalRuleCatalog() {
    val configuration = linterConfiguration()

    assertEquals("latest", configuration.version)
    assertEquals(38, configuration.ruleGroups.size)
    assertEquals(391, configuration.ruleGroups.values.sumOf { it.rules.size })
    assertEquals(8, configuration.parameterizedRules.size)
    assertEquals(Severity.ERROR, configuration.severity("entry", "invalidMainSignature"))
    assertEquals(Severity.ERROR, configuration.severity("text", "invalidSourceUtf8"))
    assertEquals(Severity.OFF, configuration.severity("format", "sourceNotFormatted"))
    assertEquals(Severity.WARNING, configuration.severity("unsafe", "rawPointerPublicApi"))
    assertEquals(
      80,
      configuration.parameterizedRules.getValue("naming.maximumIdentifierLength").integers["value"],
    )
    assertEquals(emptyList(), configuration.stringSettings["naming.disallowedNames"])
  }

  @Test
  fun snapshotsTopLevelGroupsAndParameterizedRules() {
    val shortNames = mutableListOf("i", "j")
    val deniedNames = mutableListOf("tmp")
    val configuration = linterConfiguration {
      version = "0.1.0"
      maxDiagnostics = 100
      diagnosticOrder = DiagnosticOrder.SEVERITY
      showExplanationUrl = false
      fixes { applySafe = true }
      analysis { wholeProgram = true }
      naming {
        namespacePascalCase = Severity.ERROR
        minimumIdentifierLength { allowedShortNames = shortNames }
        disallowedNames = deniedNames
      }
      declarations { tooManyParameters { maxParameters = 6 } }
      `override` { signatureDrift = Severity.WARNING }
      maintenance { excessiveNesting { maxDepth = 7 } }
    }
    shortNames += "x"
    deniedNames += "scratch"

    assertEquals(100, configuration.maxDiagnostics)
    assertEquals(DiagnosticOrder.SEVERITY, configuration.diagnosticOrder)
    assertFalse(configuration.showExplanationUrl)
    assertTrue(configuration.fixes.applySafe)
    assertTrue(configuration.analysis.wholeProgram)
    assertEquals(Severity.ERROR, configuration.severity("naming", "namespacePascalCase"))
    assertEquals(Severity.WARNING, configuration.severity("override", "signatureDrift"))
    assertEquals(
      listOf("i", "j"),
      configuration.parameterizedRules
        .getValue("naming.minimumIdentifierLength")
        .strings
        .getValue("allowedShortNames"),
    )
    assertEquals(listOf("tmp"), configuration.stringSettings["naming.disallowedNames"])
    assertEquals(
      6,
      configuration.parameterizedRules
        .getValue("declarations.tooManyParameters")
        .integers["maxParameters"],
    )
    assertEquals(
      7,
      configuration.parameterizedRules
        .getValue("maintenance.excessiveNesting")
        .integers["maxDepth"],
    )
  }

  @Test
  fun rejectsInvalidValuesAtSnapshotBoundary() {
    assertFailsWith<LinterConfigurationException> {
      linterConfiguration { maxDiagnostics = -1 }
    }
    assertFailsWith<LinterConfigurationException> {
      linterConfiguration { declarations { largeTypeBody { maxMembers = 0 } } }
    }
    assertFailsWith<LinterConfigurationException> {
      linterConfiguration { version = "nightly" }
    }
  }
}
