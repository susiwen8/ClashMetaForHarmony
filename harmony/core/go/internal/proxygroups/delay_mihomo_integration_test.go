package proxygroups

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	mihomoexecutor "github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const realMihomoDelayChildEnv = "CMFA_PROXYGROUPS_REAL_MIHOMO_DELAY_CHILD"

func TestMihomoDelayRegistryBuildsOrderedNodesAndPreservesSelection(t *testing.T) {
	memberProvider := &delayProbeCall{delay: 21}
	memberFallback := &delayProbeCall{delay: 34}
	providerURL := "https://provider.example.test/health"

	nested := adapter.NewProxy(&delayFakeGroup{
		name: "nested",
		typ:  C.Selector,
		now:  "nested-member",
		members: []C.Proxy{
			&delayTerminalProxy{name: "nested-member", typ: C.Socks5},
		},
	})
	direct := &delayTerminalProxy{name: "DIRECT", typ: C.Direct}
	reject := &delayTerminalProxy{name: "REJECT", typ: C.Reject}
	rejectDrop := &delayTerminalProxy{name: "REJECT-DROP", typ: C.RejectDrop}
	pass := &delayTerminalProxy{name: "PASS", typ: C.Pass}
	passRule := &delayTerminalProxy{name: "PASS-RULE", typ: C.PassRule}
	rematch := &delayTerminalProxy{name: "REMATCH", typ: C.Rematch}
	dns := &delayTerminalProxy{name: "DNS", typ: C.Dns}
	providerBacked := &delayTerminalProxy{name: "provider-backed", typ: C.Socks5, call: memberProvider}
	fallbackBacked := &delayTerminalProxy{name: "fallback-backed", typ: C.Trojan, call: memberFallback}

	group := &delayFakeGroup{
		name: "group-a",
		typ:  C.Selector,
		now:  "provider-backed",
		members: []C.Proxy{
			nested,
			direct,
			reject,
			rejectDrop,
			pass,
			passRule,
			rematch,
			dns,
			providerBacked,
			fallbackBacked,
		},
		providers: []P.ProxyProvider{
			&delayProviderStub{name: "provider-a", proxies: []C.Proxy{providerBacked}, url: providerURL},
			&delayProviderStub{name: "provider-b", proxies: []C.Proxy{fallbackBacked}, url: "not-a-url"},
		},
	}

	restore := installDelayTestGroup(t, "group-a", group)
	defer restore()

	before := group.Now()
	nodes, err := newMihomoDelayRegistry().DelayNodes("group-a")
	if err != nil {
		t.Fatalf("DelayNodes() unexpected error: %v", err)
	}
	if group.Now() != before {
		t.Fatal("DelayNodes() must not mutate selector state")
	}

	gotNames := make([]string, 0, len(nodes))
	for _, node := range nodes {
		gotNames = append(gotNames, node.Name)
	}
	wantNames := []string{
		"nested",
		"DIRECT",
		"REJECT",
		"REJECT-DROP",
		"PASS",
		"PASS-RULE",
		"REMATCH",
		"DNS",
		"provider-backed",
		"fallback-backed",
	}
	if !reflect.DeepEqual(gotNames, wantNames) {
		t.Fatalf("DelayNodes() order mismatch: got %v want %v", gotNames, wantNames)
	}

	for index := 0; index < 8; index++ {
		if nodes[index].Probe != nil {
			t.Fatalf("nodes[%d] unexpected probe for unsupported member %q", index, nodes[index].Name)
		}
	}
	if nodes[0].Source != nil {
		t.Fatalf("nested group source = %v, want nil", nodes[0].Source)
	}

	if nodes[8].Probe == nil {
		t.Fatal("provider-backed member must be testable")
	}
	if nodes[8].Source == nil || *nodes[8].Source != DelayURLSourceProvider {
		t.Fatalf("provider-backed source = %v want %q", nodes[8].Source, DelayURLSourceProvider)
	}
	if _, err := nodes[8].Probe(context.Background()); err != nil {
		t.Fatalf("provider-backed probe unexpected error: %v", err)
	}
	if memberProvider.calls != 1 || memberProvider.url != providerURL {
		t.Fatalf("provider-backed probe call = %+v", memberProvider)
	}
	if !memberProvider.expected.Check(201) || !memberProvider.expected.Check(250) || !memberProvider.expected.Check(298) {
		t.Fatal("provider-backed expected status must accept the full 200-299 range")
	}
	if memberProvider.expected.Check(199) || memberProvider.expected.Check(300) {
		t.Fatal("provider-backed expected status must reject values outside 200-299")
	}

	if nodes[9].Probe == nil {
		t.Fatal("fallback-backed member must be testable")
	}
	if nodes[9].Source == nil || *nodes[9].Source != DelayURLSourceFallback {
		t.Fatalf("fallback-backed source = %v want %q", nodes[9].Source, DelayURLSourceFallback)
	}
	if _, err := nodes[9].Probe(context.Background()); err != nil {
		t.Fatalf("fallback-backed probe unexpected error: %v", err)
	}
	if memberFallback.calls != 1 || memberFallback.url != DefaultDelayTestURL {
		t.Fatalf("fallback-backed probe call = %+v", memberFallback)
	}
	if !memberFallback.expected.Check(204) {
		t.Fatal("fallback expected status must accept 204")
	}
	if memberFallback.expected.Check(200) || memberFallback.expected.Check(205) {
		t.Fatal("fallback expected status must reject non-204 responses")
	}
	if group.Now() != before {
		t.Fatal("probing members must not mutate selector state")
	}
}

func TestMihomoDelayRegistryUsesFirstContainingProviderURLAndProviderExpectedRange(t *testing.T) {
	call := &delayProbeCall{delay: 19}
	member := &delayTerminalProxy{name: "provider-backed", typ: C.Http, call: call}
	group := &delayFakeGroup{
		name:    "group-a",
		typ:     C.Selector,
		now:     "provider-backed",
		members: []C.Proxy{member},
		providers: []P.ProxyProvider{
			&delayProviderStub{name: "provider-first", proxies: []C.Proxy{member}, url: "http://first.example.test/health"},
			&delayProviderStub{name: "provider-second", proxies: []C.Proxy{member}, url: "https://second.example.test/health"},
		},
	}

	restore := installDelayTestGroup(t, "group-a", group)
	defer restore()

	nodes, err := newMihomoDelayRegistry().DelayNodes("group-a")
	if err != nil {
		t.Fatalf("DelayNodes() unexpected error: %v", err)
	}
	if len(nodes) != 1 || nodes[0].Probe == nil {
		t.Fatalf("DelayNodes() returned unexpected nodes: %+v", nodes)
	}

	if _, err := nodes[0].Probe(context.Background()); err != nil {
		t.Fatalf("Probe() unexpected error: %v", err)
	}
	if call.url != "http://first.example.test/health" {
		t.Fatalf("Probe() url = %q want %q", call.url, "http://first.example.test/health")
	}
	if !call.expected.Check(201) || !call.expected.Check(298) || call.expected.Check(199) {
		t.Fatalf("provider expected status mismatch for first provider: %+v", call)
	}
}

func TestMihomoDelayRegistryMatchesProvidersByExactProxyInstance(t *testing.T) {
	tests := []struct {
		name       string
		providers  []P.ProxyProvider
		wantURL    string
		wantSource DelayURLSource
	}{
		{
			name: "same-name different instance does not steal provider ownership",
			providers: []P.ProxyProvider{
				&delayProviderStub{name: "provider-wrong", url: "https://wrong.example.test/health"},
				&delayProviderStub{name: "provider-right", url: "https://right.example.test/health"},
			},
			wantURL:    "https://right.example.test/health",
			wantSource: DelayURLSourceProvider,
		},
		{
			name: "same-name different instance falls back when exact instance is absent",
			providers: []P.ProxyProvider{
				&delayProviderStub{name: "provider-wrong", url: "https://wrong.example.test/health"},
			},
			wantURL:    DefaultDelayTestURL,
			wantSource: DelayURLSourceFallback,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			call := &delayProbeCall{delay: 23}
			member := &delayTerminalProxy{name: "shared-name", typ: C.Socks5, call: call}
			otherInstanceSameName := &delayTerminalProxy{name: "shared-name", typ: C.Socks5}

			providers := make([]P.ProxyProvider, 0, len(tc.providers))
			for index, provider := range tc.providers {
				stub := provider.(*delayProviderStub)
				providerProxies := []C.Proxy{otherInstanceSameName}
				if index == len(tc.providers)-1 && tc.wantSource == DelayURLSourceProvider {
					providerProxies = []C.Proxy{member}
				}
				providers = append(providers, &delayProviderStub{
					name:    stub.name,
					proxies: providerProxies,
					url:     stub.url,
				})
			}

			group := &delayFakeGroup{
				name:      "group-a",
				typ:       C.Selector,
				now:       "shared-name",
				members:   []C.Proxy{member},
				providers: providers,
			}

			restore := installDelayTestGroup(t, "group-a", group)
			defer restore()

			nodes, err := newMihomoDelayRegistry().DelayNodes("group-a")
			if err != nil {
				t.Fatalf("DelayNodes() unexpected error: %v", err)
			}
			if len(nodes) != 1 || nodes[0].Probe == nil {
				t.Fatalf("DelayNodes() returned unexpected nodes: %+v", nodes)
			}
			if nodes[0].Source == nil || *nodes[0].Source != tc.wantSource {
				t.Fatalf("node source = %v want %q", nodes[0].Source, tc.wantSource)
			}

			if _, err := nodes[0].Probe(context.Background()); err != nil {
				t.Fatalf("Probe() unexpected error: %v", err)
			}
			if call.url != tc.wantURL {
				t.Fatalf("Probe() url = %q want %q", call.url, tc.wantURL)
			}
		})
	}
}

func TestMihomoDelayRegistryFallsBackForInvalidOrMissingProviderURL(t *testing.T) {
	tests := []struct {
		name       string
		providers  []P.ProxyProvider
		wantSource DelayURLSource
	}{
		{
			name: "invalid first provider URL does not scan later providers",
			providers: []P.ProxyProvider{
				&delayProviderStub{name: "provider-first", proxies: nil, url: "ftp://ignored"},
				&delayProviderStub{name: "provider-second", proxies: nil, url: "https://second.example.test/health"},
			},
			wantSource: DelayURLSourceFallback,
		},
		{
			name: "empty provider URL falls back",
			providers: []P.ProxyProvider{
				&delayProviderStub{name: "provider-empty", proxies: nil, url: ""},
			},
			wantSource: DelayURLSourceFallback,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			call := &delayProbeCall{delay: 8}
			member := &delayTerminalProxy{name: "fallback-backed", typ: C.Vmess, call: call}
			providers := make([]P.ProxyProvider, len(tc.providers))
			for i, provider := range tc.providers {
				stub := provider.(*delayProviderStub)
				providers[i] = &delayProviderStub{name: stub.name, proxies: []C.Proxy{member}, url: stub.url}
			}

			group := &delayFakeGroup{
				name:      "group-a",
				typ:       C.Selector,
				now:       "fallback-backed",
				members:   []C.Proxy{member},
				providers: providers,
			}

			restore := installDelayTestGroup(t, "group-a", group)
			defer restore()

			nodes, err := newMihomoDelayRegistry().DelayNodes("group-a")
			if err != nil {
				t.Fatalf("DelayNodes() unexpected error: %v", err)
			}
			if len(nodes) != 1 || nodes[0].Probe == nil {
				t.Fatalf("DelayNodes() returned unexpected nodes: %+v", nodes)
			}
			if nodes[0].Source == nil || *nodes[0].Source != tc.wantSource {
				t.Fatalf("node source = %v want %q", nodes[0].Source, tc.wantSource)
			}

			if _, err := nodes[0].Probe(context.Background()); err != nil {
				t.Fatalf("Probe() unexpected error: %v", err)
			}
			if call.url != DefaultDelayTestURL {
				t.Fatalf("Probe() url = %q want %q", call.url, DefaultDelayTestURL)
			}
			if !call.expected.Check(204) || call.expected.Check(200) {
				t.Fatalf("fallback expected status mismatch: %+v", call)
			}
		})
	}
}

func TestIsValidMihomoDelayURLRequiresHTTPHTTPSAndHostname(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want bool
	}{
		{name: "empty", raw: "", want: false},
		{name: "only port", raw: "https://:443/path", want: false},
		{name: "missing host", raw: "https:///path", want: false},
		{name: "ftp rejected", raw: "ftp://example.test/path", want: false},
		{name: "valid https", raw: "https://example.test/path", want: true},
		{name: "valid userinfo", raw: "https://user:pass@example.test/path", want: true},
		{name: "valid fragment", raw: "http://example.test/path#fragment", want: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := isValidMihomoDelayURL(tc.raw); got != tc.want {
				t.Fatalf("isValidMihomoDelayURL(%q) = %v want %v", tc.raw, got, tc.want)
			}
		})
	}
}

func TestMihomoDelayRegistryRejectsMalformedMembersAndDuplicates(t *testing.T) {
	tests := []struct {
		name    string
		group   *delayFakeGroup
		wantErr ErrorCode
	}{
		{
			name: "duplicate member names",
			group: &delayFakeGroup{
				name: "group-a",
				typ:  C.Selector,
				now:  "dup",
				members: []C.Proxy{
					&delayTerminalProxy{name: "dup", typ: C.Socks5},
					&delayTerminalProxy{name: "dup", typ: C.Trojan},
				},
			},
			wantErr: ErrCodeProxyBridgeInvalid,
		},
		{
			name: "nil member",
			group: &delayFakeGroup{
				name:    "group-a",
				typ:     C.Selector,
				now:     "missing",
				members: []C.Proxy{nil},
			},
			wantErr: ErrCodeProxyBridgeInvalid,
		},
		{
			name: "unknown adapter type",
			group: &delayFakeGroup{
				name: "group-a",
				typ:  C.Selector,
				now:  "mystery",
				members: []C.Proxy{
					&delayTerminalProxy{name: "mystery", typ: C.AdapterType(255)},
				},
			},
			wantErr: ErrCodeProxyBridgeInvalid,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			restore := installDelayTestGroup(t, "group-a", tc.group)
			defer restore()

			_, err := newMihomoDelayRegistry().DelayNodes("group-a")
			assertErrorCode(t, err, tc.wantErr)
		})
	}
}

func TestMihomoDelayRegistryAndManagerUseFreshTunnelSnapshotAfterReload(t *testing.T) {
	oldProxies := tunnel.Proxies()
	oldProviders := tunnel.Providers()
	t.Cleanup(func() {
		tunnel.UpdateProxies(oldProxies, oldProviders)
	})

	registry := newMihomoDelayRegistry()
	manager := NewDelayJobManager(registry, WithDelayJobIDSource(delayFixedIDSource(
		"33333333333333333333333333333333",
		"44444444444444444444444444444444",
	)))

	installDelayReloadFixture(t, "node-a")

	nodesA, err := registry.DelayNodes("delay-group")
	if err != nil {
		t.Fatalf("DelayNodes(A) unexpected error: %v", err)
	}
	if len(nodesA) != 1 || nodesA[0].Name != "node-a" {
		t.Fatalf("DelayNodes(A) = %+v, want node-a", nodesA)
	}
	jobA, err := manager.Start(validQueryContext(nil), "delay-group")
	if err != nil {
		t.Fatalf("Start(A) unexpected error: %v", err)
	}
	finalA := waitDelayTerminalSnapshot(t, manager, jobA.JobID)
	if len(finalA.Nodes) != 1 || finalA.Nodes[0].Name != "node-a" {
		t.Fatalf("finalA nodes = %+v, want node-a", finalA.Nodes)
	}

	installDelayReloadFixture(t, "node-b")

	nodesB, err := registry.DelayNodes("delay-group")
	if err != nil {
		t.Fatalf("DelayNodes(B) unexpected error: %v", err)
	}
	if len(nodesB) != 1 || nodesB[0].Name != "node-b" {
		t.Fatalf("DelayNodes(B) = %+v, want node-b", nodesB)
	}
	jobB, err := manager.Start(validQueryContext(nil), "delay-group")
	if err != nil {
		t.Fatalf("Start(B) unexpected error: %v", err)
	}
	finalB := waitDelayTerminalSnapshot(t, manager, jobB.JobID)
	if len(finalB.Nodes) != 1 || finalB.Nodes[0].Name != "node-b" {
		t.Fatalf("finalB nodes = %+v, want node-b", finalB.Nodes)
	}
}

func TestNewMihomoDelayJobManagerUsesInjectedOptionsAndFreshRuntime(t *testing.T) {
	oldProxies := tunnel.Proxies()
	oldProviders := tunnel.Providers()
	t.Cleanup(func() {
		tunnel.UpdateProxies(oldProxies, oldProviders)
	})

	manager := NewMihomoDelayJobManager(WithDelayJobIDSource(delayFixedIDSource(
		"55555555555555555555555555555555",
		"66666666666666666666666666666666",
	)))

	installDelayReloadFixture(t, "node-a")

	jobA, err := manager.Start(validQueryContext(nil), "delay-group")
	if err != nil {
		t.Fatalf("Start(A) unexpected error: %v", err)
	}
	if jobA.JobID != "55555555555555555555555555555555" {
		t.Fatalf("jobA.JobID = %q want %q", jobA.JobID, "55555555555555555555555555555555")
	}
	finalA := waitDelayTerminalSnapshot(t, manager, jobA.JobID)
	if len(finalA.Nodes) != 1 || finalA.Nodes[0].Name != "node-a" {
		t.Fatalf("finalA nodes = %+v, want node-a", finalA.Nodes)
	}

	installDelayReloadFixture(t, "node-b")

	jobB, err := manager.Start(validQueryContext(nil), "delay-group")
	if err != nil {
		t.Fatalf("Start(B) unexpected error: %v", err)
	}
	if jobB.JobID != "66666666666666666666666666666666" {
		t.Fatalf("jobB.JobID = %q want %q", jobB.JobID, "66666666666666666666666666666666")
	}
	finalB := waitDelayTerminalSnapshot(t, manager, jobB.JobID)
	if len(finalB.Nodes) != 1 || finalB.Nodes[0].Name != "node-b" {
		t.Fatalf("finalB nodes = %+v, want node-b", finalB.Nodes)
	}
}

func TestDelayServiceWithRealMihomoRuntime(t *testing.T) {
	if os.Getenv(realMihomoDelayChildEnv) == "1" {
		runRealMihomoDelayChild(t)
		return
	}

	originalManager := statistic.DefaultManager
	originalProxyKeys := snapshotProxyRegistryKeys(tunnel.Proxies())
	originalProviderKeys := snapshotProviderRegistryKeys(tunnel.Providers())

	if err := runSilentMihomoSubprocess(t, "^TestDelayServiceWithRealMihomoRuntime$", realMihomoDelayChildEnv); err != nil {
		t.Fatal("real mihomo delay subprocess failed")
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

func runRealMihomoDelayChild(t *testing.T) {
	oldProxies := tunnel.Proxies()
	oldProviders := tunnel.Providers()
	oldManager := statistic.DefaultManager
	t.Cleanup(func() {
		tunnel.UpdateProxies(oldProxies, oldProviders)
		statistic.DefaultManager = oldManager
	})

	statistic.DefaultManager = &statistic.Manager{}

	t.Run("provider URL success", func(t *testing.T) {
		origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/provider-ok" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			time.Sleep(10 * time.Millisecond)
			w.WriteHeader(http.StatusCreated)
		}))
		defer origin.Close()

		group := applyRealMihomoDelayConfig(t, origin.URL+"/provider-ok")
		before := group.Now()

		manager := NewDelayJobManager(newMihomoDelayRegistry(), WithDelayJobIDSource(delayFixedIDSource("11111111111111111111111111111111")))
		job, err := manager.Start(validQueryContext(nil), "delay-group")
		if err != nil {
			t.Fatalf("Start() unexpected error: %v", err)
		}

		final := waitDelayTerminalSnapshot(t, manager, job.JobID)
		if final.State != DelayJobStateCompleted {
			t.Fatalf("final state = %q want %q", final.State, DelayJobStateCompleted)
		}
		if final.AvailableCount == 0 {
			t.Fatalf("expected at least one available node: %+v", final)
		}
		foundProviderNode := false
		for _, node := range final.Nodes {
			if node.State == DelayNodeStateAvailable && node.Source != nil && *node.Source == DelayURLSourceProvider {
				foundProviderNode = true
				break
			}
		}
		if !foundProviderNode {
			t.Fatalf("expected at least one provider-backed available node: %+v", final)
		}
		if group.Now() != before {
			t.Fatal("delay probing must not mutate the real selector choice")
		}
	})

	t.Run("blocking origin cancels", func(t *testing.T) {
		origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/block" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			<-r.Context().Done()
		}))
		defer origin.Close()

		group := applyRealMihomoDelayConfig(t, origin.URL+"/block")
		before := group.Now()

		manager := NewDelayJobManager(newMihomoDelayRegistry(), WithDelayJobIDSource(delayFixedIDSource("22222222222222222222222222222222")))
		job, err := manager.Start(validQueryContext(nil), "delay-group")
		if err != nil {
			t.Fatalf("Start() unexpected error: %v", err)
		}

		waitForDelayTestingNode(t, manager, job.JobID)
		cancelled, err := manager.Cancel(job.JobID)
		if err != nil {
			t.Fatalf("Cancel() unexpected error: %v", err)
		}
		if cancelled.State != DelayJobStateCancelled {
			t.Fatalf("cancelled state = %q want %q", cancelled.State, DelayJobStateCancelled)
		}
		if cancelled.CancelledCount == 0 {
			t.Fatalf("expected cancelled node in final snapshot: %+v", cancelled)
		}
		if group.Now() != before {
			t.Fatal("cancelling delay probing must not mutate the real selector choice")
		}
	})
}

func applyRealMihomoDelayConfig(t *testing.T, healthURL string) outboundGroup {
	t.Helper()

	socksA := startDelaySOCKS5Proxy(t)
	t.Cleanup(func() { _ = socksA.Close() })
	socksB := startDelaySOCKS5Proxy(t)
	t.Cleanup(func() { _ = socksB.Close() })

	providerPath := writeDelayProviderFile(t, []delaySocksProxySpec{
		{name: "provider-a", address: socksA.Addr().String()},
		{name: "provider-b", address: socksB.Addr().String()},
	})

	cfg, err := mihomoexecutor.ParseWithBytes([]byte(fmt.Sprintf(`
mixed-port: 0
allow-lan: false
log-level: silent
mode: rule
proxy-providers:
  remote:
    type: file
    path: %q
    health-check:
      enable: false
      url: %q
proxy-groups:
  - name: nested
    type: select
    proxies:
      - DIRECT
      - REJECT
  - name: delay-group
    type: select
    use:
      - remote
  - name: builtins
    type: select
    proxies:
      - nested
      - DIRECT
      - REJECT
rules:
  - MATCH,DIRECT
`, providerPath, healthURL)))
	if err != nil {
		t.Fatalf("ParseWithBytes() unexpected error: %v", err)
	}

	mihomoexecutor.ApplyConfig(cfg, true)

	remoteProvider := tunnel.Providers()["remote"]
	if remoteProvider == nil {
		t.Fatal("remote provider missing after ApplyConfig()")
	}
	if remoteProvider.HealthCheckURL() != healthURL {
		t.Fatalf("remote provider HealthCheckURL() = %q want %q", remoteProvider.HealthCheckURL(), healthURL)
	}

	proxy := tunnel.Proxies()["delay-group"]
	if proxy == nil {
		t.Fatal("delay-group missing after ApplyConfig()")
	}
	group, ok := proxy.Adapter().(outboundGroup)
	if !ok {
		t.Fatal("delay-group adapter missing ProxyGroup interface")
	}
	return group
}

type outboundGroup interface {
	Now() string
}

type delaySocksProxySpec struct {
	name    string
	address string
}

func writeDelayProviderFile(t *testing.T, proxies []delaySocksProxySpec) string {
	t.Helper()

	payload := struct {
		Proxies []map[string]any `json:"proxies"`
	}{
		Proxies: make([]map[string]any, 0, len(proxies)),
	}
	for _, proxy := range proxies {
		host, port, err := net.SplitHostPort(proxy.address)
		if err != nil {
			t.Fatalf("SplitHostPort(%q): %v", proxy.address, err)
		}
		payload.Proxies = append(payload.Proxies, map[string]any{
			"name":   proxy.name,
			"type":   "socks5",
			"server": host,
			"port":   mustDelayPort(t, port),
		})
	}

	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("Marshal provider payload: %v", err)
	}

	dir := filepath.Join(C.Path.HomeDir(), "delay-provider-test")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("MkdirAll(%q): %v", dir, err)
	}
	path := filepath.Join(dir, fmt.Sprintf("provider-%d.yaml", time.Now().UnixNano()))
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatalf("WriteFile(%q): %v", path, err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })
	return path
}

func mustDelayPort(t *testing.T, raw string) int {
	t.Helper()

	var port int
	if _, err := fmt.Sscanf(raw, "%d", &port); err != nil {
		t.Fatalf("parse port %q: %v", raw, err)
	}
	return port
}

func waitForDelayTestingNode(t *testing.T, manager *DelayJobManager, jobID string) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		snapshot, err := manager.Read(jobID)
		if err == nil {
			for _, node := range snapshot.Nodes {
				if node.State == DelayNodeStateTesting {
					return
				}
			}
			if snapshot.State != DelayJobStateRunning {
				t.Fatalf("snapshot reached terminal state before testing node observed: %+v", snapshot)
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting for a testing node")
}

func installDelayTestGroup(t *testing.T, groupName string, group *delayFakeGroup) func() {
	t.Helper()

	oldProxies := tunnel.Proxies()
	oldProviders := tunnel.Providers()
	tunnel.UpdateProxies(map[string]C.Proxy{
		groupName: adapter.NewProxy(group),
	}, map[string]P.ProxyProvider{})
	return func() {
		tunnel.UpdateProxies(oldProxies, oldProviders)
	}
}

func installDelayReloadFixture(t *testing.T, memberName string) {
	t.Helper()

	call := &delayProbeCall{delay: 11}
	member := &delayTerminalProxy{name: memberName, typ: C.Socks5, call: call}
	group := &delayFakeGroup{
		name:      "delay-group",
		typ:       C.Selector,
		now:       memberName,
		members:   []C.Proxy{member},
		providers: []P.ProxyProvider{&delayProviderStub{name: memberName + "-provider", proxies: []C.Proxy{member}, url: "https://provider.example.test/health"}},
	}

	tunnel.UpdateProxies(map[string]C.Proxy{
		"delay-group": adapter.NewProxy(group),
	}, map[string]P.ProxyProvider{})
}

type delayProbeCall struct {
	url      string
	expected utils.IntRanges[uint16]
	calls    int
	delay    uint16
	err      error
}

type delayTerminalProxy struct {
	name string
	typ  C.AdapterType
	call *delayProbeCall
}

func (p *delayTerminalProxy) Name() string { return p.name }

func (p *delayTerminalProxy) Type() C.AdapterType { return p.typ }

func (*delayTerminalProxy) Addr() string { return "" }

func (*delayTerminalProxy) SupportUDP() bool { return false }

func (*delayTerminalProxy) ProxyInfo() C.ProxyInfo { return C.ProxyInfo{} }

func (*delayTerminalProxy) MarshalJSON() ([]byte, error) { return []byte(`{}`), nil }

func (*delayTerminalProxy) DialContext(context.Context, *C.Metadata) (C.Conn, error) {
	return nil, C.ErrNotSupport
}

func (*delayTerminalProxy) ListenPacketContext(context.Context, *C.Metadata) (C.PacketConn, error) {
	return nil, C.ErrNotSupport
}

func (*delayTerminalProxy) SupportUOT() bool { return false }

func (*delayTerminalProxy) IsL3Protocol(*C.Metadata) bool { return false }

func (*delayTerminalProxy) Unwrap(*C.Metadata, bool) C.Proxy { return nil }

func (*delayTerminalProxy) Close() error { return nil }

func (p *delayTerminalProxy) Adapter() C.ProxyAdapter { return p }

func (*delayTerminalProxy) AliveForTestUrl(string) bool { return false }

func (*delayTerminalProxy) DelayHistory() []C.DelayHistory { return nil }

func (*delayTerminalProxy) ExtraDelayHistories() map[string]C.ProxyState { return nil }

func (*delayTerminalProxy) LastDelayForTestUrl(string) uint16 { return 0 }

func (p *delayTerminalProxy) URLTest(_ context.Context, url string, expected utils.IntRanges[uint16]) (uint16, error) {
	if p.call == nil {
		return 1, nil
	}
	p.call.url = url
	p.call.expected = expected
	p.call.calls++
	return p.call.delay, p.call.err
}

type delayFakeGroup struct {
	name      string
	typ       C.AdapterType
	now       string
	hidden    bool
	members   []C.Proxy
	providers []P.ProxyProvider
}

func (g *delayFakeGroup) Name() string { return g.name }

func (g *delayFakeGroup) Type() C.AdapterType { return g.typ }

func (*delayFakeGroup) Addr() string { return "" }

func (*delayFakeGroup) SupportUDP() bool { return false }

func (*delayFakeGroup) ProxyInfo() C.ProxyInfo { return C.ProxyInfo{} }

func (*delayFakeGroup) MarshalJSON() ([]byte, error) { return []byte(`{}`), nil }

func (*delayFakeGroup) DialContext(context.Context, *C.Metadata) (C.Conn, error) {
	return nil, C.ErrNotSupport
}

func (*delayFakeGroup) ListenPacketContext(context.Context, *C.Metadata) (C.PacketConn, error) {
	return nil, C.ErrNotSupport
}

func (*delayFakeGroup) SupportUOT() bool { return false }

func (*delayFakeGroup) IsL3Protocol(*C.Metadata) bool { return false }

func (*delayFakeGroup) Unwrap(*C.Metadata, bool) C.Proxy { return nil }

func (*delayFakeGroup) Close() error { return nil }

func (g *delayFakeGroup) Providers() []P.ProxyProvider { return g.providers }

func (g *delayFakeGroup) Proxies() []C.Proxy { return g.members }

func (g *delayFakeGroup) Now() string { return g.now }

func (*delayFakeGroup) Touch() {}

func (g *delayFakeGroup) Hidden() bool { return g.hidden }

func (*delayFakeGroup) Icon() string { return "" }

func (*delayFakeGroup) URLTest(context.Context, string, utils.IntRanges[uint16]) (map[string]uint16, error) {
	return nil, C.ErrNotSupport
}

type delayProviderStub struct {
	name    string
	proxies []C.Proxy
	url     string
}

func (p *delayProviderStub) Name() string { return p.name }

func (*delayProviderStub) VehicleType() P.VehicleType { return P.Compatible }

func (*delayProviderStub) Type() P.ProviderType { return P.Proxy }

func (*delayProviderStub) Initial() error { return nil }

func (*delayProviderStub) Update() error { return nil }

func (p *delayProviderStub) Proxies() []C.Proxy { return p.proxies }

func (p *delayProviderStub) Count() int { return len(p.proxies) }

func (*delayProviderStub) Touch() {}

func (*delayProviderStub) HealthCheck() {}

func (*delayProviderStub) Version() uint32 { return 1 }

func (*delayProviderStub) RegisterHealthCheckTask(string, utils.IntRanges[uint16], string, uint) {}

func (p *delayProviderStub) HealthCheckURL() string { return p.url }

func startDelaySOCKS5Proxy(t *testing.T) net.Listener {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen SOCKS5 proxy: %v", err)
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go handleDelaySOCKS5ProxyConn(conn)
		}
	}()
	return listener
}

func handleDelaySOCKS5ProxyConn(client net.Conn) {
	defer client.Close()

	header := make([]byte, 2)
	if _, err := io.ReadFull(client, header); err != nil {
		return
	}
	if header[0] != 0x05 {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(client, methods); err != nil {
		return
	}
	_, _ = client.Write([]byte{0x05, 0x00})

	requestHeader := make([]byte, 4)
	if _, err := io.ReadFull(client, requestHeader); err != nil {
		return
	}
	if requestHeader[0] != 0x05 || requestHeader[1] != 0x01 {
		return
	}

	targetHost, targetPort, err := readDelaySOCKS5Target(client, requestHeader[3])
	if err != nil {
		return
	}
	upstream, err := net.Dial("tcp", net.JoinHostPort(targetHost, targetPort))
	if err != nil {
		_, _ = client.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer upstream.Close()

	bindAddr := upstream.LocalAddr().(*net.TCPAddr)
	replyAddr := bindAddr.IP.To4()
	if replyAddr == nil {
		replyAddr = net.IPv4zero
	}
	_, _ = client.Write([]byte{
		0x05, 0x00, 0x00, 0x01,
		replyAddr[0], replyAddr[1], replyAddr[2], replyAddr[3],
		byte(bindAddr.Port >> 8), byte(bindAddr.Port),
	})
	proxyDelayStream(bufio.NewReader(client), client, upstream)
}

func readDelaySOCKS5Target(client net.Conn, atyp byte) (string, string, error) {
	switch atyp {
	case 0x01:
		addr := make([]byte, 4)
		if _, err := io.ReadFull(client, addr); err != nil {
			return "", "", err
		}
		port := make([]byte, 2)
		if _, err := io.ReadFull(client, port); err != nil {
			return "", "", err
		}
		return net.IP(addr).String(), fmt.Sprintf("%d", int(port[0])<<8|int(port[1])), nil
	case 0x03:
		length := make([]byte, 1)
		if _, err := io.ReadFull(client, length); err != nil {
			return "", "", err
		}
		host := make([]byte, int(length[0]))
		if _, err := io.ReadFull(client, host); err != nil {
			return "", "", err
		}
		port := make([]byte, 2)
		if _, err := io.ReadFull(client, port); err != nil {
			return "", "", err
		}
		return string(host), fmt.Sprintf("%d", int(port[0])<<8|int(port[1])), nil
	default:
		return "", "", fmt.Errorf("unsupported ATYP %d", atyp)
	}
}

func proxyDelayStream(buffered *bufio.Reader, client net.Conn, upstream net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(upstream, buffered)
		if tcpConn, ok := upstream.(*net.TCPConn); ok {
			_ = tcpConn.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, upstream)
		if tcpConn, ok := client.(*net.TCPConn); ok {
			_ = tcpConn.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
	<-done
}
