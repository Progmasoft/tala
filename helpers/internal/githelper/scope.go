// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package githelper

import (
	"fmt"
	"sort"
	"strings"
)

// stagedPaths lists every path the index changes relative to HEAD, including
// both sides of a rename.
func stagedPaths(runner gitRunner) ([]string, error) {
	output, err := runner.Capture("diff", "--cached", "--name-only", "--no-renames", "-z")
	if err != nil {
		return nil, err
	}
	paths := splitNullSeparated(output)
	sort.Strings(paths)
	return paths, nil
}

// describeScope summarizes staged paths by top-level directory, so the scope
// of a commit is visible before it is created.
func describeScope(paths []string) string {
	counts := map[string]int{}
	for _, stagedPath := range paths {
		root, _, nested := strings.Cut(stagedPath, "/")
		if !nested {
			root = "(repository root)"
		}
		counts[root]++
	}
	roots := make([]string, 0, len(counts))
	for root := range counts {
		roots = append(roots, root)
	}
	sort.Strings(roots)
	var summary strings.Builder
	fmt.Fprintf(&summary, "%d staged path(s):\n", len(paths))
	for _, root := range roots {
		fmt.Fprintf(&summary, "  %4d  %s\n", counts[root], root)
	}
	return summary.String()
}

// normalizeMessage gives the commit message Unix line endings and exactly
// one trailing newline. Its content is never changed.
func normalizeMessage(message string) string {
	return strings.TrimRight(strings.ReplaceAll(message, "\r\n", "\n"), "\n ") + "\n"
}
