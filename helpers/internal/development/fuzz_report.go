// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"fmt"
	"strconv"
	"strings"
)

// Keep libFuzzer's counters beside the requested budget. Exit zero alone does
// not establish that a campaign executed any inputs or produced a final report.
type fuzzStatistics struct {
	ExecutedUnits      uint64 `json:"executed_units"`
	AverageExecPerSec  uint64 `json:"average_exec_per_second"`
	NewUnitsAdded      uint64 `json:"new_units_added"`
	SlowestUnitSeconds uint64 `json:"slowest_unit_seconds"`
	PeakRSSMiB         uint64 `json:"peak_rss_mib"`
}

// plus folds the statistics of a later process of the same campaign into
// these: executions and new units add up, the slowest unit and the peak RSS
// are those of the worst process. The caller derives the average rate from the
// total, because the rates of processes of different length do not average.
func (statistics *fuzzStatistics) plus(later *fuzzStatistics) *fuzzStatistics {
	if statistics == nil {
		return later
	}
	return &fuzzStatistics{
		ExecutedUnits:      statistics.ExecutedUnits + later.ExecutedUnits,
		NewUnitsAdded:      statistics.NewUnitsAdded + later.NewUnitsAdded,
		SlowestUnitSeconds: max(statistics.SlowestUnitSeconds, later.SlowestUnitSeconds),
		PeakRSSMiB:         max(statistics.PeakRSSMiB, later.PeakRSSMiB),
	}
}

func parseFuzzStatistics(output string) (*fuzzStatistics, error) {
	statistics := &fuzzStatistics{}
	fields := map[string]*uint64{
		"number_of_executed_units": &statistics.ExecutedUnits,
		"average_exec_per_sec":     &statistics.AverageExecPerSec,
		"new_units_added":          &statistics.NewUnitsAdded,
		"slowest_unit_time_sec":    &statistics.SlowestUnitSeconds,
		"peak_rss_mb":              &statistics.PeakRSSMiB,
	}
	seen := make(map[string]bool, len(fields))
	for _, line := range strings.Split(output, "\n") {
		statistic, ok := strings.CutPrefix(strings.TrimSpace(line), "stat::")
		if !ok {
			continue
		}
		name, value, ok := strings.Cut(statistic, ":")
		destination, recognized := fields[name]
		if !recognized {
			continue // Future libFuzzer counters do not change this contract.
		}
		if !ok || seen[name] {
			return nil, fmt.Errorf("invalid or duplicate libFuzzer statistic %q", name)
		}
		parsed, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid libFuzzer statistic %q: %w", name, err)
		}
		*destination = parsed
		seen[name] = true
	}
	for name := range fields {
		if !seen[name] {
			return nil, fmt.Errorf("libFuzzer did not report %q", name)
		}
	}
	if statistics.ExecutedUnits == 0 || statistics.PeakRSSMiB == 0 {
		return nil, fmt.Errorf("libFuzzer reported no executed input or no measured RSS")
	}
	return statistics, nil
}
