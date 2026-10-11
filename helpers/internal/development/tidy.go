// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// tidyRoots are the first-party C++ trees clang-tidy analyzes. Vendored and
// fetched dependencies compile inside the same Bazel actions but are not ours
// to lint.
var tidyRoots = []string{"Compiler/", "Interactive/", "Benchmarks/"}

// tidyUnit is one first-party translation unit together with the exact
// compiler command Bazel uses for it.
type tidyUnit struct {
	Directory string   `json:"directory"`
	File      string   `json:"file"`
	Arguments []string `json:"arguments"`
}

// tidyOutcome is the analyzer's verdict for one translation unit.
type tidyOutcome struct {
	file   string
	output string
	err    error
}

// tidyDiagnostic matches the first line of one clang-tidy diagnostic:
// path:line:column: severity: message [check].
var tidyDiagnostic = regexp.MustCompile(`^(.+?):\d+:\d+: (?:error|warning): .* \[([^\]]+)\]$`)

// tidyFindings splits an analyzer report into the diagnostics that are ours
// and the number that are not. A check finding belongs to the file it is
// reported in: one located in a vendored or fetched header is that
// dependency's, even when a first-party test instantiates the code. A
// compiler error is ours wherever it is reported, because the unit was then
// not analyzed. Each returned block keeps the notes that follow its first
// line.
func tidyFindings(output, executionRoot string) (ours []string, foreign int) {
	root := strings.ToLower(strings.ReplaceAll(executionRoot, `\`, "/"))
	keep := false
	for _, line := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		match := tidyDiagnostic.FindStringSubmatch(line)
		if match == nil {
			if keep && strings.TrimSpace(line) != "" {
				ours[len(ours)-1] += "\n" + line
			}
			continue
		}
		path := strings.ReplaceAll(match[1], `\`, "/")
		if root != "" && strings.HasPrefix(strings.ToLower(path), root+"/") {
			path = path[len(root)+1:]
		}
		keep = isFirstPartyLocation(strings.TrimPrefix(path, "./")) || strings.Contains(match[2], "clang-diagnostic-error")
		if keep {
			ours = append(ours, line)
		} else {
			foreign++
		}
	}
	return ours, foreign
}

// captureStandardOutput runs a tool and returns only its standard output.
// Bazel writes progress to standard error, which must not reach the JSON
// decoder. Tests replace it to supply a recorded action graph.
var captureStandardOutput = func(directory, name string, arguments ...string) ([]byte, error) {
	command := exec.Command(name, arguments...)
	command.Dir = directory
	command.Stderr = os.Stderr
	return command.Output()
}

// tidyActionQuery selects every C++ compile action the native build performs.
// Dependencies are included so library sources are analyzed with the flags of
// their own target rather than only the test files that link them.
func tidyActionQuery(targets []string) string {
	return `mnemonic("CppCompile", deps(set(` + strings.Join(targets, " ") + `)))`
}

func tidyTargets() []string {
	targets := []string{"//Compiler/Cli:vxs", "//Interactive:vxsi"}
	return append(targets, nativeTargets...)
}

// tidyJobs selects how many analyzer processes run at once. Each process is
// single-threaded and independent, so one per logical processor is the
// useful maximum. VXS_TIDY_JOBS overrides it.
func tidyJobs(configured string, logicalProcessors int) (int, error) {
	if configured != "" {
		jobs, err := strconv.Atoi(configured)
		if err != nil || jobs < 1 || jobs > 256 {
			return 0, errors.New("VXS_TIDY_JOBS must be an integer in [1, 256]")
		}
		return jobs, nil
	}
	if logicalProcessors < 1 {
		return 1, nil
	}
	return logicalProcessors, nil
}

// expandParameterFiles replaces every @file argument with the arguments stored
// in that file. Bazel moves long command lines into parameter files on
// Windows; they exist only after the owning action has been built. A missing
// file is reported so an unbuilt unit is never silently skipped.
func expandParameterFiles(executionRoot string, arguments []string) ([]string, error) {
	expanded := make([]string, 0, len(arguments))
	for _, argument := range arguments {
		path, isFile := strings.CutPrefix(argument, "@")
		if !isFile {
			expanded = append(expanded, argument)
			continue
		}
		content, err := os.ReadFile(filepath.Join(executionRoot, filepath.FromSlash(path)))
		if err != nil {
			return nil, fmt.Errorf("compiler parameter file %s is not available: %w", path, err)
		}
		for _, line := range strings.Split(string(content), "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			if len(line) >= 2 && strings.HasPrefix(line, `"`) && strings.HasSuffix(line, `"`) {
				line = strings.ReplaceAll(line[1:len(line)-1], `\"`, `"`)
			}
			expanded = append(expanded, line)
		}
	}
	return expanded, nil
}

// tidySource returns the translation unit a compile command builds: the last
// argument that names a C or C++ source and is not an output option.
func tidySource(arguments []string) string {
	for index := len(arguments) - 1; index >= 0; index-- {
		argument := arguments[index]
		if strings.HasPrefix(argument, "-") || strings.HasPrefix(argument, "/Fo") || strings.HasPrefix(argument, "/Fd") {
			continue
		}
		switch strings.ToLower(filepath.Ext(argument)) {
		case ".cpp", ".cc", ".cxx", ".c":
			// Bazel spells Windows sources with either separator.
			return strings.ReplaceAll(argument, `\`, "/")
		}
	}
	return ""
}

func isFirstPartySource(source string) bool {
	for _, root := range tidyRoots {
		if strings.HasPrefix(source, root) {
			return true
		}
	}
	return false
}

// firstPartyOutput matches first-party files below Bazel's output tree: the
// public headers Bazel exposes through the main repository's virtual include
// directories and anything generated into a first-party package. Outputs of
// fetched repositories live under bin/external and do not match.
var firstPartyOutput = regexp.MustCompile(`^bazel-out/[^/]+/bin/(_virtual_includes|Compiler|Interactive|Benchmarks)/`)

// isFirstPartyLocation reports whether a diagnostic location is ours.
func isFirstPartyLocation(path string) bool {
	return isFirstPartySource(path) || firstPartyOutput.MatchString(path)
}

// testOnlyDisabledChecks are switched off for translation units under a
// Tests directory, and only there. Both model control flow the test
// framework hides from the analyzer: REQUIRE aborts the test case before a
// rejected optional is read, and the fixtures' value types are released by
// destructors the leak checker does not follow through the standard library.
// Production code keeps both checks.
var testOnlyDisabledChecks = []string{
	"bugprone-unchecked-optional-access",
	"clang-analyzer-cplusplus.NewDeleteLeaks",
}

// tidyCheckOverride returns the --checks value for one unit, or "" when the
// repository configuration applies unchanged. clang-tidy appends the value
// to the configured list.
func tidyCheckOverride(source string) string {
	if !strings.Contains("/"+source, "/Tests/") {
		return ""
	}
	return "-" + strings.Join(testOnlyDisabledChecks, ",-")
}

// tidyUnitsFromActions turns a Bazel action graph into the first-party
// translation units, sorted by path and without duplicates. One source that
// several targets compile is analyzed once, with the first command in action
// order.
func tidyUnitsFromActions(graph []byte, executionRoot string) ([]tidyUnit, error) {
	var document struct {
		Actions []struct {
			Arguments []string `json:"arguments"`
		} `json:"actions"`
	}
	if err := json.Unmarshal(graph, &document); err != nil {
		return nil, fmt.Errorf("Bazel action graph is not valid JSON: %w", err)
	}
	units := map[string]tidyUnit{}
	for _, action := range document.Actions {
		// The source is named on the command line or inside a parameter
		// file. Skip third-party actions before requiring their parameter
		// files, which exist only for targets that were built.
		if source := tidySource(action.Arguments); source != "" && !isFirstPartySource(source) {
			continue
		}
		arguments, err := expandParameterFiles(executionRoot, action.Arguments)
		if err != nil {
			if tidySource(action.Arguments) == "" && !mentionsFirstParty(action.Arguments) {
				continue
			}
			return nil, err
		}
		source := tidySource(arguments)
		if source == "" || !isFirstPartySource(source) {
			continue
		}
		if _, seen := units[source]; !seen {
			units[source] = tidyUnit{Directory: executionRoot, File: source, Arguments: arguments}
		}
	}
	if len(units) == 0 {
		return nil, errors.New("the Bazel action graph contains no first-party C++ translation unit")
	}
	ordered := make([]tidyUnit, 0, len(units))
	for _, unit := range units {
		ordered = append(ordered, unit)
	}
	sort.Slice(ordered, func(left, right int) bool { return ordered[left].File < ordered[right].File })
	return ordered, nil
}

// mentionsFirstParty reports whether an unexpanded command refers to a
// first-party output, which is how a parameter-file action identifies its
// owner before the file can be read.
func mentionsFirstParty(arguments []string) bool {
	for _, argument := range arguments {
		normalized := filepath.ToSlash(argument)
		for _, root := range tidyRoots {
			if strings.Contains(normalized, "/bin/"+root) {
				return true
			}
		}
	}
	return false
}

// runTidyUnits analyzes every unit with at most jobs processes at a time and
// returns the outcomes in unit order, so the report does not depend on
// scheduling.
func runTidyUnits(units []tidyUnit, jobs int, analyze func(tidyUnit) (string, error)) []tidyOutcome {
	outcomes := make([]tidyOutcome, len(units))
	slots := make(chan struct{}, jobs)
	var group sync.WaitGroup
	for index, unit := range units {
		group.Add(1)
		slots <- struct{}{}
		go func() {
			defer group.Done()
			defer func() { <-slots }()
			output, err := analyze(unit)
			outcomes[index] = tidyOutcome{file: unit.File, output: output, err: err}
		}()
	}
	group.Wait()
	return outcomes
}

// reportTidyOutcomes prints the first-party diagnostics of every failing unit
// and returns an error naming how many units failed. A unit fails when it has
// a first-party finding, and also when the analyzer exits unsuccessfully
// without any diagnostic this function can attribute: a crash or an
// unreadable report must not look like a clean unit.
func reportTidyOutcomes(outcomes []tidyOutcome, executionRoot string) error {
	failed, ignored := 0, 0
	for _, outcome := range outcomes {
		ours, foreign := tidyFindings(outcome.output, executionRoot)
		ignored += foreign
		unexplained := outcome.err != nil && len(ours) == 0 && foreign == 0
		if len(ours) == 0 && !unexplained {
			continue
		}
		failed++
		fmt.Printf("\n%s\n", outcome.file)
		for _, finding := range ours {
			fmt.Println(finding)
		}
		if unexplained {
			fmt.Printf("clang-tidy failed without an attributable diagnostic: %v\n%s\n", outcome.err, strings.TrimSpace(outcome.output))
		}
	}
	if ignored != 0 {
		fmt.Printf("\n%d findings located in dependency headers were not counted.\n", ignored)
	}
	if failed != 0 {
		return fmt.Errorf("clang-tidy reported findings in %d of %d translation units", failed, len(outcomes))
	}
	fmt.Printf("\nclang-tidy analyzed %d translation units without a first-party finding.\n", len(outcomes))
	return nil
}

// compiledUnits builds the native targets and recovers from Bazel the
// first-party translation units with the command each is compiled with, and
// the execution root those commands are relative to.
func compiledUnits(repository string, runner commandRunner, bazelArguments []string) ([]tidyUnit, string, error) {
	// The build produces generated headers, fetches dependency headers and,
	// on Windows, writes the parameter files that hold the commands.
	if err := buildTargets(repository, runner, "", bazelArguments); err != nil {
		return nil, "", err
	}
	bazel, err := findBazel(runner)
	if err != nil {
		return nil, "", err
	}
	executionRoot, err := captureStandardOutput(repository, bazel, "info", "execution_root")
	if err != nil {
		return nil, "", fmt.Errorf("Bazel execution root is not available: %w", err)
	}
	root := strings.TrimSpace(string(executionRoot))
	query := append([]string{"aquery", tidyActionQuery(tidyTargets()), "--output=jsonproto"}, bazelArguments...)
	graph, err := captureStandardOutput(repository, bazel, query...)
	if err != nil {
		return nil, "", fmt.Errorf("Bazel action query failed: %w", err)
	}
	units, err := tidyUnitsFromActions(graph, root)
	if err != nil {
		return nil, "", err
	}
	return units, root, nil
}

// runTidy builds the native targets, recovers their compile commands from
// Bazel and runs clang-tidy with the repository configuration over every
// first-party translation unit.
func runTidy(repository string, runner commandRunner, bazelArguments []string) error {
	clangTidy, err := runner.LookPath("clang-tidy")
	if err != nil {
		return errors.New("required tool \"clang-tidy\" was not found; install LLVM's clang-tidy and run doctor again")
	}
	jobs, err := tidyJobs(os.Getenv("VXS_TIDY_JOBS"), runtime.NumCPU())
	if err != nil {
		return err
	}
	units, root, err := compiledUnits(repository, runner, bazelArguments)
	if err != nil {
		return err
	}
	database, err := os.MkdirTemp("", "vxs-tidy-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(database)
	encoded, err := json.Marshal(units)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(database, "compile_commands.json"), encoded, 0o600); err != nil {
		return err
	}
	configuration := filepath.Join(repository, ".clang-tidy")
	fmt.Printf("Analyzing %d first-party translation units with %d clang-tidy processes...\n", len(units), jobs)
	outcomes := runTidyUnits(units, jobs, func(unit tidyUnit) (string, error) {
		// Sources are addressed relative to the execution root, where the
		// include paths of the recorded command resolve.
		arguments := []string{"-p", database, "--config-file=" + configuration, "--quiet", "--use-color=false"}
		if override := tidyCheckOverride(unit.File); override != "" {
			arguments = append(arguments, "--checks="+override)
		}
		return runner.OutputIn(root, clangTidy, append(arguments, unit.File)...)
	})
	return reportTidyOutcomes(outcomes, root)
}
