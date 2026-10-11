// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
)

// haskellBenchmarkReport is the file of a result set that holds the
// Criterion benchmarks.
const haskellBenchmarkReport = "haskell.csv"

// benchmarkOptions are what the benchmark command can be told beyond the
// Bazel options it forwards.
type benchmarkOptions struct {
	// filter is a Google Benchmark regular expression; only the native
	// benchmarks whose name it matches are run. Criterion selects by other
	// rules, so the Haskell benchmarks are not narrowed by it.
	filter string
	// repetitions runs each native benchmark this many times and makes the
	// program report their median, which is what a comparison reads.
	repetitions int
	// output is the directory a result set is written to.
	output string
	// nativeOnly and haskellOnly leave the other half out.
	nativeOnly, haskellOnly bool
}

// validate refuses what cannot be meant before anything is built.
func (options benchmarkOptions) validate() error {
	if options.repetitions < 0 || options.repetitions > 100 {
		return errors.New("--repetitions must be an integer in [1, 100]")
	}
	if options.nativeOnly && options.haskellOnly {
		return errors.New("--native-only and --haskell-only leave nothing to run")
	}
	if options.filter != "" && options.haskellOnly {
		return errors.New("--filter selects native benchmarks; it has no meaning with --haskell-only")
	}
	if options.repetitions != 0 && options.haskellOnly {
		return errors.New("--repetitions repeats native benchmarks; it has no meaning with --haskell-only")
	}
	return nil
}

// resultDirectory creates the directory of the result set and gives its
// absolute path, or nothing when no result set was asked for. The programs
// run in other directories, so the path they are handed must not be relative.
func (options benchmarkOptions) resultDirectory() (string, error) {
	if options.output == "" {
		return "", nil
	}
	directory, err := filepath.Abs(options.output)
	if err != nil {
		return "", fmt.Errorf("cannot resolve the benchmark output directory: %w", err)
	}
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return "", fmt.Errorf("cannot create the benchmark output directory %q: %w", directory, err)
	}
	return directory, nil
}

// nativeArguments are the Google Benchmark options of one native program.
func (options benchmarkOptions) nativeArguments(directory, program string) []string {
	var arguments []string
	if options.filter != "" {
		arguments = append(arguments, "--benchmark_filter="+options.filter)
	}
	if options.repetitions != 0 {
		arguments = append(arguments,
			"--benchmark_repetitions="+strconv.Itoa(options.repetitions),
			"--benchmark_report_aggregates_only=false")
	}
	if directory != "" {
		arguments = append(arguments,
			"--benchmark_out="+filepath.Join(directory, program+".json"),
			"--benchmark_out_format=json")
	}
	return arguments
}

// criterionArguments are the Cabal options that make Criterion write its
// report into the result set. Each Criterion option is handed over on its
// own, so a directory with a space in its name stays one argument.
func (options benchmarkOptions) criterionArguments(directory string) []string {
	if directory == "" {
		return nil
	}
	return []string{"--benchmark-option=--csv", "--benchmark-option=" + filepath.Join(directory, haskellBenchmarkReport)}
}

// executeBenchmarkReport writes one result set as a table.
func executeBenchmarkReport(output io.Writer, directory, markdown string) error {
	times, err := readBenchmarkResults(directory)
	if err != nil {
		return err
	}
	return writeTo(output, markdown, func(target io.Writer) error { return writeBenchmarkReport(target, times) })
}

// executeBenchmarkComparison compares two result sets and fails when a
// benchmark became slower than the threshold allows, unless the comparison
// was asked to inform only.
func executeBenchmarkComparison(output io.Writer, baselineDirectory, candidateDirectory string, threshold float64, markdown string, informational bool) error {
	if threshold < 0 {
		return errors.New("--threshold must not be negative")
	}
	baseline, err := readBenchmarkResults(baselineDirectory)
	if err != nil {
		return fmt.Errorf("baseline: %w", err)
	}
	candidate, err := readBenchmarkResults(candidateDirectory)
	if err != nil {
		return fmt.Errorf("candidate: %w", err)
	}
	changes := compareBenchmarks(baseline, candidate, threshold)
	if err := writeTo(output, markdown, func(target io.Writer) error {
		return writeBenchmarkComparison(target, changes, threshold)
	}); err != nil {
		return err
	}
	if slower := slowerBenchmarks(changes); slower != 0 && !informational {
		return fmt.Errorf("%d benchmark(s) became more than %s %% slower", slower, strconv.FormatFloat(threshold, 'f', -1, 64))
	}
	return nil
}

// writeTo writes a report to the command's output and, when a file is named,
// to that file as well.
func writeTo(output io.Writer, path string, write func(io.Writer) error) error {
	if err := write(output); err != nil {
		return err
	}
	if path == "" {
		return nil
	}
	file, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("cannot create %q: %w", path, err)
	}
	if err := write(file); err != nil {
		file.Close()
		return fmt.Errorf("cannot write %q: %w", path, err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("cannot close %q: %w", path, err)
	}
	return nil
}
