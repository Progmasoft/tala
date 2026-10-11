// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// verify_benchmarks keeps the benchmark-results index synchronized with its reports.
package main

import (
	"errors"
	"fmt"
	"github.com/spf13/cobra"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const benchmarkDirectoryName = "Benchmarks"

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// newCommand owns the command line. Parsing is separate from the check so
// that an invalid invocation reads nothing.
func newCommand(output, errorOutput io.Writer) *cobra.Command {
	root := "."
	command := &cobra.Command{
		Use:   "verify-benchmarks",
		Short: "Verify the committed benchmark-results index.",
		Long: `Verify the committed benchmark-results index.

Every root-level benchmark result Markdown file must be linked exactly once from
Benchmarks/README.md, and every result link must resolve to a report file.`,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			count, err := verifyBenchmarkIndex(root)
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Verified %d benchmark result reports against Benchmarks/README.md.\n", count)
			return nil
		},
	}
	command.Flags().StringVar(&root, "root", ".", "repository root containing Benchmarks/README.md")
	command.SetOut(output)
	command.SetErr(errorOutput)
	command.CompletionOptions.DisableDefaultCmd = true
	return command
}

func run(arguments []string, output, errorOutput io.Writer) error {
	command := newCommand(output, errorOutput)
	command.SetArgs(arguments)
	return command.Execute()
}

// verifyBenchmarkIndex finds stale links as well as unindexed reports so either
// direction of documentation drift is fixed before the change reaches a user.
func verifyBenchmarkIndex(repositoryRoot string) (int, error) {
	root, err := filepath.Abs(repositoryRoot)
	if err != nil {
		return 0, fmt.Errorf("resolve repository root: %w", err)
	}
	benchmarkRoot := filepath.Join(root, benchmarkDirectoryName)
	entries, err := os.ReadDir(benchmarkRoot)
	if err != nil {
		return 0, fmt.Errorf("read %s: %w", benchmarkRoot, err)
	}

	var failures []string
	reports := make(map[string]struct{})
	for _, entry := range entries {
		if entry.IsDir() || !strings.EqualFold(filepath.Ext(entry.Name()), ".md") || strings.EqualFold(entry.Name(), "README.md") {
			continue
		}
		if entry.Type()&fs.ModeSymlink != 0 {
			failures = append(failures, fmt.Sprintf("benchmark report %q must not be a symbolic link", entry.Name()))
			continue
		}
		reports[entry.Name()] = struct{}{}
	}

	indexPath := filepath.Join(benchmarkRoot, "README.md")
	index, err := os.ReadFile(indexPath)
	if err != nil {
		failures = append(failures, fmt.Sprintf("read Benchmarks/README.md: %v", err))
	} else {
		linkedReports, indexFailures := indexedReports(string(index))
		failures = append(failures, indexFailures...)
		for name := range linkedReports {
			if _, exists := reports[name]; !exists {
				failures = append(failures, fmt.Sprintf("Benchmarks/README.md links %q, but that report does not exist", name))
			}
		}
		for name := range reports {
			if _, linked := linkedReports[name]; !linked {
				failures = append(failures, fmt.Sprintf("Benchmarks/%s is not indexed in Benchmarks/README.md", name))
			}
		}
	}

	if len(failures) != 0 {
		sort.Strings(failures)
		return len(reports), errors.New("benchmark result index verification failed:\n - " + strings.Join(failures, "\n - "))
	}
	return len(reports), nil
}

func indexedReports(markdown string) (map[string]struct{}, []string) {
	reports := make(map[string]struct{})
	var failures []string
	for lineNumber, line := range strings.Split(markdown, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "- ") {
			continue
		}
		item := strings.TrimSpace(strings.TrimPrefix(line, "- "))
		if len(item) < 4 || item[0] != '`' {
			continue
		}
		end := strings.IndexByte(item[1:], '`')
		if end < 0 {
			continue
		}
		name := item[1 : end+1]
		if !strings.EqualFold(filepath.Ext(name), ".md") {
			continue
		}
		if filepath.Base(name) != name || strings.ContainsAny(name, `/\:`) {
			failures = append(failures, fmt.Sprintf("Benchmarks/README.md:%d must link to a report filename, not a path", lineNumber+1))
			continue
		}
		if _, duplicate := reports[name]; duplicate {
			failures = append(failures, fmt.Sprintf("Benchmarks/README.md:%d repeats report %q", lineNumber+1, name))
			continue
		}
		reports[name] = struct{}{}
	}
	return reports, failures
}
