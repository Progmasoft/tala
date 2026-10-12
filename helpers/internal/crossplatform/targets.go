// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// Package crossplatform runs the repository's own checks for platforms other
// than the one a developer sits at, in containers Podman starts.
//
// A container is a Linux process tree. Podman gives every host one, on
// Windows and on macOS inside a small Linux machine, so the Linux hosts of
// the compiler can be tested from anywhere, with the distribution, the
// compiler and the libraries the workflows use. Windows and macOS do not run
// in a container: there is no macOS image and no license for one outside
// Apple hardware, and Podman starts no Windows containers. Those targets are
// listed with the reason, so that asking for one explains itself instead of
// silently testing something else.
package crossplatform

import (
	"fmt"
	"sort"
	"strings"
)

// Fidelity says how closely a target reproduces the platform it is named
// after.
type Fidelity string

const (
	// Native runs the platform's own user space on its own kernel interface.
	Native Fidelity = "native"
	// Unavailable is a platform this host has no container for.
	Unavailable Fidelity = "unavailable"
)

// Target is one platform the tool knows.
type Target struct {
	// Name is what the command line calls it.
	Name string `json:"name"`
	// Platform is the operating system the target stands for.
	Platform string `json:"platform"`
	// Description is one line for a listing.
	Description string `json:"description"`
	// Fidelity is Native for a target that runs, Unavailable otherwise.
	Fidelity Fidelity `json:"fidelity"`
	// Reason says why an unavailable target is unavailable.
	Reason string `json:"reason,omitempty"`
	// Containerfile is the build file of the image, relative to the
	// repository, for a target that runs.
	Containerfile string `json:"containerfile,omitempty"`
}

// Runs reports whether the target can be run at all.
func (target Target) Runs() bool {
	return target.Fidelity == Native
}

const (
	macOSReason = "macOS does not run in a container: Apple publishes no container image and licenses macOS for Apple hardware only. " +
		"Test it on a Mac or in the macOS jobs of the workflows."
	windowsReason = "Podman starts Linux containers only, on every host; there is no Windows container to run. " +
		"Test it on Windows or in the Windows jobs of the workflows."
)

// Targets returns the platforms the tool knows, for a host of the given
// operating system (a GOOS value). The Linux targets run from every host.
// The host's own platform is not a cross-platform target and is left out;
// the two that cannot run in a container are listed as unavailable.
func Targets(hostOS string) []Target {
	targets := []Target{
		{
			Name:          "ubuntu-26.04",
			Platform:      "linux",
			Description:   "Ubuntu 26.04 LTS with the distribution's Clang and LLVM",
			Fidelity:      Native,
			Containerfile: "helpers/containers/ubuntu-26.04/Containerfile",
		},
		{
			Name:          "fedora-43",
			Platform:      "linux",
			Description:   "Fedora 43 with the distribution's Clang and LLVM",
			Fidelity:      Native,
			Containerfile: "helpers/containers/fedora-43/Containerfile",
		},
	}
	if hostOS != "darwin" {
		targets = append(targets, Target{
			Name: "macos", Platform: "darwin", Description: "macOS", Fidelity: Unavailable, Reason: macOSReason,
		})
	}
	if hostOS != "windows" {
		targets = append(targets, Target{
			Name: "windows", Platform: "windows", Description: "Windows", Fidelity: Unavailable, Reason: windowsReason,
		})
	}
	return targets
}

// Select returns the targets with the given names, in the order of the
// listing. No name selects every target that runs. An unknown name and a
// name of a target that cannot run are errors: a run that leaves out what
// was asked for must not pass.
func Select(all []Target, names []string) ([]Target, error) {
	if len(names) == 0 {
		var runnable []Target
		for _, target := range all {
			if target.Runs() {
				runnable = append(runnable, target)
			}
		}
		return runnable, nil
	}
	wanted := map[string]bool{}
	for _, name := range names {
		for _, part := range strings.Split(name, ",") {
			if part = strings.TrimSpace(part); part != "" {
				wanted[part] = true
			}
		}
	}
	var selected []Target
	for _, target := range all {
		if !wanted[target.Name] {
			continue
		}
		delete(wanted, target.Name)
		if !target.Runs() {
			return nil, fmt.Errorf("target %s cannot be run from this host: %s", target.Name, target.Reason)
		}
		selected = append(selected, target)
	}
	if len(wanted) != 0 {
		unknown := make([]string, 0, len(wanted))
		for name := range wanted {
			unknown = append(unknown, name)
		}
		sort.Strings(unknown)
		known := make([]string, 0, len(all))
		for _, target := range all {
			known = append(known, target.Name)
		}
		return nil, fmt.Errorf("unknown target %s; the targets are %s", strings.Join(unknown, ", "), strings.Join(known, ", "))
	}
	if len(selected) == 0 {
		return nil, fmt.Errorf("no target was named")
	}
	return selected, nil
}

// Suite is a named set of the repository's own commands.
type Suite struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	// Script is run by `sh -eu` in the root of the checkout.
	Script string `json:"-"`
}

// Suites returns the suites, cheapest first. The jobs value limits how many
// compilers Bazel runs at once: a container has the memory of the machine
// Podman runs it in, which is a fraction of the host's.
func Suites(jobs int) []Suite {
	bazel := fmt.Sprintf(" -- --jobs=%d", jobs)
	return []Suite{
		{
			Name:        "helpers",
			Description: "the tests of the Go helpers",
			Script:      "go run ./helpers/cmd/verify-helpers",
		},
		{
			Name:        "doctor",
			Description: "whether the image has the toolchain the build needs",
			Script:      "go run ./helpers/cmd/develop doctor",
		},
		{
			Name:        "frontend",
			Description: "the Haskell frontend and its tests",
			Script:      "cd Talac && cabal update && cabal test all",
		},
		{
			Name:        "native",
			Description: "the native compiler and its suites",
			Script:      "(cd Talac && cabal update) && go run ./helpers/cmd/develop test" + bazel,
		},
	}
}

// SelectSuite returns the suite of the given name.
func SelectSuite(suites []Suite, name string) (Suite, error) {
	names := make([]string, 0, len(suites))
	for _, suite := range suites {
		if suite.Name == name {
			return suite, nil
		}
		names = append(names, suite.Name)
	}
	return Suite{}, fmt.Errorf("unknown suite %q; the suites are %s", name, strings.Join(names, ", "))
}
