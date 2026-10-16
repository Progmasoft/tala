// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// Package console presents the programs the helpers start to a developer.
//
// In a terminal each program is one step: a spinner names it and shows its
// latest line, its whole output goes to a log file, and a failure prints the
// last lines together with the path of that file. Without a terminal the
// output streams as it always did, framed by plain step lines, and on GitHub
// Actions every step is a collapsible log group.
package console

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/pterm/pterm"
	"golang.org/x/term"
)

// Mode is how a Console presents its steps.
type Mode int

const (
	// Plain streams program output with plain step lines around it.
	Plain Mode = iota
	// Actions streams program output inside GitHub Actions log groups.
	Actions
	// Rich draws a spinner per step and keeps the output in log files.
	Rich
)

// OutputVariable overrides the detected mode: "rich", "plain" or "actions".
const OutputVariable = "TALA_HELPERS_OUTPUT"

// tailLines is how much of a failed step's output is printed again.
const tailLines = 40

// Console presents steps and messages on one pair of streams.
type Console struct {
	mode        Mode
	out         io.Writer
	err         io.Writer
	logRoot     string
	session     string
	summaryFile string
	now         func() time.Time

	mu    sync.Mutex
	steps []record
}

type record struct {
	title    string
	duration time.Duration
	failed   bool
	warnings int
	log      string
}

// New returns the Console for the host process streams.
func New() *Console {
	return NewWith(DetectMode(os.Getenv, os.Stderr), os.Stdout, os.Stderr)
}

// NewWith returns a Console of the given mode on the given streams.
func NewWith(mode Mode, out, err io.Writer) *Console {
	console := &Console{mode: mode, out: out, err: err, now: time.Now}
	if mode == Actions {
		console.summaryFile = os.Getenv("GITHUB_STEP_SUMMARY")
	}
	if mode == Rich {
		console.logRoot = logRoot()
	}
	return console
}

// DetectMode chooses the mode from the environment and from whether stream is
// a terminal that understands escape sequences.
func DetectMode(getenv func(string) string, stream *os.File) Mode {
	switch strings.ToLower(getenv(OutputVariable)) {
	case "rich":
		return Rich
	case "plain":
		return Plain
	case "actions":
		return Actions
	}
	if getenv("GITHUB_ACTIONS") == "true" {
		return Actions
	}
	if getenv("CI") != "" || getenv("TERM") == "dumb" || stream == nil {
		return Plain
	}
	if !term.IsTerminal(int(stream.Fd())) || !enableEscapes(stream) {
		return Plain
	}
	return Rich
}

// Mode reports how the Console presents its steps.
func (c *Console) Mode() Mode {
	return c.mode
}

// Section starts a group of related steps.
func (c *Console) Section(title string) {
	switch c.mode {
	case Rich:
		pterm.DefaultSection.WithWriter(c.err).Println(title)
	default:
		fmt.Fprintf(c.err, "\n== %s ==\n", title)
	}
}

// Info, Success, Warning and Failure print one message.
func (c *Console) Info(format string, arguments ...any) {
	c.message(pterm.Info, "info", format, arguments...)
}

// Success prints a message about work that is done.
func (c *Console) Success(format string, arguments ...any) {
	c.message(pterm.Success, "ok", format, arguments...)
}

// Warning prints a message about something that did not stop the work.
func (c *Console) Warning(format string, arguments ...any) {
	c.message(pterm.Warning, "warning", format, arguments...)
}

// Failure prints a message about work that stopped.
func (c *Console) Failure(format string, arguments ...any) {
	c.message(pterm.Error, "error", format, arguments...)
}

func (c *Console) message(printer pterm.PrefixPrinter, label, format string, arguments ...any) {
	text := fmt.Sprintf(format, arguments...)
	if c.mode == Rich {
		printer.WithWriter(c.err).Println(text)
		return
	}
	fmt.Fprintf(c.err, "%s: %s\n", label, text)
}

// Table prints rows under a header.
func (c *Console) Table(header []string, rows [][]string) {
	if c.mode == Rich {
		data := append(pterm.TableData{header}, rows...)
		_ = pterm.DefaultTable.WithHasHeader().WithBoxed().WithWriter(c.err).WithData(data).Render()
		return
	}
	widths := make([]int, len(header))
	for _, row := range append([][]string{header}, rows...) {
		for column, cell := range row {
			if column < len(widths) {
				widths[column] = max(widths[column], len([]rune(cell)))
			}
		}
	}
	for _, row := range append([][]string{header}, rows...) {
		cells := make([]string, len(row))
		for column, cell := range row {
			cells[column] = cell
			if column < len(row)-1 && column < len(widths) {
				cells[column] += strings.Repeat(" ", widths[column]-len([]rune(cell)))
			}
		}
		fmt.Fprintln(c.err, strings.Join(cells, "  "))
	}
}

// Summary prints a table of the steps once more than one step ran, and on
// GitHub Actions adds it to the job summary.
func (c *Console) Summary() {
	c.mu.Lock()
	steps := append([]record(nil), c.steps...)
	c.mu.Unlock()
	if len(steps) < 2 {
		return
	}
	rows := make([][]string, 0, len(steps))
	for _, step := range steps {
		rows = append(rows, []string{step.title, result(step), Duration(step.duration)})
	}
	fmt.Fprintln(c.err)
	c.Table([]string{"Step", "Result", "Time"}, rows)
	if c.summaryFile != "" {
		c.writeJobSummary(rows)
	}
}

func result(step record) string {
	switch {
	case step.failed:
		return "failed"
	case step.warnings == 1:
		return "ok, 1 warning"
	case step.warnings > 1:
		return fmt.Sprintf("ok, %d warnings", step.warnings)
	}
	return "ok"
}

func (c *Console) writeJobSummary(rows [][]string) {
	file, err := os.OpenFile(c.summaryFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer file.Close()
	var text strings.Builder
	text.WriteString("\n| Step | Result | Time |\n| --- | --- | --- |\n")
	for _, row := range rows {
		cells := make([]string, len(row))
		for index, cell := range row {
			cells[index] = strings.ReplaceAll(cell, "|", `\|`)
		}
		fmt.Fprintf(&text, "| `%s` | %s | %s |\n", cells[0], cells[1], cells[2])
	}
	_, _ = file.WriteString(text.String())
}

// Duration formats a step's time the way the step lines print it.
func Duration(duration time.Duration) string {
	if duration < time.Minute {
		return fmt.Sprintf("%.1fs", duration.Seconds())
	}
	return duration.Round(time.Second).String()
}

// logRoot is the folder of this process's log files. Folders of earlier runs
// that are more than a week old are removed so the cache does not grow.
func logRoot() string {
	base, err := os.UserCacheDir()
	if err != nil || base == "" {
		base = os.TempDir()
	}
	root := filepath.Join(base, "tala", "helper-logs")
	pruneLogs(root, time.Now().Add(-7*24*time.Hour))
	return root
}

func pruneLogs(root string, before time.Time) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, entry := range entries {
		info, err := entry.Info()
		if err == nil && entry.IsDir() && info.ModTime().Before(before) {
			_ = os.RemoveAll(filepath.Join(root, entry.Name()))
		}
	}
}
