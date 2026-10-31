// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package githelper

import (
	"runtime"
	"strings"
)

// generatedDirectories are never committed, wherever they appear in the tree.
var generatedDirectories = []string{"build", "node_modules", "dist", "dist-newstyle", "out"}

// privateRoots hold local agent notes that must stay out of every commit.
var privateRoots = []string{".codex", ".claude"}

// generatedPathspecs lists the Git pathspecs that cover every generated and
// private location, at the repository root and nested below it.
func generatedPathspecs() []string {
	pathspecs := make([]string, 0, 2*len(generatedDirectories)+len(privateRoots)+1)
	for _, directory := range generatedDirectories {
		pathspecs = append(pathspecs, directory+"/")
	}
	pathspecs = append(pathspecs, privateRoots...)
	pathspecs = append(pathspecs, "XS/")
	for _, directory := range generatedDirectories {
		pathspecs = append(pathspecs, ":(glob)**/"+directory+"/**")
	}
	return pathspecs
}

func inDirectory(path string, directory string) bool {
	return path == directory || strings.HasPrefix(path, directory+"/") || strings.Contains(path, "/"+directory+"/")
}

// isGenerated reports whether a repository path lies in a generated or
// private location that generatedPathspecs already covers.
func isGenerated(path string) bool {
	for _, directory := range generatedDirectories {
		if inDirectory(path, directory) {
			return true
		}
	}
	for _, root := range privateRoots {
		if path == root || strings.HasPrefix(path, root+"/") {
			return true
		}
	}
	return false
}

// untrackPathspecs returns the generated pathspecs followed by every tracked
// file that an ignore rule covers, each once and in a deterministic order.
func untrackPathspecs(runner gitRunner) ([]string, error) {
	output, err := runner.Capture("ls-files", "-ci", "-z", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	pathspecs := generatedPathspecs()
	seen := make(map[string]struct{}, len(pathspecs))
	for _, path := range pathspecs {
		seen[path] = struct{}{}
	}
	for _, path := range splitNullSeparated(output) {
		if isGenerated(path) {
			continue
		}
		if _, exists := seen[path]; exists {
			continue
		}
		seen[path] = struct{}{}
		pathspecs = append(pathspecs, path)
	}
	return pathspecs, nil
}

// cleanIndex removes generated, private and ignored files from the index.
// The files themselves stay on disk.
func cleanIndex(runner gitRunner) error {
	if runtime.GOOS == "windows" {
		// Submodules checked out on Windows otherwise report every file as a
		// mode change, which `git add --all` would stage in the superproject.
		if err := run(runner, "Windows submodule filemode configuration failed",
			"submodule", "foreach", "--recursive", "git config core.filemode false"); err != nil {
			return err
		}
	}
	pathspecs, err := untrackPathspecs(runner)
	if err != nil {
		return err
	}
	code, err := runner.Run(nullSeparated(pathspecs), false,
		"rm", "--cached", "-r", "--ignore-unmatch", "--pathspec-from-file=-", "--pathspec-file-nul")
	if err != nil {
		return err
	}
	if code != 0 {
		return exitError{code: code, message: "error: generated or ignored files could not be removed from the index"}
	}
	return nil
}
