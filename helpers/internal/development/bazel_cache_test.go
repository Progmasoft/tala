// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestBazelDiskCacheIsLocalOptionalAndAbsolute(t *testing.T) {
	root := t.TempDir()
	cache := func() (string, error) { return root, nil }
	if directory, enabled := bazelDiskCacheDirectory("", "", cache); !enabled || directory != filepath.Join(root, "tala", "bazel-disk-cache") {
		t.Fatalf("default cache: %q, %v", directory, enabled)
	}
	// CI owns its cache through the workflow; a developer may opt out.
	for _, example := range [][2]string{{"true", ""}, {"", "off"}, {"true", root}} {
		if directory, enabled := bazelDiskCacheDirectory(example[0], example[1], cache); enabled {
			t.Fatalf("cache enabled for CI=%q setting=%q: %q", example[0], example[1], directory)
		}
	}
	if directory, enabled := bazelDiskCacheDirectory("", root, cache); !enabled || directory != root {
		t.Fatalf("explicit cache: %q, %v", directory, enabled)
	}
	// A relative path would resolve inside Bazel's own working directory.
	if _, enabled := bazelDiskCacheDirectory("", "relative/cache", cache); enabled {
		t.Fatal("relative cache directory accepted")
	}
	if _, enabled := bazelDiskCacheDirectory("", "", func() (string, error) { return "", errors.New("no cache directory") }); enabled {
		t.Fatal("cache enabled without a user cache directory")
	}
}

func TestCachedBuildOnlyExtendsBuildCommands(t *testing.T) {
	t.Setenv("CI", "")
	t.Setenv("TALA_BAZEL_DISK_CACHE", t.TempDir())
	build := cachedBuild([]string{"build", "--config=asan-linux", "//Talac/Cli:talac"})
	if len(build) != 5 || build[0] != "build" || build[3] != "--config=asan-linux" || build[4] != "//Talac/Cli:talac" {
		t.Fatalf("build arguments were reordered or dropped: %v", build)
	}
	clean := []string{"clean", "--expunge"}
	if got := cachedBuild(clean); len(got) != 2 {
		t.Fatalf("non-build command changed: %v", got)
	}
	t.Setenv("TALA_BAZEL_DISK_CACHE", "off")
	if got := cachedBuild([]string{"build", "//Talac/Cli:talac"}); len(got) != 2 {
		t.Fatalf("disabled cache still added options: %v", got)
	}
}
