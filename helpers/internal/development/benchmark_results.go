// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// A benchmark result set is a directory the benchmark command writes: one
// Google Benchmark JSON file for each native benchmark program and one
// Criterion CSV file for the Haskell benchmarks. The functions here read such
// a directory into one table of times, report it, and compare two of them.

// benchmarkTime is the time of one benchmark in nanoseconds for one
// iteration, under the name the result set gives it: the file without its
// extension, a slash, and the name of the benchmark inside the file.
type benchmarkTimes map[string]float64

// googleBenchmarkReport is the part of Google Benchmark's JSON output that a
// time is read from.
type googleBenchmarkReport struct {
	Benchmarks []struct {
		Name          string  `json:"name"`
		RunName       string  `json:"run_name"`
		RunType       string  `json:"run_type"`
		AggregateName string  `json:"aggregate_name"`
		RealTime      float64 `json:"real_time"`
		TimeUnit      string  `json:"time_unit"`
		ErrorOccurred bool    `json:"error_occurred"`
		ErrorMessage  string  `json:"error_message"`
	} `json:"benchmarks"`
}

// nanosecondsPer gives the length of a time unit of either tool.
func nanosecondsPer(unit string) (float64, error) {
	switch unit {
	case "ns", "":
		return 1, nil
	case "us":
		return 1e3, nil
	case "ms":
		return 1e6, nil
	case "s":
		return 1e9, nil
	default:
		return 0, fmt.Errorf("unknown time unit %q", unit)
	}
}

// readGoogleBenchmark reads the times of one program. With repetitions the
// program reports each run and then aggregates; the median is taken, which a
// single slow run does not move. Without them the one run is the time. A
// benchmark that is listed more than once without an aggregate is averaged.
func readGoogleBenchmark(reader io.Reader) (benchmarkTimes, error) {
	var report googleBenchmarkReport
	if err := json.NewDecoder(reader).Decode(&report); err != nil {
		return nil, fmt.Errorf("not Google Benchmark JSON: %w", err)
	}
	medians := benchmarkTimes{}
	sums := map[string]float64{}
	counts := map[string]int{}
	for _, entry := range report.Benchmarks {
		name := entry.RunName
		if name == "" {
			name = entry.Name
		}
		if entry.ErrorOccurred {
			return nil, fmt.Errorf("benchmark %s reported an error: %s", name, entry.ErrorMessage)
		}
		scale, err := nanosecondsPer(entry.TimeUnit)
		if err != nil {
			return nil, fmt.Errorf("benchmark %s: %w", name, err)
		}
		if math.IsNaN(entry.RealTime) || math.IsInf(entry.RealTime, 0) || entry.RealTime < 0 {
			return nil, fmt.Errorf("benchmark %s has no usable time: %v", name, entry.RealTime)
		}
		switch {
		case entry.RunType == "aggregate" && entry.AggregateName == "median":
			medians[name] = entry.RealTime * scale
		case entry.RunType == "aggregate":
			// Mean, standard deviation and coefficient of variation are not
			// times to compare.
		default:
			sums[name] += entry.RealTime * scale
			counts[name]++
		}
	}
	times := benchmarkTimes{}
	for name, count := range counts {
		times[name] = sums[name] / float64(count)
	}
	for name, median := range medians {
		times[name] = median
	}
	if len(times) == 0 {
		return nil, errors.New("the report holds no benchmark")
	}
	return times, nil
}

// readCriterion reads the times of a Criterion CSV report. Its first line
// names the columns; the mean is in seconds.
func readCriterion(reader io.Reader) (benchmarkTimes, error) {
	rows, err := csv.NewReader(reader).ReadAll()
	if err != nil {
		return nil, fmt.Errorf("not Criterion CSV: %w", err)
	}
	if len(rows) == 0 {
		return nil, errors.New("the report is empty")
	}
	nameColumn, meanColumn := -1, -1
	for index, title := range rows[0] {
		switch strings.TrimSpace(title) {
		case "Name":
			nameColumn = index
		case "Mean":
			meanColumn = index
		}
	}
	if nameColumn < 0 || meanColumn < 0 {
		return nil, errors.New("the report has no Name and Mean columns")
	}
	times := benchmarkTimes{}
	for _, row := range rows[1:] {
		if len(row) <= nameColumn || len(row) <= meanColumn {
			return nil, fmt.Errorf("a row of the report is shorter than its header: %v", row)
		}
		// Criterion repeats the header when it appends to an existing file.
		if strings.TrimSpace(row[nameColumn]) == "Name" {
			continue
		}
		seconds, err := strconv.ParseFloat(strings.TrimSpace(row[meanColumn]), 64)
		if err != nil || math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds < 0 {
			return nil, fmt.Errorf("benchmark %s has no usable mean: %q", row[nameColumn], row[meanColumn])
		}
		times[row[nameColumn]] = seconds * 1e9
	}
	if len(times) == 0 {
		return nil, errors.New("the report holds no benchmark")
	}
	return times, nil
}

// readBenchmarkResults reads every report of a result set. A directory
// without any is an error: a comparison with nothing is not a comparison that
// passed.
func readBenchmarkResults(directory string) (benchmarkTimes, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, fmt.Errorf("cannot read the benchmark results in %q: %w", directory, err)
	}
	all := benchmarkTimes{}
	reports := 0
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		extension := strings.ToLower(filepath.Ext(entry.Name()))
		var read func(io.Reader) (benchmarkTimes, error)
		switch extension {
		case ".json":
			read = readGoogleBenchmark
		case ".csv":
			read = readCriterion
		default:
			continue
		}
		path := filepath.Join(directory, entry.Name())
		file, err := os.Open(path)
		if err != nil {
			return nil, fmt.Errorf("cannot open %q: %w", path, err)
		}
		times, err := read(file)
		closeErr := file.Close()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if closeErr != nil {
			return nil, fmt.Errorf("cannot close %q: %w", path, closeErr)
		}
		program := strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name()))
		for name, time := range times {
			all[program+"/"+name] = time
		}
		reports++
	}
	if reports == 0 {
		return nil, fmt.Errorf("%q holds no benchmark report (*.json from Google Benchmark, *.csv from Criterion)", directory)
	}
	return all, nil
}

// formatBenchmarkTime writes a time with the unit a person reads it in.
func formatBenchmarkTime(nanoseconds float64) string {
	switch {
	case nanoseconds >= 1e9:
		return fmt.Sprintf("%.3f s", nanoseconds/1e9)
	case nanoseconds >= 1e6:
		return fmt.Sprintf("%.3f ms", nanoseconds/1e6)
	case nanoseconds >= 1e3:
		return fmt.Sprintf("%.3f us", nanoseconds/1e3)
	default:
		return fmt.Sprintf("%.1f ns", nanoseconds)
	}
}

// writeBenchmarkReport writes one result set as a Markdown table, sorted by
// name so that two reports of the same benchmarks line up.
func writeBenchmarkReport(output io.Writer, times benchmarkTimes) error {
	names := make([]string, 0, len(times))
	for name := range times {
		names = append(names, name)
	}
	sort.Strings(names)
	if _, err := fmt.Fprintf(output, "| Benchmark | Time |\n| --- | ---: |\n"); err != nil {
		return err
	}
	for _, name := range names {
		if _, err := fmt.Fprintf(output, "| `%s` | %s |\n", name, formatBenchmarkTime(times[name])); err != nil {
			return err
		}
	}
	_, err := fmt.Fprintf(output, "\n%d benchmarks.\n", len(names))
	return err
}

// benchmarkVerdict is what a comparison says of one benchmark.
type benchmarkVerdict string

const (
	benchmarkSlower    benchmarkVerdict = "slower"
	benchmarkFaster    benchmarkVerdict = "faster"
	benchmarkUnchanged benchmarkVerdict = "unchanged"
	benchmarkAdded     benchmarkVerdict = "added"
	benchmarkRemoved   benchmarkVerdict = "removed"
)

// benchmarkChange is one row of a comparison. Change is the candidate's time
// against the baseline's in percent: positive is slower.
type benchmarkChange struct {
	Name      string
	Baseline  float64
	Candidate float64
	Change    float64
	Verdict   benchmarkVerdict
}

// compareBenchmarks sets a candidate result set against a baseline. A
// benchmark is slower or faster when its time moved by more than the
// threshold, in percent; inside the threshold it is unchanged, since two runs
// of the same program on the same machine do not give the same time. A
// benchmark only one side has is added or removed and is never a regression:
// a comparison cannot say anything about a time it has once.
func compareBenchmarks(baseline, candidate benchmarkTimes, threshold float64) []benchmarkChange {
	names := map[string]bool{}
	for name := range baseline {
		names[name] = true
	}
	for name := range candidate {
		names[name] = true
	}
	changes := make([]benchmarkChange, 0, len(names))
	for name := range names {
		before, hadBefore := baseline[name]
		after, hasAfter := candidate[name]
		change := benchmarkChange{Name: name, Baseline: before, Candidate: after}
		switch {
		case !hadBefore:
			change.Verdict = benchmarkAdded
		case !hasAfter:
			change.Verdict = benchmarkRemoved
		case before == 0:
			// Nothing can be said in percent of a time of zero.
			change.Verdict = benchmarkUnchanged
		default:
			change.Change = (after - before) / before * 100
			switch {
			case change.Change > threshold:
				change.Verdict = benchmarkSlower
			case change.Change < -threshold:
				change.Verdict = benchmarkFaster
			default:
				change.Verdict = benchmarkUnchanged
			}
		}
		changes = append(changes, change)
	}
	sort.Slice(changes, func(left, right int) bool { return changes[left].Name < changes[right].Name })
	return changes
}

// slowerBenchmarks counts the regressions of a comparison.
func slowerBenchmarks(changes []benchmarkChange) int {
	count := 0
	for _, change := range changes {
		if change.Verdict == benchmarkSlower {
			count++
		}
	}
	return count
}

// writeBenchmarkComparison writes a comparison as Markdown: a line that says
// what was found, the benchmarks that moved, and then all of them.
func writeBenchmarkComparison(output io.Writer, changes []benchmarkChange, threshold float64) error {
	counts := map[benchmarkVerdict]int{}
	for _, change := range changes {
		counts[change.Verdict]++
	}
	var text strings.Builder
	fmt.Fprintf(&text, "%d benchmarks compared with a threshold of %s %%: %d slower, %d faster, %d unchanged, %d added, %d removed.\n",
		len(changes), strconv.FormatFloat(threshold, 'f', -1, 64), counts[benchmarkSlower], counts[benchmarkFaster],
		counts[benchmarkUnchanged], counts[benchmarkAdded], counts[benchmarkRemoved])
	row := func(change benchmarkChange) {
		before, after, moved := "-", "-", "-"
		if change.Verdict != benchmarkAdded {
			before = formatBenchmarkTime(change.Baseline)
		}
		if change.Verdict != benchmarkRemoved {
			after = formatBenchmarkTime(change.Candidate)
		}
		if change.Verdict != benchmarkAdded && change.Verdict != benchmarkRemoved {
			moved = fmt.Sprintf("%+.1f %%", change.Change)
		}
		fmt.Fprintf(&text, "| `%s` | %s | %s | %s | %s |\n", change.Name, before, after, moved, change.Verdict)
	}
	header := "| Benchmark | Baseline | Candidate | Change | Verdict |\n| --- | ---: | ---: | ---: | --- |\n"
	if counts[benchmarkSlower]+counts[benchmarkFaster] != 0 {
		text.WriteString("\n### Moved\n\n" + header)
		for _, change := range changes {
			if change.Verdict == benchmarkSlower || change.Verdict == benchmarkFaster {
				row(change)
			}
		}
	}
	text.WriteString("\n### All\n\n" + header)
	for _, change := range changes {
		row(change)
	}
	_, err := io.WriteString(output, text.String())
	return err
}
