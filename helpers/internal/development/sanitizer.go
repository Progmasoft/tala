// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"fmt"
	"path/filepath"
	"strings"
)

// A test run without a reported violation says nothing about whether runtime
// instrumentation actually loaded. Require one clean process and known-bad
// inputs for every selected checker before trusting the suite result.
func verifySanitizerRuntime(repository string, currentHost host, runner commandRunner, selected sanitizer) error {
	bazel, err := findBazel(runner)
	if err != nil {
		return err
	}
	if err := runner.Run(repository, nil, bazel, cachedBuild([]string{"build", "--config=" + selected.config, "//Talac/Sanitizers:sanitizer_probe"})...); err != nil {
		return fmt.Errorf("sanitizer probe build failed: %w", err)
	}
	probe := filepath.Join(repository, "bazel-bin", "Talac", "Sanitizers", "sanitizer_probe"+currentHost.executable)
	if _, err := runner.RunWithInput(repository, selected.environment, "", probe, "clean"); err != nil {
		return fmt.Errorf("sanitizer runtime could not start a clean probe: %w", err)
	}
	for _, mode := range sanitizerProbeModes(selected.config) {
		output, err := runner.RunWithInput(repository, selected.environment, "", probe, mode)
		if err == nil || !expectedSanitizerReport(mode, output) {
			return fmt.Errorf("%s runtime did not diagnose its intentional %s violation (exit error: %v):\n%s", selected.name, mode, err, output)
		}
	}
	return nil
}

func sanitizerProbeModes(configuration string) []string {
	switch {
	case strings.HasPrefix(configuration, "asan-ubsan-"):
		return []string{"address", "undefined"}
	case strings.HasPrefix(configuration, "asan-"):
		return []string{"address"}
	case strings.HasPrefix(configuration, "ubsan-"):
		return []string{"undefined"}
	case strings.HasPrefix(configuration, "tsan-"):
		return []string{"thread"}
	default:
		return nil
	}
}

func expectedSanitizerReport(mode, output string) bool {
	switch mode {
	case "address":
		return strings.Contains(output, "AddressSanitizer") && strings.Contains(output, "heap-use-after-free")
	case "undefined":
		return strings.Contains(output, "runtime error:") && strings.Contains(output, "signed integer overflow")
	case "thread":
		return strings.Contains(output, "ThreadSanitizer") && strings.Contains(output, "data race")
	default:
		return false
	}
}
