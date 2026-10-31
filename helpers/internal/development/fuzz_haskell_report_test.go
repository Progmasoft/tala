// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHaskellReportFileIgnoresRuntimeDiagnosticsButNotMissingEvidence(t *testing.T) {
	report := "stage=lexer\nexecuted_units=3255\ncovered_ticks=839\navailable_ticks=36407\nnew_units_added=33\nseed=12345\n"
	// The GHC runtime may print to stderr after the report; captured output
	// interleaves both streams.
	output := "HPC_FUZZ_RESULT\r\n" + strings.ReplaceAll(report, "\n", "\r\n") +
		"\r\nonIOComplete: failed to grab table semaphore (res=2439, err=-1), dropping request 0x6\n"
	file := filepath.Join(t.TempDir(), "campaign.txt")
	if err := os.WriteFile(file, []byte(report), 0o600); err != nil {
		t.Fatal(err)
	}
	values, err := readHaskellFuzzReport(file, output, "lexer")
	if err != nil || values["covered_ticks"] != 839 || values["executed_units"] != 3255 {
		t.Fatalf("completed campaign rejected: %v / %v", values, err)
	}
	// The same trailing diagnostics are still not statistics.
	if _, err := parseHaskellFuzzStatistics(output, "lexer"); err == nil {
		t.Fatal("runtime diagnostics were accepted as campaign statistics")
	}
	// A report file without a run that announced it is stale evidence.
	if _, err := readHaskellFuzzReport(file, "process exited successfully", "lexer"); err == nil {
		t.Fatal("report file accepted without a completed campaign")
	}
	if _, err := readHaskellFuzzReport(filepath.Join(t.TempDir(), "missing.txt"), output, "lexer"); err == nil {
		t.Fatal("missing report file accepted")
	}
	if _, err := readHaskellFuzzReport(file, output, "parser"); err == nil {
		t.Fatal("report for another stage accepted")
	}
	if err := os.WriteFile(file, []byte(strings.Replace(report, "covered_ticks=839", "covered_ticks=0", 1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readHaskellFuzzReport(file, output, "lexer"); err == nil {
		t.Fatal("report without production coverage accepted")
	}
}
