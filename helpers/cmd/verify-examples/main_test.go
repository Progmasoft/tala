// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVerifyExamplesAcceptsCompleteCatalog(t *testing.T) {
	root := makeExampleFixture(t, "Alpha", "Beta")

	count, err := verifyExamples(root)
	if err != nil {
		t.Fatalf("verifyExamples() returned error: %v", err)
	}
	if count != 2 {
		t.Fatalf("verifyExamples() count = %d, want 2", count)
	}
}

func TestVerifyExamplesReportsEveryMissingLanguage(t *testing.T) {
	root := makeExampleFixture(t, "Alpha")
	if err := os.Remove(filepath.Join(root, "Examples", "Alpha", "Alpha.rs")); err != nil {
		t.Fatalf("remove Rust fixture: %v", err)
	}

	_, err := verifyExamples(root)
	if err == nil || !strings.Contains(err.Error(), "Examples/Alpha/Alpha.rs is missing") {
		t.Fatalf("verifyExamples() error = %v, want missing Rust source", err)
	}
}

func TestVerifyExamplesReportsCatalogDriftAndWrongSourceName(t *testing.T) {
	root := makeExampleFixture(t, "Alpha")
	if err := os.WriteFile(filepath.Join(root, "Examples", "Alpha", "Other.cpp"), []byte("source"), 0o600); err != nil {
		t.Fatalf("write incorrectly named source: %v", err)
	}
	readme := filepath.Join(root, "Examples", "README.md")
	content, err := os.ReadFile(readme)
	if err != nil {
		t.Fatalf("read fixture README: %v", err)
	}
	content = append(content, []byte("| `CatalogOnly` | missing program |\n")...)
	if err := os.WriteFile(readme, content, 0o600); err != nil {
		t.Fatalf("add stale README row: %v", err)
	}

	_, err = verifyExamples(root)
	if err == nil {
		t.Fatal("verifyExamples() accepted catalogue drift and a mismatched filename")
	}
	for _, expected := range []string{
		`contains "Other.cpp"; source files must use the directory name`,
		`Examples/README.md lists "CatalogOnly", but Examples/CatalogOnly/ is missing`,
	} {
		if !strings.Contains(err.Error(), expected) {
			t.Errorf("verifyExamples() error %q does not contain %q", err, expected)
		}
	}
}

func TestReadCatalogProgramsIgnoresOtherMarkdownTables(t *testing.T) {
	markdown := "# Examples\n\n| Program | Surface |\n| --- | --- |\n| `Alpha` | loops |\n\n| `Other` | not a program row |\n| --- | --- |\n"
	programs, failures := readCatalogPrograms(markdown)
	if len(failures) != 0 {
		t.Fatalf("readCatalogPrograms() failures = %v, want none", failures)
	}
	if len(programs) != 1 {
		t.Fatalf("readCatalogPrograms() returned %v, want only the Program table", programs)
	}
	if _, found := programs["Alpha"]; !found {
		t.Fatalf("readCatalogPrograms() returned %v without Alpha", programs)
	}
}

func TestValidProgramNameRequiresASCIICaseSensitiveIdentifier(t *testing.T) {
	for _, name := range []string{"HelloWorld", "MatrixTranspose2", "GCD"} {
		if !validProgramName(name) {
			t.Errorf("validProgramName(%q) = false, want true", name)
		}
	}
	for _, name := range []string{"", "2Fast", "hello-world", "GCD_2", "Şekil"} {
		if validProgramName(name) {
			t.Errorf("validProgramName(%q) = true, want false", name)
		}
	}
}

func makeExampleFixture(t *testing.T, programs ...string) string {
	t.Helper()
	root := t.TempDir()
	var rows strings.Builder
	rows.WriteString("# Comparative examples\n\n| Program | Surface |\n| --- | --- |\n")
	for _, program := range programs {
		rows.WriteString("| `" + program + "` | fixture |\n")
		programRoot := filepath.Join(root, "Examples", program)
		if err := os.MkdirAll(programRoot, 0o700); err != nil {
			t.Fatalf("create %s: %v", program, err)
		}
		for _, extension := range comparativeSourceExtensions {
			path := filepath.Join(programRoot, program+extension)
			if err := os.WriteFile(path, []byte("source\n"), 0o600); err != nil {
				t.Fatalf("write %s: %v", path, err)
			}
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "Examples"), 0o700); err != nil {
		t.Fatalf("create Examples/: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "Examples", "README.md"), []byte(rows.String()), 0o600); err != nil {
		t.Fatalf("write fixture README: %v", err)
	}
	return root
}
