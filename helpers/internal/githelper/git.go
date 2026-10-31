// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

// Package githelper implements the guarded Git workflow of the Tala
// repositories: stage safely, commit, push without rewriting history, and keep
// a topic branch current with the default branch. It passes arguments directly
// to Git and never builds a shell command.
package githelper

import (
	"bytes"
	"errors"
	"fmt"
	"github.com/Progmasoft/tala/helpers/internal/console"
	"io"
	"os/exec"
	"strings"
)

const remoteName = "origin"

// gitRunner is the only way the package reaches Git, so every workflow can be
// tested against a scripted repository.
type gitRunner interface {
	// Run executes Git with inherited output and returns its exit code. A
	// non-nil input replaces standard input; quiet discards standard output.
	Run(input []byte, quiet bool, arguments ...string) (int, error)
	// Capture executes Git and returns its standard output. A non-zero exit
	// is an error.
	Capture(arguments ...string) ([]byte, error)
}

type processRunner struct {
	stdin  io.Reader
	stdout io.Writer
	stderr io.Writer
	// console presents each Git command that is not quiet as a step; without
	// one the command is echoed and its output inherited.
	console *console.Console
}

// exitError carries the process exit code a failed workflow should end with.
type exitError struct {
	code    int
	message string
}

func (failure exitError) Error() string {
	return failure.message
}

func failf(format string, arguments ...any) error {
	return exitError{code: 1, message: "error: " + fmt.Sprintf(format, arguments...)}
}

func (runner processRunner) Run(input []byte, quiet bool, arguments ...string) (int, error) {
	if quiet || runner.console == nil {
		if !quiet {
			fmt.Fprintln(runner.stderr, "+ git "+strings.Join(arguments, " "))
		}
		stdout := runner.stdout
		if quiet {
			stdout = io.Discard
		}
		return runner.exitCode(runner.git(input, stdout, runner.stderr, arguments))
	}
	// The step shows a failure; the workflow still decides what it means.
	var err error
	_ = runner.console.StepShowingOutput("git "+strings.Join(arguments, " "), func(stdout, stderr io.Writer) error {
		err = runner.git(input, stdout, stderr, arguments)
		return err
	})
	return runner.exitCode(err)
}

func (runner processRunner) git(input []byte, stdout, stderr io.Writer, arguments []string) error {
	command := exec.Command("git", arguments...)
	if input != nil {
		command.Stdin = bytes.NewReader(input)
	} else {
		command.Stdin = runner.stdin
	}
	command.Stdout = stdout
	command.Stderr = stderr
	return command.Run()
}

func (runner processRunner) exitCode(err error) (int, error) {
	if err == nil {
		return 0, nil
	}
	var processFailure *exec.ExitError
	if errors.As(err, &processFailure) {
		return processFailure.ExitCode(), nil
	}
	return -1, err
}

func (runner processRunner) Capture(arguments ...string) ([]byte, error) {
	command := exec.Command("git", arguments...)
	command.Stderr = runner.stderr
	output, err := command.Output()
	if err != nil {
		var processFailure *exec.ExitError
		if errors.As(err, &processFailure) {
			return nil, fmt.Errorf("git %s failed with code %d", strings.Join(arguments, " "), processFailure.ExitCode())
		}
		return nil, err
	}
	return output, nil
}

// run executes a Git command that must succeed.
func run(runner gitRunner, failure string, arguments ...string) error {
	code, err := runner.Run(nil, false, arguments...)
	if err != nil {
		return err
	}
	if code != 0 {
		return exitError{code: code, message: "error: " + failure}
	}
	return nil
}

func captureLine(runner gitRunner, arguments ...string) (string, error) {
	output, err := runner.Capture(arguments...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

func requireWorkTree(runner gitRunner) error {
	inside, err := captureLine(runner, "rev-parse", "--is-inside-work-tree")
	if err != nil || inside != "true" {
		return failf("not inside a git work tree")
	}
	return nil
}

func currentBranch(runner gitRunner) (string, error) {
	branch, err := captureLine(runner, "branch", "--show-current")
	if err != nil {
		return "", err
	}
	if branch == "" {
		return "", failf("detached HEAD state; cannot determine the current branch")
	}
	return branch, nil
}

// defaultBranch names the branch the remote treats as its default. The remote
// HEAD reference is authoritative; a clone that never recorded it falls back
// to the conventional name that exists on the remote.
func defaultBranch(runner gitRunner) (string, error) {
	if reference, err := captureLine(runner, "symbolic-ref", "--quiet", "--short", "refs/remotes/"+remoteName+"/HEAD"); err == nil {
		if name, found := strings.CutPrefix(reference, remoteName+"/"); found && name != "" {
			return name, nil
		}
	}
	for _, candidate := range []string{"main", "master"} {
		if _, err := runner.Capture("rev-parse", "--verify", "--quiet", "refs/remotes/"+remoteName+"/"+candidate); err == nil {
			return candidate, nil
		}
	}
	return "", failf("cannot determine the default branch of %s; run git remote set-head %s --auto", remoteName, remoteName)
}

func workTreeStatus(runner gitRunner) (string, error) {
	status, err := runner.Capture("status", "--short")
	if err != nil {
		return "", err
	}
	return strings.TrimRight(string(status), "\r\n"), nil
}

func requireCleanWorkTree(runner gitRunner, action string) error {
	status, err := workTreeStatus(runner)
	if err != nil {
		return err
	}
	if status != "" {
		return failf("%s needs a clean work tree; commit or set aside these changes first:\n%s", action, status)
	}
	return nil
}

func splitNullSeparated(output []byte) []string {
	parts := bytes.Split(output, []byte{0})
	paths := make([]string, 0, len(parts))
	for _, part := range parts {
		if len(part) != 0 {
			paths = append(paths, string(part))
		}
	}
	return paths
}

func nullSeparated(paths []string) []byte {
	var output bytes.Buffer
	for _, path := range paths {
		output.WriteString(path)
		output.WriteByte(0)
	}
	return output.Bytes()
}
