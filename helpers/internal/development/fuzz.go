// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

func fuzzConfiguration(currentHost host) (string, error) {
	switch currentHost.kind {
	case hostWindows:
		return "fuzz-windows", nil
	case hostMacOS:
		return "fuzz-macos", nil
	case hostLinux:
		return "fuzz-linux", nil
	default:
		return "", errors.New("coverage-guided fuzzing requires a supported host")
	}
}

func macOSFuzzerRuntime(root string) (string, error) {
	if root == "" {
		return "", errors.New("LLVM_ROOT is required to locate the macOS libFuzzer runtime")
	}
	matches, err := filepath.Glob(filepath.Join(root, "lib", "clang", "*", "lib", "darwin", "libclang_rt.fuzzer_osx.a"))
	if err != nil || len(matches) != 1 {
		return "", fmt.Errorf("expected exactly one Homebrew LLVM macOS libFuzzer runtime under %q, found %d", root, len(matches))
	}
	return matches[0], nil
}

// Smoke programs own main; only campaign drivers may link libFuzzer's
// main. Sharing one global fuzz profile with both groups duplicates main on
// Linux, where -fsanitize=fuzzer pulls the driver in unconditionally.
func fuzzBuildArguments(configuration, sanitizerConfiguration, macRuntime string) ([]string, []string) {
	smoke := []string{"build"}
	campaign := []string{"build", "--config=" + configuration}
	if sanitizerConfiguration != "" {
		smoke = append(smoke, "--config="+sanitizerConfiguration)
		campaign = append(campaign, "--config="+sanitizerConfiguration)
	}
	if macRuntime != "" {
		campaign = append(campaign, "--linkopt="+macRuntime)
	}
	smoke = append(smoke, "//Compiler/Fuzzing:wire_fuzz_smoke", "//Compiler/Fuzzing:source_fuzz_smoke", "//Compiler/Fuzzing:source_execution_smoke", "//Compiler/Fuzzing:source_expression_smoke", "//Compiler/Fuzzing:source_feature_smoke", "//Compiler/Fuzzing:source_console_smoke")
	for _, target := range nativeFuzzTargets() {
		campaign = append(campaign, target.label)
	}
	return smoke, campaign
}

// CI OOM reports showed 245 MiB quarantined versus 35 MiB live memory. Keep
// a nonzero UAF detection window without consuming the target's RSS budget
// predominantly with ASan's intentionally retained freed-allocation cache.
func fuzzSanitizerEnvironment(environment []string) []string {
	result := append([]string(nil), environment...)
	for index, setting := range result {
		if strings.HasPrefix(setting, "ASAN_OPTIONS=") {
			result[index] = setting + ":quarantine_size_mb=64:thread_local_quarantine_size_kb=256"
		}
	}
	return result
}

func runFuzzCampaign(repository string, currentHost host, runner commandRunner, stress bool, asan bool) error {
	duration, err := fuzzDuration(stress, os.Getenv("VXS_FUZZ_SECONDS"))
	if err != nil {
		return err
	}
	// A selection narrows what is run, not what is built or smoke-tested:
	// the smoke programs are the precondition of every campaign.
	targets, haskell, err := selectFuzzTargets(nativeFuzzTargets(), os.Getenv(fuzzTargetsVariable))
	if err != nil {
		return err
	}
	configuration, err := fuzzConfiguration(currentHost)
	if err != nil {
		return err
	}
	frontendLibrary, err := buildFrontendLibrary(repository, runner)
	if err != nil {
		return err
	}
	bazel, err := findBazel(runner)
	if err != nil {
		return err
	}
	temporaryRoot := os.Getenv("RUNNER_TEMP")
	if temporaryRoot == "" {
		temporaryRoot = os.TempDir()
	}
	work, err := os.MkdirTemp(temporaryRoot, "vxs-fuzz-")
	if err != nil {
		return fmt.Errorf("could not create fuzz work directory: %w", err)
	}
	persistentCorpus := os.Getenv("VXS_FUZZ_CORPUS")
	corpusRoot := persistentCorpus
	if corpusRoot == "" {
		corpusRoot = filepath.Join(work, "corpus")
	}
	artifacts := filepath.Join(work, "artifacts")
	if err := os.Mkdir(artifacts, 0o700); err != nil {
		return fmt.Errorf("could not create fuzz artifact directory %q: %w", work, err)
	}
	for _, target := range targets {
		stage := target.corpus
		corpus := filepath.Join(corpusRoot, stage)
		if err := os.MkdirAll(corpus, 0o700); err != nil {
			return fmt.Errorf("could not prepare %s corpus; preserved %q: %w", stage, work, err)
		}
		// Wire seeds are encoded by the production writers below; unlike
		// source seeds, no hand-maintained versioned wire directory exists.
		if stage == "wire" {
			continue
		}
		if err := syncSeedCorpus(filepath.Join(repository, "Compiler", "Fuzzing", "Corpus", stage), corpus); err != nil {
			return fmt.Errorf("could not synchronize the versioned %s seed corpus: %w", stage, err)
		}
	}
	wireGenerated := filepath.Join(work, "generated-wire-corpus")
	smoke := filepath.Join(repository, "bazel-bin", "Compiler", "Fuzzing", "wire_fuzz_smoke"+currentHost.executable)
	sanitizerConfiguration := ""
	selectedEnvironment := []string(nil)
	if asan {
		selected, err := selectSanitizer(currentHost, "address-undefined")
		if err != nil {
			return err
		}
		sanitizerConfiguration = selected.config
		selectedEnvironment, err = sanitizerEnvironment(currentHost, selected, runner)
		if err != nil {
			return err
		}
		selected.environment = selectedEnvironment
		if err := verifySanitizerRuntime(repository, currentHost, runner, selected); err != nil {
			return err
		}
		selectedEnvironment = fuzzSanitizerEnvironment(selectedEnvironment)
	}
	macRuntime := ""
	if currentHost.kind == hostMacOS {
		runtime, err := macOSFuzzerRuntime(os.Getenv("LLVM_ROOT"))
		if err != nil {
			return fmt.Errorf("could not locate macOS libFuzzer runtime; preserved %q: %w", work, err)
		}
		macRuntime = runtime
	}
	smokeArguments, campaignArguments := fuzzBuildArguments(configuration, sanitizerConfiguration, macRuntime)
	if err := runner.Run(repository, nil, bazel, cachedBuild(smokeArguments)...); err != nil {
		return fmt.Errorf("could not build standalone fuzz smoke targets; preserved %q: %w", work, err)
	}
	if err := runner.Run(repository, selectedEnvironment, smoke, "-Write-Corpus", wireGenerated); err != nil {
		return fmt.Errorf("could not export valid wire seeds; preserved %q: %w", work, err)
	}
	if fuzzTargetSelected(targets, "wire") {
		if err := syncSeedCorpus(wireGenerated, filepath.Join(corpusRoot, "wire")); err != nil {
			return fmt.Errorf("could not add generated wire seeds to the persistent corpus: %w", err)
		}
	}
	smokeSource := filepath.Join(repository, "bazel-bin", "Compiler", "Fuzzing", "source_fuzz_smoke"+currentHost.executable)
	if err := copyFile(frontendLibrary, filepath.Join(filepath.Dir(smokeSource), filepath.Base(frontendLibrary)), 0o755); err != nil {
		return fmt.Errorf("could not stage Haskell frontend for source-fuzz smoke: %w", err)
	}
	if err := runner.Run(repository, selectedEnvironment, smokeSource); err != nil {
		return fmt.Errorf("source-to-LLVM differential smoke failed; preserved %q: %w", work, err)
	}
	// The programs with hand-written results stand in the same directory,
	// beside the frontend library staged above.
	smokeExecution := filepath.Join(filepath.Dir(smokeSource), "source_execution_smoke"+currentHost.executable)
	if err := runner.Run(repository, selectedEnvironment, smokeExecution); err != nil {
		return fmt.Errorf("source execution smoke failed; preserved %q: %w", work, err)
	}
	smokeExpression := filepath.Join(filepath.Dir(smokeSource), "source_expression_smoke"+currentHost.executable)
	if err := runner.Run(repository, selectedEnvironment, smokeExpression); err != nil {
		return fmt.Errorf("source expression smoke failed; preserved %q: %w", work, err)
	}
	smokeFeature := filepath.Join(filepath.Dir(smokeSource), "source_feature_smoke"+currentHost.executable)
	if err := runner.Run(repository, selectedEnvironment, smokeFeature); err != nil {
		return fmt.Errorf("source feature smoke failed; preserved %q: %w", work, err)
	}
	smokeConsole := filepath.Join(filepath.Dir(smokeSource), "source_console_smoke"+currentHost.executable)
	if err := runner.Run(repository, selectedEnvironment, smokeConsole); err != nil {
		return fmt.Errorf("source console smoke failed; preserved %q: %w", work, err)
	}
	// Run smoke tests before changing Bazel's instrumentation configuration and
	// staging the campaign binaries into the same host output tree.
	if err := runner.Run(repository, nil, bazel, cachedBuild(campaignArguments)...); err != nil {
		return fmt.Errorf("could not build instrumented fuzz targets; preserved %q: %w", work, err)
	}
	campaign := fuzzCampaign{
		repository:  repository,
		corpusRoot:  corpusRoot,
		artifacts:   artifacts,
		work:        work,
		report:      "campaigns.json",
		duration:    duration,
		environment: selectedEnvironment,
		sanitizer:   sanitizerConfiguration,
		executable:  currentHost.executable,
	}
	jobs, err := hostFuzzJobs(os.Getenv("VXS_FUZZ_JOBS"))
	if err != nil {
		return err
	}
	if err := campaign.runAll(runner, targets, frontendLibrary, jobs); err != nil {
		return err
	}
	if haskell {
		if err := runHaskellFuzz(repository, corpusRoot, artifacts, duration, jobs, runner); err != nil {
			return fmt.Errorf("Haskell feedback campaign failed; preserved %q: %w", work, err)
		}
	}
	if os.Getenv("CI") == "true" {
		fmt.Printf("Campaign logs and coverage limits preserved in %s.\n", work)
		return nil
	}
	if persistentCorpus != "" {
		if err := removeSuccessfulFuzzWork(temporaryRoot, work); err != nil {
			return err
		}
		fmt.Printf("Coverage corpus persisted in %s.\n", persistentCorpus)
		return nil
	}
	// Only the exact directory returned by MkdirTemp may be removed. On a
	// failed campaign the same directory remains for replay and minimization.
	if err := removeSuccessfulFuzzWork(temporaryRoot, work); err != nil {
		return err
	}
	if len(targets) != len(nativeFuzzTargets()) || !haskell {
		fmt.Printf("The selected fuzz targets completed without a reported failure: %s.\n",
			strings.Join(selectedFuzzTargetNames(targets, haskell), ", "))
		return nil
	}
	fmt.Println("All coverage-guided compiler fuzz targets completed without a reported failure.")
	return nil
}

// fuzzTargetSelected reports whether the target of the given corpus runs.
func fuzzTargetSelected(targets []fuzzTarget, corpus string) bool {
	for _, target := range targets {
		if target.corpus == corpus {
			return true
		}
	}
	return false
}

func selectedFuzzTargetNames(targets []fuzzTarget, haskell bool) []string {
	names := make([]string, 0, len(targets)+1)
	for _, target := range targets {
		names = append(names, target.corpus)
	}
	if haskell {
		names = append(names, haskellFuzzTarget)
	}
	return names
}

// fuzzCampaign carries the settings shared by every libFuzzer target of one
// helper invocation and accumulates their structured report.
type fuzzCampaign struct {
	repository, corpusRoot, artifacts, work, report string
	duration                                        int
	environment                                     []string
	sanitizer, executable                           string
	// records holds one slot per target in inventory order; guard serializes
	// report updates and console output of concurrently finishing targets.
	records []map[string]any
	guard   sync.Mutex
}

// runAll stages every frontend library first, because several targets share
// one output directory, and then runs the targets with bounded concurrency.
// Each target keeps its own corpus, artifact directory, time budget, RSS
// limit, watchdog and report checks exactly as in a sequential run.
func (campaign *fuzzCampaign) runAll(runner commandRunner, targets []fuzzTarget, frontendLibrary string, jobs int) error {
	campaign.records = make([]map[string]any, len(targets))
	tasks := make([]fuzzTask, 0, len(targets))
	for index, target := range targets {
		if target.frontend {
			if err := copyFile(frontendLibrary, filepath.Join(filepath.Dir(campaign.program(target)), filepath.Base(frontendLibrary)), 0o755); err != nil {
				return fmt.Errorf("could not stage frontend for %s; preserved %q: %w", target.binary, campaign.work, err)
			}
		}
		tasks = append(tasks, fuzzTask{heavy: isHeavyFuzzTarget(target), run: func() error { return campaign.run(runner, index, target) }})
	}
	fmt.Printf("Running %d fuzz targets with up to %d concurrent processes.\n", len(targets), jobs)
	return runFuzzTasks(jobs, tasks)
}

func (campaign *fuzzCampaign) program(target fuzzTarget) string {
	packagePath, _, _ := strings.Cut(strings.TrimPrefix(target.label, "//"), ":")
	return filepath.Join(campaign.repository, "bazel-bin", filepath.FromSlash(packagePath), target.binary+campaign.executable)
}

// run executes one instrumented target against its persistent corpus. The
// report is rewritten after every target so a later failure still leaves the
// earlier measurements, and a process that exits zero without libFuzzer's final
// counters is a failure rather than an unexplained success.
func (campaign *fuzzCampaign) run(runner commandRunner, index int, target fuzzTarget) error {
	fuzzer := campaign.program(target)
	campaignArtifacts := filepath.Join(campaign.artifacts, target.binary)
	if err := os.MkdirAll(campaignArtifacts, 0o700); err != nil {
		return fmt.Errorf("could not create %s artifact directory: %w", target.binary, err)
	}
	arguments := []string{
		filepath.Join(campaign.corpusRoot, target.corpus),
		"-max_total_time=" + strconv.Itoa(campaign.duration),
		"-max_len=" + target.maxLength,
		"-timeout=30",
		"-rss_limit_mb=" + target.rssLimit,
		"-use_value_profile=1",
		"-verbosity=0",
		"-print_final_stats=1",
		"-artifact_prefix=" + campaignArtifacts + string(os.PathSeparator),
	}
	output, runErr := runner.RunWithInput(campaign.repository, campaign.environment, "", fuzzer, arguments...)
	if err := os.WriteFile(filepath.Join(campaign.artifacts, target.binary+".log"), []byte(output), 0o600); err != nil {
		return fmt.Errorf("could not preserve campaign log: %w", err)
	}
	statistics, statisticsErr := parseFuzzStatistics(output)
	if runErr == nil && statisticsErr != nil {
		runErr = statisticsErr
	}
	campaign.guard.Lock()
	defer campaign.guard.Unlock()
	fmt.Print(output)
	campaign.records[index] = map[string]any{"target": target.binary, "seconds": campaign.duration, "rss_limit_mb": target.rssLimit, "sanitizer": campaign.sanitizer, "native_coverage": true, "haskell_native_coverage": false, "statistics": statistics, "success": runErr == nil}
	finished := make([]map[string]any, 0, len(campaign.records))
	for _, record := range campaign.records {
		if record != nil {
			finished = append(finished, record)
		}
	}
	report, err := json.MarshalIndent(finished, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(campaign.artifacts, campaign.report), report, 0o600); err != nil {
		return err
	}
	if runErr != nil {
		return fmt.Errorf("%s campaign failed; corpus and crash artifacts preserved in %q: %w", target.binary, campaign.work, runErr)
	}
	fmt.Printf("%s campaign completed (%d seconds; RSS <= %s MiB; %s).\n", target.binary, campaign.duration, target.rssLimit, campaign.sanitizer)
	return nil
}

func fuzzDuration(stress bool, configured string) (int, error) {
	if configured == "" {
		if stress {
			return 900, nil
		}
		return 30, nil
	}
	duration, err := strconv.Atoi(configured)
	if err != nil || duration < 1 || duration > 3600 {
		return 0, errors.New("VXS_FUZZ_SECONDS must be an integer in [1, 3600]")
	}
	return duration, nil
}

func syncSeedCorpus(source string, destination string) error {
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			continue
		}
		target := filepath.Join(destination, entry.Name())
		if info, err := os.Lstat(target); err == nil && !info.Mode().IsRegular() {
			return fmt.Errorf("cached corpus entry is not a regular file: %q", target)
		} else if err != nil && !os.IsNotExist(err) {
			return err
		}
		seed, err := os.ReadFile(filepath.Join(source, entry.Name()))
		if err != nil {
			return err
		}
		existing, err := os.ReadFile(target)
		if err == nil {
			if bytes.Equal(existing, seed) {
				continue
			}
			// Preserve both a learned/replaced cached seed and the current
			// versioned seed; a filename collision must not discard either.
			digest := sha256.Sum256(seed)
			target = fmt.Sprintf("%s-%x", target, digest)
		} else if !os.IsNotExist(err) {
			return err
		}
		if err := writeSeedExclusive(target, seed); err != nil {
			return err
		}
	}
	return nil
}

// Exclusive creation prevents a cached path from being overwritten, including
// a symlink inserted after the initial directory inspection.
func writeSeedExclusive(target string, seed []byte) error {
	output, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if os.IsExist(err) {
		info, statErr := os.Lstat(target)
		if statErr != nil {
			return statErr
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("cached corpus entry is not a regular file: %q", target)
		}
		existing, readErr := os.ReadFile(target)
		if readErr != nil {
			return readErr
		}
		if !bytes.Equal(existing, seed) {
			return fmt.Errorf("content-addressed corpus entry has different contents: %q", target)
		}
		return nil
	}
	if err != nil {
		return err
	}
	_, writeErr := output.Write(seed)
	closeErr := output.Close()
	return errors.Join(writeErr, closeErr)
}

func removeSuccessfulFuzzWork(temporaryRoot string, work string) error {
	root, err := filepath.Abs(temporaryRoot)
	if err != nil {
		return err
	}
	target, err := filepath.Abs(work)
	if err != nil {
		return err
	}
	relative, err := filepath.Rel(root, target)
	if err != nil || filepath.Dir(relative) != "." || !strings.HasPrefix(relative, "vxs-fuzz-") {
		return fmt.Errorf("refusing to remove fuzz work outside the expected temporary root: %q", work)
	}
	if err := os.RemoveAll(target); err != nil {
		return fmt.Errorf("could not remove successful fuzz work %q: %w", work, err)
	}
	return nil
}
