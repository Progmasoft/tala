// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// emptyHome points the home directory of the process at a new, empty
// directory. The installer looks for rustup under the home directory when it
// is not on PATH, and a machine that runs these tests may well have one
// there; what the tests assert must not depend on it.
func emptyHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	return home
}

func release(text string) func() (string, error) {
	return func() (string, error) { return text, nil }
}

// elevated is how a package manager is expected to be started by this
// process: directly as root, through sudo otherwise.
func elevated(command ...string) string {
	if os.Geteuid() == 0 {
		return strings.Join(command, " ")
	}
	return "sudo " + strings.Join(command, " ")
}

func commandLines(runner *fakePackageRunner) []string {
	lines := make([]string, 0, len(runner.commands))
	for _, command := range runner.commands {
		lines = append(lines, strings.Join(command, " "))
	}
	return lines
}

func TestThePlatformsAreThoseOfPrebuild(t *testing.T) {
	ubuntu := "NAME=\"Ubuntu\"\nID=ubuntu\nVERSION_ID=\"26.04\"\n"
	fedora := "NAME=\"Fedora Linux\"\r\nID=fedora\r\nVERSION_ID=43\r\n"
	cases := []struct {
		goos, release, want string
	}{
		{"windows", "", platformWindows},
		{"darwin", "", platformMacOS},
		{"linux", ubuntu, platformUbuntu},
		{"linux", fedora, platformFedora},
	}
	for _, entry := range cases {
		got, err := optionalPlatform(entry.goos, release(entry.release))
		if err != nil || got != entry.want {
			t.Errorf("optionalPlatform(%q) = %q (error %v), want %q", entry.goos, got, err, entry.want)
		}
	}
}

func TestOtherHostsAreRefusedWithTheHostsThatAreSupported(t *testing.T) {
	refused := map[string]func() (string, error){
		"an older Ubuntu":      release("ID=ubuntu\nVERSION_ID=\"24.04\"\n"),
		"a newer Fedora":       release("ID=fedora\nVERSION_ID=44\n"),
		"another distribution": release("ID=debian\nVERSION_ID=\"13\"\n"),
		"an empty description": release(""),
	}
	for name, read := range refused {
		_, err := optionalPlatform("linux", read)
		if err == nil || !strings.Contains(err.Error(), "Ubuntu 26.04 LTS, and Fedora 43") {
			t.Errorf("%s: error = %v, want one that lists the supported hosts", name, err)
		}
	}
	unreadable := errors.New("permission denied")
	if _, err := optionalPlatform("linux", func() (string, error) { return "", unreadable }); !errors.Is(err, unreadable) {
		t.Errorf("an unreadable os-release gave %v, want the read error", err)
	}
	if _, err := optionalPlatform("freebsd", release("")); err == nil || !strings.Contains(err.Error(), `"freebsd"`) {
		t.Errorf("another operating system gave %v, want it named", err)
	}
}

func TestEveryPackageHasANameOnEveryPlatform(t *testing.T) {
	for _, item := range optionalPackages {
		if item.wingetID == "" || item.homebrewFormula == "" || item.aptPackage == "" || item.dnfPackage == "" {
			t.Errorf("%s lacks a package on a supported platform: %+v", item.name, item)
		}
		if linuxPackage(item, platformUbuntu) != item.aptPackage || linuxPackage(item, platformFedora) != item.dnfPackage {
			t.Errorf("%s is not installed by its own package on Linux", item.name)
		}
	}
	if linuxManager(platformUbuntu) != "apt-get" || linuxManager(platformFedora) != "dnf" {
		t.Error("a Linux platform has the wrong package manager")
	}
}

func TestLinuxInstallsEachPackageWithTheManagerOfTheDistribution(t *testing.T) {
	for platform, manager := range map[string]string{platformUbuntu: "apt-get", platformFedora: "dnf"} {
		for _, item := range optionalPackages[:5] {
			runner := &fakePackageRunner{paths: map[string][]string{manager: {manager}, "sudo": {"sudo"}}}
			if err := installOneForOS(runner, item, platform); err != nil {
				t.Fatalf("%s on %s returned error: %v", item.name, platform, err)
			}
			want := elevated(manager, "install", "-y", linuxPackage(item, platform))
			if got := commandLines(runner); len(got) != 1 || got[0] != want {
				t.Fatalf("%s on %s ran %v, want %q", item.name, platform, got, want)
			}
		}
	}
}

func TestLinuxInstallNeedsTheManagerAndAWayToBecomeRoot(t *testing.T) {
	runner := &fakePackageRunner{paths: map[string][]string{"sudo": {"sudo"}}}
	err := installOneForOS(runner, optionalPackages[2], platformFedora)
	if err == nil || !strings.Contains(err.Error(), "dnf is required") {
		t.Fatalf("a host without dnf gave %v", err)
	}
	if len(runner.commands) != 0 {
		t.Fatalf("a host without dnf ran %v", runner.commands)
	}
	if os.Geteuid() == 0 {
		return
	}
	runner = &fakePackageRunner{paths: map[string][]string{"apt-get": {"apt-get"}}}
	err = installOneForOS(runner, optionalPackages[2], platformUbuntu)
	if err == nil || !strings.Contains(err.Error(), "sudo is required") {
		t.Fatalf("a host without sudo gave %v", err)
	}
	if len(runner.commands) != 0 {
		t.Fatalf("a host without sudo ran %v", runner.commands)
	}
}

func TestUbuntuRefreshesItsPackageListsOnceAndOnlyWhenItInstalls(t *testing.T) {
	// Nothing is missing: nothing is refreshed, nothing is installed.
	ready := readyPackageRunner()
	ready.paths["apt-get"] = []string{"apt-get"}
	ready.paths["sudo"] = []string{"sudo"}
	if err := installOptionalPackagesForOS(ready, platformUbuntu); err != nil {
		t.Fatalf("a ready host returned error: %v", err)
	}
	if len(ready.commands) != 0 {
		t.Fatalf("a ready host ran %v", ready.commands)
	}

	// Two packages are missing: one refresh, before the first of them.
	missing := readyPackageRunner()
	missing.paths["apt-get"] = []string{"apt-get"}
	missing.paths["sudo"] = []string{"sudo"}
	delete(missing.paths, "just")
	delete(missing.paths, "jq")
	if err := installOptionalPackagesForOS(missing, platformUbuntu); err != nil {
		t.Fatalf("install returned error: %v", err)
	}
	want := []string{
		elevated("apt-get", "update"),
		elevated("apt-get", "install", "-y", "just"),
		elevated("apt-get", "install", "-y", "jq"),
	}
	if got := commandLines(missing); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("ran %v, want %v", got, want)
	}
}

func TestFedoraInstallsWithoutRefreshingLists(t *testing.T) {
	runner := readyPackageRunner()
	runner.paths["dnf"] = []string{"dnf"}
	runner.paths["sudo"] = []string{"sudo"}
	delete(runner.paths, "rg")
	if err := installOptionalPackagesForOS(runner, platformFedora); err != nil {
		t.Fatalf("install returned error: %v", err)
	}
	want := elevated("dnf", "install", "-y", "ripgrep")
	if got := commandLines(runner); len(got) != 1 || got[0] != want {
		t.Fatalf("ran %v, want %q alone", got, want)
	}
}

func TestLinuxLeavesAnInstalledPackageAlone(t *testing.T) {
	for platform, probe := range map[string]string{platformUbuntu: "dpkg-query", platformFedora: "rpm"} {
		runner := &fakePackageRunner{paths: map[string][]string{probe: {probe}}, versions: map[string]string{}}
		// The probe answers for every package that it is installed.
		runner.versions[probe] = "install ok installed"
		if !packageAlreadyInstalled(runner, optionalPackages[2], platform) {
			t.Errorf("%s did not recognize an installed package", platform)
		}
		// Without the probe nothing can be said, so nothing is claimed.
		if packageAlreadyInstalled(&fakePackageRunner{}, optionalPackages[2], platform) {
			t.Errorf("%s claimed a package is installed without asking", platform)
		}
	}
	absent := &fakePackageRunner{paths: map[string][]string{"dpkg-query": {"dpkg-query"}}, versions: map[string]string{"dpkg-query": "deinstall ok config-files"}}
	if packageAlreadyInstalled(absent, optionalPackages[2], platformUbuntu) {
		t.Error("a removed package was taken for an installed one")
	}
}

func TestLinuxSetsRustupUpWithoutAToolchain(t *testing.T) {
	emptyHome(t)
	rust := optionalPackages[5]
	// The distribution packages the installer only: rustup-init appears,
	// rustup does not, and the installer is told to select no toolchain.
	runner := &fakePackageRunner{paths: map[string][]string{
		"dnf": {"dnf"}, "sudo": {"sudo"}, "rustup-init": {"rustup-init"},
	}}
	err := installRustComponentsForOS(runner, rust, platformFedora)
	got := commandLines(runner)
	want := []string{
		elevated("dnf", "install", "-y", "rustup"),
		"rustup-init -y --default-toolchain none --no-modify-path",
	}
	if len(got) < 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("ran %v, want %v first", got, want)
	}
	for _, line := range got {
		if strings.Contains(line, "toolchain install") || strings.Contains(line, "default stable") {
			t.Fatalf("a toolchain was installed: %q", line)
		}
	}
	// rustup is still not visible to this process, which is said and not
	// papered over.
	if err == nil || !strings.Contains(err.Error(), "not visible") {
		t.Fatalf("error = %v, want one that says rustup is not visible yet", err)
	}
}

func TestLinuxFindsRustupUnderTheHomeDirectoryAfterItsInstaller(t *testing.T) {
	home := emptyHome(t)
	// The installer puts rustup under the home directory and leaves PATH
	// alone, so this process finds it there and nowhere else.
	directory := filepath.Join(home, ".cargo", "bin")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatalf("create the cargo directory: %v", err)
	}
	if err := os.WriteFile(filepath.Join(directory, "rustup"), []byte("stand-in"), 0o700); err != nil {
		t.Fatalf("write the stand-in for rustup: %v", err)
	}
	rust := optionalPackages[5]
	runner := &fakePackageRunner{paths: map[string][]string{
		"apt-get": {"apt-get"}, "sudo": {"sudo"}, "rustup-init": {"rustup-init"},
	}}
	err := installRustComponentsForOS(runner, rust, platformUbuntu)
	// rustup was found, and it has no toolchain: the command says so and
	// creates none.
	if err == nil || !strings.Contains(err.Error(), "never installs toolchains") {
		t.Fatalf("error = %v, want a refusal to create a toolchain", err)
	}
	for _, line := range commandLines(runner) {
		if strings.Contains(line, "component add") || strings.Contains(line, "toolchain install") {
			t.Fatalf("a host without a toolchain ran %q", line)
		}
	}
}

func TestLinuxAddsComponentsToAnExistingToolchainOnly(t *testing.T) {
	rust := optionalPackages[5]
	runner := &fakePackageRunner{paths: map[string][]string{"rustup": {"rustup"}}, activeToolchain: true}
	if err := installRustComponentsForOS(runner, rust, platformUbuntu); err != nil {
		t.Fatalf("returned error: %v", err)
	}
	if got := commandLines(runner); len(got) != 1 || got[0] != "rustup component add rustc rust-std" {
		t.Fatalf("ran %v, want the components alone", got)
	}
	without := &fakePackageRunner{paths: map[string][]string{"rustup": {"rustup"}}}
	err := installRustComponentsForOS(without, rust, platformUbuntu)
	if err == nil || !strings.Contains(err.Error(), "never installs toolchains") {
		t.Fatalf("error = %v, want a refusal to create a toolchain", err)
	}
	if len(without.commands) != 0 {
		t.Fatalf("a host without a toolchain ran %v", without.commands)
	}
}
