// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"strings"
	"testing"
)

func TestHaskellReportRequiresActualProductionCoverage(t *testing.T) {
	valid := "HPC_FUZZ_RESULT\nstage=lexer\nexecuted_units=3378\ncovered_ticks=958\navailable_ticks=36407\nnew_units_added=38\nseed=12345\n"
	for _, report := range []string{valid, strings.ReplaceAll(valid, "\n", "\r\n")} {
		values, err := parseHaskellFuzzStatistics(report, "lexer")
		if err != nil || values["covered_ticks"] != 958 {
			t.Fatalf("valid coverage rejected: %v / %v", values, err)
		}
	}
	for _, bad := range []string{
		"process exited successfully",
		strings.Replace(valid, "stage=lexer", "stage=parser", 1),
		strings.Replace(valid, "executed_units=3378", "executed_units=0", 1),
		strings.Replace(valid, "covered_ticks=958", "covered_ticks=0", 1),
		strings.Replace(valid, "available_ticks=36407", "available_ticks=10", 1),
		strings.Replace(valid, "seed=12345\n", "", 1),
		valid + "seed=54321\n",
		valid + "stage=lexer\n",
		strings.Replace(valid, "new_units_added=38", "new_units_added=-1", 1),
	} {
		if _, err := parseHaskellFuzzStatistics(bad, "lexer"); err == nil {
			t.Fatalf("missing/malformed coverage report accepted: %q", bad)
		}
	}
}

func TestNativeFuzzInventoryIsComponentOwnedAndBounded(t *testing.T) {
	labels, corpora := map[string]bool{}, map[string]bool{}
	for _, target := range nativeFuzzTargets() {
		if labels[target.label] || corpora[target.corpus] {
			t.Fatalf("duplicate target/corpus: %+v", target)
		}
		labels[target.label], corpora[target.corpus] = true, true
		if !strings.HasPrefix(target.label, "//") || !strings.HasSuffix(target.label, ":"+target.binary) || target.maxLength == "" || target.rssLimit == "" {
			t.Fatalf("unbounded or disconnected target: %+v", target)
		}
	}
	for _, label := range []string{"//Talac/Cli/Fuzzing:cli_fuzzer", "//Interactive/Fuzzing:repl_fuzzer", "//Talac/Runtime/AARC/Fuzzing:ownership_fuzzer"} {
		if !labels[label] {
			t.Fatalf("missing component-local target %s", label)
		}
	}
}

func TestFuzzProcessWatchdogDoesNotLimitBuildTools(t *testing.T) {
	for _, item := range []struct {
		name    string
		args    []string
		seconds int
	}{
		{"source_fuzz_smoke.exe", nil, 240},
		{"source_execution_smoke.exe", nil, 240},
		{"source_expression_smoke.exe", nil, 240},
		{"source_feature_smoke.exe", nil, 240},
		{"source_console_smoke.exe", nil, 240},
		{"wire_fuzzer", []string{"-max_total_time=30"}, 120},
		{"frontend-fuzz.exe", []string{"parser", "900"}, 1200},
		{"cabal", []string{"build", "all"}, 0},
		{"bazel", []string{"build", "//Talac:talac"}, 0},
	} {
		if got := fuzzProcessSeconds(item.name, item.args); got != item.seconds {
			t.Fatalf("%s timeout = %d; want %d", item.name, got, item.seconds)
		}
	}
}
