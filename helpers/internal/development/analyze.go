// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

// The Clang Static Analyzer explores the paths through each function and
// reports the ones on which something goes wrong: a null pointer that is
// dereferenced, a value that is read before it is written, memory that is
// freed twice or never. clang-tidy runs the analyzer's default checkers as
// one group among its own. This command runs the analyzer itself, with the
// checkers that have to be asked for and with the steps of each path in the
// report, and can write what it finds as SARIF.

// analyzerOptInCheckers are stable checkers the analyzer does not enable by
// itself. A finding of one of them fails the command, like a finding of a
// default checker.
var analyzerOptInCheckers = []string{
	"nullability.NullableDereferenced",
	"nullability.NullablePassedToNonnull",
	"nullability.NullableReturnedFromNonnull",
	"optin.core.EnumCastOutOfRange",
	"optin.cplusplus.UninitializedObject",
	"optin.cplusplus.VirtualCall",
	"optin.portability.UnixAPI",
	"security.ArrayBound",
	"security.FloatLoopCounter",
	"security.PointerSub",
	"security.cert.env.InvalidPtr",
	"security.insecureAPI.strcpy",
}

// analyzerAlphaCheckers are checkers LLVM still develops. They find what no
// stable checker looks for, a smart pointer that is read after it was moved
// from, a buffer that is overrun, a conversion that loses a sign, and they
// are wrong more often. Their findings are reported and never fail the
// command.
//
// Three groups are left out because all they report on this code is wrong.
// The iterator checkers stop the analyzer itself in comparisons the test
// framework wraps, and report, several hundred times, the erase of what
// std::ranges::unique returns. alpha.security.ReturnPtrRange reports the
// move assignment std::ranges::reverse performs on a vector's elements, and
// alpha.core.StoreToImmutable the constructor of an object declared const.
var analyzerAlphaCheckers = []string{
	"alpha.core.BoolAssignment",
	"alpha.core.Conversion",
	"alpha.core.PointerArithm",
	"alpha.core.StdVariant",
	"alpha.core.TestAfterDivZero",
	"alpha.cplusplus.DeleteWithNonVirtualDtor",
	"alpha.cplusplus.SmartPtr",
	"alpha.security.ArrayBoundV2",
	"alpha.unix.cstring.BufferOverlap",
	"alpha.unix.cstring.OutOfBounds",
	"alpha.unix.cstring.UninitializedRead",
}

// analyzerTestOnlyDisabledCheckers are switched off for translation units
// under a Tests directory, for the reason clang-tidy switches off its copy:
// the fixtures' values are released by destructors the leak checker does
// not follow through the standard library.
var analyzerTestOnlyDisabledCheckers = []string{"cplusplus.NewDeleteLeaks"}

// analyzerFinding is one report of the analyzer: where, which checker, what
// it says, and the steps of the path that leads there.
type analyzerFinding struct {
	File    string
	Line    int
	Column  int
	Checker string
	Message string
	Steps   []analyzerStep
}

// analyzerStep is one note under a report.
type analyzerStep struct {
	File    string
	Line    int
	Column  int
	Message string
}

// advisory reports whether a finding comes from a checker that is still in
// development and therefore does not fail the command.
func (finding analyzerFinding) advisory() bool {
	return strings.HasPrefix(finding.Checker, "alpha.")
}

// analyzerCheckerName matches one checker in the analyzer's own listing.
var analyzerCheckerName = regexp.MustCompile(`(?m)^  ([A-Za-z0-9_.-]+)(?:\s|$)`)

// availableCheckers keeps the wanted checkers this analyzer has, in the
// order they were asked for. Checkers are renamed and promoted between LLVM
// releases, and the analyzer refuses to run with a name it does not know.
func availableCheckers(listing string, wanted []string) []string {
	known := map[string]bool{}
	for _, match := range analyzerCheckerName.FindAllStringSubmatch(listing, -1) {
		known[match[1]] = true
	}
	var available []string
	for _, name := range wanted {
		if known[name] {
			available = append(available, name)
		}
	}
	return available
}

// analyzerCommand turns the command a unit is compiled with into the one
// that analyzes it. What names an output is dropped, because nothing is
// written; everything that decides what the source means is kept. The
// command has to be given without its compiler.
func analyzerCommand(compile []string, source string, checkers []string) []string {
	// The output format is given to the frontend: the clang-cl driver does
	// not know the driver's own spelling of it and would write report files.
	arguments := []string{"--analyze", "-Xclang", "-analyzer-output=text"}
	for _, checker := range checkers {
		arguments = append(arguments, "-Xclang", "-analyzer-checker="+checker)
	}
	if strings.Contains("/"+source, "/Tests/") {
		for _, checker := range analyzerTestOnlyDisabledCheckers {
			arguments = append(arguments, "-Xclang", "-analyzer-disable-checker="+checker)
		}
	}
	// A finding is a report, not a reason to stop: with the build's
	// -Werror the first one would end the analysis of its unit.
	arguments = append(arguments, "-Wno-error")
	for index := 0; index < len(compile); index++ {
		argument := compile[index]
		switch {
		case argument == "-c" || argument == "/c" || argument == "-MD" || argument == "-MMD" || argument == "/showIncludes":
			continue
		case argument == "-o" || argument == "-MF" || argument == "-MT" || argument == "-MQ":
			index++
			continue
		case strings.HasPrefix(argument, "/Fo") || strings.HasPrefix(argument, "/Fd"):
			continue
		case strings.HasPrefix(argument, "-Werror") || argument == "/WX" || argument == "/clang:-Werror":
			continue
		}
		arguments = append(arguments, argument)
	}
	return arguments
}

// analyzerDiagnostic matches the first line of a report or of a note: a
// place, a severity and a message, with the checker in brackets on a report.
// The place is path:line:column from the clang driver and path(line,column)
// from clang-cl, which writes diagnostics the way the Microsoft compiler
// does. A report in a form this does not match would be a finding that is
// never counted.
var analyzerDiagnostic = regexp.MustCompile(
	`^(.+?)(?::(\d+):(\d+)|\((\d+),(\d+)\)): (fatal error|error|warning|note): (.*?)(?: \[([A-Za-z0-9_.,-]+)\])?$`)

// analyzerFindings reads the analyzer's text report. It returns the findings
// located in first-party code, how many were located elsewhere, and the
// compiler errors, which mean the unit was not analyzed. A report without a
// checker is a compiler warning and none of the analyzer's.
func analyzerFindings(output, executionRoot string) (ours []analyzerFinding, foreign int, compileErrors []string) {
	root := strings.ToLower(strings.ReplaceAll(executionRoot, `\`, "/"))
	relative := func(path string) string {
		path = strings.ReplaceAll(path, `\`, "/")
		if root != "" && strings.HasPrefix(strings.ToLower(path), root+"/") {
			path = path[len(root)+1:]
		}
		return strings.TrimPrefix(path, "./")
	}
	keep := false
	for _, line := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		match := analyzerDiagnostic.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		path := relative(match[1])
		lineNumber, _ := strconv.Atoi(match[2] + match[4])
		column, _ := strconv.Atoi(match[3] + match[5])
		message, checker := match[7], match[8]
		switch match[6] {
		case "note":
			if keep {
				last := &ours[len(ours)-1]
				last.Steps = append(last.Steps, analyzerStep{File: path, Line: lineNumber, Column: column, Message: message})
			}
		case "error", "fatal error":
			keep = false
			compileErrors = append(compileErrors, line)
		default:
			keep = false
			if checker == "" || strings.HasPrefix(checker, "-W") {
				continue
			}
			if !isFirstPartyLocation(path) {
				foreign++
				continue
			}
			keep = true
			ours = append(ours, analyzerFinding{File: path, Line: lineNumber, Column: column, Checker: checker, Message: message})
		}
	}
	return ours, foreign, compileErrors
}

// uniqueFindings removes the reports several translation units make of the
// same place in a shared header, and orders the rest by place and checker.
func uniqueFindings(findings []analyzerFinding) []analyzerFinding {
	seen := map[string]bool{}
	var unique []analyzerFinding
	for _, finding := range findings {
		key := fmt.Sprintf("%s:%d:%d:%s:%s", finding.File, finding.Line, finding.Column, finding.Checker, finding.Message)
		if !seen[key] {
			seen[key] = true
			unique = append(unique, finding)
		}
	}
	sort.SliceStable(unique, func(left, right int) bool {
		first, second := unique[left], unique[right]
		if first.File != second.File {
			return first.File < second.File
		}
		if first.Line != second.Line {
			return first.Line < second.Line
		}
		if first.Column != second.Column {
			return first.Column < second.Column
		}
		return first.Checker < second.Checker
	})
	return unique
}

// publicHeader matches a first-party header as a translation unit sees it:
// the copy Bazel exposes below its output tree, under a directory named
// after the target that owns it.
var publicHeader = regexp.MustCompile(`^bazel-out/[^/]+/bin/_virtual_includes/[^/]+/(.+)$`)

// headerRoots are the directories whose headers Bazel exposes that way.
var headerRoots = []string{"Talac/Headers", "Interactive/Headers"}

// sourceLocation returns the file in the repository a location names. A
// header below the output tree is the copy of a header under one of the
// header roots; the finding belongs to that header, where its suppression
// comments are and where code scanning can show it. Any other location, and
// a copy whose original is not found, is returned as it is.
func sourceLocation(repository string, path string) string {
	match := publicHeader.FindStringSubmatch(path)
	if match == nil {
		return path
	}
	for _, root := range headerRoots {
		candidate := root + "/" + match[1]
		if info, err := os.Stat(filepath.Join(repository, filepath.FromSlash(candidate))); err == nil && info.Mode().IsRegular() {
			return candidate
		}
	}
	return path
}

// inRepository rewrites the places of findings and of their steps to the
// files of the repository.
func inRepository(repository string, findings []analyzerFinding) []analyzerFinding {
	for index := range findings {
		findings[index].File = sourceLocation(repository, findings[index].File)
		for step := range findings[index].Steps {
			findings[index].Steps[step].File = sourceLocation(repository, findings[index].Steps[step].File)
		}
	}
	return findings
}

// analyzerSuppression matches the comment that silences a clang-tidy check
// on its own line or on the next one, with the checks it names.
var analyzerSuppression = regexp.MustCompile(`NOLINT(NEXTLINE)?(?:\(([^)]*)\))?`)

// suppressedBy reports whether the lines around a finding silence it. The
// comment is the one clang-tidy reads, with the name clang-tidy gives the
// checker, so that one comment answers both tools: NOLINT on the line of the
// finding, or NOLINTNEXTLINE on the line before it, naming
// clang-analyzer-<checker> or naming nothing.
func suppressedBy(lines []string, finding analyzerFinding) bool {
	names := func(line string, nextLine bool) bool {
		for _, match := range analyzerSuppression.FindAllStringSubmatch(line, -1) {
			if (match[1] == "NEXTLINE") != nextLine {
				continue
			}
			if !strings.Contains(match[0], "(") {
				return true
			}
			for _, check := range strings.Split(match[2], ",") {
				check = strings.TrimSpace(check)
				if check == "clang-analyzer-"+finding.Checker || check == "clang-analyzer-*" || check == "*" {
					return true
				}
			}
		}
		return false
	}
	if finding.Line >= 1 && finding.Line <= len(lines) && names(lines[finding.Line-1], false) {
		return true
	}
	return finding.Line >= 2 && finding.Line-1 <= len(lines) && names(lines[finding.Line-2], true)
}

// withoutSuppressed drops the findings a comment in the source silences and
// returns how many it dropped. A finding in a file that cannot be read from
// the repository, a header under the output tree, is kept.
func withoutSuppressed(repository string, findings []analyzerFinding) ([]analyzerFinding, int) {
	sources := map[string][]string{}
	var kept []analyzerFinding
	dropped := 0
	for _, finding := range findings {
		lines, read := sources[finding.File]
		if !read {
			if content, err := os.ReadFile(filepath.Join(repository, filepath.FromSlash(finding.File))); err == nil {
				lines = strings.Split(strings.ReplaceAll(string(content), "\r\n", "\n"), "\n")
			}
			sources[finding.File] = lines
		}
		if suppressedBy(lines, finding) {
			dropped++
			continue
		}
		kept = append(kept, finding)
	}
	return kept, dropped
}

// analyzerProbe is a program with one defect every version of the analyzer
// reports: on the path where flag is false, a null pointer is dereferenced.
const analyzerProbe = `int Read(int *pointer, bool flag)
{
    int *chosen = flag ? pointer : nullptr;
    if (flag)
        return 1;
    return *chosen;
}
`

// probeReported reports whether the analyzer's output for the probe holds
// its defect in a form this command reads.
func probeReported(output string) bool {
	for _, line := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		match := analyzerDiagnostic.FindStringSubmatch(line)
		if match != nil && match[6] == "warning" && match[8] == "core.NullDereference" {
			return true
		}
	}
	return false
}

// proveAnalyzerReports analyzes the probe with the compiler, the checkers
// and the options of the real run, and fails unless its defect comes back.
// A run that finds nothing is only worth believing when the same analyzer,
// asked the same way, is known to find something: a compiler that does not
// analyze, an option it ignores or a report in a form this command cannot
// read would otherwise look like clean code.
func proveAnalyzerReports(runner commandRunner, compiler string, checkers []string) error {
	directory, err := os.MkdirTemp("", "tala-analyze-probe-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	source := filepath.Join(directory, "probe.cpp")
	if err := os.WriteFile(source, []byte(analyzerProbe), 0o600); err != nil {
		return err
	}
	output, err := runner.OutputIn(directory, compiler, analyzerCommand([]string{"probe.cpp"}, "probe.cpp", checkers)...)
	if !probeReported(output) {
		return fmt.Errorf("the analyzer of %q did not report the defect of the probe program, so a clean result from it would mean nothing (%v):\n%s",
			compiler, err, strings.TrimSpace(output))
	}
	return nil
}

// filterUnits keeps the units whose path contains the given text.
func filterUnits(units []tidyUnit, filter string) []tidyUnit {
	var kept []tidyUnit
	for _, unit := range units {
		if strings.Contains(unit.File, filter) {
			kept = append(kept, unit)
		}
	}
	return kept
}

func printFinding(finding analyzerFinding) {
	fmt.Printf("%s:%d:%d: %s [%s]\n", finding.File, finding.Line, finding.Column, finding.Message, finding.Checker)
	for _, step := range finding.Steps {
		fmt.Printf("    %s:%d:%d: %s\n", step.File, step.Line, step.Column, step.Message)
	}
}

// runAnalyze builds the native targets, recovers their compile commands from
// Bazel and runs the Clang Static Analyzer over every first-party
// translation unit, each with the compiler and the options it is built with.
//
// TALA_ANALYZE_JOBS sets how many analyzer processes run at once,
// TALA_ANALYZE_SARIF names a file that receives every finding as SARIF, and
// TALA_ANALYZE_FILTER limits the run to the units whose path contains it,
// for trying a change on one directory.
func runAnalyze(repository string, runner commandRunner, bazelArguments []string) error {
	jobs, err := tidyJobs(os.Getenv("TALA_ANALYZE_JOBS"), runtime.NumCPU())
	if err != nil {
		return errors.New("TALA_ANALYZE_JOBS must be an integer in [1, 256]")
	}
	units, root, err := compiledUnits(repository, runner, bazelArguments)
	if err != nil {
		return err
	}
	if filter := os.Getenv("TALA_ANALYZE_FILTER"); filter != "" {
		units = filterUnits(units, filter)
		if len(units) == 0 {
			return fmt.Errorf("TALA_ANALYZE_FILTER=%q matches no first-party translation unit", filter)
		}
	}
	// Each unit is analyzed by the compiler that compiles it, so that the
	// analyzer reads the source as the build does.
	compiler := units[0].Arguments[0]
	version, err := runner.OutputIn(root, compiler, "--version")
	if err != nil {
		return fmt.Errorf("the compiler %q of the native build does not run: %w", compiler, err)
	}
	stable, _ := runner.OutputIn(root, compiler, "-cc1", "-analyzer-checker-help")
	alpha, _ := runner.OutputIn(root, compiler, "-cc1", "-analyzer-checker-help-alpha")
	checkers := append(availableCheckers(stable, analyzerOptInCheckers), availableCheckers(alpha, analyzerAlphaCheckers)...)
	if len(checkers) == 0 {
		return fmt.Errorf("the compiler %q lists none of the analyzer's checkers; it is not Clang, or it was built without the static analyzer", compiler)
	}
	if err := proveAnalyzerReports(runner, compiler, checkers); err != nil {
		return err
	}
	fmt.Printf("The analyzer reported the defect of the probe program.\n")
	fmt.Printf("Analyzing %d first-party translation units with %d analyzer processes and %d checkers beyond the default ones...\n",
		len(units), jobs, len(checkers))
	outcomes := runTidyUnits(units, jobs, func(unit tidyUnit) (string, error) {
		return runner.OutputIn(root, unit.Arguments[0], analyzerCommand(unit.Arguments[1:], unit.File, checkers)...)
	})

	var findings []analyzerFinding
	foreign, broken := 0, 0
	for _, outcome := range outcomes {
		ours, elsewhere, compileErrors := analyzerFindings(outcome.output, root)
		findings = append(findings, ours...)
		foreign += elsewhere
		// A unit that was not analyzed must not look like a clean one.
		if len(compileErrors) != 0 || (outcome.err != nil && len(ours) == 0 && elsewhere == 0) {
			broken++
			fmt.Printf("\n%s was not analyzed: %v\n%s\n", outcome.file, outcome.err, strings.TrimSpace(outcome.output))
		}
	}
	findings, suppressed := withoutSuppressed(repository, uniqueFindings(inRepository(repository, findings)))
	blocking, advisory := 0, 0
	for _, finding := range findings {
		if finding.advisory() {
			advisory++
		} else {
			blocking++
		}
	}
	if blocking != 0 {
		fmt.Printf("\nFindings of stable checkers:\n\n")
		for _, finding := range findings {
			if !finding.advisory() {
				printFinding(finding)
			}
		}
	}
	if advisory != 0 {
		fmt.Printf("\nFindings of checkers that are still in development (reported, not counted):\n\n")
		for _, finding := range findings {
			if finding.advisory() {
				printFinding(finding)
			}
		}
	}
	if foreign != 0 {
		fmt.Printf("\n%d findings located in dependency headers were not counted.\n", foreign)
	}
	if suppressed != 0 {
		fmt.Printf("\n%d findings are silenced by a NOLINT comment in the source.\n", suppressed)
	}
	if target := os.Getenv("TALA_ANALYZE_SARIF"); target != "" {
		document, err := analyzerSarif(findings, strings.SplitN(version, "\n", 2)[0])
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(target, document, 0o644); err != nil {
			return err
		}
		fmt.Printf("\nWrote %d findings as SARIF to %s.\n", len(findings), target)
	}
	if broken != 0 {
		return fmt.Errorf("the Clang Static Analyzer could not analyze %d of %d translation units", broken, len(outcomes))
	}
	if blocking != 0 {
		return fmt.Errorf("the Clang Static Analyzer reported %d findings of stable checkers in first-party code", blocking)
	}
	fmt.Printf("\nThe Clang Static Analyzer analyzed %d translation units without a finding of a stable checker; %d advisory findings.\n",
		len(outcomes), advisory)
	return nil
}
