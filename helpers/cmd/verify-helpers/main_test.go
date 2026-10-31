// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixtureHeader = "// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>\n// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0\n"

func fixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	d := filepath.Join(root, "helpers", "cmd", "example")
	if err := os.MkdirAll(d, 0700); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(root, "helpers", "go.mod"), "module "+moduleName+"\n\ngo 1.26.0\n")
	write(t, filepath.Join(d, "main.go"), fixtureHeader+"\npackage main\nfunc main(){}\n")
	write(t, filepath.Join(d, "main_test.go"), fixtureHeader+"\npackage main\n")
	return root
}
func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
}

type fakeRunner struct {
	calls               []string
	failure, formatting string
}

func (r *fakeRunner) Run(directory, command string, args ...string) ([]byte, error) {
	key := command + " " + strings.Join(args, " ")
	r.calls = append(r.calls, key)
	if r.failure != "" && strings.Contains(key, r.failure) {
		return []byte("gate diagnostic"), errors.New("failed")
	}
	if command == "gofmt" {
		return []byte(r.formatting), nil
	}
	return nil, nil
}
func TestInventoryIncludesPackageTests(t *testing.T) {
	files, n, err := inventory(fixture(t))
	if err != nil || len(files) != 2 || n != 1 {
		t.Fatalf("%v %d %v", files, n, err)
	}
}
func TestInventoryRejectsInvalidLayout(t *testing.T) {
	for _, problem := range []string{"root-module", "wrong-module", "missing-test", "wrong-package", "missing-license", "too-long"} {
		t.Run(problem, func(t *testing.T) {
			root := fixture(t)
			d := filepath.Join(root, "helpers", "cmd", "example")
			switch problem {
			case "root-module":
				write(t, filepath.Join(root, "go.mod"), "module obsolete\n")
			case "wrong-module":
				write(t, filepath.Join(root, "helpers", "go.mod"), "module obsolete\n")
			case "missing-test":
				if err := os.Remove(filepath.Join(d, "main_test.go")); err != nil {
					t.Fatal(err)
				}
			case "wrong-package":
				write(t, filepath.Join(d, "main.go"), fixtureHeader+"\npackage other\n")
			case "missing-license":
				write(t, filepath.Join(d, "main.go"), "package main\n")
			case "too-long":
				write(t, filepath.Join(d, "main.go"), fixtureHeader+"\npackage main\n"+strings.Repeat("// line\n", 1500))
			}
			if _, _, err := inventory(root); err == nil {
				t.Fatal("invalid layout accepted")
			}
		})
	}
}
func TestVerificationRunsModuleWideGates(t *testing.T) {
	r := &fakeRunner{}
	var out bytes.Buffer
	if err := verify([]string{"--root", fixture(t)}, &out, &out, r); err != nil {
		t.Fatal(err)
	}
	if len(r.calls) != 4 || r.calls[1] != "go mod verify" || r.calls[2] != "go vet ./..." || r.calls[3] != "go test ./..." {
		t.Fatal(r.calls)
	}
}
func TestVerificationPropagatesEachFailure(t *testing.T) {
	for _, gate := range []string{"gofmt", "mod verify", "vet", "test"} {
		t.Run(gate, func(t *testing.T) {
			r := &fakeRunner{failure: gate}
			err := verify([]string{"--root", fixture(t)}, &bytes.Buffer{}, &bytes.Buffer{}, r)
			if err == nil || !strings.Contains(err.Error(), "gate diagnostic") {
				t.Fatal(err)
			}
		})
	}
}
func TestFormattingFailureStopsExecution(t *testing.T) {
	r := &fakeRunner{formatting: "unformatted.go"}
	if err := verify([]string{"--root", fixture(t)}, &bytes.Buffer{}, &bytes.Buffer{}, r); err == nil || len(r.calls) != 1 {
		t.Fatalf("%v %v", err, r.calls)
	}
}
func TestHelpAndInvalidArgumentsNeverRunTools(t *testing.T) {
	for _, args := range [][]string{{"--help"}, {"unexpected"}, {"--unknown"}} {
		r := &fakeRunner{}
		_ = verify(args, &bytes.Buffer{}, &bytes.Buffer{}, r)
		if len(r.calls) != 0 {
			t.Fatal(r.calls)
		}
	}
}
func TestInventoryRejectsSymlink(t *testing.T) {
	root := fixture(t)
	if err := os.Symlink(t.TempDir(), filepath.Join(root, "helpers", "external")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if _, _, err := inventory(root); err == nil {
		t.Fatal("symlink accepted")
	}
}
