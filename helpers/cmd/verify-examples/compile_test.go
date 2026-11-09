// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeTalacVariable makes the test binary act as talac: it rejects a source
// that contains REJECT with a diagnostic that names the entry it was given,
// and fails without one, as a crash would, on a source that contains CRASH.
const fakeTalacVariable = "VERIFY_EXAMPLES_FAKE_TALAC"

func TestMain(m *testing.M) {
	if os.Getenv(fakeTalacVariable) == "1" {
		os.Exit(fakeTalac(os.Args[1:]))
	}
	os.Exit(m.Run())
}

func fakeTalac(arguments []string) int {
	if len(arguments) != 3 || arguments[2] != "--emit=core" || !strings.HasPrefix(arguments[1], "--entry=") {
		fmt.Println("unexpected arguments", arguments)
		return 2
	}
	source, err := os.ReadFile(arguments[0])
	if err != nil {
		fmt.Println(err)
		return 2
	}
	if strings.Contains(string(source), "CRASH") {
		fmt.Println("talac: internal error")
		return 1
	}
	if strings.Contains(string(source), "REJECT") {
		fmt.Printf("%s:7:9: TAP0006: rejected %s\n", filepath.Base(arguments[0]), arguments[1])
		return 1
	}
	// talac writes its output next to the input; the check must not let
	// that land in the repository.
	if err := os.WriteFile(strings.TrimSuffix(arguments[0], ".tala")+".core", nil, 0o644); err != nil {
		fmt.Println(err)
		return 2
	}
	return 0
}

func tala(class string, rejected bool) string {
	body := "Console.Println(\"hi\");"
	if rejected {
		body = "REJECT"
	}
	return source(class, body)
}

func source(class, body string) string {
	return "-- comment\r\nnamespace Examples.Fixture;\r\n\r\npublic class Helper {\r\n}\r\n\r\npublic class " + class +
		" {\r\n    public static void Main() {\r\n        " + body + "\r\n    }\r\n}\r\n"
}

// compileFixture makes a catalogue whose talac column is given per program,
// with a Tala source that the fake talac accepts or rejects.
func compileFixture(t *testing.T, column map[string]string, rejected map[string]bool) string {
	t.Helper()
	root := t.TempDir()
	var readme strings.Builder
	readme.WriteString("| Program | Surface | Compiles with talac |\n| --- | --- | --- |\n")
	for name, cell := range column {
		readme.WriteString("| `" + name + "` | fixture | " + cell + " |\n")
		directory := filepath.Join(root, "Examples", name)
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(directory, name+".tala"), []byte(tala(name, rejected[name])), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "Examples", "README.md"), []byte(readme.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv(fakeTalacVariable, "1")
	return root
}

func testBinary(t *testing.T) string {
	t.Helper()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return binary
}

func TestCompileExamplesAcceptsACatalogThatMatchesTalac(t *testing.T) {
	root := compileFixture(t,
		map[string]string{"Alpha": "yes", "Beta": "no: `yield`"},
		map[string]bool{"Beta": true})
	compiled, err := compileExamples(root, testBinary(t))
	if err != nil {
		t.Fatal(err)
	}
	if compiled != 1 {
		t.Fatalf("compiled = %d, want 1", compiled)
	}
	if _, err := os.Stat(filepath.Join(root, "Examples", "Alpha", "Alpha.core")); err == nil {
		t.Fatal("the output of talac landed next to the example")
	}
}

func TestCompileExamplesFailsWhenTheColumnIsWrongEitherWay(t *testing.T) {
	root := compileFixture(t,
		map[string]string{"Alpha": "yes", "Beta": "no: fields"},
		map[string]bool{"Alpha": true})
	_, err := compileExamples(root, testBinary(t))
	if err == nil {
		t.Fatal("a wrong column was accepted")
	}
	for _, expected := range []string{
		"Alpha is marked yes",
		"rejected --entry=Examples.Fixture.Alpha",
		"Beta compiles now; mark it yes",
	} {
		if !strings.Contains(err.Error(), expected) {
			t.Errorf("error lacks %q:\n%v", expected, err)
		}
	}
}

func TestTheTalacColumnIsRequiredAndSaysYesOrNoWithAReason(t *testing.T) {
	if _, failures := readCompileExpectations("| Program | Surface |\n| --- | --- |\n| `Alpha` | x |\n"); len(failures) != 1 ||
		!strings.Contains(failures[0], `no "Compiles with talac" column`) {
		t.Fatalf("failures = %v, want the missing column", failures)
	}
	markdown := "| Program | Surface | Compiles with talac |\n| --- | --- | --- |\n" +
		"| `Alpha` | x | yes |\n| `Beta` | x | no |\n| `Gamma` | x | maybe |\n| `Delta` | x | no: fields |\n| `Epsilon` | x |\n"
	expectations, failures := readCompileExpectations(markdown)
	if len(failures) != 3 {
		t.Fatalf("failures = %v, want Beta, Gamma and Epsilon", failures)
	}
	if !expectations["Alpha"].compiles || expectations["Delta"].compiles || len(expectations) != 2 {
		t.Fatalf("expectations = %v", expectations)
	}
}

func TestEntryPointIsTheClassOfMain(t *testing.T) {
	entry, err := entryPoint(tala("Program", false))
	if err != nil || entry != "Examples.Fixture.Program" {
		t.Fatalf("entryPoint = %q, %v", entry, err)
	}
	if _, err := entryPoint("public class A {}"); err == nil {
		t.Fatal("a source without a namespace got an entry point")
	}
}

func TestTheRepositoryCatalogHasTheTalacColumn(t *testing.T) {
	catalog, err := os.ReadFile(filepath.Join("..", "..", "..", examplesDirectoryName, "README.md"))
	if err != nil {
		t.Fatal(err)
	}
	expectations, failures := readCompileExpectations(string(catalog))
	if len(failures) != 0 {
		t.Fatal(failures)
	}
	if !expectations["HelloWorld"].compiles {
		t.Fatal("HelloWorld, the smoke-test program, is not marked yes")
	}
}

func TestACrashIsNotTheRejectionANoCellExpects(t *testing.T) {
	root := compileFixture(t, map[string]string{"Beta": "no: fields"}, nil)
	path := filepath.Join(root, "Examples", "Beta", "Beta.tala")
	if err := os.WriteFile(path, []byte(source("Beta", "CRASH")), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := compileExamples(root, testBinary(t))
	if err == nil || !strings.Contains(err.Error(), "Beta: talac failed without a diagnostic of the program") {
		t.Fatalf("a crash passed for a rejection: %v", err)
	}
}

func TestEntryPointSkipsCommentsStringsAndOtherMainMethods(t *testing.T) {
	text := "namespace Examples.Fixture;\n-- class Fake\npublic class Helper {\n    static void Main() {}\n" +
		"    String note = \"class Quoted\";\n}\n\npublic class Program {\n    public static void Main() {}\n}\n"
	entry, err := entryPoint(text)
	if err != nil || entry != "Examples.Fixture.Program" {
		t.Fatalf("entryPoint = %q, %v", entry, err)
	}
	twice := "namespace A;\npublic class B {\n    public static void Main() {}\n}\npublic class C {\n    public static void Main() {}\n}\n"
	if _, err := entryPoint(twice); err == nil {
		t.Fatal("two entry points were accepted")
	}
}
