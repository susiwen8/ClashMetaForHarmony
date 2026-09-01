//go:build !with_gvisor

package runtime

import (
	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
)

func productionTunListenerFactory(options LC.Tun, tunnel C.Tunnel, additions ...adapterinbound.Addition) (TunListenerHandle, error) {
	return sing_tun.New(options, tunnel, additions...)
}
