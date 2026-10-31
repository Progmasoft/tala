// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// The native C ABI wrapper cannot feed back GHC branches. This executable is
// rebuilt in an isolated HPC tree and retains inputs that hit new production
// ticks, rather than pretending native callback coverage represents Haskell.
func runHaskellFuzz(repository, corpusRoot, artifacts string, duration, jobs int, runner commandRunner) error {
	directory := filepath.Join(repository, "Talac")
	options := []string{"--enable-coverage", "--disable-tests", "--builddir=dist-fuzz-coverage"}
	build := append([]string{"build", "exe:frontend-fuzz"}, options...)
	if err := runner.Run(directory, nil, "cabal", build...); err != nil {
		return fmt.Errorf("HPC frontend build failed: %w", err)
	}
	arguments := append([]string{"list-bin", "exe:frontend-fuzz"}, options...)
	binary, err := runner.OutputIn(directory, "cabal", arguments...)
	if err != nil || !filepath.IsAbs(binary) || strings.ContainsAny(binary, "\r\n") {
		return fmt.Errorf("could not resolve HPC frontend executable: %q (%v)", binary, err)
	}
	// Stages share only the read-only executable: each has its own corpus,
	// tick file, report and artifact directory, so they may run together.
	var console sync.Mutex
	stages := []string{"lexer", "parser", "source"}
	tasks := make([]fuzzTask, 0, len(stages))
	for _, stage := range stages {
		tasks = append(tasks, fuzzTask{run: func() error {
			corpus := filepath.Join(corpusRoot, "haskell-"+stage)
			resultPath := filepath.Join(artifacts, "haskell-"+stage)
			for _, path := range []string{corpus, resultPath} {
				if err := os.MkdirAll(path, 0o700); err != nil {
					return err
				}
			}
			if err := syncSeedCorpus(filepath.Join(repository, "Talac", "Fuzzing", "Corpus", stage), corpus); err != nil {
				return err
			}
			// An HPC executable loads an existing tick file at startup and aborts
			// when its module hashes belong to an earlier build. Give every stage a
			// fresh file beside its report instead of the default one in the
			// working directory, which would also leave output in the source tree.
			tickFile := filepath.Join(resultPath, "frontend-fuzz.tix")
			if err := os.Remove(tickFile); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("could not reset the HPC tick file: %w", err)
			}
			// The engine writes its report to this file only after a completed
			// campaign. Remove an earlier one so a crashed run cannot inherit it.
			reportFile := filepath.Join(resultPath, "campaign.txt")
			if err := os.Remove(reportFile); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("could not reset the HPC campaign report: %w", err)
			}
			output, runErr := runner.RunWithInput(directory, []string{"HPCTIXFILE=" + tickFile}, "", binary, stage, strconv.Itoa(duration), corpus, resultPath, "12345")
			console.Lock()
			fmt.Print(output)
			console.Unlock()
			if err := os.WriteFile(filepath.Join(resultPath, "output.log"), []byte(output), 0o600); err != nil {
				return err
			}
			stats, statsErr := readHaskellFuzzReport(reportFile, output, stage)
			record := map[string]any{"stage": stage, "seconds": duration, "coverage_engine": "ghc-hpc", "asan_instrumented": false, "heap_limit_mib": 512, "statistics": stats, "success": runErr == nil && statsErr == nil}
			report, err := json.MarshalIndent(record, "", "  ")
			if err != nil {
				return err
			}
			if err := os.WriteFile(filepath.Join(resultPath, "campaign.json"), report, 0o600); err != nil {
				return err
			}
			if runErr != nil {
				return fmt.Errorf("HPC %s campaign failed; artifacts in %q: %w", stage, resultPath, runErr)
			}
			if statsErr != nil {
				return statsErr
			}
			return nil
		}})
	}
	return runFuzzTasks(jobs, tasks)
}

// readHaskellFuzzReport validates the report file the engine wrote for this
// run. Captured process output interleaves stdout with stderr, where the GHC
// runtime may print its own diagnostics after the report; those lines are kept
// in the log but are not statistics. The output must still announce the report,
// so a stale or hand-placed file is never accepted without a completed run.
func readHaskellFuzzReport(reportFile, output, stage string) (map[string]uint64, error) {
	if !strings.Contains(output, "HPC_FUZZ_RESULT") {
		return nil, fmt.Errorf("HPC %s campaign omitted its coverage report", stage)
	}
	report, err := os.ReadFile(reportFile)
	if err != nil {
		return nil, fmt.Errorf("HPC %s campaign did not write its report file: %w", stage, err)
	}
	return parseHaskellFuzzStatistics("HPC_FUZZ_RESULT\n"+string(report), stage)
}

func parseHaskellFuzzStatistics(output, stage string) (map[string]uint64, error) {
	_, report, found := strings.Cut(output, "HPC_FUZZ_RESULT\n")
	if !found { // Windows process output may have CRLF newlines.
		_, report, found = strings.Cut(output, "HPC_FUZZ_RESULT\r\n")
	}
	if !found {
		return nil, fmt.Errorf("HPC %s campaign omitted its coverage report", stage)
	}
	values := make(map[string]uint64)
	stageSeen := false
	for _, line := range strings.Split(strings.ReplaceAll(report, "\r\n", "\n"), "\n") {
		if line == "" {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			return nil, fmt.Errorf("malformed HPC report line: %q", line)
		}
		if key == "stage" {
			if stageSeen || value != stage {
				return nil, fmt.Errorf("unexpected or duplicate HPC stage: %q", value)
			}
			stageSeen = true
			continue
		}
		if _, duplicate := values[key]; duplicate {
			return nil, fmt.Errorf("duplicate HPC statistic: %s", key)
		}
		number, err := strconv.ParseUint(value, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid HPC statistic %s: %w", key, err)
		}
		values[key] = number
	}
	if !stageSeen || values["executed_units"] == 0 || values["covered_ticks"] == 0 || values["covered_ticks"] > values["available_ticks"] {
		return nil, fmt.Errorf("HPC %s campaign did not prove production coverage", stage)
	}
	for _, key := range []string{"new_units_added", "seed"} {
		if _, found := values[key]; !found {
			return nil, fmt.Errorf("HPC report omitted %s", key)
		}
	}
	return values, nil
}
