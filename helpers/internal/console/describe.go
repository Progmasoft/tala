// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package console

import (
	"path/filepath"
	"strings"
)

// describedArguments is how many arguments a step title keeps.
const describedArguments = 5

// Describe names the step that runs a program: the program without its
// folder and extension, then its arguments. A path is shortened to its last
// element, an option whose value is a path is left out (cache and output
// folders say little about the step), and so is a Bazel --experimental_
// option; a long list ends in "…".
func Describe(name string, arguments []string) string {
	words := []string{strings.TrimSuffix(filepath.Base(name), ".exe")}
	kept := 0
	for _, argument := range arguments {
		if kept == describedArguments {
			words = append(words, "…")
			break
		}
		if option, value, found := strings.Cut(argument, "="); found && strings.HasPrefix(option, "-") && (isPath(value) || strings.HasPrefix(option, "--experimental_")) {
			continue
		}
		if isPath(argument) {
			argument = filepath.Base(argument)
		}
		words = append(words, argument)
		kept++
	}
	return strings.Join(words, " ")
}

// isPath reports whether text names a file or a folder. Bazel labels
// ("//Talac:talac", "@llvm//:support") are not paths.
func isPath(text string) bool {
	if strings.HasPrefix(text, "//") || strings.HasPrefix(text, "@") {
		return false
	}
	return filepath.IsAbs(text) || strings.ContainsAny(text, `/\`)
}
