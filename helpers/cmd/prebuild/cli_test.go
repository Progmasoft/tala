// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package main

import (
	"bytes"
	"strings"
	"testing"
)

func executePrebuild(runner *bootstrapFakeRunner, arguments ...string) (string, error) {
	var output, errorOutput bytes.Buffer
	command := newPrebuildCommand(runner, &output, &errorOutput)
	command.SetArgs(arguments)
	err := command.Execute()
	return output.String(), err
}

func TestCommandHelpListsBothCommandsAndTouchesNothing(t *testing.T) {
	for _, arguments := range [][]string{{}, {"--help"}, {"-h"}, {"help"}} {
		runner := &bootstrapFakeRunner{}
		output, err := executePrebuild(runner, arguments...)
		if err != nil {
			t.Fatalf("command %v returned error: %v", arguments, err)
		}
		for _, expected := range []string{"prebuild", "check", "install", "ClangCL/LLD on Windows"} {
			if !strings.Contains(output, expected) {
				t.Fatalf("command %v help lacks %q:\n%s", arguments, expected, output)
			}
		}
		if len(runner.invocations) != 0 {
			t.Fatalf("command %v ran %v for a request for help", arguments, runner.invocations)
		}
	}
}

func TestCommandHelpOfACommandDescribesThatCommand(t *testing.T) {
	runner := &bootstrapFakeRunner{}
	output, err := executePrebuild(runner, "install", "--help")
	if err != nil {
		t.Fatalf("install --help returned error: %v", err)
	}
	if !strings.Contains(output, "Install missing tools") {
		t.Fatalf("install --help does not describe the command:\n%s", output)
	}
	if len(runner.invocations) != 0 {
		t.Fatalf("install --help ran %v", runner.invocations)
	}
}

func TestCommandRejectsWhatItDoesNotUnderstandAndTouchesNothing(t *testing.T) {
	cases := map[string][]string{
		"an unknown command":            {"remove"},
		"an argument after a command":   {"check", "extra"},
		"two commands":                  {"check", "install"},
		"an unknown flag":               {"--unknown"},
		"an unknown flag of a command":  {"install", "--force"},
		"the earlier -help spelling":    {"-help"},
		"a command in another spelling": {"Install"},
	}
	for name, arguments := range cases {
		runner := &bootstrapFakeRunner{}
		if _, err := executePrebuild(runner, arguments...); err == nil {
			t.Errorf("command %v accepted %s", arguments, name)
		}
		if len(runner.invocations) != 0 {
			t.Errorf("command %v ran %v for %s", arguments, runner.invocations, name)
		}
	}
}
