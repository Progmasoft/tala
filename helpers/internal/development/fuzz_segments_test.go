// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestLightTargetsRunLongCampaignsInSegments(t *testing.T) {
	light := fuzzTarget{binary: "lexer_fuzzer", rssLimit: "1024"}
	heavy := fuzzTarget{binary: "source_llvm_fuzzer", rssLimit: "4096"}
	for _, item := range []struct {
		target   fuzzTarget
		duration int
		want     []int
	}{
		{light, 30, []int{30}},
		{light, 90, []int{90}},
		{light, 180, []int{90, 90}},
		{light, 200, []int{90, 110}},
		{light, 240, []int{90, 90, 60}},
		{light, 900, []int{90, 90, 90, 90, 90, 90, 90, 90, 90, 90}},
		{heavy, 900, []int{900}},
	} {
		got := fuzzSegments(item.target, item.duration)
		if !reflect.DeepEqual(got, item.want) {
			t.Fatalf("%s for %d seconds = %v; want %v", item.target.binary, item.duration, got, item.want)
		}
		total := 0
		for _, seconds := range got {
			total += seconds
		}
		if total != item.duration {
			t.Fatalf("%s segments cover %d of %d seconds", item.target.binary, total, item.duration)
		}
	}
}

// segmentRunner answers every fuzzer process with libFuzzer's final counters
// and records the time each process was given.
type segmentRunner struct {
	fakeRunner
	durations []string
	failAt    int
}

func (runner *segmentRunner) RunWithInput(_ string, _ []string, _ string, _ string, arguments ...string) (string, error) {
	for _, argument := range arguments {
		if value, ok := strings.CutPrefix(argument, "-max_total_time="); ok {
			runner.durations = append(runner.durations, value)
		}
	}
	process := len(runner.durations)
	if process == runner.failAt {
		return "==1== ERROR: libFuzzer: out-of-memory\n", errors.New("exit status 71")
	}
	return fmt.Sprintf("stat::number_of_executed_units: %d\nstat::average_exec_per_sec: 7\nstat::new_units_added: %d\nstat::slowest_unit_time_sec: %d\nstat::peak_rss_mb: %d\n",
		1000*process, process, process%3, 200+10*process), nil
}

func segmentCampaign(t *testing.T, duration int) *fuzzCampaign {
	t.Helper()
	work := t.TempDir()
	artifacts := filepath.Join(work, "artifacts")
	if err := os.MkdirAll(artifacts, 0o700); err != nil {
		t.Fatal(err)
	}
	return &fuzzCampaign{repository: work, corpusRoot: filepath.Join(work, "corpus"), artifacts: artifacts, work: work, report: "campaigns.json", duration: duration, sanitizer: "asan-ubsan-linux", records: make([]map[string]any, 1)}
}

func TestSegmentedCampaignReportsOneRecordOfAllItsProcesses(t *testing.T) {
	campaign := segmentCampaign(t, 240)
	runner := &segmentRunner{}
	if err := campaign.run(runner, 0, fuzzTarget{binary: "lexer_fuzzer", corpus: "lexer", maxLength: "64", rssLimit: "1024"}); err != nil {
		t.Fatal(err)
	}
	if want := []string{"90", "90", "60"}; !reflect.DeepEqual(runner.durations, want) {
		t.Fatalf("process durations = %v; want %v", runner.durations, want)
	}
	report, err := os.ReadFile(filepath.Join(campaign.artifacts, campaign.report))
	if err != nil {
		t.Fatal(err)
	}
	var records []struct {
		Seconds    int            `json:"seconds"`
		Success    bool           `json:"success"`
		Statistics fuzzStatistics `json:"statistics"`
	}
	if err := json.Unmarshal(report, &records); err != nil {
		t.Fatal(err)
	}
	want := fuzzStatistics{ExecutedUnits: 6000, AverageExecPerSec: 25, NewUnitsAdded: 6, SlowestUnitSeconds: 2, PeakRSSMiB: 230}
	if len(records) != 1 || !records[0].Success || records[0].Seconds != 240 || records[0].Statistics != want {
		t.Fatalf("report = %+v; want one successful record of 240 seconds with %+v", records, want)
	}
	log, err := os.ReadFile(filepath.Join(campaign.artifacts, "lexer_fuzzer.log"))
	if err != nil || strings.Count(string(log), "stat::peak_rss_mb") != 3 {
		t.Fatalf("campaign log must keep the output of every process: %v\n%s", err, log)
	}
}

func TestSegmentedCampaignStopsAtTheFirstFailingProcess(t *testing.T) {
	campaign := segmentCampaign(t, 900)
	runner := &segmentRunner{failAt: 3}
	err := campaign.run(runner, 0, fuzzTarget{binary: "ownership_fuzzer", corpus: "ownership", maxLength: "64", rssLimit: "768"})
	if err == nil || !strings.Contains(err.Error(), "exit status 71") {
		t.Fatalf("a failing process must fail the campaign: %v", err)
	}
	if len(runner.durations) != 3 {
		t.Fatalf("%d processes ran after the failure; want the campaign to stop at the third", len(runner.durations))
	}
	report, readErr := os.ReadFile(filepath.Join(campaign.artifacts, campaign.report))
	if readErr != nil || !strings.Contains(string(report), `"success": false`) || !strings.Contains(string(report), `"executed_units": 3000`) {
		t.Fatalf("report must record the failure and the processes before it: %v\n%s", readErr, report)
	}
}

func TestFuzzerWatchdogGrowsWithItsCorpus(t *testing.T) {
	corpus := t.TempDir()
	for index := range 1059 {
		if err := os.WriteFile(filepath.Join(corpus, fmt.Sprintf("seed-%d", index)), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// 90 seconds of fuzzing, the fixed allowance of 90, and 529 for the files.
	if got := fuzzProcessSeconds("source_llvm_fuzzer.exe", []string{corpus, "-max_total_time=90"}); got != 709 {
		t.Fatalf("watchdog with 1,059 corpus files = %d; want 709", got)
	}
	if got := fuzzProcessSeconds("wire_fuzzer", []string{filepath.Join(corpus, "absent"), "-max_total_time=30"}); got != 120 {
		t.Fatalf("watchdog with an unreadable corpus = %d; want the fixed 120", got)
	}
}
