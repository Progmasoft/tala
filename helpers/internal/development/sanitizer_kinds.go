// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"text/tabwriter"
)

// allSanitizers is the kind that stands for every checker the host has.
const allSanitizers = "all"

// sanitizerKinds are the kinds `sanitize` accepts, in the order they are
// listed. Their aliases (asan, ubsan, tsan) select the same suites.
var sanitizerKinds = []string{"address", "undefined", "address-undefined", "thread"}

// sanitizerSupport is what one kind means on one host.
type sanitizerSupport struct {
	Kind          string `json:"kind"`
	Name          string `json:"name,omitempty"`
	Configuration string `json:"bazelConfiguration,omitempty"`
	Supported     bool   `json:"supported"`
	Reason        string `json:"reason,omitempty"`
}

// hostSanitizers asks the selection itself what each kind is on this host, so
// that the list cannot say something the command would not do.
func hostSanitizers(currentHost host) []sanitizerSupport {
	support := make([]sanitizerSupport, 0, len(sanitizerKinds))
	for _, kind := range sanitizerKinds {
		selected, err := selectSanitizer(currentHost, kind)
		if err != nil {
			support = append(support, sanitizerSupport{Kind: kind, Reason: err.Error()})
			continue
		}
		support = append(support, sanitizerSupport{Kind: kind, Name: selected.name, Configuration: selected.config, Supported: true})
	}
	return support
}

// comprehensiveSanitizers are the kinds `sanitize all` runs: every checker the
// host has, each once. The combined address and undefined-behaviour build
// stands for both of its parts, so they are not run a second time alone.
func comprehensiveSanitizers(currentHost host) []string {
	var kinds []string
	for _, kind := range []string{"address-undefined", "thread"} {
		if _, err := selectSanitizer(currentHost, kind); err == nil {
			kinds = append(kinds, kind)
		}
	}
	return kinds
}

// writeSanitizers prints what each kind is on this host, as a table for a
// person or as JSON for a script.
func writeSanitizers(output io.Writer, currentHost host, asJSON bool) error {
	support := hostSanitizers(currentHost)
	if asJSON {
		encoder := json.NewEncoder(output)
		encoder.SetIndent("", "  ")
		return encoder.Encode(support)
	}
	fmt.Fprintf(output, "Host: %s\n\n", currentHost.name)
	table := tabwriter.NewWriter(output, 0, 4, 2, ' ', 0)
	fmt.Fprintln(table, "KIND\tCHECKER\tBAZEL CONFIGURATION\tON THIS HOST")
	for _, entry := range support {
		if entry.Supported {
			fmt.Fprintf(table, "%s\t%s\t%s\tsupported\n", entry.Kind, entry.Name, entry.Configuration)
			continue
		}
		fmt.Fprintf(table, "%s\t-\t-\tnot supported: %s\n", entry.Kind, entry.Reason)
	}
	if err := table.Flush(); err != nil {
		return err
	}
	fmt.Fprintf(output, "\n`sanitize %s` runs: %s.\n", allSanitizers, strings.Join(comprehensiveSanitizers(currentHost), ", "))
	return nil
}

// runSanitizerSuites runs the native suites under each of the given kinds and
// reports every outcome. A kind that fails does not stop the ones after it:
// the checkers find different defects, and one report of all of them is worth
// more than the first. The error names each kind that failed.
func runSanitizerSuites(kinds []string, output io.Writer, run func(kind string) error) error {
	if len(kinds) == 0 {
		return errors.New("this host has no sanitizer to run")
	}
	type outcome struct {
		kind string
		err  error
	}
	outcomes := make([]outcome, 0, len(kinds))
	for _, kind := range kinds {
		outcomes = append(outcomes, outcome{kind, run(kind)})
	}
	if len(kinds) == 1 {
		return outcomes[0].err
	}
	fmt.Fprintln(output, "\nSanitizer summary:")
	var failures []error
	for _, result := range outcomes {
		if result.err != nil {
			fmt.Fprintf(output, "  FAILED  %s\n", result.kind)
			failures = append(failures, fmt.Errorf("%s: %w", result.kind, result.err))
			continue
		}
		fmt.Fprintf(output, "  passed  %s\n", result.kind)
	}
	return errors.Join(failures...)
}
