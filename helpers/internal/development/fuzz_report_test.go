// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"strings"
	"testing"
)

const fuzzFinalStatistics = "INFO: seed corpus loaded\r\n" +
	"stat::number_of_executed_units: 155\r\n" +
	"stat::average_exec_per_sec:     5\r\n" +
	"stat::new_units_added:          139\r\n" +
	"stat::slowest_unit_time_sec:    0\r\n" +
	"stat::peak_rss_mb:              196\r\n"

func TestFuzzStatisticsPreserveExecutionEvidence(t *testing.T) {
	statistics, err := parseFuzzStatistics(fuzzFinalStatistics + "stat::future_counter: 42\n")
	if err != nil {
		t.Fatal(err)
	}
	if statistics.ExecutedUnits != 155 || statistics.AverageExecPerSec != 5 ||
		statistics.NewUnitsAdded != 139 || statistics.SlowestUnitSeconds != 0 || statistics.PeakRSSMiB != 196 {
		t.Fatalf("lost campaign evidence: %+v", statistics)
	}
}

func TestFuzzStatisticsRejectIncompleteOrContradictoryReports(t *testing.T) {
	for name, report := range map[string]string{
		"missing":     "INFO: clean exit without final statistics\n",
		"truncated":   strings.ReplaceAll(fuzzFinalStatistics, "stat::peak_rss_mb:              196\r\n", ""),
		"duplicate":   fuzzFinalStatistics + "stat::number_of_executed_units: 1\n",
		"zero inputs": strings.ReplaceAll(fuzzFinalStatistics, "units: 155", "units: 0"),
		"negative":    strings.ReplaceAll(fuzzFinalStatistics, "units: 155", "units: -1"),
		"overflow":    strings.ReplaceAll(fuzzFinalStatistics, "units: 155", "units: 18446744073709551616"),
		"fraction":    strings.ReplaceAll(fuzzFinalStatistics, "units: 155", "units: 1.5"),
		"no RSS":      strings.ReplaceAll(fuzzFinalStatistics, "196", "0"),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseFuzzStatistics(report); err == nil {
				t.Fatal("accepted a report without reliable execution evidence")
			}
		})
	}
}
