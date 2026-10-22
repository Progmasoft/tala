// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// Command repo-info produces a read-only, secret-free checkout and tool inventory.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/Progmasoft/tala/helpers/internal/repository"
	"github.com/spf13/cobra"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

type toolInfo struct {
	Name      string `json:"name"`
	Path      string `json:"path,omitempty"`
	Available bool   `json:"available"`
}
type report struct {
	Root         string     `json:"root"`
	OS           string     `json:"os"`
	Architecture string     `json:"architecture"`
	Branch       string     `json:"branch,omitempty"`
	Revision     string     `json:"revision,omitempty"`
	Dirty        bool       `json:"dirty"`
	GitError     string     `json:"gitError,omitempty"`
	Tools        []toolInfo `json:"tools"`
}
type probe interface {
	LookPath(string) (string, error)
	Git(context.Context, string, ...string) (string, error)
}
type systemProbe struct{}

func (systemProbe) LookPath(name string) (string, error) { return exec.LookPath(name) }
func (systemProbe) Git(ctx context.Context, root string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = root
	// Never report process environment, remote URLs, credential helpers, or tokens.
	output, err := cmd.Output()
	return strings.TrimSpace(string(output)), err
}
func collect(ctx context.Context, root string, p probe) report {
	result := report{Root: root, OS: runtime.GOOS, Architecture: runtime.GOARCH}
	for _, name := range []string{"go", "git", "bazelisk", "clang", "clang-cl", "lld", "llvm-config", "ghc", "cabal", "doxygen"} {
		path, err := p.LookPath(name)
		result.Tools = append(result.Tools, toolInfo{Name: name, Path: path, Available: err == nil})
	}
	for _, query := range []struct {
		args []string
		set  func(string)
	}{
		{[]string{"branch", "--show-current"}, func(v string) { result.Branch = v }},
		{[]string{"rev-parse", "HEAD"}, func(v string) { result.Revision = v }},
		{[]string{"status", "--porcelain", "--untracked-files=no"}, func(v string) { result.Dirty = v != "" }},
	} {
		value, err := p.Git(ctx, root, query.args...)
		if err != nil {
			result.GitError = "Git checkout metadata could not be read"
			break
		}
		query.set(value)
	}
	return result
}
func run(args []string, out, errOut io.Writer, p probe) error {
	root := "."
	jsonOutput := false
	cmd := &cobra.Command{Use: "repo-info", Short: "Report checkout and tool availability without changing the machine.", Args: cobra.NoArgs, SilenceUsage: true, SilenceErrors: true}
	cmd.Flags().StringVar(&root, "root", ".", "location inside the checkout")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "write a machine-readable JSON report")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		resolved, err := repository.FindRoot(root)
		if err != nil {
			return err
		}
		ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
		defer cancel()
		result := collect(ctx, resolved, p)
		if jsonOutput {
			encoder := json.NewEncoder(out)
			encoder.SetIndent("", "  ")
			return encoder.Encode(result)
		}
		if _, err := fmt.Fprintf(out, "Checkout: %s\nHost: %s/%s\nBranch: %s\nRevision: %s\nTracked changes: %t\n", result.Root, result.OS, result.Architecture, result.Branch, result.Revision, result.Dirty); err != nil {
			return err
		}
		if result.GitError != "" {
			if _, err := fmt.Fprintln(out, result.GitError); err != nil {
				return err
			}
		}
		for _, tool := range result.Tools {
			state := tool.Path
			if !tool.Available {
				state = "not found"
			}
			if _, err := fmt.Fprintf(out, "%-12s %s\n", tool.Name, state); err != nil {
				return err
			}
		}
		return nil
	}
	cmd.SetOut(out)
	cmd.SetErr(errOut)
	cmd.SetArgs(args)
	return cmd.Execute()
}
func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr, systemProbe{}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
