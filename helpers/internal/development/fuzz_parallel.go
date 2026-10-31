// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"errors"
	"runtime"
	"strconv"
	"sync"
)

// heavyRSSLimitMiB marks targets whose RSS limit is large enough that two of
// them running together could exhaust a developer machine. Their limits are
// not lowered; they simply never overlap each other.
const heavyRSSLimitMiB = 4096

// fuzzTask is one independent campaign process. Tasks share no corpus,
// artifact directory or report entry, so running them together changes only
// the wall-clock time, not the per-target budget or its checks.
type fuzzTask struct {
	heavy bool
	run   func() error
}

// fuzzJobs selects how many campaign processes may run at once. A campaign's
// evidence is the number of inputs a target executes inside its time budget,
// so concurrency is only free while every process keeps a physical core to
// itself. Measured on a two-core, four-thread host, two concurrent targets
// cut executed inputs by 40 to 90 percent. The default therefore grants one
// job per four logical processors, at most four, which is a single job on
// such a host and on four-vCPU CI runners. TALA_FUZZ_JOBS overrides it for a
// host with spare cores.
func fuzzJobs(configured string, logicalProcessors int) (int, error) {
	if configured != "" {
		jobs, err := strconv.Atoi(configured)
		if err != nil || jobs < 1 || jobs > 64 {
			return 0, errors.New("TALA_FUZZ_JOBS must be an integer in [1, 64]")
		}
		return jobs, nil
	}
	jobs := logicalProcessors / 4
	if jobs < 1 {
		jobs = 1
	}
	if jobs > 4 {
		jobs = 4
	}
	return jobs, nil
}

func hostFuzzJobs(configured string) (int, error) {
	return fuzzJobs(configured, runtime.NumCPU())
}

// runFuzzTasks executes every task with at most jobs running concurrently and
// at most one heavy task at a time. All started tasks finish so their logs and
// reports are complete; after the first failure no further task is started.
// The returned error is the failure of the earliest task in inventory order,
// which keeps the reported failure independent of scheduling.
func runFuzzTasks(jobs int, tasks []fuzzTask) error {
	if jobs < 1 {
		jobs = 1
	}
	failures := make([]error, len(tasks))
	slots := make(chan struct{}, jobs)
	var heavy sync.Mutex
	var state sync.Mutex
	failed := false
	var group sync.WaitGroup
	for index, task := range tasks {
		slots <- struct{}{}
		state.Lock()
		stop := failed
		state.Unlock()
		if stop {
			<-slots
			break
		}
		group.Add(1)
		go func() {
			defer group.Done()
			defer func() { <-slots }()
			if task.heavy {
				heavy.Lock()
				defer heavy.Unlock()
			}
			if err := task.run(); err != nil {
				state.Lock()
				failures[index] = err
				failed = true
				state.Unlock()
			}
		}()
	}
	group.Wait()
	for _, failure := range failures {
		if failure != nil {
			return failure
		}
	}
	return nil
}

func isHeavyFuzzTarget(target fuzzTarget) bool {
	limit, err := strconv.Atoi(target.rssLimit)
	return err != nil || limit >= heavyRSSLimitMiB
}
