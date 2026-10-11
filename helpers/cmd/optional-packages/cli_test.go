// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package main

import (
	"bytes"
	"strings"
	"testing"
)

func executeOptionalPackages(runner *fakePackageRunner, arguments ...string) (string, error) {
	var output, errorOutput bytes.Buffer
	command := newOptionalPackagesCommand(runner, &output, &errorOutput)
	command.SetArgs(arguments)
	err := command.Execute()
	return output.String(), err
}

func TestCommandHelpListsBothCommandsAndTouchesNothing(t *testing.T) {
	for _, arguments := range [][]string{{}, {"--help"}, {"-h"}, {"help"}} {
		runner := &fakePackageRunner{}
		output, err := executeOptionalPackages(runner, arguments...)
		if err != nil {
			t.Fatalf("command %v returned error: %v", arguments, err)
		}
		for _, expected := range []string{"optional-packages", "install", "check", "never installs a toolchain"} {
			if !strings.Contains(output, expected) {
				t.Fatalf("command %v help lacks %q:\n%s", arguments, expected, output)
			}
		}
		if len(runner.commands) != 0 {
			t.Fatalf("command %v ran %v for a request for help", arguments, runner.commands)
		}
	}
}

func TestCommandHelpOfACommandDescribesThatCommand(t *testing.T) {
	runner := &fakePackageRunner{}
	output, err := executeOptionalPackages(runner, "install", "--help")
	if err != nil {
		t.Fatalf("install --help returned error: %v", err)
	}
	if !strings.Contains(output, "Install missing .NET 10") {
		t.Fatalf("install --help does not describe the command:\n%s", output)
	}
	if len(runner.commands) != 0 {
		t.Fatalf("install --help ran %v", runner.commands)
	}
}

func TestCommandRejectsWhatItDoesNotUnderstandAndTouchesNothing(t *testing.T) {
	cases := map[string][]string{
		"an unknown command":            {"remove"},
		"an argument after a command":   {"check", "extra"},
		"two commands":                  {"check", "install"},
		"an unknown flag":               {"--unknown"},
		"an unknown flag of a command":  {"install", "--force"},
		"the earlier -Help spelling":    {"-Help"},
		"a command in another spelling": {"Check"},
	}
	for name, arguments := range cases {
		runner := &fakePackageRunner{}
		if _, err := executeOptionalPackages(runner, arguments...); err == nil {
			t.Errorf("command %v accepted %s", arguments, name)
		}
		if len(runner.commands) != 0 {
			t.Errorf("command %v ran %v for %s", arguments, runner.commands, name)
		}
	}
}

func TestCheckCommandReportsMissingToolchains(t *testing.T) {
	runner := &fakePackageRunner{}
	_, err := executeOptionalPackages(runner, "check")
	if err == nil || !strings.Contains(err.Error(), "optional toolchain(s) missing") {
		t.Fatalf("check error = %v, want the count of missing toolchains", err)
	}
}
