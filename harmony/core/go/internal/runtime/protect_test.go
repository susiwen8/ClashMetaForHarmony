package runtime

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
)

type fakeSocketProtector struct {
	calls    atomic.Int64
	lastFD   atomic.Int64
	timeout  time.Duration
	err      error
}

func (p *fakeSocketProtector) ProtectSocket(fd int, timeout time.Duration) error {
	p.calls.Add(1)
	p.lastFD.Store(int64(fd))
	p.timeout = timeout
	return p.err
}

type fakeRawConn struct {
	fd         uintptr
	closeCalls atomic.Int64
	controlCalls atomic.Int64
}

func (c *fakeRawConn) Control(fn func(fd uintptr)) error {
	c.controlCalls.Add(1)
	fn(c.fd)
	return nil
}

func (c *fakeRawConn) Read(func(fd uintptr) bool) error  { return nil }
func (c *fakeRawConn) Write(func(fd uintptr) bool) error { return nil }

func TestProtectInstallsPerSocketHookOnAPI20And21(t *testing.T) {
	for _, apiLevel := range []int{20, 21} {
		t.Run(string(rune('A'+apiLevel-20)), func(t *testing.T) {
			protector := &fakeSocketProtector{}
			sink := &recordingSink{}
			restore := installSocketProtection(SocketProtectionOptions{
				APILevel:      apiLevel,
				Timeout:       3 * time.Second,
				Protector:     protector,
				Events:        sink,
				FailureCode:   "VPN_SOCKET_PROTECT_FAILED",
				FailureState:  RuntimeRunning,
			})
			defer restore()

			if dialer.DefaultSocketHook == nil {
				t.Fatal("DefaultSocketHook should be installed for API20/21")
			}

			raw := &fakeRawConn{fd: 57}
			if err := dialer.DefaultSocketHook("tcp", "1.1.1.1:443", raw); err != nil {
				t.Fatalf("socket hook error: %v", err)
			}
			if protector.calls.Load() != 1 {
				t.Fatalf("protect calls = %d want 1", protector.calls.Load())
			}
			if protector.lastFD.Load() != 57 {
				t.Fatalf("protected fd = %d want 57", protector.lastFD.Load())
			}
			if len(sink.Events()) != 0 {
				t.Fatalf("success should not emit failure events: %#v", sink.Events())
			}
		})
	}
}

func TestProtectFailureFailsClosedAndEmitsEvent(t *testing.T) {
	protector := &fakeSocketProtector{err: errors.New("rejected")}
	sink := &recordingSink{}
	restore := installSocketProtection(SocketProtectionOptions{
		APILevel:     21,
		Timeout:      3 * time.Second,
		Protector:    protector,
		Events:       sink,
		FailureCode:  "VPN_SOCKET_PROTECT_FAILED",
		FailureState: RuntimeRunning,
	})
	defer restore()

	raw := &fakeRawConn{fd: 99}
	err := dialer.DefaultSocketHook("udp", "8.8.8.8:53", raw)
	if err == nil {
		t.Fatal("socket hook unexpectedly succeeded")
	}
	if len(sink.Events()) != 1 {
		t.Fatalf("failure events = %#v want 1", sink.Events())
	}
	if sink.Events()[0].Code != "VPN_SOCKET_PROTECT_FAILED" {
		t.Fatalf("failure code = %q want VPN_SOCKET_PROTECT_FAILED", sink.Events()[0].Code)
	}
}

func TestProtectFailureDoesNotCloseBorrowedFDInHook(t *testing.T) {
	protector := &fakeSocketProtector{err: errors.New("rejected")}
	restore := installSocketProtection(SocketProtectionOptions{
		APILevel:     21,
		Timeout:      3 * time.Second,
		Protector:    protector,
		Events:       &recordingSink{},
		FailureCode:  "VPN_SOCKET_PROTECT_FAILED",
		FailureState: RuntimeRunning,
	})
	defer restore()

	raw := &fakeRawConn{fd: 101}
	err := dialer.DefaultSocketHook("tcp", "1.1.1.1:443", raw)
	if err == nil {
		t.Fatal("socket hook unexpectedly succeeded")
	}
	if raw.controlCalls.Load() != 1 {
		t.Fatalf("raw control calls = %d want 1 (borrowed fd must not be closed in hook)", raw.controlCalls.Load())
	}
}

func TestProtectSkippedOnAPI22Plus(t *testing.T) {
	protector := &fakeSocketProtector{}
	restore := installSocketProtection(SocketProtectionOptions{
		APILevel:         22,
		Timeout:          3 * time.Second,
		Protector:        protector,
		Events:           &recordingSink{},
		ProcessProtected: true,
	})
	defer restore()

	if dialer.DefaultSocketHook != nil {
		t.Fatal("DefaultSocketHook should remain nil for API22+ process-protected mode")
	}
}

func TestProtectHookWorksWithRealDialerOncePerConnect(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen error: %v", err)
	}
	defer ln.Close()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		conn, acceptErr := ln.Accept()
		if acceptErr == nil {
			_ = conn.Close()
		}
	}()

	protector := &fakeSocketProtector{}
	restore := installSocketProtection(SocketProtectionOptions{
		APILevel:  21,
		Timeout:   time.Second,
		Protector: protector,
		Events:    &recordingSink{},
	})
	defer restore()

	conn, err := dialer.DialContext(context.Background(), "tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("DialContext error: %v", err)
	}
	_ = conn.Close()
	<-serverDone

	if protector.calls.Load() != 1 {
		t.Fatalf("protect calls = %d want 1", protector.calls.Load())
	}
}
