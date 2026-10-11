// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBenchmarkOptionsRefuseWhatCannotBeMeant(t *testing.T) {
	valid := []benchmarkOptions{
		{}, {filter: "Verify"}, {repetitions: 1}, {repetitions: 100}, {output: "results"},
		{nativeOnly: true, filter: "Verify", repetitions: 5}, {haskellOnly: true, output: "results"},
	}
	for _, options := range valid {
		if err := options.validate(); err != nil {
			t.Errorf("validate(%+v) returned error: %v", options, err)
		}
	}
	invalid := map[string]benchmarkOptions{
		"--repetitions":  {repetitions: 101},
		"nothing to run": {nativeOnly: true, haskellOnly: true},
		"--filter":       {haskellOnly: true, filter: "Verify"},
		"native":         {haskellOnly: true, repetitions: 3},
	}
	for expected, options := range invalid {
		err := options.validate()
		if err == nil || !strings.Contains(err.Error(), expected) {
			t.Errorf("validate(%+v) error = %v, want one that mentions %q", options, err, expected)
		}
	}
	if err := (benchmarkOptions{repetitions: -1}).validate(); err == nil {
		t.Error("a negative number of repetitions was accepted")
	}
}

func TestNativeBenchmarksGetOnlyTheOptionsThatWereGiven(t *testing.T) {
	if arguments := (benchmarkOptions{}).nativeArguments("", "core_benches"); len(arguments) != 0 {
		t.Fatalf("no option gave %v, want no argument", arguments)
	}
	directory := filepath.Join("out", "set")
	arguments := (benchmarkOptions{filter: "Verify/.*", repetitions: 7}).nativeArguments(directory, "core_benches")
	want := []string{
		"--benchmark_filter=Verify/.*", "--benchmark_repetitions=7", "--benchmark_report_aggregates_only=false",
		"--benchmark_out=" + filepath.Join(directory, "core_benches.json"), "--benchmark_out_format=json",
	}
	if strings.Join(arguments, "\n") != strings.Join(want, "\n") {
		t.Fatalf("arguments = %v, want %v", arguments, want)
	}
}

func TestCriterionGetsItsReportAsSeparateArguments(t *testing.T) {
	if arguments := (benchmarkOptions{}).criterionArguments(""); arguments != nil {
		t.Fatalf("no result set gave %v, want no argument", arguments)
	}
	// A directory with a space must stay one argument.
	directory := filepath.Join("my results", "set")
	arguments := (benchmarkOptions{}).criterionArguments(directory)
	want := []string{"--benchmark-option=--csv", "--benchmark-option=" + filepath.Join(directory, "haskell.csv")}
	if strings.Join(arguments, "\n") != strings.Join(want, "\n") {
		t.Fatalf("arguments = %v, want %v", arguments, want)
	}
}

func TestTheResultDirectoryIsCreatedAndAbsolute(t *testing.T) {
	if directory, err := (benchmarkOptions{}).resultDirectory(); err != nil || directory != "" {
		t.Fatalf("no output gave %q (error %v), want nothing", directory, err)
	}
	wanted := filepath.Join(t.TempDir(), "nested", "set")
	directory, err := (benchmarkOptions{output: wanted}).resultDirectory()
	if err != nil {
		t.Fatalf("resultDirectory() returned error: %v", err)
	}
	if !filepath.IsAbs(directory) {
		t.Fatalf("resultDirectory() = %q, want an absolute path", directory)
	}
	if info, err := os.Stat(directory); err != nil || !info.IsDir() {
		t.Fatalf("the result directory was not created: %v", err)
	}
}

func TestAComparisonFailsOnARegressionUnlessItOnlyInforms(t *testing.T) {
	baseline := writeResultSet(t, map[string]string{"core_benches.json": googleSingleRun})
	slower := writeResultSet(t, map[string]string{"core_benches.json": strings.Replace(googleSingleRun, `"real_time": 1500.0`, `"real_time": 3000.0`, 1)})

	var output bytes.Buffer
	err := executeBenchmarkComparison(&output, baseline, slower, 10, "", false)
	if err == nil || !strings.Contains(err.Error(), "1 benchmark(s) became more than 10 % slower") {
		t.Fatalf("error = %v, want the count of regressions", err)
	}
	if !strings.Contains(output.String(), "| `core_benches/Verify/8` | 1.500 us | 3.000 us | +100.0 % | slower |") {
		t.Fatalf("the comparison was not written before the failure:\n%s", output.String())
	}

	output.Reset()
	if err := executeBenchmarkComparison(&output, baseline, slower, 10, "", true); err != nil {
		t.Fatalf("an informational comparison failed: %v", err)
	}
	if !strings.Contains(output.String(), "1 slower") {
		t.Fatalf("an informational comparison does not report the regression:\n%s", output.String())
	}

	// A wide enough threshold makes the same movement unremarkable.
	if err := executeBenchmarkComparison(&bytes.Buffer{}, baseline, slower, 150, "", false); err != nil {
		t.Fatalf("a movement inside the threshold failed the comparison: %v", err)
	}
	// The same set against itself never fails.
	if err := executeBenchmarkComparison(&bytes.Buffer{}, baseline, baseline, 0, "", false); err != nil {
		t.Fatalf("a set compared with itself failed: %v", err)
	}
}

func TestAComparisonSaysWhichSideCouldNotBeRead(t *testing.T) {
	good := writeResultSet(t, map[string]string{"core_benches.json": googleSingleRun})
	empty := t.TempDir()
	if err := executeBenchmarkComparison(&bytes.Buffer{}, empty, good, 10, "", false); err == nil || !strings.HasPrefix(err.Error(), "baseline:") {
		t.Fatalf("error = %v, want one that names the baseline", err)
	}
	if err := executeBenchmarkComparison(&bytes.Buffer{}, good, empty, 10, "", false); err == nil || !strings.HasPrefix(err.Error(), "candidate:") {
		t.Fatalf("error = %v, want one that names the candidate", err)
	}
	if err := executeBenchmarkComparison(&bytes.Buffer{}, good, good, -1, "", false); err == nil {
		t.Fatal("a negative threshold was accepted")
	}
}

func TestReportsAreAlsoWrittenToTheFileThatIsNamed(t *testing.T) {
	results := writeResultSet(t, map[string]string{"core_benches.json": googleSingleRun, "haskell.csv": criterionReport})
	path := filepath.Join(t.TempDir(), "report.md")
	var output bytes.Buffer
	if err := executeBenchmarkReport(&output, results, path); err != nil {
		t.Fatalf("executeBenchmarkReport() returned error: %v", err)
	}
	written, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("the report file was not written: %v", err)
	}
	if string(written) != output.String() || !strings.Contains(output.String(), "4 benchmarks.") {
		t.Fatalf("the file and the output differ, or lack the count:\n%s\n---\n%s", written, output.String())
	}
	if err := executeBenchmarkReport(&bytes.Buffer{}, results, filepath.Join(t.TempDir(), "missing", "report.md")); err == nil {
		t.Fatal("a report file in a directory that does not exist was written")
	}
}

func TestBenchmarkCommandsRefuseBadInvocationsBeforeAnyProcess(t *testing.T) {
	for _, args := range [][]string{
		{"benchmark", "extra"}, {"benchmark", "extra", "--", "--jobs=4"}, {"benchmark", "--", "--config=private"},
		{"benchmark", "--repetitions", "500"}, {"benchmark", "--native-only", "--haskell-only"},
		{"benchmark", "--haskell-only", "--filter", "Verify"}, {"benchmark", "--unknown"},
		{"benchmark-report"}, {"benchmark-report", "one", "two"},
		{"benchmark-compare", "one"}, {"benchmark-compare", "one", "two", "three"},
		{"benchmark-compare", "one", "two", "--threshold", "many"},
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

func TestTheCompareCommandReadsTwoResultSets(t *testing.T) {
	baseline := writeResultSet(t, map[string]string{"core_benches.json": googleSingleRun})
	slower := writeResultSet(t, map[string]string{"core_benches.json": strings.Replace(googleSingleRun, `"real_time": 1500.0`, `"real_time": 3000.0`, 1)})

	var output bytes.Buffer
	command := newCommand(fakeRunner{}, &output, &output)
	command.SetArgs([]string{"benchmark-compare", baseline, slower, "--threshold", "25"})
	if err := command.Execute(); err == nil || !strings.Contains(err.Error(), "25 % slower") {
		t.Fatalf("error = %v, want a regression beyond 25 %%", err)
	}
	if !strings.Contains(output.String(), "threshold of 25 %") {
		t.Fatalf("the command did not write the comparison:\n%s", output.String())
	}

	output.Reset()
	command = newCommand(fakeRunner{}, &output, &output)
	command.SetArgs([]string{"benchmark-compare", baseline, slower, "--informational"})
	if err := command.Execute(); err != nil {
		t.Fatalf("an informational comparison failed: %v", err)
	}

	output.Reset()
	command = newCommand(fakeRunner{}, &output, &output)
	command.SetArgs([]string{"benchmark-report", baseline})
	if err := command.Execute(); err != nil || !strings.Contains(output.String(), "`core_benches/Verify/8`") {
		t.Fatalf("benchmark-report wrote %q (error %v)", output.String(), err)
	}
}
