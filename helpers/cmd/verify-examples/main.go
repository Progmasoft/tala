// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// verify_examples checks that the comparative-example catalogue stays aligned
// with the source tree and that every program has all supported language forms.
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

const examplesDirectoryName = "Examples"

var comparativeSourceExtensions = []string{".vxs", ".cs", ".cpp", ".java", ".rs"}

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
		Use:   "verify-examples",
		Short: "Verify the comparative Visual X# example catalogue.",
		Long: `Verify the comparative Visual X# example catalogue.

The check compares the program names in Examples/README.md with the immediate
program directories under Examples/ and requires matching .vxs, .cs, .cpp,
.java, and .rs source files in every program directory.`,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			count, err := verifyExamples(root)
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Verified %d comparative programs across %d source languages.\n",
				count, len(comparativeSourceExtensions))
			return nil
		},
	}
	command.Flags().StringVar(&root, "root", ".", "repository root containing Examples/ and Examples/README.md")
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

// verifyExamples reports all catalogue and filesystem mismatches in one pass
// so a contributor can repair the complete example set without repeated runs.
func verifyExamples(repositoryRoot string) (int, error) {
	root, err := filepath.Abs(repositoryRoot)
	if err != nil {
		return 0, fmt.Errorf("resolve repository root: %w", err)
	}
	examplesRoot := filepath.Join(root, examplesDirectoryName)
	directories, err := os.ReadDir(examplesRoot)
	if err != nil {
		return 0, fmt.Errorf("read %s: %w", examplesRoot, err)
	}

	var failures []string
	programs := make(map[string]string)
	caseFolded := make(map[string]string)
	for _, entry := range directories {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		programs[name] = name
		folded := strings.ToLower(name)
		if existing, found := caseFolded[folded]; found {
			failures = append(failures,
				fmt.Sprintf("program directories %q and %q differ only by letter case", existing, name))
		} else {
			caseFolded[folded] = name
		}
		if !validProgramName(name) {
			failures = append(failures, fmt.Sprintf("%s is not an ASCII identifier suitable for a program directory", name))
		}
		failures = append(failures, verifyProgramFiles(examplesRoot, name)...)
	}
	if len(programs) == 0 {
		failures = append(failures, "Examples/ contains no program directories")
	}

	catalogPath := filepath.Join(examplesRoot, "README.md")
	catalog, err := os.ReadFile(catalogPath)
	if err != nil {
		failures = append(failures, fmt.Sprintf("read Examples/README.md: %v", err))
	} else {
		catalogPrograms, catalogFailures := readCatalogPrograms(string(catalog))
		failures = append(failures, catalogFailures...)
		failures = append(failures, compareProgramSets(programs, catalogPrograms)...)
	}

	if len(failures) != 0 {
		sort.Strings(failures)
		return len(programs), errors.New("comparative example verification failed:\n - " + strings.Join(failures, "\n - "))
	}
	return len(programs), nil
}

func verifyProgramFiles(examplesRoot, program string) []string {
	programRoot := filepath.Join(examplesRoot, program)
	entries, err := os.ReadDir(programRoot)
	if err != nil {
		return []string{fmt.Sprintf("read %s: %v", filepath.ToSlash(filepath.Join("Examples", program)), err)}
	}

	expected := make(map[string]struct{}, len(comparativeSourceExtensions))
	for _, extension := range comparativeSourceExtensions {
		expected[program+extension] = struct{}{}
	}
	var failures []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if _, source := supportedExtension(filepath.Ext(entry.Name())); source {
			if _, namedCorrectly := expected[entry.Name()]; !namedCorrectly {
				failures = append(failures,
					fmt.Sprintf("%s contains %q; source files must use the directory name", filepath.ToSlash(filepath.Join("Examples", program)), entry.Name()))
			}
		}
	}
	for expectedName := range expected {
		path := filepath.Join(programRoot, expectedName)
		info, statErr := os.Stat(path)
		if statErr != nil {
			if errors.Is(statErr, fs.ErrNotExist) {
				failures = append(failures, filepath.ToSlash(filepath.Join("Examples", program, expectedName))+" is missing")
			} else {
				failures = append(failures, fmt.Sprintf("inspect %s: %v", filepath.ToSlash(filepath.Join("Examples", program, expectedName)), statErr))
			}
			continue
		}
		if !info.Mode().IsRegular() {
			failures = append(failures, filepath.ToSlash(filepath.Join("Examples", program, expectedName))+" is not a regular file")
			continue
		}
		if info.Size() == 0 {
			failures = append(failures, filepath.ToSlash(filepath.Join("Examples", program, expectedName))+" is empty")
		}
	}
	return failures
}

func supportedExtension(extension string) (string, bool) {
	for _, supported := range comparativeSourceExtensions {
		if strings.EqualFold(extension, supported) {
			return supported, true
		}
	}
	return "", false
}

func readCatalogPrograms(markdown string) (map[string]string, []string) {
	programs := make(map[string]string)
	var failures []string
	lines := strings.Split(markdown, "\n")
	programTable := false
	for lineNumber, line := range lines {
		columns := strings.Split(line, "|")
		if len(columns) < 3 {
			if programTable {
				break
			}
			continue
		}
		cell := strings.TrimSpace(columns[1])
		if !programTable {
			programTable = cell == "Program"
			continue
		}
		if strings.TrimSpace(line) == "" {
			break
		}
		if strings.Trim(cell, "-: ") == "" {
			continue
		}
		if len(cell) < 2 || cell[0] != '`' || cell[len(cell)-1] != '`' {
			failures = append(failures, fmt.Sprintf("Examples/README.md:%d has an unquoted program name %q", lineNumber+1, cell))
			continue
		}
		name := cell[1 : len(cell)-1]
		if !validProgramName(name) {
			failures = append(failures, fmt.Sprintf("Examples/README.md:%d has invalid program name %q", lineNumber+1, name))
			continue
		}
		if _, duplicate := programs[name]; duplicate {
			failures = append(failures, fmt.Sprintf("Examples/README.md:%d repeats program %q", lineNumber+1, name))
			continue
		}
		programs[name] = name
	}
	if !programTable {
		failures = append(failures, "Examples/README.md has no table with a Program column")
	} else if len(programs) == 0 {
		failures = append(failures, "Examples/README.md contains no backticked program rows")
	}
	return programs, failures
}

func compareProgramSets(filesystem, catalog map[string]string) []string {
	var failures []string
	for name := range filesystem {
		if _, listed := catalog[name]; !listed {
			failures = append(failures, fmt.Sprintf("Examples/%s is not listed in Examples/README.md", name))
		}
	}
	for name := range catalog {
		if _, present := filesystem[name]; !present {
			failures = append(failures, fmt.Sprintf("Examples/README.md lists %q, but Examples/%s/ is missing", name, name))
		}
	}
	return failures
}

func validProgramName(name string) bool {
	if name == "" || !isASCIILetter(name[0]) {
		return false
	}
	for index := 1; index < len(name); index++ {
		character := name[index]
		if !isASCIILetter(character) && (character < '0' || character > '9') {
			return false
		}
	}
	return true
}

func isASCIILetter(character byte) bool {
	return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z')
}
