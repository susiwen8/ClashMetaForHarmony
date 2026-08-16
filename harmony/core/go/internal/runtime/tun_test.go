package runtime

import (
	"errors"
	"net"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/dialer"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
)

type fakeNatTable struct{}

func (fakeNatTable) GetOrCreate(string, func() C.PacketSender) (C.PacketSender, bool) { return nil, false }
func (fakeNatTable) Delete(string)                                                     {}
func (fakeNatTable) GetForLocalConn(string, string) *net.UDPConn                       { return nil }
func (fakeNatTable) AddForLocalConn(string, string, *net.UDPConn) bool                 { return false }
func (fakeNatTable) RangeForLocalConn(string, func(string, *net.UDPConn) bool)         {}
func (fakeNatTable) GetOrCreateLockForLocalConn(string, string) (*sync.Cond, bool) {
	return nil, false
}
func (fakeNatTable) DeleteForLocalConn(string, string) {}
func (fakeNatTable) DeleteLockForLocalConn(string, string) {}

type fakeBaseTunnel struct{}

func (fakeBaseTunnel) HandleTCPConn(net.Conn, *C.Metadata)      {}
func (fakeBaseTunnel) HandleUDPPacket(C.UDPPacket, *C.Metadata) {}
func (fakeBaseTunnel) NatTable() C.NatTable                     { return fakeNatTable{} }

type fakeTunListener struct {
	address string
	closed  bool
	closeFn func() error
}

func (l *fakeTunListener) Address() string {
	return l.address
}

func (l *fakeTunListener) Close() error {
	l.closed = true
	if l.closeFn != nil {
		return l.closeFn()
	}
	return nil
}

func TestTunStartUsesPinnedConfigAndListenerFactory(t *testing.T) {
	tunnel := fakeBaseTunnel{}
	var (
		gotConfig    LC.Tun
		gotTunnel    C.Tunnel
		gotAdditions []adapterinbound.Addition
	)

	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:0"}, nil
		},
		TunFactory: func(options LC.Tun, tun C.Tunnel, additions ...adapterinbound.Addition) (TunListenerHandle, error) {
			gotConfig = options
			gotTunnel = tun
			gotAdditions = additions
			return &fakeTunListener{address: "CMFA-TUN(fd=42)"}, nil
		},
		BaseTunnel: tunnel,
	})

	if _, err := proxy.Start(StartOptions{
		ConfigPath:         "phase4.yaml",
		HTTPListenAddress:  "127.0.0.1:7890",
		SOCKSListenAddress: "127.0.0.1:0",
	}); err != nil {
		t.Fatalf("Start error: %v", err)
	}

	snapshot, err := proxy.StartTun(TunStartOptions{SessionID: "session-1", TunFD: 42})
	if err != nil {
		t.Fatalf("StartTun error: %v", err)
	}

	if snapshot.State != TunStateReady {
		t.Fatalf("tun state = %v want %v", snapshot.State, TunStateReady)
	}
	if snapshot.SessionID != "session-1" {
		t.Fatalf("tun session = %q want session-1", snapshot.SessionID)
	}
	if gotTunnel == nil {
		t.Fatal("tun factory received nil tunnel")
	}
	if gotTunnel == tunnel {
		t.Fatal("tun factory should receive the traced TUN tunnel wrapper, not the raw local tunnel")
	}
	if gotConfig.FileDescriptor != 42 {
		t.Fatalf("file descriptor = %d want 42", gotConfig.FileDescriptor)
	}
	if gotConfig.Stack != C.TunGvisor {
		t.Fatalf("stack = %v want %v", gotConfig.Stack, C.TunGvisor)
	}
	if gotConfig.MTU != 1500 {
		t.Fatalf("mtu = %d want 1500", gotConfig.MTU)
	}
	if gotConfig.AutoRoute {
		t.Fatal("AutoRoute should be false")
	}
	if gotConfig.AutoDetectInterface {
		t.Fatal("AutoDetectInterface should be false")
	}
	if gotConfig.AutoRedirect {
		t.Fatal("AutoRedirect should be false")
	}
	if len(gotConfig.Inet4Address) != 1 || gotConfig.Inet4Address[0] != netip.MustParsePrefix("10.111.222.1/30") {
		t.Fatalf("inet4 prefixes = %#v", gotConfig.Inet4Address)
	}
	if len(gotConfig.Inet6Address) != 1 || gotConfig.Inet6Address[0] != netip.MustParsePrefix("fd00:111:222::1/126") {
		t.Fatalf("inet6 prefixes = %#v", gotConfig.Inet6Address)
	}
	if len(gotConfig.DNSHijack) != 2 ||
		gotConfig.DNSHijack[0] != "10.111.222.2:53" ||
		gotConfig.DNSHijack[1] != "[fd00:111:222::2]:53" {
		t.Fatalf("dns hijack = %#v want exact virtual DNS endpoints", gotConfig.DNSHijack)
	}
	if len(gotAdditions) == 0 {
		t.Fatal("tun listener additions should include inbound.WithInName")
	}
}

func TestTunStartRequiresOwnedDescriptor(t *testing.T) {
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{})
	if _, err := proxy.StartTun(TunStartOptions{SessionID: "session-1", TunFD: 0}); err == nil {
		t.Fatal("StartTun unexpectedly succeeded with fd=0")
	}
}

func TestTunUpgradeStopsLocalRuntimeBeforeRestart(t *testing.T) {
	var order []string
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error {
			order = append(order, "prepare")
			return nil
		},
		HTTPFactory: func(string) (ListenerHandle, error) {
			order = append(order, "http.start")
			return &fakeListener{address: "127.0.0.1:7890", closeErr: nil}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			order = append(order, "socks.start")
			return &fakeListener{address: "127.0.0.1:7891", closeErr: nil}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			order = append(order, "tun.start")
			return &fakeTunListener{address: "CMFA-TUN"}, nil
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

	if _, err := proxy.Start(StartOptions{
		ConfigPath:         "phase4.yaml",
		HTTPListenAddress:  "127.0.0.1:7890",
		SOCKSListenAddress: "127.0.0.1:0",
	}); err != nil {
		t.Fatalf("Start error: %v", err)
	}
	order = nil

	if _, err := proxy.StartTun(TunStartOptions{SessionID: "session-1", TunFD: 42}); err != nil {
		t.Fatalf("StartTun error: %v", err)
	}

	want := []string{
		"connections.close",
		"executor.shutdown",
		"prepare",
		"http.start",
		"socks.start",
		"tun.start",
	}
	if len(order) < len(want) {
		t.Fatalf("order = %#v want prefix %#v", order, want)
	}
	for index, step := range want {
		if order[index] != step {
			t.Fatalf("order[%d] = %q want %q (full order=%#v)", index, order[index], step, order)
		}
	}
}

func TestTunStopClosesTunBeforeLocalResources(t *testing.T) {
	var order []string
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890", closeErr: nil}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7891", closeErr: nil}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{
				address: "CMFA-TUN",
				closeFn: func() error {
					order = append(order, "tun.close")
					return nil
				},
			}, nil
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

	if _, err := proxy.StartTun(TunStartOptions{
		SessionID: "session-1",
		TunFD:     42,
		Base: StartOptions{
			ConfigPath:         "phase4.yaml",
			HTTPListenAddress:  "127.0.0.1:7890",
			SOCKSListenAddress: "127.0.0.1:0",
		},
	}); err != nil {
		t.Fatalf("StartTun error: %v", err)
	}

	if _, err := proxy.Stop(); err != nil {
		t.Fatalf("Stop error: %v", err)
	}

	if len(order) < 3 {
		t.Fatalf("close order too short: %#v", order)
	}
	if order[0] != "tun.close" {
		t.Fatalf("first close = %q want tun.close", order[0])
	}
	if order[len(order)-2] != "connections.close" || order[len(order)-1] != "executor.shutdown" {
		t.Fatalf("tail order = %#v", order)
	}
}

func TestTunStopContinuesCleanupAndRestoresHookAfterFailures(t *testing.T) {
	protector := &fakeSocketProtector{}
	var order []string
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare:               func(string) error { return nil },
		SocketProtector:       protector,
		SocketProtectAPILevel: 21,
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{
				address: "127.0.0.1:7890",
				closeFn: func() error {
					order = append(order, "http.close")
					return errors.New("http close failed")
				},
			}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{
				address: "127.0.0.1:7891",
				closeFn: func() error {
					order = append(order, "socks.close")
					return errors.New("socks close failed")
				},
			}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{
				address: "CMFA-TUN",
				closeFn: func() error {
					order = append(order, "tun.close")
					return errors.New("tun close failed")
				},
			}, nil
		},
		CloseConnections: func() error {
			order = append(order, "connections.close")
			return errors.New("connections close failed")
		},
		Shutdown: func() error {
			order = append(order, "executor.shutdown")
			return errors.New("executor shutdown failed")
		},
	})

	if _, err := proxy.StartTun(TunStartOptions{
		SessionID: "session-1",
		TunFD:     42,
		Base: StartOptions{
			ConfigPath:         "phase4.yaml",
			HTTPListenAddress:  "127.0.0.1:7890",
			SOCKSListenAddress: "127.0.0.1:0",
		},
	}); err != nil {
		t.Fatalf("StartTun error: %v", err)
	}

	if _, err := proxy.Stop(); err == nil {
		t.Fatal("Stop unexpectedly succeeded")
	} else {
		for _, want := range []string{
			"tun close failed",
			"http close failed",
			"socks close failed",
			"connections close failed",
			"executor shutdown failed",
		} {
			if !strings.Contains(err.Error(), want) {
				t.Fatalf("Stop error = %q want substring %q", err.Error(), want)
			}
		}
	}
	if len(order) != 5 ||
		order[0] != "tun.close" ||
		order[1] != "http.close" ||
		order[2] != "socks.close" ||
		order[3] != "connections.close" ||
		order[4] != "executor.shutdown" {
		t.Fatalf("cleanup order = %#v want full tail execution", order)
	}
	if dialer.DefaultSocketHook != nil {
		t.Fatal("DefaultSocketHook should be restored even when tun close fails")
	}
}

func TestTunStartRollsBackAfterHTTPBindFailure(t *testing.T) {
	protector := &fakeSocketProtector{}
	var order []string
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare:               func(string) error { return nil },
		SocketProtector:       protector,
		SocketProtectAPILevel: 21,
		HTTPFactory: func(string) (ListenerHandle, error) {
			return nil, errors.New("http bind failed")
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

	if _, err := proxy.StartTun(TunStartOptions{
		SessionID: "session-1",
		TunFD:     42,
		Base: StartOptions{
			ConfigPath:         "phase4.yaml",
			HTTPListenAddress:  "127.0.0.1:7890",
			SOCKSListenAddress: "127.0.0.1:0",
		},
	}); err == nil {
		t.Fatal("StartTun unexpectedly succeeded")
	} else if !strings.Contains(err.Error(), "bind HTTP listener 127.0.0.1:7890: http bind failed") {
		t.Fatalf("StartTun error = %q", err.Error())
	}

	if len(order) != 2 || order[0] != "connections.close" || order[1] != "executor.shutdown" {
		t.Fatalf("rollback order = %#v want connections+executor", order)
	}
	if dialer.DefaultSocketHook != nil {
		t.Fatal("DefaultSocketHook should be restored after HTTP bind failure")
	}
}

func TestTunStartRollsBackAfterSOCKSBindFailure(t *testing.T) {
	protector := &fakeSocketProtector{}
	http := &fakeListener{address: "127.0.0.1:7890"}
	var order []string
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare:               func(string) error { return nil },
		SocketProtector:       protector,
		SocketProtectAPILevel: 21,
		HTTPFactory: func(string) (ListenerHandle, error) {
			return http, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return nil, errors.New("socks bind failed")
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

	if _, err := proxy.StartTun(TunStartOptions{
		SessionID: "session-1",
		TunFD:     42,
		Base: StartOptions{
			ConfigPath:         "phase4.yaml",
			HTTPListenAddress:  "127.0.0.1:7890",
			SOCKSListenAddress: "127.0.0.1:0",
		},
	}); err == nil {
		t.Fatal("StartTun unexpectedly succeeded")
	} else if !strings.Contains(err.Error(), "bind SOCKS listener 127.0.0.1:0: socks bind failed") {
		t.Fatalf("StartTun error = %q", err.Error())
	}

	if !http.Closed() {
		t.Fatal("HTTP listener should be closed during SOCKS bind rollback")
	}
	if len(order) != 2 || order[0] != "connections.close" || order[1] != "executor.shutdown" {
		t.Fatalf("rollback order = %#v want connections+executor", order)
	}
	if dialer.DefaultSocketHook != nil {
		t.Fatal("DefaultSocketHook should be restored after SOCKS bind failure")
	}
}

func TestTunStartPrepareFailureRedactsEffectiveConfigPath(t *testing.T) {
	events := &recordingSink{}
	logs := &recordingLogSink{}
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(configPath string) error {
			return errors.New("failed to load /tmp/secret-token/profile.yaml from " + configPath)
		},
		Events: events,
		Logs:   logs,
	})

	_, err := proxy.StartTun(TunStartOptions{
		SessionID: "session-1",
		TunFD:     42,
		Base: StartOptions{
			ConfigPath:         "/tmp/secret-token/profile.yaml",
			HTTPListenAddress:  "127.0.0.1:7890",
			SOCKSListenAddress: "127.0.0.1:0",
		},
	})
	if err == nil {
		t.Fatal("StartTun unexpectedly succeeded")
	}
	if strings.Contains(err.Error(), "/tmp/secret-token/profile.yaml") {
		t.Fatalf("error leaked config path: %q", err.Error())
	}

	snapshot := proxy.TunSnapshot()
	if strings.Contains(snapshot.Failure.Detail, "/tmp/secret-token/profile.yaml") {
		t.Fatalf("tun snapshot leaked config path: %q", snapshot.Failure.Detail)
	}
	for _, event := range events.Events() {
		if strings.Contains(event.Message, "/tmp/secret-token/profile.yaml") {
			t.Fatalf("event leaked config path: %#v", event)
		}
	}
	for _, log := range logs.Logs() {
		if strings.Contains(log.Message, "/tmp/secret-token/profile.yaml") {
			t.Fatalf("log leaked config path: %#v", log)
		}
	}
}

func TestTunStartRollbackClosesPartialResourcesInReverseOrder(t *testing.T) {
	http := &fakeListener{address: "127.0.0.1:7890"}
	socks := &fakeListener{address: "127.0.0.1:7891"}
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) { return http, nil },
		SOCKSFactory: func(string) (ListenerHandle, error) { return socks, nil },
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return nil, errors.New("tun start failed")
		},
	})

	if _, err := proxy.StartTun(TunStartOptions{
		SessionID: "session-1",
		TunFD:     42,
		Base: StartOptions{
			ConfigPath:         "phase4.yaml",
			HTTPListenAddress:  "127.0.0.1:7890",
			SOCKSListenAddress: "127.0.0.1:0",
		},
	}); err == nil {
		t.Fatal("StartTun unexpectedly succeeded")
	}

	if !http.Closed() || !socks.Closed() {
		t.Fatalf("rollback did not close listeners: http=%v socks=%v", http.Closed(), socks.Closed())
	}
	if proxy.TunSnapshot().State != TunStateError {
		t.Fatalf("tun state = %v want %v", proxy.TunSnapshot().State, TunStateError)
	}
}

func TestTunStartAndStopRaceExposeBusy(t *testing.T) {
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error {
			time.Sleep(25 * time.Millisecond)
			return nil
		},
	})

	done := make(chan error, 1)
	go func() {
		_, err := proxy.StartTun(TunStartOptions{
			SessionID: "session-1",
			TunFD:     42,
			Base: StartOptions{
				ConfigPath:         "phase4.yaml",
				HTTPListenAddress:  "127.0.0.1:7890",
				SOCKSListenAddress: "127.0.0.1:0",
			},
		})
		done <- err
	}()

	time.Sleep(5 * time.Millisecond)
	if _, err := proxy.Stop(); !errors.Is(err, ErrRuntimeBusy) {
		t.Fatalf("Stop error = %v want %v", err, ErrRuntimeBusy)
	}
	<-done
}

func TestCloseStaleOutboundConnectionsUsesCloseConnectionsWithoutStoppingTun(t *testing.T) {
	var order []string
	tunListener := &fakeTunListener{address: "CMFA-TUN"}
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			order = append(order, "http.start")
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			order = append(order, "socks.start")
			return &fakeListener{address: "127.0.0.1:0"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			order = append(order, "tun.start")
			return tunListener, nil
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

	snapshot, err := proxy.StartTun(TunStartOptions{
		SessionID: "session-1",
		TunFD:     42,
		Base: StartOptions{
			ConfigPath:         "phase4.yaml",
			HTTPListenAddress:  "127.0.0.1:7890",
			SOCKSListenAddress: "127.0.0.1:0",
		},
	})
	if err != nil {
		t.Fatalf("StartTun error: %v", err)
	}
	if snapshot.State != TunStateReady {
		t.Fatalf("tun state = %v want %v", snapshot.State, TunStateReady)
	}

	order = nil
	if err := proxy.CloseStaleOutboundConnections("session-1"); err != nil {
		t.Fatalf("CloseStaleOutboundConnections error: %v", err)
	}
	if len(order) != 1 || order[0] != "connections.close" {
		t.Fatalf("order = %#v want only connections.close", order)
	}
	if tunListener.closed {
		t.Fatal("close stale should not close tun listener")
	}
	if proxy.TunSnapshot().State != TunStateReady {
		t.Fatalf("tun state after close stale = %v want %v", proxy.TunSnapshot().State, TunStateReady)
	}
}

func TestCloseStaleOutboundConnectionsRejectsStaleSessionID(t *testing.T) {
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:0"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{address: "CMFA-TUN"}, nil
		},
	})

	if _, err := proxy.StartTun(TunStartOptions{
		SessionID: "session-1",
		TunFD:     42,
		Base: StartOptions{
			ConfigPath:         "phase4.yaml",
			HTTPListenAddress:  "127.0.0.1:7890",
			SOCKSListenAddress: "127.0.0.1:0",
		},
	}); err != nil {
		t.Fatalf("StartTun error: %v", err)
	}

	err := proxy.CloseStaleOutboundConnections("session-2")
	if err == nil {
		t.Fatal("CloseStaleOutboundConnections unexpectedly succeeded for stale session")
	}
	if !strings.Contains(err.Error(), "stale session") {
		t.Fatalf("CloseStaleOutboundConnections error = %q", err.Error())
	}
}

func TestCloseStaleOutboundConnectionsMakesStopBusyUntilCleanupReturns(t *testing.T) {
	blocked := make(chan struct{})
	release := make(chan struct{})
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:0"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{address: "CMFA-TUN"}, nil
		},
		CloseConnections: func() error {
			close(blocked)
			<-release
			return nil
		},
	})

	if _, err := proxy.StartTun(TunStartOptions{
		SessionID: "session-1",
		TunFD:     42,
		Base: StartOptions{
			ConfigPath:         "phase4.yaml",
			HTTPListenAddress:  "127.0.0.1:7890",
			SOCKSListenAddress: "127.0.0.1:0",
		},
	}); err != nil {
		t.Fatalf("StartTun error: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- proxy.CloseStaleOutboundConnections("session-1")
	}()
	<-blocked

	if _, err := proxy.Stop(); !errors.Is(err, ErrRuntimeBusy) {
		t.Fatalf("Stop error = %v want %v", err, ErrRuntimeBusy)
	}

	close(release)
	if err := <-done; err != nil {
		t.Fatalf("CloseStaleOutboundConnections error: %v", err)
	}
}
