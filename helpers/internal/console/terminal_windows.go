// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package console

import (
	"os"

	"golang.org/x/sys/windows"
)

// enableEscapes turns on escape sequence processing for a Windows console. A
// console that refuses it gets plain output instead of raw escape sequences.
func enableEscapes(stream *os.File) bool {
	handle := windows.Handle(stream.Fd())
	var mode uint32
	if windows.GetConsoleMode(handle, &mode) != nil {
		return false
	}
	if mode&windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0 {
		return true
	}
	return windows.SetConsoleMode(handle, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) == nil
}
