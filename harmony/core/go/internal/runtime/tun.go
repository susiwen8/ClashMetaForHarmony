package runtime

import (
	"errors"
	"net/netip"

	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
)

var (
	errTunFDRequired     = errors.New("tun fd must be positive")
	errTunSessionRequired = errors.New("tun session id must not be empty")
	tunPrefix4           = netip.MustParsePrefix("10.111.222.1/30")
	tunPrefix6           = netip.MustParsePrefix("fd00:111:222::1/126")
)

func IsTunSessionRequired(err error) bool {
	return errors.Is(err, errTunSessionRequired)
}

type TunListenerHandle interface {
	Address() string
	Close() error
}

type TunListenerFactory func(options LC.Tun, tunnel C.Tunnel, additions ...adapterinbound.Addition) (TunListenerHandle, error)

func productionTunListenerFactory(options LC.Tun, tunnel C.Tunnel, additions ...adapterinbound.Addition) (TunListenerHandle, error) {
	return sing_tun.New(options, tunnel, additions...)
}

func buildTunConfig(fd int) LC.Tun {
	return LC.Tun{
		Enable:              true,
		Stack:               C.TunGvisor,
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
