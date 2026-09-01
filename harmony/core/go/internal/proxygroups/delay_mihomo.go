package proxygroups

import (
	"context"
	"net/url"
	"strings"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

var (
	mihomoDelayProviderExpectedStatus = mustMihomoDelayExpectedStatus("200-299")
	mihomoDelayFallbackExpectedStatus = mustMihomoDelayExpectedStatus("204")
)

func newMihomoDelayRegistry() *mihomoRegistry {
	return newMihomoRegistry()
}

func NewMihomoDelayJobManager(opts ...DelayJobManagerOption) *DelayJobManager {
	return NewDelayJobManager(newMihomoDelayRegistry(), opts...)
}

func (r *mihomoRegistry) DelayNodes(groupName string) ([]DelayRuntimeNode, error) {
	group, err := r.delayGroup(groupName)
	if err != nil {
		return nil, err
	}

	members := group.Proxies()
	providers := group.Providers()
	nodes := make([]DelayRuntimeNode, 0, len(members))
	seen := make(map[string]struct{}, len(members))

	for _, member := range members {
		if member == nil {
			return nil, newModelError(ErrCodeProxyBridgeInvalid)
		}

		typeName, err := adapterTypeName(member.Type())
		if err != nil {
			return nil, err
		}
		if _, ok := seen[member.Name()]; ok {
			return nil, newModelError(ErrCodeProxyBridgeInvalid)
		}
		seen[member.Name()] = struct{}{}

		if _, ok := member.Adapter().(outboundgroup.ProxyGroup); ok {
			nodes = append(nodes, DelayRuntimeNode{
				Name:    member.Name(),
				Type:    typeName,
				IsGroup: true,
			})
			continue
		}

		if isUnsupportedDelayAdapterType(member.Type()) {
			nodes = append(nodes, DelayRuntimeNode{
				Name: member.Name(),
				Type: typeName,
			})
			continue
		}

		source, privateURL, expectedStatus, err := resolveDelayProbeTarget(member, providers)
		if err != nil {
			return nil, err
		}

		member := member
		nodes = append(nodes, DelayRuntimeNode{
			Name:   member.Name(),
			Type:   typeName,
			Source: cloneDelayURLSourcePtr(&source),
			Probe: func(ctx context.Context) (uint16, error) {
				return member.URLTest(ctx, privateURL, expectedStatus)
			},
		})
	}

	return nodes, nil
}

func (r *mihomoRegistry) delayGroup(groupName string) (outboundgroup.ProxyGroup, error) {
	proxies := r.snapshotProxies()
	if len(proxies) == 0 {
		return nil, newModelError(ErrCodeProxyRuntimeNotReady)
	}

	proxy := proxies[groupName]
	if proxy == nil {
		return nil, newModelError(ErrCodeProxyGroupNotFound)
	}

	group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		return nil, newModelError(ErrCodeProxyBridgeInvalid)
	}
	return group, nil
}

func resolveDelayProbeTarget(member C.Proxy, providers []P.ProxyProvider) (DelayURLSource, string, utils.IntRanges[uint16], error) {
	provider, err := firstDelayProviderForMember(member, providers)
	if err != nil {
		return "", "", nil, err
	}
	if provider != nil {
		privateURL := strings.TrimSpace(provider.HealthCheckURL())
		if isValidMihomoDelayURL(privateURL) {
			return DelayURLSourceProvider, privateURL, mihomoDelayProviderExpectedStatus, nil
		}
	}
	return DelayURLSourceFallback, DefaultDelayTestURL, mihomoDelayFallbackExpectedStatus, nil
}

func firstDelayProviderForMember(member C.Proxy, providers []P.ProxyProvider) (P.ProxyProvider, error) {
	for _, provider := range providers {
		if provider == nil {
			return nil, newModelError(ErrCodeProxyBridgeInvalid)
		}
		for _, providerProxy := range provider.Proxies() {
			if providerProxy == nil {
				return nil, newModelError(ErrCodeProxyBridgeInvalid)
			}
			if providerProxy == member {
				return provider, nil
			}
		}
	}
	return nil, nil
}

func isUnsupportedDelayAdapterType(adapterType C.AdapterType) bool {
	switch adapterType {
	case C.Direct, C.Reject, C.RejectDrop, C.Pass, C.PassRule, C.Rematch, C.Dns:
		return true
	default:
		return false
	}
}

func isValidMihomoDelayURL(raw string) bool {
	if raw == "" {
		return false
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return false
	}
	if parsed.Hostname() == "" {
		return false
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
		return true
	default:
		return false
	}
}

func mustMihomoDelayExpectedStatus(raw string) utils.IntRanges[uint16] {
	expected, err := utils.NewUnsignedRanges[uint16](raw)
	if err != nil {
		panic(err)
	}
	return expected
}
