// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestCommandRunsTheVerificationOnce(t *testing.T) {
	calls := 0
	var output, errorOutput bytes.Buffer

	err := execute(nil, &output, &errorOutput, func() error {
		calls++
		return nil
	})
	if err != nil {
		t.Fatalf("execute() returned error: %v", err)
	}
	if calls != 1 {
		t.Fatalf("execute() ran the verification %d times, want 1", calls)
	}
}

func TestCommandReturnsTheFailureOfTheVerification(t *testing.T) {
	failure := errors.New("undocumented entry")
	var output, errorOutput bytes.Buffer

	err := execute(nil, &output, &errorOutput, func() error { return failure })
	if !errors.Is(err, failure) {
		t.Fatalf("execute() error = %v, want the failure of the verification", err)
	}
}

func TestCommandHelpDoesNotRunTheVerification(t *testing.T) {
	for _, arguments := range [][]string{{"--help"}, {"-h"}} {
		calls := 0
		var output, errorOutput bytes.Buffer
		err := execute(arguments, &output, &errorOutput, func() error {
			calls++
			return nil
		})
		if err != nil {
			t.Fatalf("execute(%v) returned error: %v", arguments, err)
		}
		if calls != 0 {
			t.Fatalf("execute(%v) ran the verification for a request for help", arguments)
		}
		for _, expected := range []string{"verify-docs", "Doxygen", "Haddock"} {
			if !strings.Contains(output.String(), expected) {
				t.Fatalf("execute(%v) help lacks %q:\n%s", arguments, expected, output.String())
			}
		}
	}
}

func TestCommandRejectsArgumentsWithoutRunningTheVerification(t *testing.T) {
	for _, arguments := range [][]string{{"extra"}, {"--unknown"}, {"-Help"}} {
		calls := 0
		var output, errorOutput bytes.Buffer
		err := execute(arguments, &output, &errorOutput, func() error {
			calls++
			return nil
		})
		if err == nil {
			t.Errorf("execute(%v) accepted an invocation it does not understand", arguments)
		}
		if calls != 0 {
			t.Errorf("execute(%v) ran the verification after rejecting the invocation", arguments)
		}
	}
}
