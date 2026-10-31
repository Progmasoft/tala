// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestSplitArgumentsKeepsCommandAndBazelSurfacesSeparate(t *testing.T) {
	command, bazel, err := splitArguments([]string{"address", "--", "--jobs=4", "--nocache_test_results"})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(command, []string{"address"}) {
		t.Fatalf("command arguments = %#v", command)
	}
	if !reflect.DeepEqual(bazel, []string{"--jobs=4", "--nocache_test_results"}) {
		t.Fatalf("Bazel arguments = %#v", bazel)
	}
}

func TestSplitArgumentsRejectsPrivateConfigurationEscape(t *testing.T) {
	for _, value := range []string{"--config", "--config=asan-windows"} {
		_, _, err := splitArguments([]string{"--", value})
		if err == nil {
			t.Fatalf("expected %q to be rejected", value)
		}
	}
}

func TestBenchmarkProgramsMirrorComponentOwnedTargets(t *testing.T) {
	if len(nativeBenchmarkTargets) != len(nativeBenchmarkPrograms) {
		t.Fatalf("benchmark target count %d does not match program count %d", len(nativeBenchmarkTargets), len(nativeBenchmarkPrograms))
	}
	wantComponents := []string{"Codegen/Xmm", "Codegen/Xpp", "Core/Benches", "Core/CorePrep"}
	for _, component := range wantComponents {
		foundTarget := false
		foundProgram := false
		for _, target := range nativeBenchmarkTargets {
			foundTarget = foundTarget || strings.Contains(target, component)
		}
		for _, program := range nativeBenchmarkPrograms {
			foundProgram = foundProgram || strings.Contains(program, component)
		}
		if !foundTarget || !foundProgram {
			t.Fatalf("component %q is not represented by both benchmark surfaces", component)
		}
	}
}

func TestCriterionEnvironmentIsUnicodeCapable(t *testing.T) {
	want := []string{"GHC_CHARENC=UTF-8"}
	if got := criterionEnvironment(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Criterion environment = %#v, want %#v", got, want)
	}
}

func TestMergeEnvironmentReplacesPathInsteadOfAppendingDuplicates(t *testing.T) {
	got := mergeEnvironment([]string{"HOME=/tmp", "PATH=/old/bin", "EDITOR=vi"}, []string{"PATH=/bundle/bin"}, false)
	want := []string{"HOME=/tmp", "EDITOR=vi", "PATH=/bundle/bin"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("merged environment = %#v, want %#v", got, want)
	}
}

func TestMergeEnvironmentTreatsWindowsKeysCaseInsensitively(t *testing.T) {
	got := mergeEnvironment([]string{"Path=C:\\Windows", "TEMP=C:\\Temp"}, []string{"PATH=C:\\bundle"}, true)
	want := []string{"TEMP=C:\\Temp", "PATH=C:\\bundle"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("merged environment = %#v, want %#v", got, want)
	}
}

func TestSelectAddressSanitizerUsesHostSpecificProfile(t *testing.T) {
	windows, err := selectSanitizer(host{kind: hostWindows}, "asan")
	if err != nil {
		t.Fatal(err)
	}
	if windows.config != "asan-windows" || windows.name != "AddressSanitizer" {
		t.Fatalf("unexpected Windows sanitizer: %#v", windows)
	}

	macOS, err := selectSanitizer(host{kind: hostMacOS}, "address")
	if err != nil {
		t.Fatal(err)
	}
	if macOS.config != "asan-macos" || macOS.name != "AddressSanitizer" {
		t.Fatalf("unexpected macOS sanitizer: %#v", macOS)
	}
	if !reflect.DeepEqual(macOS.environment, []string{"ASAN_OPTIONS=halt_on_error=1:strict_string_checks=1:detect_container_overflow=0"}) {
		t.Fatalf("unexpected macOS AddressSanitizer environment: %#v", macOS.environment)
	}
	linux, err := selectSanitizer(host{kind: hostLinux}, "address")
	if err != nil || linux.config != "asan-linux" {
		t.Fatalf("unexpected Linux AddressSanitizer: %#v, %v", linux, err)
	}
}

func TestClassifyLinuxHostAcceptsThePinnedTierReleases(t *testing.T) {
	for _, test := range []struct {
		release string
		name    string
	}{
		{`ID=ubuntu` + "\n" + `VERSION_ID="26.04"`, "Ubuntu 26.04 LTS"},
		{`ID=fedora` + "\n" + `VERSION_ID=43`, "Fedora 43 (N-1)"},
	} {
		got, err := classifyLinuxHost(test.release)
		if err != nil || got.kind != hostLinux || got.name != test.name {
			t.Fatalf("classifyLinuxHost(%q) = %#v, %v", test.release, got, err)
		}
	}
	for _, release := range []string{`ID=ubuntu` + "\n" + `VERSION_ID=24.04`, `ID=fedora` + "\n" + `VERSION_ID=44`, `ID=arch`} {
		if _, err := classifyLinuxHost(release); err == nil {
			t.Fatalf("unsupported release %q was accepted", release)
		}
	}
}

func TestSelectSanitizerExplainsUnsupportedWindowsKinds(t *testing.T) {
	for _, kind := range []string{"thread"} {
		_, err := selectSanitizer(host{kind: hostWindows}, kind)
		if err == nil {
			t.Fatalf("expected %s to be rejected on Windows", kind)
		}
	}
}

func TestLinuxSanitizersUseClangProfiles(t *testing.T) {
	for _, test := range []struct{ name, config string }{
		{"undefined", "ubsan-linux"},
		{"thread", "tsan-linux"},
	} {
		got, err := selectSanitizer(host{kind: hostLinux}, test.name)
		if err != nil || got.config != test.config {
			t.Fatalf("Linux %s sanitizer = %#v, %v", test.name, got, err)
		}
	}
}

func TestSelectSanitizerRejectsUnknownName(t *testing.T) {
	_, err := selectSanitizer(host{kind: hostMacOS}, "memory")
	if err == nil {
		t.Fatal("expected an unknown sanitizer diagnostic")
	}
}

func TestFuzzConfigurationUsesOfficialHostCompiler(t *testing.T) {
	for _, test := range []struct {
		host hostKind
		want string
	}{
		{hostWindows, "fuzz-windows"},
		{hostMacOS, "fuzz-macos"},
		{hostLinux, "fuzz-linux"},
	} {
		got, err := fuzzConfiguration(host{kind: test.host})
		if err != nil || got != test.want {
			t.Fatalf("fuzz configuration for %v = %q, %v", test.host, got, err)
		}
	}
	if _, err := fuzzConfiguration(host{kind: hostUnsupported}); err == nil {
		t.Fatal("unsupported host unexpectedly received a fuzz configuration")
	}
}

func TestMacOSFuzzerRuntimeFindsOnlyHomebrewRuntime(t *testing.T) {
	root := t.TempDir()
	if _, err := macOSFuzzerRuntime(root); err == nil {
		t.Fatal("missing runtime was accepted")
	}
	runtime := filepath.Join(root, "lib", "clang", "22", "lib", "darwin", "libclang_rt.fuzzer_osx.a")
	if err := os.MkdirAll(filepath.Dir(runtime), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(runtime, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := macOSFuzzerRuntime(root); err != nil || got != runtime {
		t.Fatalf("runtime = %q, %v; want %q", got, err, runtime)
	}
}

func TestSuccessfulFuzzCleanupStaysInsideItsTemporaryRoot(t *testing.T) {
	root := t.TempDir()
	work, err := os.MkdirTemp(root, "tala-fuzz-")
	if err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(root, "unrelated")
	if err := os.Mkdir(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := removeSuccessfulFuzzWork(root, outside); err == nil {
		t.Fatal("cleanup accepted a directory it did not create")
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatalf("cleanup touched unrelated data: %v", err)
	}
	if err := removeSuccessfulFuzzWork(root, work); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(work); !os.IsNotExist(err) {
		t.Fatalf("successful fuzz work remains or cannot be checked: %v", err)
	}
}

func TestHelpSpellingsAreAccepted(t *testing.T) {
	for _, spelling := range []string{"--help", "-h"} {
		if !isHelp(spelling) {
			t.Fatalf("expected %q to be a help spelling", spelling)
		}
	}
	if isHelp("doctor") {
		t.Fatal("doctor is not a help spelling")
	}
	if isHelp("-Help") {
		t.Fatal("Go helper help must not inherit the talac flag spelling")
	}
}

type fakeRunner struct {
	paths map[string]string
}

func (runner fakeRunner) Run(string, []string, string, ...string) error {
	return errors.New("unexpected process execution")
}

func (runner fakeRunner) RunWithInput(string, []string, string, string, ...string) (string, error) {
	return "", errors.New("unexpected process execution")
}

func (runner fakeRunner) Output(string, ...string) (string, error) {
	return "", errors.New("not available")
}

func (runner fakeRunner) OutputIn(string, string, ...string) (string, error) {
	return "", errors.New("not available")
}

func (runner fakeRunner) LookPath(name string) (string, error) {
	if path, ok := runner.paths[name]; ok {
		return path, nil
	}
	return "", errors.New("not found")
}

func TestFindBazelPrefersBazelisk(t *testing.T) {
	runner := fakeRunner{paths: map[string]string{
		"bazelisk": "preferred-bazelisk",
		"bazel":    "fallback-bazel",
	}}
	path, err := findBazel(runner)
	if err != nil {
		t.Fatal(err)
	}
	if path != "preferred-bazelisk" {
		t.Fatalf("selected %q", path)
	}
}

func TestFindBazelFallsBackToBazel(t *testing.T) {
	runner := fakeRunner{paths: map[string]string{"bazel": "fallback-bazel"}}
	path, err := findBazel(runner)
	if err != nil {
		t.Fatal(err)
	}
	if path != "fallback-bazel" {
		t.Fatalf("selected %q", path)
	}
}

func TestLocateToolUsesPathBeforeEnvironmentDiscovery(t *testing.T) {
	runner := fakeRunner{paths: map[string]string{"llvm-config": "path-llvm-config"}}
	path, err := locateTool(runner, "llvm-config")
	if err != nil {
		t.Fatal(err)
	}
	if path != "path-llvm-config" {
		t.Fatalf("selected %q", path)
	}
}

func TestParseModuleVersionReadsOnlyTheRootModuleDeclaration(t *testing.T) {
	contents := `module(
    name = "tala",
    version = "0.3.6",
)
bazel_dep(name = "fmt", version = "12.1.0")`
	version, err := parseModuleVersion(contents)
	if err != nil {
		t.Fatal(err)
	}
	if version != "0.3.6" {
		t.Fatalf("version = %q", version)
	}
}

func TestParseModuleVersionRejectsMissingAndMalformedVersions(t *testing.T) {
	for _, contents := range []string{
		"module(\n    name = \"tala\",\n)",
		"module(\n    version = \"0.3\",\n)",
		"module(\n    version = \"0.next.0\",\n)",
		"module(\n    version = \"0.3.6\",\n    version = \"0.3.7\",\n)",
	} {
		if _, err := parseModuleVersion(contents); err == nil {
			t.Fatalf("expected version input to be rejected:\n%s", contents)
		}
	}
}

func TestValidateReleaseVersionRejectsAmbiguousSpellings(t *testing.T) {
	for _, version := range []string{"", "0.3", "0.3.6.1.2", "0.03.6", "0.3.9.05", "v0.3.6", "0.next.6"} {
		if err := validateReleaseVersion(version); err == nil {
			t.Fatalf("expected %q to be rejected", version)
		}
	}
	for _, version := range []string{"0.3.6", "0.3.9.5"} {
		if err := validateReleaseVersion(version); err != nil {
			t.Fatal(err)
		}
	}
}

func TestCheckFileLineOnceDoesNotAcceptLongerVersionPrefix(t *testing.T) {
	path := filepath.Join(t.TempDir(), "metadata.txt")
	contents := "version: 0.3.60\n## 0.3.60 - future\n"
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
	if check := checkFileLineOnce(path, "version: 0.3.6", false, "exact"); check.ok {
		t.Fatal("exact release line accepted a longer version")
	}
	if check := checkFileLineOnce(path, "## 0.3.6 - ", true, "heading"); check.ok {
		t.Fatal("release heading accepted a longer version")
	}
}

func TestDistributionPlatformUsesStablePublicNames(t *testing.T) {
	tests := []struct {
		host         host
		architecture string
		want         string
	}{
		{host: host{kind: hostWindows}, architecture: "amd64", want: "windows-x86_64"},
		{host: host{kind: hostWindows}, architecture: "arm64", want: "windows-arm64"},
		{host: host{kind: hostMacOS}, architecture: "amd64", want: "macos-x86_64"},
		{host: host{kind: hostMacOS}, architecture: "arm64", want: "macos-arm64"},
		{host: host{kind: hostLinux}, architecture: "amd64", want: "linux-x86_64"},
	}
	for _, test := range tests {
		got, err := distributionPlatform(test.host, test.architecture)
		if err != nil {
			t.Fatal(err)
		}
		if got != test.want {
			t.Fatalf("platform = %q, want %q", got, test.want)
		}
	}
	if _, err := distributionPlatform(host{kind: hostWindows}, "386"); err == nil {
		t.Fatal("expected unsupported architecture to be rejected")
	}
}

func TestValidateBundleTargetRejectsTargetsOutsideExactDistributionRoot(t *testing.T) {
	repository := t.TempDir()
	unsafeTargets := []string{
		filepath.Join(repository, "dist"),
		filepath.Join(repository, "dist", "other-product-0.3.6"),
		filepath.Join(repository, "dist", "nested", "tala-0.3.6-windows-x86_64"),
		filepath.Join(repository, "tala-0.3.6-windows-x86_64"),
	}
	for _, target := range unsafeTargets {
		if err := validateBundleTarget(repository, target); err == nil {
			t.Fatalf("expected unsafe target %q to be rejected", target)
		}
	}

	safe := filepath.Join(repository, "dist", "tala-0.3.6-windows-x86_64")
	if err := validateBundleTarget(repository, safe); err != nil {
		t.Fatal(err)
	}
	staging := filepath.Join(repository, "dist", ".staging")
	if err := os.MkdirAll(staging, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(staging, "verified.txt"), []byte("verified"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := publishBundleDirectory(repository, staging, safe); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(filepath.Join(safe, "verified.txt"))
	if err != nil || string(contents) != "verified" {
		t.Fatalf("verified staging content was not published: %q, %v", contents, err)
	}
}

func TestWriteBundleChecksumsIsSortedAndContentSensitive(t *testing.T) {
	bundle := t.TempDir()
	if err := os.MkdirAll(filepath.Join(bundle, "LICENSES"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bundle, "talac.exe"), []byte("compiler"), 0o755); err != nil {
		t.Fatal(err)
	}
	license := filepath.Join(bundle, "LICENSES", "exception.txt")
	if err := os.WriteFile(license, []byte("license"), 0o644); err != nil {
		t.Fatal(err)
	}
	files := []string{"talac.exe", "LICENSES/exception.txt"}
	if err := writeBundleChecksums(bundle, files); err != nil {
		t.Fatal(err)
	}
	first, err := os.ReadFile(filepath.Join(bundle, "SHA256SUMS"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(first)), "\n")
	if len(lines) != 2 || !strings.HasSuffix(lines[0], "  LICENSES/exception.txt") || !strings.HasSuffix(lines[1], "  talac.exe") {
		t.Fatalf("checksums are not deterministically sorted: %q", string(first))
	}
	if err := os.WriteFile(license, []byte("changed license"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeBundleChecksums(bundle, files); err != nil {
		t.Fatal(err)
	}
	second, err := os.ReadFile(filepath.Join(bundle, "SHA256SUMS"))
	if err != nil {
		t.Fatal(err)
	}
	if string(first) == string(second) {
		t.Fatal("checksum output did not change with file contents")
	}
}

func TestCleanGeneratedPathsPreservesUnlistedDistribution(t *testing.T) {
	repository := t.TempDir()
	generated := filepath.Join(repository, "Talac", "dist-newstyle", "nested")
	if err := os.MkdirAll(generated, 0o755); err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(repository, "dist", "tala-0.3.6-windows-x86_64")
	if err := os.MkdirAll(bundle, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := cleanGeneratedPaths(repository, []string{"Talac/dist-newstyle"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(repository, "Talac", "dist-newstyle")); !os.IsNotExist(err) {
		t.Fatalf("generated build directory survived cleanup: %v", err)
	}
	if information, err := os.Stat(bundle); err != nil || !information.IsDir() {
		t.Fatalf("unlisted distribution was removed: %v", err)
	}
}

func TestCleanGeneratedPathsRejectsRepositoryEscape(t *testing.T) {
	repository := t.TempDir()
	if err := cleanGeneratedPaths(repository, []string{"../outside"}); err == nil {
		t.Fatal("cleanup accepted a path outside the repository")
	}
}
