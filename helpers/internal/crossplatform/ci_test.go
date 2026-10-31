// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package crossplatform

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestTheHostedTargetsNameWorkflowsThatExistAndCanBeStartedByHand(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, target := range HostedTargets() {
		if seen[target.Name] || target.Description == "" {
			t.Fatalf("target %+v", target)
		}
		seen[target.Name] = true
		content, err := os.ReadFile(filepath.Join(root, ".github", "workflows", target.Workflow))
		if err != nil {
			t.Fatalf("target %s: %v", target.Name, err)
		}
		if !strings.Contains(string(content), "\n  workflow_dispatch:") {
			t.Fatalf("workflow %s of target %s cannot be started by hand", target.Workflow, target.Name)
		}
	}
}

func TestHostedWorkflowsAreNamedOnceInOrder(t *testing.T) {
	all := HostedTargets()
	every, err := HostedWorkflows(all, nil)
	if err != nil || !reflect.DeepEqual(every, []string{"compiler-tier1.yml", "compiler-tier2.yml"}) {
		t.Fatalf("every workflow = %v, %v", every, err)
	}
	some, err := HostedWorkflows(all, []string{"ubuntu-26.04, macos-26", "windows"})
	if err != nil || !reflect.DeepEqual(some, []string{"compiler-tier1.yml", "compiler-tier2.yml"}) {
		t.Fatalf("selected workflows = %v, %v", some, err)
	}
	if _, err := HostedWorkflows(all, []string{"windows", "solaris"}); err == nil || !strings.Contains(err.Error(), "unknown target solaris") {
		t.Fatalf("an unknown target was accepted: %v", err)
	}
	if _, err := HostedWorkflows(all, []string{" , "}); err == nil {
		t.Fatal("an empty name selected something")
	}
}

// hostedEngine answers Git and the GitHub command line from a script.
type hostedEngine struct {
	missing   map[string]bool
	branch    string
	status    string
	local     string
	remote    string
	runs      []string
	failRun   map[string]bool
	failWatch map[string]bool
	calls     []string
}

func (engine *hostedEngine) LookPath(name string) (string, error) {
	if engine.missing[name] {
		return "", errors.New("not found")
	}
	return name, nil
}

func (engine *hostedEngine) Output(directory string, name string, arguments ...string) (string, error) {
	joined := strings.Join(arguments, " ")
	engine.calls = append(engine.calls, name+" "+joined)
	switch {
	case name == "git" && arguments[0] == "branch":
		return engine.branch + "\n", nil
	case name == "git" && arguments[0] == "status":
		return engine.status, nil
	case name == "git" && arguments[0] == "rev-parse":
		return engine.local + "\n", nil
	case name == "git" && arguments[0] == "ls-remote":
		return engine.remote, nil
	case name == "gh" && arguments[0] == "run":
		if len(engine.runs) == 0 {
			return "\n", nil
		}
		next := engine.runs[0]
		engine.runs = engine.runs[1:]
		return next + "\n", nil
	}
	return "", nil
}

func (engine *hostedEngine) Run(directory string, input io.Reader, output io.Writer, errorOutput io.Writer, name string, arguments ...string) error {
	engine.calls = append(engine.calls, name+" "+strings.Join(arguments, " "))
	if arguments[0] == "workflow" && engine.failRun[arguments[2]] {
		return errors.New("exit status 1")
	}
	if arguments[0] == "run" && engine.failWatch[arguments[2]] {
		return errors.New("exit status 1")
	}
	return nil
}

const commit = "0123456789abcdef0123456789abcdef01234567"

func pushed() *hostedEngine {
	return &hostedEngine{branch: "feature/x", local: commit, remote: commit + "\trefs/heads/feature/x\n"}
}

func TestAWorkflowIsStartedOnlyForWhatIsPushed(t *testing.T) {
	if branch, err := PushedBranch(pushed(), "."); err != nil || branch != "feature/x" {
		t.Fatalf("a pushed branch: %q, %v", branch, err)
	}
	cases := map[string]func(*hostedEngine){
		"not committed":        func(engine *hostedEngine) { engine.status = " M helpers/a.go\n" },
		"is not on the remote": func(engine *hostedEngine) { engine.remote = "" },
		"push first": func(engine *hostedEngine) {
			engine.remote = "ffffffffffffffffffffffffffffffffffffffff\trefs/heads/feature/x\n"
		},
		"no branch": func(engine *hostedEngine) { engine.branch = "" },
		"git":       func(engine *hostedEngine) { engine.missing = map[string]bool{"git": true} },
	}
	for report, change := range cases {
		engine := pushed()
		change(engine)
		if _, err := PushedBranch(engine, "."); err == nil || !strings.Contains(strings.ToLower(err.Error()), strings.ToLower(report)) {
			t.Fatalf("%s: %v", report, err)
		}
	}
}

func TestDispatchStartsEachWorkflowAndFollowsItWhenAsked(t *testing.T) {
	previous := pause
	pause = func() {}
	defer func() { pause = previous }()

	var output bytes.Buffer
	engine := pushed()
	workflows := []string{"compiler-tier1.yml", "compiler-tier2.yml"}
	if err := Dispatch(engine, ".", workflows, "feature/x", false, &output, &output); err != nil {
		t.Fatal(err)
	}
	calls := strings.Join(engine.calls, "\n")
	if !strings.Contains(calls, "gh workflow run compiler-tier1.yml --ref feature/x") ||
		!strings.Contains(calls, "gh workflow run compiler-tier2.yml --ref feature/x") || strings.Contains(calls, "gh run watch") {
		t.Fatalf("calls = %v", engine.calls)
	}

	// The first question about the run comes too early and is asked again.
	engine = pushed()
	engine.runs = []string{"", "111", "222"}
	engine.failWatch = map[string]bool{"222": true}
	err := Dispatch(engine, ".", workflows, "feature/x", true, &output, &output)
	if err == nil || !strings.Contains(err.Error(), "1 of 2 workflows failed: compiler-tier2.yml") {
		t.Fatalf("a failed run: %v", err)
	}
	calls = strings.Join(engine.calls, "\n")
	if !strings.Contains(calls, "gh run watch 111 --exit-status") || !strings.Contains(calls, "gh run watch 222 --exit-status") {
		t.Fatalf("calls = %v", engine.calls)
	}

	engine = pushed()
	if err := Dispatch(engine, ".", workflows, "feature/x", true, &output, &output); err == nil || !strings.Contains(err.Error(), "no run of it appeared") {
		t.Fatalf("a run that never appears: %v", err)
	}
	engine = pushed()
	engine.failRun = map[string]bool{"compiler-tier1.yml": true}
	if err := Dispatch(engine, ".", workflows, "feature/x", false, &output, &output); err == nil || !strings.Contains(err.Error(), "default branch") {
		t.Fatalf("a workflow that cannot be started: %v", err)
	}
	engine = pushed()
	engine.missing = map[string]bool{"gh": true}
	if err := Dispatch(engine, ".", workflows, "feature/x", false, &output, &output); err == nil || !strings.Contains(err.Error(), "gh auth login") {
		t.Fatalf("a missing GitHub command line: %v", err)
	}
}
