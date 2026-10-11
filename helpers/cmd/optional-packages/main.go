// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// optional_packages installs or checks optional developer tools and toolchains
// used for examples and comparative benchmarks. It deliberately does not change the
// repository's core compiler requirements.
package main

import (
	"errors"
	"fmt"
	"github.com/spf13/cobra"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

const optionalPackagesUsage = `Optional Visual X# developer packages

Supported hosts are those of prebuild: Windows 10/11, macOS 15/26, Ubuntu
26.04 LTS, and Fedora 43. Windows uses WinGet defaults, macOS uses Homebrew,
Ubuntu uses apt and Fedora uses dnf. Package managers choose their recommended
installation scope. Rustup may manage components only for an
already-installed toolchain; this command never installs a toolchain.`

// The hosts this command installs on. They are the hosts prebuild supports:
// a machine that can be prepared to build the compiler can be given the
// optional toolchains as well.
const (
	platformWindows = "windows"
	platformMacOS   = "darwin"
	platformUbuntu  = "ubuntu"
	platformFedora  = "fedora"
)

const supportedPlatformsText = "Windows 10/11, macOS 15/26, Ubuntu 26.04 LTS, and Fedora 43"

// optionalPlatform names the host the way the installers select by. Windows
// and macOS are their operating system; a Linux host is its distribution,
// read from the os-release text, and only the releases prebuild supports.
func optionalPlatform(goos string, release func() (string, error)) (string, error) {
	switch goos {
	case "windows":
		return platformWindows, nil
	case "darwin":
		return platformMacOS, nil
	case "linux":
		contents, err := release()
		if err != nil {
			return "", fmt.Errorf("cannot identify the Linux distribution: %w", err)
		}
		fields := make(map[string]string)
		for _, line := range strings.Split(contents, "\n") {
			key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
			if ok {
				fields[key] = strings.Trim(value, `"`)
			}
		}
		switch {
		case fields["ID"] == "ubuntu" && fields["VERSION_ID"] == "26.04":
			return platformUbuntu, nil
		case fields["ID"] == "fedora" && fields["VERSION_ID"] == "43":
			return platformFedora, nil
		}
		return "", fmt.Errorf("unsupported Linux release %q %q; supported hosts are %s",
			fields["ID"], fields["VERSION_ID"], supportedPlatformsText)
	default:
		return "", unsupportedPlatform(goos)
	}
}

func readOSRelease() (string, error) {
	contents, err := os.ReadFile("/etc/os-release")
	return string(contents), err
}

func unsupportedPlatform(platform string) error {
	return fmt.Errorf("unsupported operating system %q; supported hosts are %s", platform, supportedPlatformsText)
}

func supportedPlatform(platform string) bool {
	switch platform {
	case platformWindows, platformMacOS, platformUbuntu, platformFedora:
		return true
	default:
		return false
	}
}

// linuxManager is the package manager of a Linux platform.
func linuxManager(platform string) string {
	if platform == platformFedora {
		return "dnf"
	}
	return "apt-get"
}

// linuxPackage is the distribution's package of an item, or nothing when the
// item has none there.
func linuxPackage(item optionalPackage, platform string) string {
	if platform == platformFedora {
		return item.dnfPackage
	}
	return item.aptPackage
}

// runLinuxManager runs the distribution's package manager, through sudo when
// the process is not root. The manager and sudo are looked for first, so a
// host without them gets a sentence and not a failed command.
func runLinuxManager(runner packageRunner, platform string, arguments ...string) error {
	manager := linuxManager(platform)
	if len(runner.lookPaths(manager)) == 0 {
		return fmt.Errorf("%s is required to install packages on this host", manager)
	}
	if os.Geteuid() == 0 {
		return runner.run(manager, arguments...)
	}
	if len(runner.lookPaths("sudo")) == 0 {
		return errors.New("sudo is required to install distribution packages as a non-root user")
	}
	return runner.run("sudo", append([]string{manager}, arguments...)...)
}

type optionalPackage struct {
	name                string
	executable          string
	wingetID            string
	homebrewFormula     string
	aptPackage          string
	dnfPackage          string
	versionArgs         []string
	versionPattern      *regexp.Regexp
	versionNote         string
	requiredExecutables []string
	requiredComponents  []*regexp.Regexp
	homebrewCask        bool
}

var optionalPackages = []optionalPackage{
	{
		name: "Microsoft .NET 10 SDK", executable: "dotnet",
		wingetID: "Microsoft.DotNet.SDK.10", homebrewFormula: "dotnet@10",
		aptPackage: "dotnet-sdk-10.0", dnfPackage: "dotnet-sdk-10.0",
		versionArgs:    []string{"--list-sdks"},
		versionPattern: regexp.MustCompile(`(?m)^10\.[0-9]+\.[0-9]+`),
		versionNote:    "SDK major version 10",
	},
	{
		name: "GNU Fortran", executable: "gfortran",
		wingetID:        "BrechtSanders.WinLibs.POSIX.UCRT",
		homebrewFormula: "gcc",
		aptPackage:      "gfortran", dnfPackage: "gcc-gfortran",
		versionArgs:    []string{"--version"},
		versionPattern: regexp.MustCompile(`(?i)GNU Fortran.*(14\.[1-9]|14\.[1-9][0-9]+|1[5-9]\.[0-9]+|[2-9][0-9]\.[0-9]+)`),
		versionNote:    "GNU Fortran 14.1+ with Fortran 2023 mode",
	},
	{
		name: "just", executable: "just",
		wingetID: "Casey.Just", homebrewFormula: "just",
		aptPackage: "just", dnfPackage: "just",
		versionArgs:    []string{"--version"},
		versionPattern: regexp.MustCompile(`(?m)^just\s+[0-9]+\.[0-9]+\.[0-9]+`),
		versionNote:    "just recipe runner",
	},
	{
		name: "ripgrep", executable: "rg",
		wingetID: "BurntSushi.ripgrep.MSVC", homebrewFormula: "ripgrep",
		aptPackage: "ripgrep", dnfPackage: "ripgrep",
		versionArgs:    []string{"--version"},
		versionPattern: regexp.MustCompile(`(?m)^ripgrep\s+[0-9]+\.[0-9]+\.[0-9]+`),
		versionNote:    "ripgrep search tool",
	},
	{
		name: "jq", executable: "jq",
		wingetID: "jqlang.jq", homebrewFormula: "jq",
		aptPackage: "jq", dnfPackage: "jq",
		versionArgs:    []string{"--version"},
		versionPattern: regexp.MustCompile(`(?m)^jq-[0-9]+\.[0-9]+(?:\.[0-9]+)?`),
		versionNote:    "jq JSON processor",
	},
	{
		name: "rustup, rustc, and rust-std", executable: "rustup",
		wingetID: "Rustlang.Rustup", homebrewFormula: "rustup",
		aptPackage: "rustup", dnfPackage: "rustup",
		versionArgs:         []string{"--version"},
		versionPattern:      regexp.MustCompile(`(?i)^rustup\s+[0-9]+\.[0-9]+\.[0-9]+`),
		versionNote:         "rustup manager with rustc and host rust-std installed on the active toolchain",
		requiredExecutables: []string{"rustc"},
		requiredComponents: []*regexp.Regexp{
			regexp.MustCompile(`(?m)^rustc(?:-[A-Za-z0-9_-]+)?$`),
			regexp.MustCompile(`(?m)^rust-std(?:-[A-Za-z0-9_-]+)?$`),
		},
	},
}

type packageRunner interface {
	lookPaths(string) []string
	output(string, ...string) (string, error)
	run(string, ...string) error
}

type systemPackageRunner struct{}

func (systemPackageRunner) lookPaths(name string) []string {
	paths := make([]string, 0, 4)
	seen := make(map[string]struct{})
	appendPath := func(path string) {
		key := strings.ToLower(filepath.Clean(path))
		if _, exists := seen[key]; !exists {
			seen[key] = struct{}{}
			paths = append(paths, path)
		}
	}
	if path, err := exec.LookPath(name); err == nil {
		appendPath(path)
	}
	if runtime.GOOS == "windows" && (name == "rustup" || name == "rustc") {
		if home, err := os.UserHomeDir(); err == nil {
			appendPath(filepath.Join(home, ".cargo", "bin", name+".exe"))
		}
	}
	if runtime.GOOS == "darwin" && name == "rustup" {
		if brew, err := exec.LookPath("brew"); err == nil {
			prefix, outputErr := exec.Command(brew, "--prefix", "rustup").Output()
			if outputErr == nil {
				candidate := filepath.Join(strings.TrimSpace(string(prefix)), "bin", "rustup")
				if information, statErr := os.Stat(candidate); statErr == nil && !information.IsDir() {
					appendPath(candidate)
				}
			}
		}
	}

	// Search every PATH directory instead of trusting LookPath's first hit.
	// Older system compilers can precede newer package-manager installs.
	extensions := []string{""}
	if runtime.GOOS == "windows" && filepath.Ext(name) == "" {
		extensions = extensions[:0]
		for _, extension := range strings.Split(os.Getenv("PATHEXT"), ";") {
			if extension != "" {
				extensions = append(extensions, strings.ToLower(extension))
			}
		}
		if len(extensions) == 0 {
			extensions = []string{".exe", ".cmd", ".bat"}
		}
	}
	for _, directory := range filepath.SplitList(os.Getenv("PATH")) {
		if strings.TrimSpace(directory) == "" {
			continue
		}
		for _, extension := range extensions {
			candidate := filepath.Join(directory, name+extension)
			info, err := os.Stat(candidate)
			if err == nil && !info.IsDir() {
				appendPath(candidate)
			}
		}
	}
	return paths
}

func (systemPackageRunner) output(name string, args ...string) (string, error) {
	command := exec.Command(name, args...)
	output, err := command.CombinedOutput()
	return strings.TrimSpace(string(output)), err
}

func (systemPackageRunner) run(name string, args ...string) error {
	command := exec.Command(name, args...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}

func main() {
	if err := runOptionalPackages(os.Args[1:], systemPackageRunner{}); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

// newOptionalPackagesCommand owns the command line. Parsing is separate from
// the package work, so an invalid invocation installs and probes nothing.
func newOptionalPackagesCommand(runner packageRunner, output, errorOutput io.Writer) *cobra.Command {
	root := &cobra.Command{
		Use:           "optional-packages",
		Short:         "Check or install the optional Visual X# developer packages.",
		Long:          optionalPackagesUsage,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE:          func(cmd *cobra.Command, args []string) error { return cmd.Help() },
	}
	root.SetOut(output)
	root.SetErr(errorOutput)
	root.CompletionOptions.DisableDefaultCmd = true
	root.AddCommand(
		&cobra.Command{
			Use:   "install",
			Short: "Install missing .NET 10, GNU Fortran, just, ripgrep, jq, and rustup components.",
			Args:  cobra.NoArgs,
			RunE:  func(cmd *cobra.Command, args []string) error { return installOptionalPackages(runner) },
		},
		&cobra.Command{
			Use:   "check",
			Short: "Check those tools, including rustc and rust-std on the active toolchain.",
			Args:  cobra.NoArgs,
			RunE:  func(cmd *cobra.Command, args []string) error { return checkOptionalPackages(runner) },
		},
	)
	return root
}

func runOptionalPackages(args []string, runner packageRunner) error {
	command := newOptionalPackagesCommand(runner, os.Stdout, os.Stderr)
	command.SetArgs(args)
	return command.Execute()
}

func checkOptionalPackages(runner packageRunner) error {
	missing := make([]string, 0, len(optionalPackages))
	for _, item := range optionalPackages {
		path, version, ready := findReadyTool(runner, item)
		if !ready && len(runner.lookPaths(item.executable)) == 0 {
			location := item.executable + " not found on PATH"
			fmt.Printf("MISSING  %s (%s)\n", item.name, location)
			missing = append(missing, item.name)
			continue
		}
		if !ready {
			fmt.Printf("MISSING  %s (found %s, but %s was not detected)\n", item.name, path, item.versionNote)
			missing = append(missing, item.name)
			continue
		}
		fmt.Printf("READY    %s: %s [%s]\n", item.name, firstMatchingLine(version, item.versionPattern), path)
	}
	if len(missing) != 0 {
		return fmt.Errorf("%d optional toolchain(s) missing; run `go run ./helpers/cmd/optional-packages install`", len(missing))
	}
	return nil
}

func findReadyTool(runner packageRunner, item optionalPackage) (string, string, bool) {
	paths := runner.lookPaths(item.executable)
	for _, path := range paths {
		if !requiredToolsPresent(runner, item) {
			continue
		}
		if len(item.requiredComponents) != 0 {
			components, err := runner.output(path, "component", "list", "--installed")
			if err != nil || !allPatternsMatch(components, item.requiredComponents) {
				continue
			}
		}
		version, err := runner.output(path, item.versionArgs...)
		if err == nil && item.versionPattern.MatchString(version) {
			return path, version, true
		}
	}
	if len(paths) != 0 {
		return paths[0], "", false
	}
	return "", "", false
}

func requiredToolsPresent(runner packageRunner, item optionalPackage) bool {
	for _, executable := range item.requiredExecutables {
		if len(runner.lookPaths(executable)) == 0 {
			return false
		}
	}
	return true
}

func allPatternsMatch(value string, patterns []*regexp.Regexp) bool {
	for _, pattern := range patterns {
		if !pattern.MatchString(value) {
			return false
		}
	}
	return true
}

func firstMatchingLine(output string, pattern *regexp.Regexp) string {
	for _, line := range strings.Split(output, "\n") {
		if pattern.MatchString(line) {
			return strings.TrimSpace(line)
		}
	}
	return "version available"
}

func installOptionalPackages(runner packageRunner) error {
	platform, err := optionalPlatform(runtime.GOOS, readOSRelease)
	if err != nil {
		return err
	}
	return installOptionalPackagesForOS(runner, platform)
}

// installOptionalPackagesForOS keeps platform selection explicit so the
// package-manager workflow of every supported host can be verified on any of
// them without installing software.
func installOptionalPackagesForOS(runner packageRunner, goos string) error {
	if !supportedPlatform(goos) {
		return unsupportedPlatform(goos)
	}

	// apt installs from the package lists it has; they are refreshed once,
	// before the first package that is actually installed.
	listsRefreshed := goos != platformUbuntu
	refreshLists := func() error {
		if listsRefreshed {
			return nil
		}
		listsRefreshed = true
		if err := runLinuxManager(runner, goos, "update"); err != nil {
			return fmt.Errorf("cannot refresh the apt package lists: %w", err)
		}
		return nil
	}

	var failures []string
	for _, item := range optionalPackages {
		if _, _, ready := findReadyTool(runner, item); ready {
			fmt.Printf("SKIP     %s already available\n", item.name)
			continue
		}
		if err := refreshLists(); err != nil {
			return err
		}
		if len(item.requiredComponents) != 0 {
			if err := installRustComponentsForOS(runner, item, goos); err != nil {
				failures = append(failures, fmt.Sprintf("%s: %v", item.name, err))
			} else {
				fmt.Printf("INSTALLED %s components on the selected toolchain\n", item.name)
			}
			continue
		}
		if installed := packageAlreadyInstalled(runner, item, goos); installed {
			fmt.Printf("SKIP     %s package is already installed; leaving it unchanged\n", item.name)
			continue
		}
		if err := installOneForOS(runner, item, goos); err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", item.name, err))
		} else {
			fmt.Printf("INSTALLED %s\n", item.name)
		}
	}
	if len(failures) != 0 {
		return fmt.Errorf("some installations failed:\n- %s", strings.Join(failures, "\n- "))
	}
	fmt.Println("Installation commands completed. Open a new terminal, then run `go run ./helpers/cmd/optional-packages check`.")
	return nil
}

func packageAlreadyInstalled(runner packageRunner, item optionalPackage, goos string) bool {
	switch goos {
	case "windows":
		if item.wingetID == "" || len(runner.lookPaths("winget")) == 0 {
			return false
		}
		listing, err := runner.output("winget", "list", "--id", item.wingetID, "--exact", "--source", "winget", "--disable-interactivity")
		return err == nil && strings.Contains(strings.ToLower(listing), strings.ToLower(item.wingetID))
	case "darwin":
		if item.homebrewFormula == "" || len(runner.lookPaths("brew")) == 0 {
			return false
		}
		arguments := []string{"list", "--formula", item.homebrewFormula}
		if item.homebrewCask {
			arguments[1] = "--cask"
		}
		_, err := runner.output("brew", arguments...)
		return err == nil
	case platformUbuntu:
		name := linuxPackage(item, goos)
		if name == "" || len(runner.lookPaths("dpkg-query")) == 0 {
			return false
		}
		status, err := runner.output("dpkg-query", "--show", "--showformat=${Status}", name)
		return err == nil && strings.Contains(status, "install ok installed")
	case platformFedora:
		name := linuxPackage(item, goos)
		if name == "" || len(runner.lookPaths("rpm")) == 0 {
			return false
		}
		_, err := runner.output("rpm", "--query", name)
		return err == nil
	default:
		return false
	}
}

func installRustComponents(runner packageRunner, item optionalPackage) error {
	platform, err := optionalPlatform(runtime.GOOS, readOSRelease)
	if err != nil {
		return err
	}
	return installRustComponentsForOS(runner, item, platform)
}

func installRustComponentsForOS(runner packageRunner, item optionalPackage, goos string) error {
	if !supportedPlatform(goos) {
		return unsupportedPlatform(goos)
	}
	paths := runner.lookPaths("rustup")
	if len(paths) == 0 {
		if packageAlreadyInstalled(runner, item, goos) {
			return errors.New("the rustup package is already installed but its command is not visible; repair PATH instead of reinstalling it")
		}
		if goos == "windows" {
			if len(runner.lookPaths("winget")) == 0 {
				return errors.New("winget is required to install the rustup manager")
			}
			// The explicit no-toolchain option is essential: installing the
			// manager must not silently choose stable or another channel.
			if err := runner.run("winget", rustupManagerWingetArguments(item.wingetID)...); err != nil {
				return fmt.Errorf("cannot install rustup without selecting a toolchain: %w", err)
			}
		} else if goos == "darwin" {
			if len(runner.lookPaths("brew")) == 0 {
				return errors.New("Homebrew is required to install rustup")
			}
			if err := runner.run("brew", "install", item.homebrewFormula); err != nil {
				return fmt.Errorf("cannot install the rustup manager: %w", err)
			}
		} else {
			if err := runLinuxManager(runner, goos, "install", "-y", linuxPackage(item, goos)); err != nil {
				return fmt.Errorf("cannot install the rustup manager: %w", err)
			}
			// Some distributions package the installer of rustup and not
			// rustup itself. The installer is told to select no toolchain,
			// like the Windows one, and to leave the shell profile alone.
			if len(runner.lookPaths("rustup")) == 0 && len(runner.lookPaths("rustup-init")) != 0 {
				if err := runner.run("rustup-init", rustupInitArguments()...); err != nil {
					return fmt.Errorf("cannot set up rustup without selecting a toolchain: %w", err)
				}
			}
		}
		paths = runner.lookPaths("rustup")
		if len(paths) == 0 && (goos == platformUbuntu || goos == platformFedora) {
			if home, err := os.UserHomeDir(); err == nil {
				candidate := filepath.Join(home, ".cargo", "bin", "rustup")
				if information, statErr := os.Stat(candidate); statErr == nil && !information.IsDir() {
					paths = append(paths, candidate)
				}
			}
		}
		if len(paths) == 0 && goos == "windows" {
			if home, err := os.UserHomeDir(); err == nil {
				candidate := filepath.Join(home, ".cargo", "bin", "rustup.exe")
				if information, statErr := os.Stat(candidate); statErr == nil && !information.IsDir() {
					paths = append(paths, candidate)
				}
			}
		}
		if len(paths) == 0 {
			return errors.New("rustup was installed but is not visible to this process; open a new terminal and rerun install")
		}
	}

	if _, err := runner.output(paths[0], "show", "active-toolchain"); err != nil {
		return errors.New("rustup is installed, but there is no active toolchain; choose or install one yourself, then rerun install (this script never installs toolchains)")
	}
	return runner.run(paths[0], "component", "add", "rustc", "rust-std")
}

func rustupManagerWingetArguments(packageID string) []string {
	return []string{
		"install", "--id", packageID, "--exact", "--source", "winget",
		"--accept-source-agreements", "--accept-package-agreements",
		"--override", "-y --default-toolchain none",
	}
}

// rustupInitArguments set rustup up without a toolchain and without editing
// the shell profile of the user.
func rustupInitArguments() []string {
	return []string{"-y", "--default-toolchain", "none", "--no-modify-path"}
}

func installOne(runner packageRunner, item optionalPackage) error {
	platform, err := optionalPlatform(runtime.GOOS, readOSRelease)
	if err != nil {
		return err
	}
	return installOneForOS(runner, item, platform)
}

func installOneForOS(runner packageRunner, item optionalPackage, goos string) error {
	if goos == "windows" {
		if len(runner.lookPaths("winget")) == 0 {
			return errors.New("winget is required on Windows; install App Installer from Microsoft Store, then retry")
		}
		args := []string{
			"install", "--id", item.wingetID, "--exact",
			"--source", "winget", "--accept-source-agreements",
			"--accept-package-agreements",
		}
		return runner.run("winget", args...)
	} else if goos == platformUbuntu || goos == platformFedora {
		name := linuxPackage(item, goos)
		if name == "" {
			return fmt.Errorf("no %s package is defined for %s", item.name, goos)
		}
		return runLinuxManager(runner, goos, "install", "-y", name)
	} else if goos != "darwin" {
		return unsupportedPlatform(goos)
	}
	if len(runner.lookPaths("brew")) == 0 {
		return errors.New("Homebrew is required on macOS; install it for your user, then retry")
	}
	return runner.run("brew", "install", item.homebrewFormula)
}
