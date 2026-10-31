// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package githelper

import (
	"fmt"
	"io"
	"strings"
)

// updateOptions select how one commit is created and published.
type updateOptions struct {
	// message is the complete commit message; it is committed as written.
	message string
	// dryRun reports what would be committed and changes nothing.
	dryRun bool
	// allowDefaultBranch permits a commit directly on the default branch.
	allowDefaultBranch bool
	// noPush creates the commit and leaves publishing to a later push.
	noPush bool
}

// refuseDefaultBranch stops work that would land directly on the protected
// default branch, before anything is staged or committed.
func refuseDefaultBranch(runner gitRunner, branch string, action string) error {
	protected, err := defaultBranch(runner)
	if err != nil {
		// Without a known default branch there is nothing to protect by name.
		return nil
	}
	if branch == protected {
		return failf("%s on the default branch %q is not allowed; create a topic branch with `githelper start <name>`", action, branch)
	}
	return nil
}

// pushBranch publishes the current branch. It never forces: a remote branch
// that has diverged is rejected by Git and left as it is.
func pushBranch(runner gitRunner, branch string) error {
	return run(runner, "git push failed; the remote branch may have commits this branch lacks", "push", "-u", remoteName, branch)
}

func update(runner gitRunner, output io.Writer, options updateOptions) error {
	if strings.TrimSpace(options.message) == "" {
		return exitError{code: 2, message: "error: the commit message is empty"}
	}
	branch, err := currentBranch(runner)
	if err != nil {
		return err
	}
	if !options.allowDefaultBranch {
		if err := refuseDefaultBranch(runner, branch, "committing"); err != nil {
			return err
		}
	}
	if options.dryRun {
		return previewUpdate(runner, output)
	}

	// Hygiene runs on both sides of staging: before, so a tracked generated
	// file is not re-added; after, so `git add --all` cannot have staged one.
	if err := cleanIndex(runner); err != nil {
		return err
	}
	if err := run(runner, "git add --all failed", "add", "--all"); err != nil {
		return err
	}
	if err := cleanIndex(runner); err != nil {
		return err
	}

	paths, err := stagedPaths(runner)
	if err != nil {
		return err
	}
	if len(paths) == 0 {
		return failf("nothing to commit; use `githelper push` to publish existing commits")
	}
	fmt.Fprint(output, describeScope(paths))

	code, err := runner.Run([]byte(normalizeMessage(options.message)), false, "commit", "--file=-")
	if err != nil {
		return err
	}
	if code != 0 {
		return exitError{code: code, message: "error: git commit failed"}
	}
	if options.noPush {
		return nil
	}
	if err := pushBranch(runner, branch); err != nil {
		return err
	}
	status, err := workTreeStatus(runner)
	if err != nil {
		return err
	}
	if status != "" {
		return failf("the commit was pushed, but the work tree is still dirty:\n%s", status)
	}
	return nil
}

// previewUpdate shows what `update` would stage, without touching the index.
func previewUpdate(runner gitRunner, output io.Writer) error {
	listing, err := runner.Capture("status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return err
	}
	paths := make([]string, 0)
	entries := splitNullSeparated(listing)
	for index := 0; index < len(entries); index++ {
		entry := entries[index]
		if len(entry) < 4 {
			continue
		}
		state, changed := entry[:2], entry[3:]
		// A rename or copy is followed by its source path as its own entry.
		if state[0] == 'R' || state[0] == 'C' {
			index++
			if index < len(entries) && !isGenerated(entries[index]) {
				paths = append(paths, entries[index])
			}
		}
		if !isGenerated(changed) {
			paths = append(paths, changed)
		}
	}
	if len(paths) == 0 {
		fmt.Fprintln(output, "nothing to commit")
		return nil
	}
	fmt.Fprint(output, describeScope(paths))
	for _, changed := range paths {
		fmt.Fprintf(output, "  %s\n", changed)
	}
	fmt.Fprintln(output, "dry run: nothing was staged, committed or pushed")
	return nil
}

// push publishes commits that already exist, such as a merge of the default
// branch, without creating a new one.
func push(runner gitRunner) error {
	branch, err := currentBranch(runner)
	if err != nil {
		return err
	}
	if err := refuseDefaultBranch(runner, branch, "pushing"); err != nil {
		return err
	}
	return pushBranch(runner, branch)
}

// sync merges the remote default branch into the current topic branch. It
// does not push: the merged tree is to be tested first.
func sync(runner gitRunner, output io.Writer) error {
	branch, err := currentBranch(runner)
	if err != nil {
		return err
	}
	if err := requireCleanWorkTree(runner, "sync"); err != nil {
		return err
	}
	if err := run(runner, "git fetch failed", "fetch", "--prune", remoteName); err != nil {
		return err
	}
	base, err := defaultBranch(runner)
	if err != nil {
		return err
	}
	upstream := remoteName + "/" + base
	if branch == base {
		return run(runner, "the default branch cannot be fast-forwarded; it has local commits", "merge", "--ff-only", upstream)
	}
	behind, err := captureLine(runner, "rev-list", "--count", "HEAD.."+upstream)
	if err != nil {
		return err
	}
	if behind == "0" {
		fmt.Fprintf(output, "%s already contains %s\n", branch, upstream)
		return nil
	}
	code, err := runner.Run(nil, false, "merge", "--no-edit", upstream)
	if err != nil {
		return err
	}
	if code != 0 {
		return exitError{code: code, message: "error: the merge stopped on conflicts; resolve them, commit with `githelper update`, or run `git merge --abort`"}
	}
	fmt.Fprintf(output, "merged %s commit(s) from %s; test the result, then run `githelper push`\n", behind, upstream)
	return nil
}

// start creates a topic branch from the current remote default branch.
func start(runner gitRunner, output io.Writer, name string) error {
	if code, err := runner.Run(nil, true, "check-ref-format", "--branch", name); err != nil {
		return err
	} else if code != 0 {
		return exitError{code: 2, message: fmt.Sprintf("error: %q is not a valid branch name", name)}
	}
	if err := requireCleanWorkTree(runner, "start"); err != nil {
		return err
	}
	if err := run(runner, "git fetch failed", "fetch", "--prune", remoteName); err != nil {
		return err
	}
	base, err := defaultBranch(runner)
	if err != nil {
		return err
	}
	if err := run(runner, "the branch could not be created; it may already exist",
		"switch", "--create", name, "--no-track", remoteName+"/"+base); err != nil {
		return err
	}
	fmt.Fprintf(output, "on new branch %s from %s/%s\n", name, remoteName, base)
	return nil
}

// status reports where the branch stands: its relation to its upstream and
// to the default branch, and what is uncommitted.
func status(runner gitRunner, output io.Writer) error {
	branch, err := currentBranch(runner)
	if err != nil {
		return err
	}
	fmt.Fprintf(output, "branch: %s\n", branch)
	if upstream, err := captureLine(runner, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"); err == nil && upstream != "" {
		if counts, err := captureLine(runner, "rev-list", "--left-right", "--count", "HEAD..."+upstream); err == nil {
			ahead, behind, _ := strings.Cut(counts, "\t")
			fmt.Fprintf(output, "upstream: %s (%s ahead, %s behind)\n", upstream, ahead, strings.TrimSpace(behind))
		}
	} else {
		fmt.Fprintln(output, "upstream: none; the branch has not been pushed")
	}
	if base, err := defaultBranch(runner); err == nil && base != branch {
		if behind, err := captureLine(runner, "rev-list", "--count", "HEAD.."+remoteName+"/"+base); err == nil {
			fmt.Fprintf(output, "default branch: %s/%s (%s commit(s) not merged here, as of the last fetch)\n", remoteName, base, behind)
		}
	}
	changes, err := workTreeStatus(runner)
	if err != nil {
		return err
	}
	if changes == "" {
		fmt.Fprintln(output, "nothing uncommitted")
		return nil
	}
	fmt.Fprintln(output, changes)
	return nil
}
