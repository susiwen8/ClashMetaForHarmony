package proxygroups

import (
	"io"
	"os"
	"os/exec"
	"reflect"
	"sort"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	mihomoprovider "github.com/metacubex/mihomo/adapter/provider"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	mihomoexecutor "github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const realMihomoRuntimeChildEnv = "CMFA_PROXYGROUPS_REAL_RUNTIME_CHILD"

func TestServiceWithRealMihomoRuntime(t *testing.T) {
	if os.Getenv(realMihomoRuntimeChildEnv) == "1" {
		runRealMihomoRuntimeChild(t)
		return
	}

	originalManager := statistic.DefaultManager
	originalProxyKeys := snapshotProxyRegistryKeys(tunnel.Proxies())
	originalProviderKeys := snapshotProviderRegistryKeys(tunnel.Providers())

	if err := runSilentMihomoSubprocess(t, "^TestServiceWithRealMihomoRuntime$", realMihomoRuntimeChildEnv); err != nil {
		t.Fatal("real mihomo runtime subprocess failed")
	}

	if statistic.DefaultManager != originalManager {
		t.Fatal("parent statistic manager changed after subprocess")
	}
	if !reflect.DeepEqual(snapshotProxyRegistryKeys(tunnel.Proxies()), originalProxyKeys) {
		t.Fatal("parent proxy registry changed after subprocess")
	}
	if !reflect.DeepEqual(snapshotProviderRegistryKeys(tunnel.Providers()), originalProviderKeys) {
		t.Fatal("parent provider registry changed after subprocess")
	}
}

func runRealMihomoRuntimeChild(t *testing.T) {
	oldProxies := tunnel.Proxies()
	oldProviders := tunnel.Providers()
	oldManager := statistic.DefaultManager

	t.Cleanup(func() {
		tunnel.UpdateProxies(oldProxies, oldProviders)
		statistic.DefaultManager = oldManager
	})

	statistic.DefaultManager = &statistic.Manager{}

	cfg, err := mihomoexecutor.ParseWithBytes([]byte(`
mixed-port: 0
allow-lan: false
log-level: silent
mode: rule
proxy-groups:
  - name: group-a
    type: select
    proxies:
      - group-b
      - DIRECT
      - REJECT
  - name: group-b
    type: select
    proxies:
      - DIRECT
      - REJECT
  - name: group-load-balance
    type: load-balance
    proxies:
      - DIRECT
      - REJECT
rules:
  - MATCH,DIRECT
`))
	if err != nil {
		t.Fatalf("ParseWithBytes() unexpected error")
	}

	mihomoexecutor.ApplyConfig(cfg, true)

	service := NewService(nil)
	ctx := validQueryContext(nil)

	listPayload, err := service.ListGroups(ctx, false)
	if err != nil {
		t.Fatalf("ListGroups() unexpected error: %v", err)
	}
	listEnvelope := decodeGroupListEnvelope(t, listPayload)
	assertGroupRefs(t, listEnvelope.Groups, []GroupRef{
		{Name: "group-a", Type: "Selector"},
		{Name: "group-b", Type: "Selector"},
		{Name: "group-load-balance", Type: "LoadBalance"},
	})

	selectablePayload, err := service.ListGroups(ctx, true)
	if err != nil {
		t.Fatalf("ListGroups(selectable) unexpected error: %v", err)
	}
	selectableEnvelope := decodeGroupListEnvelope(t, selectablePayload)
	assertGroupRefs(t, selectableEnvelope.Groups, []GroupRef{
		{Name: "group-a", Type: "Selector"},
		{Name: "group-b", Type: "Selector"},
	})

	queryPayload, err := service.QueryGroup(ctx, "group-a")
	if err != nil {
		t.Fatalf("QueryGroup() unexpected error: %v", err)
	}
	queryEnvelope := decodeGroupSnapshotEnvelope(t, queryPayload)
	if queryEnvelope.Group.SelectedName != "group-b" {
		t.Fatalf("initial selection mismatch")
	}
	if len(queryEnvelope.Group.Nodes) != 3 {
		t.Fatalf("member count mismatch")
	}
	if !queryEnvelope.Group.Nodes[0].IsGroup {
		t.Fatalf("nested group flag mismatch")
	}

	selectPayload, err := service.Select(ctx, "group-a", "DIRECT")
	if err != nil {
		t.Fatalf("Select() unexpected error: %v", err)
	}
	selectEnvelope := decodeSelectionEnvelope(t, selectPayload)
	if selectEnvelope.PreviousName != "group-b" {
		t.Fatalf("previous selection mismatch")
	}
	if selectEnvelope.Group.SelectedName != "DIRECT" {
		t.Fatalf("selection mismatch")
	}
}

func TestMihomoRegistryActiveGroupsUsesGlobalProxyOrderAcrossProviders(t *testing.T) {
	oldProxies := tunnel.Proxies()
	oldProviders := tunnel.Providers()
	t.Cleanup(func() {
		tunnel.UpdateProxies(oldProxies, oldProviders)
	})

	direct := adapter.NewProxy(outbound.NewDirect())
	reject := adapter.NewProxy(outbound.NewReject())
	compatible := adapter.NewProxy(outbound.NewCompatible())

	groupA := mustNewSelectorProxy(t, "group-a", []C.Proxy{direct, reject})
	groupB := mustNewSelectorProxy(t, "group-b", []C.Proxy{direct, reject})
	groupC := mustNewSelectorProxy(t, "group-c", []C.Proxy{direct, reject})

	providerA := mustNewCompatibleProvider(t, "provider-a", []C.Proxy{groupA, direct})
	providerB := mustNewCompatibleProvider(t, "provider-b", []C.Proxy{groupC, groupB, reject})
	global, err := outboundgroup.NewSelector(
		outboundgroup.GroupCommonOption{Name: "GLOBAL"},
		outboundgroup.SelectorOption{},
		compatible,
		[]P.ProxyProvider{providerA, providerB},
	)
	if err != nil {
		t.Fatalf("NewSelector() unexpected error: %v", err)
	}

	tunnel.UpdateProxies(map[string]C.Proxy{
		"DIRECT":  direct,
		"REJECT":  reject,
		"group-a": groupA,
		"group-b": groupB,
		"group-c": groupC,
		"GLOBAL":  adapter.NewProxy(global),
	}, map[string]P.ProxyProvider{
		"provider-a": providerA,
		"provider-b": providerB,
	})

	groups, err := newMihomoRegistry().ActiveGroups()
	if err != nil {
		t.Fatalf("ActiveGroups() unexpected error: %v", err)
	}

	got := make([]string, 0, len(groups))
	for _, group := range groups {
		snapshot, err := group.Snapshot()
		if err != nil {
			t.Fatalf("Snapshot() unexpected error: %v", err)
		}
		got = append(got, snapshot.Name)
	}

	want := []string{"group-a", "group-c", "group-b"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("GLOBAL group order mismatch")
	}
}

func TestMihomoRegistryUsesFreshTunnelSnapshotAfterReload(t *testing.T) {
	oldProxies := tunnel.Proxies()
	oldProviders := tunnel.Providers()
	t.Cleanup(func() {
		tunnel.UpdateProxies(oldProxies, oldProviders)
	})

	registry := newMihomoRegistry()

	installMihomoRegistryRuntimeFixture(t, "alpha", []string{"alpha", "beta"})

	group, err := registry.Group("alpha")
	if err != nil {
		t.Fatalf("Group(alpha) unexpected error: %v", err)
	}
	alphaSnapshot, err := group.Snapshot()
	if err != nil {
		t.Fatalf("Group(alpha).Snapshot() unexpected error: %v", err)
	}
	if alphaSnapshot.Name != "alpha" {
		t.Fatalf("alpha snapshot name = %q want %q", alphaSnapshot.Name, "alpha")
	}

	alphaGroups, err := registry.ActiveGroups()
	if err != nil {
		t.Fatalf("ActiveGroups(alpha) unexpected error: %v", err)
	}
	alphaNames := snapshotRuntimeGroupNames(t, alphaGroups)
	if !reflect.DeepEqual(alphaNames, []string{"alpha", "beta"}) {
		t.Fatalf("alpha ActiveGroups() = %v want %v", alphaNames, []string{"alpha", "beta"})
	}

	installMihomoRegistryRuntimeFixture(t, "gamma", []string{"gamma", "delta"})

	group, err = registry.Group("gamma")
	if err != nil {
		t.Fatalf("Group(gamma) unexpected error: %v", err)
	}
	gammaSnapshot, err := group.Snapshot()
	if err != nil {
		t.Fatalf("Group(gamma).Snapshot() unexpected error: %v", err)
	}
	if gammaSnapshot.Name != "gamma" {
		t.Fatalf("gamma snapshot name = %q want %q", gammaSnapshot.Name, "gamma")
	}

	if _, err := registry.Group("alpha"); err == nil {
		t.Fatal("Group(alpha) unexpectedly succeeded after reload")
	} else {
		assertErrorCode(t, err, ErrCodeProxyGroupNotFound)
	}

	gammaGroups, err := registry.ActiveGroups()
	if err != nil {
		t.Fatalf("ActiveGroups(gamma) unexpected error: %v", err)
	}
	gammaNames := snapshotRuntimeGroupNames(t, gammaGroups)
	if !reflect.DeepEqual(gammaNames, []string{"gamma", "delta"}) {
		t.Fatalf("gamma ActiveGroups() = %v want %v", gammaNames, []string{"gamma", "delta"})
	}
}

func mustNewSelectorProxy(t *testing.T, name string, members []C.Proxy) C.Proxy {
	t.Helper()
	pd := mustNewCompatibleProvider(t, name+"-provider", members)
	selector, err := outboundgroup.NewSelector(
		outboundgroup.GroupCommonOption{Name: name},
		outboundgroup.SelectorOption{},
		members[0],
		[]P.ProxyProvider{pd},
	)
	if err != nil {
		t.Fatalf("NewSelector() unexpected error: %v", err)
	}
	return adapter.NewProxy(selector)
}

func mustNewCompatibleProvider(t *testing.T, name string, proxies []C.Proxy) P.ProxyProvider {
	t.Helper()
	hc := mihomoprovider.NewHealthCheck(proxies, "", 5000, 0, true, nil)
	pd, err := mihomoprovider.NewCompatibleProvider(name, proxies, hc)
	if err != nil {
		t.Fatalf("NewCompatibleProvider() unexpected error: %v", err)
	}
	return pd
}

func snapshotProxyRegistryKeys(proxies map[string]C.Proxy) []string {
	keys := make([]string, 0, len(proxies))
	for key := range proxies {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func snapshotProviderRegistryKeys(providers map[string]P.ProxyProvider) []string {
	keys := make([]string, 0, len(providers))
	for key := range providers {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func installMihomoRegistryRuntimeFixture(t *testing.T, primary string, orderedGroups []string) {
	t.Helper()

	direct := adapter.NewProxy(outbound.NewDirect())
	reject := adapter.NewProxy(outbound.NewReject())
	compatible := adapter.NewProxy(outbound.NewCompatible())

	proxyMap := map[string]C.Proxy{
		"DIRECT": direct,
		"REJECT": reject,
	}
	providerMap := map[string]P.ProxyProvider{}
	globalMembers := make([]C.Proxy, 0, len(orderedGroups))

	for _, name := range orderedGroups {
		group := mustNewSelectorProxy(t, name, []C.Proxy{direct, reject})
		proxyMap[name] = group
		globalMembers = append(globalMembers, group)
		providerMap[name+"-provider"] = mustNewCompatibleProvider(t, name+"-provider", []C.Proxy{group})
	}

	globalProvider := mustNewCompatibleProvider(t, "global-provider", globalMembers)
	global, err := outboundgroup.NewSelector(
		outboundgroup.GroupCommonOption{Name: "GLOBAL"},
		outboundgroup.SelectorOption{},
		compatible,
		[]P.ProxyProvider{globalProvider},
	)
	if err != nil {
		t.Fatalf("NewSelector(GLOBAL) unexpected error: %v", err)
	}
	proxyMap["GLOBAL"] = adapter.NewProxy(global)
	providerMap["global-provider"] = globalProvider

	tunnel.UpdateProxies(proxyMap, providerMap)

	if primary != orderedGroups[0] {
		t.Fatalf("fixture primary %q must match first ordered group %q", primary, orderedGroups[0])
	}
}

func snapshotRuntimeGroupNames(t *testing.T, groups []RuntimeGroup) []string {
	t.Helper()

	names := make([]string, 0, len(groups))
	for _, group := range groups {
		snapshot, err := group.Snapshot()
		if err != nil {
			t.Fatalf("Snapshot() unexpected error: %v", err)
		}
		names = append(names, snapshot.Name)
	}
	return names
}

func runSilentMihomoSubprocess(t *testing.T, testPattern, envKey string) error {
	t.Helper()

	cmd := exec.Command(os.Args[0], "-test.run="+testPattern)
	cmd.Env = append(os.Environ(), envKey+"=1")
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run()
}
