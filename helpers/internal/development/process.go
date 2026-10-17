// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"context"
	"fmt"
	"github.com/Progmasoft/tala/helpers/internal/console"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type commandRunner interface {
	Run(directory string, environment []string, name string, arguments ...string) error
	RunWithInput(directory string, environment []string, input string, name string, arguments ...string) (string, error)
	Output(name string, arguments ...string) (string, error)
	OutputIn(directory string, name string, arguments ...string) (string, error)
	LookPath(name string) (string, error)
}

type systemRunner struct {
	stdout io.Writer
	stderr io.Writer
	// console presents each program as a step; without one the program's
	// output goes straight to stdout and stderr.
	console *console.Console
}

func (runner systemRunner) Run(directory string, environment []string, name string, arguments ...string) error {
	if runner.console == nil {
		return runProgram(directory, environment, runner.stdout, runner.stderr, name, arguments)
	}
	return runner.console.Step(console.Describe(name, arguments), func(stdout, stderr io.Writer) error {
		return runProgram(directory, environment, stdout, stderr, name, arguments)
	})
}

func runProgram(directory string, environment []string, stdout, stderr io.Writer, name string, arguments []string) error {
	command, finish := watchedCommand(name, arguments)
	defer finish(nil)
	command.Dir = directory
	command.Env = mergedEnvironment(environment)
	command.Stdin = os.Stdin
	command.Stdout = stdout
	command.Stderr = stderr
	return finish(command.Run())
}

// RunWithInput drives programs with deterministic stdin while keeping captured
// output available to the caller for smoke-test assertions.
func (runner systemRunner) RunWithInput(directory string, environment []string, input string, name string, arguments ...string) (string, error) {
	command, finish := watchedCommand(name, arguments)
	defer finish(nil)
	command.Dir = directory
	command.Env = mergedEnvironment(environment)
	command.Stdin = strings.NewReader(input)
	output, err := command.CombinedOutput()
	return string(output), finish(err)
}

// watchdogGrace bounds how long a cancelled program may hold its output pipes
// open after its process tree was terminated.
const watchdogGrace = 10 * time.Second

// watchedCommand bounds fuzz and smoke programs. libFuzzer's -timeout covers one
// input, but a deterministic smoke program or an HPC campaign has no in-process
// watchdog, and a miscompiled generated loop never returns. The deadline
// terminates the whole process tree rather than only the direct child, and the
// returned finish function reports expiry as a watchdog failure instead of the
// host's generic kill status. Build tools are not bounded here; they keep their
// CI job timeout.
func watchedCommand(name string, arguments []string) (*exec.Cmd, func(error) error) {
	return watchedCommandWithin(fuzzProcessSeconds(name, arguments), name, arguments)
}

func watchedCommandWithin(seconds int, name string, arguments []string) (*exec.Cmd, func(error) error) {
	if seconds == 0 {
		return exec.Command(name, arguments...), func(err error) error { return err }
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(seconds)*time.Second)
	command := exec.CommandContext(ctx, name, arguments...)
	prepareProcessTree(command)
	command.Cancel = func() error { return terminateProcessTree(command) }
	command.WaitDelay = watchdogGrace
	return command, func(err error) error {
		expired := ctx.Err() == context.DeadlineExceeded
		cancel()
		if err != nil && expired {
			return fmt.Errorf("%s exceeded its %d-second process watchdog and its process tree was terminated: %w", filepath.Base(name), seconds, err)
		}
		return err
	}
}

// smokeProcessSeconds bounds a deterministic smoke program. The bound exists to
// end a run that will never finish, not to measure speed, so it must stay well
// clear of the slowest legitimate run. source_fuzz_smoke takes 3 to 7 seconds in
// an ordinary build and about 78 seconds under AddressSanitizer and
// UndefinedBehaviorSanitizer on a hosted Windows runner. The former bound of 90
// seconds left that run 12 seconds of headroom, and a slower machine exceeded it
// with every case passing. The execution tables are a program of their own,
// source_execution_smoke: with them, source_fuzz_smoke ran 221 seconds in the
// fuzzing configuration on a developer machine. Apart, each ran 77 to 110
// seconds there, so the bound did not have to grow with the tables. The tables
// of single features are source_feature_smoke for the same reason, and so are
// the expression and leaving tables, source_expression_smoke: once arguments
// were passed by need, the programs of the three tables together ran 344
// seconds under the sanitizers there.
const smokeProcessSeconds = 240

func fuzzProcessSeconds(name string, arguments []string) int {
	binary := strings.TrimSuffix(filepath.Base(name), ".exe")
	if binary == "source_fuzz_smoke" || binary == "source_execution_smoke" || binary == "source_expression_smoke" || binary == "source_feature_smoke" || binary == "source_console_smoke" || binary == "wire_fuzz_smoke" {
		return smokeProcessSeconds
	}
	if binary == "frontend-fuzz" && len(arguments) >= 2 {
		if seconds, err := strconv.Atoi(arguments[1]); err == nil && seconds >= 1 && seconds <= 3600 {
			return seconds + 300 // bounded corpus warmup and shutdown allowance
		}
	}
	if strings.HasSuffix(binary, "_fuzzer") {
		for _, argument := range arguments {
			if value, ok := strings.CutPrefix(argument, "-max_total_time="); ok {
				if seconds, err := strconv.Atoi(value); err == nil && seconds >= 1 && seconds <= 3600 {
					return seconds + 90 + corpusWarmupSeconds(arguments)
				}
			}
		}
	}
	return 0
}

// corpusWarmupSeconds is the part of a fuzzer's bound that grows with its
// corpus. libFuzzer executes every file of the corpus before it looks at
// -max_total_time, and the corpus is a cache that every campaign extends. With
// 1,059 files, source_llvm_fuzzer needed 178 seconds for a campaign of 90 on a
// hosted Windows runner, two seconds inside the former fixed bound, and the
// next run of the same sources was terminated at 180 with no failing input.
// Half a second for each file is three times what that run needed, so the
// bound still ends a process that never finishes.
func corpusWarmupSeconds(arguments []string) int {
	if len(arguments) == 0 || strings.HasPrefix(arguments[0], "-") {
		return 0
	}
	entries, err := os.ReadDir(arguments[0])
	if err != nil {
		return 0
	}
	return len(entries) / 2
}

// mergedEnvironment replaces inherited keys rather than appending duplicate
// PATH entries whose precedence differs between host process APIs.
func mergedEnvironment(overrides []string) []string {
	return mergeEnvironment(os.Environ(), overrides, runtime.GOOS == "windows")
}

func mergeEnvironment(base []string, overrides []string, windows bool) []string {
	environment := append([]string(nil), base...)
	for _, override := range overrides {
		key, _, found := strings.Cut(override, "=")
		if !found || key == "" {
			environment = append(environment, override)
			continue
		}
		filtered := environment[:0]
		for _, entry := range environment {
			entryKey, _, hasValue := strings.Cut(entry, "=")
			matches := hasValue && entryKey == key
			if windows {
				matches = hasValue && strings.EqualFold(entryKey, key)
			}
			if !matches {
				filtered = append(filtered, entry)
			}
		}
		environment = append(filtered, override)
	}
	return environment
}

func (runner systemRunner) Output(name string, arguments ...string) (string, error) {
	return runner.OutputIn("", name, arguments...)
}

func (runner systemRunner) OutputIn(directory string, name string, arguments ...string) (string, error) {
	command := exec.Command(name, arguments...)
	command.Dir = directory
	output, err := command.CombinedOutput()
	return strings.TrimSpace(string(output)), err
}

func (runner systemRunner) LookPath(name string) (string, error) {
	return exec.LookPath(name)
}
