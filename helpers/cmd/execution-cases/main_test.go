// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Progmasoft/tala/helpers/internal/executioncases"
)

// repository creates a root that holds case files and nothing generated.
func repository(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, name := range []string{"Selection.cases", "Leaving.cases"} {
		path := filepath.Join(root, "Talac", "Fuzzing", "Cases", name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("body: return left;\nrun: plain 3 0 -> 3\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func run(t *testing.T, arguments ...string) (string, string, error) {
	t.Helper()
	var output, problems bytes.Buffer
	command := newCommand(&output, &problems)
	command.SetArgs(arguments)
	err := command.Execute()
	return output.String(), problems.String(), err
}

func TestCheckFailsUntilGenerateHasRun(t *testing.T) {
	root := repository(t)
	_, problems, err := run(t, "check", "--root", root)
	if err == nil {
		t.Fatal("check passed without generated tables")
	}
	if !strings.Contains(problems, "stale: "+executioncases.HaskellModule) {
		t.Errorf("the missing module is not named: %q", problems)
	}

	output, _, err := run(t, "generate", "--root", root)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(output, "wrote ") != 3 {
		t.Errorf("generate reported %q", output)
	}
	if output, _, err = run(t, "check", "--root", root); err != nil || !strings.Contains(output, "current") {
		t.Fatalf("check after generate: %q, %v", output, err)
	}
	if output, _, err = run(t, "generate", "--root", root); err != nil || strings.Contains(output, "wrote ") {
		t.Fatalf("a second generate wrote again: %q, %v", output, err)
	}
}

func TestCheckReportsAnEditedTableAndABrokenCaseFile(t *testing.T) {
	root := repository(t)
	if _, _, err := run(t, "generate", "--root", root); err != nil {
		t.Fatal(err)
	}
	include := filepath.Join(root, "Talac", "Fuzzing", "Generated", "LeavingCases.inc")
	if err := os.WriteFile(include, []byte("// edited by hand\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, problems, err := run(t, "check", "--root", root)
	if err == nil || !strings.Contains(problems, "LeavingCases.inc") || strings.Contains(problems, "SelectionCases.inc") {
		t.Fatalf("the edited table alone must be reported: %q, %v", problems, err)
	}

	cases := filepath.Join(root, "Talac", "Fuzzing", "Cases", "Leaving.cases")
	if err := os.WriteFile(cases, []byte("body: return left;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "generate", "--root", root); err == nil || !strings.Contains(err.Error(), "has no run") {
		t.Fatalf("a body without a run must stop generation: %v", err)
	}
}

func TestPositionalArgumentsAreRejected(t *testing.T) {
	if _, _, err := run(t, "check", "extra"); err == nil {
		t.Fatal("check accepted a positional argument")
	}
}
