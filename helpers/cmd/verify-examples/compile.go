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

// talacDiagnosticExit is the exit status with which talac reports that it
// rejected a program with diagnostics.
const talacDiagnosticExit = 1

// compileExpectation is what the catalogue says about one program.
type compileExpectation struct {
	compiles bool
	line     int
}

// compileOutcome is how talac ended for one program.
type compileOutcome int

const (
	// outcomeCompiled: talac exited with status 0.
	outcomeCompiled compileOutcome = iota
	// outcomeRejected: talac exited with its diagnostic status and named a
	// diagnostic of the program, such as "Fibonacci.tala:12:27: TAP0006: ...".
	outcomeRejected
	// outcomeFailed: anything else, such as a crash, a signal, another exit
	// status or a failure without a diagnostic of the program. It never
	// passes for the rejection a "no" cell expects.
	outcomeFailed
)

// readCompileExpectations reads the talac column of the Program table. Every
// program row needs a cell that starts with "yes" or "no".
func readCompileExpectations(markdown string) (map[string]compileExpectation, []string) {
	expectations := make(map[string]compileExpectation)
	var failures []string
	column := -1
	for lineNumber, line := range strings.Split(markdown, "\n") {
		cells, isRow := tableCells(line)
		if !isRow {
			if column >= 0 {
				break
			}
			continue
		}
		location := fmt.Sprintf("Examples/README.md:%d", lineNumber+1)
		if column < 0 {
			if cells[0] != "Program" {
				continue
			}
			if column = indexOf(cells, compileColumn); column < 0 {
				return nil, []string{fmt.Sprintf("%s: the Program table has no %q column", location, compileColumn)}
			}
			continue
		}
		if strings.Trim(cells[0], "-: ") == "" {
			continue
		}
		name := strings.Trim(cells[0], "`")
		expectation, failure := readCompileCell(cells, column, name, location)
		if failure != "" {
			failures = append(failures, failure)
			continue
		}
		expectation.line = lineNumber + 1
		expectations[name] = expectation
	}
	return expectations, failures
}

// tableCells splits a Markdown table row into its trimmed cells.
func tableCells(line string) ([]string, bool) {
	cells := strings.Split(strings.TrimSpace(line), "|")
	if len(cells) < 3 {
		return nil, false
	}
	cells = cells[1 : len(cells)-1]
	for index := range cells {
		cells[index] = strings.TrimSpace(cells[index])
	}
	return cells, true
}

func indexOf(cells []string, wanted string) int {
	for index, cell := range cells {
		if cell == wanted {
			return index
		}
	}
	return -1
}

// readCompileCell reads the talac cell of one program row.
func readCompileCell(cells []string, column int, name, location string) (compileExpectation, string) {
	if column >= len(cells) {
		return compileExpectation{}, fmt.Sprintf("%s: %s has no %q cell", location, name, compileColumn)
	}
	cell := cells[column]
	if cell == "yes" {
		return compileExpectation{compiles: true}, ""
	}
	if strings.HasPrefix(cell, "no: ") && strings.TrimSpace(cell[len("no: "):]) != "" {
		return compileExpectation{compiles: false}, ""
	}
	return compileExpectation{}, fmt.Sprintf("%s: %s says %q; write yes, or no: and what talac lacks", location, name, cell)
}

var (
	namespacePattern = regexp.MustCompile(`(?m)^namespace\s+([A-Za-z][A-Za-z0-9.]*)\s*;`)
	classPattern     = regexp.MustCompile(`\bclass\s+([A-Za-z][A-Za-z0-9]*)`)
	mainPattern      = regexp.MustCompile(`\bpublic\s+static\s+void\s+Main\s*\(\s*\)`)
	// stringOrComment matches a string literal or a "--" comment, which can
	// hold text that only looks like a declaration.
	stringOrComment = regexp.MustCompile(`"(?:[^"\\\n]|\\.)*"|--[^\n]*`)
)

// entryPoint is the --entry of a program: its namespace and the last class
// declared before its public static void Main(). Strings and comments are
// left out of the search.
func entryPoint(source string) (string, error) {
	code := stringOrComment.ReplaceAllStringFunc(source, func(text string) string {
		return strings.Repeat(" ", len(text))
	})
	namespace := namespacePattern.FindStringSubmatch(code)
	if namespace == nil {
		return "", errors.New("no namespace declaration")
	}
	main := mainPattern.FindAllStringIndex(code, -1)
	if len(main) != 1 {
		return "", fmt.Errorf("%d public static void Main() methods, want one", len(main))
	}
	classes := classPattern.FindAllStringSubmatch(code[:main[0][0]], -1)
	if len(classes) == 0 {
		return "", errors.New("no class before Main")
	}
	return namespace[1] + "." + classes[len(classes)-1][1], nil
}

// compileExamples compiles every Tala program to Core with talac and compares
// the outcome with the catalogue. A program marked yes must compile; one
// marked no must still be rejected with a diagnostic, so the catalogue is
// updated when talac gains what it needed, and a crash never passes for a
// rejection. Each program is compiled in a directory of its own, because
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
	expectations, err := readCatalogue(root)
	if err != nil {
		return 0, err
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
	var failures []string
	compiled := 0
	for _, name := range names {
		expectation := expectations[name]
		outcome, output, compileErr := compileExample(root, compiler, scratch, name)
		if failure := compareOutcome(name, expectation, outcome, output, compileErr); failure != "" {
			failures = append(failures, failure)
		} else if outcome == outcomeCompiled {
			compiled++
		}
	}
	if len(failures) != 0 {
		return compiled, errors.New("example compilation does not match Examples/README.md:\n - " + strings.Join(failures, "\n - "))
	}
	return compiled, nil
}

// readCatalogue reads the talac column of Examples/README.md.
func readCatalogue(root string) (map[string]compileExpectation, error) {
	catalog, err := os.ReadFile(filepath.Join(root, examplesDirectoryName, "README.md"))
	if err != nil {
		return nil, fmt.Errorf("read Examples/README.md: %w", err)
	}
	expectations, failures := readCompileExpectations(string(catalog))
	if len(failures) != 0 {
		return nil, errors.New("example compilation was not checked:\n - " + strings.Join(failures, "\n - "))
	}
	return expectations, nil
}

// compareOutcome says what is wrong when talac's outcome is not the one the
// catalogue states, or returns "".
func compareOutcome(name string, expectation compileExpectation, outcome compileOutcome, output string, err error) string {
	switch {
	case outcome == outcomeFailed && output == "":
		return fmt.Sprintf("%s: %v", name, err)
	case outcome == outcomeFailed:
		return fmt.Sprintf("%s: talac failed without a diagnostic of the program (%v):\n%s", name, err, indent(output))
	case expectation.compiles && outcome == outcomeRejected:
		return fmt.Sprintf("%s is marked yes on Examples/README.md:%d, but talac rejects it:\n%s", name, expectation.line, indent(output))
	case !expectation.compiles && outcome == outcomeCompiled:
		return fmt.Sprintf("%s compiles now; mark it yes on Examples/README.md:%d", name, expectation.line)
	}
	return ""
}

// compileExample compiles one program to Core and classifies how talac ended.
// A failure before talac ran is outcomeFailed with no output.
func compileExample(root, compiler, scratch, name string) (compileOutcome, string, error) {
	source, err := os.ReadFile(filepath.Join(root, examplesDirectoryName, name, name+".tala"))
	if err != nil {
		return outcomeFailed, "", err
	}
	entry, err := entryPoint(string(source))
	if err != nil {
		return outcomeFailed, "", err
	}
	directory := filepath.Join(scratch, name)
	if err := os.Mkdir(directory, 0o755); err != nil {
		return outcomeFailed, "", err
	}
	staged := filepath.Join(directory, name+".tala")
	if err := os.WriteFile(staged, source, 0o644); err != nil {
		return outcomeFailed, "", err
	}
	command := exec.Command(compiler, staged, "--entry="+entry, "--emit=core")
	command.Dir = directory
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	err = command.Run()
	if err == nil {
		return outcomeCompiled, output.String(), nil
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		return outcomeFailed, "", fmt.Errorf("cannot run talac: %w", err)
	}
	text := strings.TrimSpace(output.String()) + "\n"
	if exit.ExitCode() == talacDiagnosticExit && namesDiagnostic(text, name+".tala") {
		return outcomeRejected, text, err
	}
	return outcomeFailed, text, err
}

// namesDiagnostic reports whether talac's output holds a diagnostic of the
// file, in the form "<file>:<line>:<column>: TA<stage><number>: <message>".
func namesDiagnostic(output, file string) bool {
	pattern := regexp.MustCompile(`(?m)(?:^|[\s/\\])` + regexp.QuoteMeta(file) + `:\d+:\d+: TA[A-Z]+\d{4}: `)
	return pattern.MatchString(output)
}

func indent(text string) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	for index, line := range lines {
		lines[index] = "     " + line
	}
	return strings.Join(lines, "\n")
}
