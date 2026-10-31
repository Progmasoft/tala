// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const watchdogRole = "TALA_WATCHDOG_TEST_ROLE"

// TestMain lets the test binary stand in for a hung fuzz program: the parent
// role starts a child that never exits and then blocks, like a smoke program
// stuck in a non-terminating generated loop with a helper process below it.
func TestMain(m *testing.M) {
	switch os.Getenv(watchdogRole) {
	case "parent":
		child := exec.Command(os.Args[0])
		child.Env = append(os.Environ(), watchdogRole+"=child")
		child.Stdout, child.Stderr = os.Stdout, os.Stderr
		if err := child.Start(); err != nil {
			os.Exit(3)
		}
		if err := os.WriteFile(os.Getenv("TALA_WATCHDOG_TEST_PID"), []byte(strconv.Itoa(child.Process.Pid)), 0o600); err != nil {
			os.Exit(4)
		}
		time.Sleep(10 * time.Minute)
		os.Exit(5)
	case "child":
		time.Sleep(10 * time.Minute)
		os.Exit(6)
	}
	os.Exit(m.Run())
}

func TestWatchdogTerminatesTheWholeProcessTree(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	t.Setenv(watchdogRole, "parent")
	t.Setenv("TALA_WATCHDOG_TEST_PID", pidFile)
	command, finish := watchedCommandWithin(3, os.Args[0], nil)
	started := time.Now()
	output, runErr := command.CombinedOutput()
	err := finish(runErr)
	elapsed := time.Since(started)
	if err == nil || !strings.Contains(err.Error(), "exceeded its 3-second process watchdog") {
		t.Fatalf("hung program was not reported as a watchdog failure: %v\n%s", err, output)
	}
	// The deadline plus the pipe grace period bounds the wait; without tree
	// termination the grandchild keeps the output pipe open for minutes.
	if elapsed > 3*time.Second+watchdogGrace+5*time.Second {
		t.Fatalf("watchdog returned only after %s", elapsed)
	}
	text, readErr := os.ReadFile(pidFile)
	if readErr != nil {
		t.Fatalf("parent never started its child: %v", readErr)
	}
	pid, convErr := strconv.Atoi(string(text))
	if convErr != nil {
		t.Fatal(convErr)
	}
	deadline := time.Now().Add(10 * time.Second)
	for processAlive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("descendant %d survived the watchdog", pid)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestWatchdogLeavesCompletedAndUnboundedCommandsAlone(t *testing.T) {
	t.Setenv(watchdogRole, "")
	for _, seconds := range []int{0, 60} {
		command, finish := watchedCommandWithin(seconds, os.Args[0], []string{"-test.run=^$"})
		if err := finish(command.Run()); err != nil {
			t.Fatalf("completed command reported a failure under a %d-second bound: %v", seconds, err)
		}
	}
	// An ordinary failure inside the budget keeps its own error text.
	command, finish := watchedCommandWithin(60, os.Args[0], []string{"-test.unknown-flag"})
	err := finish(command.Run())
	if err == nil || strings.Contains(err.Error(), "watchdog") {
		t.Fatalf("ordinary failure was misreported: %v", err)
	}
}
