// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"strings"
	"testing"
)

func TestThreadFuzzPlanInstrumentsOnlyThreadedTargets(t *testing.T) {
	targets := threadFuzzTargets()
	if len(targets) != 1 || targets[0].binary != "ownership_fuzzer" || targets[0].frontend {
		t.Fatalf("unexpected threaded targets: %+v", targets)
	}
	for _, example := range []struct{ fuzz, sanitizer, runtime string }{
		{"fuzz-linux", "tsan-linux", ""},
		{"fuzz-macos", "tsan-macos", "/llvm/libclang_rt.fuzzer_osx.a"},
	} {
		plan := threadFuzzBuildArguments(example.fuzz, example.sanitizer, example.runtime)
		joined := strings.Join(plan, " ")
		for _, required := range []string{"--config=" + example.fuzz, "--config=" + example.sanitizer, "//Talac/Runtime/AARC/Fuzzing:ownership_fuzzer"} {
			if !strings.Contains(joined, required) {
				t.Fatalf("thread plan lacks %s: %v", required, plan)
			}
		}
		// ASan and TSan runtimes cannot coexist in one executable.
		if strings.Contains(joined, "asan") || strings.Contains(joined, "_smoke") {
			t.Fatalf("thread plan mixes incompatible instrumentation: %v", plan)
		}
		if (example.runtime != "") != strings.Contains(joined, "--linkopt=") {
			t.Fatalf("libFuzzer runtime link option mismatch: %v", plan)
		}
	}
}

func TestThreadFuzzIsRejectedWhereNoRuntimeExists(t *testing.T) {
	// Windows has no Clang ThreadSanitizer runtime. The campaign must fail
	// before building or executing anything instead of reporting success.
	err := runThreadFuzzCampaign(t.TempDir(), host{kind: hostWindows, executable: ".exe"}, nil)
	if err == nil || !strings.Contains(err.Error(), "does not support Windows ThreadSanitizer") {
		t.Fatalf("unsupported host was not rejected explicitly: %v", err)
	}
}
