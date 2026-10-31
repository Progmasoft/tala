// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package executioncases

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sample = `# A header that belongs to no case.

# First line.
# Second line.
body: return left + "\(";
run: plain 1 -2 -> 3
run: flags true false 0 0 -> -4

body: return right;
run: plain 0 7 -> 7
`

func TestParseReadsCommentsBodiesAndRuns(t *testing.T) {
	cases, err := Parse("sample", sample)
	if err != nil {
		t.Fatal(err)
	}
	if len(cases) != 2 {
		t.Fatalf("got %d cases", len(cases))
	}
	first := cases[0]
	if strings.Join(first.Comment, "|") != "First line.|Second line." {
		t.Errorf("comment: %q", first.Comment)
	}
	if first.Body != `return left + "\(";` {
		t.Errorf("body: %q", first.Body)
	}
	want := []Run{{Left: 1, Right: -2, Expected: 3}, {Flag: true, Expected: -4}}
	if len(first.Runs) != 2 || first.Runs[0] != want[0] || first.Runs[1] != want[1] {
		t.Errorf("runs: %+v", first.Runs)
	}
	if len(cases[1].Comment) != 0 {
		t.Errorf("the second case has no comment, got %q", cases[1].Comment)
	}
}

func TestParseRejectsMalformedFiles(t *testing.T) {
	for name, text := range map[string]string{
		"empty file":          "# nothing\n",
		"run before a body":   "run: plain 0 0 -> 0\n",
		"body without a run":  "body: return 0;\n",
		"unknown line":        "body: return 0;\nrun: plain 0 0 -> 0\nnote\n",
		"missing expectation": "body: return 0;\nrun: plain 0 0\n",
		"wrong arity":         "body: return 0;\nrun: plain 0 -> 0\n",
		"flag spelled wrong":  "body: return 0;\nrun: flags True false 0 0 -> 0\n",
		"not a number":        "body: return 0;\nrun: plain x 0 -> 0\n",
		"out of range":        "body: return 0;\nrun: plain 0 0 -> 4294967296\n",
		"repeated body":       "body: return 0;\nrun: plain 0 0 -> 0\n\nbody: return 0;\nrun: plain 1 0 -> 0\n",
		"comment before run":  "body: return 0;\n# stray\nrun: plain 0 0 -> 0\n",
		"empty body":          "body:  \nrun: plain 0 0 -> 0\n",
	} {
		if _, err := Parse(name, text); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestRenderingEscapesAndIsDeterministic(t *testing.T) {
	cases, err := Parse("sample", sample)
	if err != nil {
		t.Fatal(err)
	}
	table := Table{Source: "Cases/Sample.cases", Include: "Sample.inc", Binding: "sampleCases", Summary: "A sample.", Cases: cases}
	include := RenderInclude(table)
	for _, expected := range []string{
		"{ false, false, 1, -2, 3,\n  \"return left + \\\"\\\\(\\\";\" },\n",
		"{ true, false, 0, 0, -4,\n",
		"// First line.\n// Second line.\n",
		"Generated from Cases/Sample.cases",
	} {
		if !strings.Contains(include, expected) {
			t.Errorf("the include lacks %q:\n%s", expected, include)
		}
	}
	haskell := RenderHaskell([]Table{table})
	for _, expected := range []string{
		"    [ -- First line.\n      -- Second line.\n        ( \"return left + \\\"\\\\(\\\";\"\n",
		"        , [((False, False, 1, -2), 3), ((True, False, 0, 0), -4)]\n",
		"evaluationCases = sampleCases\n",
		"    ,\n        ( \"return right;\"\n",
	} {
		if !strings.Contains(haskell, expected) {
			t.Errorf("the module lacks %q:\n%s", expected, haskell)
		}
	}
	if include != RenderInclude(table) || haskell != RenderHaskell([]Table{table}) {
		t.Error("rendering the same table twice gave different text")
	}
}

// The committed tables must be what the committed case files generate. This
// is the check that keeps a table from being edited by hand or left behind.
func TestCommittedTablesAreCurrent(t *testing.T) {
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	stale, err := Stale(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(stale) != 0 {
		t.Fatalf("stale generated tables %v; run `go -C helpers run ./cmd/execution-cases generate`", stale)
	}
}

func TestWriteLeavesCurrentFilesAndRepairsStaleOnes(t *testing.T) {
	root := t.TempDir()
	for _, table := range tables() {
		path := filepath.Join(root, filepath.FromSlash(table.Source))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("body: return left;\nrun: plain 3 0 -> 3\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	written, err := Write(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(written) != len(tables())+1 {
		t.Fatalf("the first write wrote %v", written)
	}
	if again, err := Write(root); err != nil || len(again) != 0 {
		t.Fatalf("a second write wrote %v, %v", again, err)
	}
	// A checkout with the other line ending is still current.
	module := filepath.Join(root, filepath.FromSlash(HaskellModule))
	text, err := os.ReadFile(module)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(module, []byte(strings.ReplaceAll(string(text), "\n", "\r\n")), 0o644); err != nil {
		t.Fatal(err)
	}
	if stale, err := Stale(root); err != nil || len(stale) != 0 {
		t.Fatalf("a CRLF checkout is reported stale: %v, %v", stale, err)
	}
	if err := os.WriteFile(module, append(text, []byte("-- edited\n")...), 0o644); err != nil {
		t.Fatal(err)
	}
	stale, err := Stale(root)
	if err != nil || len(stale) != 1 || stale[0] != HaskellModule {
		t.Fatalf("an edited table is not reported: %v, %v", stale, err)
	}
}
