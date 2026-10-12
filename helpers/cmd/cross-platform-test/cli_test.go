// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/Progmasoft/tala/helpers/internal/crossplatform"
)

// idleEngine fails the test when anything is started.
type idleEngine struct{ t *testing.T }

func (engine idleEngine) LookPath(name string) (string, error) {
	engine.t.Fatalf("looked for %s", name)
	return "", errors.New("unreachable")
}

func (engine idleEngine) Output(directory string, name string, arguments ...string) (string, error) {
	engine.t.Fatalf("ran %s", name)
	return "", errors.New("unreachable")
}

func (engine idleEngine) Run(directory string, input io.Reader, output io.Writer, errorOutput io.Writer, name string, arguments ...string) error {
	engine.t.Fatalf("ran %s", name)
	return errors.New("unreachable")
}

func execute(t *testing.T, host string, arguments ...string) (string, error) {
	t.Helper()
	var output bytes.Buffer
	command := newCommand(idleEngine{t}, host, &output, &output)
	command.SetArgs(arguments)
	err := command.Execute()
	return output.String(), err
}

func TestHelpAndListingsStartNothing(t *testing.T) {
	for _, arguments := range [][]string{{}, {"--help"}, {"run", "--help"}, {"ci", "--help"}, {"ci", "--list"}, {"targets"}, {"suites"}} {
		output, err := execute(t, "windows", arguments...)
		if err != nil || output == "" {
			t.Fatalf("%v: %q, %v", arguments, output, err)
		}
	}
}

func TestTargetsListWhatTheHostCannotRunWithTheReason(t *testing.T) {
	output, err := execute(t, "windows", "targets")
	if err != nil || !strings.Contains(output, "ubuntu-26.04") || !strings.Contains(output, "macos") || !strings.Contains(output, "Apple") {
		t.Fatalf("listing on Windows: %q, %v", output, err)
	}
	if strings.Contains(output, "windows ") {
		t.Fatalf("the host's own platform is listed: %q", output)
	}
	output, err = execute(t, "darwin", "targets", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var targets []crossplatform.Target
	if err := json.Unmarshal([]byte(output), &targets); err != nil || len(targets) != 3 || targets[2].Name != "windows" || targets[2].Reason == "" {
		t.Fatalf("listing on macOS: %+v, %v", targets, err)
	}
}

func TestAnInvocationThatIsNotUnderstoodStartsNothing(t *testing.T) {
	cases := [][]string{
		{"run", "--target", "macos"},
		{"run", "--target", "solaris"},
		{"run", "--suite", "everything"},
		{"run", "--suite", "helpers", "--command", "true"},
		{"run", "--command", "  "},
		{"run", "--jobs", "0"},
		{"ci", "--target", "solaris"},
		{"ci", "--target", " , "},
		{"ci", "extra"},
		{"run", "--cpus", "0"},
		{"run", "--memory", "lots"},
		{"run", "--memory", "0g"},
		{"clean", "extra"},
		{"usage", "extra"},
		{"run", "extra"},
		{"targets", "extra"},
		{"-Help"},
		{"unknown"},
	}
	for _, arguments := range cases {
		if _, err := execute(t, "windows", arguments...); err == nil {
			t.Fatalf("%v was accepted", arguments)
		}
	}
}

func TestSummaryFailsWhenATargetFailed(t *testing.T) {
	var output bytes.Buffer
	if err := summarize(&output, []crossplatform.Result{{Target: "ubuntu-26.04", Passed: true}}); err != nil {
		t.Fatal(err)
	}
	err := summarize(&output, []crossplatform.Result{{Target: "ubuntu-26.04", Passed: true}, {Target: "fedora-43"}})
	if err == nil || !strings.Contains(err.Error(), "1 of 2 targets failed: fedora-43") || !strings.Contains(output.String(), "FAIL") {
		t.Fatalf("summary: %q, %v", output.String(), err)
	}
}
