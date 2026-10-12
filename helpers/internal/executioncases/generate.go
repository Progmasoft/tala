// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package executioncases

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// HaskellModule is the generated Haskell module, relative to the repository
// root.
const HaskellModule = "Talac/Haskell/Driver/test/BranchingEvaluationCases.hs"

// tables lists the case files in the order the Haskell tests report them.
func tables() []Table {
	return []Table{
		{
			Source:  "Talac/Fuzzing/Cases/Selection.cases",
			Include: "Talac/Fuzzing/Generated/SelectionCases.inc",
			Binding: "selectionCases",
			Summary: "Which arm, block or body is selected, and how often each part runs.",
		},
		{
			Source:  "Talac/Fuzzing/Cases/Leaving.cases",
			Include: "Talac/Fuzzing/Generated/LeavingCases.inc",
			Binding: "leavingCases",
			Summary: "Expressions that leave instead of yielding a value.",
		},
	}
}

// Outputs reads every case file under the repository root and returns the
// generated files by their path relative to that root. The result depends on
// the case files alone.
func Outputs(root string) (map[string]string, error) {
	loaded := tables()
	outputs := make(map[string]string, len(loaded)+1)
	for index := range loaded {
		table := &loaded[index]
		text, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(table.Source)))
		if err != nil {
			return nil, fmt.Errorf("read case file: %w", err)
		}
		table.Cases, err = Parse(table.Source, string(text))
		if err != nil {
			return nil, err
		}
		outputs[table.Include] = RenderInclude(*table)
	}
	outputs[HaskellModule] = RenderHaskell(loaded)
	return outputs, nil
}

// sameText compares generated text with a file as checked out: the working
// tree may hold either line ending.
func sameText(generated string, onDisk []byte) bool {
	return generated == string(bytes.ReplaceAll(onDisk, []byte("\r\n"), []byte("\n")))
}

// Stale returns the generated files that are missing or differ from what the
// case files generate, sorted.
func Stale(root string) ([]string, error) {
	outputs, err := Outputs(root)
	if err != nil {
		return nil, err
	}
	var stale []string
	for path, text := range outputs {
		onDisk, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(path)))
		if err != nil && !os.IsNotExist(err) {
			return nil, fmt.Errorf("read generated file: %w", err)
		}
		if err != nil || !sameText(text, onDisk) {
			stale = append(stale, path)
		}
	}
	sort.Strings(stale)
	return stale, nil
}

// Write regenerates every file that is stale and returns the files it wrote.
// A file that is current is left untouched, so its line endings and its
// modification time stay as they are.
func Write(root string) ([]string, error) {
	outputs, err := Outputs(root)
	if err != nil {
		return nil, err
	}
	stale, err := Stale(root)
	if err != nil {
		return nil, err
	}
	for _, path := range stale {
		target := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return nil, fmt.Errorf("create directory: %w", err)
		}
		if err := os.WriteFile(target, []byte(outputs[path]), 0o644); err != nil {
			return nil, fmt.Errorf("write generated file: %w", err)
		}
	}
	return stale, nil
}

// FindRoot walks up from a directory to the repository root, which is the
// directory that holds the case files.
func FindRoot(start string) (string, error) {
	directory, err := filepath.Abs(start)
	if err != nil {
		return "", fmt.Errorf("resolve directory: %w", err)
	}
	marker := filepath.FromSlash(tables()[0].Source)
	for {
		if _, err := os.Stat(filepath.Join(directory, marker)); err == nil {
			return directory, nil
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			return "", fmt.Errorf("no repository root with %s above %s", strings.ReplaceAll(marker, `\`, "/"), start)
		}
		directory = parent
	}
}
