// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

//go:build windows

package development

import (
	"os/exec"
	"strconv"
	"strings"
)

// processAlive reports whether a process with this identifier still exists.
// os.FindProcess always succeeds on Windows, so query the process table.
func processAlive(pid int) bool {
	output, err := exec.Command("tasklist", "/NH", "/FI", "PID eq "+strconv.Itoa(pid)).Output()
	return err == nil && strings.Contains(string(output), " "+strconv.Itoa(pid)+" ")
}
