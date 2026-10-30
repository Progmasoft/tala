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
	"Talac/Headers/Progmasoft/Tala/Frontend.h",
	"Talac/Haskell/Host/ffi/tala-frontend.def",
	"Talac/Haskell/Host/src/Progmasoft/Tala/Driver/FFI.hs",
	"Talac/Cli/Commands/Frontend.cpp",
	"Talac/Headers/Progmasoft/Tala/Runtime/AARC.h",
	"Talac/Headers/Progmasoft/Tala/Runtime/Text.h",
	"Talac/Runtime/host.bzl",
	"Talac/Headers/Progmasoft/Tala/Core/Wire.hpp",
	"Talac/Haskell/Core/src/Progmasoft/Tala/Core/Wire.hs",
	"Talac/Headers/Progmasoft/Tala/Core/CorePrep/Wire/Format.hpp",
	"Talac/Haskell/Core/src/Progmasoft/Tala/Core/CorePrep/Wire/Format.hs",
	"Talac/Headers/Progmasoft/Tala/Xpp/Wire.hpp",
	"Talac/Codegen/Xpp/Wire.cpp",
	"Talac/Headers/Progmasoft/Tala/Xmm/Wire.hpp",
	"Talac/Codegen/Xmm/Wire.cpp",
	"Talac/Linker/LinkPlan.cpp",
	"Talac/Linker/NativeLinker.cpp",
	"Talac/Cli/Arguments/Options.cpp",
}

// generators are the sources that may hold the entry symbols; one exists.
var generators = []string{"Talac/Backend/LLVM/Generator.cpp", "Talac/Backend/LLVM/Codegen.cpp"}

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
		{"a frontend function the manifest lacks", Path, "      \"tala_frontend_shutdown\"\n", "      \"tala_frontend_shutdown_now\"\n", "frontend functions"},
		{"a frontend function the header gains", "Talac/Headers/Progmasoft/Tala/Frontend.h", "    tala_frontend_shutdown(void);", "    tala_frontend_shutdown(void);\n    int32_t\n    tala_frontend_added(void);", "tala_frontend_added"},
		{"an export the definition file loses", "Talac/Haskell/Host/ffi/tala-frontend.def", "    tala_frontend_execute\n", "", "tala-frontend.def"},
		{"the frontend ABI version", Path, "\"abi_version\": 2,\n    \"header\": \"Talac/Headers/Progmasoft/Tala/Frontend.h\"", "\"abi_version\": 3,\n    \"header\": \"Talac/Headers/Progmasoft/Tala/Frontend.h\"", "frontend ABI version"},
		{"an output kind's number", Path, "\"TALA_FRONTEND_WARNING_TEXT\": 5", "\"TALA_FRONTEND_WARNING_TEXT\": 6", "TALA_FRONTEND_WARNING_TEXT"},
		{"a status the header gains", "Talac/Headers/Progmasoft/Tala/Frontend.h", "TALA_FRONTEND_OUTPUT_REJECTED = 4", "TALA_FRONTEND_OUTPUT_REJECTED = 4,\n        TALA_FRONTEND_ADDED = 5", "TALA_FRONTEND_ADDED"},
		{"the name of a frontend library", Path, "\"libtala-frontend.so\"", "\"libtala-front.so\"", "libtala-front.so"},
		{"the ownership ABI version", "Talac/Headers/Progmasoft/Tala/Runtime/AARC.h", "#define TALA_AARC_ABI_VERSION UINT32_C(2)", "#define TALA_AARC_ABI_VERSION UINT32_C(3)", "ownership ABI version"},
		{"an ownership function the manifest lacks", Path, "        \"tala_aarc_string_literal\"\n", "        \"tala_aarc_string\"\n", "ownership functions"},
		{"the order of the metadata fields", Path, "        \"abiVersion\",\n        \"flags\",", "        \"flags\",\n        \"abiVersion\",", "TalaAarcTypeMetadata"},
		{"a text function the header gains", "Talac/Headers/Progmasoft/Tala/Runtime/Text.h", "    tala_text_newline(void) TALA_TEXT_NOEXCEPT;", "    tala_text_newline(void) TALA_TEXT_NOEXCEPT;\n    void *\n    tala_text_added(void) TALA_TEXT_NOEXCEPT;", "tala_text_added"},
		{"a text constant's value", Path, "\"TALA_TEXT_FLAG_GROUP\": 32", "\"TALA_TEXT_FLAG_GROUP\": 33", "TALA_TEXT_FLAG_GROUP"},
		{"an entry point the host list loses", "Talac/Runtime/host.bzl", "    \"tala_text_newline\",\n", "", "host.bzl"},
		{"the native Core wire version", "Talac/Headers/Progmasoft/Tala/Core/Wire.hpp", "kCurrentVersion = 10", "kCurrentVersion = 11", "Core wire format"},
		{"the frontend Core wire version", "Talac/Haskell/Core/src/Progmasoft/Tala/Core/Wire.hs", "currentCoreWireVersion = CoreWireVersion 10", "currentCoreWireVersion = CoreWireVersion 11", "Core wire format"},
		{"the CorePrep wire version", Path, "\"magic\": \"TACP\", \"version\": 8", "\"magic\": \"TACP\", \"version\": 9", "CorePrep wire format"},
		{"the Xpp magic", Path, "\"magic\": \"TAPP\"", "\"magic\": \"TAPQ\"", "magic of the Xpp"},
		{"the Xmm wire version", "Talac/Headers/Progmasoft/Tala/Xmm/Wire.hpp", "kCurrentVersion = 7U", "kCurrentVersion = 8U", "Xmm wire format"},
		{"a wire format the manifest lacks", Path, "    { \"name\": \"Xpp\", \"magic\": \"TAPP\", \"version\": 7 },\n", "", "Xpp is not in the manifest"},
		{"the entry symbol on Windows", Path, "\"windows\": \"mainCRTStartup\"", "\"windows\": \"WinMain\"", "entry symbol on windows"},
		{"the entry symbol on Linux", Path, "\"linux\": \"main\"", "\"linux\": \"_start\"", "entry symbol on linux"},
		{"the executable extension on Windows", Path, "\"windows\": \".exe\"", "\"windows\": \".com\"", "executable extension on windows"},
		{"the executable extension on Linux", "Talac/Cli/Arguments/Options.cpp", "#else\n    constexpr const char *kExecutable = \"\";", "#else\n    constexpr const char *kExecutable = \".out\";", "executable extension on linux"},
		{"the Windows linker", Path, "\"linker\": \"lld-link\"", "\"linker\": \"link\"", "Windows linker"},
		{"the Windows runtime library", Path, "\"runtime_library\": \"talart.lib\"", "\"runtime_library\": \"runtime.lib\"", "runtime library"},
		{"the linker on Linux", Path, "\"linux\": {\n        \"linker\": \"cc\"", "\"linux\": {\n        \"linker\": \"ld\"", "linker on linux"},
		{"the runtime library on macOS", Path, "\"macos\": {\n        \"linker\": \"cc\",\n        \"runtime_library\": \"libtalart.a\"", "\"macos\": {\n        \"linker\": \"cc\",\n        \"runtime_library\": \"libruntime.a\"", "runtime library on macos"},
		{"the driver the linker starts", "Talac/Linker/LinkPlan.cpp", "kLinkerDriver = \"cc\"", "kLinkerDriver = \"clang\"", "linker on linux"},
		{"a system import the manifest lacks", Path, "            \"WriteConsoleW\",\n", "", "imported from KERNEL32.dll"},
		{"the shared runtime on Linux", Path, "\"shared_runtime_library\": \"libtalart.so\"", "\"shared_runtime_library\": \"libtalart.so.1\"", "shared runtime library libtalart.so.1"},
		{"a runtime import the shared library loses", "Talac/Linker/NativeLinker.cpp", "\"    tala_text_newline\\n\"\n", "", "imported from talart.dll"},
		{"a system import the linker gains", "Talac/Linker/NativeLinker.cpp", "\"    WriteFile\\n\"", "\"    WriteFile\\n\"\n\"    ExitProcess\\n\"", "ExitProcess"},
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
	if err := os.Remove(filepath.Join(repository, "Talac", "Runtime", "host.bzl")); err != nil {
		t.Fatal(err)
	}
	problems, err := Verify(repository)
	if err != nil || !strings.Contains(strings.Join(problems, "\n"), "host.bzl could not be read") {
		t.Fatalf("a missing source went unnoticed: %v, %v", problems, err)
	}
}
