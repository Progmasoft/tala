// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeProbe struct {
	calls int
	fail  bool
}

func (p *fakeProbe) LookPath(name string) (string, error) {
	if name == "go" {
		return "/tools/go", nil
	}
	return "", errors.New("missing")
}
func (p *fakeProbe) Git(ctx context.Context, root string, args ...string) (string, error) {
	p.calls++
	if p.fail {
		return "", errors.New("secret stderr must never be included")
	}
	switch args[0] {
	case "branch":
		return "main", nil
	case "rev-parse":
		return "abcd", nil
	default:
		return " M tracked.go", nil
	}
}
func TestCollectMissingToolsAndTrackedChanges(t *testing.T) {
	p := &fakeProbe{}
	r := collect(context.Background(), "checkout", p)
	if r.Branch != "main" || r.Revision != "abcd" || !r.Dirty || p.calls != 3 {
		t.Fatalf("%+v", r)
	}
	if len(r.Tools) != 10 || !r.Tools[0].Available || r.Tools[1].Available {
		t.Fatal(r.Tools)
	}
}
func TestGitErrorsDoNotExposeSubprocessDetails(t *testing.T) {
	r := collect(context.Background(), "checkout", &fakeProbe{fail: true})
	if r.GitError == "" || strings.Contains(r.GitError, "secret") {
		t.Fatal(r)
	}
}
func TestJSONReportFromNestedDirectory(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "MODULE.bazel"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "nested")
	if err := os.Mkdir(nested, 0700); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := run([]string{"--root", nested, "--json"}, &out, &out, &fakeProbe{}); err != nil {
		t.Fatal(err)
	}
	var r report
	if err := json.Unmarshal(out.Bytes(), &r); err != nil {
		t.Fatal(err)
	}
	if r.Root != root || r.Revision != "abcd" {
		t.Fatalf("%+v", r)
	}
}
func TestHelpAndInvalidArgumentsNeverProbe(t *testing.T) {
	for _, args := range [][]string{{"--help"}, {"-h"}, {"--unknown"}, {"unexpected"}} {
		p := &fakeProbe{}
		_ = run(args, &bytes.Buffer{}, &bytes.Buffer{}, p)
		if p.calls != 0 {
			t.Fatal("Git executed")
		}
	}
}
