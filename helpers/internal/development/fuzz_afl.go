// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"bufio"
	"crypto/sha1"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// aflReport is the file of an AFL++ campaign's results in its artifacts.
const aflReport = "afl-campaigns.json"

// aflPerInputMilliseconds matches the 30-second per-input limit of the
// libFuzzer campaigns, so a slow input is a finding under both engines.
const aflPerInputMilliseconds = "30000"

// aflFuzzTargets are the targets AFL++ runs: those that load no Haskell
// frontend and start no threads. AFL++ starts a fresh process image for
// every input through its fork server, and the GHC runtime's start-up would
// dominate each execution; a threaded target's findings depend on
// scheduling, which AFL++ neither controls nor reproduces.
func aflFuzzTargets() []fuzzTarget {
	var targets []fuzzTarget
	for _, target := range nativeFuzzTargets() {
		if !target.frontend && !target.threaded {
			targets = append(targets, target)
		}
	}
	return targets
}

// aflBuildArguments builds the libFuzzer drivers of the targets with AFL++'s
// compiler. With cmplog the build records the operands of comparisons, which
// afl-fuzz uses to solve magic values such as the wire formats' headers; that
// build carries no sanitizer, as AFL++ recommends for its CmpLog binary.
func aflBuildArguments(sanitizerConfiguration string, cmplog bool, targets []fuzzTarget) []string {
	arguments := []string{"build", "--config=afl-linux"}
	if cmplog {
		arguments = append(arguments, "--action_env=AFL_LLVM_CMPLOG=1")
	} else if sanitizerConfiguration != "" {
		arguments = append(arguments, "--config="+sanitizerConfiguration)
	}
	for _, target := range targets {
		arguments = append(arguments, target.label)
	}
	return arguments
}

// aflEnvironment adds what afl-fuzz requires of a sanitized target, and what
// a CI runner needs, to the sanitizer settings of the libFuzzer campaigns.
// afl-fuzz refuses sanitizer options that do not abort on an error or that
// symbolize, because it detects a crash by the abort signal.
func aflEnvironment(sanitizer []string) []string {
	environment := make([]string, 0, len(sanitizer)+4)
	for _, setting := range fuzzSanitizerEnvironment(sanitizer) {
		if strings.HasPrefix(setting, "ASAN_OPTIONS=") || strings.HasPrefix(setting, "UBSAN_OPTIONS=") {
			setting += ":abort_on_error=1:symbolize=0"
		}
		environment = append(environment, setting)
	}
	return append(environment,
		"AFL_NO_UI=1",
		"AFL_SKIP_CPUFREQ=1",
		// A hosted runner pipes core dumps to a handler AFL++ cannot change;
		// crashes are still detected through the abort signal.
		"AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1",
	)
}

// aflFuzzArguments runs one target for the given time with its CmpLog twin.
func aflFuzzArguments(input, output, program, cmplog string, target fuzzTarget, seconds int) []string {
	return []string{
		"-i", input,
		"-o", output,
		"-V", strconv.Itoa(seconds),
		"-G", target.maxLength,
		"-t", aflPerInputMilliseconds,
		"-m", "none",
		"-c", cmplog,
		"--", program,
	}
}

// aflFindings lists the inputs afl-fuzz kept in one of its finding
// directories, crashes or hangs. Each holds a README that is not an input.
func aflFindings(directory string) ([]string, error) {
	entries, err := os.ReadDir(directory)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var findings []string
	for _, entry := range entries {
		if entry.IsDir() || entry.Name() == "README.txt" {
			continue
		}
		findings = append(findings, filepath.Join(directory, entry.Name()))
	}
	return findings, nil
}

// exportAFLQueue adds every input afl-fuzz kept to the target's corpus under
// the name libFuzzer gives an input, the SHA-1 of its content, so the
// libFuzzer campaigns start from what AFL++ reached and no input is stored
// twice.
func exportAFLQueue(queue, corpus string) (int, error) {
	entries, err := os.ReadDir(queue)
	if err != nil {
		return 0, err
	}
	added := 0
	for _, entry := range entries {
		// afl-fuzz names an input id:NNNNNN, or id_NNNNNN where a file name
		// cannot hold a colon.
		if !entry.Type().IsRegular() || !(strings.HasPrefix(entry.Name(), "id:") || strings.HasPrefix(entry.Name(), "id_")) {
			continue
		}
		seed, err := os.ReadFile(filepath.Join(queue, entry.Name()))
		if err != nil {
			return added, err
		}
		target := filepath.Join(corpus, fmt.Sprintf("%x", sha1.Sum(seed)))
		if _, err := os.Lstat(target); err == nil {
			continue
		}
		if err := writeSeedExclusive(target, seed); err != nil {
			return added, err
		}
		added++
	}
	return added, nil
}

// aflArtifactName is the portable name of a finding of afl-fuzz: the target,
// crashes or hangs, and the name afl-fuzz gave the input with every character
// that a file of an artifact may not hold replaced.
func aflArtifactName(program, kind, name string) string {
	portable := strings.Map(func(character rune) rune {
		switch {
		case character >= 'a' && character <= 'z', character >= 'A' && character <= 'Z',
			character >= '0' && character <= '9', character == '-', character == '_', character == '.':
			return character
		default:
			return '_'
		}
	}, name)
	return program + "-" + kind + "-" + portable
}

// aflStatistics reads the counters afl-fuzz writes to fuzzer_stats.
func aflStatistics(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	statistics := map[string]string{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		key, value, found := strings.Cut(scanner.Text(), ":")
		if found {
			statistics[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return statistics, scanner.Err()
}

// runAFLCampaign runs AFL++ over the targets that suit it. It shares the
// corpus, the sanitizers and the time budget of the libFuzzer campaigns, so
// the two engines feed each other: AFL++ starts from what libFuzzer kept and
// leaves what it reaches for the next libFuzzer run.
func runAFLCampaign(repository string, currentHost host, runner commandRunner) error {
	if currentHost.kind != hostLinux {
		return errors.New("AFL++ campaigns run on Linux, where afl-fuzz and its fork server are supported")
	}
	duration, err := fuzzDuration(false, os.Getenv("TALA_FUZZ_SECONDS"))
	if err != nil {
		return err
	}
	targets := aflFuzzTargets()
	if selection := os.Getenv(fuzzTargetsVariable); selection != "" {
		selected, haskell, err := selectFuzzTargets(targets, selection)
		if err != nil {
			return fmt.Errorf("fuzz-afl runs targets without the frontend or threads only: %w", err)
		}
		if haskell || len(selected) == 0 {
			return errors.New("fuzz-afl runs targets without the frontend or threads only; the selection names none")
		}
		targets = selected
	}
	tools := map[string]string{}
	for _, tool := range []string{"afl-fuzz", "afl-clang-fast", "afl-clang-fast++"} {
		path, err := runner.LookPath(tool)
		if err != nil {
			return fmt.Errorf("%s was not found; install AFL++ (Ubuntu: apt install afl++, Fedora: dnf install american-fuzzy-lop)", tool)
		}
		tools[tool] = path
	}
	bazel, err := findBazel(runner)
	if err != nil {
		return err
	}
	selected, err := selectSanitizer(currentHost, "address-undefined")
	if err != nil {
		return err
	}
	selected.environment, err = sanitizerEnvironment(currentHost, selected, runner)
	if err != nil {
		return err
	}
	temporaryRoot := os.Getenv("RUNNER_TEMP")
	if temporaryRoot == "" {
		temporaryRoot = os.TempDir()
	}
	work, err := os.MkdirTemp(temporaryRoot, "tala-fuzz-")
	if err != nil {
		return fmt.Errorf("could not create fuzz work directory: %w", err)
	}
	persistentCorpus := os.Getenv("TALA_FUZZ_CORPUS")
	corpusRoot := persistentCorpus
	if corpusRoot == "" {
		corpusRoot = filepath.Join(work, "corpus")
	}
	artifacts := filepath.Join(work, "artifacts")
	programs := filepath.Join(work, "programs")
	for _, directory := range []string{artifacts, programs} {
		if err := os.Mkdir(directory, 0o700); err != nil {
			return fmt.Errorf("could not prepare %q: %w", directory, err)
		}
	}
	for _, target := range targets {
		corpus := filepath.Join(corpusRoot, target.corpus)
		if err := os.MkdirAll(corpus, 0o700); err != nil {
			return fmt.Errorf("could not prepare %s corpus; preserved %q: %w", target.corpus, work, err)
		}
		if target.corpus == "wire" {
			continue
		}
		if err := syncSeedCorpus(filepath.Join(repository, "Talac", "Fuzzing", "Corpus", target.corpus), corpus); err != nil {
			return fmt.Errorf("could not synchronize the versioned %s seed corpus: %w", target.corpus, err)
		}
	}
	if fuzzTargetSelected(targets, "wire") {
		// As in the libFuzzer campaign, the wire seeds come from the
		// production writers, through the smoke program built normally.
		if err := runner.Run(repository, nil, bazel, cachedBuild([]string{"build", "--config=" + selected.config, "//Talac/Fuzzing:wire_fuzz_smoke"})...); err != nil {
			return fmt.Errorf("could not build the wire smoke program; preserved %q: %w", work, err)
		}
		generated := filepath.Join(work, "generated-wire-corpus")
		smoke := filepath.Join(repository, "bazel-bin", "Talac", "Fuzzing", "wire_fuzz_smoke"+currentHost.executable)
		if err := runner.Run(repository, selected.environment, smoke, "-Write-Corpus", generated); err != nil {
			return fmt.Errorf("could not export valid wire seeds; preserved %q: %w", work, err)
		}
		if err := syncSeedCorpus(generated, filepath.Join(corpusRoot, "wire")); err != nil {
			return fmt.Errorf("could not add generated wire seeds to the corpus: %w", err)
		}
	}
	// The sanitized build and the CmpLog build write the same paths, so each
	// is copied out before the other is built.
	for _, cmplog := range []bool{false, true} {
		if err := runner.Run(repository, nil, bazel, cachedBuild(aflBuildArguments(selected.config, cmplog, targets))...); err != nil {
			return fmt.Errorf("could not build the AFL++ targets; preserved %q: %w", work, err)
		}
		for _, target := range targets {
			packagePath, _, _ := strings.Cut(strings.TrimPrefix(target.label, "//"), ":")
			built := filepath.Join(repository, "bazel-bin", filepath.FromSlash(packagePath), target.binary)
			name := target.binary
			if cmplog {
				name += ".cmplog"
			}
			if err := copyFile(built, filepath.Join(programs, name), 0o755); err != nil {
				return fmt.Errorf("could not stage %s; preserved %q: %w", name, work, err)
			}
		}
	}
	// afl-fuzz names its files id:000001,src:... and upload-artifact rejects
	// a colon, so its output stays outside the work directory CI uploads;
	// the findings are copied into the artifacts under portable names.
	aflOutput, err := os.MkdirTemp(temporaryRoot, "tala-afl-")
	if err != nil {
		return fmt.Errorf("could not create the AFL++ output directory: %w", err)
	}
	environment := aflEnvironment(selected.environment)
	records := make([]map[string]any, 0, len(targets))
	var failures []string
	for _, target := range targets {
		output := filepath.Join(aflOutput, target.corpus)
		corpus := filepath.Join(corpusRoot, target.corpus)
		program := filepath.Join(programs, target.binary)
		fmt.Printf("AFL++ runs %s for %d seconds.\n", target.binary, duration)
		runErr := runner.Run(work, environment, tools["afl-fuzz"],
			aflFuzzArguments(corpus, output, program, program+".cmplog", target, duration)...)
		record := map[string]any{"target": target.binary, "seconds": duration, "sanitizer": selected.config}
		statistics, statisticsErr := aflStatistics(filepath.Join(output, "default", "fuzzer_stats"))
		if statisticsErr == nil {
			for _, key := range []string{"execs_done", "execs_per_sec", "corpus_count", "bitmap_cvg", "edges_found", "saved_crashes", "saved_hangs"} {
				record[key] = statistics[key]
			}
		}
		crashes, err := aflFindings(filepath.Join(output, "default", "crashes"))
		if err != nil {
			return err
		}
		hangs, err := aflFindings(filepath.Join(output, "default", "hangs"))
		if err != nil {
			return err
		}
		findings := append(crashes, hangs...)
		for _, finding := range findings {
			kind := filepath.Base(filepath.Dir(finding))
			if err := copyFile(finding, filepath.Join(artifacts, aflArtifactName(target.binary, kind, filepath.Base(finding))), 0o600); err != nil {
				return err
			}
		}
		added, exportErr := exportAFLQueue(filepath.Join(output, "default", "queue"), corpus)
		record["corpusAdded"] = added
		records = append(records, record)
		switch {
		case runErr != nil:
			failures = append(failures, fmt.Sprintf("%s: afl-fuzz failed: %v", target.binary, runErr))
		case statisticsErr != nil:
			failures = append(failures, fmt.Sprintf("%s: afl-fuzz wrote no statistics: %v", target.binary, statisticsErr))
		case len(crashes) != 0 || len(hangs) != 0:
			failures = append(failures, fmt.Sprintf("%s: %d crashes and %d hangs, kept in %s", target.binary, len(crashes), len(hangs), artifacts))
		case exportErr != nil:
			failures = append(failures, fmt.Sprintf("%s: could not add the AFL++ queue to the corpus: %v", target.binary, exportErr))
		default:
			fmt.Printf("%s: %s executions, %s edges, %d new corpus inputs.\n", target.binary, record["execs_done"], record["edges_found"], added)
		}
	}
	report, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(artifacts, aflReport), append(report, '\n'), 0o600); err != nil {
		return err
	}
	if len(failures) != 0 {
		return fmt.Errorf("AFL++ campaign failed; preserved %q and %q:\n%s", work, aflOutput, strings.Join(failures, "\n"))
	}
	if os.Getenv("CI") == "true" {
		fmt.Printf("AFL++ campaign logs preserved in %s.\n", work)
		return nil
	}
	if err := os.RemoveAll(aflOutput); err != nil {
		return fmt.Errorf("could not remove the AFL++ output %q: %w", aflOutput, err)
	}
	if err := removeSuccessfulFuzzWork(temporaryRoot, work); err != nil {
		return err
	}
	fmt.Println("All AFL++ targets completed without a crash or a hang.")
	return nil
}
