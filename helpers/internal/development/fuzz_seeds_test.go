// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeSource(t *testing.T, repository string, relative string, text string) {
	t.Helper()
	path := filepath.Join(repository, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func seedNames(t *testing.T, corpus string) []string {
	t.Helper()
	entries, err := os.ReadDir(corpus)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names
}

func TestRepositorySourcesSeedTheSourceCorpora(t *testing.T) {
	repository := t.TempDir()
	writeSource(t, repository, "Examples/Hello/Hello.tala", "namespace Hello;")
	writeSource(t, repository, "Spec/Language/Sample.TALA", "namespace Sample;")
	writeSource(t, repository, "Talac/Core/Tests/a.tala", "namespace A;")
	// Not a source, outside the roots, empty, and longer than the target reads.
	writeSource(t, repository, "Examples/Hello/README.md", "namespace Hello;")
	writeSource(t, repository, "helpers/c.tala", "namespace C;")
	writeSource(t, repository, "Examples/Empty/Empty.tala", "")
	writeSource(t, repository, "Examples/Long/Long.tala", strings.Repeat("-", 65))

	corpus := t.TempDir()
	held, err := syncRepositorySources(repository, corpus, 64)
	if err != nil {
		t.Fatal(err)
	}
	names := seedNames(t, corpus)
	if held != 3 || len(names) != 3 {
		t.Fatalf("held %d seeds in %v, want the three sources under the roots", held, names)
	}
	for _, name := range names {
		if !strings.HasPrefix(name, "repository-") || !strings.HasSuffix(name, ".tala") {
			t.Fatalf("seed %q is not named after its content", name)
		}
	}
}

func TestRepositorySourcesAreAddedOnceAndNeverReplaced(t *testing.T) {
	repository := t.TempDir()
	writeSource(t, repository, "Examples/Hello/Hello.tala", "namespace Hello;")
	// The same text in two places is one seed.
	writeSource(t, repository, "Spec/Language/Hello.tala", "namespace Hello;")
	corpus := t.TempDir()
	// What a campaign learned stays whatever the repository holds.
	learned := filepath.Join(corpus, "0123456789abcdef")
	if err := os.WriteFile(learned, []byte("learned"), 0o600); err != nil {
		t.Fatal(err)
	}
	for round := 0; round < 2; round++ {
		held, err := syncRepositorySources(repository, corpus, 1024)
		if err != nil {
			t.Fatal(err)
		}
		if held != 2 {
			t.Fatalf("round %d met %d sources, want 2", round, held)
		}
	}
	if names := seedNames(t, corpus); len(names) != 2 {
		t.Fatalf("corpus holds %v, want the learned unit and one seed", names)
	}

	// A source that changes adds a seed; the seed of its old text stays.
	writeSource(t, repository, "Examples/Hello/Hello.tala", "namespace Changed;")
	if _, err := syncRepositorySources(repository, corpus, 1024); err != nil {
		t.Fatal(err)
	}
	if names := seedNames(t, corpus); len(names) != 3 {
		t.Fatalf("corpus holds %v, want three entries after a source changed", names)
	}
	if text, err := os.ReadFile(learned); err != nil || string(text) != "learned" {
		t.Fatalf("the learned unit was changed: %q, %v", text, err)
	}
}

func TestRepositorySourcesNeedNoRoot(t *testing.T) {
	held, err := syncRepositorySources(t.TempDir(), t.TempDir(), 1024)
	if err != nil || held != 0 {
		t.Fatalf("an empty repository gave %d seeds and %v", held, err)
	}
}

func TestOnlyTheSourceCorporaReadSourceText(t *testing.T) {
	reading := 0
	for _, target := range nativeFuzzTargets() {
		if readsSourceText(target.corpus) {
			reading++
		}
	}
	if reading != 3 || readsSourceText("wire") || readsSourceText("differential") || readsSourceText("cli") {
		t.Fatalf("%d targets read source text, want the lexer, the parser and the source target", reading)
	}
}
