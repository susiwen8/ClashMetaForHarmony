package runtime

import (
	"errors"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
)

type recordingSink struct {
	mu     sync.Mutex
	events []RuntimeEvent
}

func (s *recordingSink) Publish(event RuntimeEvent) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, event)
}

func (s *recordingSink) Events() []RuntimeEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	cloned := make([]RuntimeEvent, len(s.events))
	copy(cloned, s.events)
	return cloned
}

type recordingLogSink struct {
	mu   sync.Mutex
	logs []RuntimeLog
}

func (s *recordingLogSink) Publish(log RuntimeLog) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.logs = append(s.logs, log)
}

func (s *recordingLogSink) Logs() []RuntimeLog {
	s.mu.Lock()
	defer s.mu.Unlock()
	cloned := make([]RuntimeLog, len(s.logs))
	copy(cloned, s.logs)
	return cloned
}

type fakeListener struct {
	mu      sync.Mutex
	address string
	closed  bool
	closeErr error
}

func (l *fakeListener) Address() string {
	return l.address
}

func (l *fakeListener) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closed = true
	return l.closeErr
}

func (l *fakeListener) Closed() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.closed
}

type fakeFactory struct {
	mu           sync.Mutex
	returnedAddr string
	failFor      string
	listeners    []*fakeListener
	nextPort     int
}

func newFakeFactory(startPort int) *fakeFactory {
	return &fakeFactory{nextPort: startPort}
}

func (f *fakeFactory) newListener(requested string) (ListenerHandle, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if requested == f.failFor {
		return nil, errors.New("bind denied")
	}
	actual := f.returnedAddr
	if actual == "" {
		actual = "127.0.0.1:" + strconv.Itoa(f.nextPort)
		f.nextPort += 1
	}
	listener := &fakeListener{address: actual}
	f.listeners = append(f.listeners, listener)
	return listener, nil
}

func (f *fakeFactory) LastListener() *fakeListener {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.listeners) == 0 {
		return nil
	}
	return f.listeners[len(f.listeners)-1]
}

func newTestProxy(t *testing.T, sink EventSink, mutate func(*LocalProxyDeps)) *LocalProxy {
	t.Helper()

	httpFactory := newFakeFactory(41001)
	socksFactory := newFakeFactory(42001)
	deps := LocalProxyDeps{
		Prepare: func(string) error {
			return nil
		},
		HTTPFactory:       httpFactory.newListener,
		SOCKSFactory:      socksFactory.newListener,
		CloseConnections:  func() error { return nil },
		Shutdown:          func() error { return nil },
		Events:            sink,
		Logs:              DiscardLogs{},
		MaxMessageBytes:   256,
		MaxSnapshotBytes:  512,
		AllowedLoopbackIP: "127.0.0.1",
	}
	if mutate != nil {
		mutate(&deps)
	}
	return NewLocalProxyWithDeps(deps)
}

func assertLoopbackAddress(t *testing.T, raw string) {
	t.Helper()

	host, port, err := net.SplitHostPort(raw)
	if err != nil {
		t.Fatalf("SplitHostPort(%q): %v", raw, err)
	}
	if host != "127.0.0.1" {
		t.Fatalf("host = %q want 127.0.0.1", host)
	}
	if port == "0" || port == "" {
		t.Fatalf("port = %q want non-zero", port)
	}
}

func TestLocalProxyAllowsOnlyOneRuntimeAtATime(t *testing.T) {
	sink := &recordingSink{}

	prepareEntered := make(chan struct{})
	releasePrepare := make(chan struct{})
	proxy := newTestProxy(t, sink, func(deps *LocalProxyDeps) {
		deps.Prepare = func(string) error {
			close(prepareEntered)
			<-releasePrepare
			return nil
		}
	})

	firstDone := make(chan error, 1)
	go func() {
		_, err := proxy.Start(StartOptions{
			ConfigPath:         "phase2-match-direct.yaml",
			HTTPListenAddress:  "127.0.0.1:0",
			SOCKSListenAddress: "127.0.0.1:0",
		})
		firstDone <- err
	}()

	<-prepareEntered

	_, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:0",
	})
	if !errors.Is(err, ErrRuntimeBusy) {
		t.Fatalf("second Start error = %v want %v", err, ErrRuntimeBusy)
	}

	close(releasePrepare)
	if err := <-firstDone; err != nil {
		t.Fatalf("first Start error: %v", err)
	}

	if _, err := proxy.Stop(); err != nil {
		t.Fatalf("Stop error: %v", err)
	}
}

func TestLocalProxyBindsLoopbackAndReturnsActualAddresses(t *testing.T) {
	proxy := newTestProxy(t, &recordingSink{}, nil)

	snapshot, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:0",
	})
	if err != nil {
		t.Fatalf("Start error: %v", err)
	}
	t.Cleanup(func() {
		_, _ = proxy.Stop()
	})

	if snapshot.State != RuntimeRunning {
		t.Fatalf("snapshot.State = %v want %v", snapshot.State, RuntimeRunning)
	}
	if snapshot.ActiveConfigPath != "phase2-match-direct.yaml" {
		t.Fatalf("snapshot.ActiveConfigPath = %q", snapshot.ActiveConfigPath)
	}
	assertLoopbackAddress(t, snapshot.HTTPAddress)
	assertLoopbackAddress(t, snapshot.SOCKSAddress)
	if snapshot.HTTPAddress == "127.0.0.1:0" || snapshot.SOCKSAddress == "127.0.0.1:0" {
		t.Fatalf("actual listener addresses must not keep the ephemeral request: %#v", snapshot)
	}
}

func TestLocalProxyPartialBindFailureClosesAllListeners(t *testing.T) {
	httpFactory := newFakeFactory(41001)
	socksFactory := newFakeFactory(42001)
	socksFactory.failFor = "127.0.0.1:43001"
	proxy := newTestProxy(t, &recordingSink{}, func(deps *LocalProxyDeps) {
		deps.HTTPFactory = httpFactory.newListener
		deps.SOCKSFactory = socksFactory.newListener
	})

	_, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:43001",
	})
	if err == nil {
		t.Fatal("Start unexpectedly succeeded")
	}
	httpListener := httpFactory.LastListener()
	if httpListener == nil {
		t.Fatal("HTTP listener never bound before SOCKS failure")
	}

	snapshot := proxy.Snapshot()
	if snapshot.State != RuntimeError {
		t.Fatalf("snapshot.State = %v want %v", snapshot.State, RuntimeError)
	}
	if snapshot.HTTPAddress != "" || snapshot.SOCKSAddress != "" {
		t.Fatalf("snapshot retained closed listeners: %#v", snapshot)
	}
	if !strings.Contains(snapshot.LastError, "127.0.0.1:43001") {
		t.Fatalf("snapshot.LastError = %q want bind diagnostic for %q", snapshot.LastError, "127.0.0.1:43001")
	}
	if !httpListener.Closed() {
		t.Fatal("HTTP listener was not closed after partial failure")
	}
}

func TestLocalProxyStopIsIdempotent(t *testing.T) {
	proxy := newTestProxy(t, &recordingSink{}, nil)

	if _, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:0",
	}); err != nil {
		t.Fatalf("Start error: %v", err)
	}

	first, err := proxy.Stop()
	if err != nil {
		t.Fatalf("first Stop error: %v", err)
	}
	second, err := proxy.Stop()
	if err != nil {
		t.Fatalf("second Stop error: %v", err)
	}
	if first.State != RuntimeStopped || second.State != RuntimeStopped {
		t.Fatalf("stop snapshots = %#v %#v", first, second)
	}
}

func TestLocalProxyEmitsOrderedStructuredEvents(t *testing.T) {
	sink := &recordingSink{}
	proxy := newTestProxy(t, sink, nil)

	if _, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:0",
	}); err != nil {
		t.Fatalf("Start error: %v", err)
	}
	if _, err := proxy.Stop(); err != nil {
		t.Fatalf("Stop error: %v", err)
	}

	events := sink.Events()
	if len(events) != 4 {
		t.Fatalf("len(events) = %d want 4 (%#v)", len(events), events)
	}
	if events[0].Kind != "runtime.starting" || events[0].State != RuntimeStarting {
		t.Fatalf("events[0] = %#v", events[0])
	}
	if events[1].Kind != "runtime.running" || events[1].State != RuntimeRunning {
		t.Fatalf("events[1] = %#v", events[1])
	}
	if events[1].HTTPAddress == "" || events[1].SOCKSAddress == "" {
		t.Fatalf("running event must include bound addresses: %#v", events[1])
	}
	if events[2].Kind != "runtime.stopping" || events[2].State != RuntimeStopping {
		t.Fatalf("events[2] = %#v", events[2])
	}
	if events[3].Kind != "runtime.stopped" || events[3].State != RuntimeStopped {
		t.Fatalf("events[3] = %#v", events[3])
	}
}

func TestLocalProxyFailedRestartRetainsErrorStateAndDiagnosticCause(t *testing.T) {
	sink := &recordingSink{}
	socksFactory := newFakeFactory(42001)
	socksFactory.failFor = "127.0.0.1:43002"
	proxy := newTestProxy(t, sink, func(deps *LocalProxyDeps) {
		deps.SOCKSFactory = socksFactory.newListener
	})

	if _, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:0",
	}); err != nil {
		t.Fatalf("initial Start error: %v", err)
	}
	if _, err := proxy.Stop(); err != nil {
		t.Fatalf("Stop error: %v", err)
	}

	_, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:43002",
	})
	if err == nil {
		t.Fatal("restart unexpectedly succeeded")
	}

	snapshot := proxy.Snapshot()
	if snapshot.State != RuntimeError {
		t.Fatalf("snapshot.State = %v want %v", snapshot.State, RuntimeError)
	}
	if !strings.Contains(snapshot.LastError, "127.0.0.1:43002") {
		t.Fatalf("snapshot.LastError = %q want %q", snapshot.LastError, "127.0.0.1:43002")
	}

	events := sink.Events()
	if len(events) < 6 {
		t.Fatalf("len(events) = %d want at least 6", len(events))
	}
	last := events[len(events)-1]
	if last.Kind != "runtime.error" || last.State != RuntimeError {
		t.Fatalf("last event = %#v want runtime.error/%v", last, RuntimeError)
	}
	if !strings.Contains(last.Message, "127.0.0.1:43002") {
		t.Fatalf("last.Message = %q want bind diagnostic", last.Message)
	}
}

func TestLocalProxyStopPreservesErrorSnapshotAndDiagnostic(t *testing.T) {
	sink := &recordingSink{}
	socksFactory := newFakeFactory(42001)
	socksFactory.failFor = "127.0.0.1:43003"
	proxy := newTestProxy(t, sink, func(deps *LocalProxyDeps) {
		deps.SOCKSFactory = socksFactory.newListener
	})

	_, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:43003",
	})
	if err == nil {
		t.Fatal("Start unexpectedly succeeded")
	}

	beforeStop := proxy.Snapshot()
	if beforeStop.State != RuntimeError {
		t.Fatalf("beforeStop.State = %v want %v", beforeStop.State, RuntimeError)
	}

	afterStop, err := proxy.Stop()
	if err != nil {
		t.Fatalf("Stop error: %v", err)
	}
	if afterStop.State != RuntimeError {
		t.Fatalf("afterStop.State = %v want %v", afterStop.State, RuntimeError)
	}
	if afterStop.LastError != beforeStop.LastError {
		t.Fatalf("afterStop.LastError = %q want %q", afterStop.LastError, beforeStop.LastError)
	}

	events := sink.Events()
	last := events[len(events)-1]
	if last.State != RuntimeError || last.Kind != "runtime.error" {
		t.Fatalf("last event = %#v want runtime.error/%v", last, RuntimeError)
	}
}

func TestLocalProxyProducesBoundedRedactedStructuredLogs(t *testing.T) {
	logs := &recordingLogSink{}
	proxy := newTestProxy(t, &recordingSink{}, func(deps *LocalProxyDeps) {
		deps.Logs = logs
		deps.MaxLogContextFields = 2
		deps.MaxLogFieldBytes = 48
		deps.Prepare = func(string) error {
			return errors.New("fetch https://alice:secret@example.invalid/config.yaml?token=abc123&password=hunter2 failed")
		}
	})

	_, err := proxy.Start(StartOptions{
		ConfigPath:         "/tmp/profiles/password=letmein-token=abcdef.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:0",
	})
	if err == nil {
		t.Fatal("Start unexpectedly succeeded")
	}

	entries := logs.Logs()
	if len(entries) < 2 {
		t.Fatalf("len(entries) = %d want at least 2", len(entries))
	}
	last := entries[len(entries)-1]
	if last.Level != LogLevelError {
		t.Fatalf("last.Level = %v want %v", last.Level, LogLevelError)
	}
	if last.Category != "runtime.start.failed" {
		t.Fatalf("last.Category = %q", last.Category)
	}
	if last.Context["configPath"] == "/tmp/profiles/password=letmein-token=abcdef.yaml" {
		t.Fatalf("configPath was not redacted: %#v", last)
	}
	if strings.Contains(last.Message, "secret") || strings.Contains(last.Message, "abc123") || strings.Contains(last.Message, "hunter2") {
		t.Fatalf("failure log leaked secrets: %#v", last)
	}
}

func TestLocalProxyPartialBindFailureReportsCleanupFailureAndConsistentSnapshot(t *testing.T) {
	httpFactory := newFakeFactory(41001)
	socksFactory := newFakeFactory(42001)
	socksFactory.failFor = "127.0.0.1:43011"
	proxy := newTestProxy(t, &recordingSink{}, func(deps *LocalProxyDeps) {
		deps.HTTPFactory = func(addr string) (ListenerHandle, error) {
			listener, err := httpFactory.newListener(addr)
			if err != nil {
				return nil, err
			}
			listener.(*fakeListener).closeErr = errors.New("password=hunter2 cleanup denied")
			return listener, nil
		}
		deps.SOCKSFactory = socksFactory.newListener
	})

	snapshot, err := proxy.Start(StartOptions{
		ConfigPath:         "/tmp/profiles/password=letmein.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:43011",
	})
	if err == nil {
		t.Fatal("Start unexpectedly succeeded")
	}
	if snapshot.LastError != err.Error() {
		t.Fatalf("snapshot.LastError = %q want err %q", snapshot.LastError, err.Error())
	}
	if !strings.Contains(snapshot.LastError, "cleanup HTTP listener failed") {
		t.Fatalf("snapshot.LastError = %q", snapshot.LastError)
	}
	if strings.Contains(snapshot.LastError, "hunter2") {
		t.Fatalf("snapshot.LastError should redact sensitive text: %q", snapshot.LastError)
	}
}

func TestLocalProxyStopFailureMatchesSnapshotLastError(t *testing.T) {
	proxy := newTestProxy(t, &recordingSink{}, func(deps *LocalProxyDeps) {
		deps.Shutdown = func() error {
			return errors.New("stop failed for https://alice:secret@example.invalid?token=abc123")
		}
	})
	if _, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:0",
	}); err != nil {
		t.Fatalf("Start error: %v", err)
	}

	snapshot, err := proxy.Stop()
	if err == nil {
		t.Fatal("Stop unexpectedly succeeded")
	}
	if snapshot.LastError != err.Error() {
		t.Fatalf("snapshot.LastError = %q want err %q", snapshot.LastError, err.Error())
	}
	if strings.Contains(snapshot.LastError, "secret") || strings.Contains(snapshot.LastError, "abc123") {
		t.Fatalf("snapshot.LastError should redact sensitive text: %q", snapshot.LastError)
	}
}

func TestLocalProxyRealConstructorsBindLoopbackAndReleasePorts(t *testing.T) {
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error {
			return nil
		},
		CloseConnections: func() error { return nil },
		Shutdown:         func() error { return nil },
	})

	snapshot, err := proxy.Start(StartOptions{
		ConfigPath:         "phase2-match-direct.yaml",
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:0",
	})
	if err != nil {
		t.Fatalf("Start error: %v", err)
	}

	assertLoopbackAddress(t, snapshot.HTTPAddress)
	assertLoopbackAddress(t, snapshot.SOCKSAddress)

	stopped, err := proxy.Stop()
	if err != nil {
		t.Fatalf("Stop error: %v", err)
	}
	if stopped.State != RuntimeStopped {
		t.Fatalf("stopped.State = %v want %v", stopped.State, RuntimeStopped)
	}

	httpRebind, err := net.Listen("tcp", snapshot.HTTPAddress)
	if err != nil {
		t.Fatalf("HTTP address not released after Stop: %v", err)
	}
	_ = httpRebind.Close()

	socksRebind, err := net.Listen("tcp", snapshot.SOCKSAddress)
	if err != nil {
		t.Fatalf("SOCKS address not released after Stop: %v", err)
	}
	_ = socksRebind.Close()
}
