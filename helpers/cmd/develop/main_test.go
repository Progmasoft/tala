// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import (
	"os/exec"
	"strings"
	"testing"
)

// Exercise the exact public invocation, not just the implementation package.
func TestDeveloperEntrypointDelegatesHelp(t *testing.T) {
	command := exec.Command("go", "run", ".", "--help")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("developer help failed: %v\n%s", err, output)
	}
	for _, expected := range []string{"Tala native developer command", "fuzz-stress", "cold-clean-build", "bundle"} {
		if !strings.Contains(string(output), expected) {
			t.Errorf("developer help is missing %q", expected)
		}
	}
}
