package probe

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

const DefaultTimeout = 30 * time.Second
const managedProbeTimeout = DefaultTimeout

var (
	errProbeCanceled = errors.New("probe canceled")
	errProbeTimedOut = errors.New("probe timed out")
)

type CancelRunStatus int

const (
	CancelRunRecorded CancelRunStatus = iota + 1
	CancelRunPending
	CancelRunInvalid
)

type managedRunEntry struct {
	id     uint64
	cancel context.CancelCauseFunc
}

type managedRunRegistry struct {
	mu             sync.Mutex
	nextID         uint64
	active         map[string]managedRunEntry
	pendingCancels map[string]struct{}
}

var probeRuns = managedRunRegistry{
	active:         make(map[string]managedRunEntry),
	pendingCancels: make(map[string]struct{}),
}

func manageProbeRun(parent context.Context, runID string, timeout time.Duration) (context.Context, func(), error) {
	if runID == "" {
		return nil, nil, &Error{Code: "INVALID_ARGUMENT", Stage: "request", Detail: "probeRunID must not be empty"}
	}
	if timeout <= 0 {
		timeout = managedProbeTimeout
	}

	timeoutCtx, stopTimeout := context.WithTimeoutCause(parent, timeout, errProbeTimedOut)
	ctx, cancel := context.WithCancelCause(timeoutCtx)

	entryID, shouldCancel, err := probeRuns.register(runID, cancel)
	if err != nil {
		cancel(nil)
		stopTimeout()
		return nil, nil, err
	}
	if shouldCancel {
		cancel(errProbeCanceled)
	}

	release := func() {
		probeRuns.unregister(runID, entryID)
		cancel(nil)
		stopTimeout()
	}
	return ctx, release, nil
}

func (registry *managedRunRegistry) register(runID string, cancel context.CancelCauseFunc) (uint64, bool, error) {
	registry.mu.Lock()
	defer registry.mu.Unlock()

	if _, exists := registry.active[runID]; exists {
		return 0, false, &Error{
			Code:   "PROBE_RUN_ID_IN_USE",
			Stage:  "request",
			Detail: fmt.Sprintf("probeRunID %q is already active", runID),
		}
	}

	registry.nextID += 1
	entryID := registry.nextID
	_, shouldCancel := registry.pendingCancels[runID]
	delete(registry.pendingCancels, runID)
	registry.active[runID] = managedRunEntry{
		id:     entryID,
		cancel: cancel,
	}
	return entryID, shouldCancel, nil
}

func (registry *managedRunRegistry) unregister(runID string, entryID uint64) {
	registry.mu.Lock()
	defer registry.mu.Unlock()

	entry, ok := registry.active[runID]
	if !ok || entry.id != entryID {
		return
	}
	delete(registry.active, runID)
}

func CancelProbeRun(runID string) CancelRunStatus {
	if runID == "" {
		return CancelRunInvalid
	}

	probeRuns.mu.Lock()
	defer probeRuns.mu.Unlock()

	if entry, ok := probeRuns.active[runID]; ok {
		entry.cancel(errProbeCanceled)
		return CancelRunRecorded
	}

	probeRuns.pendingCancels[runID] = struct{}{}
	return CancelRunPending
}
