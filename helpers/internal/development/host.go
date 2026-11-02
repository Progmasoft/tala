// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

type hostKind int

const (
	hostUnsupported hostKind = iota
	hostWindows
	hostMacOS
	hostLinux
)

type host struct {
	kind       hostKind
	name       string
	version    string
	executable string
}

type sanitizer struct {
	name        string
	config      string
	environment []string
}

type releaseCheck struct {
	name   string
	ok     bool
	detail string
}

func sanitizerEnvironment(currentHost host, selected sanitizer, runner commandRunner) ([]string, error) {
	environment := append([]string(nil), selected.environment...)
	if currentHost.kind != hostWindows || !strings.Contains(selected.config, "asan") {
		return environment, nil
	}
	resourceDirectory, err := runner.Output("clang-cl", "/clang:-print-resource-dir")
	if err != nil || resourceDirectory == "" {
		return nil, errors.New("AddressSanitizer could not locate the Clang runtime directory")
	}
	runtimeDirectory := filepath.Join(resourceDirectory, "lib", "windows")
	runtimeLibrary := filepath.Join(runtimeDirectory, "clang_rt.asan_dynamic-x86_64.dll")
	if information, err := os.Stat(runtimeLibrary); err != nil || information.IsDir() {
		return nil, fmt.Errorf("AddressSanitizer runtime is missing: %s", runtimeLibrary)
	}
	// Instrumented executables use Clang's matching dynamic runtime. Scope the
	// PATH extension to child tests instead of mutating the developer's shell.
	environment = append(environment, "PATH="+runtimeDirectory+string(os.PathListSeparator)+os.Getenv("PATH"))
	return environment, nil
}

func detectHost(runner commandRunner) (host, error) {
	switch runtime.GOOS {
	case "windows":
		version, _ := runner.Output("cmd", "/c", "ver")
		return host{kind: hostWindows, name: "Windows 10/11", version: version, executable: ".exe"}, nil
	case "darwin":
		version, err := runner.Output("sw_vers", "-productVersion")
		if err != nil {
			return host{}, fmt.Errorf("cannot determine the macOS version: %w", err)
		}
		majorText := strings.SplitN(version, ".", 2)[0]
		major, err := strconv.Atoi(majorText)
		if err != nil || (major != 15 && major != 26) {
			return host{}, fmt.Errorf("macOS %s is not an official host; use macOS 15 Sequoia or macOS 26 Tahoe", version)
		}
		name := "macOS 15 Sequoia"
		if major == 26 {
			name = "macOS 26 Tahoe"
		}
		return host{kind: hostMacOS, name: name, version: version}, nil
	case "linux":
		contents, err := os.ReadFile("/etc/os-release")
		if err != nil {
			return host{}, fmt.Errorf("cannot identify the Linux distribution: %w", err)
		}
		return classifyLinuxHost(string(contents))
	default:
		return host{}, fmt.Errorf("%s is not a supported development host", runtime.GOOS)
	}
}

func classifyLinuxHost(release string) (host, error) {
	fields := make(map[string]string)
	for _, line := range strings.Split(release, "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			fields[key] = strings.Trim(value, `"`)
		}
	}
	switch {
	case fields["ID"] == "ubuntu" && fields["VERSION_ID"] == "26.04":
		return host{kind: hostLinux, name: "Ubuntu 26.04 LTS", version: "26.04"}, nil
	case fields["ID"] == "fedora" && fields["VERSION_ID"] == "43":
		return host{kind: hostLinux, name: "Fedora 43 (N-1)", version: "43"}, nil
	default:
		return host{}, fmt.Errorf("unsupported Linux release %q %q; expected Ubuntu 26.04 LTS or Fedora 43 (N-1)", fields["ID"], fields["VERSION_ID"])
	}
}

func selectSanitizer(currentHost host, requested string) (sanitizer, error) {
	name := strings.ToLower(requested)
	switch name {
	case "address", "asan":
		if currentHost.kind == hostWindows {
			return sanitizer{
				name:        "AddressSanitizer",
				config:      "asan-windows",
				environment: []string{"ASAN_OPTIONS=halt_on_error=1:strict_string_checks=1"},
			}, nil
		}
		if currentHost.kind == hostLinux {
			// As on macOS, the LLVM libraries are built with libc++ but without
			// instrumentation, so libc++ container annotations would report
			// overflows inside allocations that LLVM fills and reads.
			return sanitizer{name: "AddressSanitizer", config: "asan-linux", environment: []string{"ASAN_OPTIONS=halt_on_error=1:strict_string_checks=1:detect_container_overflow=0"}}, nil
		}
		return sanitizer{
			name:   "AddressSanitizer",
			config: "asan-macos",
			// Apple's AddressSanitizer runtime aborts when detect_leaks is set;
			// address, bounds, and use-after-free diagnostics remain enabled.
			// The LLVM libraries come from the LLVM release without instrumentation.
			// libc++ annotates a vector only where instrumented code grows it,
			// so a vector LLVM fills and reads, such as the subtarget features
			// of the X86 target, reports a container overflow inside its own
			// allocation. The sanitizer documentation names such a mix as the
			// case for turning the check off; the other checks stay on.
			environment: []string{"ASAN_OPTIONS=halt_on_error=1:strict_string_checks=1:detect_container_overflow=0"},
		}, nil
	case "undefined", "ubsan":
		if currentHost.kind == hostWindows {
			return sanitizer{name: "UndefinedBehaviorSanitizer", config: "ubsan-windows", environment: []string{"UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1"}}, nil
		}
		if currentHost.kind == hostLinux {
			return sanitizer{name: "UndefinedBehaviorSanitizer", config: "ubsan-linux", environment: []string{"UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1"}}, nil
		}
		return sanitizer{
			name:        "UndefinedBehaviorSanitizer",
			config:      "ubsan-macos",
			environment: []string{"UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1"},
		}, nil
	case "thread", "tsan":
		if currentHost.kind == hostWindows {
			return sanitizer{}, errors.New("Clang compiler-rt does not support Windows ThreadSanitizer; use address-undefined here and run thread on macOS/Linux")
		}
		if currentHost.kind == hostLinux {
			return sanitizer{name: "ThreadSanitizer", config: "tsan-linux", environment: []string{"TSAN_OPTIONS=halt_on_error=1"}}, nil
		}
		return sanitizer{
			name:        "ThreadSanitizer",
			config:      "tsan-macos",
			environment: []string{"TSAN_OPTIONS=halt_on_error=1"},
		}, nil
	case "address-undefined", "asan-ubsan":
		address, err := selectSanitizer(currentHost, "address")
		if err != nil {
			return sanitizer{}, err
		}
		undefined, err := selectSanitizer(currentHost, "undefined")
		if err != nil {
			return sanitizer{}, err
		}
		return sanitizer{name: "AddressSanitizer + UndefinedBehaviorSanitizer", config: strings.Replace(address.config, "asan-", "asan-ubsan-", 1), environment: append(address.environment, undefined.environment...)}, nil
	default:
		return sanitizer{}, fmt.Errorf("unknown sanitizer %q; choose address, undefined, address-undefined, or thread", requested)
	}
}

func runDoctor(currentHost host, runner commandRunner) error {
	fmt.Printf("Official host: %s\n", currentHost.name)
	if currentHost.version != "" {
		fmt.Printf("Detected version: %s\n", currentHost.version)
	}

	required := []string{"llvm-config", "ghc", "cabal"}
	if currentHost.kind == hostWindows {
		required = append(required, "clang-cl", "lld-link")
	} else if currentHost.kind == hostMacOS {
		required = append(required, "clang++", "xcrun")
	} else {
		required = append(required, "clang++")
	}
	missing := make([]string, 0)
	if _, err := findBazel(runner); err != nil {
		fmt.Println("[missing] bazelisk or bazel")
		missing = append(missing, "Bazelisk")
	} else {
		fmt.Println("[ready]   Bazel")
	}
	for _, tool := range required {
		if path, err := locateTool(runner, tool); err != nil {
			fmt.Printf("[missing] %s\n", tool)
			missing = append(missing, tool)
		} else {
			fmt.Printf("[ready]   %s (%s)\n", tool, path)
		}
	}
	if currentHost.kind == hostMacOS {
		if sdk, err := runner.Output("xcrun", "--show-sdk-path"); err == nil {
			fmt.Printf("[ready]   Apple SDK (%s)\n", sdk)
		} else {
			fmt.Println("[missing] Apple SDK; install the Xcode Command Line Tools")
			missing = append(missing, "Apple SDK")
		}
	}
	if len(missing) != 0 {
		return fmt.Errorf("toolchain is incomplete: %s", strings.Join(missing, ", "))
	}
	fmt.Println("\nNative toolchain discovery is ready.")
	return nil
}

func requireBuildTools(currentHost host, runner commandRunner) error {
	if _, err := findBazel(runner); err != nil {
		return err
	}
	if err := prepareLinuxLLVMRoot(currentHost, runner); err != nil {
		return err
	}
	tools := []string{"llvm-config", "ghc", "cabal"}
	if currentHost.kind == hostWindows {
		tools = append(tools, "clang-cl", "lld-link")
	} else if currentHost.kind == hostMacOS {
		tools = append(tools, "clang++", "xcrun")
	} else {
		tools = append(tools, "clang++")
	}
	for _, tool := range tools {
		if _, err := locateTool(runner, tool); err != nil {
			return fmt.Errorf("required tool %q was not found; run doctor for the complete host report", tool)
		}
	}
	return nil
}

func locateTool(runner commandRunner, name string) (string, error) {
	if path, err := runner.LookPath(name); err == nil {
		return path, nil
	}
	// LLVM_ROOT is an established repository discovery input. Doctor must agree
	// with the Bazel repository rule instead of reporting a false negative when
	// the user intentionally keeps LLVM's bin directory off the global PATH.
	if name == "llvm-config" {
		if root := os.Getenv("LLVM_ROOT"); root != "" {
			executable := name
			if runtime.GOOS == "windows" {
				executable += ".exe"
			}
			candidate := filepath.Join(root, "bin", executable)
			if information, err := os.Stat(candidate); err == nil && !information.IsDir() {
				return candidate, nil
			}
		}
	}
	return "", errors.New("tool not found")
}

func findBazel(runner commandRunner) (string, error) {
	if path, err := runner.LookPath("bazelisk"); err == nil {
		return path, nil
	}
	if path, err := runner.LookPath("bazel"); err == nil {
		return path, nil
	}
	return "", errors.New("Bazelisk or Bazel was not found; install Bazelisk and run doctor again")
}
