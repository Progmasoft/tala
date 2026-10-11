// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"
)

// newCommand owns parsing independently of tool discovery and execution. Invalid
// invocations therefore cannot trigger downloads, builds, or generated cleanup.
func newCommand(runner commandRunner, output, errorOutput io.Writer) *cobra.Command {
	root := &cobra.Command{
		Use:           "develop",
		Short:         "Visual X# native developer command",
		Long:          "Visual X# native developer command\n\nBuild, verify, package, and diagnose the native toolchain.",
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.NoArgs,
		RunE:          func(cmd *cobra.Command, args []string) error { return cmd.Help() },
	}
	root.SetOut(output)
	root.SetErr(errorOutput)
	root.CompletionOptions.DisableDefaultCmd = true
	type commandSpec struct {
		name, description string
		positionals       int
		forward           bool
	}
	specs := []commandSpec{
		{"doctor", "Explain whether this host has the required native toolchain.", 0, false},
		{"build", "Build the compiler and native contract suites.", 0, true},
		{"bundle", "Stage, checksum, and smoke-test a host distribution.", 0, true},
		{"test", "Build and execute every native contract suite.", 0, true},
		{"sanitize", "Run address, undefined, address-undefined, or thread sanitizer suites, or all the host has.", 1, true},
		{"tidy", "Run clang-tidy over every first-party C++ translation unit.", 0, true},
		{"version", "Validate major.minor.patch[.revision] release metadata.", 1, false},
		{"incremental-clean-build", "Rebuild while preserving downloaded dependencies.", 0, false},
		{"cold-clean-build", "Expunge Bazel state and rebuild the compiler.", 0, false},
		{"clean", "Remove generated Bazel, Cabal, and Gradle output.", 0, false},
	}
	for _, spec := range specs {
		use := spec.name
		if spec.positionals != 0 {
			use += " <value>"
		}
		if spec.forward {
			use += " [-- <Bazel options>]"
		}
		child := &cobra.Command{Use: use, Short: spec.description, DisableFlagParsing: spec.forward}
		child.Args = func(cmd *cobra.Command, args []string) error {
			if spec.forward && len(args) == 1 && isHelp(args[0]) {
				return nil
			}
			positionals, trailing, err := splitArguments(args)
			if err != nil {
				return err
			}
			if !spec.forward && len(trailing) != 0 {
				return fmt.Errorf("%s does not accept Bazel options", spec.name)
			}
			if len(positionals) != spec.positionals {
				return fmt.Errorf("%s requires %d positional arguments; Bazel options belong after --", spec.name, spec.positionals)
			}
			return nil
		}
		child.RunE = func(cmd *cobra.Command, args []string) error {
			if spec.forward && len(args) == 1 && isHelp(args[0]) {
				return cmd.Help()
			}
			return executeWorkflow(append([]string{spec.name}, args...), runner)
		}
		root.AddCommand(child)
	}
	fuzz := newFuzzCommand(runner, "fuzz", "Run bounded ASan/UBSan libFuzzer campaigns and the Haskell HPC campaign.", false, nativeFuzzTargets())
	thread := newFuzzCommand(runner, "fuzz-thread", "Run the threaded fuzz targets under ThreadSanitizer (macOS/Linux).", false, threadFuzzTargets())
	var asan bool
	stress := newFuzzCommand(runner, "fuzz-stress", "Run long per-target fuzz campaigns with ASan and UBSan.", true, nativeFuzzTargets())
	stress.Flags().BoolVar(&asan, "asan", false, "compatibility flag; ASan and UBSan are always enabled")
	root.AddCommand(fuzz, thread, stress)

	root.AddCommand(newBenchmarkCommand(runner), newBenchmarkReportCommand(), newBenchmarkCompareCommand())

	var sanitizersAsJSON bool
	sanitizers := &cobra.Command{
		Use:   "sanitizers",
		Short: "List the sanitizer kinds, what each is on this host, and what `sanitize all` runs.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			arguments := []string{"sanitizers"}
			if sanitizersAsJSON {
				arguments = append(arguments, "--json")
			}
			return executeWorkflow(arguments, runner)
		},
	}
	sanitizers.Flags().BoolVar(&sanitizersAsJSON, "json", false, "write the list as JSON")
	root.AddCommand(sanitizers)

	var targetsAsJSON bool
	targets := &cobra.Command{
		Use:   "fuzz-targets",
		Short: "List the fuzz targets, their limits, and the names a selection may use.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return writeFuzzTargets(cmd.OutOrStdout(), nativeFuzzTargets(), targetsAsJSON)
		},
	}
	targets.Flags().BoolVar(&targetsAsJSON, "json", false, "write the inventory as JSON")
	root.AddCommand(targets)
	return root
}

// newBenchmarkCommand builds the command that runs the benchmarks. Its own
// options are flags; what follows `--` goes to Bazel, as for the other
// commands that build.
func newBenchmarkCommand(runner commandRunner) *cobra.Command {
	var options benchmarkOptions
	command := &cobra.Command{
		Use:   "benchmark [flags] [-- <Bazel options>]",
		Short: "Run native and Haskell compiler benchmarks.",
		Long: `Run native and Haskell compiler benchmarks.

The native benchmark programs are built optimized and run one after another,
then the Criterion benchmarks of the Haskell Core. With --output the times are
also written to a directory as a result set: one Google Benchmark JSON file for
each native program and one Criterion CSV file. benchmark-report prints such a
set as a table, and benchmark-compare sets one against another.`,
		Args: func(cmd *cobra.Command, args []string) error {
			dash := cmd.ArgsLenAtDash()
			if dash < 0 && len(args) != 0 || dash > 0 {
				return errors.New("benchmark takes no positional arguments; Bazel options belong after --")
			}
			_, _, err := splitArguments(append([]string{"--"}, args...))
			return err
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := options.validate(); err != nil {
				return err
			}
			return executeBenchmark(options, args, runner)
		},
	}
	flags := command.Flags()
	flags.StringVar(&options.filter, "filter", "", "run only the native benchmarks whose name matches this regular expression")
	flags.IntVar(&options.repetitions, "repetitions", 0, "run each native benchmark this many times and report the median, 1 to 100")
	flags.StringVar(&options.output, "output", "", "directory to write the result set to")
	flags.BoolVar(&options.nativeOnly, "native-only", false, "run the native benchmarks and leave the Haskell ones out")
	flags.BoolVar(&options.haskellOnly, "haskell-only", false, "run the Haskell benchmarks and leave the native ones out")
	return command
}

// newBenchmarkReportCommand builds the command that prints a result set. It
// reads files and starts nothing.
func newBenchmarkReportCommand() *cobra.Command {
	var markdown string
	command := &cobra.Command{
		Use:   "benchmark-report <results>",
		Short: "Print a benchmark result set as a Markdown table.",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return executeBenchmarkReport(cmd.OutOrStdout(), args[0], markdown)
		},
	}
	command.Flags().StringVar(&markdown, "markdown", "", "also write the table to this file")
	return command
}

// newBenchmarkCompareCommand builds the command that sets one result set
// against another. It reads files and starts nothing.
func newBenchmarkCompareCommand() *cobra.Command {
	var markdown string
	var informational bool
	threshold := 10.0
	command := &cobra.Command{
		Use:   "benchmark-compare <baseline> <candidate>",
		Short: "Compare two benchmark result sets and fail on a regression.",
		Long: `Compare two benchmark result sets and fail on a regression.

A benchmark is slower or faster when its time moved by more than the
threshold, in percent; inside the threshold it is unchanged. The command fails
when a benchmark is slower, unless --informational is given. A benchmark that
only one of the two sets has is listed as added or removed and never fails
the comparison.

Two runs are only comparable when they were made on the same machine under
the same load. Times from different machines measure the machines.`,
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return executeBenchmarkComparison(cmd.OutOrStdout(), args[0], args[1], threshold, markdown, informational)
		},
	}
	flags := command.Flags()
	flags.Float64Var(&threshold, "threshold", threshold, "change in percent beyond which a benchmark counts as slower or faster")
	flags.StringVar(&markdown, "markdown", "", "also write the comparison to this file")
	flags.BoolVar(&informational, "informational", false, "report regressions without failing")
	return command
}

// newFuzzCommand builds one of the fuzz commands. They share their options,
// which are checked here, before the workflow discovers a tool or builds a
// target: the limits of the campaign and the names of the inventory are known
// without either.
func newFuzzCommand(runner commandRunner, name, description string, stress bool, inventory []fuzzTarget) *cobra.Command {
	var options fuzzOptions
	command := &cobra.Command{
		Use:   name,
		Short: description,
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := options.validate(stress, inventory); err != nil {
				return err
			}
			if err := options.apply(os.Setenv); err != nil {
				return err
			}
			return executeWorkflow([]string{name}, runner)
		},
	}
	flags := command.Flags()
	flags.IntVar(&options.seconds, "seconds", 0, "time budget of each target in seconds, 1 to 3600 (default: VXS_FUZZ_SECONDS, or the command's own)")
	flags.IntVar(&options.jobs, "jobs", 0, "targets to run at once, 1 to 64 (default: VXS_FUZZ_JOBS, or one per four logical processors)")
	flags.StringVar(&options.corpus, "corpus", "", "directory that keeps the corpus between runs (default: VXS_FUZZ_CORPUS, or a temporary one)")
	flags.StringArrayVar(&options.targets, "target", nil, "run this target only; repeat for several (see fuzz-targets)")
	return command
}

func run(arguments []string, runner commandRunner) error {
	command := newCommand(runner, os.Stdout, os.Stderr)
	command.SetArgs(arguments)
	return command.Execute()
}
