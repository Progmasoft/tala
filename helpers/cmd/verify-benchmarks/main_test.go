// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVerifyBenchmarkIndexAcceptsIndexedReports(t *testing.T) {
	root := makeBenchmarkFixture(t, "2026-01-01-First.md", "2026-01-02-Second.md")

	count, err := verifyBenchmarkIndex(root)
	if err != nil {
		t.Fatalf("verifyBenchmarkIndex() returned error: %v", err)
	}
	if count != 2 {
		t.Fatalf("verifyBenchmarkIndex() count = %d, want 2", count)
	}
}

func TestVerifyBenchmarkIndexFindsUnindexedReport(t *testing.T) {
	root := makeBenchmarkFixture(t, "2026-01-01-First.md")
	if err := os.WriteFile(filepath.Join(root, "Benchmarks", "2026-01-02-Unindexed.md"), []byte("result\n"), 0o600); err != nil {
		t.Fatalf("write unindexed report: %v", err)
	}

	_, err := verifyBenchmarkIndex(root)
	if err == nil || !strings.Contains(err.Error(), "Benchmarks/2026-01-02-Unindexed.md is not indexed") {
		t.Fatalf("verifyBenchmarkIndex() error = %v, want unindexed report", err)
	}
}

func TestVerifyBenchmarkIndexFindsMissingAndDuplicateLinks(t *testing.T) {
	root := makeBenchmarkFixture(t, "2026-01-01-First.md")
	indexPath := filepath.Join(root, "Benchmarks", "README.md")
	content := "# Benchmarks\n\n- `2026-01-01-First.md` baseline\n- `2026-01-01-First.md` duplicate\n- `2026-01-03-Missing.md` stale\n"
	if err := os.WriteFile(indexPath, []byte(content), 0o600); err != nil {
		t.Fatalf("rewrite benchmark index: %v", err)
	}

	_, err := verifyBenchmarkIndex(root)
	if err == nil {
		t.Fatal("verifyBenchmarkIndex() accepted duplicate and stale links")
	}
	for _, expected := range []string{
		`repeats report "2026-01-01-First.md"`,
		`links "2026-01-03-Missing.md", but that report does not exist`,
	} {
		if !strings.Contains(err.Error(), expected) {
			t.Errorf("verifyBenchmarkIndex() error %q does not contain %q", err, expected)
		}
	}
}

func TestIndexedReportsRejectsPathTraversal(t *testing.T) {
	_, failures := indexedReports("# Benchmarks\n\n- `../outside.md` escape\n")
	if len(failures) != 1 || !strings.Contains(failures[0], "must link to a report filename") {
		t.Fatalf("indexedReports() failures = %v, want path traversal rejection", failures)
	}
}

func makeBenchmarkFixture(t *testing.T, reports ...string) string {
	t.Helper()
	root := t.TempDir()
	benchmarkRoot := filepath.Join(root, "Benchmarks")
	if err := os.MkdirAll(benchmarkRoot, 0o700); err != nil {
		t.Fatalf("create benchmark directory: %v", err)
	}
	var index strings.Builder
	index.WriteString("# Benchmark results\n\n")
	for _, report := range reports {
		if err := os.WriteFile(filepath.Join(benchmarkRoot, report), []byte("result\n"), 0o600); err != nil {
			t.Fatalf("write report %s: %v", report, err)
		}
		index.WriteString("- `" + report + "` result\n")
	}
	if err := os.WriteFile(filepath.Join(benchmarkRoot, "README.md"), []byte(index.String()), 0o600); err != nil {
		t.Fatalf("write benchmark index: %v", err)
	}
	return root
}
