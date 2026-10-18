// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package crossplatform

import (
	"archive/tar"
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func names(targets []Target) []string {
	var result []string
	for _, target := range targets {
		result = append(result, target.Name)
	}
	return result
}

func TestEveryHostRunsTheLinuxTargetsAndListsWhatItCannot(t *testing.T) {
	cases := map[string][]string{
		"windows": {"ubuntu-26.04", "fedora-43", "macos"},
		"darwin":  {"ubuntu-26.04", "fedora-43", "windows"},
		"linux":   {"ubuntu-26.04", "fedora-43", "macos", "windows"},
	}
	for host, want := range cases {
		targets := Targets(host)
		if got := names(targets); !reflect.DeepEqual(got, want) {
			t.Fatalf("targets of %s = %v, want %v", host, got, want)
		}
		for _, target := range targets {
			if target.Platform == "linux" != target.Runs() {
				t.Fatalf("%s on %s: runs = %v", target.Name, host, target.Runs())
			}
			if target.Runs() && (target.Containerfile == "" || target.Reason != "") {
				t.Fatalf("a target that runs needs a build file and no reason: %+v", target)
			}
			if !target.Runs() && (target.Reason == "" || target.Containerfile != "") {
				t.Fatalf("a target that cannot run must say why: %+v", target)
			}
		}
	}
}

func TestTheBuildFilesOfTheTargetsExist(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range Targets("linux") {
		if !target.Runs() {
			continue
		}
		content, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(target.Containerfile)))
		if err != nil {
			t.Fatalf("target %s: %v", target.Name, err)
		}
		// The toolchain a workflow pins is pinned in the image as well.
		for _, pinned := range []string{"haskell:9.10.3-", "/opt/ghc/9.10.3", "cabal 3.16.1.0", "bazelisk@v1.29.0", "sha256sum -c"} {
			if !strings.Contains(string(content), pinned) {
				t.Fatalf("the build file of %s does not pin %q", target.Name, pinned)
			}
		}
	}
}

func TestSelectTakesWhatRunsByDefaultAndRefusesTheRest(t *testing.T) {
	all := Targets("windows")
	selected, err := Select(all, nil)
	if err != nil || !reflect.DeepEqual(names(selected), []string{"ubuntu-26.04", "fedora-43"}) {
		t.Fatalf("default selection = %v, %v", names(selected), err)
	}
	selected, err = Select(all, []string{"fedora-43, ubuntu-26.04", "fedora-43"})
	if err != nil || !reflect.DeepEqual(names(selected), []string{"ubuntu-26.04", "fedora-43"}) {
		t.Fatalf("named selection = %v, %v", names(selected), err)
	}
	if _, err := Select(all, []string{"macos"}); err == nil || !strings.Contains(err.Error(), "Apple") {
		t.Fatalf("a target that cannot run was selected: %v", err)
	}
	if _, err := Select(all, []string{"ubuntu-26.04", "solaris"}); err == nil || !strings.Contains(err.Error(), "unknown target solaris") {
		t.Fatalf("an unknown target was accepted: %v", err)
	}
	// Windows is the host here, so it is not a target at all.
	if _, err := Select(all, []string{"windows"}); err == nil || !strings.Contains(err.Error(), "unknown target") {
		t.Fatalf("the host's own platform was accepted: %v", err)
	}
	if _, err := Select(all, []string{" , "}); err == nil {
		t.Fatal("an empty name selected something")
	}
}

func TestSuitesAreNamedOnceAndLimitBazel(t *testing.T) {
	seen := map[string]bool{}
	for _, suite := range Suites(3) {
		if seen[suite.Name] || suite.Script == "" || suite.Description == "" {
			t.Fatalf("suite %+v", suite)
		}
		seen[suite.Name] = true
	}
	native, err := SelectSuite(Suites(3), "native")
	if err != nil || !strings.Contains(native.Script, "--jobs=3") {
		t.Fatalf("native suite = %+v, %v", native, err)
	}
	if _, err := SelectSuite(Suites(3), "everything"); err == nil || !strings.Contains(err.Error(), "helpers") {
		t.Fatalf("an unknown suite was accepted: %v", err)
	}
}

func TestSourceFilesAreSortedUniqueAndInsideTheCheckout(t *testing.T) {
	files, err := SourceFiles("b.txt\x00a/c.txt\x00\x00b.txt\x00a\\d.txt\x00")
	want := []string{"a/c.txt", "a/d.txt", "b.txt"}
	if filepath.Separator != '\\' {
		want = []string{"a/c.txt", "a\\d.txt", "b.txt"}
	}
	if err != nil || !reflect.DeepEqual(files, want) {
		t.Fatalf("files = %v, %v", files, err)
	}
	for _, outside := range []string{"../secret", "a/../../secret", "/etc/passwd", "."} {
		if _, err := SourceFiles(outside); err == nil {
			t.Fatalf("%q was accepted", outside)
		}
	}
	if files, err := SourceFiles(""); err != nil || len(files) != 0 {
		t.Fatalf("an empty listing gave %v, %v", files, err)
	}
}

func write(t *testing.T, root string, name string, content string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestTheArchiveHoldsTheListedFilesAsTheyAre(t *testing.T) {
	root := t.TempDir()
	write(t, root, "MODULE.bazel", "module()\n")
	write(t, root, "Talac/a.cpp", "int a;\r\n")
	write(t, root, "run.sh", "#!/bin/sh\n")
	if err := os.MkdirAll(filepath.Join(root, "third_party", "catch3"), 0o700); err != nil {
		t.Fatal(err)
	}
	var stream bytes.Buffer
	written, err := WriteArchive(&stream, root, []string{"Talac/a.cpp", "MODULE.bazel", "run.sh", "deleted.txt", "third_party/catch3"})
	if err != nil || written != 3 {
		t.Fatalf("wrote %d files, %v", written, err)
	}
	contents := map[string]string{}
	modes := map[string]int64{}
	reader := tar.NewReader(&stream)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(reader)
		if err != nil {
			t.Fatal(err)
		}
		contents[header.Name] = string(data)
		modes[header.Name] = header.Mode
	}
	if len(contents) != 3 || contents["Talac/a.cpp"] != "int a;\r\n" || contents["MODULE.bazel"] != "module()\n" {
		t.Fatalf("archive = %v", contents)
	}
	if modes["run.sh"] != 0o755 || modes["Talac/a.cpp"] != 0o644 {
		t.Fatalf("modes = %v", modes)
	}
}

func TestTheImageNameFollowsTheBuildFileAndNotItsLineEndings(t *testing.T) {
	target := Target{Name: "ubuntu-26.04"}
	first := ImageName(target, []byte("FROM a\nRUN b\n"))
	if first != ImageName(target, []byte("FROM a\r\nRUN b\r\n")) {
		t.Fatal("a checkout with other line endings would build another image")
	}
	if first == ImageName(target, []byte("FROM a\nRUN c\n")) {
		t.Fatal("a changed build file keeps its image")
	}
	if !strings.HasPrefix(first, "localhost/tala-cross-ubuntu-26.04:") {
		t.Fatalf("image name = %s", first)
	}
	if CacheVolume(target) == CacheVolume(Target{Name: "fedora-43"}) {
		t.Fatal("two targets share a cache")
	}
}

// fakeEngine records what would be run.
type fakeEngine struct {
	missing     map[string]bool
	infoFails   bool
	imageExists bool
	runFails    map[string]bool
	calls       []string
	archives    []int
}

func (engine *fakeEngine) LookPath(name string) (string, error) {
	if engine.missing[name] {
		return "", errors.New("not found")
	}
	return name, nil
}

func (engine *fakeEngine) Output(directory string, name string, arguments ...string) (string, error) {
	engine.calls = append(engine.calls, name+" "+strings.Join(arguments, " "))
	switch {
	case name == "podman" && arguments[0] == "info":
		if engine.infoFails {
			return "", errors.New("cannot connect")
		}
		return "linux\n", nil
	case name == "podman" && arguments[0] == "images":
		return "localhost/tala-cross-ubuntu-26.04:abc\t2.7 GB\ndocker.io/library/ubuntu:26.04\t112 MB\n", nil
	case name == "podman" && arguments[0] == "volume":
		return "tala-cross-ubuntu-26.04\nsomeone-elses-volume\n", nil
	case name == "podman" && arguments[0] == "system":
		return "TYPE  TOTAL\n", nil
	case name == "podman" && arguments[0] == "image":
		if engine.imageExists {
			return "", nil
		}
		return "", errors.New("exit status 1")
	case name == "git" && strings.Contains(strings.Join(arguments, " "), "--cached"):
		return "MODULE.bazel\x00Talac/a.cpp\x00", nil
	case name == "git":
		return "new.txt\x00", nil
	}
	return "", nil
}

func (engine *fakeEngine) Run(directory string, input io.Reader, output io.Writer, errorOutput io.Writer, name string, arguments ...string) error {
	engine.calls = append(engine.calls, name+" "+strings.Join(arguments[:2], " "))
	if arguments[0] == "run" {
		// Read the sources as a container would.
		count := 0
		reader := tar.NewReader(input)
		for {
			if _, err := reader.Next(); err != nil {
				break
			}
			count++
		}
		engine.archives = append(engine.archives, count)
		for target, fails := range engine.runFails {
			if fails && strings.Contains(strings.Join(arguments, " "), "tala-cross-"+target) {
				return errors.New("exit status 1")
			}
		}
	}
	return nil
}

func checkout(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	write(t, root, "MODULE.bazel", "module()\n")
	write(t, root, "Talac/a.cpp", "int a;\n")
	write(t, root, "new.txt", "new\n")
	for _, target := range Targets("linux") {
		if target.Runs() {
			write(t, root, target.Containerfile, "FROM scratch\n")
		}
	}
	return root
}

func TestARunBuildsTheImageOnceSendsTheSourcesAndReportsEachTarget(t *testing.T) {
	root := checkout(t)
	engine := &fakeEngine{runFails: map[string]bool{"fedora-43": true}}
	var output, errorOutput bytes.Buffer
	selected, _ := Select(Targets("windows"), nil)
	results, err := RunAll(engine, selected, Options{Repository: root, Script: "true", Output: &output, ErrorOutput: &errorOutput})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 || !results[0].Passed || results[1].Passed || !strings.Contains(results[1].Error, "fedora-43") {
		t.Fatalf("results = %+v", results)
	}
	// Both targets got the three files, and the failure of one did not
	// stop the other.
	if !reflect.DeepEqual(engine.archives, []int{3, 3}) {
		t.Fatalf("files received = %v", engine.archives)
	}
	builds := 0
	for _, call := range engine.calls {
		if strings.HasPrefix(call, "podman build") {
			builds++
		}
	}
	if builds != 2 {
		t.Fatalf("builds = %d in %v", builds, engine.calls)
	}

	engine = &fakeEngine{imageExists: true}
	if _, err := RunAll(engine, selected[:1], Options{Repository: root, Script: "true", Output: &output, ErrorOutput: &errorOutput}); err != nil {
		t.Fatal(err)
	}
	for _, call := range engine.calls {
		if strings.HasPrefix(call, "podman build") {
			t.Fatalf("an image that exists was built again: %v", engine.calls)
		}
	}
}

func TestARunExplainsAMissingOrStoppedPodman(t *testing.T) {
	root := checkout(t)
	selected, _ := Select(Targets("windows"), nil)
	options := Options{Repository: root, Script: "true", Output: io.Discard, ErrorOutput: io.Discard}
	if _, err := RunAll(&fakeEngine{missing: map[string]bool{"podman": true}}, selected, options); err == nil || !strings.Contains(err.Error(), "prebuild install") {
		t.Fatalf("missing Podman: %v", err)
	}
	if _, err := RunAll(&fakeEngine{infoFails: true}, selected, options); err == nil || !strings.Contains(err.Error(), "podman machine start") {
		t.Fatalf("stopped Podman: %v", err)
	}
	if _, err := RunAll(&fakeEngine{missing: map[string]bool{"git": true}}, selected, options); err == nil || !strings.Contains(err.Error(), "git") {
		t.Fatalf("missing Git: %v", err)
	}
}

func TestBuildsAndRunsAreBounded(t *testing.T) {
	options := Options{CPUs: 2, Memory: "3g"}
	if got := strings.Join(runLimits(options), " "); got != "--cpus 2 --memory 3g" {
		t.Fatalf("run limits = %q", got)
	}
	if got := strings.Join(buildLimits(options), " "); got != "--cpu-period 100000 --cpu-quota 200000 --memory 3g" {
		t.Fatalf("build limits = %q", got)
	}
	if len(runLimits(Options{})) != 0 || len(buildLimits(Options{})) != 0 {
		t.Fatal("a run without bounds is bounded")
	}
}

func TestCleanRemovesOnlyWhatThisToolCreated(t *testing.T) {
	engine := &fakeEngine{}
	var output bytes.Buffer
	images, volumes, err := Clean(engine, &output, &output)
	if err != nil || images != 1 || volumes != 1 {
		t.Fatalf("removed %d images and %d volumes, %v", images, volumes, err)
	}
	calls := strings.Join(engine.calls, "\n")
	if !strings.Contains(calls, "podman rmi --force") || !strings.Contains(calls, "podman volume rm") || !strings.Contains(calls, "podman image prune") {
		t.Fatalf("calls = %v", engine.calls)
	}
	if err := Usage(engine, &output); err != nil || !strings.Contains(output.String(), "tala-cross-ubuntu-26.04") ||
		strings.Contains(output.String(), "someone-elses-volume") {
		t.Fatalf("usage: %q, %v", output.String(), err)
	}
	if _, _, err := Clean(&fakeEngine{missing: map[string]bool{"podman": true}}, &output, &output); err == nil {
		t.Fatal("cleaning without Podman passed")
	}
}

func TestTheContainerScriptUnpacksIntoItsOwnDirectoryAndKeepsCaches(t *testing.T) {
	script := containerScript("go run ./helpers/cmd/verify-helpers")
	for _, expected := range []string{"set -eu", "rm -rf /work/source", "tar -xf - -C /work/source", "HOME=/cache/home", "LLVM_ROOT=", "cd /work/source"} {
		if !strings.Contains(script, expected) {
			t.Fatalf("the container script lacks %q:\n%s", expected, script)
		}
	}
	if !strings.HasSuffix(script, "go run ./helpers/cmd/verify-helpers") {
		t.Fatalf("the command is not last:\n%s", script)
	}
}
