// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import (
	"errors"
	"os/exec"
	"strings"
	"testing"
)

// Exercise the exact public invocation, not just the implementation package.
func TestGitHelperEntrypointDelegatesHelp(t *testing.T) {
	output, err := exec.Command("go", "run", ".", "--help").CombinedOutput()
	if err != nil {
		t.Fatalf("githelper help failed: %v\n%s", err, output)
	}
	for _, expected := range []string{"Guarded Git workflow", "update", "push", "sync", "start", "status", "clean"} {
		if !strings.Contains(string(output), expected) {
			t.Errorf("githelper help is missing %q", expected)
		}
	}
}

func TestGitHelperEntrypointRejectsAnUnknownCommand(t *testing.T) {
	output, err := exec.Command("go", "run", ".", "rewrite-history").CombinedOutput()
	var failure *exec.ExitError
	if !errors.As(err, &failure) {
		t.Fatalf("an unknown command succeeded: %v\n%s", err, output)
	}
	if !strings.Contains(string(output), "unknown command") {
		t.Errorf("unexpected report:\n%s", output)
	}
}
