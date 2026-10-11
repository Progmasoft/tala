// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestEveryHostListsEveryKindAndSaysWhatItLacks(t *testing.T) {
	hosts := map[string]host{
		"Windows": {kind: hostWindows, name: "Windows 10/11"},
		"macOS":   {kind: hostMacOS, name: "macOS 26 Tahoe"},
		"Linux":   {kind: hostLinux, name: "Ubuntu 26.04"},
	}
	for name, current := range hosts {
		support := hostSanitizers(current)
		if len(support) != len(sanitizerKinds) {
			t.Fatalf("%s lists %d kinds, want %d", name, len(support), len(sanitizerKinds))
		}
		for index, entry := range support {
			if entry.Kind != sanitizerKinds[index] {
				t.Errorf("%s lists %q at %d, want %q", name, entry.Kind, index, sanitizerKinds[index])
			}
			// The list says exactly what the command would do.
			_, err := selectSanitizer(current, entry.Kind)
			if entry.Supported != (err == nil) {
				t.Errorf("%s lists %s as supported=%v, but selecting it gives %v", name, entry.Kind, entry.Supported, err)
			}
			if entry.Supported && (entry.Name == "" || entry.Configuration == "") {
				t.Errorf("%s lists %s without a checker or a configuration: %+v", name, entry.Kind, entry)
			}
			if !entry.Supported && entry.Reason == "" {
				t.Errorf("%s does not say why %s is not supported", name, entry.Kind)
			}
		}
	}
}

func TestAllRunsEveryCheckerOnceAndOnlyWhatTheHostHas(t *testing.T) {
	windows := comprehensiveSanitizers(host{kind: hostWindows})
	if strings.Join(windows, ",") != "address-undefined" {
		t.Fatalf("Windows runs %v, want the combined build alone: it has no ThreadSanitizer", windows)
	}
	for _, current := range []host{{kind: hostMacOS}, {kind: hostLinux}} {
		kinds := comprehensiveSanitizers(current)
		if strings.Join(kinds, ",") != "address-undefined,thread" {
			t.Fatalf("host %v runs %v, want address-undefined and thread", current.kind, kinds)
		}
	}
}

func TestTheSanitizerListIsWrittenForPeopleAndForScripts(t *testing.T) {
	windows := host{kind: hostWindows, name: "Windows 10/11"}
	var table bytes.Buffer
	if err := writeSanitizers(&table, windows, false); err != nil {
		t.Fatalf("writeSanitizers() returned error: %v", err)
	}
	for _, expected := range []string{"Host: Windows 10/11", "asan-ubsan-windows", "not supported", "`sanitize all` runs: address-undefined."} {
		if !strings.Contains(table.String(), expected) {
			t.Fatalf("the list lacks %q:\n%s", expected, table.String())
		}
	}
	var encoded bytes.Buffer
	if err := writeSanitizers(&encoded, windows, true); err != nil {
		t.Fatalf("writeSanitizers() returned error: %v", err)
	}
	var support []sanitizerSupport
	if err := json.Unmarshal(encoded.Bytes(), &support); err != nil || len(support) != len(sanitizerKinds) {
		t.Fatalf("the JSON holds %d kinds (error %v):\n%s", len(support), err, encoded.String())
	}
}

func TestOneKindReturnsItsOwnResultWithoutASummary(t *testing.T) {
	var output bytes.Buffer
	failure := errors.New("heap-use-after-free")
	err := runSanitizerSuites([]string{"address"}, &output, func(string) error { return failure })
	if !errors.Is(err, failure) {
		t.Fatalf("error = %v, want the failure of the suite", err)
	}
	if output.Len() != 0 {
		t.Fatalf("one kind wrote a summary: %q", output.String())
	}
}

func TestSeveralKindsAllRunAndEveryFailureIsNamed(t *testing.T) {
	var ran []string
	var output bytes.Buffer
	race := errors.New("data race")
	err := runSanitizerSuites([]string{"address-undefined", "thread", "undefined"}, &output, func(kind string) error {
		ran = append(ran, kind)
		if kind == "address-undefined" {
			return errors.New("overflow")
		}
		if kind == "thread" {
			return race
		}
		return nil
	})
	// A kind that fails does not stop the ones after it.
	if strings.Join(ran, ",") != "address-undefined,thread,undefined" {
		t.Fatalf("ran %v, want all three in order", ran)
	}
	if err == nil || !errors.Is(err, race) {
		t.Fatalf("error = %v, want one that holds every failure", err)
	}
	for _, expected := range []string{"address-undefined: overflow", "thread: data race"} {
		if !strings.Contains(err.Error(), expected) {
			t.Fatalf("error %q does not name %q", err, expected)
		}
	}
	for _, expected := range []string{"FAILED  address-undefined", "FAILED  thread", "passed  undefined"} {
		if !strings.Contains(output.String(), expected) {
			t.Fatalf("the summary lacks %q:\n%s", expected, output.String())
		}
	}
}

func TestSeveralKindsThatPassReturnNothing(t *testing.T) {
	var output bytes.Buffer
	if err := runSanitizerSuites([]string{"address-undefined", "thread"}, &output, func(string) error { return nil }); err != nil {
		t.Fatalf("error = %v, want none", err)
	}
	if strings.Contains(output.String(), "FAILED") {
		t.Fatalf("the summary reports a failure:\n%s", output.String())
	}
}

func TestAHostWithoutASanitizerIsAnErrorAndNotASuccess(t *testing.T) {
	ran := false
	err := runSanitizerSuites(nil, &bytes.Buffer{}, func(string) error {
		ran = true
		return nil
	})
	if err == nil || ran {
		t.Fatalf("no kind gave error %v and ran=%v; want an error and nothing run", err, ran)
	}
}

func TestSanitizerCommandsRefuseBadInvocations(t *testing.T) {
	for _, args := range [][]string{{"sanitizers", "extra"}, {"sanitizers", "--yaml"}, {"sanitize"}, {"sanitize", "all", "extra"}} {
		command := newCommand(fakeRunner{}, &bytes.Buffer{}, &bytes.Buffer{})
		command.SetArgs(args)
		err := command.Execute()
		if err == nil {
			t.Fatalf("accepted %v", args)
		}
		if strings.Contains(err.Error(), "unexpected process") {
			t.Fatalf("%v ran a process before it was refused: %v", args, err)
		}
	}
}
