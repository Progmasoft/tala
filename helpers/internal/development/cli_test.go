// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"bytes"
	"strings"
	"testing"
)

func TestCommandTreeHelpDoesNotDiscoverTools(t *testing.T) {
	for _, args := range [][]string{{}, {"--help"}, {"build", "--help"}, {"fuzz-stress", "--help"}, {"help", "sanitize"}} {
		var out bytes.Buffer
		command := newCommand(fakeRunner{}, &out, &out)
		command.SetArgs(args)
		if err := command.Execute(); err != nil {
			t.Fatalf("%v: %v", args, err)
		}
		if !strings.Contains(out.String(), "Usage:") {
			t.Fatalf("missing help: %s", out.String())
		}
	}
}

func TestCommandTreeRejectsInvalidInputsBeforeExecution(t *testing.T) {
	for _, args := range [][]string{
		{"unknown"}, {"doctor", "extra"}, {"build", "--jobs=4"}, {"build", "--", "--config=private"},
		{"sanitize"}, {"sanitize", "address", "extra"}, {"version"}, {"clean", "extra"},
		{"fuzz-stress", "--unknown"}, {"fuzz-stress", "--asan=invalid"}, {"fuzz-stress", "extra"}, {"-Help"},
	} {
		command := newCommand(fakeRunner{}, &bytes.Buffer{}, &bytes.Buffer{})
		command.SetArgs(args)
		err := command.Execute()
		if err == nil {
			t.Fatalf("accepted %v", args)
		}
		if strings.Contains(err.Error(), "unexpected process") {
			t.Fatalf("executed invalid command %v: %v", args, err)
		}
	}
}

func TestFuzzBuildPlansSeparateSmokeAndRuntimeMain(t *testing.T) {
	for _, configuration := range []string{"fuzz-windows", "fuzz-macos", "fuzz-linux"} {
		for _, sanitizer := range []string{"", "asan-test"} {
			smoke, campaign := fuzzBuildArguments(configuration, sanitizer, "/llvm/fuzzer.a")
			if len(smoke) < 3 || smoke[0] != "build" || campaign[1] != "--config="+configuration {
				t.Fatalf("invalid build plans: %v / %v", smoke, campaign)
			}
			for _, argument := range smoke {
				if strings.Contains(argument, "fuzzer") || argument == "--config="+configuration {
					t.Fatalf("smoke unexpectedly links libFuzzer's main: %v", smoke)
				}
			}
			for _, argument := range campaign {
				if strings.HasSuffix(argument, "_smoke") {
					t.Fatalf("campaign includes a program that already owns main: %v", campaign)
				}
			}
			drivers := 0
			for _, argument := range campaign {
				if strings.HasPrefix(argument, "//") {
					drivers++
				}
			}
			if drivers != 8 {
				t.Fatalf("expected eight campaign drivers: %v", campaign)
			}
			if sanitizer != "" {
				for _, plan := range [][]string{smoke, campaign} {
					if !strings.Contains(strings.Join(plan, " "), "--config="+sanitizer) {
						t.Fatalf("sanitizer missing from plan: %v", plan)
					}
				}
			}
		}
	}
}
