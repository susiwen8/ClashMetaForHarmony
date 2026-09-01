package runtime

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/dialer"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
)

type fakeNatTable struct{}

func (fakeNatTable) GetOrCreate(string, func() C.PacketSender) (C.PacketSender, bool) {
	return nil, false
}
func (fakeNatTable) Delete(string)                                             {}
func (fakeNatTable) GetForLocalConn(string, string) *net.UDPConn               { return nil }
func (fakeNatTable) AddForLocalConn(string, string, *net.UDPConn) bool         { return false }
func (fakeNatTable) RangeForLocalConn(string, func(string, *net.UDPConn) bool) {}
func (fakeNatTable) GetOrCreateLockForLocalConn(string, string) (*sync.Cond, bool) {
	return nil, false
}
func (fakeNatTable) DeleteForLocalConn(string, string)     {}
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

func TestTunStartReportsFixedStageLifecycleInOrder(t *testing.T) {
	var stages []string
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7891"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{address: "CMFA-TUN"}, nil
		},
		ReportStageLifecycle: func(stage string) {
			stages = append(stages, stage)
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

	want := []string{
		"tun.prepare.begin",
		"tun.prepare.ok",
		"tun.http-listener.begin",
		"tun.http-listener.ok",
		"tun.socks-listener.begin",
		"tun.socks-listener.ok",
		"tun.listener.begin",
		"tun.listener.ok",
	}
	if len(stages) != len(want) {
		t.Fatalf("stages = %#v want %#v", stages, want)
	}
	for index, stage := range want {
		if stages[index] != stage {
			t.Fatalf("stages[%d] = %q want %q (all=%#v)", index, stages[index], stage, stages)
		}
	}
}

func TestTunStartRoutesPacketDiagnosticsThroughLifecycleSink(t *testing.T) {
	var stages []string
	events := &recordingSink{}
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		Events:  events,
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7891"}, nil
		},
		TunFactory: func(_ LC.Tun, tunnel C.Tunnel, _ ...adapterinbound.Addition) (TunListenerHandle, error) {
			reporter, ok := tunnel.(tunPacketDiagnosticReporter)
			if !ok {
				t.Fatal("wrapped TUN tunnel does not expose packet diagnostics")
			}
			reporter.reportTunPacketDiagnostic("tun.packet.read-loop-enter")
			return &fakeTunListener{address: "CMFA-TUN"}, nil
		},
		ReportStageLifecycle: func(stage string) {
			stages = append(stages, stage)
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

	found := false
	for _, stage := range stages {
		if stage == "tun.packet.read-loop-enter" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("stages = %#v want packet diagnostic routed through lifecycle sink", stages)
	}
	gotEvents := events.Events()
	diagnosticCount := 0
	for _, event := range gotEvents {
		if event.Kind == "tun.diagnostic" && event.Protocol == "tun.packet.read-loop-enter" {
			diagnosticCount++
		}
	}
	if diagnosticCount != 1 {
		t.Fatalf("events = %#v want one fixed packet diagnostic runtime event", gotEvents)
	}
}

func TestTunStartReportsTheFailingStageWithoutAdvancing(t *testing.T) {
	tests := []struct {
		name       string
		failedStep string
		want       []string
	}{
		{
			name:       "prepare",
			failedStep: "prepare",
			want:       []string{"tun.prepare.begin", "tun.prepare.failed"},
		},
		{
			name:       "http listener",
			failedStep: "http",
			want: []string{
				"tun.prepare.begin", "tun.prepare.ok",
				"tun.http-listener.begin", "tun.http-listener.failed",
			},
		},
		{
			name:       "socks listener",
			failedStep: "socks",
			want: []string{
				"tun.prepare.begin", "tun.prepare.ok",
				"tun.http-listener.begin", "tun.http-listener.ok",
				"tun.socks-listener.begin", "tun.socks-listener.failed",
			},
		},
		{
			name:       "tun listener",
			failedStep: "tun",
			want: []string{
				"tun.prepare.begin", "tun.prepare.ok",
				"tun.http-listener.begin", "tun.http-listener.ok",
				"tun.socks-listener.begin", "tun.socks-listener.ok",
				"tun.listener.begin",
				"tun.listener.failure.unknown-scope",
				"tun.listener.failure.unknown-cause",
				"tun.listener.failed",
			},
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			var stages []string
			proxy := NewLocalProxyWithDeps(LocalProxyDeps{
				Prepare: func(string) error {
					if testCase.failedStep == "prepare" {
						return errors.New("prepare failed")
					}
					return nil
				},
				HTTPFactory: func(string) (ListenerHandle, error) {
					if testCase.failedStep == "http" {
						return nil, errors.New("http failed")
					}
					return &fakeListener{address: "127.0.0.1:7890"}, nil
				},
				SOCKSFactory: func(string) (ListenerHandle, error) {
					if testCase.failedStep == "socks" {
						return nil, errors.New("socks failed")
					}
					return &fakeListener{address: "127.0.0.1:7891"}, nil
				},
				TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
					if testCase.failedStep == "tun" {
						return nil, errors.New("tun failed")
					}
					return &fakeTunListener{address: "CMFA-TUN"}, nil
				},
				ReportStageLifecycle: func(stage string) {
					stages = append(stages, stage)
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

			if len(stages) != len(testCase.want) {
				t.Fatalf("stages = %#v want %#v", stages, testCase.want)
			}
			for index, stage := range testCase.want {
				if stages[index] != stage {
					t.Fatalf("stages[%d] = %q want %q (all=%#v)", index, stages[index], stage, stages)
				}
			}
		})
	}
}

func TestClassifyTunListenerFailureUsesOnlyFixedScopeAndCause(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want []string
	}{
		{
			name: "stack start invalid",
			err:  errors.New("createInboundDispatcher(sec" + "ret=do-not-log): invalid argument"),
			want: []string{"tun.listener.failure.stack-start", "tun.listener.failure.invalid"},
		},
		{
			name: "stack descriptor inspection permission",
			err:  fmt.Errorf("unix.Fstat(77,...) failed: %w", syscall.EPERM),
			want: []string{"tun.listener.failure.stack-start", "tun.listener.failure.permission"},
		},
		{
			name: "interface permission",
			err:  errors.New("configure tun interface /secret/path: permission denied"),
			want: []string{"tun.listener.failure.interface", "tun.listener.failure.permission"},
		},
		{
			name: "stack unsupported",
			err:  errors.New("gVisor stack is unsupported on current platform: token=secret"),
			want: []string{"tun.listener.failure.stack-create", "tun.listener.failure.unsupported"},
		},
		{
			name: "unknown",
			err:  errors.New("secret dynamic failure"),
			want: []string{"tun.listener.failure.unknown-scope", "tun.listener.failure.unknown-cause"},
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			got := classifyTunListenerFailure(testCase.err)
			if len(got) != len(testCase.want) {
				t.Fatalf("classification = %#v want %#v", got, testCase.want)
			}
			for index := range testCase.want {
				if got[index] != testCase.want[index] {
					t.Fatalf("classification[%d] = %q want %q", index, got[index], testCase.want[index])
				}
				if strings.Contains(got[index], "secret") {
					t.Fatalf("classification leaked source detail: %q", got[index])
				}
			}
		})
	}
}

func TestTunStartIgnoresStageReporterPanics(t *testing.T) {
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7891"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{address: "CMFA-TUN"}, nil
		},
		ReportStageLifecycle: func(string) {
			panic("reporter failed")
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

func TestTunStopReportsFixedStageLifecycleInOrder(t *testing.T) {
	var stages []string
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7891"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{address: "CMFA-TUN"}, nil
		},
		CloseConnections: func() error { return nil },
		Shutdown:         func() error { return nil },
		ReportStageLifecycle: func(stage string) {
			stages = append(stages, stage)
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
	stages = nil

	if _, err := proxy.Stop(); err != nil {
		t.Fatalf("Stop error: %v", err)
	}

	want := []string{
		"tun.stop.listener.begin",
		"tun.stop.listener.ok",
		"tun.stop.http-listener.begin",
		"tun.stop.http-listener.ok",
		"tun.stop.socks-listener.begin",
		"tun.stop.socks-listener.ok",
		"tun.stop.connections.begin",
		"tun.stop.connections.ok",
		"tun.stop.executor.begin",
		"tun.stop.executor.ok",
	}
	if len(stages) != len(want) {
		t.Fatalf("stages = %#v want %#v", stages, want)
	}
	for index, stage := range want {
		if stages[index] != stage {
			t.Fatalf("stages[%d] = %q want %q (all=%#v)", index, stages[index], stage, stages)
		}
	}
}

func TestTunStopReportsFailureAndContinuesRemainingStages(t *testing.T) {
	var stages []string
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7891"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{
				address: "CMFA-TUN",
				closeFn: func() error {
					return errors.New("tun close failed sec" + "ret=do-not-log")
				},
			}, nil
		},
		CloseConnections: func() error { return nil },
		Shutdown:         func() error { return nil },
		ReportStageLifecycle: func(stage string) {
			stages = append(stages, stage)
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
	stages = nil

	if _, err := proxy.Stop(); err == nil {
		t.Fatal("Stop unexpectedly succeeded")
	}

	want := []string{
		"tun.stop.listener.begin",
		"tun.stop.listener.failed",
		"tun.stop.http-listener.begin",
		"tun.stop.http-listener.ok",
		"tun.stop.socks-listener.begin",
		"tun.stop.socks-listener.ok",
		"tun.stop.connections.begin",
		"tun.stop.connections.ok",
		"tun.stop.executor.begin",
		"tun.stop.executor.ok",
	}
	if len(stages) != len(want) {
		t.Fatalf("stages = %#v want %#v", stages, want)
	}
	for index, stage := range want {
		if stages[index] != stage {
			t.Fatalf("stages[%d] = %q want %q (all=%#v)", index, stages[index], stage, stages)
		}
	}
	for _, stage := range stages {
		if strings.Contains(stage, "secret") {
			t.Fatalf("stage leaked sensitive content: %#v", stages)
		}
	}
	if snapshot := proxy.TunSnapshot(); snapshot.SessionID != "session-1" {
		t.Fatalf("TunSnapshot.SessionID after failed Stop = %q want session-1", snapshot.SessionID)
	}
}

func TestTunStopPreservesSessionIDAfterSuccessfulStop(t *testing.T) {
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7891"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{address: "CMFA-TUN"}, nil
		},
		CloseConnections: func() error { return nil },
		Shutdown:         func() error { return nil },
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

	stoppedTun := proxy.TunSnapshot()
	if stoppedTun.State != TunStateStopped {
		t.Fatalf("TunSnapshot.State after Stop = %v want %v", stoppedTun.State, TunStateStopped)
	}
	if stoppedTun.SessionID != "session-1" {
		t.Fatalf("TunSnapshot.SessionID after Stop = %q want session-1", stoppedTun.SessionID)
	}
}

func TestTunStopPreservesSessionIDAfterCleanupFailure(t *testing.T) {
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7891"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{
				address: "CMFA-TUN",
				closeFn: func() error {
					return errors.New("tun close failed sec" + "ret=do-not-log")
				},
			}, nil
		},
		CloseConnections: func() error { return nil },
		Shutdown:         func() error { return nil },
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
	}

	stoppedTun := proxy.TunSnapshot()
	if stoppedTun.State != TunStateError {
		t.Fatalf("TunSnapshot.State after failed Stop = %v want %v", stoppedTun.State, TunStateError)
	}
	if stoppedTun.SessionID != "session-1" {
		t.Fatalf("TunSnapshot.SessionID after failed Stop = %q want session-1", stoppedTun.SessionID)
	}
}

func TestBuildStopCommitDecisionSelectsFinalStateWithoutTransientStopped(t *testing.T) {
	baseTunSnapshot := TunSnapshot{
		State:     TunStateStopped,
		SessionID: "session-1",
		Counters: TunCounters{
			TXPackets: 3,
		},
	}
	previous := Snapshot{
		State:            RuntimeError,
		ActiveConfigPath: "phase4.yaml",
		LastError:        "existing runtime failure",
	}
	previousTun := TunSnapshot{
		State:     TunStateError,
		SessionID: "session-1",
		Counters: TunCounters{
			RXPackets: 7,
		},
		Failure: TunFailure{
			Code:   "VPN_TUN_START_FAILED",
			Detail: "existing tun failure",
		},
	}

	tests := []struct {
		name                  string
		preserveError         bool
		stopFailureDiagnostic string
		wantState             RuntimeState
		wantLastError         string
		wantTunState          TunState
		wantTunCounters       TunCounters
		wantTunFailure        TunFailure
		wantErr               bool
	}{
		{
			name:                  "cleanup failure goes directly to runtime error",
			stopFailureDiagnostic: "TUN_STOP_LISTENER_FAILED_PANIC",
			wantState:             RuntimeError,
			wantLastError:         "TUN_STOP_LISTENER_FAILED_PANIC",
			wantTunState:          TunStateError,
			wantTunCounters:       baseTunSnapshot.Counters,
			wantErr:               true,
		},
		{
			name:            "successful stop commits stopped state",
			wantState:       RuntimeStopped,
			wantTunState:    TunStateStopped,
			wantTunCounters: baseTunSnapshot.Counters,
		},
		{
			name:            "preserved error keeps previous failure snapshot",
			preserveError:   true,
			wantState:       RuntimeError,
			wantLastError:   "existing runtime failure",
			wantTunState:    TunStateError,
			wantTunCounters: previousTun.Counters,
			wantTunFailure:  previousTun.Failure,
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			decision := buildStopCommitDecision(
				testCase.preserveError,
				previous,
				previousTun,
				testCase.stopFailureDiagnostic,
				baseTunSnapshot,
			)

			if decision.snapshot.State != testCase.wantState {
				t.Fatalf("snapshot.State = %v want %v", decision.snapshot.State, testCase.wantState)
			}
			if decision.snapshot.LastError != testCase.wantLastError {
				t.Fatalf("snapshot.LastError = %q want %q", decision.snapshot.LastError, testCase.wantLastError)
			}
			if decision.tunSnapshot.State != testCase.wantTunState {
				t.Fatalf("tunSnapshot.State = %v want %v", decision.tunSnapshot.State, testCase.wantTunState)
			}
			if decision.tunSnapshot.SessionID != "session-1" {
				t.Fatalf("tunSnapshot.SessionID = %q want session-1", decision.tunSnapshot.SessionID)
			}
			if decision.tunSnapshot.Counters != testCase.wantTunCounters {
				t.Fatalf("tunSnapshot.Counters = %#v want %#v", decision.tunSnapshot.Counters, testCase.wantTunCounters)
			}
			if decision.tunSnapshot.Failure != testCase.wantTunFailure {
				t.Fatalf("tunSnapshot.Failure = %#v want %#v", decision.tunSnapshot.Failure, testCase.wantTunFailure)
			}
			if (decision.returnErr != nil) != testCase.wantErr {
				t.Fatalf("returnErr present = %t want %t", decision.returnErr != nil, testCase.wantErr)
			}
		})
	}
}

func TestTunStopClassifiesTunListenerFailureWithFixedCauseCodes(t *testing.T) {
	tests := []struct {
		name       string
		closeErr   error
		wantPrefix string
	}{
		{
			name:       "bad fd via wrapped syscall",
			closeErr:   fmt.Errorf("listener token=raw-bad-fd: %w", syscall.EBADF),
			wantPrefix: "TUN_STOP_LISTENER_FAILED_BAD_FD",
		},
		{
			name:       "already closed via normalized string",
			closeErr:   errors.New("listener sec" + "ret=raw-closed use of closed network connection"),
			wantPrefix: "TUN_STOP_LISTENER_FAILED_ALREADY_CLOSED",
		},
		{
			name:       "invalid via wrapped syscall",
			closeErr:   fmt.Errorf("listener pass"+"word=raw-invalid: %w", syscall.EINVAL),
			wantPrefix: "TUN_STOP_LISTENER_FAILED_INVALID",
		},
		{
			name:       "io via normalized string",
			closeErr:   errors.New("listener sec" + "ret=raw-io i/o timeout"),
			wantPrefix: "TUN_STOP_LISTENER_FAILED_IO",
		},
		{
			name:       "other",
			closeErr:   errors.New("listener sec" + "ret=raw-other close exploded"),
			wantPrefix: "TUN_STOP_LISTENER_FAILED_OTHER",
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			proxy := NewLocalProxyWithDeps(LocalProxyDeps{
				Prepare: func(string) error { return nil },
				HTTPFactory: func(string) (ListenerHandle, error) {
					return &fakeListener{address: "127.0.0.1:7890"}, nil
				},
				SOCKSFactory: func(string) (ListenerHandle, error) {
					return &fakeListener{address: "127.0.0.1:7891"}, nil
				},
				TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
					return &fakeTunListener{
						address: "CMFA-TUN",
						closeFn: func() error {
							return testCase.closeErr
						},
					}, nil
				},
				CloseConnections: func() error { return nil },
				Shutdown:         func() error { return nil },
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

			snapshot, err := proxy.Stop()
			if err == nil {
				t.Fatal("Stop unexpectedly succeeded")
			}
			if !strings.HasPrefix(snapshot.LastError, testCase.wantPrefix) {
				t.Fatalf("snapshot.LastError = %q want prefix %q", snapshot.LastError, testCase.wantPrefix)
			}
			if !strings.HasPrefix(err.Error(), testCase.wantPrefix) {
				t.Fatalf("Stop error = %q want prefix %q", err.Error(), testCase.wantPrefix)
			}
			for _, forbidden := range []string{"raw-bad-fd", "raw-closed", "raw-invalid", "raw-io", "raw-other"} {
				if strings.Contains(snapshot.LastError, forbidden) || strings.Contains(err.Error(), forbidden) {
					t.Fatalf("stop failure leaked %q: err=%q snapshot=%q", forbidden, err.Error(), snapshot.LastError)
				}
			}
			if !strings.Contains(snapshot.LastError, "<redacted>") {
				t.Fatalf("snapshot.LastError = %q want redacted secret marker", snapshot.LastError)
			}
		})
	}
}

func TestTunStopConvertsActionPanicsToSanitizedFailureAndContinuesCleanup(t *testing.T) {
	previousHook := dialer.DefaultSocketHook
	defer func() {
		dialer.DefaultSocketHook = previousHook
	}()

	events := &recordingSink{}
	protector := &fakeSocketProtector{}
	var (
		order  []string
		stages []string
	)
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare:               func(string) error { return nil },
		Events:                events,
		SocketProtector:       protector,
		SocketProtectAPILevel: 21,
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{
				address: "127.0.0.1:7890",
				closeFn: func() error {
					order = append(order, "http.close")
					return nil
				},
			}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{
				address: "127.0.0.1:7891",
				closeFn: func() error {
					order = append(order, "socks.close")
					return nil
				},
			}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{
				address: "CMFA-TUN",
				closeFn: func() error {
					order = append(order, "tun.close")
					panic("listener panic sec" + "ret=do-not-log")
				},
			}, nil
		},
		CloseConnections: func() error {
			order = append(order, "connections.close")
			panic("cleanup panic token=abc123")
		},
		Shutdown: func() error {
			order = append(order, "executor.shutdown")
			return nil
		},
		ReportStageLifecycle: func(stage string) {
			stages = append(stages, stage)
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
	order = nil
	stages = nil

	snapshot, err := proxy.Stop()
	if err == nil {
		t.Fatal("Stop unexpectedly succeeded")
	}
	if snapshot.State != RuntimeError {
		t.Fatalf("snapshot.State = %v want %v", snapshot.State, RuntimeError)
	}
	if snapshot.LastError == "" {
		t.Fatal("snapshot.LastError should record sanitized panic failure")
	}
	for _, forbidden := range []string{"secret", "do-not-log", "abc123"} {
		if strings.Contains(err.Error(), forbidden) || strings.Contains(snapshot.LastError, forbidden) {
			t.Fatalf("stop failure leaked panic detail %q: err=%q snapshot=%q", forbidden, err.Error(), snapshot.LastError)
		}
	}
	for _, wanted := range []string{"TUN_STOP_LISTENER_FAILED_PANIC", "TUN_STOP_CONNECTIONS_FAILED_PANIC"} {
		if !strings.Contains(err.Error(), wanted) {
			t.Fatalf("Stop error = %q want substring %q", err.Error(), wanted)
		}
	}
	if len(order) != 5 ||
		order[0] != "tun.close" ||
		order[1] != "http.close" ||
		order[2] != "socks.close" ||
		order[3] != "connections.close" ||
		order[4] != "executor.shutdown" {
		t.Fatalf("cleanup order = %#v want full continuation after panics", order)
	}
	wantStages := []string{
		"tun.stop.listener.begin",
		"tun.stop.listener.failed",
		"tun.stop.http-listener.begin",
		"tun.stop.http-listener.ok",
		"tun.stop.socks-listener.begin",
		"tun.stop.socks-listener.ok",
		"tun.stop.connections.begin",
		"tun.stop.connections.failed",
		"tun.stop.executor.begin",
		"tun.stop.executor.ok",
	}
	if len(stages) != len(wantStages) {
		t.Fatalf("stages = %#v want %#v", stages, wantStages)
	}
	for index, stage := range wantStages {
		if stages[index] != stage {
			t.Fatalf("stages[%d] = %q want %q (all=%#v)", index, stages[index], stage, stages)
		}
	}
	if dialer.DefaultSocketHook != nil {
		t.Fatal("DefaultSocketHook should be restored after panic-based stop failure")
	}
	tunSnapshot := proxy.TunSnapshot()
	if tunSnapshot.State != TunStateError {
		t.Fatalf("tunSnapshot.State = %v want %v", tunSnapshot.State, TunStateError)
	}

	gotEvents := events.Events()
	if len(gotEvents) < 4 {
		t.Fatalf("events = %#v want runtime lifecycle", gotEvents)
	}
	last := gotEvents[len(gotEvents)-1]
	if last.Kind != "runtime.error" || last.State != RuntimeError {
		t.Fatalf("last event = %#v want runtime.error/%v", last, RuntimeError)
	}
	for _, event := range gotEvents {
		if event.Kind == "runtime.stopped" {
			t.Fatalf("events should not publish runtime.stopped on stop failure: %#v", gotEvents)
		}
		if strings.Contains(event.Message, "secret") || strings.Contains(event.Message, "abc123") {
			t.Fatalf("event leaked panic content: %#v", gotEvents)
		}
	}
}

func TestTunStopIgnoresStageReporterPanics(t *testing.T) {
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7891"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return &fakeTunListener{address: "CMFA-TUN"}, nil
		},
		CloseConnections: func() error { return nil },
		Shutdown:         func() error { return nil },
		ReportStageLifecycle: func(string) {
			panic("reporter failed")
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

	snapshot, err := proxy.Stop()
	if err != nil {
		t.Fatalf("Stop error: %v", err)
	}
	if snapshot.State != RuntimeStopped {
		t.Fatalf("snapshot.State = %v want %v", snapshot.State, RuntimeStopped)
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
			"TUN_STOP_LISTENER_FAILED_OTHER",
			"tun close failed",
			"TUN_STOP_HTTP_LISTENER_FAILED_ERROR",
			"http close failed",
			"TUN_STOP_SOCKS_LISTENER_FAILED_ERROR",
			"socks close failed",
			"TUN_STOP_CONNECTIONS_FAILED_ERROR",
			"connections close failed",
			"TUN_STOP_EXECUTOR_FAILED_ERROR",
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
		Prepare:      func(string) error { return nil },
		HTTPFactory:  func(string) (ListenerHandle, error) { return http, nil },
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

func TestTunSnapshotMarksRouteLossAsRecoverableNetworkLost(t *testing.T) {
	tunListener := &fakeTunListener{address: "CMFA-TUN"}
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:0"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return tunListener, nil
		},
		TunRouteProbe: func() error {
			return syscall.ENETUNREACH
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

	snapshot := proxy.TunSnapshot()
	if snapshot.State != TunStateError {
		t.Fatalf("tun state = %v want %v", snapshot.State, TunStateError)
	}
	if snapshot.Failure.Code != "NETWORK_LOST" {
		t.Fatalf("tun failure code = %q want NETWORK_LOST", snapshot.Failure.Code)
	}
	if snapshot.Failure.Detail != "Physical network route unavailable." {
		t.Fatalf("tun failure detail = %q", snapshot.Failure.Detail)
	}
	if tunListener.closed {
		t.Fatal("route loss probe must not close the active tun listener")
	}
	if proxy.Snapshot().State != RuntimeRunning {
		t.Fatalf("runtime state = %v want %v", proxy.Snapshot().State, RuntimeRunning)
	}
}

func TestTunSnapshotRecoversNetworkLostStateAfterRouteReturns(t *testing.T) {
	tunListener := &fakeTunListener{address: "CMFA-TUN"}
	probeErrors := []error{syscall.ENETDOWN, nil}
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		Prepare: func(string) error { return nil },
		HTTPFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:7890"}, nil
		},
		SOCKSFactory: func(string) (ListenerHandle, error) {
			return &fakeListener{address: "127.0.0.1:0"}, nil
		},
		TunFactory: func(LC.Tun, C.Tunnel, ...adapterinbound.Addition) (TunListenerHandle, error) {
			return tunListener, nil
		},
		TunRouteProbe: func() error {
			next := probeErrors[0]
			probeErrors = probeErrors[1:]
			return next
		},
		TunRouteProbeInterval: 20 * time.Millisecond,
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

	lost := proxy.TunSnapshot()
	if lost.State != TunStateError || lost.Failure.Code != "NETWORK_LOST" {
		t.Fatalf("lost snapshot = %#v want NETWORK_LOST error", lost)
	}

	time.Sleep(25 * time.Millisecond)
	recovered := proxy.TunSnapshot()
	if recovered.State != TunStateReady {
		t.Fatalf("recovered state = %v want %v", recovered.State, TunStateReady)
	}
	if recovered.Failure != (TunFailure{}) {
		t.Fatalf("recovered failure = %#v want cleared failure", recovered.Failure)
	}
	if recovered.SessionID != "session-1" {
		t.Fatalf("recovered session = %q want session-1", recovered.SessionID)
	}
	if tunListener.closed {
		t.Fatal("route recovery must not recreate or close the active tun listener")
	}
}

func TestTunSnapshotDoesNotMisreportNonRouteProbeFailures(t *testing.T) {
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
		TunRouteProbe: func() error {
			return syscall.EPERM
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

	snapshot := proxy.TunSnapshot()
	if snapshot.State != TunStateReady {
		t.Fatalf("tun state = %v want %v", snapshot.State, TunStateReady)
	}
	if snapshot.Failure != (TunFailure{}) {
		t.Fatalf("tun failure = %#v want no failure", snapshot.Failure)
	}
}

func TestTunSnapshotPreservesNonNetworkLostErrors(t *testing.T) {
	proxy := NewLocalProxyWithDeps(LocalProxyDeps{
		TunRouteProbe: func() error { return nil },
	})
	proxy.mu.Lock()
	proxy.tunListener = &fakeTunListener{address: "CMFA-TUN"}
	proxy.tunSnapshot = TunSnapshot{
		State:     TunStateError,
		SessionID: "session-1",
		Failure: TunFailure{
			Code:   "VPN_TUN_START_FAILED",
			Detail: "existing failure",
		},
	}
	proxy.mu.Unlock()

	snapshot := proxy.TunSnapshot()
	if snapshot.State != TunStateError {
		t.Fatalf("tun state = %v want %v", snapshot.State, TunStateError)
	}
	if snapshot.Failure.Code != "VPN_TUN_START_FAILED" {
		t.Fatalf("tun failure code = %q want VPN_TUN_START_FAILED", snapshot.Failure.Code)
	}
	if snapshot.Failure.Detail != "existing failure" {
		t.Fatalf("tun failure detail = %q want existing failure", snapshot.Failure.Detail)
	}
}

func TestDefaultTunRouteProbeUsesDialerSocketHook(t *testing.T) {
	previousHook := dialer.DefaultSocketHook
	defer func() {
		dialer.DefaultSocketHook = previousHook
	}()

	calls := 0
	dialer.DefaultSocketHook = func(network, address string, rawConn syscall.RawConn) error {
		calls += 1
		if network != "udp" && network != "udp4" {
			t.Fatalf("network = %q want udp or udp4", network)
		}
		if address != "192.0.2.1:9" {
			t.Fatalf("address = %q want 192.0.2.1:9", address)
		}
		return syscall.ENETUNREACH
	}

	err := defaultTunRouteProbe()
	if !errors.Is(err, syscall.ENETUNREACH) {
		t.Fatalf("defaultTunRouteProbe error = %v want %v", err, syscall.ENETUNREACH)
	}
	if calls != 1 {
		t.Fatalf("socket hook calls = %d want 1", calls)
	}
}

func TestTunSnapshotThrottlesRouteProbePerSession(t *testing.T) {
	probeCalls := 0
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
		TunRouteProbe: func() error {
			probeCalls += 1
			return nil
		},
		TunRouteProbeInterval: 20 * time.Millisecond,
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

	_ = proxy.TunSnapshot()
	_ = proxy.TunSnapshot()
	if probeCalls != 1 {
		t.Fatalf("immediate route probe calls = %d want 1", probeCalls)
	}

	time.Sleep(25 * time.Millisecond)
	_ = proxy.TunSnapshot()
	if probeCalls != 2 {
		t.Fatalf("delayed route probe calls = %d want 2", probeCalls)
	}
}

func TestTunSnapshotRestartDoesNotInheritInFlightProbeGate(t *testing.T) {
	oldProbeStarted := make(chan struct{})
	releaseOldProbe := make(chan struct{})
	newProbeCalled := make(chan struct{}, 1)
	var probeMu sync.Mutex
	probeCall := 0
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
		TunRouteProbe: func() error {
			probeMu.Lock()
			probeCall += 1
			call := probeCall
			probeMu.Unlock()
			if call == 1 {
				close(oldProbeStarted)
				<-releaseOldProbe
				return syscall.ENETUNREACH
			}
			if call == 2 {
				newProbeCalled <- struct{}{}
			}
			return nil
		},
		TunRouteProbeInterval: time.Hour,
	})

	startTun := func(sessionID string) {
		t.Helper()
		if _, err := proxy.StartTun(TunStartOptions{
			SessionID: sessionID,
			TunFD:     42,
			Base: StartOptions{
				ConfigPath:         "phase4.yaml",
				HTTPListenAddress:  "127.0.0.1:7890",
				SOCKSListenAddress: "127.0.0.1:0",
			},
		}); err != nil {
			t.Fatalf("StartTun(%s) error: %v", sessionID, err)
		}
	}

	startTun("session-1")
	done := make(chan TunSnapshot, 1)
	go func() {
		done <- proxy.TunSnapshot()
	}()
	<-oldProbeStarted

	if _, err := proxy.Stop(); err != nil {
		t.Fatalf("Stop error: %v", err)
	}
	startTun("session-2")

	snapshot := proxy.TunSnapshot()
	select {
	case <-newProbeCalled:
	default:
		t.Fatal("new session first TunSnapshot did not execute route probe while old probe was still in flight")
	}
	if snapshot.SessionID != "session-2" {
		t.Fatalf("snapshot session = %q want session-2", snapshot.SessionID)
	}

	close(releaseOldProbe)
	oldSnapshot := <-done
	if oldSnapshot.SessionID != "session-2" {
		t.Fatalf("late snapshot session = %q want session-2", oldSnapshot.SessionID)
	}
	finalSnapshot := proxy.TunSnapshot()
	if finalSnapshot.SessionID != "session-2" {
		t.Fatalf("final snapshot session = %q want session-2", finalSnapshot.SessionID)
	}
	if finalSnapshot.State != TunStateReady {
		t.Fatalf("final state = %v want %v", finalSnapshot.State, TunStateReady)
	}
}

func TestTunSnapshotLateOldProbeCannotClearNewSessionInFlightGate(t *testing.T) {
	oldProbeStarted := make(chan struct{})
	releaseOldProbe := make(chan struct{})
	oldProbeFinished := make(chan struct{})
	newProbeStarted := make(chan struct{})
	releaseNewProbe := make(chan struct{})
	thirdProbeStarted := make(chan struct{}, 1)
	var probeMu sync.Mutex
	probeCall := 0
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
		TunRouteProbe: func() error {
			probeMu.Lock()
			probeCall += 1
			call := probeCall
			probeMu.Unlock()
			switch call {
			case 1:
				close(oldProbeStarted)
				<-releaseOldProbe
				close(oldProbeFinished)
				return syscall.ENETUNREACH
			case 2:
				close(newProbeStarted)
				<-releaseNewProbe
				return nil
			default:
				thirdProbeStarted <- struct{}{}
				return nil
			}
		},
		TunRouteProbeInterval: time.Hour,
	})

	startTun := func(sessionID string) {
		t.Helper()
		if _, err := proxy.StartTun(TunStartOptions{
			SessionID: sessionID,
			TunFD:     42,
			Base: StartOptions{
				ConfigPath:         "phase4.yaml",
				HTTPListenAddress:  "127.0.0.1:7890",
				SOCKSListenAddress: "127.0.0.1:0",
			},
		}); err != nil {
			t.Fatalf("StartTun(%s) error: %v", sessionID, err)
		}
	}

	startTun("session-1")
	oldDone := make(chan TunSnapshot, 1)
	go func() {
		oldDone <- proxy.TunSnapshot()
	}()
	<-oldProbeStarted

	if _, err := proxy.Stop(); err != nil {
		t.Fatalf("Stop error: %v", err)
	}
	startTun("session-2")
	newDone := make(chan TunSnapshot, 1)
	go func() {
		newDone <- proxy.TunSnapshot()
	}()
	<-newProbeStarted

	close(releaseOldProbe)
	<-oldProbeFinished

	thirdSnapshot := proxy.TunSnapshot()
	if thirdSnapshot.SessionID != "session-2" {
		t.Fatalf("third snapshot session = %q want session-2", thirdSnapshot.SessionID)
	}
	select {
	case <-thirdProbeStarted:
		t.Fatal("late session-1 probe cleared the session-2 in-flight gate")
	default:
	}

	close(releaseNewProbe)
	<-oldDone
	finalSnapshot := <-newDone
	if finalSnapshot.SessionID != "session-2" {
		t.Fatalf("final snapshot session = %q want session-2", finalSnapshot.SessionID)
	}
}

func TestTunSnapshotRestartDoesNotInheritPreviousProbeThrottle(t *testing.T) {
	var probeMu sync.Mutex
	probeCalls := 0
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
		TunRouteProbe: func() error {
			probeMu.Lock()
			probeCalls += 1
			probeMu.Unlock()
			return nil
		},
		TunRouteProbeInterval: time.Hour,
	})

	startTun := func(sessionID string) {
		t.Helper()
		if _, err := proxy.StartTun(TunStartOptions{
			SessionID: sessionID,
			TunFD:     42,
			Base: StartOptions{
				ConfigPath:         "phase4.yaml",
				HTTPListenAddress:  "127.0.0.1:7890",
				SOCKSListenAddress: "127.0.0.1:0",
			},
		}); err != nil {
			t.Fatalf("StartTun(%s) error: %v", sessionID, err)
		}
	}

	startTun("session-1")
	_ = proxy.TunSnapshot()
	if _, err := proxy.Stop(); err != nil {
		t.Fatalf("Stop error: %v", err)
	}
	startTun("session-2")
	_ = proxy.TunSnapshot()

	probeMu.Lock()
	defer probeMu.Unlock()
	if probeCalls != 2 {
		t.Fatalf("route probe calls across restart = %d want 2", probeCalls)
	}
}

func TestTunSnapshotProbePanicDoesNotLeaveGateLatched(t *testing.T) {
	var probeMu sync.Mutex
	probeCalls := 0
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
		TunRouteProbe: func() error {
			probeMu.Lock()
			probeCalls += 1
			call := probeCalls
			probeMu.Unlock()
			if call == 1 {
				panic("probe panic")
			}
			return nil
		},
		TunRouteProbeInterval: time.Hour,
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

	func() {
		defer func() {
			if recovered := recover(); recovered == nil {
				t.Fatal("TunSnapshot should propagate probe panic")
			}
		}()
		_ = proxy.TunSnapshot()
	}()

	_ = proxy.TunSnapshot()

	probeMu.Lock()
	defer probeMu.Unlock()
	if probeCalls != 2 {
		t.Fatalf("route probe calls after panic = %d want 2", probeCalls)
	}
}
