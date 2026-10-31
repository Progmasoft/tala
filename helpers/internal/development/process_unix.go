// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

//go:build !windows

package development

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// prepareProcessTree places the child in its own process group so descendants
// that it spawns can be signalled together with it.
func prepareProcessTree(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// terminateProcessTree kills the child's whole process group. A group that has
// already exited is reported as os.ErrProcessDone, which exec treats as benign.
func terminateProcessTree(command *exec.Cmd) error {
	if command.Process == nil {
		return os.ErrProcessDone
	}
	err := syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	if errors.Is(err, syscall.ESRCH) {
		return os.ErrProcessDone
	}
	return err
}
