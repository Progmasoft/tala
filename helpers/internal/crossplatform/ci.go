// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package crossplatform

import (
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
)

// A container reaches the Linux hosts only. The workflows run on all of
// them, on real Windows and macOS machines among them, and cost the
// developer's machine nothing. This file starts those workflows for a branch
// that has no pull request yet, which is the question a container was meant
// to answer: does this work elsewhere, before anyone is asked to review it.

// HostedTarget is a platform a workflow of the repository builds and tests
// on.
type HostedTarget struct {
	// Name is what the command line calls it.
	Name string `json:"name"`
	// Description is one line for a listing.
	Description string `json:"description"`
	// Workflow is the file of the workflow that covers it.
	Workflow string `json:"workflow"`
}

// HostedTargets returns the platforms the workflows cover. Several share a
// workflow: asking for one of them runs the others of that workflow too.
func HostedTargets() []HostedTarget {
	return []HostedTarget{
		{Name: "windows", Description: "Windows with ClangCL", Workflow: "compiler-tier1.yml"},
		{Name: "macos-15", Description: "macOS 15 Sequoia with Clang", Workflow: "compiler-tier1.yml"},
		{Name: "macos-26", Description: "macOS 26 Tahoe with Clang", Workflow: "compiler-tier1.yml"},
		{Name: "ubuntu-26.04", Description: "Ubuntu 26.04 LTS with Clang", Workflow: "compiler-tier2.yml"},
		{Name: "fedora-43", Description: "Fedora 43 with Clang", Workflow: "compiler-tier3.yml"},
	}
}

// HostedWorkflows returns the workflows that cover the named targets, each
// once, in the order of the listing. No name selects every workflow.
func HostedWorkflows(all []HostedTarget, names []string) ([]string, error) {
	wanted := map[string]bool{}
	for _, name := range names {
		for _, part := range strings.Split(name, ",") {
			if part = strings.TrimSpace(part); part != "" {
				wanted[part] = true
			}
		}
	}
	if len(names) != 0 && len(wanted) == 0 {
		return nil, errors.New("no target was named")
	}
	seen := map[string]bool{}
	var workflows []string
	for _, target := range all {
		if len(names) != 0 && !wanted[target.Name] {
			continue
		}
		delete(wanted, target.Name)
		if !seen[target.Workflow] {
			seen[target.Workflow] = true
			workflows = append(workflows, target.Workflow)
		}
	}
	if len(wanted) != 0 {
		unknown := make([]string, 0, len(wanted))
		for name := range wanted {
			unknown = append(unknown, name)
		}
		sort.Strings(unknown)
		known := make([]string, 0, len(all))
		for _, target := range all {
			known = append(known, target.Name)
		}
		return nil, fmt.Errorf("unknown target %s; the workflows cover %s", strings.Join(unknown, ", "), strings.Join(known, ", "))
	}
	return workflows, nil
}

// PushedBranch returns the current branch, after checking that the commit
// the workflows would run is the one that is checked out. A workflow runs
// what the remote has: with unpushed commits, or with changes that are not
// committed, it would test something other than what the developer sees.
func PushedBranch(engine Engine, repository string) (string, error) {
	git, err := engine.LookPath("git")
	if err != nil {
		return "", errors.New("required tool \"git\" was not found")
	}
	branch, err := engine.Output(repository, git, "branch", "--show-current")
	if err != nil {
		return "", fmt.Errorf("git could not name the current branch: %w", err)
	}
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return "", errors.New("no branch is checked out; a workflow is started for a branch")
	}
	status, err := engine.Output(repository, git, "status", "--porcelain")
	if err != nil {
		return "", fmt.Errorf("git could not report the working tree: %w", err)
	}
	if strings.TrimSpace(status) != "" {
		return "", errors.New("the working tree has changes that are not committed; a workflow tests what is pushed, so commit and push them first")
	}
	local, err := engine.Output(repository, git, "rev-parse", "HEAD")
	if err != nil {
		return "", fmt.Errorf("git could not name the current commit: %w", err)
	}
	remote, err := engine.Output(repository, git, "ls-remote", "--heads", "origin", "refs/heads/"+branch)
	if err != nil {
		return "", fmt.Errorf("git could not ask the remote for branch %s: %w", branch, err)
	}
	fields := strings.Fields(remote)
	if len(fields) == 0 {
		return "", fmt.Errorf("branch %s is not on the remote; push it first", branch)
	}
	if fields[0] != strings.TrimSpace(local) {
		return "", fmt.Errorf("branch %s on the remote is at %.8s and the checkout is at %.8s; push first, so that the workflows test this commit",
			branch, fields[0], strings.TrimSpace(local))
	}
	return branch, nil
}

// Dispatch starts each workflow for the branch and prints where its runs are
// listed. With watch it then follows the newest run of each to its end and
// fails if one fails.
func Dispatch(engine Engine, repository string, workflows []string, branch string, watch bool, output io.Writer, errorOutput io.Writer) error {
	gh, err := engine.LookPath("gh")
	if err != nil {
		return errors.New("required tool \"gh\", the GitHub command line, was not found; install it and run `gh auth login`")
	}
	for _, workflow := range workflows {
		if err := engine.Run(repository, nil, output, errorOutput, gh, "workflow", "run", workflow, "--ref", branch); err != nil {
			return fmt.Errorf("workflow %s could not be started for %s: %w\n"+
				"A workflow is started by hand only when its file on the default branch allows it.", workflow, branch, err)
		}
		fmt.Fprintf(output, "Started %s for %s. Its runs: gh run list --workflow %s --branch %s\n", workflow, branch, workflow, branch)
	}
	if !watch {
		return nil
	}
	var failed []string
	for _, workflow := range workflows {
		// A run appears a moment after it is requested; `gh run watch`
		// needs its identity, which the list gives once it exists.
		identity := ""
		for attempt := 0; attempt < 30 && identity == ""; attempt++ {
			listed, err := engine.Output(repository, gh, "run", "list", "--workflow", workflow, "--branch", branch,
				"--event", "workflow_dispatch", "--limit", "1", "--json", "databaseId", "--jq", ".[0].databaseId")
			if err != nil {
				return fmt.Errorf("the runs of %s could not be listed: %w", workflow, err)
			}
			identity = strings.TrimSpace(listed)
			if identity == "" {
				pause()
			}
		}
		if identity == "" {
			return fmt.Errorf("workflow %s was started and no run of it appeared", workflow)
		}
		if err := engine.Run(repository, nil, output, errorOutput, gh, "run", "watch", identity, "--exit-status"); err != nil {
			failed = append(failed, workflow)
		}
	}
	if len(failed) != 0 {
		return fmt.Errorf("%d of %d workflows failed: %s", len(failed), len(workflows), strings.Join(failed, ", "))
	}
	return nil
}
