// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// Command verify-abi compares Documents/abi-manifest.json with the sources
// it describes.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/Progmasoft/tala/helpers/internal/abimanifest"
	"github.com/Progmasoft/tala/helpers/internal/repository"
	"github.com/spf13/cobra"
)

const usage = `Compare Documents/abi-manifest.json with the sources.

The manifest states the binary interfaces of the compiler: the C functions of
the frontend library and of the runtime, the numbers they exchange, the
versions of the wire formats, and how an executable is entered and linked.
Every entry is read back from the header, module-definition file or source
that defines it, and a difference in either direction fails the command.`

func main() {
	if err := newCommand(os.Stdout, os.Stderr, "").Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func newCommand(output, errorOutput io.Writer, root string) *cobra.Command {
	command := &cobra.Command{
		Use:           "verify-abi",
		Short:         "Compare the ABI manifest with the sources it describes.",
		Long:          usage,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			checkout := root
			if checkout == "" {
				directory, err := os.Getwd()
				if err != nil {
					return err
				}
				if checkout, err = repository.FindRoot(directory); err != nil {
					return err
				}
			}
			problems, err := abimanifest.Verify(checkout)
			if err != nil {
				return err
			}
			for _, problem := range problems {
				fmt.Fprintln(errorOutput, problem)
			}
			if len(problems) != 0 {
				return fmt.Errorf("%s differs from the sources in %d places", abimanifest.Path, len(problems))
			}
			fmt.Fprintf(output, "%s agrees with the sources.\n", abimanifest.Path)
			return nil
		},
	}
	command.Flags().StringVar(&root, "root", root, "the checkout to verify (default: the one that holds the working directory)")
	command.SetOut(output)
	command.SetErr(errorOutput)
	command.CompletionOptions.DisableDefaultCmd = true
	return command
}
