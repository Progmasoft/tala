// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"bytes"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const googleSingleRun = `{
  "context": {"date": "2026-10-11"},
  "benchmarks": [
    {"name": "Verify/8", "run_name": "Verify/8", "run_type": "iteration", "real_time": 1500.0, "cpu_time": 1400.0, "time_unit": "ns"},
    {"name": "Lower/64", "run_name": "Lower/64", "run_type": "iteration", "real_time": 2.5, "cpu_time": 2.4, "time_unit": "ms"}
  ]
}`

const googleRepeated = `{
  "benchmarks": [
    {"name": "Verify/8", "run_name": "Verify/8", "run_type": "iteration", "real_time": 1000.0, "time_unit": "ns"},
    {"name": "Verify/8", "run_name": "Verify/8", "run_type": "iteration", "real_time": 9000.0, "time_unit": "ns"},
    {"name": "Verify/8", "run_name": "Verify/8", "run_type": "iteration", "real_time": 1100.0, "time_unit": "ns"},
    {"name": "Verify/8_mean", "run_name": "Verify/8", "run_type": "aggregate", "aggregate_name": "mean", "real_time": 3700.0, "time_unit": "ns"},
    {"name": "Verify/8_median", "run_name": "Verify/8", "run_type": "aggregate", "aggregate_name": "median", "real_time": 1100.0, "time_unit": "ns"},
    {"name": "Verify/8_stddev", "run_name": "Verify/8", "run_type": "aggregate", "aggregate_name": "stddev", "real_time": 4590.0, "time_unit": "ns"}
  ]
}`

const criterionReport = "Name,Mean,MeanLB,MeanUB,Stddev,StddevLB,StddevUB\r\n" +
	"Core/Verify/8,1.5e-6,1.4e-6,1.6e-6,1e-8,1e-9,2e-8\r\n" +
	"\"Core/Optimize, deep\",2.5e-3,2.4e-3,2.6e-3,1e-5,1e-6,2e-5\r\n"

func near(left, right float64) bool {
	return math.Abs(left-right) <= 1e-6*math.Max(math.Abs(left), math.Abs(right))
}

func TestASingleRunIsItsOwnTimeInNanoseconds(t *testing.T) {
	times, err := readGoogleBenchmark(strings.NewReader(googleSingleRun))
	if err != nil {
		t.Fatalf("readGoogleBenchmark() returned error: %v", err)
	}
	if len(times) != 2 || !near(times["Verify/8"], 1500) || !near(times["Lower/64"], 2.5e6) {
		t.Fatalf("times = %v, want Verify/8 at 1500 ns and Lower/64 at 2.5 ms", times)
	}
}

func TestRepetitionsAreReadByTheirMedianAndNotTheirMean(t *testing.T) {
	times, err := readGoogleBenchmark(strings.NewReader(googleRepeated))
	if err != nil {
		t.Fatalf("readGoogleBenchmark() returned error: %v", err)
	}
	// One slow run moves the mean to 3700 ns and leaves the median at 1100.
	if len(times) != 1 || !near(times["Verify/8"], 1100) {
		t.Fatalf("times = %v, want the median of 1100 ns alone", times)
	}
}

func TestRepeatedRunsWithoutAnAggregateAreAveraged(t *testing.T) {
	report := `{"benchmarks": [
	  {"name": "A", "run_type": "iteration", "real_time": 100, "time_unit": "ns"},
	  {"name": "A", "run_type": "iteration", "real_time": 300, "time_unit": "ns"}]}`
	times, err := readGoogleBenchmark(strings.NewReader(report))
	if err != nil || !near(times["A"], 200) {
		t.Fatalf("times = %v (error %v), want A at 200 ns", times, err)
	}
}

func TestAGoogleReportThatCannotBeTrustedIsRefused(t *testing.T) {
	cases := map[string]string{
		"not JSON":             `benchmarks: none`,
		"no benchmark":         `{"benchmarks": []}`,
		"an unknown time unit": `{"benchmarks": [{"name": "A", "real_time": 1, "time_unit": "fortnights"}]}`,
		"a negative time":      `{"benchmarks": [{"name": "A", "real_time": -1, "time_unit": "ns"}]}`,
		"a reported error":     `{"benchmarks": [{"name": "A", "real_time": 1, "time_unit": "ns", "error_occurred": true, "error_message": "state"}]}`,
		"aggregates alone":     `{"benchmarks": [{"name": "A_mean", "run_name": "A", "run_type": "aggregate", "aggregate_name": "mean", "real_time": 1, "time_unit": "ns"}]}`,
	}
	for name, report := range cases {
		if times, err := readGoogleBenchmark(strings.NewReader(report)); err == nil {
			t.Errorf("a report with %s was read as %v", name, times)
		}
	}
}

func TestACriterionReportIsReadInNanosecondsWithQuotedNames(t *testing.T) {
	times, err := readCriterion(strings.NewReader(criterionReport))
	if err != nil {
		t.Fatalf("readCriterion() returned error: %v", err)
	}
	if len(times) != 2 || !near(times["Core/Verify/8"], 1500) || !near(times["Core/Optimize, deep"], 2.5e6) {
		t.Fatalf("times = %v, want 1500 ns and 2.5 ms", times)
	}
}

func TestACriterionReportThatWasAppendedToSkipsTheSecondHeader(t *testing.T) {
	report := criterionReport + "Name,Mean,MeanLB,MeanUB,Stddev,StddevLB,StddevUB\r\nCore/Wire/8,3e-6,0,0,0,0,0\r\n"
	times, err := readCriterion(strings.NewReader(report))
	if err != nil || len(times) != 3 || !near(times["Core/Wire/8"], 3000) {
		t.Fatalf("times = %v (error %v), want three benchmarks", times, err)
	}
}

func TestACriterionReportThatCannotBeTrustedIsRefused(t *testing.T) {
	cases := map[string]string{
		"nothing":              ``,
		"a header alone":       "Name,Mean\n",
		"no Mean column":       "Name,Average\nA,1\n",
		"a mean without digit": "Name,Mean\nA,fast\n",
		"a negative mean":      "Name,Mean\nA,-1\n",
		"a short row":          "Name,Other,Mean\nA\n",
	}
	for name, report := range cases {
		if times, err := readCriterion(strings.NewReader(report)); err == nil {
			t.Errorf("a report with %s was read as %v", name, times)
		}
	}
}

func writeResultSet(t *testing.T, files map[string]string) string {
	t.Helper()
	directory := t.TempDir()
	for name, contents := range files {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(contents), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return directory
}

func TestAResultSetNamesEachBenchmarkByItsFile(t *testing.T) {
	directory := writeResultSet(t, map[string]string{
		"core_benches.json": googleSingleRun,
		"haskell.csv":       criterionReport,
		"notes.txt":         "not a report",
	})
	if err := os.Mkdir(filepath.Join(directory, "nested.json"), 0o700); err != nil {
		t.Fatalf("create a directory: %v", err)
	}
	times, err := readBenchmarkResults(directory)
	if err != nil {
		t.Fatalf("readBenchmarkResults() returned error: %v", err)
	}
	if len(times) != 4 || !near(times["core_benches/Verify/8"], 1500) || !near(times["haskell/Core/Verify/8"], 1500) {
		t.Fatalf("times = %v, want four benchmarks under their file names", times)
	}
}

func TestAResultSetWithoutAReportOrWithABrokenOneIsAnError(t *testing.T) {
	if _, err := readBenchmarkResults(writeResultSet(t, map[string]string{"notes.txt": "x"})); err == nil {
		t.Fatal("a directory without a report was read")
	}
	if _, err := readBenchmarkResults(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("a directory that does not exist was read")
	}
	broken := writeResultSet(t, map[string]string{"core_benches.json": googleSingleRun, "xpp_benches.json": "{"})
	_, err := readBenchmarkResults(broken)
	if err == nil || !strings.Contains(err.Error(), "xpp_benches.json") {
		t.Fatalf("error = %v, want one that names the broken report", err)
	}
}

func verdicts(changes []benchmarkChange) map[string]benchmarkVerdict {
	result := map[string]benchmarkVerdict{}
	for _, change := range changes {
		result[change.Name] = change.Verdict
	}
	return result
}

func TestAComparisonJudgesEachBenchmarkAgainstTheThreshold(t *testing.T) {
	baseline := benchmarkTimes{"same": 1000, "inside": 1000, "edge": 1000, "slower": 1000, "faster": 1000, "gone": 1000, "zero": 0}
	candidate := benchmarkTimes{"same": 1000, "inside": 1090, "edge": 1100, "slower": 1101, "faster": 800, "new": 500, "zero": 5}
	changes := compareBenchmarks(baseline, candidate, 10)

	want := map[string]benchmarkVerdict{
		"same": benchmarkUnchanged, "inside": benchmarkUnchanged,
		// Exactly at the threshold is not beyond it.
		"edge":   benchmarkUnchanged,
		"slower": benchmarkSlower, "faster": benchmarkFaster,
		"gone": benchmarkRemoved, "new": benchmarkAdded,
		// Nothing can be said in percent of a baseline of zero.
		"zero": benchmarkUnchanged,
	}
	got := verdicts(changes)
	for name, verdict := range want {
		if got[name] != verdict {
			t.Errorf("%s is %s, want %s", name, got[name], verdict)
		}
	}
	if len(changes) != len(want) {
		t.Errorf("the comparison has %d rows, want %d", len(changes), len(want))
	}
	for index := 1; index < len(changes); index++ {
		if changes[index-1].Name >= changes[index].Name {
			t.Fatalf("rows are not sorted by name: %s before %s", changes[index-1].Name, changes[index].Name)
		}
	}
	if slowerBenchmarks(changes) != 1 {
		t.Errorf("slowerBenchmarks() = %d, want 1", slowerBenchmarks(changes))
	}
	for _, change := range changes {
		if change.Name == "faster" && !near(change.Change, -20) {
			t.Errorf("faster moved by %v %%, want -20", change.Change)
		}
	}
}

func TestAThresholdOfZeroCountsEveryMovement(t *testing.T) {
	changes := compareBenchmarks(benchmarkTimes{"a": 1000, "b": 1000, "c": 1000}, benchmarkTimes{"a": 1001, "b": 999, "c": 1000}, 0)
	got := verdicts(changes)
	if got["a"] != benchmarkSlower || got["b"] != benchmarkFaster || got["c"] != benchmarkUnchanged {
		t.Fatalf("verdicts = %v", got)
	}
}

func TestTimesAreWrittenInTheUnitAPersonReads(t *testing.T) {
	cases := map[float64]string{12.34: "12.3 ns", 1500: "1.500 us", 2.5e6: "2.500 ms", 3.25e9: "3.250 s", 999.9: "999.9 ns"}
	for nanoseconds, want := range cases {
		if got := formatBenchmarkTime(nanoseconds); got != want {
			t.Errorf("formatBenchmarkTime(%v) = %q, want %q", nanoseconds, got, want)
		}
	}
}

func TestAReportListsEveryBenchmarkSortedByName(t *testing.T) {
	var output bytes.Buffer
	if err := writeBenchmarkReport(&output, benchmarkTimes{"b/Two": 2.5e6, "a/One": 1500}); err != nil {
		t.Fatalf("writeBenchmarkReport() returned error: %v", err)
	}
	text := output.String()
	first, second := strings.Index(text, "`a/One`"), strings.Index(text, "`b/Two`")
	if first < 0 || second < 0 || first > second {
		t.Fatalf("the report does not list both benchmarks in order:\n%s", text)
	}
	for _, expected := range []string{"| Benchmark | Time |", "1.500 us", "2.500 ms", "2 benchmarks."} {
		if !strings.Contains(text, expected) {
			t.Fatalf("the report lacks %q:\n%s", expected, text)
		}
	}
}

func TestAComparisonIsWrittenWithWhatMovedFirst(t *testing.T) {
	changes := compareBenchmarks(
		benchmarkTimes{"same": 1000, "slower": 1000, "gone": 1000},
		benchmarkTimes{"same": 1000, "slower": 1500, "new": 500}, 10)
	var output bytes.Buffer
	if err := writeBenchmarkComparison(&output, changes, 10); err != nil {
		t.Fatalf("writeBenchmarkComparison() returned error: %v", err)
	}
	text := output.String()
	for _, expected := range []string{
		"4 benchmarks compared with a threshold of 10 %: 1 slower, 0 faster, 1 unchanged, 1 added, 1 removed.",
		"### Moved", "### All", "| `slower` | 1.000 us | 1.500 us | +50.0 % | slower |",
		"| `new` | - | 500.0 ns | - | added |", "| `gone` | 1.000 us | - | - | removed |",
	} {
		if !strings.Contains(text, expected) {
			t.Fatalf("the comparison lacks %q:\n%s", expected, text)
		}
	}
	if strings.Index(text, "### Moved") > strings.Index(text, "### All") {
		t.Fatalf("what moved does not come first:\n%s", text)
	}

	var quiet bytes.Buffer
	if err := writeBenchmarkComparison(&quiet, compareBenchmarks(benchmarkTimes{"a": 1}, benchmarkTimes{"a": 1}, 10), 10); err != nil {
		t.Fatalf("writeBenchmarkComparison() returned error: %v", err)
	}
	if strings.Contains(quiet.String(), "### Moved") {
		t.Fatalf("a comparison in which nothing moved has a section for what moved:\n%s", quiet.String())
	}
}
