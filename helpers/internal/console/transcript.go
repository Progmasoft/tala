// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package console

import (
	"bytes"
	"io"
	"regexp"
	"strings"
	"sync"
)

// transcript records a program's output: all of it to an optional file, and
// its last lines, its latest line and its warnings in memory. It may be the
// stdout and the stderr of one program at the same time.
type transcript struct {
	mu       sync.Mutex
	file     io.Writer
	partial  []byte
	lines    []string
	next     int
	full     bool
	current  string
	warned   int
	capacity int
}

func newTranscript(file io.Writer) *transcript {
	return &transcript{file: file, lines: make([]string, tailLines), capacity: tailLines}
}

func (t *transcript) Write(data []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.file != nil {
		// A log file that cannot be written must not fail the program.
		_, _ = t.file.Write(data)
	}
	t.partial = append(t.partial, data...)
	for {
		end := bytes.IndexAny(t.partial, "\r\n")
		if end < 0 {
			break
		}
		t.line(string(t.partial[:end]))
		t.partial = t.partial[end+1:]
	}
	if len(t.partial) > 0 {
		if latest := clean(string(t.partial)); latest != "" {
			t.current = latest
		}
	}
	return len(data), nil
}

func (t *transcript) line(text string) {
	text = clean(text)
	if text == "" {
		return
	}
	t.current = text
	t.lines[t.next] = text
	t.next = (t.next + 1) % t.capacity
	t.full = t.full || t.next == 0
	if warningLine.MatchString(text) {
		t.warned++
	}
}

// tail returns the last lines, including an unfinished one, oldest first.
func (t *transcript) tail() []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	var lines []string
	if t.full {
		lines = append(lines, t.lines[t.next:]...)
	}
	lines = append(lines, t.lines[:t.next]...)
	if rest := clean(string(t.partial)); rest != "" {
		lines = append(lines, rest)
		if len(lines) > t.capacity {
			lines = lines[1:]
		}
	}
	return lines
}

func (t *transcript) latest() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.current
}

func (t *transcript) warnings() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.warned
}

// warningLine matches the warnings of compilers ("file:1:2: warning: ...") and
// of Bazel ("WARNING: ...").
var warningLine = regexp.MustCompile(`(?i)(^|[\s:\]])warning:`)

var escape = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)

func stripEscapes(text string) string {
	return escape.ReplaceAllString(text, "")
}

// clean removes escape sequences and other control characters, which would
// move the cursor when the line is drawn beside a spinner.
func clean(text string) string {
	text = stripEscapes(text)
	text = strings.Map(func(character rune) rune {
		if character == '\t' {
			return ' '
		}
		if character < ' ' || character == 0x7f {
			return -1
		}
		return character
	}, text)
	return strings.TrimSpace(text)
}
