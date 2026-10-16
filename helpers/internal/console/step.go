// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package console

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/pterm/pterm"
)

// Step runs work as one step named title. work writes the program's output to
// the two writers it is given; in a terminal they are the same writer.
func (c *Console) Step(title string, work func(stdout, stderr io.Writer) error) error {
	switch c.mode {
	case Rich:
		return c.richStep(title, work, false)
	case Actions:
		return c.actionsStep(title, work)
	}
	return c.plainStep(title, work)
}

// StepShowingOutput runs work like Step and, in a terminal, prints the
// program's last lines after it succeeds as well: what Git says about a commit
// or a push is the answer, not noise.
func (c *Console) StepShowingOutput(title string, work func(stdout, stderr io.Writer) error) error {
	if c.mode != Rich {
		return c.Step(title, work)
	}
	return c.richStep(title, work, true)
}

// Live runs work as one step whose program talks to the developer itself: a
// package manager that may ask for a password, or a program that draws its
// own progress. Its output goes straight to the streams in every mode, and
// only the lines around it are drawn.
func (c *Console) Live(title string, work func(stdout, stderr io.Writer) error) error {
	switch c.mode {
	case Plain:
		return c.plainStep(title, work)
	case Actions:
		return c.actionsStep(title, work)
	}
	fmt.Fprintln(c.err, pterm.Cyan("▶ ")+pterm.Bold.Sprint(title))
	output := newTranscript(nil)
	started := c.now()
	err := work(io.MultiWriter(c.out, output), io.MultiWriter(c.err, output))
	duration := c.now().Sub(started)
	c.remember(title, duration, err, output, "")
	if err != nil {
		pterm.Error.WithWriter(c.err).Printfln("%s failed after %s: %v", title, Duration(duration), err)
		return err
	}
	pterm.Success.WithWriter(c.err).Printfln("%s %s%s", title, pterm.Gray(Duration(duration)), warningNote(output.warnings()))
	return nil
}

func (c *Console) plainStep(title string, work func(stdout, stderr io.Writer) error) error {
	fmt.Fprintf(c.err, "==> %s\n", title)
	output := newTranscript(nil)
	started := c.now()
	err := work(io.MultiWriter(c.out, output), io.MultiWriter(c.err, output))
	duration := c.now().Sub(started)
	c.remember(title, duration, err, output, "")
	if err != nil {
		fmt.Fprintf(c.err, "==> %s failed after %s: %v\n", title, Duration(duration), err)
		return err
	}
	fmt.Fprintf(c.err, "==> %s finished in %s%s\n", title, Duration(duration), warningNote(output.warnings()))
	return nil
}

func (c *Console) actionsStep(title string, work func(stdout, stderr io.Writer) error) error {
	fmt.Fprintf(c.err, "::group::%s\n", escapeData(title))
	output := newTranscript(nil)
	started := c.now()
	err := work(io.MultiWriter(c.out, output), io.MultiWriter(c.err, output))
	duration := c.now().Sub(started)
	fmt.Fprintln(c.err, "::endgroup::")
	c.remember(title, duration, err, output, "")
	if err != nil {
		fmt.Fprintf(c.err, "::error title=%s::%s\n", escapeProperty(title+" failed"), escapeData(err.Error()))
		c.printTail(c.err, title, output.tail(), "")
		return err
	}
	fmt.Fprintf(c.err, "%s finished in %s%s\n", title, Duration(duration), warningNote(output.warnings()))
	return nil
}

func (c *Console) richStep(title string, work func(stdout, stderr io.Writer) error, showOutput bool) error {
	logPath, logFile := c.openLog(title)
	if logFile != nil {
		defer logFile.Close()
	}
	output := newTranscript(logFile)
	spinner, _ := pterm.DefaultSpinner.WithWriter(c.err).WithText(title).Start()
	done := make(chan struct{})
	var follow sync.WaitGroup
	follow.Go(func() { followLatest(spinner, title, output, done) })

	started := c.now()
	err := work(output, output)
	duration := c.now().Sub(started)
	close(done)
	follow.Wait()
	c.remember(title, duration, err, output, logPath)

	if err != nil {
		spinner.Fail(fmt.Sprintf("%s failed after %s: %v", title, Duration(duration), err))
		c.printTail(c.err, title, output.tail(), logPath)
		return err
	}
	note := warningNote(output.warnings())
	spinner.Success(fmt.Sprintf("%s %s%s", title, pterm.Gray(Duration(duration)), note))
	if showOutput {
		for _, line := range output.tail() {
			fmt.Fprintln(c.err, "  "+pterm.Gray(line))
		}
	}
	if note != "" && logPath != "" {
		fmt.Fprintf(c.err, "  %s\n", pterm.Gray("output: "+logPath))
	}
	return nil
}

// followLatest shows the latest line of output beside the title, a few times
// a second rather than once a line, so a chatty program does not flood the
// terminal with redraws.
func followLatest(spinner *pterm.SpinnerPrinter, title string, output *transcript, done <-chan struct{}) {
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	shown := ""
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
			latest := output.latest()
			if latest == shown {
				continue
			}
			shown = latest
			// The spinner and its timer take about a dozen columns.
			room := pterm.GetTerminalWidth() - 16 - len([]rune(title)) - 3
			text := truncate(title, pterm.GetTerminalWidth()-16)
			if latest != "" && room >= 10 {
				text += pterm.Gray(" · " + truncate(latest, room))
			}
			spinner.UpdateText(text)
		}
	}
}

func (c *Console) printTail(writer io.Writer, title string, lines []string, logPath string) {
	if len(lines) == 0 {
		return
	}
	heading := fmt.Sprintf("last %d lines of %s", len(lines), title)
	if c.mode == Rich {
		fmt.Fprintln(writer, pterm.Red("┌ "+heading))
		for _, line := range lines {
			fmt.Fprintln(writer, pterm.Red("│ ")+line)
		}
		footer := "└"
		if logPath != "" {
			footer += " whole output: " + logPath
		}
		fmt.Fprintln(writer, pterm.Red(footer))
		return
	}
	fmt.Fprintf(writer, "%s:\n", heading)
	for _, line := range lines {
		fmt.Fprintf(writer, "  %s\n", line)
	}
}

func (c *Console) remember(title string, duration time.Duration, err error, output *transcript, logPath string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.steps = append(c.steps, record{title: title, duration: duration, failed: err != nil, warnings: output.warnings(), log: logPath})
}

// openLog creates the log file of the next step. Without one the step still
// runs; only the tail of its output is kept.
func (c *Console) openLog(title string) (string, *os.File) {
	c.mu.Lock()
	if c.session == "" {
		c.session = filepath.Join(c.logRoot, fmt.Sprintf("%s-%d", c.now().Format("20060102-150405"), os.Getpid()))
	}
	number := len(c.steps) + 1
	session := c.session
	c.mu.Unlock()
	if c.logRoot == "" || os.MkdirAll(session, 0o755) != nil {
		return "", nil
	}
	name := strings.Fields(title)
	tool := "step"
	if len(name) > 0 {
		tool = unsafeName.ReplaceAllString(name[0], "_")
	}
	path := filepath.Join(session, fmt.Sprintf("%02d-%s.log", number, tool))
	file, err := os.Create(path)
	if err != nil {
		return "", nil
	}
	return path, file
}

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9._-]`)

func warningNote(count int) string {
	switch {
	case count == 1:
		return " (1 warning)"
	case count > 1:
		return fmt.Sprintf(" (%d warnings)", count)
	}
	return ""
}

// truncate shortens text to width columns, counting a rune as one column.
func truncate(text string, width int) string {
	runes := []rune(text)
	if width < 1 || len(runes) <= width {
		return text
	}
	return string(runes[:width-1]) + "…"
}

// escapeData and escapeProperty encode text for a GitHub Actions workflow
// command, so that a title or a message cannot end the command early.
func escapeData(text string) string {
	return strings.NewReplacer("%", "%25", "\r", "%0D", "\n", "%0A").Replace(text)
}

func escapeProperty(text string) string {
	return strings.NewReplacer("%", "%25", "\r", "%0D", "\n", "%0A", ":", "%3A", ",", "%2C").Replace(text)
}
