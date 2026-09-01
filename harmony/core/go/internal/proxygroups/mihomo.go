package proxygroups

import (
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type mihomoRegistry struct{}

type mihomoGroup struct {
	proxy C.Proxy
	group outboundgroup.ProxyGroup
}

func (g mihomoGroup) Reference() (RuntimeGroupReference, error) {
	typeName, err := adapterTypeName(g.proxy.Type())
	if err != nil {
		return RuntimeGroupReference{}, err
	}
	return RuntimeGroupReference{
		Name:   g.proxy.Name(),
		Type:   typeName,
		Hidden: g.group.Hidden(),
	}, nil
}

func newMihomoRegistry() *mihomoRegistry {
	return &mihomoRegistry{}
}

func (r *mihomoRegistry) ActiveGroups() ([]RuntimeGroup, error) {
	proxies := r.snapshotProxies()
	if len(proxies) == 0 {
		return nil, newModelError(ErrCodeProxyRuntimeNotReady)
	}

	globalProxy := proxies["GLOBAL"]
	if globalProxy == nil {
		return nil, newModelError(ErrCodeProxyRuntimeNotReady)
	}

	globalGroup, ok := globalProxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		return nil, newModelError(ErrCodeProxyBridgeInvalid)
	}

	ordered := globalGroup.Proxies()
	groups := make([]RuntimeGroup, 0, len(ordered))
	seen := make(map[string]struct{}, len(ordered))
	for _, proxy := range ordered {
		if proxy == nil {
			return nil, newModelError(ErrCodeProxyBridgeInvalid)
		}

		group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
		if !ok {
			continue
		}
		if _, ok := seen[proxy.Name()]; ok {
			return nil, newModelError(ErrCodeProxyBridgeInvalid)
		}
		seen[proxy.Name()] = struct{}{}
		groups = append(groups, mihomoGroup{proxy: proxy, group: group})
	}
	return groups, nil
}

func (r *mihomoRegistry) Group(name string) (RuntimeGroup, error) {
	proxies := r.snapshotProxies()
	if len(proxies) == 0 {
		return nil, newModelError(ErrCodeProxyRuntimeNotReady)
	}

	proxy := proxies[name]
	if proxy == nil {
		return nil, newModelError(ErrCodeProxyGroupNotFound)
	}

	group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		return nil, newModelError(ErrCodeProxyBridgeInvalid)
	}
	return mihomoGroup{proxy: proxy, group: group}, nil
}

func (*mihomoRegistry) CloseConnectionsForGroup(name string) {
	if statistic.DefaultManager == nil {
		return
	}

	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		if chainContains(tracker.Chains(), name) {
			_ = tracker.Close()
		}
		return true
	})
}

func (*mihomoRegistry) snapshotProxies() map[string]C.Proxy {
	return tunnel.Proxies()
}

func (g mihomoGroup) Snapshot() (RuntimeGroupSnapshot, error) {
	typeName, err := adapterTypeName(g.proxy.Type())
	if err != nil {
		return RuntimeGroupSnapshot{}, err
	}

	members := g.group.Proxies()
	nodes := make([]RuntimeNode, 0, len(members))
	for _, member := range members {
		if member == nil {
			return RuntimeGroupSnapshot{}, newModelError(ErrCodeProxyBridgeInvalid)
		}

		memberType, err := adapterTypeName(member.Type())
		if err != nil {
			return RuntimeGroupSnapshot{}, err
		}
		_, isGroup := member.Adapter().(outboundgroup.ProxyGroup)
		nodes = append(nodes, RuntimeNode{
			Name:    member.Name(),
			Type:    memberType,
			IsGroup: isGroup,
		})
	}

	return RuntimeGroupSnapshot{
		Name:    g.proxy.Name(),
		Type:    typeName,
		Hidden:  g.group.Hidden(),
		Current: g.group.Now(),
		Members: nodes,
	}, nil
}

func (g mihomoGroup) Set(name string) error {
	if g.proxy.Type() != C.Selector {
		return newModelError(ErrCodeProxyGroupNotSelectable)
	}

	selectable, ok := g.proxy.Adapter().(outboundgroup.SelectAble)
	if !ok {
		return newModelError(ErrCodeProxyBridgeInvalid)
	}
	if err := selectable.Set(name); err != nil {
		return newModelError(ErrCodeProxySelectionFailed)
	}
	return nil
}

func adapterTypeName(adapterType C.AdapterType) (string, error) {
	switch adapterType {
	case C.Direct:
		return "Direct", nil
	case C.Reject:
		return "Reject", nil
	case C.RejectDrop:
		return "RejectDrop", nil
	case C.Compatible:
		return "Compatible", nil
	case C.Pass:
		return "Pass", nil
	case C.PassRule:
		return "PassRule", nil
	case C.Rematch:
		return "Rematch", nil
	case C.Dns:
		return "Dns", nil
	case C.Relay:
		return "Relay", nil
	case C.Selector:
		return "Selector", nil
	case C.Fallback:
		return "Fallback", nil
	case C.URLTest:
		return "URLTest", nil
	case C.LoadBalance:
		return "LoadBalance", nil
	case C.Shadowsocks:
		return "Shadowsocks", nil
	case C.ShadowsocksR:
		return "ShadowsocksR", nil
	case C.Snell:
		return "Snell", nil
	case C.Socks5:
		return "Socks5", nil
	case C.Http:
		return "Http", nil
	case C.Vmess:
		return "Vmess", nil
	case C.Vless:
		return "Vless", nil
	case C.Trojan:
		return "Trojan", nil
	case C.Hysteria:
		return "Hysteria", nil
	case C.Hysteria2:
		return "Hysteria2", nil
	case C.WireGuard:
		return "WireGuard", nil
	case C.Tuic:
		return "Tuic", nil
	case C.Ssh:
		return "Ssh", nil
	case C.Mieru:
		return "Mieru", nil
	case C.AnyTLS:
		return "AnyTLS", nil
	case C.Sudoku:
		return "Sudoku", nil
	case C.Masque:
		return "Masque", nil
	case C.TrustTunnel:
		return "TrustTunnel", nil
	case C.ShadowQuic:
		return "ShadowQuic", nil
	case C.OpenVPN:
		return "OpenVPN", nil
	case C.Tailscale:
		return "Tailscale", nil
	case C.GostRelay:
		return "GostRelay", nil
	default:
		return "", newModelError(ErrCodeProxyBridgeInvalid)
	}
}

func chainContains(chain C.Chain, target string) bool {
	for _, name := range chain {
		if name == target {
			return true
		}
	}
	return false
}
