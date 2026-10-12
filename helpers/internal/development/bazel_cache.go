// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"os"
	"path/filepath"
)

// bazelDiskCacheLimit bounds the local cache; Bazel evicts the least recently
// used entries beyond it while idle.
const bazelDiskCacheLimit = "8G"

// cachedBuild adds a persistent, content-addressed disk cache to a Bazel build.
// One output tree serves the plain, sanitizer and fuzz configurations in turn,
// and Bazel's in-tree action cache remembers only the most recent action per
// output, so every configuration switch otherwise recompiles all owned
// translation units even when no source changed. The disk cache is keyed by
// each action's complete command line and inputs: a sanitizer or fuzz object
// can never be served to another configuration, and no instrumentation,
// check or time budget is altered.
//
// CI keeps its own cache through the workflow's Bazel setup, and
// TALA_BAZEL_DISK_CACHE=off disables this one for a cold local measurement.
func cachedBuild(arguments []string) []string {
	directory, enabled := bazelDiskCacheDirectory(os.Getenv("CI"), os.Getenv("TALA_BAZEL_DISK_CACHE"), os.UserCacheDir)
	if !enabled || len(arguments) == 0 || arguments[0] != "build" {
		return arguments
	}
	cached := make([]string, 0, len(arguments)+2)
	cached = append(cached, "build", "--disk_cache="+directory, "--experimental_disk_cache_gc_max_size="+bazelDiskCacheLimit)
	return append(cached, arguments[1:]...)
}

func bazelDiskCacheDirectory(ci, configured string, userCache func() (string, error)) (string, bool) {
	if ci == "true" || configured == "off" {
		return "", false
	}
	if configured != "" {
		return configured, filepath.IsAbs(configured)
	}
	root, err := userCache()
	if err != nil || root == "" {
		return "", false
	}
	return filepath.Join(root, "tala", "bazel-disk-cache"), true
}
