// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package abimanifest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// described are the sources the manifest is compared with.
var described = []string{
	Path,
	"Compiler/Headers/Visual/XSharp/Frontend.h",
	"Compiler/Haskell/Driver/ffi/vxs-frontend.def",
	"Compiler/Haskell/Driver/src/Visual/XSharp/Driver/FFI.hs",
	"Compiler/Cli/Commands/Frontend.cpp",
	"Compiler/Headers/Visual/XSharp/Runtime/AARC.h",
	"Compiler/Headers/Visual/XSharp/Runtime/Text.h",
	"Compiler/Runtime/host.bzl",
	"Compiler/Headers/Visual/XSharp/Core/Wire.hpp",
	"Compiler/Haskell/Core/src/Visual/XSharp/Core/Wire.hs",
	"Compiler/Headers/Visual/XSharp/Core/CorePrep/Wire/Format.hpp",
	"Compiler/Haskell/Core/src/Visual/XSharp/Core/CorePrep/Wire/Format.hs",
	"Compiler/Headers/Visual/XSharp/Xpp/Wire.hpp",
	"Compiler/Codegen/Xpp/Wire.cpp",
	"Compiler/Headers/Visual/XSharp/Xmm/Wire.hpp",
	"Compiler/Codegen/Xmm/Wire.cpp",
	"Compiler/Linker/NativeLinker.cpp",
}

// generators are the sources that may hold the entry symbols; one exists.
var generators = []string{"Compiler/Backend/LLVM/Generator.cpp", "Compiler/Backend/LLVM/Codegen.cpp"}

func realRepository(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// copyOf returns a directory that holds the described sources of the real
// repository, so that a test can change one of them.
func copyOf(t *testing.T) string {
	t.Helper()
	real := realRepository(t)
	copied := t.TempDir()
	transfer := func(name string, required bool) {
		content, err := os.ReadFile(filepath.Join(real, filepath.FromSlash(name)))
		if err != nil {
			if required {
				t.Fatal(err)
			}
			return
		}
		target := filepath.Join(copied, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, content, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range described {
		transfer(name, true)
	}
	for _, name := range generators {
		transfer(name, false)
	}
	return copied
}

func change(t *testing.T, repository string, name string, old string, replacement string) {
	t.Helper()
	path := filepath.Join(repository, filepath.FromSlash(name))
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ReplaceAll(string(content), "\r\n", "\n")
	if strings.Count(text, old) != 1 {
		t.Fatalf("%s holds %q %d times, want once", name, old, strings.Count(text, old))
	}
	if err := os.WriteFile(path, []byte(strings.Replace(text, old, replacement, 1)), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestTheManifestAgreesWithTheRepository(t *testing.T) {
	problems, err := Verify(realRepository(t))
	if err != nil {
		t.Fatal(err)
	}
	if len(problems) != 0 {
		t.Fatalf("the manifest differs from the sources:\n%s", strings.Join(problems, "\n"))
	}
}

// Each case changes one fact on one side only and names a word the report
// of the difference must hold.
func TestEveryStatementOfTheManifestIsChecked(t *testing.T) {
	cases := []struct {
		name, file, old, replacement, report string
	}{
		{"a frontend function the manifest lacks", Path, "      \"vxs_frontend_shutdown\"\n", "      \"vxs_frontend_shutdown_now\"\n", "frontend functions"},
		{"a frontend function the header gains", "Compiler/Headers/Visual/XSharp/Frontend.h", "    vxs_frontend_shutdown(void);", "    vxs_frontend_shutdown(void);\n    int32_t\n    vxs_frontend_added(void);", "vxs_frontend_added"},
		{"an export the definition file loses", "Compiler/Haskell/Driver/ffi/vxs-frontend.def", "    vxs_frontend_execute\n", "", "vxs-frontend.def"},
		{"the frontend ABI version", Path, "\"abi_version\": 2,\n    \"header\": \"Compiler/Headers/Visual/XSharp/Frontend.h\"", "\"abi_version\": 3,\n    \"header\": \"Compiler/Headers/Visual/XSharp/Frontend.h\"", "frontend ABI version"},
		{"an output kind's number", Path, "\"VXS_FRONTEND_WARNING_TEXT\": 5", "\"VXS_FRONTEND_WARNING_TEXT\": 6", "VXS_FRONTEND_WARNING_TEXT"},
		{"a status the header gains", "Compiler/Headers/Visual/XSharp/Frontend.h", "VXS_FRONTEND_OUTPUT_REJECTED = 4", "VXS_FRONTEND_OUTPUT_REJECTED = 4,\n        VXS_FRONTEND_ADDED = 5", "VXS_FRONTEND_ADDED"},
		{"the name of a frontend library", Path, "\"libvxs-frontend.so\"", "\"libvxs-front.so\"", "libvxs-front.so"},
		{"the ownership ABI version", "Compiler/Headers/Visual/XSharp/Runtime/AARC.h", "#define VXS_AARC_ABI_VERSION UINT32_C(2)", "#define VXS_AARC_ABI_VERSION UINT32_C(3)", "ownership ABI version"},
		{"an ownership function the manifest lacks", Path, "        \"vxs_aarc_string_literal\"\n", "        \"vxs_aarc_string\"\n", "ownership functions"},
		{"the order of the metadata fields", Path, "        \"abiVersion\",\n        \"flags\",", "        \"flags\",\n        \"abiVersion\",", "VxsAarcTypeMetadata"},
		{"a text function the header gains", "Compiler/Headers/Visual/XSharp/Runtime/Text.h", "    vxs_text_newline(void) VXS_TEXT_NOEXCEPT;", "    vxs_text_newline(void) VXS_TEXT_NOEXCEPT;\n    void *\n    vxs_text_added(void) VXS_TEXT_NOEXCEPT;", "vxs_text_added"},
		{"a text constant's value", Path, "\"VXS_TEXT_FLAG_GROUP\": 32", "\"VXS_TEXT_FLAG_GROUP\": 33", "VXS_TEXT_FLAG_GROUP"},
		{"an entry point the host list loses", "Compiler/Runtime/host.bzl", "    \"vxs_text_newline\",\n", "", "host.bzl"},
		{"the native Core wire version", "Compiler/Headers/Visual/XSharp/Core/Wire.hpp", "kCurrentVersion = 10", "kCurrentVersion = 11", "Core wire format"},
		{"the frontend Core wire version", "Compiler/Haskell/Core/src/Visual/XSharp/Core/Wire.hs", "currentCoreWireVersion = CoreWireVersion 10", "currentCoreWireVersion = CoreWireVersion 11", "Core wire format"},
		{"the CorePrep wire version", Path, "\"magic\": \"VXCP\", \"version\": 8", "\"magic\": \"VXCP\", \"version\": 9", "CorePrep wire format"},
		{"the Xpp magic", Path, "\"magic\": \"VXPP\"", "\"magic\": \"VXPQ\"", "magic of the Xpp"},
		{"the Xmm wire version", "Compiler/Headers/Visual/XSharp/Xmm/Wire.hpp", "kCurrentVersion = 7U", "kCurrentVersion = 8U", "Xmm wire format"},
		{"a wire format the manifest lacks", Path, "    { \"name\": \"Xpp\", \"magic\": \"VXPP\", \"version\": 7 },\n", "", "Xpp is not in the manifest"},
		{"the entry symbol on Windows", Path, "\"windows\": \"mainCRTStartup\"", "\"windows\": \"WinMain\"", "entry symbol on windows"},
		{"the entry symbol on Linux", Path, "\"linux\": \"main\"", "\"linux\": \"_start\"", "entry symbol on linux"},
		{"the executable extension", Path, "\"extension\": \".vxse\"", "\"extension\": \".exe\"", "extension"},
		{"the Windows linker", Path, "\"linker\": \"lld-link\"", "\"linker\": \"link\"", "Windows linker"},
		{"the Windows runtime library", Path, "\"runtime_library\": \"vxs-runtime.lib\"", "\"runtime_library\": \"runtime.lib\"", "runtime library"},
		{"the linker on Linux", Path, "\"linux\": {\n        \"linker\": \"cc\"", "\"linux\": {\n        \"linker\": \"ld\"", "linker on linux"},
		{"the runtime library on macOS", Path, "\"macos\": {\n        \"linker\": \"cc\",\n        \"runtime_library\": \"libvxs-runtime.a\"", "\"macos\": {\n        \"linker\": \"cc\",\n        \"runtime_library\": \"libruntime.a\"", "runtime library on macos"},
		{"the driver the linker starts", "Compiler/Linker/NativeLinker.cpp", "kLinkerDriver = \"cc\"", "kLinkerDriver = \"clang\"", "linker on linux"},
		{"a system import the manifest lacks", Path, "            \"WriteConsoleW\",\n", "", "imported from KERNEL32.dll"},
		{"a system import the linker gains", "Compiler/Linker/NativeLinker.cpp", "\"    WriteFile\\n\"", "\"    WriteFile\\n\"\n\"    ExitProcess\\n\"", "ExitProcess"},
	}
	for _, test := range cases {
		repository := copyOf(t)
		change(t, repository, test.file, test.old, test.replacement)
		problems, err := Verify(repository)
		if err != nil {
			t.Fatalf("%s: %v", test.name, err)
		}
		if len(problems) == 0 || !strings.Contains(strings.Join(problems, "\n"), test.report) {
			t.Fatalf("%s went unnoticed or was reported without %q:\n%s", test.name, test.report, strings.Join(problems, "\n"))
		}
	}
}

func TestAStatementNothingChecksIsRefused(t *testing.T) {
	repository := copyOf(t)
	change(t, repository, Path, "\"schema\": 1,", "\"schema\": 1,\n  \"calling_convention\": \"unchecked\",")
	if _, err := Verify(repository); err == nil || !strings.Contains(err.Error(), "calling_convention") {
		t.Fatalf("an unknown field was accepted: %v", err)
	}
	repository = copyOf(t)
	change(t, repository, Path, "\"schema\": 1,", "\"schema\": 2,")
	if problems, err := Verify(repository); err != nil || len(problems) == 0 {
		t.Fatalf("another schema was accepted: %v, %v", problems, err)
	}
	if _, err := Verify(t.TempDir()); err == nil {
		t.Fatal("a repository without a manifest was accepted")
	}
}

func TestAMissingSourceIsADifference(t *testing.T) {
	repository := copyOf(t)
	if err := os.Remove(filepath.Join(repository, "Compiler", "Runtime", "host.bzl")); err != nil {
		t.Fatal(err)
	}
	problems, err := Verify(repository)
	if err != nil || !strings.Contains(strings.Join(problems, "\n"), "host.bzl could not be read") {
		t.Fatalf("a missing source went unnoticed: %v, %v", problems, err)
	}
}
