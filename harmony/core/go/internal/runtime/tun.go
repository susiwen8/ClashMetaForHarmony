package runtime

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strings"
	"syscall"
	"time"

	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/dialer"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
)

var (
	errTunFDRequired      = errors.New("tun fd must be positive")
	errTunSessionRequired = errors.New("tun session id must not be empty")
	tunPrefix4            = netip.MustParsePrefix("10.111.222.1/30")
	tunPrefix6            = netip.MustParsePrefix("fd00:111:222::1/126")
	tunRouteProbeAddress  = net.JoinHostPort("192.0.2.1", "9")
)

const tunRouteLostCode = "NETWORK_LOST"
const tunRouteLostDetail = "Physical network route unavailable."

type TunRouteProbe func() error

func IsTunSessionRequired(err error) bool {
	return errors.Is(err, errTunSessionRequired)
}

type TunListenerHandle interface {
	Address() string
	Close() error
}

type TunListenerFactory func(options LC.Tun, tunnel C.Tunnel, additions ...adapterinbound.Addition) (TunListenerHandle, error)

func classifyTunListenerFailure(err error) []string {
	detail := ""
	if err != nil {
		detail = strings.ToLower(err.Error())
	}

	scope := "tun.listener.failure.unknown-scope"
	switch {
	case strings.Contains(detail, "configure tun interface"):
		scope = "tun.listener.failure.interface"
	case strings.Contains(detail, "unsupported on current platform"), strings.Contains(detail, "unknown stack"):
		scope = "tun.listener.failure.stack-create"
	case strings.Contains(detail, "setnonblock"),
		strings.Contains(detail, "unix.fstat"),
		strings.Contains(detail, "newreadvdispatcher"),
		strings.Contains(detail, "createinbounddispatcher"),
		strings.Contains(detail, "createnic"):
		scope = "tun.listener.failure.stack-start"
	}

	cause := "tun.listener.failure.unknown-cause"
	switch {
	case errors.Is(err, syscall.EBADF), strings.Contains(detail, "bad file descriptor"):
		cause = "tun.listener.failure.bad-fd"
	case errors.Is(err, syscall.EPERM), errors.Is(err, syscall.EACCES), strings.Contains(detail, "permission denied"):
		cause = "tun.listener.failure.permission"
	case errors.Is(err, syscall.EINVAL), strings.Contains(detail, "invalid argument"):
		cause = "tun.listener.failure.invalid"
	case errors.Is(err, syscall.ENOSYS),
		errors.Is(err, syscall.EOPNOTSUPP),
		strings.Contains(detail, "not supported"),
		strings.Contains(detail, "unsupported"):
		cause = "tun.listener.failure.unsupported"
	case errors.Is(err, syscall.EIO), strings.Contains(detail, "input/output error"):
		cause = "tun.listener.failure.io"
	}

	return []string{scope, cause}
}

func buildTunConfig(fd int) LC.Tun {
	return LC.Tun{
		Enable: true,
		Stack:  C.TunGvisor,
		// sing_tun.New parses explicit virtual addr:port strings and uses the
		// resulting endpoints for both TCP and UDP DNS hijack handling.
		DNSHijack:           []string{"10.111.222.2:53", "[fd00:111:222::2]:53"},
		AutoRoute:           false,
		AutoDetectInterface: false,
		AutoRedirect:        false,
		MTU:                 1500,
		Inet4Address:        []netip.Prefix{tunPrefix4},
		Inet6Address:        []netip.Prefix{tunPrefix6},
		FileDescriptor:      fd,
	}
}

func defaultTunRouteProbe() error {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	conn, err := dialer.DialContext(ctx, "udp", tunRouteProbeAddress)
	if err != nil {
		return err
	}
	return conn.Close()
}

func classifyTunRouteProbeFailure(err error) (TunFailure, bool) {
	switch {
	case errors.Is(err, syscall.ENETUNREACH),
		errors.Is(err, syscall.EHOSTUNREACH),
		errors.Is(err, syscall.ENETDOWN):
		return TunFailure{
			Code:   tunRouteLostCode,
			Detail: tunRouteLostDetail,
		}, true
	default:
		return TunFailure{}, false
	}
}
