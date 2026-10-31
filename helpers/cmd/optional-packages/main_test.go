// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import (
	"errors"
	"strings"
	"testing"
)

type fakePackageRunner struct {
	paths             map[string][]string
	versions          map[string]string
	components        string
	activeToolchain   bool
	installedPackages map[string]bool
	installedFormulas map[string]bool
	commands          [][]string
}

func (runner *fakePackageRunner) lookPaths(name string) []string {
	return runner.paths[name]
}

func (runner *fakePackageRunner) output(name string, args ...string) (string, error) {
	if name == "rustup" && len(args) == 3 && args[0] == "component" && args[1] == "list" {
		return runner.components, nil
	}
	if name == "rustup" && len(args) == 2 && args[0] == "show" && args[1] == "active-toolchain" && runner.activeToolchain {
		return "nightly-x86_64-pc-windows-msvc (active, default)", nil
	}
	if name == "winget" && len(args) >= 3 && args[0] == "list" {
		packageID := args[2]
		if runner.installedPackages[packageID] {
			return "Name Id Version\n" + packageID + " 1.0", nil
		}
		return "No installed package found", errors.New("not installed")
	}
	if name == "brew" && len(args) == 3 && args[0] == "list" {
		formula := args[2]
		if runner.installedFormulas[formula] {
			return formula, nil
		}
		return "", errors.New("not installed")
	}
	version, found := runner.versions[name]
	if !found {
		return "", errors.New("no version output")
	}
	return version, nil
}

func (runner *fakePackageRunner) run(name string, args ...string) error {
	command := append([]string{name}, args...)
	runner.commands = append(runner.commands, command)
	return nil
}

func TestCheckAcceptsAllRequiredOptionalToolchains(t *testing.T) {
	runner := readyPackageRunner()
	if err := checkOptionalPackages(runner); err != nil {
		t.Fatalf("checkOptionalPackages rejected a complete installation: %v", err)
	}
}

func TestCheckReportsEveryMissingToolchain(t *testing.T) {
	runner := &fakePackageRunner{paths: map[string][]string{}, versions: map[string]string{}}
	err := checkOptionalPackages(runner)
	if err == nil || !strings.Contains(err.Error(), "6 optional toolchain(s) missing") {
		t.Fatalf("expected one aggregate error for all missing tools, got %v", err)
	}
}

func TestRustComponentCheckRequiresRustcAndHostStandardLibrary(t *testing.T) {
	item := optionalPackages[len(optionalPackages)-1]
	runner := readyPackageRunner()
	runner.components = "rustc-x86_64-pc-windows-msvc\n"
	if _, _, ready := findReadyTool(runner, item); ready {
		t.Fatal("rustc without rust-std was considered a complete benchmark toolchain")
	}
	runner.components += "rust-std-x86_64-pc-windows-msvc\n"
	if _, _, ready := findReadyTool(runner, item); !ready {
		t.Fatal("installed rustc and host rust-std components were not accepted")
	}
}

func TestVersionChecksRejectWrongMajorSDKAndNonGNUFortran(t *testing.T) {
	runner := readyPackageRunner()
	runner.versions["dotnet"] = "9.0.300 [C:\\dotnet]"
	runner.versions["gfortran"] = "GNU Fortran (GCC) 13.2.0"
	if err := checkOptionalPackages(runner); err == nil {
		t.Fatal("check accepted mismatched .NET and Fortran toolchains")
	}
}

func TestCheckFindsNewCompilerAfterOlderSystemCompiler(t *testing.T) {
	runner := readyPackageRunner()
	runner.paths["gfortran"] = []string{"old-gfortran", "new-gfortran"}
	runner.versions["old-gfortran"] = "GNU Fortran (GCC) 13.2.0"
	runner.versions["new-gfortran"] = "GNU Fortran (GCC) 16.1.0"
	if err := checkOptionalPackages(runner); err != nil {
		t.Fatalf("check did not discover the Fortran 2023-capable compiler later on PATH: %v", err)
	}
}

func TestInstallUsesPackageManagerDefaultScopeAndDoesNotInstallRustToolchain(t *testing.T) {
	runner := &fakePackageRunner{
		paths: map[string][]string{
			"rustup": {"rustup"},
			"winget": {"winget"},
			"brew":   {"brew"},
		},
		versions: map[string]string{
			"rustup": "rustup 1.29.1",
		},
		activeToolchain: true,
	}
	for _, item := range optionalPackages[:2] {
		if err := installOneForOS(runner, item, "windows"); err != nil {
			t.Fatalf("install command orchestration failed for %s: %v", item.name, err)
		}
	}
	if err := installRustComponentsForOS(runner, optionalPackages[len(optionalPackages)-1], "windows"); err != nil {
		t.Fatal(err)
	}
	if len(runner.commands) != 3 {
		t.Fatalf("got %d install/component commands, want 3", len(runner.commands))
	}
	for _, command := range runner.commands {
		joined := strings.Join(command, " ")
		if strings.Contains(joined, "--scope") {
			t.Errorf("installer overrides the package manager's default scope: %s", joined)
		}
		if !strings.Contains(joined, "install") && !strings.Contains(joined, "component add rustc rust-std") {
			t.Errorf("unexpected install command: %s", joined)
		}
	}
	for _, command := range runner.commands {
		if strings.Contains(strings.Join(command, " "), "toolchain install") {
			t.Fatal("optional installer tried to install or select a Rust toolchain")
		}
	}
}

func TestRustComponentInstallerRefusesToCreateToolchain(t *testing.T) {
	runner := &fakePackageRunner{paths: map[string][]string{"rustup": {"rustup"}}}
	err := installRustComponentsForOS(runner, optionalPackages[len(optionalPackages)-1], "windows")
	if err == nil || !strings.Contains(err.Error(), "never installs toolchains") {
		t.Fatalf("missing active toolchain was not explained: %v", err)
	}
	if len(runner.commands) != 0 {
		t.Fatalf("installer attempted component work without a selected toolchain: %#v", runner.commands)
	}
}

func TestRustupBootstrapExplicitlyUsesNoDefaultToolchain(t *testing.T) {
	arguments := rustupManagerWingetArguments("Rustlang.Rustup")
	joined := strings.Join(arguments, " ")
	if !strings.Contains(joined, "--override -y --default-toolchain none") {
		t.Fatalf("rustup bootstrap does not suppress default toolchain installation: %q", joined)
	}
	if strings.Contains(joined, "toolchain install") {
		t.Fatalf("rustup bootstrap must never install a Rust toolchain: %q", joined)
	}
}

func TestOptionalInstallRecognizesAnAlreadyInstalledWinGetPackage(t *testing.T) {
	runner := &fakePackageRunner{
		paths:             map[string][]string{"winget": {"winget"}},
		installedPackages: map[string]bool{"Microsoft.DotNet.SDK.10": true},
	}
	if !packageAlreadyInstalled(runner, optionalPackages[0], "windows") {
		t.Fatal("already installed WinGet package was not detected")
	}
}

func TestOptionalInstallSkipsInstalledPackagesAndContinues(t *testing.T) {
	runner := readyPackageRunner()
	runner.paths["winget"] = []string{"winget"}
	runner.paths["brew"] = []string{"brew"}
	runner.versions["dotnet"] = "9.0.300 [C:\\dotnet]"
	runner.versions["gfortran"] = "GNU Fortran (GCC) 13.2.0"
	runner.installedPackages = map[string]bool{
		"Microsoft.DotNet.SDK.10":          true,
		"BrechtSanders.WinLibs.POSIX.UCRT": true,
	}
	runner.installedFormulas = map[string]bool{
		"dotnet@10": true,
		"gcc":       true,
	}
	if err := installOptionalPackagesForOS(runner, "windows"); err != nil {
		t.Fatalf("already-installed packages should be skipped without aborting install: %v", err)
	}
	if len(runner.commands) != 0 {
		t.Fatalf("installer reran package commands for present packages: %#v", runner.commands)
	}
}

func TestOptionalInstallRejectsUnsupportedOperatingSystem(t *testing.T) {
	runner := readyPackageRunner()
	err := installOptionalPackagesForOS(runner, "linux")
	if err == nil || !strings.Contains(err.Error(), `unsupported operating system "linux"`) {
		t.Fatalf("Linux install result = %v, want explicit unsupported-host error", err)
	}
	if len(runner.commands) != 0 {
		t.Fatalf("unsupported host issued package-manager commands: %#v", runner.commands)
	}
}

func TestInstallOneUsesHomebrewOnlyForMacOS(t *testing.T) {
	runner := &fakePackageRunner{paths: map[string][]string{"brew": {"brew"}}}
	if err := installOneForOS(runner, optionalPackages[0], "darwin"); err != nil {
		t.Fatalf("macOS package install returned error: %v", err)
	}
	if len(runner.commands) != 1 || strings.Join(runner.commands[0], " ") != "brew install dotnet@10" {
		t.Fatalf("macOS install commands = %#v, want Homebrew formula", runner.commands)
	}
	if err := installOneForOS(runner, optionalPackages[0], "linux"); err == nil {
		t.Fatal("Linux unexpectedly selected a macOS package-manager command")
	}
}

func TestDeveloperUtilityPackageManagers(t *testing.T) {
	for _, item := range optionalPackages[2:5] {
		t.Run(item.executable, func(t *testing.T) {
			for _, goos := range []string{"windows", "darwin"} {
				runner := &fakePackageRunner{paths: map[string][]string{
					"winget": {"winget"}, "brew": {"brew"},
				}}
				if err := installOneForOS(runner, item, goos); err != nil {
					t.Fatal(err)
				}
				if len(runner.commands) != 1 {
					t.Fatalf("expected exactly one installation: %#v", runner.commands)
				}
				command := strings.Join(runner.commands[0], " ")
				if goos == "windows" && !strings.Contains(command, "--id "+item.wingetID+" --exact") {
					t.Fatalf("wrong exact WinGet identity: %s", command)
				}
				if goos == "darwin" && command != "brew install "+item.homebrewFormula {
					t.Fatalf("wrong Homebrew formula: %s", command)
				}
			}
		})
	}
}

func TestDeveloperUtilitiesRejectUnrelatedVersionOutput(t *testing.T) {
	for _, item := range optionalPackages[2:5] {
		runner := readyPackageRunner()
		runner.versions[item.executable] = "unrelated program 1.0.0"
		if _, _, ready := findReadyTool(runner, item); ready {
			t.Fatalf("accepted unrelated version output for %s", item.executable)
		}
	}
}

func readyPackageRunner() *fakePackageRunner {
	return &fakePackageRunner{
		paths: map[string][]string{
			"dotnet":   {"dotnet"},
			"gfortran": {"gfortran"},
			"rustup":   {"rustup"},
			"rustc":    {"rustc"},
			"just":     {"just"},
			"rg":       {"rg"},
			"jq":       {"jq"},
		},
		versions: map[string]string{
			"dotnet":   "10.0.401 [C:\\dotnet]",
			"gfortran": "GNU Fortran (GCC) 16.1.0",
			"rustup":   "rustup 1.29.1",
			"just":     "just 1.46.0",
			"rg":       "ripgrep 15.1.0\nfeatures:+pcre2",
			"jq":       "jq-1.8.1",
		},
		components:      "rustc-x86_64-pc-windows-msvc\nrust-std-x86_64-pc-windows-msvc\n",
		activeToolchain: true,
	}
}
