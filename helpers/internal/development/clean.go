// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var generatedBuildPaths = []string{
	"Talac/dist-newstyle",
	"Talac/dist-fuzz-coverage",
}

func cleanGeneratedBuildPaths(repository string) error {
	return cleanGeneratedPaths(repository, generatedBuildPaths)
}

func runCleanBuild(repository string, currentHost host, runner commandRunner, cold bool) error {
	if err := requireBuildTools(currentHost, runner); err != nil {
		return err
	}
	bazel, err := findBazel(runner)
	if err != nil {
		return err
	}
	cleanArguments := []string{"clean"}
	if cold {
		cleanArguments = append(cleanArguments, "--expunge")
	}
	if cold {
		cabal, err := runner.LookPath("cabal")
		if err != nil {
			return err
		}
		if err := runner.Run(filepath.Join(repository, "Talac"), nil, cabal, "clean"); err != nil {
			return fmt.Errorf("Cabal cold clean failed: %w", err)
		}
		if err := cleanGeneratedBuildPaths(repository); err != nil {
			return err
		}
	}
	if err := runner.Run(repository, nil, bazel, cleanArguments...); err != nil {
		return fmt.Errorf("Bazel clean failed: %w", err)
	}
	if cold {
		fmt.Println("Cold build: Bazel output base and Cabal outputs were removed; downloaded dependencies remain governed by their caches.")
	} else {
		fmt.Println("Incremental clean build: Bazel action outputs will be rebuilt; external and repository caches are retained.")
	}
	return buildTargets(repository, runner, "", nil)
}

func cleanGeneratedPaths(repository string, relativePaths []string) error {
	root, err := filepath.Abs(repository)
	if err != nil {
		return fmt.Errorf("cannot resolve repository root for cleanup: %w", err)
	}
	for _, relative := range relativePaths {
		target, err := filepath.Abs(filepath.Join(root, filepath.FromSlash(relative)))
		if err != nil {
			return fmt.Errorf("cannot resolve generated path %s: %w", relative, err)
		}
		within, err := filepath.Rel(root, target)
		if err != nil || within == "." || within == ".." || strings.HasPrefix(within, ".."+string(os.PathSeparator)) {
			return fmt.Errorf("refusing to remove unsafe generated path %q", target)
		}
		if err := os.RemoveAll(target); err != nil {
			return fmt.Errorf("cannot remove generated path %s: %w", relative, err)
		}
	}
	return nil
}
