// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeAnalyzedSource(t *testing.T, repository string, relative string, text string) {
	t.Helper()
	path := filepath.Join(repository, filepath.FromSlash(relative))
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestAvailableCheckersKeepsOnlyWhatTheAnalyzerLists(t *testing.T) {
	listing := "OVERVIEW: Clang Static Analyzer Checkers List\n\nCHECKERS:\n" +
		"  alpha.core.Conversion           Loss of sign/precision in implicit conversions\n" +
		"  alpha.cplusplus.SmartPtr\n" +
		"                                  Find the dereference of null SmrtPtr\n" +
		"  security.ArrayBound             Warn about out of bounds access to memory\n"
	wanted := []string{"security.ArrayBound", "alpha.security.ArrayBoundV2", "alpha.cplusplus.SmartPtr", "alpha.core.Conversion"}
	want := []string{"security.ArrayBound", "alpha.cplusplus.SmartPtr", "alpha.core.Conversion"}
	if got := availableCheckers(listing, wanted); !reflect.DeepEqual(got, want) {
		t.Fatalf("available checkers = %v, want %v", got, want)
	}
	if got := availableCheckers("not a listing", wanted); len(got) != 0 {
		t.Fatalf("a compiler without the analyzer gave %v", got)
	}
}

func TestEveryRequestedCheckerIsNamedOnceAndInItsOwnGroup(t *testing.T) {
	seen := map[string]bool{}
	for _, name := range analyzerOptInCheckers {
		if strings.HasPrefix(name, "alpha.") || seen[name] {
			t.Fatalf("stable checker list holds %q wrongly", name)
		}
		seen[name] = true
	}
	for _, name := range analyzerAlphaCheckers {
		if !strings.HasPrefix(name, "alpha.") || seen[name] {
			t.Fatalf("development checker list holds %q wrongly", name)
		}
		seen[name] = true
	}
}

func TestAnalyzerCommandKeepsMeaningAndDropsOutputs(t *testing.T) {
	compile := []string{"-std=c++20", "-Iexternal/llvm/include", "-DNDEBUG", "-Werror", "-Wall", "-MD", "-MF", "out/a.d",
		"-c", "Compiler/Core/Verifier.cpp", "-o", "out/a.o"}
	got := analyzerCommand(compile, "Compiler/Core/Verifier.cpp", []string{"security.ArrayBound"})
	want := []string{"--analyze", "-Xclang", "-analyzer-output=text", "-Xclang", "-analyzer-checker=security.ArrayBound", "-Wno-error",
		"-std=c++20", "-Iexternal/llvm/include", "-DNDEBUG", "-Wall", "Compiler/Core/Verifier.cpp"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("analyzer command =\n%v\nwant\n%v", got, want)
	}

	windows := []string{"/nologo", "/std:c++20", "/clang:-Werror", "/WX", "/showIncludes", "/c", "Compiler/Core/Verifier.cpp",
		"/Fobazel-out/a.obj", "/Fdbazel-out/a.pdb"}
	got = analyzerCommand(windows, "Compiler/Core/Verifier.cpp", nil)
	want = []string{"--analyze", "-Xclang", "-analyzer-output=text", "-Wno-error", "/nologo", "/std:c++20", "Compiler/Core/Verifier.cpp"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("clang-cl analyzer command =\n%v\nwant\n%v", got, want)
	}
}

func TestAnalyzerCommandSparesTestsTheLeakChecker(t *testing.T) {
	got := strings.Join(analyzerCommand([]string{"-c", "Compiler/Core/Tests/CoreTests.cpp"}, "Compiler/Core/Tests/CoreTests.cpp", nil), " ")
	if !strings.Contains(got, "-analyzer-disable-checker=cplusplus.NewDeleteLeaks") {
		t.Fatalf("a test unit keeps the leak checker: %s", got)
	}
	got = strings.Join(analyzerCommand([]string{"-c", "Compiler/Core/Verifier.cpp"}, "Compiler/Core/Verifier.cpp", nil), " ")
	if strings.Contains(got, "-analyzer-disable-checker") {
		t.Fatalf("a production unit loses a checker: %s", got)
	}
}

const analyzerReport = `C:/work/execroot/_main/Compiler/Core/Verifier.cpp:41:12: warning: Dereference of null pointer (loaded from variable 'node') [core.NullDereference]
   41 |     return node->kind;
      |            ^~~~
C:/work/execroot/_main/Compiler/Core/Verifier.cpp:38:9: note: Assuming 'node' is null
C:\work\execroot\_main\Compiler\Core\Verifier.cpp:41:12: note: Dereference of null pointer (loaded from variable 'node')
Compiler/Core/Verifier.cpp:77:5: warning: Use of invalidated iterator [alpha.cplusplus.InvalidatedIterator]
external/+llvm+llvm/include/llvm/ADT/SmallVector.h:9:3: warning: Called C++ object pointer is null [core.CallAndMessage]
external/+llvm+llvm/include/llvm/ADT/SmallVector.h:8:3: note: not ours
Compiler/Core/Verifier.cpp:12:9: warning: unused variable 'spare' [-Wunused-variable]
bazel-out/x64_windows-fastbuild/bin/Compiler/Headers/_virtual_includes/headers/Visual/XSharp/Core/IR.hpp:5:1: warning: Potential leak of memory [cplusplus.NewDeleteLeaks]
2 warnings generated.
`

func TestAnalyzerFindingsAreAttributedAndKeepTheirSteps(t *testing.T) {
	ours, foreign, compileErrors := analyzerFindings(analyzerReport, `C:\work\execroot\_main`)
	if foreign != 1 || len(compileErrors) != 0 {
		t.Fatalf("foreign = %d, compile errors = %v", foreign, compileErrors)
	}
	if len(ours) != 3 {
		t.Fatalf("findings = %+v, want three in first-party code", ours)
	}
	first := ours[0]
	if first.File != "Compiler/Core/Verifier.cpp" || first.Line != 41 || first.Column != 12 || first.Checker != "core.NullDereference" ||
		first.Message != "Dereference of null pointer (loaded from variable 'node')" || first.advisory() {
		t.Fatalf("first finding = %+v", first)
	}
	if len(first.Steps) != 2 || first.Steps[0].Line != 38 || first.Steps[1].File != "Compiler/Core/Verifier.cpp" {
		t.Fatalf("steps of the first finding = %+v", first.Steps)
	}
	if !ours[1].advisory() || len(ours[1].Steps) != 0 {
		t.Fatalf("a finding of a checker in development = %+v", ours[1])
	}
	if !strings.HasPrefix(ours[2].File, "bazel-out/") {
		t.Fatalf("a finding in a first-party header under the output tree was lost: %+v", ours[2])
	}
}

func TestASuppressionCommentSilencesTheCheckerItNames(t *testing.T) {
	lines := []string{
		"auto moved = std::move(source);",
		"// NOLINTNEXTLINE(bugprone-use-after-move,clang-analyzer-cplusplus.Move)",
		"source.Invoke();",
		"other.Invoke(); // NOLINT(clang-analyzer-core.CallAndMessage)",
		"third.Invoke(); // NOLINT",
		"// NOLINTNEXTLINE(bugprone-use-after-move)",
		"fourth.Invoke();",
	}
	at := func(line int, checker string) analyzerFinding { return analyzerFinding{Line: line, Checker: checker} }
	for _, silenced := range []analyzerFinding{at(3, "cplusplus.Move"), at(4, "core.CallAndMessage"), at(5, "core.NullDereference")} {
		if !suppressedBy(lines, silenced) {
			t.Fatalf("%+v is not silenced", silenced)
		}
	}
	for _, reported := range []analyzerFinding{at(3, "core.NullDereference"), at(4, "cplusplus.Move"), at(7, "cplusplus.Move"),
		at(1, "cplusplus.Move"), at(2, "cplusplus.Move"), at(99, "cplusplus.Move"), at(0, "cplusplus.Move")} {
		if suppressedBy(lines, reported) {
			t.Fatalf("%+v is silenced by a comment that does not name it", reported)
		}
	}
}

func TestSuppressedFindingsAreDroppedAndCounted(t *testing.T) {
	repository := t.TempDir()
	writeAnalyzedSource(t, repository, "Compiler/Core/A.cpp", "int first;\r\n// NOLINTNEXTLINE(clang-analyzer-core.DivideZero)\r\nint second = 1 / zero;\r\n")
	findings := []analyzerFinding{
		{File: "Compiler/Core/A.cpp", Line: 3, Checker: "core.DivideZero"},
		{File: "Compiler/Core/A.cpp", Line: 1, Checker: "core.DivideZero"},
		{File: "bazel-out/k8/bin/_virtual_includes/x/A.hpp", Line: 3, Checker: "core.DivideZero"},
	}
	kept, dropped := withoutSuppressed(repository, findings)
	if dropped != 1 || len(kept) != 2 || kept[0].Line != 1 {
		t.Fatalf("kept %+v, dropped %d", kept, dropped)
	}
}

func TestFilterUnitsKeepsMatchingPaths(t *testing.T) {
	units := []tidyUnit{{File: "Compiler/Core/Verifier.cpp"}, {File: "Interactive/Session.cpp"}, {File: "Compiler/Core/Tests/CoreTests.cpp"}}
	if kept := filterUnits(units, "Compiler/Core/"); len(kept) != 2 {
		t.Fatalf("kept %v", kept)
	}
	if kept := filterUnits(units, "Nowhere"); len(kept) != 0 {
		t.Fatalf("kept %v", kept)
	}
}

func TestAnalyzerFindingsAreReadInTheFormOfClangCl(t *testing.T) {
	report := "Compiler\\Core\\Verifier.cpp(6,12): warning: Dereference of null pointer (loaded from variable 'chosen') [core.NullDereference]\n" +
		"    6 |     return *chosen;\n" +
		"Compiler\\Core\\Verifier.cpp(3,19): note: Assuming 'flag' is false\n" +
		"C:\\work\\execroot\\_main\\Compiler\\Core\\Verifier.cpp(3,5): note: 'chosen' initialized to a null pointer value\n" +
		"external\\llvm\\include\\llvm\\ADT\\SmallVector.h(9,3): warning: Called C++ object pointer is null [core.CallAndMessage]\n" +
		"Compiler\\Core\\Verifier.cpp(2,1): error: unknown type name 'Thing'\n"
	ours, foreign, compileErrors := analyzerFindings(report, `C:\work\execroot\_main`)
	if len(ours) != 1 || foreign != 1 || len(compileErrors) != 1 {
		t.Fatalf("findings %+v, foreign %d, compile errors %v", ours, foreign, compileErrors)
	}
	finding := ours[0]
	if finding.File != "Compiler/Core/Verifier.cpp" || finding.Line != 6 || finding.Column != 12 || finding.Checker != "core.NullDereference" {
		t.Fatalf("finding = %+v", finding)
	}
	if len(finding.Steps) != 2 || finding.Steps[0].Line != 3 || finding.Steps[0].Column != 19 || finding.Steps[1].File != "Compiler/Core/Verifier.cpp" {
		t.Fatalf("steps = %+v", finding.Steps)
	}
}

func TestACompilerErrorMeansTheUnitWasNotAnalyzed(t *testing.T) {
	report := "Compiler/Core/Verifier.cpp:3:10: fatal error: 'missing.hpp' file not found\n" +
		"Compiler/Core/Verifier.cpp:9:1: error: unknown type name 'Thing'\n" +
		"Compiler/Core/Verifier.cpp:9:1: note: did you mean 'Think'?\n"
	ours, foreign, compileErrors := analyzerFindings(report, "")
	if len(ours) != 0 || foreign != 0 || len(compileErrors) != 2 {
		t.Fatalf("findings %v, foreign %d, compile errors %v", ours, foreign, compileErrors)
	}
}

func TestUniqueFindingsDropWhatSeveralUnitsReport(t *testing.T) {
	header := analyzerFinding{File: "Compiler/Headers/A.hpp", Line: 4, Column: 2, Checker: "core.DivideZero", Message: "Division by zero"}
	later := analyzerFinding{File: "Compiler/Headers/A.hpp", Line: 9, Column: 1, Checker: "core.DivideZero", Message: "Division by zero"}
	other := analyzerFinding{File: "Compiler/Core/B.cpp", Line: 1, Column: 1, Checker: "alpha.core.Conversion", Message: "Loss of sign"}
	got := uniqueFindings([]analyzerFinding{later, header, other, header})
	if len(got) != 3 || got[0].File != "Compiler/Core/B.cpp" || got[1].Line != 4 || got[2].Line != 9 {
		t.Fatalf("unique findings = %+v", got)
	}
}

func TestAnalyzerSarifIsOneRunWithRulesLevelsAndCodeFlows(t *testing.T) {
	ours, _, _ := analyzerFindings(analyzerReport, `C:\work\execroot\_main`)
	encoded, err := analyzerSarif(ours, "clang version 22.1.8")
	if err != nil {
		t.Fatal(err)
	}
	var document sarifDocument
	if err := json.Unmarshal(encoded, &document); err != nil {
		t.Fatal(err)
	}
	if document.Version != "2.1.0" || len(document.Runs) != 1 {
		t.Fatalf("document = %+v", document)
	}
	run := document.Runs[0]
	if run.Tool.Driver.Name != "Clang Static Analyzer" || len(run.Tool.Driver.Rules) != 3 || len(run.Results) != 3 {
		t.Fatalf("run has %d rules and %d results", len(run.Tool.Driver.Rules), len(run.Results))
	}
	levels := map[string]string{}
	for _, result := range run.Results {
		levels[result.RuleID] = result.Level
		place := result.Locations[0].PhysicalLocation
		if place.ArtifactLocation.URIBaseID != "%SRCROOT%" || strings.Contains(place.ArtifactLocation.URI, `\`) || place.Region.StartLine < 1 {
			t.Fatalf("result location = %+v", place)
		}
		if result.RuleID == "core.NullDereference" {
			if len(result.CodeFlows) != 1 || len(result.CodeFlows[0].ThreadFlows[0].Locations) != 2 {
				t.Fatalf("the steps of a path were not written as a code flow: %+v", result.CodeFlows)
			}
		}
	}
	if levels["core.NullDereference"] != "warning" || levels["alpha.cplusplus.InvalidatedIterator"] != "note" {
		t.Fatalf("levels = %v", levels)
	}
	again, _ := analyzerSarif([]analyzerFinding{ours[2], ours[0], ours[1]}, "clang version 22.1.8")
	if string(again) != string(encoded) {
		t.Fatal("the document depends on the order the findings were found in")
	}
	empty, err := analyzerSarif(nil, "clang")
	if err != nil || !strings.Contains(string(empty), `"results": []`) {
		t.Fatalf("a clean analysis must still be a run with no results: %s, %v", empty, err)
	}
}
