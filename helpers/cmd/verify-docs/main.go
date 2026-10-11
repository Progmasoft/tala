// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// verify_docs builds the public C++ reference and checks Haddock's own
// exported-API coverage reports. Haddock reports missing comments without a
// failing exit status, so this wrapper makes incomplete API docs a CI error.
package main

import (
	"errors"
	"fmt"
	"github.com/spf13/cobra"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

var haddockPackages = []string{
	"visual-xsharp-syntax",
	"visual-xsharp-frontend",
	"visual-xsharp-core",
	"visual-xsharp-compiler",
}

var haddockCoverageLine = regexp.MustCompile(`(?m)^\s*(\d+)%\s+\(\s*(\d+)\s*/\s*(\d+)\)\s+in '([^']+)'`)

type moduleCoverage struct {
	module     string
	documented int
	exported   int
}

func main() {
	if err := execute(os.Args[1:], os.Stdout, os.Stderr, verify); err != nil {
		fmt.Fprintln(os.Stderr, "API documentation verification failed:", err)
		os.Exit(1)
	}
}

// newCommand owns the command line. The verification is handed in, so that
// parsing can be tested without Doxygen or Cabal.
func newCommand(output, errorOutput io.Writer, check func() error) *cobra.Command {
	command := &cobra.Command{
		Use:   "verify-docs",
		Short: "Verify that the public C++ and Haskell APIs are documented.",
		Long: `Verify that the public C++ and Haskell APIs are documented.

Doxygen must report no warning for the public C++ headers, and Haddock must
report every exported entry of the compiler packages as documented.`,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE:          func(cmd *cobra.Command, args []string) error { return check() },
	}
	command.SetOut(output)
	command.SetErr(errorOutput)
	command.CompletionOptions.DisableDefaultCmd = true
	return command
}

func execute(arguments []string, output, errorOutput io.Writer, check func() error) error {
	command := newCommand(output, errorOutput, check)
	command.SetArgs(arguments)
	return command.Execute()
}

func verify() error {
	repository, err := findRepositoryRoot()
	if err != nil {
		return err
	}

	var failures []error
	if err := run(repository, "doxygen", "Doxyfile"); err != nil {
		failures = append(failures, fmt.Errorf("Doxygen reported an undocumented or malformed public C++ API: %w", err))
		printDoxygenDiagnostics(repository)
	} else {
		fmt.Println("Doxygen public C++ API: no documentation warnings.")
	}

	compilerDirectory := filepath.Join(repository, "Compiler")
	for _, packageName := range haddockPackages {
		output, err := runCaptured(compilerDirectory, "cabal", "haddock", packageName)
		fmt.Print(output)
		if err != nil {
			failures = append(failures, fmt.Errorf("Haddock failed for %s: %w", packageName, err))
			continue
		}
		coverage, err := parseCoverage(output)
		if err != nil {
			failures = append(failures, fmt.Errorf("Haddock did not produce a coverage report for %s: %w", packageName, err))
			continue
		}
		if err := requireCompleteCoverage(packageName, coverage); err != nil {
			failures = append(failures, err)
			continue
		}
		fmt.Printf("Haddock %s: all %d exported modules and %d API entries are documented.\n",
			packageName, len(coverage), totalEntries(coverage))
	}
	return errors.Join(failures...)
}

func printDoxygenDiagnostics(repository string) {
	path := filepath.Join(repository, "Compiler", "dist-newstyle", "doxygen-warnings.log")
	contents, err := os.ReadFile(path)
	if err != nil || len(contents) == 0 {
		fmt.Println("Doxygen did not produce a warning log.")
		return
	}
	lines := strings.Split(strings.TrimSpace(string(contents)), "\n")
	limit := 50
	if len(lines) < limit {
		limit = len(lines)
	}
	fmt.Printf("Doxygen reported %d warning-log lines; first %d follow:\n", len(lines), limit)
	for _, line := range lines[:limit] {
		fmt.Println(strings.TrimSpace(line))
	}
	if len(lines) > limit {
		fmt.Printf("... %d additional Doxygen diagnostics are in %s\n", len(lines)-limit, path)
	}
}

func findRepositoryRoot() (string, error) {
	workingDirectory, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("cannot read the current directory: %w", err)
	}
	for directory := workingDirectory; ; directory = filepath.Dir(directory) {
		if _, err := os.Stat(filepath.Join(directory, ".git")); err == nil {
			return directory, nil
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			return "", errors.New("could not locate the XSharp Git root")
		}
	}
}

func run(directory, executable string, arguments ...string) error {
	command := exec.Command(executable, arguments...)
	command.Dir = directory
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", executable, strings.Join(arguments, " "), err)
	}
	return nil
}

func runCaptured(directory, executable string, arguments ...string) (string, error) {
	command := exec.Command(executable, arguments...)
	command.Dir = directory
	output, err := command.CombinedOutput()
	return string(output), err
}

func parseCoverage(output string) ([]moduleCoverage, error) {
	if !strings.Contains(output, "Haddock coverage:") {
		return nil, errors.New("missing Haddock coverage summary")
	}
	matches := haddockCoverageLine.FindAllStringSubmatch(output, -1)
	coverage := make([]moduleCoverage, 0, len(matches))
	for _, match := range matches {
		var item moduleCoverage
		if _, err := fmt.Sscanf(match[2], "%d", &item.documented); err != nil {
			return nil, fmt.Errorf("invalid documented-entry count %q", match[2])
		}
		if _, err := fmt.Sscanf(match[3], "%d", &item.exported); err != nil {
			return nil, fmt.Errorf("invalid exported-entry count %q", match[3])
		}
		item.module = match[4]
		coverage = append(coverage, item)
	}
	if len(coverage) == 0 {
		return nil, errors.New("coverage summary contains no module records")
	}
	return coverage, nil
}

func requireCompleteCoverage(packageName string, modules []moduleCoverage) error {
	var missing []string
	for _, module := range modules {
		if module.documented < module.exported {
			missing = append(missing, fmt.Sprintf("%s (%d/%d)", module.module, module.documented, module.exported))
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("%s has undocumented public API entries; document every exported name before merging:\n  %s",
			packageName, strings.Join(missing, "\n  "))
	}
	return nil
}

func totalEntries(modules []moduleCoverage) int {
	total := 0
	for _, module := range modules {
		total += module.exported
	}
	return total
}
