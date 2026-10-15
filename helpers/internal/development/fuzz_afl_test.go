// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"crypto/sha1"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestAFLRunsTheTargetsWithoutFrontendOrThreads(t *testing.T) {
	var names []string
	for _, target := range aflFuzzTargets() {
		if target.frontend || target.threaded {
			t.Fatalf("AFL++ target %s loads the frontend or starts threads", target.binary)
		}
		names = append(names, target.corpus)
	}
	if !reflect.DeepEqual(names, []string{"wire", "cli"}) {
		t.Fatalf("AFL++ targets = %v, want wire and cli", names)
	}
}

func TestAFLBuildsSanitizedAndCmpLogTwins(t *testing.T) {
	targets := aflFuzzTargets()
	sanitized := aflBuildArguments("asan-ubsan-linux", false, targets)
	if !reflect.DeepEqual(sanitized[:3], []string{"build", "--config=afl-linux", "--config=asan-ubsan-linux"}) {
		t.Fatalf("sanitized build = %v", sanitized)
	}
	cmplog := aflBuildArguments("asan-ubsan-linux", true, targets)
	if !reflect.DeepEqual(cmplog[:3], []string{"build", "--config=afl-linux", "--action_env=AFL_LLVM_CMPLOG=1"}) {
		t.Fatalf("CmpLog build = %v", cmplog)
	}
	for _, argument := range cmplog {
		if strings.Contains(argument, "asan") {
			t.Fatalf("the CmpLog build must carry no sanitizer: %v", cmplog)
		}
	}
	for _, build := range [][]string{sanitized, cmplog} {
		if build[len(build)-1] != targets[len(targets)-1].label {
			t.Fatalf("build does not end with the target labels: %v", build)
		}
	}
}

func TestAFLEnvironmentAbortsWithoutSymbolizing(t *testing.T) {
	environment := aflEnvironment([]string{"ASAN_OPTIONS=halt_on_error=1", "UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1"})
	want := map[string]string{
		"ASAN_OPTIONS":                          "halt_on_error=1:quarantine_size_mb=64:thread_local_quarantine_size_kb=256:abort_on_error=1:symbolize=0",
		"UBSAN_OPTIONS":                         "halt_on_error=1:print_stacktrace=1:abort_on_error=1:symbolize=0",
		"AFL_NO_UI":                             "1",
		"AFL_SKIP_CPUFREQ":                      "1",
		"AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES": "1",
	}
	got := map[string]string{}
	for _, setting := range environment {
		name, value, _ := strings.Cut(setting, "=")
		got[name] = value
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("environment = %v, want %v", got, want)
	}
}

func TestAFLFuzzArgumentsBoundTimeLengthAndInput(t *testing.T) {
	target := fuzzTarget{binary: "cli_fuzzer", corpus: "cli", maxLength: "16384"}
	got := aflFuzzArguments("in", "out", "prog", "prog.cmplog", target, 90)
	want := []string{"-i", "in", "-o", "out", "-V", "90", "-G", "16384", "-t", "30000", "-m", "none", "-c", "prog.cmplog", "--", "prog"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("afl-fuzz arguments = %v, want %v", got, want)
	}
}

func TestAFLFindingsSkipTheReadme(t *testing.T) {
	directory := t.TempDir()
	for _, name := range []string{"README.txt", "id_000000_sig_06_src_000001"} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	findings, err := aflFindings(directory)
	if err != nil || len(findings) != 1 || filepath.Base(findings[0]) != "id_000000_sig_06_src_000001" {
		t.Fatalf("findings = %v, %v", findings, err)
	}
	missing, err := aflFindings(filepath.Join(directory, "absent"))
	if err != nil || len(missing) != 0 {
		t.Fatalf("an absent directory holds no findings: %v, %v", missing, err)
	}
}

func TestAFLArtifactNamesAreUploadable(t *testing.T) {
	got := aflArtifactName("wire_fuzzer", "crashes", "id:000000,sig:06,src:000001,time:12,execs:9,op:havoc,rep:2")
	want := "wire_fuzzer-crashes-id_000000_sig_06_src_000001_time_12_execs_9_op_havoc_rep_2"
	if got != want {
		t.Fatalf("artifact name = %q, want %q", got, want)
	}
}

func TestAFLQueueJoinsTheCorpusUnderContentNames(t *testing.T) {
	queue, corpus := t.TempDir(), t.TempDir()
	inputs := map[string]string{"id_000000_time_0_orig_a": "first", "id_000001_src_000000": "second", ".state": "skipped"}
	for name, content := range inputs {
		if err := os.WriteFile(filepath.Join(queue, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	existing := fmt.Sprintf("%x", sha1.Sum([]byte("first")))
	if err := os.WriteFile(filepath.Join(corpus, existing), []byte("first"), 0o600); err != nil {
		t.Fatal(err)
	}
	added, err := exportAFLQueue(queue, corpus)
	if err != nil || added != 1 {
		t.Fatalf("added = %d, %v; want only the input the corpus lacked", added, err)
	}
	second := filepath.Join(corpus, fmt.Sprintf("%x", sha1.Sum([]byte("second"))))
	if content, err := os.ReadFile(second); err != nil || string(content) != "second" {
		t.Fatalf("the new input is not stored under its SHA-1: %q, %v", content, err)
	}
}

func TestAFLStatisticsReadTheCounters(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fuzzer_stats")
	if err := os.WriteFile(path, []byte("execs_done        : 1234\nedges_found       : 56\nbitmap_cvg        : 7.89%\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	statistics, err := aflStatistics(path)
	if err != nil || statistics["execs_done"] != "1234" || statistics["edges_found"] != "56" || statistics["bitmap_cvg"] != "7.89%" {
		t.Fatalf("statistics = %v, %v", statistics, err)
	}
}

func TestAFLIsRejectedOutsideLinux(t *testing.T) {
	for _, kind := range []hostKind{hostWindows, hostMacOS} {
		err := runAFLCampaign(t.TempDir(), host{kind: kind}, fakeRunner{})
		if err == nil || !strings.Contains(err.Error(), "Linux") {
			t.Fatalf("host %v: err = %v, want a Linux-only error", kind, err)
		}
	}
}
