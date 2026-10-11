// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// threadFuzzBuildArguments instruments the threaded harnesses for libFuzzer and
// ThreadSanitizer together. AddressSanitizer cannot share a binary with
// ThreadSanitizer, so this is a separate build and a separate campaign.
func threadFuzzBuildArguments(configuration, sanitizerConfiguration, macRuntime string) []string {
	arguments := []string{"build", "--config=" + configuration, "--config=" + sanitizerConfiguration}
	if macRuntime != "" {
		arguments = append(arguments, "--linkopt="+macRuntime)
	}
	for _, target := range threadFuzzTargets() {
		arguments = append(arguments, target.label)
	}
	return arguments
}

// runThreadFuzzCampaign runs the interleaving-dependent harnesses under
// ThreadSanitizer. A host without a ThreadSanitizer runtime is an error, never
// a skipped success: the selection fails on Windows, and the runtime probe must
// start cleanly and report its intentional data race before any input runs.
func runThreadFuzzCampaign(repository string, currentHost host, runner commandRunner) error {
	duration, err := fuzzDuration(false, os.Getenv("VXS_FUZZ_SECONDS"))
	if err != nil {
		return err
	}
	selected, err := selectSanitizer(currentHost, "thread")
	if err != nil {
		return err
	}
	configuration, err := fuzzConfiguration(currentHost)
	if err != nil {
		return err
	}
	targets := threadFuzzTargets()
	if len(targets) == 0 {
		return errors.New("no threaded fuzz target is registered")
	}
	// A selection names targets of the whole inventory; here it can only
	// keep threaded ones. The Haskell campaign has no thread campaign.
	if selection := os.Getenv(fuzzTargetsVariable); selection != "" {
		selected, _, err := selectFuzzTargets(targets, selection)
		if err != nil {
			return fmt.Errorf("fuzz-thread runs threaded targets only: %w", err)
		}
		if len(selected) == 0 {
			return errors.New("fuzz-thread runs threaded targets only; the selection names none")
		}
		targets = selected
	}
	bazel, err := findBazel(runner)
	if err != nil {
		return err
	}
	selected.environment, err = sanitizerEnvironment(currentHost, selected, runner)
	if err != nil {
		return err
	}
	if err := verifySanitizerRuntime(repository, currentHost, runner, selected); err != nil {
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
		corpus := filepath.Join(corpusRoot, target.corpus)
		if err := os.MkdirAll(corpus, 0o700); err != nil {
			return fmt.Errorf("could not prepare %s corpus; preserved %q: %w", target.corpus, work, err)
		}
		if err := syncSeedCorpus(filepath.Join(repository, "Compiler", "Fuzzing", "Corpus", target.corpus), corpus); err != nil {
			return fmt.Errorf("could not synchronize the versioned %s seed corpus: %w", target.corpus, err)
		}
	}
	macRuntime := ""
	if currentHost.kind == hostMacOS {
		macRuntime, err = macOSFuzzerRuntime(os.Getenv("LLVM_ROOT"))
		if err != nil {
			return fmt.Errorf("could not locate macOS libFuzzer runtime; preserved %q: %w", work, err)
		}
	}
	if err := runner.Run(repository, nil, bazel, cachedBuild(threadFuzzBuildArguments(configuration, selected.config, macRuntime))...); err != nil {
		return fmt.Errorf("could not build ThreadSanitizer fuzz targets; preserved %q: %w", work, err)
	}
	campaign := fuzzCampaign{
		repository:  repository,
		corpusRoot:  corpusRoot,
		artifacts:   artifacts,
		work:        work,
		report:      "thread-campaigns.json",
		duration:    duration,
		environment: selected.environment,
		sanitizer:   selected.config,
		executable:  currentHost.executable,
	}
	for _, target := range targets {
		if target.frontend {
			// The GHC runtime is not ThreadSanitizer-instrumented; a frontend
			// target here would report races this campaign cannot attribute.
			return fmt.Errorf("threaded fuzz target %s must not depend on the Haskell frontend", target.binary)
		}
	}
	// Threaded targets already occupy several cores each and their findings
	// depend on scheduling, so they run one at a time.
	if err := campaign.runAll(runner, targets, "", 1); err != nil {
		return err
	}
	if os.Getenv("CI") == "true" {
		fmt.Printf("ThreadSanitizer campaign logs preserved in %s.\n", work)
		return nil
	}
	if err := removeSuccessfulFuzzWork(temporaryRoot, work); err != nil {
		return err
	}
	fmt.Println("All ThreadSanitizer fuzz targets completed without a reported failure.")
	return nil
}
