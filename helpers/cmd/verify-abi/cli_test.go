// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

func execute(root string, arguments ...string) (string, error) {
	var output bytes.Buffer
	command := newCommand(&output, &output, root)
	command.SetArgs(arguments)
	err := command.Execute()
	return output.String(), err
}

func TestTheManifestOfThisCheckoutIsAccepted(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	output, err := execute("", "--root", root)
	if err != nil || !strings.Contains(output, "agrees with the sources") {
		t.Fatalf("%q, %v", output, err)
	}
}

func TestACheckoutWithoutAManifestAndAnUnknownInvocationFail(t *testing.T) {
	if _, err := execute("", "--root", t.TempDir()); err == nil {
		t.Fatal("a checkout without a manifest was accepted")
	}
	for _, arguments := range [][]string{{"extra"}, {"-Root", "."}, {"--unknown"}} {
		if _, err := execute(t.TempDir(), arguments...); err == nil {
			t.Fatalf("%v was accepted", arguments)
		}
	}
	if output, err := execute(t.TempDir(), "--help"); err != nil || !strings.Contains(output, "abi-manifest.json") {
		t.Fatalf("help: %q, %v", output, err)
	}
}
