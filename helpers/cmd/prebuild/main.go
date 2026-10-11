// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// prebuild installs system tools used to develop Visual X#. Bazel, Cabal, and
// Gradle remain the owners of their build graphs after host bootstrap.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"github.com/spf13/cobra"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const prebuildUsage = `Visual X# development-host bootstrap

Supported hosts are Windows 10/11, macOS 15/26, Ubuntu 26.04 LTS, and
Fedora 43 (N-1 as of September 2026). The installed
toolchain includes LLVM, Bazelisk, GHCup/GHC/Cabal, Go, Temurin JDK 25, Git, and the
platform link resources. Visual X# uses ClangCL/LLD on Windows, not MSVC.`

type bootstrapHost int

const (
	bootstrapUnsupported bootstrapHost = iota
	bootstrapWindows
	bootstrapMacOS
	bootstrapUbuntu
	bootstrapFedora
)

type bootstrapRunner interface {
	Run(name string, arguments ...string) error
	Output(name string, arguments ...string) (string, error)
	LookPath(name string) (string, error)
}

const (
	ghcupBootstrapCommit       = "69df703e3b1c701f42913740ca48f16e9026fe89"
	ghcupWindowsBootstrapHash  = "54A83F3A1E63879530A921351FFA6DE0F8E509DE51501E8E7EF0CBBD03AC7405"
	ghcupUnixBootstrapHash     = "C85ADD4CDCA779EA34BCBEEB3A311BBFED23FC96583311DF41FE4E73554EBA6D"
	maximumBootstrapScriptSize = 512 * 1024
)

// These immutable upstream artifacts replace the mutable haskell.org bootstrap
// endpoints. Keep the hashes alongside the source revision so a changed script
// cannot silently become code executed by a developer's machine.
var ghcupWindowsBootstrap = pinnedBootstrap{
	source: "https://raw.githubusercontent.com/haskell/ghcup-hs/" + ghcupBootstrapCommit + "/scripts/bootstrap/bootstrap-haskell.ps1",
	hash:   ghcupWindowsBootstrapHash,
}

var ghcupUnixBootstrap = pinnedBootstrap{
	source: "https://raw.githubusercontent.com/haskell/ghcup-hs/" + ghcupBootstrapCommit + "/scripts/bootstrap/bootstrap-haskell",
	hash:   ghcupUnixBootstrapHash,
}

type pinnedBootstrap struct {
	source string
	hash   string
}

func loadPinnedBootstrap(artifact pinnedBootstrap) ([]byte, error) {
	client := &http.Client{
		Timeout: 45 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return errors.New("refusing to follow a redirect for a pinned bootstrap script")
		},
	}
	return fetchPinnedBootstrap(context.Background(), client, artifact)
}

func fetchPinnedBootstrap(ctx context.Context, client *http.Client, artifact pinnedBootstrap) ([]byte, error) {
	parsed, err := url.ParseRequestURI(artifact.source)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() != "raw.githubusercontent.com" {
		return nil, errors.New("pinned bootstrap source must use HTTPS from raw.githubusercontent.com")
	}
	if client == nil {
		return nil, errors.New("pinned bootstrap HTTP client is nil")
	}
	expectedHash, err := hex.DecodeString(artifact.hash)
	if err != nil || len(expectedHash) != sha256.Size {
		return nil, errors.New("pinned bootstrap SHA-256 is invalid")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, artifact.source, nil)
	if err != nil {
		return nil, fmt.Errorf("create pinned bootstrap request: %w", err)
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("download pinned bootstrap script: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download pinned bootstrap script: HTTP %d", response.StatusCode)
	}
	if response.Request == nil || response.Request.URL.String() != artifact.source {
		return nil, errors.New("pinned bootstrap source changed during the request")
	}
	contents, err := io.ReadAll(io.LimitReader(response.Body, maximumBootstrapScriptSize+1))
	if err != nil {
		return nil, fmt.Errorf("read pinned bootstrap script: %w", err)
	}
	if len(contents) > maximumBootstrapScriptSize {
		return nil, fmt.Errorf("pinned bootstrap script exceeds %d bytes", maximumBootstrapScriptSize)
	}
	actualHash := sha256.Sum256(contents)
	if !equalBytes(actualHash[:], expectedHash) {
		return nil, errors.New("pinned bootstrap script SHA-256 mismatch; refusing to execute it")
	}
	return contents, nil
}

func equalBytes(left []byte, right []byte) bool {
	if len(left) != len(right) {
		return false
	}
	var difference byte
	for index := range left {
		difference |= left[index] ^ right[index]
	}
	return difference == 0
}

func withTemporaryBootstrapScript(contents []byte, pattern string, run func(string) error) error {
	script, err := os.CreateTemp("", pattern)
	if err != nil {
		return fmt.Errorf("create temporary bootstrap script: %w", err)
	}
	path := script.Name()
	defer os.Remove(path)
	if _, err := script.Write(contents); err != nil {
		_ = script.Close()
		return fmt.Errorf("write temporary bootstrap script: %w", err)
	}
	if err := script.Close(); err != nil {
		return fmt.Errorf("close temporary bootstrap script: %w", err)
	}
	return run(path)
}

type bootstrapSystemRunner struct{}

func (bootstrapSystemRunner) Run(name string, arguments ...string) error {
	command := exec.Command(name, arguments...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}

func (bootstrapSystemRunner) Output(name string, arguments ...string) (string, error) {
	command := exec.Command(name, arguments...)
	output, err := command.CombinedOutput()
	return strings.TrimSpace(string(output)), err
}

func (bootstrapSystemRunner) LookPath(name string) (string, error) {
	return exec.LookPath(name)
}

type toolRequirement struct {
	name            string
	executables     []string
	wingetPackageID string
	homebrewFormula string
	aptPackages     []string
	dnfPackages     []string
}

var bootstrapTools = []toolRequirement{
	{name: "Go", executables: []string{"go"}, wingetPackageID: "GoLang.Go", homebrewFormula: "go", aptPackages: []string{"golang-go"}, dnfPackages: []string{"golang"}},
	{name: "Git", executables: []string{"git"}, wingetPackageID: "Git.Git", homebrewFormula: "git", aptPackages: []string{"git"}, dnfPackages: []string{"git"}},
	{name: "Bazelisk", executables: []string{"bazelisk"}, wingetPackageID: "Bazel.Bazelisk", homebrewFormula: "bazelisk"},
	{name: "LLVM", executables: []string{"llvm-config"}, wingetPackageID: "LLVM.LLVM", homebrewFormula: "llvm", aptPackages: []string{"clang", "lld", "llvm-dev", "libzstd-dev", "libxml2-dev", "zlib1g-dev"}, dnfPackages: []string{"clang", "lld", "llvm-devel", "llvm-static", "libzstd-devel", "libxml2-devel", "zlib-devel"}},
	{name: "GHCup", executables: []string{"ghcup"}, homebrewFormula: "ghcup"},
	{name: "Temurin JDK 25", executables: []string{"java"}, wingetPackageID: "EclipseAdoptium.Temurin.25.JDK", homebrewFormula: "temurin@25", aptPackages: []string{"temurin-25-jdk"}, dnfPackages: []string{"temurin-25-jdk"}},
}

func main() {
	if err := runPrebuild(os.Args[1:], bootstrapSystemRunner{}); err != nil {
		fmt.Fprintf(os.Stderr, "\nerror: %v\n", err)
		os.Exit(1)
	}
}

// newPrebuildCommand owns the command line. Parsing is separate from host
// detection and installation, so an invalid invocation changes nothing and a
// request for help works on a host the bootstrap does not support.
func newPrebuildCommand(runner bootstrapRunner, output, errorOutput io.Writer) *cobra.Command {
	root := &cobra.Command{
		Use:           "prebuild",
		Short:         "Check or install the tools a Visual X# development host needs.",
		Long:          prebuildUsage,
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
			Use:   "check",
			Short: "Report missing host tools without changing the machine.",
			Args:  cobra.NoArgs,
			RunE: func(cmd *cobra.Command, args []string) error {
				host, err := detectBootstrapHost(runtime.GOOS)
				if err != nil {
					return err
				}
				return reportBootstrapState(host, runner)
			},
		},
		&cobra.Command{
			Use:   "install",
			Short: "Install missing tools with winget, Homebrew, apt, or dnf.",
			Args:  cobra.NoArgs,
			RunE: func(cmd *cobra.Command, args []string) error {
				host, err := detectBootstrapHost(runtime.GOOS)
				if err != nil {
					return err
				}
				if err := installBootstrapTools(host, runner); err != nil {
					return err
				}
				return reportPostInstallState(host, runner)
			},
		},
	)
	return root
}

func runPrebuild(arguments []string, runner bootstrapRunner) error {
	command := newPrebuildCommand(runner, os.Stdout, os.Stderr)
	command.SetArgs(arguments)
	return command.Execute()
}

func detectBootstrapHost(goos string) (bootstrapHost, error) {
	switch goos {
	case "windows":
		return bootstrapWindows, nil
	case "darwin":
		return bootstrapMacOS, nil
	case "linux":
		contents, err := os.ReadFile("/etc/os-release")
		if err != nil {
			return bootstrapUnsupported, fmt.Errorf("cannot identify the Linux distribution: %w", err)
		}
		return classifyBootstrapLinux(string(contents))
	default:
		return bootstrapUnsupported, fmt.Errorf("%s is not a supported Visual X# development host", goos)
	}
}

func classifyBootstrapLinux(release string) (bootstrapHost, error) {
	fields := make(map[string]string)
	for _, line := range strings.Split(release, "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			fields[key] = strings.Trim(value, `"`)
		}
	}
	switch {
	case fields["ID"] == "ubuntu" && fields["VERSION_ID"] == "26.04":
		return bootstrapUbuntu, nil
	case fields["ID"] == "fedora" && fields["VERSION_ID"] == "43":
		return bootstrapFedora, nil
	default:
		return bootstrapUnsupported, fmt.Errorf("unsupported Linux release %q %q; expected Ubuntu 26.04 LTS or Fedora 43 (N-1)", fields["ID"], fields["VERSION_ID"])
	}
}

func missingTools(host bootstrapHost, runner bootstrapRunner) []toolRequirement {
	missing := make([]toolRequirement, 0)
	for _, requirement := range bootstrapTools {
		if requirement.name == "Temurin JDK 25" {
			if !temurinJDK25Available(runner) {
				missing = append(missing, requirement)
			}
			continue
		}
		ready := true
		for _, executable := range requirementExecutables(host, requirement) {
			if !bootstrapToolAvailable(runner, executable) {
				ready = false
				break
			}
		}
		if !ready {
			missing = append(missing, requirement)
		}
	}
	return missing
}

func temurinJDK25Available(runner bootstrapRunner) bool {
	if _, err := runner.LookPath("java"); err != nil {
		return false
	}
	properties, err := runner.Output("java", "-XshowSettings:properties", "-version")
	if err != nil {
		return false
	}
	lower := strings.ToLower(properties)
	return strings.Contains(lower, "java.vendor = eclipse adoptium") &&
		(strings.Contains(lower, "java.version = 25.") || strings.Contains(lower, `openjdk version "25.`))
}

func bootstrapToolAvailable(runner bootstrapRunner, executable string) bool {
	if _, err := runner.LookPath(executable); err == nil {
		return true
	}
	if executable != "llvm-config" {
		return false
	}
	root := os.Getenv("LLVM_ROOT")
	if root == "" {
		return false
	}
	name := executable
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	information, err := os.Stat(filepath.Join(root, "bin", name))
	return err == nil && !information.IsDir()
}

func requirementExecutables(host bootstrapHost, requirement toolRequirement) []string {
	executables := append([]string(nil), requirement.executables...)
	if requirement.name != "LLVM" {
		return executables
	}
	if host == bootstrapWindows {
		return append(executables, "clang-cl", "lld-link")
	}
	return append(executables, "clang++")
}

func reportBootstrapState(host bootstrapHost, runner bootstrapRunner) error {
	fmt.Printf("Official host: %s\n", bootstrapHostName(host))
	missing := missingTools(host, runner)
	for _, requirement := range bootstrapTools {
		if containsRequirement(missing, requirement.name) {
			fmt.Printf("[missing] %s\n", requirement.name)
		} else {
			fmt.Printf("[ready]   %s\n", requirement.name)
		}
	}
	if host == bootstrapWindows {
		if windowsLinkResourcesPresent() {
			fmt.Println("[ready]   Windows SDK and MSVC CRT/C++ link libraries")
		} else {
			fmt.Println("[missing] Windows SDK or MSVC CRT/C++ link libraries")
			missing = append(missing, toolRequirement{name: "Windows link resources"})
		}
	} else if host == bootstrapMacOS {
		if _, err := runner.Output("xcode-select", "-p"); err != nil {
			fmt.Println("[missing] Xcode Command Line Tools")
			missing = append(missing, toolRequirement{name: "Xcode Command Line Tools"})
		} else {
			fmt.Println("[ready]   Xcode Command Line Tools")
		}
	}
	if _, err := runner.LookPath("ghc"); err != nil {
		fmt.Println("[missing] GHC selected by GHCup")
		missing = append(missing, toolRequirement{name: "GHC"})
	} else {
		fmt.Println("[ready]   GHC")
	}
	if _, err := runner.LookPath("cabal"); err != nil {
		fmt.Println("[missing] Cabal selected by GHCup")
		missing = append(missing, toolRequirement{name: "Cabal"})
	} else {
		fmt.Println("[ready]   Cabal")
	}
	if len(missing) != 0 {
		return errors.New("development host is incomplete; run 'go run ./helpers/cmd/prebuild install'")
	}
	fmt.Println("\nDevelopment host bootstrap is complete.")
	return nil
}

func reportPostInstallState(host bootstrapHost, runner bootstrapRunner) error {
	fmt.Println("\nInstallation commands completed.")
	if err := reportBootstrapState(host, runner); err != nil {
		fmt.Println("\nNew package-manager PATH entries may not be visible to this process yet.")
		fmt.Println("Open a new terminal, then run:")
		fmt.Println("  go run ./helpers/cmd/prebuild check")
		fmt.Println("  go run ./helpers/cmd/develop doctor")
		return errors.New("installation finished, but verification is incomplete in this process; open a new terminal and run prebuild check")
	}
	fmt.Println("Run 'go run ./helpers/cmd/develop doctor' before the first build.")
	return nil
}

func installBootstrapTools(host bootstrapHost, runner bootstrapRunner) error {
	missing := missingTools(host, runner)
	if host == bootstrapWindows {
		winget, err := runner.LookPath("winget")
		if err != nil {
			return errors.New("winget is required on Windows; install or repair App Installer first")
		}
		for _, requirement := range missing {
			if requirement.name == "GHCup" {
				if err := installGHCupWindows(runner); err != nil {
					return err
				}
				continue
			}
			if err := installWingetPackage(runner, winget, requirement.wingetPackageID); err != nil {
				return fmt.Errorf("cannot install %s: %w", requirement.name, err)
			}
		}
		if !windowsLinkResourcesPresent() {
			if err := installWindowsLinkResources(runner, winget); err != nil {
				return err
			}
		}
	} else if host == bootstrapMacOS {
		brew, err := runner.LookPath("brew")
		if err != nil {
			return errors.New("Homebrew is required on macOS; install it from https://brew.sh and rerun prebuild")
		}
		if _, err := runner.Output("xcode-select", "-p"); err != nil {
			fmt.Println("Requesting the Apple Command Line Tools installer...")
			if err := runner.Run("xcode-select", "--install"); err != nil {
				return fmt.Errorf("cannot request Xcode Command Line Tools: %w", err)
			}
		}
		for _, requirement := range missing {
			if homebrewPackageInstalled(runner, brew, requirement) {
				fmt.Printf("Skipping %s; Homebrew reports it is already installed.\n", requirement.name)
				continue
			}
			fmt.Printf("Installing %s with Homebrew...\n", requirement.name)
			arguments := homebrewInstallArguments(requirement)
			if err := runner.Run(brew, arguments...); err != nil {
				return fmt.Errorf("cannot install %s: %w", requirement.name, err)
			}
		}
	} else {
		if err := installLinuxTools(host, runner, missing); err != nil {
			return err
		}
	}
	return installHaskellTools(runner)
}

func installLinuxTools(host bootstrapHost, runner bootstrapRunner, missing []toolRequirement) error {
	manager := "apt-get"
	base := []string{"curl", "xz-utils", "libgmp-dev", "libffi-dev", "libncurses-dev"}
	if host == bootstrapFedora {
		manager = "dnf"
		base = []string{"curl", "xz", "gmp-devel", "libffi-devel", "ncurses-devel"}
	}
	if _, err := runner.LookPath(manager); err != nil {
		return fmt.Errorf("%s is required on %s", manager, bootstrapHostName(host))
	}
	if host == bootstrapUbuntu {
		if err := runLinuxPackageManager(runner, manager, []string{"update"}); err != nil {
			return err
		}
	}
	if err := runLinuxPackageManager(runner, manager, linuxInstallArguments(base)); err != nil {
		return fmt.Errorf("cannot install Linux bootstrap prerequisites: %w", err)
	}
	for _, requirement := range missing {
		switch requirement.name {
		case "Bazelisk":
			if err := runner.Run("go", "install", "github.com/bazelbuild/bazelisk@v1.29.0"); err != nil {
				return fmt.Errorf("cannot install Bazelisk with Go: %w", err)
			}
		case "GHCup":
			// The reviewed script is hash-verified before it runs and receives no shell-parsed URL.
			if err := installGHCupUnix(runner); err != nil {
				return fmt.Errorf("cannot install GHCup: %w", err)
			}
		default:
			arguments := linuxRequirementPackages(host, requirement)
			if len(arguments) == 0 {
				return fmt.Errorf("no %s package is defined for %s", requirement.name, bootstrapHostName(host))
			}
			if err := runLinuxPackageManager(runner, manager, linuxInstallArguments(arguments)); err != nil {
				if requirement.name == "Temurin JDK 25" {
					return fmt.Errorf("cannot install Temurin 25; enable Eclipse Adoptium's signed apt/dnf repository and rerun prebuild: %w", err)
				}
				return fmt.Errorf("cannot install %s: %w", requirement.name, err)
			}
		}
	}
	return nil
}

func linuxRequirementPackages(host bootstrapHost, requirement toolRequirement) []string {
	if host == bootstrapFedora {
		return requirement.dnfPackages
	}
	return requirement.aptPackages
}

func linuxInstallArguments(packages []string) []string {
	return append([]string{"install", "-y"}, packages...)
}

func runLinuxPackageManager(runner bootstrapRunner, manager string, arguments []string) error {
	if os.Geteuid() == 0 {
		return runner.Run(manager, arguments...)
	}
	if _, err := runner.LookPath("sudo"); err != nil {
		return errors.New("sudo is required to install distribution packages as a non-root user")
	}
	return runner.Run("sudo", append([]string{manager}, arguments...)...)
}

func homebrewInstallArguments(requirement toolRequirement) []string {
	if requirement.name == "Temurin JDK 25" {
		return []string{"install", "--cask", requirement.homebrewFormula}
	}
	return []string{"install", requirement.homebrewFormula}
}

func installWingetPackage(runner bootstrapRunner, winget string, packageID string) error {
	if packageID == "" {
		return errors.New("package has no winget identifier")
	}
	if wingetPackageInstalled(runner, winget, packageID) {
		fmt.Printf("Skipping %s; WinGet reports it is already installed.\n", packageID)
		return nil
	}
	fmt.Printf("Installing %s with winget...\n", packageID)
	return runner.Run(winget, "install", "--id", packageID, "--exact", "--source", "winget",
		"--accept-package-agreements", "--accept-source-agreements", "--silent", "--disable-interactivity")
}

func wingetPackageInstalled(runner bootstrapRunner, winget string, packageID string) bool {
	listing, err := runner.Output(winget, "list", "--id", packageID, "--exact", "--source", "winget", "--disable-interactivity")
	return err == nil && strings.Contains(strings.ToLower(listing), strings.ToLower(packageID))
}

func homebrewPackageInstalled(runner bootstrapRunner, brew string, requirement toolRequirement) bool {
	if requirement.homebrewFormula == "" {
		return false
	}
	arguments := []string{"list", "--formula", requirement.homebrewFormula}
	if requirement.name == "Temurin JDK 25" {
		arguments[1] = "--cask"
	}
	_, err := runner.Output(brew, arguments...)
	return err == nil
}

func installGHCupWindows(runner bootstrapRunner) error {
	return installGHCupWindowsWithLoader(runner, func() ([]byte, error) {
		return loadPinnedBootstrap(ghcupWindowsBootstrap)
	})
}

func installGHCupWindowsWithLoader(runner bootstrapRunner, load func() ([]byte, error)) error {
	script, err := load()
	if err != nil {
		return fmt.Errorf("cannot verify the pinned GHCup bootstrap: %w", err)
	}
	fmt.Println("Installing GHCup with the pinned Haskell bootstrap...")
	err = withTemporaryBootstrapScript(script, "visual-xsharp-ghcup-*.ps1", func(path string) error {
		return runner.Run("powershell.exe", "-NoProfile", "-NonInteractive", "-File", path,
			"-Minimal", "-InBash", "-InstallDir", `C:\`)
	})
	if err != nil {
		return fmt.Errorf("cannot install GHCup: %w", err)
	}
	return nil
}

func installGHCupUnix(runner bootstrapRunner) error {
	return installGHCupUnixWithLoader(runner, func() ([]byte, error) {
		return loadPinnedBootstrap(ghcupUnixBootstrap)
	})
}

func installGHCupUnixWithLoader(runner bootstrapRunner, load func() ([]byte, error)) error {
	return installGHCupUnixWithLoaderAs(runner, load, os.Geteuid() == 0)
}

func installGHCupUnixWithLoaderAs(runner bootstrapRunner, load func() ([]byte, error), runningAsRoot bool) error {
	if runningAsRoot {
		return errors.New("refusing to install per-user GHCup as root; rerun prebuild as the development user")
	}
	script, err := load()
	if err != nil {
		return fmt.Errorf("cannot verify the pinned GHCup bootstrap: %w", err)
	}
	fmt.Println("Installing GHCup with the pinned Haskell bootstrap...")
	err = withTemporaryBootstrapScript(script, "visual-xsharp-ghcup-*.sh", func(path string) error {
		return runner.Run("env", "BOOTSTRAP_HASKELL_NONINTERACTIVE=1", "BOOTSTRAP_HASKELL_MINIMAL=1", "sh", path)
	})
	if err != nil {
		return fmt.Errorf("cannot install GHCup: %w", err)
	}
	return nil
}

func installWindowsLinkResources(runner bootstrapRunner, winget string) error {
	// ClangCL and LLD remain selected. The workload is used only because the SDK
	// import libraries and MSVC CRT/C++ link libraries are not a complete
	// standalone winget package.
	const packageID = "Microsoft.VisualStudio.2022.BuildTools"
	fmt.Printf("Installing Windows SDK/CRT link resources from %s...\n", packageID)
	arguments := []string{
		"install", "--id", packageID, "--exact", "--source", "winget",
		"--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity",
		"--override", "--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended",
	}
	if err := runner.Run(winget, arguments...); err != nil {
		return fmt.Errorf("winget could not install the Visual Studio Build Tools link-resource workload: %w", err)
	}
	return nil
}

func installHaskellTools(runner bootstrapRunner) error {
	ghcup, err := findGHCup(runner)
	if err != nil {
		fmt.Println("GHCup was installed but is not visible yet; open a new terminal and rerun prebuild install.")
		return nil
	}
	if _, err := runner.LookPath("ghc"); err != nil {
		fmt.Println("Installing and selecting GHCup's recommended GHC...")
		if err := runner.Run(ghcup, "install", "ghc", "recommended", "--set"); err != nil {
			return fmt.Errorf("cannot install GHC: %w", err)
		}
	}
	if _, err := runner.LookPath("cabal"); err != nil {
		fmt.Println("Installing and selecting Cabal...")
		if err := runner.Run(ghcup, "install", "cabal", "latest", "--set"); err != nil {
			return fmt.Errorf("cannot install Cabal: %w", err)
		}
	}
	return nil
}

func findGHCup(runner bootstrapRunner) (string, error) {
	if path, err := runner.LookPath("ghcup"); err == nil {
		return path, nil
	}
	candidates := []string{`C:\ghcup\bin\ghcup.exe`}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates, filepath.Join(home, ".ghcup", "bin", "ghcup"))
	}
	if appData := os.Getenv("APPDATA"); appData != "" {
		candidates = append(candidates, filepath.Join(appData, "ghcup", "bin", "ghcup.exe"))
	}
	if userProfile := os.Getenv("USERPROFILE"); userProfile != "" {
		candidates = append(candidates, filepath.Join(userProfile, ".ghcup", "bin", "ghcup.exe"))
	}
	for _, candidate := range candidates {
		if information, err := os.Stat(candidate); err == nil && !information.IsDir() {
			return candidate, nil
		}
	}
	return "", errors.New("ghcup was not found")
}

func windowsLinkResourcesPresent() bool {
	programFilesX86 := os.Getenv("ProgramFiles(x86)")
	programFiles := os.Getenv("ProgramFiles")
	if programFilesX86 == "" {
		programFilesX86 = `C:\Program Files (x86)`
	}
	if programFiles == "" {
		programFiles = `C:\Program Files`
	}
	sdk := filepath.Join(programFilesX86, "Windows Kits", "10", "Lib", "*", "ucrt", "x64", "ucrt.lib")
	crt := filepath.Join(programFiles, "Microsoft Visual Studio", "*", "*", "VC", "Tools", "MSVC", "*", "lib", "x64", "libcmt.lib")
	return globHasFile(sdk) && globHasFile(crt)
}

func globHasFile(pattern string) bool {
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return false
	}
	for _, match := range matches {
		if information, err := os.Stat(match); err == nil && !information.IsDir() {
			return true
		}
	}
	return false
}

func containsRequirement(requirements []toolRequirement, name string) bool {
	for _, requirement := range requirements {
		if requirement.name == name {
			return true
		}
	}
	return false
}

func bootstrapHostName(host bootstrapHost) string {
	switch host {
	case bootstrapWindows:
		return "Windows 10/11"
	case bootstrapMacOS:
		return "macOS Sequoia/Tahoe"
	case bootstrapUbuntu:
		return "Ubuntu 26.04 LTS (Tier 2)"
	case bootstrapFedora:
		return "Fedora 43 (Tier 3, N-1)"
	default:
		return "unsupported"
	}
}
