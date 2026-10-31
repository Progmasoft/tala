// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

// Package repository resolves the checkout independently of the command's cwd.
package repository

import (
	"fmt"
	"os"
	"path/filepath"
)

// FindRoot walks ancestors without assuming that the helper was launched at the
// checkout root. A regular MODULE.bazel is the native graph's stable boundary.
func FindRoot(start string) (string, error) {
	directory, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		info, err := os.Stat(filepath.Join(directory, "MODULE.bazel"))
		if err == nil && info.Mode().IsRegular() {
			return directory, nil
		}
		if err != nil && !os.IsNotExist(err) {
			return "", fmt.Errorf("inspect checkout: %w", err)
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			return "", fmt.Errorf("MODULE.bazel not found above %s", start)
		}
		directory = parent
	}
}
