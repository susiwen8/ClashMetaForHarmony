package main

import (
	"net"
	"net/netip"
	"testing"
	"time"

	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/dialer"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
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
	if options.Base.SOCKSListenAddress != "127.0.0.1:0" {
		t.Fatalf("SOCKS address = %q", options.Base.SOCKSListenAddress)
	}
	if options.PlatformAPILevel != 23 || !options.ProcessProtected {
		t.Fatalf("platform flags = %#v", options)
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
		TunFactory: func(options LC.Tun, tunnel C.Tunnel, additions ...adapterinbound.Addition) (runtimepkg.TunListenerHandle, error) {
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

	var wrappedTunnel C.Tunnel
	withTestLocalProxy(t, runtimepkg.LocalProxyDeps{
		Prepare:     func(string) error { return nil },
		HTTPFactory: func(addr string) (runtimepkg.ListenerHandle, error) { return &testListener{address: addr}, nil },
		SOCKSFactory: func(addr string) (runtimepkg.ListenerHandle, error) {
			return &testListener{address: "127.0.0.1:19090"}, nil
		},
		Events: backendHostEventSink{},
		TunFactory: func(options LC.Tun, tunnel C.Tunnel, additions ...adapterinbound.Addition) (runtimepkg.TunListenerHandle, error) {
			wrappedTunnel = tunnel
			return &testTunListener{address: "CMFA-TUN"}, nil
		},
	})

	if _, err := localProxy.StartTun(buildTunStartOptions("configs/phase4.yaml", 7890, "session-1", 42, 23, true)); err != nil {
		t.Fatalf("StartTun error: %v", err)
	}
	if wrappedTunnel == nil {
		t.Fatal("wrappedTunnel is nil")
	}

	left, right := net.Pipe()
	go func() {
		_, _ = right.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-1\r\n\r\n"))
		_ = right.Close()
	}()
	wrappedTunnel.HandleTCPConn(left, &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 40000,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "controlled.invalid",
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
