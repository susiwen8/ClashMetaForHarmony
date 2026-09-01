package main

import (
	"errors"
	"strings"
	"testing"
	"time"

	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/dialer"
	constantpkg "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
)

type testListener struct {
	address string
}

func (l *testListener) Address() string { return l.address }
func (l *testListener) Close() error    { return nil }

type testTunListener struct {
	address string
}

func (l *testTunListener) Address() string { return l.address }
func (l *testTunListener) Close() error    { return nil }

func withTestLocalProxy(t *testing.T, deps runtimepkg.LocalProxyDeps) {
	t.Helper()
	previousProxy := localProxy
	previousHook := dialer.DefaultSocketHook
	localProxy = runtimepkg.NewLocalProxyWithDeps(deps)
	t.Cleanup(func() {
		localProxy = previousProxy
		dialer.DefaultSocketHook = previousHook
	})
}

func TestBuildTunStartOptionsSupportsCleanProcessStart(t *testing.T) {
	options := buildTunStartOptions("configs/phase4.yaml", 7890, "session-1", 42, 23, true)
	if options.Base.ConfigPath != "configs/phase4.yaml" {
		t.Fatalf("config path = %q", options.Base.ConfigPath)
	}
	if options.Base.HTTPListenAddress != "127.0.0.1:7890" {
		t.Fatalf("HTTP address = %q", options.Base.HTTPListenAddress)
	}
	if options.Base.SOCKSListenAddress != "127.0.0.1:7891" {
		t.Fatalf("SOCKS address = %q", options.Base.SOCKSListenAddress)
	}
	if options.PlatformAPILevel != 23 || !options.ProcessProtected {
		t.Fatalf("platform flags = %#v", options)
	}
}

func TestBuildTunStartOptionsFallsBackToEphemeralSOCKSPortAtUint16Maximum(t *testing.T) {
	options := buildTunStartOptions("configs/phase4.yaml", 65535, "session-1", 42, 23, true)
	if options.Base.HTTPListenAddress != "127.0.0.1:65535" {
		t.Fatalf("HTTP address = %q", options.Base.HTTPListenAddress)
	}
	if options.Base.SOCKSListenAddress != "127.0.0.1:0" {
		t.Fatalf("SOCKS address = %q", options.Base.SOCKSListenAddress)
	}
}

func TestTunStartUsesApiModeToControlPerSocketHook(t *testing.T) {
	withTestLocalProxy(t, runtimepkg.LocalProxyDeps{
		Prepare:         func(string) error { return nil },
		SocketProtector: runtimepkg.SocketProtectorFunc(func(int, time.Duration) error { return nil }),
		HTTPFactory:     func(addr string) (runtimepkg.ListenerHandle, error) { return &testListener{address: addr}, nil },
		SOCKSFactory: func(addr string) (runtimepkg.ListenerHandle, error) {
			return &testListener{address: "127.0.0.1:19090"}, nil
		},
		TunFactory: func(options LC.Tun, tunnel constantpkg.Tunnel, additions ...adapterinbound.Addition) (runtimepkg.TunListenerHandle, error) {
			return &testTunListener{address: "CMFA-TUN"}, nil
		},
	})

	api23 := buildTunStartOptions("configs/phase4.yaml", 7890, "session-1", 42, 23, true)
	if _, err := localProxy.StartTun(api23); err != nil {
		t.Fatalf("API23 StartTun error: %v", err)
	}
	if dialer.DefaultSocketHook != nil {
		t.Fatal("API22+ process-protected start should not install per-socket hook")
	}
	if _, err := localProxy.Stop(); err != nil {
		t.Fatalf("API23 Stop error: %v", err)
	}

	api21 := buildTunStartOptions("configs/phase4.yaml", 7890, "session-2", 42, 21, false)
	if _, err := localProxy.StartTun(api21); err != nil {
		t.Fatalf("API21 StartTun error: %v", err)
	}
	if dialer.DefaultSocketHook == nil {
		t.Fatal("API20/21 start should install per-socket hook")
	}
}

func TestBackendHostEventSinkPublishesTraceFields(t *testing.T) {
	var captured runtimepkg.RuntimeEvent
	previous := hostRuntimeEventBridge
	hostRuntimeEventBridge = func(event runtimepkg.RuntimeEvent) error {
		captured = event
		return nil
	}
	t.Cleanup(func() { hostRuntimeEventBridge = previous })

	backendHostEventSink{}.Publish(runtimepkg.RuntimeEvent{
		Kind:      "tun.ingress",
		State:     runtimepkg.RuntimeRunning,
		Message:   "tcp",
		TraceID:   strings.Repeat("a", 64),
		SessionID: "session-1",
		Ingress:   "tun",
		Protocol:  "tcp",
	})

	if captured.SessionID != "session-1" {
		t.Fatalf("sessionID = %q", captured.SessionID)
	}
	if captured.Ingress != "tun" {
		t.Fatalf("ingress = %q", captured.Ingress)
	}
	if captured.Protocol != "tcp" {
		t.Fatalf("protocol = %q", captured.Protocol)
	}
	if len(captured.TraceID) != 64 {
		t.Fatalf("traceID = %q", captured.TraceID)
	}
}

func TestBackendHostEventSinkPublishesProtectFailureWithoutTraceID(t *testing.T) {
	var captured runtimepkg.RuntimeEvent
	previous := hostRuntimeEventBridge
	hostRuntimeEventBridge = func(event runtimepkg.RuntimeEvent) error {
		captured = event
		return nil
	}
	t.Cleanup(func() { hostRuntimeEventBridge = previous })

	backendHostEventSink{}.Publish(runtimepkg.RuntimeEvent{
		Kind:      "runtime.socket_protect_failed",
		State:     runtimepkg.RuntimeRunning,
		Code:      "VPN_SOCKET_PROTECT_FAILED",
		SessionID: "session-1",
		Protocol:  "udp",
	})

	if captured.Code != "VPN_SOCKET_PROTECT_FAILED" {
		t.Fatalf("code = %q", captured.Code)
	}
	if captured.Kind != "runtime.socket_protect_failed" {
		t.Fatalf("kind = %q", captured.Kind)
	}
	if captured.TraceID != "" {
		t.Fatalf("traceID = %q want empty", captured.TraceID)
	}
}

func TestBackendHostEventSinkFallsBackToRuntimeLogForTunDiagnostic(t *testing.T) {
	previousBridge := hostRuntimeEventBridge
	previousLogs := runtimeLogs
	hostRuntimeEventBridge = func(runtimepkg.RuntimeEvent) error {
		return errors.New("host runtime event bridge unavailable")
	}
	runtimeLogs = runtimepkg.NewLogBuffer(4)
	t.Cleanup(func() {
		hostRuntimeEventBridge = previousBridge
		runtimeLogs = previousLogs
	})

	backendHostEventSink{}.Publish(runtimepkg.RuntimeEvent{
		Kind:      "tun.diagnostic",
		State:     runtimepkg.RuntimeRunning,
		Message:   "tun.packet.read-loop-enter",
		TraceID:   "fixed-trace",
		SessionID: "session-1",
		Ingress:   "diagnostic",
		Protocol:  "tun.packet.read-loop-enter",
	})

	log, ok := runtimeLogs.Take()
	if !ok {
		t.Fatal("missing fixed fallback runtime log")
	}
	if log.Category != "runtime.tun.packet-diagnostic" || log.Message != "tun.packet.read-loop-enter" {
		t.Fatalf("fallback log = %#v want fixed packet diagnostic", log)
	}
}

func TestCloseStaleTunConnectionsExportUsesLocalProxyWithoutStoppingTun(t *testing.T) {
	var order []string
	withTestLocalProxy(t, runtimepkg.LocalProxyDeps{
		Prepare:     func(string) error { return nil },
		HTTPFactory: func(addr string) (runtimepkg.ListenerHandle, error) { return &testListener{address: addr}, nil },
		SOCKSFactory: func(addr string) (runtimepkg.ListenerHandle, error) {
			return &testListener{address: "127.0.0.1:19090"}, nil
		},
		TunFactory: func(options LC.Tun, tunnel constantpkg.Tunnel, additions ...adapterinbound.Addition) (runtimepkg.TunListenerHandle, error) {
			return &testTunListener{address: "CMFA-TUN"}, nil
		},
		CloseConnections: func() error {
			order = append(order, "connections.close")
			return nil
		},
		Shutdown: func() error {
			order = append(order, "executor.shutdown")
			return nil
		},
	})

	if _, err := localProxy.StartTun(buildTunStartOptions("configs/phase4.yaml", 7890, "session-1", 42, 23, true)); err != nil {
		t.Fatalf("StartTun error: %v", err)
	}

	status := callCloseStaleTunConnectionsForTest("session-1")
	if status != closeStaleTunStatusOK() {
		t.Fatalf("close stale status = %d", status)
	}
	if len(order) != 1 || order[0] != "connections.close" {
		t.Fatalf("order = %#v want only connections.close", order)
	}
	if localProxy.TunSnapshot().State != runtimepkg.TunStateReady {
		t.Fatalf("tun state = %v want ready", localProxy.TunSnapshot().State)
	}
}

func TestCloseStaleTunConnectionsExportRejectsStaleSessionID(t *testing.T) {
	withTestLocalProxy(t, runtimepkg.LocalProxyDeps{
		Prepare:     func(string) error { return nil },
		HTTPFactory: func(addr string) (runtimepkg.ListenerHandle, error) { return &testListener{address: addr}, nil },
		SOCKSFactory: func(addr string) (runtimepkg.ListenerHandle, error) {
			return &testListener{address: "127.0.0.1:19090"}, nil
		},
		TunFactory: func(options LC.Tun, tunnel constantpkg.Tunnel, additions ...adapterinbound.Addition) (runtimepkg.TunListenerHandle, error) {
			return &testTunListener{address: "CMFA-TUN"}, nil
		},
	})

	if _, err := localProxy.StartTun(buildTunStartOptions("configs/phase4.yaml", 7890, "session-1", 42, 23, true)); err != nil {
		t.Fatalf("StartTun error: %v", err)
	}

	status := callCloseStaleTunConnectionsForTest("session-2")
	if status != closeStaleTunStatusBackendError() {
		t.Fatalf("close stale status = %d want backend error", status)
	}
}

func TestCloseStaleTunConnectionsExportMapsEmptySessionToInvalidArgument(t *testing.T) {
	withTestLocalProxy(t, runtimepkg.LocalProxyDeps{})

	status := callCloseStaleTunConnectionsForTest("")
	if status != closeStaleTunStatusInvalidArgument() {
		t.Fatalf("close stale status = %d want invalid argument", status)
	}
}

func TestCloseStaleTunConnectionsExportMapsBusyWhenCleanupAlreadyInFlight(t *testing.T) {
	blocked := make(chan struct{})
	release := make(chan struct{})
	withTestLocalProxy(t, runtimepkg.LocalProxyDeps{
		Prepare:     func(string) error { return nil },
		HTTPFactory: func(addr string) (runtimepkg.ListenerHandle, error) { return &testListener{address: addr}, nil },
		SOCKSFactory: func(addr string) (runtimepkg.ListenerHandle, error) {
			return &testListener{address: "127.0.0.1:19090"}, nil
		},
		TunFactory: func(options LC.Tun, tunnel constantpkg.Tunnel, additions ...adapterinbound.Addition) (runtimepkg.TunListenerHandle, error) {
			return &testTunListener{address: "CMFA-TUN"}, nil
		},
		CloseConnections: func() error {
			close(blocked)
			<-release
			return nil
		},
	})

	if _, err := localProxy.StartTun(buildTunStartOptions("configs/phase4.yaml", 7890, "session-1", 42, 23, true)); err != nil {
		t.Fatalf("StartTun error: %v", err)
	}

	done := make(chan int, 1)
	go func() {
		done <- callCloseStaleTunConnectionsForTest("session-1")
	}()
	<-blocked

	status := callCloseStaleTunConnectionsForTest("session-1")
	if status != closeStaleTunStatusBusy() {
		t.Fatalf("close stale status = %d want busy", status)
	}

	close(release)
	firstStatus := <-done
	if firstStatus != closeStaleTunStatusOK() {
		t.Fatalf("first close stale status = %d want ok", firstStatus)
	}
}

func TestWriteTunTraceExportsDestinationAndOutboundProofHashes(t *testing.T) {
	exported := encodeTunTraceForTest(runtimepkg.TunTrace{
		SessionID:            "session-1",
		TraceID:              "trace-1",
		Ingress:              "tun",
		Protocol:             "tcp",
		HashedTuple:          "tuple-hash",
		CorrelationHash:      "flow-hash",
		DestinationHash:      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		OutboundTerminalHash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		OutboundChainHash:    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
		OutboundChainLength:  2,
	})

	if exported.DestinationHash != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
		t.Fatalf("destination hash = %q want exported destination hash", exported.DestinationHash)
	}
	if exported.OutboundTerminalHash != "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" {
		t.Fatalf("terminal hash = %q want exported terminal hash", exported.OutboundTerminalHash)
	}
	if exported.OutboundChainHash != "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" {
		t.Fatalf("chain hash = %q want exported chain hash", exported.OutboundChainHash)
	}
	if exported.OutboundChainLength != 2 {
		t.Fatalf("chain length = %d want 2", exported.OutboundChainLength)
	}
}
