// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

// Package executioncases writes the test tables that the Haskell frontend
// tests and the native smoke program share from the case files that own them.
//
// The case files under Talac/Fuzzing/Cases are the only place a case is
// written. The Haskell module runs each case in a reference Core evaluator and
// the C++ tables run it through LLVM; both must return the expected value the
// case file states. Generating the two tables from one file keeps them equal.
// It is not a second opinion on that value: an expected value that is wrong in
// the case file is wrong in both tables. The values are therefore written by
// hand from the language rules, and tests whose expectations do not come from
// these files stay beside them.
package executioncases

import (
	"bufio"
	"fmt"
	"strconv"
	"strings"
)

// Run is one call of a case body and the value it must return.
type Run struct {
	Flag     bool
	Other    bool
	Left     int64
	Right    int64
	Expected int64
}

// Case is one body of `int Run(bool flag, bool other, int left, int right)`
// with the comment written above it and its runs in file order.
type Case struct {
	Comment []string
	Body    string
	Runs    []Run
}

// Parse reads a case file. The name is used in error messages only.
func Parse(name string, text string) ([]Case, error) {
	var cases []Case
	var comment []string
	scanner := bufio.NewScanner(strings.NewReader(text))
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	line := 0
	fail := func(format string, arguments ...any) ([]Case, error) {
		return nil, fmt.Errorf("%s:%d: %s", name, line, fmt.Sprintf(format, arguments...))
	}
	for scanner.Scan() {
		line++
		current := strings.TrimRight(scanner.Text(), " \t\r")
		switch {
		case current == "":
			// A comment belongs to the body directly below it.
			comment = nil
		case strings.HasPrefix(current, "#"):
			comment = append(comment, strings.TrimPrefix(strings.TrimPrefix(current, "#"), " "))
		case strings.HasPrefix(current, "body: "):
			body := strings.TrimPrefix(current, "body: ")
			if strings.TrimSpace(body) == "" {
				return fail("a body is empty")
			}
			for _, earlier := range cases {
				if earlier.Body == body {
					return fail("this body is already a case; add the run to it")
				}
			}
			cases = append(cases, Case{Comment: comment, Body: body})
			comment = nil
		case strings.HasPrefix(current, "run: "):
			if len(cases) == 0 || comment != nil {
				return fail("a run must follow the body it runs")
			}
			run, err := parseRun(strings.TrimPrefix(current, "run: "))
			if err != nil {
				return fail("%v", err)
			}
			last := &cases[len(cases)-1]
			last.Runs = append(last.Runs, run)
		default:
			return fail("expected a comment, `body: ` or `run: `")
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	for _, parsed := range cases {
		if len(parsed.Runs) == 0 {
			return nil, fmt.Errorf("%s: the body %q has no run", name, parsed.Body)
		}
	}
	if len(cases) == 0 {
		return nil, fmt.Errorf("%s: the file has no case", name)
	}
	return cases, nil
}

// parseRun reads `plain L R -> E` or `flags F O L R -> E`.
func parseRun(text string) (Run, error) {
	arguments, expected, found := strings.Cut(text, " -> ")
	if !found {
		return Run{}, fmt.Errorf("a run needs ` -> ` and its expected value")
	}
	fields := strings.Fields(arguments)
	var run Run
	var numbers []string
	switch {
	case len(fields) == 3 && fields[0] == "plain":
		numbers = fields[1:]
	case len(fields) == 5 && fields[0] == "flags":
		flag, err := strconv.ParseBool(fields[1])
		if err != nil || (fields[1] != "true" && fields[1] != "false") {
			return Run{}, fmt.Errorf("flag must be true or false, not %q", fields[1])
		}
		other, err := strconv.ParseBool(fields[2])
		if err != nil || (fields[2] != "true" && fields[2] != "false") {
			return Run{}, fmt.Errorf("other must be true or false, not %q", fields[2])
		}
		run.Flag, run.Other = flag, other
		numbers = fields[3:]
	default:
		return Run{}, fmt.Errorf("a run is `plain <left> <right>` or `flags <flag> <other> <left> <right>`")
	}
	values := make([]int64, 0, 3)
	for _, number := range append(numbers, strings.TrimSpace(expected)) {
		// The arguments are `int` in the language and in both harnesses.
		value, err := strconv.ParseInt(number, 10, 32)
		if err != nil {
			return Run{}, fmt.Errorf("%q is not a 32-bit integer", number)
		}
		values = append(values, value)
	}
	run.Left, run.Right, run.Expected = values[0], values[1], values[2]
	return run, nil
}
