// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package repository

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFindRootFromNestedCommand(t *testing.T) {
	root := t.TempDir()
	nested := filepath.Join(root, "helpers", "cmd", "develop")
	if err := os.MkdirAll(nested, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "MODULE.bazel"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	got, err := FindRoot(nested)
	if err != nil || got != root {
		t.Fatalf("%q %v", got, err)
	}
}
func TestFindRootRejectsMissingOrDirectoryMarker(t *testing.T) {
	root := t.TempDir()
	if _, err := FindRoot(root); err == nil {
		t.Fatal("missing marker accepted")
	}
	if err := os.Mkdir(filepath.Join(root, "MODULE.bazel"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := FindRoot(root); err == nil {
		t.Fatal("directory marker accepted")
	}
}
