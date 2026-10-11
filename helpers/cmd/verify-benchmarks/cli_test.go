// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestCommandVerifiesTheRootItIsGiven(t *testing.T) {
	root := makeBenchmarkFixture(t, "2026-01-01-First.md", "2026-01-02-Second.md")
	var output, errorOutput bytes.Buffer

	if err := run([]string{"--root", root}, &output, &errorOutput); err != nil {
		t.Fatalf("run() returned error: %v", err)
	}
	if !strings.Contains(output.String(), "Verified 2 benchmark result reports") {
		t.Fatalf("run() output = %q, want the count of verified reports", output.String())
	}
}

func TestCommandReturnsTheFailureOfTheCheck(t *testing.T) {
	var output, errorOutput bytes.Buffer

	err := run([]string{"--root", t.TempDir()}, &output, &errorOutput)
	if err == nil {
		t.Fatal("run() accepted a root without a benchmark directory")
	}
	if output.Len() != 0 {
		t.Fatalf("run() wrote %q after a failed check", output.String())
	}
}

func TestCommandHelpDescribesTheCheckAndItsFlag(t *testing.T) {
	for _, arguments := range [][]string{{"--help"}, {"-h"}} {
		var output, errorOutput bytes.Buffer
		if err := run(arguments, &output, &errorOutput); err != nil {
			t.Fatalf("run(%v) returned error: %v", arguments, err)
		}
		for _, expected := range []string{"verify-benchmarks", "--root", "Benchmarks/README.md"} {
			if !strings.Contains(output.String(), expected) {
				t.Fatalf("run(%v) help lacks %q:\n%s", arguments, expected, output.String())
			}
		}
	}
}

func TestCommandRejectsWhatItDoesNotUnderstand(t *testing.T) {
	cases := map[string][]string{
		"a positional argument":      {"extra"},
		"an unknown flag":            {"--unknown"},
		"the flag without its value": {"--root"},
		"the earlier -Root spelling": {"-Root", "."},
		"the earlier -Help spelling": {"-Help"},
	}
	for name, arguments := range cases {
		var output, errorOutput bytes.Buffer
		if err := run(arguments, &output, &errorOutput); err == nil {
			t.Errorf("run(%v) accepted %s", arguments, name)
		}
		if strings.Contains(output.String(), "Verified") {
			t.Errorf("run(%v) ran the check for %s", arguments, name)
		}
	}
}
