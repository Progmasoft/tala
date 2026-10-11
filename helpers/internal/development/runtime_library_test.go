// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEveryHostHasARuntimeLibraryTheLinkerLooksFor(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	linker, err := os.ReadFile(filepath.Join(root, "Compiler", "Linker", "NativeLinker.cpp"))
	if err != nil {
		t.Fatal(err)
	}
	for _, goos := range []string{"windows", "linux", "darwin"} {
		name, target, output := runtimeLibraryFor(goos)
		if name == "" || target == "" || output == "" {
			t.Fatalf("%s has no runtime library: %q %q %q", goos, name, target, output)
		}
		// The name it is staged under is the name the compiler looks for.
		if !strings.Contains(string(linker), `"`+name+`"`) {
			t.Fatalf("the native linker does not look for %s, the library staged on %s", name, goos)
		}
		// The target is a package of the repository with a build file.
		directory := strings.TrimPrefix(strings.SplitN(target, ":", 2)[0], "//")
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(directory), "BUILD.bazel")); err != nil {
			t.Fatalf("the runtime library target of %s, %s, has no package: %v", goos, target, err)
		}
		if !strings.HasPrefix(output, directory+"/") {
			t.Fatalf("the output of %s, %s, is not below its package %s", goos, output, directory)
		}
	}
	windows, _, _ := runtimeLibraryFor("windows")
	linux, _, _ := runtimeLibraryFor("linux")
	darwin, _, _ := runtimeLibraryFor("darwin")
	if windows == linux || linux != darwin {
		t.Fatalf("library names: %s, %s, %s", windows, linux, darwin)
	}
}
