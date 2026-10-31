// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"reflect"
	"testing"
)

func TestCombinedSanitizerHasBothFailFastRuntimes(t *testing.T) {
	for _, example := range []struct {
		host   hostKind
		config string
	}{{hostWindows, "asan-ubsan-windows"}, {hostMacOS, "asan-ubsan-macos"}, {hostLinux, "asan-ubsan-linux"}} {
		selected, err := selectSanitizer(host{kind: example.host}, "address-undefined")
		if err != nil || selected.config != example.config || len(selected.environment) != 2 {
			t.Fatalf("combined profile: %#v, %v", selected, err)
		}
		if !reflect.DeepEqual(sanitizerProbeModes(selected.config), []string{"address", "undefined"}) {
			t.Fatal("combined instrumentation must prove both detectors")
		}
	}
	selected, err := selectSanitizer(host{kind: hostWindows}, "undefined")
	if err != nil || selected.config != "ubsan-windows" {
		t.Fatalf("Windows UBSan rejected: %#v, %v", selected, err)
	}
}

func TestProbeRequiresCheckerAndSpecificFailureNotAnyCrash(t *testing.T) {
	for _, example := range []struct{ mode, good string }{
		{"address", "ERROR: AddressSanitizer: heap-use-after-free"},
		{"undefined", "runtime error: signed integer overflow: 2147483647 + 1"},
		{"thread", "WARNING: ThreadSanitizer: data race"},
	} {
		if !expectedSanitizerReport(example.mode, example.good) {
			t.Fatalf("expected report rejected: %s", example.good)
		}
		for _, bad := range []string{"", "DLL missing", "access violation", "ThreadSanitizer: unexpected memory mapping", "undefined symbol"} {
			if expectedSanitizerReport(example.mode, bad) {
				t.Fatalf("unrelated failure accepted: %q", bad)
			}
		}
	}
}
