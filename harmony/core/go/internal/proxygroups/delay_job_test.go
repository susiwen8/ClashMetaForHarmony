package proxygroups

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestDelayJobStartCancelsPreviousJobBeforeDiscovery(t *testing.T) {
	var oldCancelled atomic.Int32
	oldStarted := make(chan struct{}, DelayWorkerCount)
	oldNodes := make([]DelayRuntimeNode, 0, DelayWorkerCount)
	for i := 0; i < DelayWorkerCount; i++ {
		index := i
		oldNodes = append(oldNodes, delayRuntimeNode(fmt.Sprintf("old-%02d", index), func(ctx context.Context) (uint16, error) {
			oldStarted <- struct{}{}
			<-ctx.Done()
			oldCancelled.Add(1)
			return 77, nil
		}))
	}

	secondDiscoveryCalled := make(chan struct{}, 1)
	registry := &delayRegistryStub{
		delayNodes: func(groupName string) ([]DelayRuntimeNode, error) {
			switch groupName {
			case "old-group":
				return oldNodes, nil
			case "new-group":
				secondDiscoveryCalled <- struct{}{}
				if got := oldCancelled.Load(); got != DelayWorkerCount {
					return nil, fmt.Errorf("new discovery happened before old drain: %d", got)
				}
				return []DelayRuntimeNode{
					{Name: "nested", Type: "Selector", IsGroup: true},
				}, nil
			default:
				return nil, fmt.Errorf("unexpected group %q", groupName)
			}
		},
	}

	manager := NewDelayJobManager(registry, WithDelayJobIDSource(delayFixedIDSource("11111111111111111111111111111111", "22222222222222222222222222222222")))
	first, err := manager.Start(validQueryContext(nil), "old-group")
	if err != nil {
		t.Fatalf("Start(old-group) unexpected error: %v", err)
	}
	waitDelaySignals(t, oldStarted, DelayWorkerCount)

	secondDone := make(chan struct {
		snapshot DelayTestSnapshot
		err      error
	}, 1)
	go func() {
		snapshot, startErr := manager.Start(validQueryContext(nil), "new-group")
		secondDone <- struct {
			snapshot DelayTestSnapshot
			err      error
		}{snapshot: snapshot, err: startErr}
	}()

	select {
	case <-secondDiscoveryCalled:
	case <-time.After(2 * time.Second):
		t.Fatal("second discovery was never called")
	}

	result := <-secondDone
	if result.err != nil {
		t.Fatalf("Start(new-group) unexpected error: %v", result.err)
	}
	if result.snapshot.JobID != "22222222222222222222222222222222" {
		t.Fatalf("new job id = %q want %q", result.snapshot.JobID, "22222222222222222222222222222222")
	}

	_, err = manager.Read(first.JobID)
	assertErrorCode(t, err, ErrCodeDelayJobNotFound)
}

func TestDelayJobStartsExactlySixteenConcurrentProbes(t *testing.T) {
	release := make(chan struct{})
	started := make(chan int, 64)
	var active atomic.Int32
	var peak atomic.Int32

	nodes := make([]DelayRuntimeNode, 0, 40)
	for i := 0; i < 40; i++ {
		index := i
		nodes = append(nodes, delayRuntimeNode(fmt.Sprintf("node-%02d", index), func(ctx context.Context) (uint16, error) {
			current := active.Add(1)
			for {
				previous := peak.Load()
				if current <= previous || peak.CompareAndSwap(previous, current) {
					break
				}
			}
			started <- index
			<-release
			active.Add(-1)
			return uint16(index + 10), nil
		}))
	}

	manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{"group-a": nodes}}, WithDelayJobIDSource(delayFixedIDSource("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
	snapshot, err := manager.Start(validQueryContext(nil), "group-a")
	if err != nil {
		t.Fatalf("Start() unexpected error: %v", err)
	}

	waitDelayIndices(t, started, DelayWorkerCount)
	assertNoDelaySignal(t, started)
	close(release)

	final := waitDelayTerminalSnapshot(t, manager, snapshot.JobID)
	if final.State != DelayJobStateCompleted {
		t.Fatalf("final state = %q want %q", final.State, DelayJobStateCompleted)
	}
	if got := peak.Load(); got != DelayWorkerCount {
		t.Fatalf("peak probes = %d want %d", got, DelayWorkerCount)
	}
}

func TestDelayJobRejectsMalformedTestableSourceBeforeLaunchingWorkers(t *testing.T) {
	tests := []struct {
		name string
		node DelayRuntimeNode
	}{
		{
			name: "missing source",
			node: DelayRuntimeNode{
				Name:  "node-a",
				Type:  "Direct",
				Probe: func(context.Context) (uint16, error) { t.Fatal("probe must not run"); return 0, nil },
			},
		},
		{
			name: "invalid source",
			node: DelayRuntimeNode{
				Name: "node-b",
				Type: "Direct",
				Source: func() *DelayURLSource {
					source := DelayURLSource("BROKEN")
					return &source
				}(),
				Probe: func(context.Context) (uint16, error) { t.Fatal("probe must not run"); return 0, nil },
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var launched atomic.Int32
			node := tc.node
			node.Probe = func(context.Context) (uint16, error) {
				launched.Add(1)
				return 1, nil
			}

			manager := NewDelayJobManager(&delayRegistryStub{
				nodesByGroup: map[string][]DelayRuntimeNode{
					"group-a": {node},
				},
			}, WithDelayJobIDSource(delayFixedIDSource("10101010101010101010101010101010")))

			_, err := manager.Start(validQueryContext(nil), "group-a")
			assertErrorCode(t, err, ErrCodeInvalidDelaySnapshot)
			if got := launched.Load(); got != 0 {
				t.Fatalf("launched probes = %d want 0", got)
			}
			_, readErr := manager.Read("10101010101010101010101010101010")
			assertErrorCode(t, readErr, ErrCodeDelayJobNotFound)
		})
	}
}

func TestDelayJobMalformedDiscoveredSourceDrainsOldJobButPublishesNoNewJob(t *testing.T) {
	oldStarted := make(chan struct{}, 1)
	var oldCancelled atomic.Int32
	oldSource := DelayURLSourceProvider
	oldNodes := []DelayRuntimeNode{
		{
			Name:   "old-node",
			Type:   "Direct",
			Source: &oldSource,
			Probe: func(ctx context.Context) (uint16, error) {
				oldStarted <- struct{}{}
				<-ctx.Done()
				oldCancelled.Add(1)
				return 0, ctx.Err()
			},
		},
	}

	var malformedLaunched atomic.Int32
	registry := &delayRegistryStub{
		delayNodes: func(groupName string) ([]DelayRuntimeNode, error) {
			switch groupName {
			case "old-group":
				return cloneDelayRuntimeNodes(oldNodes), nil
			case "bad-group":
				return []DelayRuntimeNode{
					{
						Name:  "bad-node",
						Type:  "Direct",
						Probe: func(context.Context) (uint16, error) { malformedLaunched.Add(1); return 1, nil },
					},
				}, nil
			default:
				return nil, fmt.Errorf("unexpected group %q", groupName)
			}
		},
	}

	manager := NewDelayJobManager(registry, WithDelayJobIDSource(delayFixedIDSource(
		"11111111111111111111111111111111",
		"22222222222222222222222222222222",
	)))

	oldJob, err := manager.Start(validQueryContext(nil), "old-group")
	if err != nil {
		t.Fatalf("Start(old-group) unexpected error: %v", err)
	}
	waitDelaySignals(t, oldStarted, 1)

	_, err = manager.Start(validQueryContext(nil), "bad-group")
	assertErrorCode(t, err, ErrCodeInvalidDelaySnapshot)
	if got := oldCancelled.Load(); got != 1 {
		t.Fatalf("old cancelled count = %d want 1", got)
	}
	if got := malformedLaunched.Load(); got != 0 {
		t.Fatalf("malformed launched probes = %d want 0", got)
	}

	cancelledOld, err := manager.Read(oldJob.JobID)
	if err != nil {
		t.Fatalf("Read(old job) unexpected error: %v", err)
	}
	if cancelledOld.State != DelayJobStateCancelled {
		t.Fatalf("old job state = %q want %q", cancelledOld.State, DelayJobStateCancelled)
	}

	_, err = manager.Read("22222222222222222222222222222222")
	assertErrorCode(t, err, ErrCodeDelayJobNotFound)
}

func TestDelayJobConcurrentStartsSerializeToOneLiveJob(t *testing.T) {
	discoveryCalls := make(chan string, 2)
	releaseFirstDiscovery := make(chan struct{})
	releaseSecondDiscovery := make(chan struct{})
	started := make(chan string, 4)
	var activeProbes atomic.Int32
	var peakProbes atomic.Int32
	var discoveryCount atomic.Int32

	registry := &delayRegistryStub{
		delayNodes: func(groupName string) ([]DelayRuntimeNode, error) {
			call := discoveryCount.Add(1)
			discoveryCalls <- groupName
			switch call {
			case 1:
				<-releaseFirstDiscovery
			case 2:
				<-releaseSecondDiscovery
			default:
				t.Fatalf("unexpected discovery call %d for %q", call, groupName)
			}
			source := DelayURLSourceProvider
			return []DelayRuntimeNode{
				{
					Name:   "node-" + groupName,
					Type:   "Direct",
					Source: &source,
					Probe: func(ctx context.Context) (uint16, error) {
						started <- groupName
						current := activeProbes.Add(1)
						for {
							previous := peakProbes.Load()
							if current <= previous || peakProbes.CompareAndSwap(previous, current) {
								break
							}
						}
						<-ctx.Done()
						activeProbes.Add(-1)
						return 0, ctx.Err()
					},
				},
			}, nil
		},
	}

	manager := NewDelayJobManager(registry, WithDelayJobIDSource(delayFixedIDSource(
		"31313131313131313131313131313131",
		"42424242424242424242424242424242",
	)))

	type startResult struct {
		snapshot DelayTestSnapshot
		err      error
	}
	results := make(chan startResult, 2)
	go func() {
		snapshot, err := manager.Start(validQueryContext(nil), "group-a")
		results <- startResult{snapshot: snapshot, err: err}
	}()
	go func() {
		snapshot, err := manager.Start(validQueryContext(nil), "group-b")
		results <- startResult{snapshot: snapshot, err: err}
	}()

	firstDiscovery := waitDelayString(t, discoveryCalls)
	if firstDiscovery != "group-a" && firstDiscovery != "group-b" {
		t.Fatalf("unexpected first discovery group %q", firstDiscovery)
	}
	assertNoDelaySignal(t, discoveryCalls)
	close(releaseFirstDiscovery)

	secondDiscovery := waitDelayString(t, discoveryCalls)
	if secondDiscovery == firstDiscovery {
		t.Fatalf("second discovery repeated first group %q", secondDiscovery)
	}
	close(releaseSecondDiscovery)

	first := <-results
	second := <-results
	if first.err != nil {
		t.Fatalf("first Start() unexpected error: %v", first.err)
	}
	if second.err != nil {
		t.Fatalf("second Start() unexpected error: %v", second.err)
	}

	waitDelaySignals(t, started, 1)
	if got := peakProbes.Load(); got > 1 {
		t.Fatalf("peak concurrent live jobs/probes = %d want <= 1", got)
	}

	jobIDs := []string{first.snapshot.JobID, second.snapshot.JobID}
	if !containsString(jobIDs, "42424242424242424242424242424242") {
		t.Fatalf("results missing second generated job id: %+v", jobIDs)
	}

	current, err := manager.Read("42424242424242424242424242424242")
	if err != nil {
		t.Fatalf("Read(current) unexpected error: %v", err)
	}
	if current.JobID != "42424242424242424242424242424242" {
		t.Fatalf("current job id = %q want %q", current.JobID, "42424242424242424242424242424242")
	}

	_, err = manager.Read("31313131313131313131313131313131")
	assertErrorCode(t, err, ErrCodeDelayJobNotFound)

	if _, err := manager.Cancel("42424242424242424242424242424242"); err != nil {
		t.Fatalf("cleanup Cancel() unexpected error: %v", err)
	}
}

func TestDelayJobLifecycleOpsDoNotMissStartDiscoveryWindow(t *testing.T) {
	tests := []struct {
		name string
		op   func(*DelayJobManager, QueryContext) error
	}{
		{
			name: "cancel active",
			op: func(manager *DelayJobManager, ctx QueryContext) error {
				return manager.CancelActiveAndDrain()
			},
		},
		{
			name: "invalidate mismatch",
			op: func(manager *DelayJobManager, ctx QueryContext) error {
				mismatch := QueryContext{
					ProfileHash:  validHash("f"),
					RevisionHash: ctx.RevisionHash,
					SessionHash:  ctx.SessionHash,
					Generation:   ctx.Generation,
				}
				return manager.InvalidateActiveIfNot(mismatch, "group-a")
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			discoveryEntered := make(chan struct{}, 1)
			releaseDiscovery := make(chan struct{})
			started := make(chan struct{}, 1)
			manager := NewDelayJobManager(&delayRegistryStub{
				delayNodes: func(groupName string) ([]DelayRuntimeNode, error) {
					discoveryEntered <- struct{}{}
					<-releaseDiscovery
					return []DelayRuntimeNode{
						delayRuntimeNode("node-a", func(ctx context.Context) (uint16, error) {
							started <- struct{}{}
							<-ctx.Done()
							return 0, ctx.Err()
						}),
					}, nil
				},
			}, WithDelayJobIDSource(delayFixedIDSource("51515151515151515151515151515151")))

			ctx := validQueryContext(nil)
			type startResult struct {
				snapshot DelayTestSnapshot
				err      error
			}
			startDone := make(chan startResult, 1)
			go func() {
				snapshot, err := manager.Start(ctx, "group-a")
				startDone <- startResult{snapshot: snapshot, err: err}
			}()

			waitDelaySignals(t, discoveryEntered, 1)
			opDone := make(chan error, 1)
			go func() {
				opDone <- tc.op(manager, ctx)
			}()
			assertNoDelaySignal(t, started)
			close(releaseDiscovery)

			result := <-startDone
			if result.err != nil {
				t.Fatalf("Start() unexpected error: %v", result.err)
			}
			if err := <-opDone; err != nil {
				t.Fatalf("lifecycle op unexpected error: %v", err)
			}

			final := waitDelayTerminalSnapshot(t, manager, result.snapshot.JobID)
			if final.State != DelayJobStateCancelled {
				t.Fatalf("final state = %q want %q", final.State, DelayJobStateCancelled)
			}
		})
	}
}

func TestDelayJobSnapshotOrderAndProgressiveStates(t *testing.T) {
	started := make(chan int, 32)
	release := make([]chan struct{}, 17)
	nodes := make([]DelayRuntimeNode, 0, 17)
	for i := 0; i < 17; i++ {
		index := i
		release[i] = make(chan struct{})
		nodes = append(nodes, delayRuntimeNode(fmt.Sprintf("node-%02d", index), func(ctx context.Context) (uint16, error) {
			started <- index
			<-release[index]
			return uint16(index + 1), nil
		}))
	}

	manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{"ordered-group": nodes}}, WithDelayJobIDSource(delayFixedIDSource("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")))
	job, err := manager.Start(validQueryContext(nil), "ordered-group")
	if err != nil {
		t.Fatalf("Start() unexpected error: %v", err)
	}

	waitDelaySignals(t, started, DelayWorkerCount)
	running, err := manager.Read(job.JobID)
	if err != nil {
		t.Fatalf("Read(running) unexpected error: %v", err)
	}
	for i := 0; i < 16; i++ {
		if running.Nodes[i].State != DelayNodeStateTesting {
			t.Fatalf("running node[%d].State = %q want %q", i, running.Nodes[i].State, DelayNodeStateTesting)
		}
	}
	if running.Nodes[16].State != DelayNodeStateWaiting {
		t.Fatalf("running node[16].State = %q want %q", running.Nodes[16].State, DelayNodeStateWaiting)
	}

	close(release[15])
	waitDelayIndex(t, started, 16)
	progressed, err := manager.Read(job.JobID)
	if err != nil {
		t.Fatalf("Read(progressed) unexpected error: %v", err)
	}
	if progressed.Nodes[15].State != DelayNodeStateAvailable {
		t.Fatalf("progressed node[15].State = %q want %q", progressed.Nodes[15].State, DelayNodeStateAvailable)
	}
	if progressed.Nodes[16].State != DelayNodeStateTesting {
		t.Fatalf("progressed node[16].State = %q want %q", progressed.Nodes[16].State, DelayNodeStateTesting)
	}

	for i := 14; i >= 0; i-- {
		close(release[i])
	}
	close(release[16])

	final := waitDelayTerminalSnapshot(t, manager, job.JobID)
	if final.FastestNodeIndex == nil || *final.FastestNodeIndex != 0 {
		t.Fatalf("FastestNodeIndex = %v want 0", final.FastestNodeIndex)
	}
	for i := range final.Nodes {
		if final.Nodes[i].Index != i {
			t.Fatalf("final node[%d].Index = %d want %d", i, final.Nodes[i].Index, i)
		}
		if final.Nodes[i].Name != fmt.Sprintf("node-%02d", i) {
			t.Fatalf("final node[%d].Name = %q want %q", i, final.Nodes[i].Name, fmt.Sprintf("node-%02d", i))
		}
		if final.Nodes[i].State != DelayNodeStateAvailable {
			t.Fatalf("final node[%d].State = %q want %q", i, final.Nodes[i].State, DelayNodeStateAvailable)
		}
		if final.Nodes[i].DelayMs == nil || *final.Nodes[i].DelayMs != uint16(i+1) {
			t.Fatalf("final node[%d].DelayMs = %v want %d", i, final.Nodes[i].DelayMs, i+1)
		}
	}
}

func TestDelayJobMapsProbeResultsAndSetsChildDeadlines(t *testing.T) {
	var (
		mu        sync.Mutex
		deadlines []time.Time
	)
	recordDeadline := func(ctx context.Context) {
		t.Helper()
		deadline, ok := ctx.Deadline()
		if !ok {
			t.Fatal("probe context missing deadline")
		}
		mu.Lock()
		deadlines = append(deadlines, deadline)
		mu.Unlock()
	}

	nodes := []DelayRuntimeNode{
		delayRuntimeNode("ok", func(ctx context.Context) (uint16, error) {
			recordDeadline(ctx)
			return 25, nil
		}),
		delayRuntimeNode("zero", func(ctx context.Context) (uint16, error) {
			recordDeadline(ctx)
			return 0, nil
		}),
		delayRuntimeNode("error", func(ctx context.Context) (uint16, error) {
			recordDeadline(ctx)
			return 0, errors.New("boom")
		}),
		delayRuntimeNode("timeout", func(ctx context.Context) (uint16, error) {
			recordDeadline(ctx)
			return 0, context.DeadlineExceeded
		}),
	}

	manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{"group-a": nodes}}, WithDelayJobIDSource(delayFixedIDSource("cccccccccccccccccccccccccccccccc")))
	job, err := manager.Start(validQueryContext(nil), "group-a")
	if err != nil {
		t.Fatalf("Start() unexpected error: %v", err)
	}

	final := waitDelayTerminalSnapshot(t, manager, job.JobID)
	if final.State != DelayJobStateCompleted {
		t.Fatalf("final state = %q want %q", final.State, DelayJobStateCompleted)
	}
	assertDelayNodeState(t, final.Nodes[0], DelayNodeStateAvailable, 25)
	assertDelayNodeState(t, final.Nodes[1], DelayNodeStateFailed, 0)
	assertDelayNodeState(t, final.Nodes[2], DelayNodeStateFailed, 0)
	assertDelayNodeState(t, final.Nodes[3], DelayNodeStateTimeout, 0)

	mu.Lock()
	defer mu.Unlock()
	if len(deadlines) != len(nodes) {
		t.Fatalf("recorded deadlines = %d want %d", len(deadlines), len(nodes))
	}
	for _, deadline := range deadlines {
		remaining := time.Until(deadline)
		if remaining < 4*time.Second || remaining > 6*time.Second {
			t.Fatalf("deadline remaining = %v want about %v", remaining, DelayNodeTimeout)
		}
	}
}

func TestDelayJobCancelBoundaryPreservesCompletedProbeOutcome(t *testing.T) {
	tests := []struct {
		name      string
		probe     func(context.Context, <-chan struct{}) (uint16, error)
		wantState DelayNodeState
		wantDelay uint16
	}{
		{
			name: "success stays available",
			probe: func(ctx context.Context, release <-chan struct{}) (uint16, error) {
				<-ctx.Done()
				<-release
				return 7, nil
			},
			wantState: DelayNodeStateAvailable,
			wantDelay: 7,
		},
		{
			name: "child deadline stays timeout",
			probe: func(ctx context.Context, release <-chan struct{}) (uint16, error) {
				<-ctx.Done()
				<-release
				return 0, context.DeadlineExceeded
			},
			wantState: DelayNodeStateTimeout,
		},
		{
			name: "ordinary error stays failed",
			probe: func(ctx context.Context, release <-chan struct{}) (uint16, error) {
				<-ctx.Done()
				<-release
				return 0, errors.New("boom")
			},
			wantState: DelayNodeStateFailed,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			release := make(chan struct{})
			started := make(chan struct{}, 1)
			manager := NewDelayJobManager(&delayRegistryStub{
				nodesByGroup: map[string][]DelayRuntimeNode{
					"group-a": {
						delayRuntimeNode("node-a", func(ctx context.Context) (uint16, error) {
							started <- struct{}{}
							return tc.probe(ctx, release)
						}),
					},
				},
			}, WithDelayJobIDSource(delayFixedIDSource("61616161616161616161616161616161")))

			job, err := manager.Start(validQueryContext(nil), "group-a")
			if err != nil {
				t.Fatalf("Start() unexpected error: %v", err)
			}
			waitDelaySignals(t, started, 1)

			cancelDone := make(chan struct {
				snapshot DelayTestSnapshot
				err      error
			}, 1)
			go func() {
				snapshot, cancelErr := manager.Cancel(job.JobID)
				cancelDone <- struct {
					snapshot DelayTestSnapshot
					err      error
				}{snapshot: snapshot, err: cancelErr}
			}()

			close(release)
			cancelled := <-cancelDone
			if cancelled.err != nil {
				t.Fatalf("Cancel() unexpected error: %v", cancelled.err)
			}
			if cancelled.snapshot.State != DelayJobStateCancelled {
				t.Fatalf("snapshot state = %q want %q", cancelled.snapshot.State, DelayJobStateCancelled)
			}
			assertDelayNodeState(t, cancelled.snapshot.Nodes[0], tc.wantState, tc.wantDelay)
		})
	}
}

func TestDelayJobCancelRetainsPartialResultsAndCancelsQueuedAndActiveNodes(t *testing.T) {
	started := make(chan int, 32)
	firstRelease := make(chan struct{})
	nodes := make([]DelayRuntimeNode, 0, 18)
	for i := 0; i < 18; i++ {
		index := i
		switch index {
		case 0:
			nodes = append(nodes, delayRuntimeNode("node-00", func(ctx context.Context) (uint16, error) {
				started <- 0
				<-firstRelease
				return 9, nil
			}))
		default:
			nodes = append(nodes, delayRuntimeNode(fmt.Sprintf("node-%02d", index), func(ctx context.Context) (uint16, error) {
				started <- index
				<-ctx.Done()
				return 0, ctx.Err()
			}))
		}
	}

	manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{"group-a": nodes}}, WithDelayJobIDSource(delayFixedIDSource("dddddddddddddddddddddddddddddddd")))
	job, err := manager.Start(validQueryContext(nil), "group-a")
	if err != nil {
		t.Fatalf("Start() unexpected error: %v", err)
	}
	waitDelaySignals(t, started, DelayWorkerCount)

	close(firstRelease)
	waitDelayIndex(t, started, 16)

	cancelled, err := manager.Cancel(job.JobID)
	if err != nil {
		t.Fatalf("Cancel() unexpected error: %v", err)
	}
	if cancelled.State != DelayJobStateCancelled {
		t.Fatalf("cancelled state = %q want %q", cancelled.State, DelayJobStateCancelled)
	}
	assertDelayNodeState(t, cancelled.Nodes[0], DelayNodeStateAvailable, 9)
	for i := 1; i < 17; i++ {
		assertDelayNodeState(t, cancelled.Nodes[i], DelayNodeStateCancelled, 0)
	}
	assertDelayNodeState(t, cancelled.Nodes[17], DelayNodeStateCancelled, 0)

	readBack, err := manager.Read(job.JobID)
	if err != nil {
		t.Fatalf("Read(cancelled) unexpected error: %v", err)
	}
	if !reflect.DeepEqual(cancelled, readBack) {
		t.Fatal("cancelled snapshot changed after final publication")
	}
}

func TestDelayJobReadIsSideEffectFreeAndCancelIsIdempotent(t *testing.T) {
	started := make(chan struct{}, 1)
	nodes := []DelayRuntimeNode{
		delayRuntimeNode("node-a", func(ctx context.Context) (uint16, error) {
			started <- struct{}{}
			<-ctx.Done()
			return 0, ctx.Err()
		}),
	}
	manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{"group-a": nodes}}, WithDelayJobIDSource(delayFixedIDSource("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")))
	job, err := manager.Start(validQueryContext(nil), "group-a")
	if err != nil {
		t.Fatalf("Start() unexpected error: %v", err)
	}
	waitDelaySignals(t, started, 1)

	firstRead, err := manager.Read(job.JobID)
	if err != nil {
		t.Fatalf("first Read() unexpected error: %v", err)
	}
	secondRead, err := manager.Read(job.JobID)
	if err != nil {
		t.Fatalf("second Read() unexpected error: %v", err)
	}
	if !reflect.DeepEqual(firstRead, secondRead) {
		t.Fatal("Read() mutated snapshot state")
	}

	firstCancel, err := manager.Cancel(job.JobID)
	if err != nil {
		t.Fatalf("first Cancel() unexpected error: %v", err)
	}
	secondCancel, err := manager.Cancel(job.JobID)
	if err != nil {
		t.Fatalf("second Cancel() unexpected error: %v", err)
	}
	if !reflect.DeepEqual(firstCancel, secondCancel) {
		t.Fatal("Cancel() was not idempotent")
	}
}

func TestDelayJobTerminalStatesForAllFailuresAndZeroTestable(t *testing.T) {
	t.Run("all ordinary failures complete job", func(t *testing.T) {
		nodes := []DelayRuntimeNode{
			delayRuntimeNode("zero", func(ctx context.Context) (uint16, error) { return 0, nil }),
			delayRuntimeNode("error", func(ctx context.Context) (uint16, error) { return 0, errors.New("nope") }),
		}
		manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{"group-a": nodes}}, WithDelayJobIDSource(delayFixedIDSource("ffffffffffffffffffffffffffffffff")))
		job, err := manager.Start(validQueryContext(nil), "group-a")
		if err != nil {
			t.Fatalf("Start() unexpected error: %v", err)
		}
		final := waitDelayTerminalSnapshot(t, manager, job.JobID)
		if final.State != DelayJobStateCompleted {
			t.Fatalf("final state = %q want %q", final.State, DelayJobStateCompleted)
		}
		if final.FailedCount != 2 || final.AvailableCount != 0 || final.FastestNodeIndex != nil {
			t.Fatalf("unexpected all-failure snapshot: %+v", final)
		}
	})

	t.Run("failed plus unsupported still completes job", func(t *testing.T) {
		nodes := []DelayRuntimeNode{
			delayRuntimeNode("error", func(ctx context.Context) (uint16, error) { return 0, errors.New("nope") }),
			{Name: "nested", Type: "Selector", IsGroup: true},
			{Name: "no-probe", Type: "Direct", Probe: nil},
		}
		manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{"group-c": nodes}}, WithDelayJobIDSource(delayFixedIDSource("edededededededededededededededed")))
		job, err := manager.Start(validQueryContext(nil), "group-c")
		if err != nil {
			t.Fatalf("Start() unexpected error: %v", err)
		}
		final := waitDelayTerminalSnapshot(t, manager, job.JobID)
		if final.State != DelayJobStateCompleted {
			t.Fatalf("final state = %q want %q", final.State, DelayJobStateCompleted)
		}
		if final.FailedCount != 1 || final.UnsupportedCount != 2 || final.TestableCount != 1 {
			t.Fatalf("unexpected failed+unsupported snapshot: %+v", final)
		}
	})

	t.Run("zero testable", func(t *testing.T) {
		manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{
			"group-b": {
				{Name: "nested", Type: "Selector", IsGroup: true},
				{Name: "no-probe", Type: "Direct", Probe: nil},
			},
		}}, WithDelayJobIDSource(delayFixedIDSource("99999999999999999999999999999999")))
		job, err := manager.Start(validQueryContext(nil), "group-b")
		if err != nil {
			t.Fatalf("Start() unexpected error: %v", err)
		}
		if job.State != DelayJobStateCompleted {
			t.Fatalf("job state = %q want %q", job.State, DelayJobStateCompleted)
		}
		if job.TestableCount != 0 || job.UnsupportedCount != 2 {
			t.Fatalf("unexpected zero-testable snapshot: %+v", job)
		}
		for i, node := range job.Nodes {
			if node.State != DelayNodeStateUnsupported {
				t.Fatalf("job.Nodes[%d].State = %q want %q", i, node.State, DelayNodeStateUnsupported)
			}
		}
	})
}

func TestDelayJobRejectsInvalidMissingAndStaleJobIDs(t *testing.T) {
	manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{
		"group-a": {{Name: "nested", Type: "Selector", IsGroup: true}},
		"group-b": {{Name: "nested", Type: "Selector", IsGroup: true}},
	}}, WithDelayJobIDSource(delayFixedIDSource(
		"12121212121212121212121212121212",
		"34343434343434343434343434343434",
	)))

	first, err := manager.Start(validQueryContext(nil), "group-a")
	if err != nil {
		t.Fatalf("first Start() unexpected error: %v", err)
	}
	second, err := manager.Start(validQueryContext(nil), "group-b")
	if err != nil {
		t.Fatalf("second Start() unexpected error: %v", err)
	}

	tests := []struct {
		name  string
		jobID string
		call  func(string) error
	}{
		{
			name:  "invalid read id",
			jobID: "not-a-job-id",
			call: func(jobID string) error {
				_, readErr := manager.Read(jobID)
				return readErr
			},
		},
		{
			name:  "missing cancel id",
			jobID: strings.Repeat("7", MaxDelayJobIDBytes),
			call: func(jobID string) error {
				_, cancelErr := manager.Cancel(jobID)
				return cancelErr
			},
		},
		{
			name:  "stale read id",
			jobID: first.JobID,
			call: func(jobID string) error {
				_, readErr := manager.Read(jobID)
				return readErr
			},
		},
		{
			name:  "stale cancel id",
			jobID: first.JobID,
			call: func(jobID string) error {
				_, cancelErr := manager.Cancel(jobID)
				return cancelErr
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.call(tc.jobID)
			assertErrorCode(t, err, ErrCodeDelayJobNotFound)
			assertNoLeak(t, err, tc.jobID, first.GroupName, second.GroupName)
		})
	}
}

func TestDelayJobRejectsRepeatedGeneratedJobID(t *testing.T) {
	manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{
		"group-a": {{Name: "nested-a", Type: "Selector", IsGroup: true}},
		"group-b": {{Name: "nested-b", Type: "Selector", IsGroup: true}},
	}}, WithDelayJobIDSource(delayFixedIDSource(
		"71717171717171717171717171717171",
		"71717171717171717171717171717171",
	)))

	first, err := manager.Start(validQueryContext(nil), "group-a")
	if err != nil {
		t.Fatalf("first Start() unexpected error: %v", err)
	}

	_, err = manager.Start(validQueryContext(nil), "group-b")
	assertErrorCode(t, err, ErrCodeInvalidDelaySnapshot)

	stillFirst, err := manager.Read(first.JobID)
	if err != nil {
		t.Fatalf("Read(first) unexpected error: %v", err)
	}
	if stillFirst.GroupName != "group-a" || stillFirst.JobID != first.JobID {
		t.Fatalf("current snapshot changed after duplicate id rejection: %+v", stillFirst)
	}
}

func TestDelayJobInvalidateActiveIfNot(t *testing.T) {
	t.Run("exact match keeps job running", func(t *testing.T) {
		started := make(chan struct{}, 1)
		manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{
			"group-a": {delayRuntimeNode("node-a", func(ctx context.Context) (uint16, error) {
				started <- struct{}{}
				<-ctx.Done()
				return 0, ctx.Err()
			})},
		}}, WithDelayJobIDSource(delayFixedIDSource("56565656565656565656565656565656")))
		ctx := validQueryContext(strPtr(validHash("c")))
		job, err := manager.Start(ctx, "group-a")
		if err != nil {
			t.Fatalf("Start() unexpected error: %v", err)
		}
		waitDelaySignals(t, started, 1)

		if err := manager.InvalidateActiveIfNot(ctx, "group-a"); err != nil {
			t.Fatalf("InvalidateActiveIfNot() unexpected error: %v", err)
		}
		running, err := manager.Read(job.JobID)
		if err != nil {
			t.Fatalf("Read() unexpected error: %v", err)
		}
		if running.State != DelayJobStateRunning {
			t.Fatalf("running state = %q want %q", running.State, DelayJobStateRunning)
		}

		if _, err := manager.Cancel(job.JobID); err != nil {
			t.Fatalf("cleanup Cancel() unexpected error: %v", err)
		}
	})

	baseCtx := validQueryContext(strPtr(validHash("d")))
	tests := []struct {
		name      string
		ctx       QueryContext
		groupName string
	}{
		{name: "profile mismatch", ctx: QueryContext{ProfileHash: validHash("e"), RevisionHash: baseCtx.RevisionHash, SessionHash: baseCtx.SessionHash, Generation: baseCtx.Generation}, groupName: "group-a"},
		{name: "revision mismatch", ctx: QueryContext{ProfileHash: baseCtx.ProfileHash, RevisionHash: validHash("f"), SessionHash: baseCtx.SessionHash, Generation: baseCtx.Generation}, groupName: "group-a"},
		{name: "session mismatch", ctx: QueryContext{ProfileHash: baseCtx.ProfileHash, RevisionHash: baseCtx.RevisionHash, SessionHash: strPtr(validHash("1")), Generation: baseCtx.Generation}, groupName: "group-a"},
		{name: "generation mismatch", ctx: QueryContext{ProfileHash: baseCtx.ProfileHash, RevisionHash: baseCtx.RevisionHash, SessionHash: baseCtx.SessionHash, Generation: baseCtx.Generation + 1}, groupName: "group-a"},
		{name: "group mismatch", ctx: baseCtx, groupName: "group-b"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			started := make(chan struct{}, 1)
			manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{
				"group-a": {delayRuntimeNode("node-a", func(ctx context.Context) (uint16, error) {
					started <- struct{}{}
					<-ctx.Done()
					return 0, ctx.Err()
				})},
			}}, WithDelayJobIDSource(delayFixedIDSource("78787878787878787878787878787878")))
			job, err := manager.Start(baseCtx, "group-a")
			if err != nil {
				t.Fatalf("Start() unexpected error: %v", err)
			}
			waitDelaySignals(t, started, 1)

			if err := manager.InvalidateActiveIfNot(tc.ctx, tc.groupName); err != nil {
				t.Fatalf("InvalidateActiveIfNot() unexpected error: %v", err)
			}
			final := waitDelayTerminalSnapshot(t, manager, job.JobID)
			if final.State != DelayJobStateCancelled {
				t.Fatalf("final state = %q want %q", final.State, DelayJobStateCancelled)
			}
		})
	}
}

func TestDelayJobConcurrentReadAndCancelIsRaceSafe(t *testing.T) {
	started := make(chan struct{}, DelayWorkerCount)
	nodes := make([]DelayRuntimeNode, 0, DelayWorkerCount)
	for i := 0; i < DelayWorkerCount; i++ {
		nodes = append(nodes, delayRuntimeNode(fmt.Sprintf("node-%02d", i), func(ctx context.Context) (uint16, error) {
			started <- struct{}{}
			<-ctx.Done()
			return 0, ctx.Err()
		}))
	}
	manager := NewDelayJobManager(&delayRegistryStub{nodesByGroup: map[string][]DelayRuntimeNode{"group-a": nodes}}, WithDelayJobIDSource(delayFixedIDSource("abababababababababababababababab")))
	job, err := manager.Start(validQueryContext(nil), "group-a")
	if err != nil {
		t.Fatalf("Start() unexpected error: %v", err)
	}
	waitDelaySignals(t, started, DelayWorkerCount)

	stop := make(chan struct{})
	var readers sync.WaitGroup
	for i := 0; i < 8; i++ {
		readers.Add(1)
		go func() {
			defer readers.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				if _, readErr := manager.Read(job.JobID); readErr != nil {
					t.Errorf("Read() unexpected error: %v", readErr)
					return
				}
				runtime.Gosched()
			}
		}()
	}

	cancelled, err := manager.Cancel(job.JobID)
	close(stop)
	readers.Wait()
	if err != nil {
		t.Fatalf("Cancel() unexpected error: %v", err)
	}
	if cancelled.State != DelayJobStateCancelled {
		t.Fatalf("cancelled state = %q want %q", cancelled.State, DelayJobStateCancelled)
	}
}

type delayRegistryStub struct {
	mu           sync.Mutex
	nodesByGroup map[string][]DelayRuntimeNode
	delayNodes   func(groupName string) ([]DelayRuntimeNode, error)
}

func (r *delayRegistryStub) DelayNodes(groupName string) ([]DelayRuntimeNode, error) {
	if r.delayNodes != nil {
		return r.delayNodes(groupName)
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	nodes, ok := r.nodesByGroup[groupName]
	if !ok {
		return nil, fmt.Errorf("group %q not found", groupName)
	}
	return cloneDelayRuntimeNodes(nodes), nil
}

func delayRuntimeNode(name string, probe DelayProbe) DelayRuntimeNode {
	source := DelayURLSourceProvider
	return DelayRuntimeNode{
		Name:   name,
		Type:   "Direct",
		Source: &source,
		Probe:  probe,
	}
}

func delayFixedIDSource(ids ...string) func() (string, error) {
	var (
		mu    sync.Mutex
		index int
	)
	return func() (string, error) {
		mu.Lock()
		defer mu.Unlock()
		if index >= len(ids) {
			return "", fmt.Errorf("id source exhausted")
		}
		value := ids[index]
		index++
		return value, nil
	}
}

func waitDelaySignals[T any](t *testing.T, ch <-chan T, count int) {
	t.Helper()
	for i := 0; i < count; i++ {
		select {
		case <-ch:
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for signal %d/%d", i+1, count)
		}
	}
}

func waitDelayIndices(t *testing.T, ch <-chan int, count int) []int {
	t.Helper()
	values := make([]int, 0, count)
	for i := 0; i < count; i++ {
		select {
		case value := <-ch:
			values = append(values, value)
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for index %d/%d", i+1, count)
		}
	}
	return values
}

func waitDelayIndex(t *testing.T, ch <-chan int, want int) {
	t.Helper()
	select {
	case got := <-ch:
		if got != want {
			t.Fatalf("started index = %d want %d", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for index %d", want)
	}
}

func waitDelayString(t *testing.T, ch <-chan string) string {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for string signal")
		return ""
	}
}

func assertNoDelaySignal[T any](t *testing.T, ch <-chan T) {
	t.Helper()
	select {
	case <-ch:
		t.Fatal("unexpected signal")
	default:
	}
}

func waitDelayTerminalSnapshot(t *testing.T, manager *DelayJobManager, jobID string) DelayTestSnapshot {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		snapshot, err := manager.Read(jobID)
		if err != nil {
			t.Fatalf("Read(%q) unexpected error while waiting: %v", jobID, err)
		}
		if snapshot.State != DelayJobStateRunning {
			return snapshot
		}
		runtime.Gosched()
	}
	t.Fatalf("timed out waiting for terminal snapshot for %q", jobID)
	return DelayTestSnapshot{}
}

func assertDelayNodeState(t *testing.T, node DelayNodeResult, state DelayNodeState, delay uint16) {
	t.Helper()
	if node.State != state {
		t.Fatalf("node %q state = %q want %q", node.Name, node.State, state)
	}
	if delay == 0 {
		if node.DelayMs != nil {
			t.Fatalf("node %q delay = %v want nil", node.Name, node.DelayMs)
		}
		return
	}
	if node.DelayMs == nil || *node.DelayMs != delay {
		t.Fatalf("node %q delay = %v want %d", node.Name, node.DelayMs, delay)
	}
}

func cloneDelayRuntimeNodes(nodes []DelayRuntimeNode) []DelayRuntimeNode {
	if nodes == nil {
		return nil
	}
	cloned := make([]DelayRuntimeNode, len(nodes))
	for i, node := range nodes {
		cloned[i] = DelayRuntimeNode{
			Name:    node.Name,
			Type:    node.Type,
			IsGroup: node.IsGroup,
			Source:  cloneDelayURLSourcePtr(node.Source),
			Probe:   node.Probe,
		}
	}
	return cloned
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
