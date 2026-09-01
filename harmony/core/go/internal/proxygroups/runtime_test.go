package proxygroups

import (
	"encoding/json"
	"errors"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

func TestServiceListGroupsFiltersHiddenAndSelectableOnly(t *testing.T) {
	ctx := validQueryContext(nil)
	service := NewService(&fakeRegistry{
		activeGroups: []RuntimeGroup{
			newFakeGroup(RuntimeGroupSnapshot{
				Name: "group-a",
				Type: "Fallback",
			}),
			newFakeGroup(RuntimeGroupSnapshot{
				Name:   "group-hidden",
				Type:   "Selector",
				Hidden: true,
			}),
			newFakeGroup(RuntimeGroupSnapshot{
				Name: "group-b",
				Type: "Selector",
			}),
			newFakeGroup(RuntimeGroupSnapshot{
				Name: "group-c",
				Type: "URLTest",
			}),
		},
	})

	payload, err := service.ListGroups(ctx, false)
	if err != nil {
		t.Fatalf("ListGroups(false) unexpected error: %v", err)
	}

	envelope := decodeGroupListEnvelope(t, payload)
	assertGroupRefs(t, envelope.Groups, []GroupRef{
		{Name: "group-a", Type: "Fallback"},
		{Name: "group-b", Type: "Selector"},
		{Name: "group-c", Type: "URLTest"},
	})

	payload, err = service.ListGroups(ctx, true)
	if err != nil {
		t.Fatalf("ListGroups(true) unexpected error: %v", err)
	}

	envelope = decodeGroupListEnvelope(t, payload)
	assertGroupRefs(t, envelope.Groups, []GroupRef{
		{Name: "group-b", Type: "Selector"},
	})
}

func TestServiceListGroupsUsesLightweightReferencesWithoutEnumeratingMembers(t *testing.T) {
	selector := &referenceOnlyGroup{
		reference: RuntimeGroupReference{Name: "selector-group", Type: "Selector"},
	}
	nonSelector := &referenceOnlyGroup{
		reference: RuntimeGroupReference{Name: "load-balance-group", Type: "LoadBalance"},
	}
	service := NewService(&fakeRegistry{activeGroups: []RuntimeGroup{selector, nonSelector}})

	payload, err := service.ListGroups(validQueryContext(nil), true)
	if err != nil {
		t.Fatalf("ListGroups(selectable) unexpected error: %v", err)
	}
	envelope := decodeGroupListEnvelope(t, payload)
	assertGroupRefs(t, envelope.Groups, []GroupRef{{Name: "selector-group", Type: "Selector"}})
	if selector.snapshotCalls != 0 || nonSelector.snapshotCalls != 0 {
		t.Fatal("group listing must not enumerate member snapshots")
	}
}

func TestServiceQueryGroupReturnsOrderedMembersAndNestedFlags(t *testing.T) {
	ctx := validQueryContext(nil)
	service := NewService(&fakeRegistry{
		groups: map[string]RuntimeGroup{
			"group-a": newFakeGroup(RuntimeGroupSnapshot{
				Name:    "group-a",
				Type:    "Selector",
				Current: "member-b",
				Members: []RuntimeNode{
					{Name: "member-a", Type: "Direct"},
					{Name: "nested-group", Type: "Relay", IsGroup: true},
					{Name: "member-b", Type: "Reject"},
				},
			}),
		},
	})

	payload, err := service.QueryGroup(ctx, "group-a")
	if err != nil {
		t.Fatalf("QueryGroup() unexpected error: %v", err)
	}

	envelope := decodeGroupSnapshotEnvelope(t, payload)
	want := GroupSnapshot{
		Name:         "group-a",
		Type:         "Selector",
		SelectedName: "member-b",
		Nodes: []NodeSummary{
			{Name: "member-a", Type: "Direct"},
			{Name: "nested-group", Type: "Relay", IsGroup: true},
			{Name: "member-b", Type: "Reject", Selected: true},
		},
	}
	if !reflect.DeepEqual(envelope.Group, want) {
		t.Fatalf("Group snapshot mismatch")
	}
}

func TestServiceSerializesListQueryAndSelectWithOneSharedMutex(t *testing.T) {
	ctx := validQueryContext(nil)
	monitor := newOperationMonitor()
	activeGroup := newFakeGroup(RuntimeGroupSnapshot{
		Name: "group-a",
		Type: "Selector",
	})
	activeGroup.monitor = monitor
	querySelectGroup := newFakeGroup(
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-a",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-b",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
	)
	querySelectGroup.monitor = monitor

	registry := &fakeRegistry{
		activeGroups: []RuntimeGroup{activeGroup},
		groups: map[string]RuntimeGroup{
			"group-a": querySelectGroup,
		},
		monitor: monitor,
	}
	service := NewService(registry)

	listDone := make(chan error, 1)
	go func() {
		_, err := service.ListGroups(ctx, false)
		listDone <- err
	}()

	firstOp := waitForOperation(t, monitor.entered)
	if firstOp == "" {
		t.Fatalf("expected first operation label")
	}

	queryDone := make(chan error, 1)
	go func() {
		_, err := service.QueryGroup(ctx, "group-a")
		queryDone <- err
	}()

	selectDone := make(chan error, 1)
	go func() {
		_, err := service.Select(ctx, "group-a", "member-b")
		selectDone <- err
	}()

	assertNoOperation(t, monitor.entered)
	monitor.releaseAll()

	if err := waitForResult(t, listDone); err != nil {
		t.Fatalf("ListGroups() unexpected error: %v", err)
	}
	if err := waitForResult(t, queryDone); err != nil {
		t.Fatalf("QueryGroup() unexpected error: %v", err)
	}
	if err := waitForResult(t, selectDone); err != nil {
		t.Fatalf("Select() unexpected error: %v", err)
	}
	if got := monitor.maxConcurrent(); got != 1 {
		t.Fatalf("max concurrent registry/group operations = %d want 1", got)
	}
}

func TestServiceRejectsInvalidQueryContextBeforeRegistryAccess(t *testing.T) {
	registry := &fakeRegistry{panicOnAccess: true}
	service := NewService(registry)

	_, err := service.ListGroups(QueryContext{}, false)
	assertErrorCode(t, err, ErrCodeInvalidQueryContext)
	if got := registry.totalCalls(); got != 0 {
		t.Fatalf("registry accessed %d times for invalid query context", got)
	}
}

func TestServiceRejectsInvalidNamesBeforeRegistryAccess(t *testing.T) {
	ctx := validQueryContext(nil)

	t.Run("invalid group name on query", func(t *testing.T) {
		registry := &fakeRegistry{panicOnAccess: true}
		service := NewService(registry)

		_, err := service.QueryGroup(ctx, "")
		assertErrorCode(t, err, ErrCodeInvalidName)
		if got := registry.totalCalls(); got != 0 {
			t.Fatalf("registry accessed %d times for invalid query group name", got)
		}
	})

	t.Run("invalid group name on select", func(t *testing.T) {
		registry := &fakeRegistry{panicOnAccess: true}
		service := NewService(registry)

		_, err := service.Select(ctx, "", "member-a")
		assertErrorCode(t, err, ErrCodeInvalidName)
		if got := registry.totalCalls(); got != 0 {
			t.Fatalf("registry accessed %d times for invalid select group name", got)
		}
	})

	t.Run("invalid member name on select", func(t *testing.T) {
		registry := &fakeRegistry{panicOnAccess: true}
		service := NewService(registry)

		_, err := service.Select(ctx, "group-a", "")
		assertErrorCode(t, err, ErrCodeInvalidName)
		if got := registry.totalCalls(); got != 0 {
			t.Fatalf("registry accessed %d times for invalid select member name", got)
		}
	})
}

func TestServiceQueryFailuresUseTypedCodes(t *testing.T) {
	ctx := validQueryContext(nil)

	t.Run("runtime not ready", func(t *testing.T) {
		service := NewService(&fakeRegistry{
			activeErr: newModelError(ErrCodeProxyRuntimeNotReady),
		})

		_, err := service.ListGroups(ctx, false)
		assertErrorCode(t, err, ErrCodeProxyRuntimeNotReady)
	})

	t.Run("missing group", func(t *testing.T) {
		service := NewService(&fakeRegistry{
			groupErrs: map[string]error{
				"group-a": newModelError(ErrCodeProxyGroupNotFound),
			},
		})

		_, err := service.QueryGroup(ctx, "group-a")
		assertErrorCode(t, err, ErrCodeProxyGroupNotFound)
	})

	t.Run("registry entry is not a group", func(t *testing.T) {
		service := NewService(&fakeRegistry{
			groupErrs: map[string]error{
				"group-a": newModelError(ErrCodeProxyBridgeInvalid),
			},
		})

		_, err := service.QueryGroup(ctx, "group-a")
		assertErrorCode(t, err, ErrCodeProxyBridgeInvalid)
	})

	t.Run("duplicate member names", func(t *testing.T) {
		service := NewService(&fakeRegistry{
			groups: map[string]RuntimeGroup{
				"group-a": newFakeGroup(RuntimeGroupSnapshot{
					Name:    "group-a",
					Type:    "Selector",
					Current: "member-a",
					Members: []RuntimeNode{
						{Name: "member-a", Type: "Direct"},
						{Name: "member-a", Type: "Reject"},
					},
				}),
			},
		})

		_, err := service.QueryGroup(ctx, "group-a")
		assertErrorCode(t, err, ErrCodeProxyBridgeInvalid)
	})

	t.Run("malformed current selection", func(t *testing.T) {
		service := NewService(&fakeRegistry{
			groups: map[string]RuntimeGroup{
				"group-a": newFakeGroup(RuntimeGroupSnapshot{
					Name:    "group-a",
					Type:    "Selector",
					Current: "missing-member",
					Members: []RuntimeNode{
						{Name: "member-a", Type: "Direct"},
					},
				}),
			},
		})

		_, err := service.QueryGroup(ctx, "group-a")
		assertErrorCode(t, err, ErrCodeProxyBridgeInvalid)
	})

	t.Run("invalid types", func(t *testing.T) {
		service := NewService(&fakeRegistry{
			groups: map[string]RuntimeGroup{
				"group-a": newFakeGroup(RuntimeGroupSnapshot{
					Name:    "group-a",
					Type:    "FutureType",
					Current: "member-a",
					Members: []RuntimeNode{
						{Name: "member-a", Type: "FutureType"},
					},
				}),
			},
		})

		_, err := service.QueryGroup(ctx, "group-a")
		assertErrorCode(t, err, ErrCodeProxyBridgeInvalid)
	})
}

func TestServiceSelectRejectsNonSelectorAndMissingMemberBeforeMutation(t *testing.T) {
	ctx := validQueryContext(nil)

	t.Run("non selector", func(t *testing.T) {
		group := newFakeGroup(RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "URLTest",
			Current: "member-a",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		})
		service := NewService(&fakeRegistry{
			groups: map[string]RuntimeGroup{
				"group-a": group,
			},
		})

		_, err := service.Select(ctx, "group-a", "member-b")
		assertErrorCode(t, err, ErrCodeProxyGroupNotSelectable)
		if len(group.setCalls) != 0 {
			t.Fatalf("Set() should not be called")
		}
	})

	t.Run("missing member", func(t *testing.T) {
		group := newFakeGroup(RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-a",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
			},
		})
		service := NewService(&fakeRegistry{
			groups: map[string]RuntimeGroup{
				"group-a": group,
			},
		})

		_, err := service.Select(ctx, "group-a", "member-b")
		assertErrorCode(t, err, ErrCodeProxyMemberNotFound)
		if len(group.setCalls) != 0 {
			t.Fatalf("Set() should not be called")
		}
	})
}

func TestServiceSelectSetFailurePreservesPreviousSelection(t *testing.T) {
	ctx := validQueryContext(nil)
	group := newFakeGroup(
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-a",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-a",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
	)
	group.setErr = errors.New("synthetic set failure")
	registry := &fakeRegistry{
		groups: map[string]RuntimeGroup{
			"group-a": group,
		},
	}
	service := NewService(registry)

	_, err := service.Select(ctx, "group-a", "member-b")
	assertErrorCode(t, err, ErrCodeProxySelectionFailed)
	assertNoLeak(t, err, "group-a", "member-a", "member-b")
	if len(registry.closedGroups) != 0 {
		t.Fatalf("CloseConnectionsForGroup() should not be called")
	}

	payload, err := service.QueryGroup(ctx, "group-a")
	if err != nil {
		t.Fatalf("QueryGroup() unexpected error: %v", err)
	}
	envelope := decodeGroupSnapshotEnvelope(t, payload)
	if envelope.Group.SelectedName != "member-a" {
		t.Fatalf("selected member changed after failed set")
	}
}

func TestServiceSelectConfirmsPostPatchAndClosesScopedConnections(t *testing.T) {
	ctx := validQueryContext(nil)
	group := newFakeGroup(
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-a",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-b",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
	)
	registry := &fakeRegistry{
		groups: map[string]RuntimeGroup{
			"group-a": group,
		},
	}
	service := NewService(registry)

	payload, err := service.Select(ctx, "group-a", "member-b")
	if err != nil {
		t.Fatalf("Select() unexpected error: %v", err)
	}

	envelope := decodeSelectionEnvelope(t, payload)
	if envelope.PreviousName != "member-a" {
		t.Fatalf("previous member mismatch")
	}
	if envelope.Group.SelectedName != "member-b" {
		t.Fatalf("selected member mismatch")
	}
	if !reflect.DeepEqual(registry.closedGroups, []string{"group-a"}) {
		t.Fatalf("closed groups mismatch")
	}
}

func TestServiceSelectKeepsConfirmedSelectionWhenCleanupFails(t *testing.T) {
	ctx := validQueryContext(nil)
	group := newFakeGroup(
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-a",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-b",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
	)
	registry := &fakeRegistry{
		groups: map[string]RuntimeGroup{
			"group-a": group,
		},
		closeErr: errors.New("synthetic cleanup failure"),
	}
	service := NewService(registry)

	payload, err := service.Select(ctx, "group-a", "member-b")
	if err != nil {
		t.Fatalf("Select() should keep confirmed selection even if cleanup fails: %v", err)
	}

	envelope := decodeSelectionEnvelope(t, payload)
	if envelope.Group.SelectedName != "member-b" {
		t.Fatalf("selected member mismatch")
	}
	if envelope.PreviousName != "member-a" {
		t.Fatalf("previous member mismatch")
	}
	if !reflect.DeepEqual(registry.closedGroups, []string{"group-a"}) {
		t.Fatalf("cleanup should still be attempted once after success")
	}
}

func TestServiceSelectRejectsPostPatchMismatch(t *testing.T) {
	ctx := validQueryContext(nil)
	group := newFakeGroup(
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-a",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
		RuntimeGroupSnapshot{
			Name:    "group-a",
			Type:    "Selector",
			Current: "member-a",
			Members: []RuntimeNode{
				{Name: "member-a", Type: "Direct"},
				{Name: "member-b", Type: "Reject"},
			},
		},
	)
	registry := &fakeRegistry{
		groups: map[string]RuntimeGroup{
			"group-a": group,
		},
	}
	service := NewService(registry)

	_, err := service.Select(ctx, "group-a", "member-b")
	assertErrorCode(t, err, ErrCodeProxySelectionFailed)
	if len(registry.closedGroups) != 0 {
		t.Fatalf("CloseConnectionsForGroup() should not be called")
	}
}

func TestAdapterTypeNameUsesPinnedBridgeNames(t *testing.T) {
	cases := []struct {
		adapterType C.AdapterType
		want        string
	}{
		{C.Direct, "Direct"},
		{C.Reject, "Reject"},
		{C.RejectDrop, "RejectDrop"},
		{C.Compatible, "Compatible"},
		{C.Pass, "Pass"},
		{C.PassRule, "PassRule"},
		{C.Rematch, "Rematch"},
		{C.Dns, "Dns"},
		{C.Relay, "Relay"},
		{C.Selector, "Selector"},
		{C.Fallback, "Fallback"},
		{C.URLTest, "URLTest"},
		{C.LoadBalance, "LoadBalance"},
		{C.Shadowsocks, "Shadowsocks"},
		{C.ShadowsocksR, "ShadowsocksR"},
		{C.Snell, "Snell"},
		{C.Socks5, "Socks5"},
		{C.Http, "Http"},
		{C.Vmess, "Vmess"},
		{C.Vless, "Vless"},
		{C.Trojan, "Trojan"},
		{C.Hysteria, "Hysteria"},
		{C.Hysteria2, "Hysteria2"},
		{C.WireGuard, "WireGuard"},
		{C.Tuic, "Tuic"},
		{C.Ssh, "Ssh"},
		{C.Mieru, "Mieru"},
		{C.AnyTLS, "AnyTLS"},
		{C.Sudoku, "Sudoku"},
		{C.Masque, "Masque"},
		{C.TrustTunnel, "TrustTunnel"},
		{C.ShadowQuic, "ShadowQuic"},
		{C.OpenVPN, "OpenVPN"},
		{C.Tailscale, "Tailscale"},
		{C.GostRelay, "GostRelay"},
	}

	for _, tc := range cases {
		got, err := adapterTypeName(tc.adapterType)
		if err != nil {
			t.Fatalf("adapterTypeName() unexpected error")
		}
		if got != tc.want {
			t.Fatalf("adapter type mismatch")
		}
	}

	_, err := adapterTypeName(C.AdapterType(999))
	assertErrorCode(t, err, ErrCodeProxyBridgeInvalid)
}

type fakeRegistry struct {
	activeGroups  []RuntimeGroup
	groups        map[string]RuntimeGroup
	activeErr     error
	groupErrs     map[string]error
	closeErr      error
	closedGroups  []string
	panicOnAccess bool
	monitor       *operationMonitor
	mu            sync.Mutex
	activeCalls   int32
	groupCalls    int32
	closeCalls    int32
}

func (r *fakeRegistry) ActiveGroups() ([]RuntimeGroup, error) {
	r.recordCall(&r.activeCalls)
	done := r.enterOperation("ActiveGroups")
	defer done()

	if r.activeErr != nil {
		return nil, r.activeErr
	}
	return append([]RuntimeGroup(nil), r.activeGroups...), nil
}

func (r *fakeRegistry) Group(name string) (RuntimeGroup, error) {
	r.recordCall(&r.groupCalls)
	done := r.enterOperation("Group")
	defer done()

	if err := r.groupErrs[name]; err != nil {
		return nil, err
	}
	group := r.groups[name]
	if group == nil {
		return nil, newModelError(ErrCodeProxyGroupNotFound)
	}
	return group, nil
}

func (r *fakeRegistry) CloseConnectionsForGroup(name string) {
	r.recordCall(&r.closeCalls)
	done := r.enterOperation("CloseConnectionsForGroup")
	defer done()

	r.mu.Lock()
	r.closedGroups = append(r.closedGroups, name)
	r.mu.Unlock()
	_ = r.closeErr
}

func (r *fakeRegistry) totalCalls() int32 {
	return atomic.LoadInt32(&r.activeCalls) + atomic.LoadInt32(&r.groupCalls) + atomic.LoadInt32(&r.closeCalls)
}

func (r *fakeRegistry) recordCall(counter *int32) {
	if r.panicOnAccess {
		panic("unexpected registry access")
	}
	atomic.AddInt32(counter, 1)
}

func (r *fakeRegistry) enterOperation(label string) func() {
	if r.monitor == nil {
		return func() {}
	}
	return r.monitor.enter(label)
}

type fakeGroup struct {
	snapshots []RuntimeGroupSnapshot
	setErr    error
	monitor   *operationMonitor

	mu            sync.Mutex
	snapshotCalls int
	setCalls      []string
}

type referenceOnlyGroup struct {
	reference     RuntimeGroupReference
	snapshotCalls int
}

func (g *referenceOnlyGroup) Reference() (RuntimeGroupReference, error) {
	return g.reference, nil
}

func (g *referenceOnlyGroup) Snapshot() (RuntimeGroupSnapshot, error) {
	g.snapshotCalls++
	return RuntimeGroupSnapshot{}, newModelError(ErrCodeProxyBridgeInvalid)
}

func (g *referenceOnlyGroup) Set(string) error {
	return nil
}

func newFakeGroup(snapshots ...RuntimeGroupSnapshot) *fakeGroup {
	return &fakeGroup{snapshots: snapshots}
}

func (g *fakeGroup) Snapshot() (RuntimeGroupSnapshot, error) {
	done := g.enterOperation("Snapshot")
	defer done()

	g.mu.Lock()
	defer g.mu.Unlock()

	if len(g.snapshots) == 0 {
		return RuntimeGroupSnapshot{}, nil
	}
	index := g.snapshotCalls
	if index >= len(g.snapshots) {
		index = len(g.snapshots) - 1
	}
	g.snapshotCalls++
	return cloneRuntimeGroupSnapshot(g.snapshots[index]), nil
}

func (g *fakeGroup) Set(name string) error {
	done := g.enterOperation("Set")
	defer done()

	g.mu.Lock()
	defer g.mu.Unlock()

	g.setCalls = append(g.setCalls, name)
	if g.setErr != nil {
		return g.setErr
	}
	return nil
}

func (g *fakeGroup) enterOperation(label string) func() {
	if g.monitor == nil {
		return func() {}
	}
	return g.monitor.enter(label)
}

func decodeGroupListEnvelope(t *testing.T, payload []byte) GroupListEnvelope {
	t.Helper()
	var envelope GroupListEnvelope
	if err := json.Unmarshal(payload, &envelope); err != nil {
		t.Fatalf("json.Unmarshal() failed: %v", err)
	}
	return envelope
}

func decodeGroupSnapshotEnvelope(t *testing.T, payload []byte) GroupSnapshotEnvelope {
	t.Helper()
	var envelope GroupSnapshotEnvelope
	if err := json.Unmarshal(payload, &envelope); err != nil {
		t.Fatalf("json.Unmarshal() failed: %v", err)
	}
	return envelope
}

func decodeSelectionEnvelope(t *testing.T, payload []byte) SelectionAppliedEnvelope {
	t.Helper()
	var envelope SelectionAppliedEnvelope
	if err := json.Unmarshal(payload, &envelope); err != nil {
		t.Fatalf("json.Unmarshal() failed: %v", err)
	}
	return envelope
}

func assertGroupRefs(t *testing.T, got, want []GroupRef) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("group refs mismatch")
	}
}

type operationMonitor struct {
	entered chan string
	release chan struct{}
	current int32
	max     int32
}

func newOperationMonitor() *operationMonitor {
	return &operationMonitor{
		entered: make(chan string, 16),
		release: make(chan struct{}),
	}
}

func (m *operationMonitor) enter(label string) func() {
	current := atomic.AddInt32(&m.current, 1)
	for {
		max := atomic.LoadInt32(&m.max)
		if current <= max || atomic.CompareAndSwapInt32(&m.max, max, current) {
			break
		}
	}
	m.entered <- label
	<-m.release
	return func() {
		atomic.AddInt32(&m.current, -1)
	}
}

func (m *operationMonitor) releaseAll() {
	close(m.release)
}

func (m *operationMonitor) maxConcurrent() int32 {
	return atomic.LoadInt32(&m.max)
}

func waitForOperation(t *testing.T, entered <-chan string) string {
	t.Helper()
	select {
	case label := <-entered:
		return label
	case <-time.After(1 * time.Second):
		t.Fatal("timed out waiting for operation entry")
		return ""
	}
}

func assertNoOperation(t *testing.T, entered <-chan string) {
	t.Helper()
	select {
	case label := <-entered:
		t.Fatalf("unexpected concurrent operation %q while another service call was in flight", label)
	case <-time.After(50 * time.Millisecond):
	}
}

func waitForResult(t *testing.T, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(1 * time.Second):
		t.Fatal("timed out waiting for service call")
		return nil
	}
}
