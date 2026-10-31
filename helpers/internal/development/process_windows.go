// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

//go:build windows

package development

import (
	"os"
	"os/exec"
	"strconv"
	"syscall"
)

// prepareProcessTree detaches the child from the helper's console control
// group so terminating it cannot deliver a console event to the helper itself.
func prepareProcessTree(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

// terminateProcessTree ends the child and every descendant. Process.Kill alone
// leaves grandchildren running on Windows, where they keep the inherited output
// pipes open; taskkill /T walks the parent links instead. The direct child is
// killed as well in case taskkill itself is unavailable.
func terminateProcessTree(command *exec.Cmd) error {
	if command.Process == nil {
		return os.ErrProcessDone
	}
	tree := exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(command.Process.Pid))
	treeErr := tree.Run()
	killErr := command.Process.Kill()
	if treeErr == nil || killErr == nil {
		return nil
	}
	return killErr
}
