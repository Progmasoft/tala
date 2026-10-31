// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFuzzSanitizerEnvironmentKeepsChecksAndInput(t *testing.T) {
	input := []string{"ASAN_OPTIONS=halt_on_error=1:strict_string_checks=1", "UBSAN_OPTIONS=halt_on_error=1"}
	output := fuzzSanitizerEnvironment(input)
	if !strings.Contains(output[0], "quarantine_size_mb=64") || !strings.Contains(output[0], "halt_on_error=1") {
		t.Fatalf("lost checks or bounded quarantine: %v", output)
	}
	if strings.Contains(input[0], "quarantine") || output[1] != input[1] {
		t.Fatalf("mutated caller settings: %v, %v", input, output)
	}
}

func TestFuzzDurationBounds(t *testing.T) {
	for _, value := range []string{"0", "-1", "3601", "7200", "invalid"} {
		if _, err := fuzzDuration(false, value); err == nil {
			t.Fatalf("accepted invalid campaign duration %q", value)
		}
	}
	for _, seconds := range []string{"1", "90", "900", "3600"} {
		if _, err := fuzzDuration(false, seconds); err != nil {
			t.Fatal(err)
		}
	}
	if duration, _ := fuzzDuration(false, ""); duration != 30 {
		t.Fatalf("short duration: %d", duration)
	}
	if duration, _ := fuzzDuration(true, ""); duration != 900 {
		t.Fatalf("stress duration: %d", duration)
	}
}

func TestSeedUpdatePreservesBothVersions(t *testing.T) {
	source, destination := t.TempDir(), t.TempDir()
	seed := filepath.Join(source, "program.tala")
	if err := os.WriteFile(seed, []byte("original seed"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := syncSeedCorpus(source, destination); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(seed, []byte("updated seed"), 0o600); err != nil {
		t.Fatal(err)
	}
	for iteration := 0; iteration < 2; iteration++ {
		if err := syncSeedCorpus(source, destination); err != nil {
			t.Fatal(err)
		}
	}
	entries, err := os.ReadDir(destination)
	if err != nil || len(entries) != 2 {
		t.Fatalf("expected two deduplicated seed versions: %v, %v", entries, err)
	}
	original, err := os.ReadFile(filepath.Join(destination, "program.tala"))
	if err != nil || string(original) != "original seed" {
		t.Fatalf("overwrote cached seed: %q, %v", original, err)
	}
}

func TestMissingVersionedCorpusIsAnError(t *testing.T) {
	if err := syncSeedCorpus(filepath.Join(t.TempDir(), "missing"), t.TempDir()); err == nil {
		t.Fatal("missing versioned corpus silently accepted")
	}
}

func TestSeedCollisionDoesNotOverwrite(t *testing.T) {
	target := filepath.Join(t.TempDir(), "seed")
	if err := writeSeedExclusive(target, []byte("first")); err != nil {
		t.Fatal(err)
	}
	if err := writeSeedExclusive(target, []byte("second")); err == nil {
		t.Fatal("different contents at a stable corpus address were overwritten")
	}
}
