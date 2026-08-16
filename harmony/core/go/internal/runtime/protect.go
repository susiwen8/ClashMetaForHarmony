package runtime

import (
	"fmt"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
)

type SocketProtector interface {
	ProtectSocket(fd int, timeout time.Duration) error
}

type SocketProtectorFunc func(fd int, timeout time.Duration) error

func (fn SocketProtectorFunc) ProtectSocket(fd int, timeout time.Duration) error {
	return fn(fd, timeout)
}

type SocketProtectionOptions struct {
	APILevel     int
	Timeout      time.Duration
	Protector    SocketProtector
	Events       EventSink
	FailureCode  string
	FailureState RuntimeState
	ProcessProtected bool
}

func installSocketProtection(options SocketProtectionOptions) func() {
	previous := dialer.DefaultSocketHook
	if options.Protector == nil || (options.APILevel >= 22 && options.ProcessProtected) {
		dialer.DefaultSocketHook = nil
		return func() {
			dialer.DefaultSocketHook = previous
		}
	}
	if options.Timeout <= 0 {
		options.Timeout = 3 * time.Second
	}
	if options.Events == nil {
		options.Events = DiscardEvents{}
	}
	if options.FailureCode == "" {
		options.FailureCode = "VPN_SOCKET_PROTECT_FAILED"
	}
	if options.FailureState == "" {
		options.FailureState = RuntimeRunning
	}

	dialer.DefaultSocketHook = func(network, address string, rawConn syscall.RawConn) error {
		fd := -1
		if err := rawConn.Control(func(value uintptr) {
			fd = int(value)
		}); err != nil {
			return err
		}
		if fd < 0 {
			return fmt.Errorf("socket protect: missing fd")
		}
		if err := options.Protector.ProtectSocket(fd, options.Timeout); err != nil {
			options.Events.Publish(RuntimeEvent{
				Kind:    "runtime.socket_protect_failed",
				State:   options.FailureState,
				Code:    options.FailureCode,
				Message: truncateUTF8(err.Error(), 256),
			})
			return err
		}
		return nil
	}

	return func() {
		dialer.DefaultSocketHook = previous
	}
}
