// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// Command cross-platform-test runs the repository's checks for platforms
// other than the host's, in containers Podman starts.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"runtime"
	"strings"

	"github.com/Progmasoft/tala/helpers/internal/crossplatform"
	"github.com/Progmasoft/tala/helpers/internal/repository"
	"github.com/spf13/cobra"
)

const usage = `Run the repository's checks for platforms other than this host's.

There are two ways. "ci" starts the compiler workflows for the current
branch: real Windows, macOS and Linux machines, nothing on this one. "run"
uses containers on this machine and reaches the Linux hosts only.

For "run", each target is a container Podman starts from an image this tool builds. The
sources are sent to the container as Git would commit them, tracked files and
new files that are not ignored, so a run never writes into the working tree.
Downloads and build output are kept in a volume for each target, which is
what makes a second run short. An image takes about 3 GB and the cache of a
full native build several more; "usage" shows what is kept and "clean"
removes it. A container may use two processors and 3 GB of memory unless
--cpus and --memory say otherwise.

The Linux targets run from every host. macOS and Windows do not run in a
container; "targets" lists them with the reason.`

func main() {
	command := newCommand(crossplatform.SystemEngine{}, runtime.GOOS, os.Stdout, os.Stderr)
	if err := command.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// memoryLimit is the form of a memory bound: megabytes or gigabytes.
var memoryLimit = regexp.MustCompile(`^[1-9][0-9]*[mg]$`)

// newCommand owns the command line. Parsing is separate from Podman, so an
// invocation that is not understood starts nothing.
func newCommand(engine crossplatform.Engine, hostOS string, output, errorOutput io.Writer) *cobra.Command {
	root := &cobra.Command{
		Use:           "cross-platform-test",
		Short:         "Run the repository's checks for other platforms in Podman containers.",
		Long:          usage,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE:          func(cmd *cobra.Command, args []string) error { return cmd.Help() },
	}
	root.SetOut(output)
	root.SetErr(errorOutput)
	root.CompletionOptions.DisableDefaultCmd = true

	var asJSON bool
	targets := &cobra.Command{
		Use:   "targets",
		Short: "List the targets and whether this host can run them.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return listTargets(output, crossplatform.Targets(hostOS), asJSON)
		},
	}
	targets.Flags().BoolVar(&asJSON, "json", false, "print the listing as JSON")

	var suitesJSON bool
	suites := &cobra.Command{
		Use:   "suites",
		Short: "List the suites a run can execute.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return listSuites(output, crossplatform.Suites(2), suitesJSON)
		},
	}
	suites.Flags().BoolVar(&suitesJSON, "json", false, "print the listing as JSON")

	var (
		names   []string
		suite   string
		script  string
		jobs    int
		cpus    int
		memory  string
		rebuild bool
	)
	run := &cobra.Command{
		Use:   "run",
		Short: "Run a suite, or a command of your own, on the selected targets.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if jobs < 1 || jobs > 256 {
				return errors.New("--jobs must be an integer in [1, 256]")
			}
			if cpus < 1 || cpus > 256 {
				return errors.New("--cpus must be an integer in [1, 256]")
			}
			if !memoryLimit.MatchString(memory) {
				return errors.New("--memory must be a number followed by m or g, such as 3g")
			}
			selected, err := crossplatform.Select(crossplatform.Targets(hostOS), names)
			if err != nil {
				return err
			}
			if cmd.Flags().Changed("suite") && cmd.Flags().Changed("command") {
				return errors.New("--suite and --command exclude each other")
			}
			if cmd.Flags().Changed("command") {
				if strings.TrimSpace(script) == "" {
					return errors.New("--command is empty")
				}
			} else {
				chosen, err := crossplatform.SelectSuite(crossplatform.Suites(jobs), suite)
				if err != nil {
					return err
				}
				script = chosen.Script
			}
			directory, err := os.Getwd()
			if err != nil {
				return err
			}
			checkout, err := repository.FindRoot(directory)
			if err != nil {
				return err
			}
			results, err := crossplatform.RunAll(engine, selected, crossplatform.Options{
				Repository: checkout, Script: script, RebuildImage: rebuild, CPUs: cpus, Memory: memory,
				Output: output, ErrorOutput: errorOutput,
			})
			if err != nil {
				return err
			}
			return summarize(output, results)
		},
	}
	run.Flags().StringSliceVar(&names, "target", nil, "a target to run; repeat or separate with commas (default: every target that runs)")
	run.Flags().StringVar(&suite, "suite", "helpers", "the suite to run; see the suites command")
	run.Flags().StringVar(&script, "command", "", "a shell command to run in the root of the sources instead of a suite")
	run.Flags().IntVar(&jobs, "jobs", 2, "how many compilers Bazel runs at once in a container")
	run.Flags().IntVar(&cpus, "cpus", 2, "how many processors a container may use")
	run.Flags().StringVar(&memory, "memory", "3g", "how much memory a container may use")
	run.Flags().BoolVar(&rebuild, "rebuild-image", false, "build the image again without its cache")

	var (
		hostedNames []string
		watch       bool
		hostedJSON  bool
	)
	ci := &cobra.Command{
		Use:   "ci",
		Short: "Start the compiler workflows for the current branch, on real Windows, macOS and Linux machines.",
		Long: `Start the compiler workflows for the current branch.

The workflows build and test on Windows, macOS 15 and 26, Ubuntu 26.04 and
Fedora 43, on machines GitHub runs. They start by themselves for a pull
request; this starts them for a branch that has none yet. Nothing runs on
this machine and nothing is stored on it. The branch has to be pushed and the
working tree clean, because a workflow tests what the remote has.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			hosted := crossplatform.HostedTargets()
			if hostedJSON {
				encoder := json.NewEncoder(output)
				encoder.SetIndent("", "  ")
				return encoder.Encode(hosted)
			}
			workflows, err := crossplatform.HostedWorkflows(hosted, hostedNames)
			if err != nil {
				return err
			}
			directory, err := os.Getwd()
			if err != nil {
				return err
			}
			checkout, err := repository.FindRoot(directory)
			if err != nil {
				return err
			}
			branch, err := crossplatform.PushedBranch(engine, checkout)
			if err != nil {
				return err
			}
			return crossplatform.Dispatch(engine, checkout, workflows, branch, watch, output, errorOutput)
		},
	}
	ci.Flags().StringSliceVar(&hostedNames, "target", nil, "windows, macos-15, macos-26, ubuntu-26.04 or fedora-43; repeat or separate with commas (default: all)")
	ci.Flags().BoolVar(&watch, "watch", false, "follow the runs to their end and fail if one fails")
	ci.Flags().BoolVar(&hostedJSON, "list", false, "print the targets the workflows cover as JSON and start nothing")

	usageCommand := &cobra.Command{
		Use:   "usage",
		Short: "Show the images and caches this tool keeps, and the size of Podman's storage.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return crossplatform.Usage(engine, output)
		},
	}
	clean := &cobra.Command{
		Use:   "clean",
		Short: "Remove the images and caches this tool created; the next run builds them again.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			images, volumes, err := crossplatform.Clean(engine, output, errorOutput)
			if err != nil {
				return err
			}
			fmt.Fprintf(output, "Removed %d images and %d cache volumes.\n", images, volumes)
			return nil
		},
	}

	root.AddCommand(ci, targets, suites, run, usageCommand, clean)
	return root
}

func listTargets(output io.Writer, targets []crossplatform.Target, asJSON bool) error {
	if asJSON {
		encoder := json.NewEncoder(output)
		encoder.SetIndent("", "  ")
		return encoder.Encode(targets)
	}
	for _, target := range targets {
		fmt.Fprintf(output, "%-14s %-12s %s\n", target.Name, target.Fidelity, target.Description)
		if target.Reason != "" {
			fmt.Fprintf(output, "%-14s %-12s %s\n", "", "", target.Reason)
		}
	}
	return nil
}

func listSuites(output io.Writer, suites []crossplatform.Suite, asJSON bool) error {
	if asJSON {
		encoder := json.NewEncoder(output)
		encoder.SetIndent("", "  ")
		return encoder.Encode(suites)
	}
	for _, suite := range suites {
		fmt.Fprintf(output, "%-10s %s\n", suite.Name, suite.Description)
	}
	return nil
}

// summarize prints one line for each target and fails when any failed.
func summarize(output io.Writer, results []crossplatform.Result) error {
	fmt.Fprintln(output)
	var failed []string
	for _, result := range results {
		verdict := "pass"
		if !result.Passed {
			verdict = "FAIL"
			failed = append(failed, result.Target)
		}
		fmt.Fprintf(output, "%-14s %s\n", result.Target, verdict)
	}
	if len(failed) != 0 {
		return fmt.Errorf("%d of %d targets failed: %s", len(failed), len(results), strings.Join(failed, ", "))
	}
	return nil
}
