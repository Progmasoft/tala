// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

// execution-cases writes the shared execution test tables from their case
// files and checks that the committed tables are current.
package main

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/Progmasoft/tala/helpers/internal/executioncases"
	"github.com/spf13/cobra"
)

// newCommand builds the command line. Results go to the first writer and the
// names of stale tables to the second.
func newCommand(output io.Writer, problems io.Writer) *cobra.Command {
	var root string
	command := &cobra.Command{
		Use:   "execution-cases",
		Short: "Generate and check the execution test tables",
		Long: `The cases under Talac/Fuzzing/Cases own the programs that the Haskell
frontend tests run in a reference evaluator and that source_execution_smoke
runs through LLVM. This command writes both tables from those files.`,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	command.SetOut(output)
	command.SetErr(problems)
	command.PersistentFlags().StringVar(&root, "root", "", "repository root (default: found above the working directory)")
	resolve := func() (string, error) {
		if root != "" {
			return root, nil
		}
		return executioncases.FindRoot(".")
	}
	command.AddCommand(&cobra.Command{
		Use:   "generate",
		Short: "Write every table that differs from what the case files generate",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			directory, err := resolve()
			if err != nil {
				return err
			}
			written, err := executioncases.Write(directory)
			if err != nil {
				return err
			}
			for _, path := range written {
				fmt.Fprintln(output, "wrote", path)
			}
			if len(written) == 0 {
				fmt.Fprintln(output, "Every generated table is current.")
			}
			return nil
		},
	})
	command.AddCommand(&cobra.Command{
		Use:   "check",
		Short: "Fail when a committed table is not what the case files generate",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			directory, err := resolve()
			if err != nil {
				return err
			}
			stale, err := executioncases.Stale(directory)
			if err != nil {
				return err
			}
			for _, path := range stale {
				fmt.Fprintln(problems, "stale:", path)
			}
			if len(stale) != 0 {
				return errors.New("generated tables are stale; run `go -C helpers run ./cmd/execution-cases generate`")
			}
			fmt.Fprintln(output, "Every generated table is current.")
			return nil
		},
	})
	return command
}

func main() {
	if err := newCommand(os.Stdout, os.Stderr).Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "execution-cases:", err)
		os.Exit(1)
	}
}
