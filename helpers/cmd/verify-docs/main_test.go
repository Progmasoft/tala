// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import "testing"

func TestParseCoverageRequiresHaddockSummary(t *testing.T) {
	t.Parallel()
	if _, err := parseCoverage("documentation built without a coverage report"); err == nil {
		t.Fatal("expected a missing coverage report to fail")
	}
}

func TestParseCoverageReadsAllModuleCounts(t *testing.T) {
	t.Parallel()
	output := "Haddock coverage:\n  100% ( 4 / 4) in 'Progmasoft.Tala.One'\n  50% ( 1 / 2) in 'Progmasoft.Tala.Two'\n"
	coverage, err := parseCoverage(output)
	if err != nil {
		t.Fatalf("parseCoverage returned an error: %v", err)
	}
	if len(coverage) != 2 || coverage[0].module != "Progmasoft.Tala.One" || coverage[1].documented != 1 {
		t.Fatalf("unexpected parsed coverage: %#v", coverage)
	}
}

func TestIncompletePublicCoverageFails(t *testing.T) {
	t.Parallel()
	coverage := []moduleCoverage{{module: "Progmasoft.Tala.AST", documented: 4, exported: 5}}
	if err := requireCompleteCoverage("tala-syntax", coverage); err == nil {
		t.Fatal("expected undocumented public declarations to fail")
	}
}

func TestCompletePublicCoveragePasses(t *testing.T) {
	t.Parallel()
	coverage := []moduleCoverage{{module: "Progmasoft.Tala.Lexer", documented: 5, exported: 5}}
	if err := requireCompleteCoverage("tala-syntax", coverage); err != nil {
		t.Fatalf("complete API documentation was rejected: %v", err)
	}
}
