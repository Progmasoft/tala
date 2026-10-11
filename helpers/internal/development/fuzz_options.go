// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
)

// haskellFuzzTarget names the Haskell feedback campaign in a selection. It is
// not a libFuzzer program and has no entry in the native inventory.
const haskellFuzzTarget = "haskell"

// fuzzTargetsVariable carries a selection of targets to the campaign, like
// the other VXS_FUZZ_ settings. Empty means every target.
const fuzzTargetsVariable = "VXS_FUZZ_TARGETS"

// fuzzOptions are the settings of a fuzz command that its flags may give.
// Each has an environment variable of the same meaning, which CI uses; a
// flag that is given replaces the variable for that run.
type fuzzOptions struct {
	seconds int
	jobs    int
	corpus  string
	targets []string
}

// validate checks every given setting against the limits the campaign itself
// enforces, and every named target against the inventory, so that a wrong
// invocation fails before anything is built.
func (options fuzzOptions) validate(stress bool, inventory []fuzzTarget) error {
	if options.seconds != 0 {
		if _, err := fuzzDuration(stress, strconv.Itoa(options.seconds)); err != nil {
			return errors.New("--seconds must be an integer in [1, 3600]")
		}
	}
	if options.jobs != 0 {
		if _, err := fuzzJobs(strconv.Itoa(options.jobs), runtime.NumCPU()); err != nil {
			return errors.New("--jobs must be an integer in [1, 64]")
		}
	}
	if _, _, err := selectFuzzTargets(inventory, strings.Join(options.targets, ",")); err != nil {
		return err
	}
	return nil
}

// apply hands the given settings to the campaign through its environment
// variables. A setting that was not given leaves its variable as it is.
func (options fuzzOptions) apply(setenv func(string, string) error) error {
	settings := []struct{ name, value string }{}
	if options.seconds != 0 {
		settings = append(settings, struct{ name, value string }{"VXS_FUZZ_SECONDS", strconv.Itoa(options.seconds)})
	}
	if options.jobs != 0 {
		settings = append(settings, struct{ name, value string }{"VXS_FUZZ_JOBS", strconv.Itoa(options.jobs)})
	}
	if options.corpus != "" {
		settings = append(settings, struct{ name, value string }{"VXS_FUZZ_CORPUS", options.corpus})
	}
	if len(options.targets) != 0 {
		settings = append(settings, struct{ name, value string }{fuzzTargetsVariable, strings.Join(options.targets, ",")})
	}
	for _, setting := range settings {
		if err := setenv(setting.name, setting.value); err != nil {
			return fmt.Errorf("could not set %s: %w", setting.name, err)
		}
	}
	return nil
}

// selectFuzzTargets narrows the inventory to a selection: names separated by
// commas, each the corpus name of a target, its program name, or "haskell"
// for the Haskell feedback campaign. The result keeps inventory order
// whatever the order of the selection, so that a report does not depend on
// how the selection was written. An empty selection is everything.
func selectFuzzTargets(inventory []fuzzTarget, selection string) ([]fuzzTarget, bool, error) {
	if strings.TrimSpace(selection) == "" {
		return inventory, true, nil
	}
	wanted := map[string]bool{}
	for _, name := range strings.Split(selection, ",") {
		name = strings.TrimSpace(name)
		if name == "" {
			return nil, false, errors.New("a fuzz target selection holds an empty name")
		}
		wanted[name] = true
	}
	haskell := wanted[haskellFuzzTarget]
	delete(wanted, haskellFuzzTarget)

	var selected []fuzzTarget
	for _, target := range inventory {
		if wanted[target.corpus] || wanted[target.binary] {
			selected = append(selected, target)
			delete(wanted, target.corpus)
			delete(wanted, target.binary)
		}
	}
	if len(wanted) != 0 {
		unknown := make([]string, 0, len(wanted))
		for name := range wanted {
			unknown = append(unknown, name)
		}
		sort.Strings(unknown)
		return nil, false, fmt.Errorf("unknown fuzz target %s; choose from %s",
			strings.Join(unknown, ", "), strings.Join(fuzzTargetNames(inventory), ", "))
	}
	return selected, haskell, nil
}

// fuzzTargetNames lists what a selection may name, in inventory order.
func fuzzTargetNames(inventory []fuzzTarget) []string {
	names := make([]string, 0, len(inventory)+1)
	for _, target := range inventory {
		names = append(names, target.corpus)
	}
	return append(names, haskellFuzzTarget)
}

// fuzzTargetRecord is one row of the inventory as it is shown and exported.
type fuzzTargetRecord struct {
	Name          string `json:"name"`
	Program       string `json:"program"`
	Label         string `json:"label"`
	MaximumLength int    `json:"maximumInputLength"`
	MemoryLimit   int    `json:"memoryLimitMiB"`
	Frontend      bool   `json:"loadsFrontend"`
	Threaded      bool   `json:"threaded"`
	Heavy         bool   `json:"heavy"`
}

func fuzzTargetRecords(inventory []fuzzTarget) ([]fuzzTargetRecord, error) {
	records := make([]fuzzTargetRecord, 0, len(inventory))
	for _, target := range inventory {
		length, err := strconv.Atoi(target.maxLength)
		if err != nil {
			return nil, fmt.Errorf("fuzz target %s has no numeric input limit: %q", target.corpus, target.maxLength)
		}
		memory, err := strconv.Atoi(target.rssLimit)
		if err != nil {
			return nil, fmt.Errorf("fuzz target %s has no numeric memory limit: %q", target.corpus, target.rssLimit)
		}
		records = append(records, fuzzTargetRecord{
			Name:          target.corpus,
			Program:       target.binary,
			Label:         target.label,
			MaximumLength: length,
			MemoryLimit:   memory,
			Frontend:      target.frontend,
			Threaded:      target.threaded,
			Heavy:         isHeavyFuzzTarget(target),
		})
	}
	return records, nil
}

// writeFuzzTargets prints the inventory a fuzz command runs, as a table for a
// person or as JSON for a script.
func writeFuzzTargets(output io.Writer, inventory []fuzzTarget, asJSON bool) error {
	records, err := fuzzTargetRecords(inventory)
	if err != nil {
		return err
	}
	if asJSON {
		encoder := json.NewEncoder(output)
		encoder.SetIndent("", "  ")
		return encoder.Encode(records)
	}
	table := tabwriter.NewWriter(output, 0, 4, 2, ' ', 0)
	fmt.Fprintln(table, "NAME\tPROGRAM\tINPUT LIMIT\tMEMORY LIMIT\tFRONTEND\tTHREADED\tHEAVY")
	mark := func(value bool) string {
		if value {
			return "yes"
		}
		return "-"
	}
	for _, record := range records {
		fmt.Fprintf(table, "%s\t%s\t%d bytes\t%d MiB\t%s\t%s\t%s\n", record.Name, record.Program,
			record.MaximumLength, record.MemoryLimit, mark(record.Frontend), mark(record.Threaded), mark(record.Heavy))
	}
	fmt.Fprintf(table, "%s\t(Haskell feedback campaign)\t-\t-\t-\t-\t-\n", haskellFuzzTarget)
	return table.Flush()
}
