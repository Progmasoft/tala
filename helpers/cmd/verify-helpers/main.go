// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// Command verify-helpers checks the complete developer module.
package main

import (
	"errors"
	"fmt"
	"github.com/spf13/cobra"
	"go/parser"
	"go/token"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const moduleName = "github.com/Progmasoft/tala/helpers"

type qualityRunner interface {
	Run(string, string, ...string) ([]byte, error)
}
type systemRunner struct{}

func (systemRunner) Run(directory, command string, args ...string) ([]byte, error) {
	p := exec.Command(command, args...)
	p.Dir = directory
	return p.CombinedOutput()
}
func main() {
	if err := verify(os.Args[1:], os.Stdout, os.Stderr, systemRunner{}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func verify(args []string, out, errOut io.Writer, runner qualityRunner) error {
	root := "."
	command := &cobra.Command{Use: "verify-helpers", Short: "Verify layout, SPDX, formatting, dependencies, vet, and package tests.", Args: cobra.NoArgs, SilenceUsage: true, SilenceErrors: true}
	command.Flags().StringVar(&root, "root", ".", "checkout root containing helpers/go.mod")
	command.RunE = func(cmd *cobra.Command, args []string) error {
		directory, err := filepath.Abs(root)
		if err != nil {
			return err
		}
		files, packages, err := inventory(directory)
		if err != nil {
			return err
		}
		result, err := runner.Run(directory, "gofmt", append([]string{"-l"}, files...)...)
		if err != nil {
			return fmt.Errorf("gofmt: %w: %s", err, result)
		}
		if strings.TrimSpace(string(result)) != "" {
			return fmt.Errorf("Go files need formatting:\n%s", result)
		}
		fmt.Fprintf(out, "PASS formatting (%d files, %d packages)\n", len(files), packages)
		// Module-wide gates include internal implementation packages and every command.
		for _, gate := range [][]string{{"mod", "verify"}, {"vet", "./..."}, {"test", "./..."}} {
			result, err := runner.Run(filepath.Join(directory, "helpers"), "go", gate...)
			if err != nil {
				return fmt.Errorf("go %s: %w\n%s", strings.Join(gate, " "), err, result)
			}
			fmt.Fprintf(out, "PASS go %s\n", strings.Join(gate, " "))
		}
		return nil
	}
	command.SetOut(out)
	command.SetErr(errOut)
	command.SetArgs(args)
	return command.Execute()
}

// inventory never follows symlinks into unrelated source trees. Tests belong to
// packages, so a small implementation module does not need an artificial pair.
func inventory(root string) ([]string, int, error) {
	directory := filepath.Join(root, "helpers")
	manifest, err := os.ReadFile(filepath.Join(directory, "go.mod"))
	if err != nil {
		return nil, 0, err
	}
	if !strings.Contains(strings.ReplaceAll(string(manifest), "\r\n", "\n"), "module "+moduleName+"\n") {
		return nil, 0, errors.New("unexpected helpers module identity")
	}
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err == nil {
		return nil, 0, errors.New("root go.mod must move to helpers/")
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, 0, err
	}
	var files []string
	type packageState struct{ source, test bool }
	packages := map[string]packageState{}
	err = filepath.WalkDir(directory, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("symlink in helper tree: %s", path)
		}
		if entry.IsDir() {
			if entry.Name() == "vendor" || entry.Name() == "bin" {
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Ext(path) != ".go" {
			return nil
		}
		if !entry.Type().IsRegular() {
			return fmt.Errorf("not a regular source: %s", path)
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		text := strings.ReplaceAll(string(contents), "\r\n", "\n")
		if !strings.HasPrefix(text, "// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>\n// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1\n") {
			return fmt.Errorf("missing Progmasoft SPDX header: %s", path)
		}
		lines := strings.Count(text, "\n")
		if text != "" && !strings.HasSuffix(text, "\n") {
			lines++
		}
		if lines > 1500 {
			return fmt.Errorf("%s exceeds 1500 lines", path)
		}
		parsed, err := parser.ParseFile(token.NewFileSet(), path, contents, parser.PackageClauseOnly)
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(directory, path)
		if err != nil {
			return err
		}
		test := strings.HasSuffix(path, "_test.go")
		if strings.HasPrefix(filepath.ToSlash(relative), "cmd/") && parsed.Name.Name != "main" && !(test && parsed.Name.Name == "main_test") {
			return fmt.Errorf("command package must be main: %s", path)
		}
		key := filepath.Dir(relative)
		state := packages[key]
		if test {
			state.test = true
		} else {
			state.source = true
		}
		packages[key] = state
		files = append(files, path)
		return nil
	})
	if err != nil {
		return nil, 0, err
	}
	if len(packages) == 0 {
		return nil, 0, errors.New("no helper packages")
	}
	for name, state := range packages {
		if !state.source || !state.test {
			return nil, 0, fmt.Errorf("package requires source and tests: %s", name)
		}
	}
	sort.Strings(files)
	return files, len(packages), nil
}
