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

func corpusNames(targets []fuzzTarget) string {
	names := make([]string, 0, len(targets))
	for _, target := range targets {
		names = append(names, target.corpus)
	}
	return strings.Join(names, ",")
}

func TestAnEmptySelectionIsEveryTargetAndTheHaskellCampaign(t *testing.T) {
	for _, selection := range []string{"", "  "} {
		selected, haskell, err := selectFuzzTargets(nativeFuzzTargets(), selection)
		if err != nil {
			t.Fatalf("selectFuzzTargets(%q) returned error: %v", selection, err)
		}
		if len(selected) != len(nativeFuzzTargets()) || !haskell {
			t.Fatalf("selectFuzzTargets(%q) = %d targets, haskell %v; want all and true", selection, len(selected), haskell)
		}
	}
}

func TestASelectionKeepsInventoryOrderAndAcceptsEitherName(t *testing.T) {
	// Written out of order, once by corpus name and once by program name.
	selected, haskell, err := selectFuzzTargets(nativeFuzzTargets(), "parser, wire_fuzzer ,cli")
	if err != nil {
		t.Fatalf("selectFuzzTargets() returned error: %v", err)
	}
	if got := corpusNames(selected); got != "wire,parser,cli" {
		t.Fatalf("selected %s, want wire,parser,cli in inventory order", got)
	}
	if haskell {
		t.Fatal("the Haskell campaign was selected without being named")
	}
}

func TestTheHaskellCampaignIsSelectedByItsOwnName(t *testing.T) {
	selected, haskell, err := selectFuzzTargets(nativeFuzzTargets(), "haskell")
	if err != nil {
		t.Fatalf("selectFuzzTargets() returned error: %v", err)
	}
	if len(selected) != 0 || !haskell {
		t.Fatalf("selected %d native targets, haskell %v; want none and true", len(selected), haskell)
	}
}

func TestANameSelectedTwiceIsOneTarget(t *testing.T) {
	selected, _, err := selectFuzzTargets(nativeFuzzTargets(), "wire,wire_fuzzer,wire")
	if err != nil {
		t.Fatalf("selectFuzzTargets() returned error: %v", err)
	}
	if got := corpusNames(selected); got != "wire" {
		t.Fatalf("selected %s, want wire once", got)
	}
}

func TestAnUnknownOrEmptyNameIsRefusedWithTheNamesThatExist(t *testing.T) {
	_, _, err := selectFuzzTargets(nativeFuzzTargets(), "wire,nope,alsonot")
	if err == nil {
		t.Fatal("an unknown target was accepted")
	}
	for _, expected := range []string{"alsonot, nope", "wire", "ownership", "haskell"} {
		if !strings.Contains(err.Error(), expected) {
			t.Fatalf("error %q does not mention %q", err, expected)
		}
	}
	if _, _, err := selectFuzzTargets(nativeFuzzTargets(), "wire,,cli"); err == nil {
		t.Fatal("an empty name in a selection was accepted")
	}
}

func TestFuzzOptionsAreHeldToTheLimitsOfTheCampaign(t *testing.T) {
	inventory := nativeFuzzTargets()
	valid := []fuzzOptions{
		{},
		{seconds: 1}, {seconds: 3600}, {jobs: 1}, {jobs: 64},
		{corpus: "kept"}, {targets: []string{"wire", "haskell"}},
	}
	for _, options := range valid {
		if err := options.validate(false, inventory); err != nil {
			t.Errorf("validate(%+v) returned error: %v", options, err)
		}
	}
	invalid := map[string]fuzzOptions{
		"--seconds": {seconds: 3601},
		"--jobs":    {jobs: 65},
		"unknown":   {targets: []string{"nope"}},
	}
	for expected, options := range invalid {
		err := options.validate(false, inventory)
		if err == nil || !strings.Contains(err.Error(), expected) {
			t.Errorf("validate(%+v) error = %v, want one that names %s", options, err, expected)
		}
	}
	for _, options := range []fuzzOptions{{seconds: -1}, {jobs: -1}} {
		if err := options.validate(false, inventory); err == nil {
			t.Errorf("validate(%+v) accepted a negative setting", options)
		}
	}
}

func TestAThreadSelectionMayOnlyNameThreadedTargets(t *testing.T) {
	if err := (fuzzOptions{targets: []string{"ownership"}}).validate(false, threadFuzzTargets()); err != nil {
		t.Fatalf("the threaded target was refused: %v", err)
	}
	if err := (fuzzOptions{targets: []string{"wire"}}).validate(false, threadFuzzTargets()); err == nil {
		t.Fatal("a target without threads was accepted for the thread campaign")
	}
}

func TestFuzzOptionsSetOnlyTheVariablesThatWereGiven(t *testing.T) {
	set := map[string]string{}
	record := func(name, value string) error {
		set[name] = value
		return nil
	}
	if err := (fuzzOptions{}).apply(record); err != nil || len(set) != 0 {
		t.Fatalf("no option set %v (error %v); want nothing", set, err)
	}
	options := fuzzOptions{seconds: 45, jobs: 2, corpus: "kept", targets: []string{"wire", "haskell"}}
	if err := options.apply(record); err != nil {
		t.Fatalf("apply() returned error: %v", err)
	}
	want := map[string]string{
		"VXS_FUZZ_SECONDS": "45", "VXS_FUZZ_JOBS": "2", "VXS_FUZZ_CORPUS": "kept", "VXS_FUZZ_TARGETS": "wire,haskell",
	}
	for name, value := range want {
		if set[name] != value {
			t.Errorf("%s = %q, want %q", name, set[name], value)
		}
	}
	if len(set) != len(want) {
		t.Errorf("apply() set %v, want exactly %v", set, want)
	}
	failure := errors.New("read-only environment")
	err := (fuzzOptions{seconds: 5}).apply(func(string, string) error { return failure })
	if !errors.Is(err, failure) {
		t.Fatalf("apply() error = %v, want the failure of the environment", err)
	}
}

func TestTheInventoryIsListedForPeopleAndForScripts(t *testing.T) {
	var table bytes.Buffer
	if err := writeFuzzTargets(&table, nativeFuzzTargets(), false); err != nil {
		t.Fatalf("writeFuzzTargets() returned error: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(table.String()), "\n")
	// A header, one line for each native target, and the Haskell campaign.
	if len(lines) != len(nativeFuzzTargets())+2 {
		t.Fatalf("the table has %d lines, want %d:\n%s", len(lines), len(nativeFuzzTargets())+2, table.String())
	}
	for _, expected := range []string{"NAME", "ownership_fuzzer", "65536 bytes", "4096 MiB", "haskell"} {
		if !strings.Contains(table.String(), expected) {
			t.Fatalf("the table lacks %q:\n%s", expected, table.String())
		}
	}

	var encoded bytes.Buffer
	if err := writeFuzzTargets(&encoded, nativeFuzzTargets(), true); err != nil {
		t.Fatalf("writeFuzzTargets() returned error: %v", err)
	}
	var records []fuzzTargetRecord
	if err := json.Unmarshal(encoded.Bytes(), &records); err != nil {
		t.Fatalf("the JSON does not decode: %v\n%s", err, encoded.String())
	}
	if len(records) != len(nativeFuzzTargets()) {
		t.Fatalf("the JSON holds %d targets, want %d", len(records), len(nativeFuzzTargets()))
	}
	byName := map[string]fuzzTargetRecord{}
	for _, record := range records {
		byName[record.Name] = record
	}
	if record := byName["ownership"]; !record.Threaded || record.Frontend || record.MemoryLimit != 768 {
		t.Fatalf("ownership is listed as %+v", record)
	}
	if record := byName["source"]; !record.Heavy || !record.Frontend || record.MaximumLength != 65536 {
		t.Fatalf("source is listed as %+v", record)
	}
}

func TestATargetWithoutNumericLimitsIsAnInventoryError(t *testing.T) {
	broken := []fuzzTarget{{label: "//x:y", binary: "y", corpus: "y", maxLength: "many", rssLimit: "768"}}
	if err := writeFuzzTargets(&bytes.Buffer{}, broken, false); err == nil {
		t.Fatal("an input limit that is not a number was listed")
	}
	broken[0].maxLength, broken[0].rssLimit = "64", "much"
	if err := writeFuzzTargets(&bytes.Buffer{}, broken, true); err == nil {
		t.Fatal("a memory limit that is not a number was listed")
	}
}

func TestFuzzCommandsRefuseBadOptionsBeforeAnyProcess(t *testing.T) {
	for _, args := range [][]string{
		{"fuzz", "--target", "nope"}, {"fuzz", "--seconds", "0x"}, {"fuzz", "--seconds", "4000"},
		{"fuzz", "--jobs", "100"}, {"fuzz", "--jobs"}, {"fuzz", "extra"},
		{"fuzz-thread", "--target", "wire"}, {"fuzz-thread", "--seconds", "-3"},
		{"fuzz-stress", "--target", "nope", "--asan"}, {"fuzz-stress", "--corpus"},
		{"fuzz-targets", "extra"}, {"fuzz-targets", "--yaml"},
	} {
		command := newCommand(fakeRunner{}, &bytes.Buffer{}, &bytes.Buffer{})
		command.SetArgs(args)
		err := command.Execute()
		if err == nil {
			t.Fatalf("accepted %v", args)
		}
		if strings.Contains(err.Error(), "unexpected process") || strings.Contains(err.Error(), "not available") {
			t.Fatalf("%v reached a process before it was refused: %v", args, err)
		}
	}
}

func TestTheFuzzTargetsCommandNeedsNoTool(t *testing.T) {
	var output bytes.Buffer
	command := newCommand(fakeRunner{}, &output, &output)
	command.SetArgs([]string{"fuzz-targets", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("fuzz-targets --json returned error: %v", err)
	}
	var records []fuzzTargetRecord
	if err := json.Unmarshal(output.Bytes(), &records); err != nil || len(records) == 0 {
		t.Fatalf("fuzz-targets --json wrote %q (error %v)", output.String(), err)
	}
}
