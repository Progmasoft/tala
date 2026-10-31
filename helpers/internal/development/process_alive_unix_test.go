// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

//go:build !windows

package development

import (
	"os"
	"strconv"
	"strings"
	"syscall"
)

// processAlive reports whether a process with this identifier still executes.
// A killed orphan stays in the process table as a zombie until its new parent
// reaps it, and a container's first process may never do so; signal 0 still
// succeeds for such an entry. Where procfs is available, a zombie or dead
// state therefore counts as terminated.
func processAlive(pid int) bool {
	if syscall.Kill(pid, 0) != nil {
		return false
	}
	status, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return true
	}
	// The command name is parenthesized and may itself contain spaces or
	// parentheses; the state letter follows the last closing parenthesis.
	_, rest, found := strings.Cut(string(status[strings.LastIndexByte(string(status), ')')+1:]), " ")
	if !found || rest == "" {
		return true
	}
	return rest[0] != 'Z' && rest[0] != 'X'
}
