// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package console

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pterm/pterm"
)

func environment(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestDetectModeHonoursTheOverrideAndTheCI(t *testing.T) {
	cases := []struct {
		values map[string]string
		want   Mode
	}{
		{map[string]string{OutputVariable: "rich"}, Rich},
		{map[string]string{OutputVariable: "PLAIN", "GITHUB_ACTIONS": "true"}, Plain},
		{map[string]string{OutputVariable: "actions"}, Actions},
		{map[string]string{"GITHUB_ACTIONS": "true", "CI": "true"}, Actions},
		{map[string]string{"CI": "true"}, Plain},
		{map[string]string{"TERM": "dumb"}, Plain},
		{map[string]string{}, Plain},
	}
	for _, test := range cases {
		if got := DetectMode(environment(test.values), nil); got != test.want {
			t.Errorf("DetectMode(%v) = %v, want %v", test.values, got, test.want)
		}
	}
}

func TestDetectModeTreatsAFileAsNoTerminal(t *testing.T) {
	file, err := os.Create(filepath.Join(t.TempDir(), "output"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if got := DetectMode(environment(nil), file); got != Plain {
		t.Fatalf("a file is %v, want Plain", got)
	}
}

func fixedClock() func() time.Time {
	now := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	return func() time.Time {
		now = now.Add(1500 * time.Millisecond)
		return now
	}
}

func TestPlainStepStreamsTheOutputBetweenStepLines(t *testing.T) {
	var out, errOut bytes.Buffer
	console := NewWith(Plain, &out, &errOut)
	console.now = fixedClock()
	err := console.Step("bazel build //...", func(stdout, stderr io.Writer) error {
		fmt.Fprintln(stdout, "INFO: Build completed successfully")
		fmt.Fprintln(stderr, "WARNING: option changed")
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if out.String() != "INFO: Build completed successfully\n" {
		t.Fatalf("stdout = %q", out.String())
	}
	want := "==> bazel build //...\nWARNING: option changed\n==> bazel build //... finished in 1.5s (1 warning)\n"
	if errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", errOut.String(), want)
	}
}

func TestPlainStepReportsAFailure(t *testing.T) {
	var out, errOut bytes.Buffer
	console := NewWith(Plain, &out, &errOut)
	console.now = fixedClock()
	failure := errors.New("exit status 1")
	if err := console.Step("cabal build", func(io.Writer, io.Writer) error { return failure }); err != failure {
		t.Fatalf("Step returned %v, want the work's error", err)
	}
	if !strings.Contains(errOut.String(), "==> cabal build failed after 1.5s: exit status 1") {
		t.Fatalf("stderr = %q", errOut.String())
	}
}

func TestActionsStepGroupsTheOutputAndRepeatsTheTailOfAFailure(t *testing.T) {
	var out, errOut bytes.Buffer
	console := NewWith(Actions, &out, &errOut)
	console.now = fixedClock()
	_ = console.Step("talac a,b: c", func(stdout, stderr io.Writer) error {
		fmt.Fprintln(stdout, "/opt/llvm")
		for line := range 50 {
			fmt.Fprintf(stderr, "line %d\n", line)
		}
		return errors.New("exit status 2\nsecond line")
	})
	// A workflow may capture standard output, as `develop llvm >> $GITHUB_ENV`
	// does, so it holds what the program printed there and nothing else.
	if out.String() != "/opt/llvm\n" {
		t.Fatalf("stdout = %q", out.String())
	}
	text := errOut.String()
	for _, want := range []string{
		"::group::talac a,b: c\n",
		"line 0\n",
		"::endgroup::\n",
		"::error title=talac a%2Cb%3A c failed::exit status 2%0Asecond line\n",
		"last 40 lines of talac a,b: c:\n  line 10\n",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("output lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "  line 9\n") {
		t.Errorf("the tail is longer than %d lines", tailLines)
	}
}

func TestRichStepKeepsTheOutputInALogAndShowsItsTailOnFailure(t *testing.T) {
	pterm.DisableColor()
	defer pterm.EnableColor()
	var errOut bytes.Buffer
	console := NewWith(Rich, io.Discard, &errOut)
	console.logRoot = t.TempDir()
	console.now = fixedClock()
	err := console.Step("bazel test //Talac:all", func(stdout, stderr io.Writer) error {
		if stdout != stderr {
			t.Error("a rich step gives a program one writer for both streams")
		}
		fmt.Fprint(stdout, "compiling\x1b[1m a\x1b[0m\nFAILED: //Talac:core_test\n")
		return errors.New("exit status 3")
	})
	if err == nil {
		t.Fatal("the failure was lost")
	}
	text := errOut.String()
	for _, want := range []string{"failed after 1.5s: exit status 3", "┌ last 2 lines of bazel test //Talac:all", "│ compiling a", "│ FAILED: //Talac:core_test", "└ whole output: "} {
		if !strings.Contains(text, want) {
			t.Errorf("output lacks %q:\n%s", want, text)
		}
	}
	logs, _ := filepath.Glob(filepath.Join(console.logRoot, "*", "01-bazel.log"))
	if len(logs) != 1 {
		t.Fatalf("log files = %v", logs)
	}
	saved, _ := os.ReadFile(logs[0])
	if !strings.Contains(string(saved), "\x1b[1m a") {
		t.Fatalf("the log is not the program's own output: %q", saved)
	}
}

func TestRichStepSucceedsQuietly(t *testing.T) {
	pterm.DisableColor()
	defer pterm.EnableColor()
	var errOut bytes.Buffer
	console := NewWith(Rich, io.Discard, &errOut)
	console.logRoot = t.TempDir()
	console.now = fixedClock()
	if err := console.Step("git fetch", func(stdout, _ io.Writer) error {
		fmt.Fprintln(stdout, "noise")
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if text := errOut.String(); !strings.Contains(text, "git fetch 1.5s") || strings.Contains(text, "noise\n") {
		t.Fatalf("output = %q", text)
	}
}

func TestStepShowingOutputRepeatsTheOutputAfterSuccess(t *testing.T) {
	pterm.DisableColor()
	defer pterm.EnableColor()
	var errOut bytes.Buffer
	console := NewWith(Rich, io.Discard, &errOut)
	console.logRoot = t.TempDir()
	console.now = fixedClock()
	if err := console.StepShowingOutput("git commit --file=-", func(stdout, _ io.Writer) error {
		fmt.Fprintln(stdout, "[topic 1234abc] Add a step")
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(errOut.String(), "  [topic 1234abc] Add a step\n") {
		t.Fatalf("output = %q", errOut.String())
	}
}

func TestLiveStepLeavesTheOutputToTheProgram(t *testing.T) {
	pterm.DisableColor()
	defer pterm.EnableColor()
	var out, errOut bytes.Buffer
	console := NewWith(Rich, &out, &errOut)
	console.now = fixedClock()
	if err := console.Live("winget install Git.Git", func(stdout, stderr io.Writer) error {
		fmt.Fprintln(stdout, "Do you agree to all the source agreements terms?")
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if out.String() != "Do you agree to all the source agreements terms?\n" {
		t.Fatalf("stdout = %q", out.String())
	}
	if text := errOut.String(); !strings.Contains(text, "▶ winget install Git.Git") || !strings.Contains(text, "winget install Git.Git 1.5s") {
		t.Fatalf("stderr = %q", text)
	}
}

func TestSummaryListsTheStepsOnceThereAreTwo(t *testing.T) {
	var errOut bytes.Buffer
	console := NewWith(Plain, io.Discard, &errOut)
	console.now = fixedClock()
	_ = console.Step("first", func(io.Writer, io.Writer) error { return nil })
	console.Summary()
	if strings.Contains(errOut.String(), "Step") {
		t.Fatal("one step has no summary")
	}
	_ = console.Step("second", func(io.Writer, io.Writer) error { return errors.New("no") })
	summaryFile := filepath.Join(t.TempDir(), "summary.md")
	console.summaryFile = summaryFile
	console.Summary()
	if !strings.Contains(errOut.String(), "Step    Result  Time\nfirst   ok      1.5s\nsecond  failed  1.5s\n") {
		t.Fatalf("summary = %q", errOut.String())
	}
	saved, _ := os.ReadFile(summaryFile)
	if !strings.Contains(string(saved), "| `second` | failed | 1.5s |") {
		t.Fatalf("job summary = %q", saved)
	}
}

func TestTranscriptKeepsTheLatestLineAndCountsWarnings(t *testing.T) {
	output := newTranscript(nil)
	fmt.Fprint(output, "a.cpp:1:2: warning: unused\r\nWARNING: changed\n[3 / 9] Compiling b")
	if output.latest() != "[3 / 9] Compiling b" {
		t.Fatalf("latest = %q", output.latest())
	}
	if output.warnings() != 2 {
		t.Fatalf("warnings = %d", output.warnings())
	}
	if tail := output.tail(); len(tail) != 3 || tail[2] != "[3 / 9] Compiling b" {
		t.Fatalf("tail = %q", tail)
	}
}

func TestDescribeKeepsWhatNamesTheStep(t *testing.T) {
	cases := map[string][]string{
		"bazel build --config=fuzz //Talac/Fuzzing:wire_fuzz_smoke": {"build", "--disk_cache=" + filepath.Join(t.TempDir(), "cache"), "--experimental_disk_cache_gc_max_size=10G", "--config=fuzz", "//Talac/Fuzzing:wire_fuzz_smoke"},
		"tar --zstd -xf llvm.tar.zst -C work":                       {"--zstd", "-xf", filepath.Join(t.TempDir(), "llvm.tar.zst"), "-C", filepath.Join(t.TempDir(), "work")},
		"git a b c d e …":                                           {"a", "b", "c", "d", "e", "f"},
	}
	for want, arguments := range cases {
		name := "git"
		switch {
		case strings.HasPrefix(want, "bazel"):
			name = filepath.Join("C:", "tools", "bazel.exe")
		case strings.HasPrefix(want, "tar"):
			name = "tar"
		}
		if got := Describe(name, arguments); got != want {
			t.Errorf("Describe = %q, want %q", got, want)
		}
	}
}

func TestPruneLogsRemovesOnlyOldRuns(t *testing.T) {
	root := t.TempDir()
	old, recent := filepath.Join(root, "old"), filepath.Join(root, "recent")
	for _, directory := range []string{old, recent} {
		if err := os.Mkdir(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	past := time.Now().Add(-30 * 24 * time.Hour)
	if err := os.Chtimes(old, past, past); err != nil {
		t.Fatal(err)
	}
	pruneLogs(root, time.Now().Add(-7*24*time.Hour))
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Error("an old run was kept")
	}
	if _, err := os.Stat(recent); err != nil {
		t.Error("a recent run was removed")
	}
}

func TestTruncateCountsRunes(t *testing.T) {
	if got := truncate("ğüşıöç-abc", 5); got != "ğüşı…" {
		t.Fatalf("truncate = %q", got)
	}
	if got := truncate("short", 10); got != "short" {
		t.Fatalf("truncate = %q", got)
	}
}
