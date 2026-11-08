// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// compileColumn is the header of the catalogue column that says whether
// talac compiles a program. Its cells are "yes", or "no" followed by what the
// program needs that talac does not have.
const compileColumn = "Compiles with talac"

// compileExpectation is what the catalogue says about one program.
type compileExpectation struct {
	compiles bool
	line     int
}

// readCompileExpectations reads the talac column of the Program table. Every
// program row needs a cell that starts with "yes" or "no".
func readCompileExpectations(markdown string) (map[string]compileExpectation, []string) {
	expectations := make(map[string]compileExpectation)
	var failures []string
	column := -1
	for lineNumber, line := range strings.Split(markdown, "\n") {
		cells := strings.Split(strings.TrimSpace(line), "|")
		if len(cells) < 3 {
			if column >= 0 {
				break
			}
			continue
		}
		cells = cells[1 : len(cells)-1]
		for index := range cells {
			cells[index] = strings.TrimSpace(cells[index])
		}
		if column < 0 {
			if cells[0] != "Program" {
				continue
			}
			for index, cell := range cells {
				if cell == compileColumn {
					column = index
				}
			}
			if column < 0 {
				return nil, []string{fmt.Sprintf("Examples/README.md:%d: the Program table has no %q column", lineNumber+1, compileColumn)}
			}
			continue
		}
		if strings.Trim(cells[0], "-: ") == "" {
			continue
		}
		name := strings.Trim(cells[0], "`")
		if column >= len(cells) {
			failures = append(failures, fmt.Sprintf("Examples/README.md:%d: %s has no %q cell", lineNumber+1, name, compileColumn))
			continue
		}
		cell := cells[column]
		switch {
		case cell == "yes":
			expectations[name] = compileExpectation{compiles: true, line: lineNumber + 1}
		case strings.HasPrefix(cell, "no: ") && len(strings.TrimSpace(cell[len("no: "):])) != 0:
			expectations[name] = compileExpectation{compiles: false, line: lineNumber + 1}
		default:
			failures = append(failures, fmt.Sprintf("Examples/README.md:%d: %s says %q; write yes, or no: and what talac lacks", lineNumber+1, name, cell))
		}
	}
	return expectations, failures
}

var (
	namespacePattern = regexp.MustCompile(`(?m)^namespace\s+([A-Za-z][A-Za-z0-9.]*)\s*;`)
	classPattern     = regexp.MustCompile(`\bclass\s+([A-Za-z][A-Za-z0-9]*)`)
	mainPattern      = regexp.MustCompile(`\bstatic\s+void\s+Main\s*\(\s*\)`)
)

// entryPoint is the --entry of a program: its namespace and the last class
// declared before its Main method.
func entryPoint(source string) (string, error) {
	namespace := namespacePattern.FindStringSubmatch(source)
	if namespace == nil {
		return "", errors.New("no namespace declaration")
	}
	main := mainPattern.FindStringIndex(source)
	if main == nil {
		return "", errors.New("no public static void Main()")
	}
	classes := classPattern.FindAllStringSubmatch(source[:main[0]], -1)
	if len(classes) == 0 {
		return "", errors.New("no class before Main")
	}
	return namespace[1] + "." + classes[len(classes)-1][1], nil
}

// compileExamples compiles every Tala program to Core with talac and compares
// the outcome with the catalogue. A program marked yes must compile; one
// marked no must still fail, so the catalogue is updated when talac gains
// what it needed. Each program is compiled in a directory of its own, because
// talac writes its output next to its input.
func compileExamples(repositoryRoot, talac string) (int, error) {
	root, err := filepath.Abs(repositoryRoot)
	if err != nil {
		return 0, fmt.Errorf("resolve repository root: %w", err)
	}
	compiler, err := filepath.Abs(talac)
	if err != nil {
		return 0, fmt.Errorf("resolve talac: %w", err)
	}
	catalog, err := os.ReadFile(filepath.Join(root, examplesDirectoryName, "README.md"))
	if err != nil {
		return 0, fmt.Errorf("read Examples/README.md: %w", err)
	}
	expectations, failures := readCompileExpectations(string(catalog))
	if len(failures) != 0 {
		return 0, errors.New("example compilation was not checked:\n - " + strings.Join(failures, "\n - "))
	}
	scratch, err := os.MkdirTemp("", "tala-examples-")
	if err != nil {
		return 0, fmt.Errorf("create a directory for the compilations: %w", err)
	}
	defer os.RemoveAll(scratch)

	names := make([]string, 0, len(expectations))
	for name := range expectations {
		names = append(names, name)
	}
	sort.Strings(names)
	compiled := 0
	for _, name := range names {
		expectation := expectations[name]
		output, compileErr := compileExample(root, compiler, scratch, name)
		switch {
		case compileErr != nil && output == "":
			failures = append(failures, fmt.Sprintf("%s: %v", name, compileErr))
		case expectation.compiles && compileErr != nil:
			failures = append(failures, fmt.Sprintf("%s is marked yes on Examples/README.md:%d, but talac rejects it:\n%s", name, expectation.line, indent(output)))
		case !expectation.compiles && compileErr == nil:
			failures = append(failures, fmt.Sprintf("%s compiles now; mark it yes on Examples/README.md:%d", name, expectation.line))
		case compileErr == nil:
			compiled++
		}
	}
	if len(failures) != 0 {
		return compiled, errors.New("example compilation does not match Examples/README.md:\n - " + strings.Join(failures, "\n - "))
	}
	return compiled, nil
}

// compileExample compiles one program to Core. It returns talac's output and
// an error when talac failed; a failure before talac ran has no output.
func compileExample(root, compiler, scratch, name string) (string, error) {
	source, err := os.ReadFile(filepath.Join(root, examplesDirectoryName, name, name+".tala"))
	if err != nil {
		return "", err
	}
	entry, err := entryPoint(string(source))
	if err != nil {
		return "", err
	}
	directory := filepath.Join(scratch, name)
	if err := os.Mkdir(directory, 0o755); err != nil {
		return "", err
	}
	staged := filepath.Join(directory, name+".tala")
	if err := os.WriteFile(staged, source, 0o644); err != nil {
		return "", err
	}
	command := exec.Command(compiler, staged, "--entry="+entry, "--emit=core")
	command.Dir = directory
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return strings.TrimSpace(output.String()) + "\n", err
		}
		return "", fmt.Errorf("cannot run talac: %w", err)
	}
	return output.String(), nil
}

func indent(text string) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	for index, line := range lines {
		lines[index] = "     " + line
	}
	return strings.Join(lines, "\n")
}
