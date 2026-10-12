// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestFuzzJobsDefaultKeepsAPhysicalCorePerTarget(t *testing.T) {
	for _, example := range []struct{ processors, jobs int }{{1, 1}, {2, 1}, {4, 1}, {8, 2}, {16, 4}, {64, 4}} {
		got, err := fuzzJobs("", example.processors)
		if err != nil || got != example.jobs {
			t.Fatalf("%d processors: %d jobs, %v; want %d", example.processors, got, err, example.jobs)
		}
	}
	if got, err := fuzzJobs("1", 16); err != nil || got != 1 {
		t.Fatalf("explicit sequential run rejected: %d, %v", got, err)
	}
	if got, err := fuzzJobs("6", 2); err != nil || got != 6 {
		t.Fatalf("explicit job count rejected: %d, %v", got, err)
	}
	for _, bad := range []string{"0", "-1", "65", "two", "1.5"} {
		if _, err := fuzzJobs(bad, 8); err == nil {
			t.Fatalf("accepted invalid TALA_FUZZ_JOBS %q", bad)
		}
	}
}

func TestFuzzTasksRespectJobAndHeavyLimits(t *testing.T) {
	var running, heavyRunning, peak, heavyPeak atomic.Int32
	raise := func(current *atomic.Int32, highest *atomic.Int32) {
		value := current.Add(1)
		for {
			seen := highest.Load()
			if value <= seen || highest.CompareAndSwap(seen, value) {
				return
			}
		}
	}
	var completed atomic.Int32
	tasks := make([]fuzzTask, 0, 12)
	for index := 0; index < 12; index++ {
		heavy := index%2 == 0
		tasks = append(tasks, fuzzTask{heavy: heavy, run: func() error {
			raise(&running, &peak)
			if heavy {
				raise(&heavyRunning, &heavyPeak)
			}
			time.Sleep(20 * time.Millisecond)
			if heavy {
				heavyRunning.Add(-1)
			}
			running.Add(-1)
			completed.Add(1)
			return nil
		}})
	}
	if err := runFuzzTasks(3, tasks); err != nil {
		t.Fatal(err)
	}
	if completed.Load() != 12 {
		t.Fatalf("only %d of 12 tasks ran", completed.Load())
	}
	if peak.Load() > 3 || peak.Load() < 2 {
		t.Fatalf("concurrency peak %d is outside the requested bound of 3", peak.Load())
	}
	if heavyPeak.Load() != 1 {
		t.Fatalf("%d memory-heavy targets overlapped", heavyPeak.Load())
	}
}

func TestFuzzTasksReportTheEarliestFailureAndStopStartingWork(t *testing.T) {
	first, second := errors.New("first"), errors.New("second")
	var started atomic.Int32
	var release sync.WaitGroup
	release.Add(1)
	tasks := []fuzzTask{
		{run: func() error { started.Add(1); release.Wait(); return first }},
		{run: func() error { started.Add(1); release.Done(); return second }},
	}
	for index := 0; index < 20; index++ {
		tasks = append(tasks, fuzzTask{run: func() error { started.Add(1); return nil }})
	}
	err := runFuzzTasks(2, tasks)
	// The later task fails first in time; the reported error is still the
	// earliest one in inventory order.
	if !errors.Is(err, first) {
		t.Fatalf("reported %v instead of the earliest failure", err)
	}
	if started.Load() == int32(len(tasks)) {
		t.Fatal("every task was started although the campaign had already failed")
	}
	// A single job is exactly the former sequential behavior.
	order := []int{}
	sequential := []fuzzTask{}
	for index := 0; index < 5; index++ {
		sequential = append(sequential, fuzzTask{heavy: index == 2, run: func() error { order = append(order, index); return nil }})
	}
	if err := runFuzzTasks(1, sequential); err != nil || len(order) != 5 {
		t.Fatalf("sequential run: %v, %v", order, err)
	}
	for index, value := range order {
		if index != value {
			t.Fatalf("one job did not preserve inventory order: %v", order)
		}
	}
}

func TestOnlyLargeRSSTargetsAreHeavy(t *testing.T) {
	heavy := map[string]bool{}
	for _, target := range nativeFuzzTargets() {
		heavy[target.binary] = isHeavyFuzzTarget(target)
	}
	for _, binary := range []string{"source_llvm_fuzzer", "differential_fuzzer", "repl_fuzzer"} {
		if !heavy[binary] {
			t.Fatalf("%s has a 4096 MiB limit but may overlap another heavy target", binary)
		}
	}
	for _, binary := range []string{"wire_fuzzer", "lexer_fuzzer", "parser_fuzzer", "cli_fuzzer", "project_fuzzer", "ownership_fuzzer"} {
		if heavy[binary] {
			t.Fatalf("%s is needlessly serialized", binary)
		}
	}
}
