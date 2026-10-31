// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func actionGraph(t *testing.T, commands ...[]string) []byte {
	t.Helper()
	type action struct {
		Arguments []string `json:"arguments"`
	}
	document := struct {
		Actions []action `json:"actions"`
	}{}
	for _, command := range commands {
		document.Actions = append(document.Actions, action{Arguments: command})
	}
	encoded, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func TestTidyUnitsKeepOnlyFirstPartySourcesOnceInPathOrder(t *testing.T) {
	root := t.TempDir()
	graph := actionGraph(t,
		[]string{"clang", "-Iexternal/llvm", "-c", "Interactive/Main.cpp", "-o", "bazel-out/bin/Interactive/Main.o"},
		[]string{"clang", "-c", "external/+llvm+llvm/lib/Support.cpp", "-o", "bazel-out/bin/external/Support.o"},
		[]string{"clang", "-DFIRST", "-c", "Talac/Core/IR.cpp", "-o", "bazel-out/bin/Talac/Core/IR.o"},
		[]string{"clang", "-DSECOND", "-c", "Talac/Core/IR.cpp", "-o", "bazel-out/bin/Talac/Core/IR.pic.o"},
		[]string{"clang", "-c", "third_party/catch3/src/catch.cpp", "-o", "bazel-out/bin/third_party/catch.o"},
		[]string{"clang", "-c", "bazel-out/bin/Talac/Generated.cpp", "-o", "bazel-out/bin/Talac/Generated.o"},
		[]string{"clang", "-c", "Benchmarks/Main.cpp", "-o", "bazel-out/bin/Benchmarks/Main.o"},
	)
	units, err := tidyUnitsFromActions(graph, root)
	if err != nil {
		t.Fatal(err)
	}
	var files []string
	for _, unit := range units {
		files = append(files, unit.File)
		if unit.Directory != root {
			t.Fatalf("%s is not rooted at the execution root: %q", unit.File, unit.Directory)
		}
	}
	want := []string{"Benchmarks/Main.cpp", "Interactive/Main.cpp", "Talac/Core/IR.cpp"}
	if !reflect.DeepEqual(files, want) {
		t.Fatalf("selected %v, want %v", files, want)
	}
	// A source compiled by several targets keeps its first command.
	if !strings.Contains(strings.Join(units[2].Arguments, " "), "-DFIRST") {
		t.Fatalf("duplicate source did not keep its first command: %v", units[2].Arguments)
	}
}

func TestTidyUnitsReadWindowsParameterFiles(t *testing.T) {
	root := t.TempDir()
	write := func(path, content string) {
		t.Helper()
		full := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	firstParty := "bazel-out/x64_windows-fastbuild/bin/Talac/Core/_objs/core/IR.obj.params"
	vendored := "bazel-out/x64_windows-fastbuild/bin/external/+llvm+llvm/_objs/Support/Path.obj.params"
	write(firstParty, "/nologo\r\n\"/DNAME=\\\"quoted value\\\"\"\r\n/I.\r\n/Fobazel-out/x64_windows-fastbuild/bin/Talac/Core/_objs/core/IR.obj\r\n/c\r\nTalac/Core/IR.cpp\r\n")
	write(vendored, "/c\r\nexternal/+llvm+llvm/lib/Support/Path.cpp\r\n")
	graph := actionGraph(t,
		[]string{"clang-cl.exe", "@" + firstParty},
		[]string{"clang-cl.exe", "@" + vendored},
	)
	units, err := tidyUnitsFromActions(graph, root)
	if err != nil {
		t.Fatal(err)
	}
	if len(units) != 1 || units[0].File != "Talac/Core/IR.cpp" {
		t.Fatalf("selected %v", units)
	}
	want := []string{
		"clang-cl.exe", "/nologo", `/DNAME="quoted value"`, "/I.",
		"/Fobazel-out/x64_windows-fastbuild/bin/Talac/Core/_objs/core/IR.obj", "/c", "Talac/Core/IR.cpp",
	}
	if !reflect.DeepEqual(units[0].Arguments, want) {
		t.Fatalf("expanded %q, want %q", units[0].Arguments, want)
	}
}

func TestTidyUnitsRejectAnUnbuiltFirstPartyUnitButSkipAnUnbuiltDependency(t *testing.T) {
	root := t.TempDir()
	built := []string{"clang", "-c", "Talac/Core/IR.cpp"}
	// A dependency whose parameter file was never written is not ours to
	// analyze, so its absence does not matter.
	dependency := []string{"clang-cl.exe", "@bazel-out/x64_windows-fastbuild/bin/external/+llvm+llvm/_objs/Support/Path.obj.params"}
	units, err := tidyUnitsFromActions(actionGraph(t, built, dependency), root)
	if err != nil || len(units) != 1 {
		t.Fatalf("an unbuilt dependency changed the result: %v / %v", units, err)
	}
	// A first-party unit without its command must fail the run: skipping it
	// would report a clean result for code that was never analyzed.
	missing := []string{"clang-cl.exe", "@bazel-out/x64_windows-fastbuild/bin/Talac/Cli/_objs/cli/Options.obj.params"}
	if _, err := tidyUnitsFromActions(actionGraph(t, built, missing), root); err == nil || !strings.Contains(err.Error(), "Options.obj.params") {
		t.Fatalf("an unbuilt first-party unit was skipped: %v", err)
	}
}

func TestTidyUnitsRejectAnEmptyOrMalformedGraph(t *testing.T) {
	root := t.TempDir()
	if _, err := tidyUnitsFromActions([]byte("INFO: not json"), root); err == nil {
		t.Fatal("non-JSON output was accepted as an action graph")
	}
	// A graph with only vendored sources would otherwise analyze nothing and
	// report success.
	vendored := actionGraph(t, []string{"clang", "-c", "external/llvm/Support.cpp"})
	if _, err := tidyUnitsFromActions(vendored, root); err == nil {
		t.Fatal("a graph without first-party sources was accepted")
	}
	if _, err := tidyUnitsFromActions(actionGraph(t), root); err == nil {
		t.Fatal("an empty graph was accepted")
	}
}

func TestTidySourceIgnoresOutputsAndOptions(t *testing.T) {
	cases := map[string][]string{
		"Talac/Core/IR.cpp":  {"clang", "-c", "Talac/Core/IR.cpp", "-o", "out/IR.o"},
		"Talac/Abi/Probe.c":  {"clang-cl.exe", "/c", "Talac/Abi/Probe.c", "/Foout/Probe.obj"},
		"Talac/Cli/Main.cpp": {"clang-cl.exe", "/FdTalac/Cli/stale.cpp", "/c", `Talac\Cli\Main.cpp`},
		"":                   {"clang", "-include", "prefix.h", "-o", "out/a.o"},
	}
	for want, arguments := range cases {
		if got := tidySource(arguments); got != want {
			t.Fatalf("tidySource(%q) = %q, want %q", arguments, got, want)
		}
	}
}

func TestTidyJobsDefaultToLogicalProcessorsAndValidateOverride(t *testing.T) {
	for processors, want := range map[int]int{0: 1, 1: 1, 4: 4, 64: 64} {
		if jobs, err := tidyJobs("", processors); err != nil || jobs != want {
			t.Fatalf("tidyJobs(%d) = %d, %v", processors, jobs, err)
		}
	}
	if jobs, err := tidyJobs("3", 16); err != nil || jobs != 3 {
		t.Fatalf("override = %d, %v", jobs, err)
	}
	for _, invalid := range []string{"0", "-1", "many", "257", "1.5"} {
		if _, err := tidyJobs(invalid, 8); err == nil {
			t.Fatalf("TALA_TIDY_JOBS=%q was accepted", invalid)
		}
	}
}

func TestRunTidyUnitsBoundsConcurrencyAndKeepsUnitOrder(t *testing.T) {
	var units []tidyUnit
	for _, name := range []string{"a.cpp", "b.cpp", "c.cpp", "d.cpp", "e.cpp", "f.cpp"} {
		units = append(units, tidyUnit{File: name})
	}
	var running, peak atomic.Int32
	var release sync.WaitGroup
	release.Add(1)
	started := make(chan struct{}, len(units))
	go func() {
		// Let the first two analyses overlap before any may finish.
		<-started
		<-started
		release.Done()
	}()
	outcomes := runTidyUnits(units, 2, func(unit tidyUnit) (string, error) {
		current := running.Add(1)
		for {
			observed := peak.Load()
			if current <= observed || peak.CompareAndSwap(observed, current) {
				break
			}
		}
		started <- struct{}{}
		release.Wait()
		running.Add(-1)
		if unit.File == "c.cpp" {
			return "finding in c", errors.New("exit status 1")
		}
		return "", nil
	})
	if peak.Load() != 2 {
		t.Fatalf("peak concurrency was %d, want exactly 2", peak.Load())
	}
	for index, outcome := range outcomes {
		if outcome.file != units[index].File {
			t.Fatalf("outcome %d belongs to %q", index, outcome.file)
		}
		if (outcome.err != nil) != (outcome.file == "c.cpp") {
			t.Fatalf("unexpected verdict for %q: %v", outcome.file, outcome.err)
		}
	}
}

func TestTidyFindingsBelongToTheFileTheyAreReportedIn(t *testing.T) {
	root := `C:\work\execroot\_main`
	report := strings.Join([]string{
		"Talac/Core/IR.cpp:10:5: error: use range-based for loop instead [modernize-loop-convert,-warnings-as-errors]",
		"   10 |     for (std::size_t i = 0; i < n; ++i)",
		"Talac/Core/IR.cpp:9:1: note: declared here",
		`external/catch3+/src\catch2/internal/catch_result_type.hpp:53:16: error: out of range [clang-analyzer-optin.core.EnumCastOutOfRange,-warnings-as-errors]`,
		"Talac/Core/Tests/T.cpp:4:1: note: in instantiation here",
		`C:/work/execroot/_main/Talac\Headers/Progmasoft/Tala/Core/IR.hpp:3:1: warning: redundant [readability-redundant-declaration]`,
		"external/llvm/include/llvm/ADT/X.h:1:1: error: 'missing.h' file not found [clang-diagnostic-error]",
		"bazel-out/k8-fastbuild/bin/_virtual_includes/a8083eb4/Progmasoft/Tala/Backend/LLVM.hpp:2:2: warning: ours [bugprone-x]",
		"bazel-out/k8-fastbuild/bin/external/+llvm+llvm/_virtual_includes/Support/llvm/X.h:2:2: warning: theirs [bugprone-x]",
		`C:\Program Files\MSVC\include\xfilesystem_abi.h:134:1: error: theirs [clang-analyzer-optin.core.EnumCastOutOfRange,-warnings-as-errors]`,
		"12 warnings generated.",
	}, "\r\n")
	ours, foreign := tidyFindings(report, root)
	if foreign != 3 {
		t.Fatalf("counted %d dependency findings, want the Catch3, fetched-header and system-header ones", foreign)
	}
	if len(ours) != 4 {
		t.Fatalf("kept %d findings: %q", len(ours), ours)
	}
	// A public header reached through Bazel's virtual include tree is ours.
	if !strings.Contains(ours[3], "_virtual_includes/a8083eb4") {
		t.Fatalf("a first-party virtual include was not recognized: %q", ours[3])
	}
	// Notes stay attached to the finding they explain, and to no other.
	if !strings.Contains(ours[0], "declared here") || strings.Contains(ours[0], "instantiation") {
		t.Fatalf("notes were not kept with their finding: %q", ours[0])
	}
	if !strings.Contains(ours[1], "Core/IR.hpp") {
		t.Fatalf("an absolute first-party header path was not recognized: %q", ours[1])
	}
	// A compile error means the unit was not analyzed, wherever it is.
	if !strings.Contains(ours[2], "clang-diagnostic-error") {
		t.Fatalf("a compile error in a dependency header was dropped: %q", ours[2])
	}
}

func TestTidyReportFailsOnFirstPartyFindingsAndUnexplainedExits(t *testing.T) {
	failure := errors.New("exit status 1")
	clean := []tidyOutcome{
		{file: "a.cpp"},
		// A dependency-only report exits unsuccessfully but is not ours.
		{file: "b.cpp", output: "external/dep/x.hpp:1:1: error: theirs [bugprone-x,-warnings-as-errors]", err: failure},
	}
	if err := reportTidyOutcomes(clean, ""); err != nil {
		t.Fatalf("units without a first-party finding reported a failure: %v", err)
	}
	mixed := []tidyOutcome{
		{file: "a.cpp"},
		{file: "Talac/b.cpp", output: "Talac/b.cpp:1:1: error: finding [bugprone-x,-warnings-as-errors]", err: failure},
		// An analyzer that dies without a diagnostic is still a failure.
		{file: "Talac/c.cpp", err: errors.New("signal: killed")},
		{file: "Talac/d.cpp", output: "Stack dump: clang-tidy crashed", err: failure},
		// A finding is a failure even if the analyzer exits successfully.
		{file: "Talac/e.cpp", output: "Talac/e.cpp:2:2: warning: finding [performance-x]"},
	}
	err := reportTidyOutcomes(mixed, "")
	if err == nil || !strings.Contains(err.Error(), "4 of 5") {
		t.Fatalf("failing units were not counted: %v", err)
	}
}

func TestTidyDisablesTheTestFrameworkChecksOnlyForTests(t *testing.T) {
	for _, production := range []string{
		"Talac/Core/IR.cpp", "Interactive/Main.cpp", "Talac/Fuzzing/SourceFuzz.cpp", "Talac/TestsSupport/Probe.cpp",
	} {
		if override := tidyCheckOverride(production); override != "" {
			t.Fatalf("%s lost checks: %q", production, override)
		}
	}
	want := "-bugprone-unchecked-optional-access,-clang-analyzer-cplusplus.NewDeleteLeaks"
	for _, test := range []string{"Talac/Core/Tests/CorePipelineTests.cpp", "Interactive/Tests/InteractiveTests.cpp", "Tests/Top.cpp"} {
		if override := tidyCheckOverride(test); override != want {
			t.Fatalf("%s override = %q, want %q", test, override, want)
		}
	}
}

func TestTidyQueryCoversEveryNativeTargetAndItsDependencies(t *testing.T) {
	query := tidyActionQuery(tidyTargets())
	if !strings.HasPrefix(query, `mnemonic("CppCompile", deps(set(`) {
		t.Fatalf("query does not select dependency compile actions: %s", query)
	}
	for _, target := range append([]string{"//Talac/Cli:talac", "//Interactive:tali"}, nativeTargets...) {
		if !strings.Contains(query, target) {
			t.Fatalf("query omits %s", target)
		}
	}
}

func TestTidyCommandRequiresTheAnalyzer(t *testing.T) {
	err := runTidy(t.TempDir(), fakeRunner{paths: map[string]string{}}, nil)
	if err == nil || !strings.Contains(err.Error(), "clang-tidy") {
		t.Fatalf("a missing analyzer was not reported: %v", err)
	}
}
