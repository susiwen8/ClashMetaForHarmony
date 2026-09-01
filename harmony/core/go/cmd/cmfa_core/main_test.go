package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	configpkg "github.com/clashmetaforandroid/harmony/core/go/internal/config"
	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
	"github.com/clashmetaforandroid/harmony/core/go/internal/version"
	mihomocfg "github.com/metacubex/mihomo/config"
	mihomoexecutor "github.com/metacubex/mihomo/hub/executor"
)

func TestSanitizeTunTraceForBridgeRedactsLegacyAddressesAndKeepsHashes(t *testing.T) {
	source := runtimepkg.TunTrace{
		SessionID:            "session-1",
		TraceID:              "trace-1",
		Ingress:              "tun",
		Protocol:             "tcp",
		SourceAddress:        "10.0.0.2:45678",
		DestinationAddress:   "1.1.1.1:443",
		HashedTuple:          "tuple-hash",
		CorrelationHash:      "corr-hash",
		DestinationHash:      "dest-hash",
		OutboundTerminalHash: "terminal-hash",
		OutboundChainHash:    "chain-hash",
		OutboundChainLength:  3,
	}

	sanitized := sanitizeTunTraceForBridge(source)

	if got := sanitized.SourceAddress; got != "" {
		t.Fatalf("source_address = %q want empty", got)
	}
	if got := sanitized.DestinationAddress; got != "" {
		t.Fatalf("destination_address = %q want empty", got)
	}
	if got := sanitized.HashedTuple; got != source.HashedTuple {
		t.Fatalf("hashed_tuple = %q want %q", got, source.HashedTuple)
	}
	if got := sanitized.CorrelationHash; got != source.CorrelationHash {
		t.Fatalf("correlation_hash = %q want %q", got, source.CorrelationHash)
	}
	if got := sanitized.DestinationHash; got != source.DestinationHash {
		t.Fatalf("destination_hash = %q want %q", got, source.DestinationHash)
	}
	if got := sanitized.OutboundTerminalHash; got != source.OutboundTerminalHash {
		t.Fatalf("outbound_terminal_hash = %q want %q", got, source.OutboundTerminalHash)
	}
	if got := sanitized.OutboundChainHash; got != source.OutboundChainHash {
		t.Fatalf("outbound_chain_hash = %q want %q", got, source.OutboundChainHash)
	}
	if got := sanitized.OutboundChainLength; got != source.OutboundChainLength {
		t.Fatalf("outbound_chain_length = %d want %d", got, source.OutboundChainLength)
	}
}

func TestWriteTunTraceUsesSanitizedBridgeTrace(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("os.ReadFile(main.go) failed: %v", err)
	}
	text := string(source)

	wantSubstrings := []string{
		"func sanitizeTunTraceForBridge(source runtimepkg.TunTrace) runtimepkg.TunTrace {",
		"sanitized.SourceAddress = \"\"",
		"sanitized.DestinationAddress = \"\"",
		"func writeTunTrace(trace *C.cmfa_tun_trace, source runtimepkg.TunTrace) {",
		"source = sanitizeTunTraceForBridge(source)",
	}
	for _, want := range wantSubstrings {
		if !strings.Contains(text, want) {
			t.Fatalf("main.go missing %q", want)
		}
	}
}

func TestBuildInfoPrivateExportIncludesPinnedFields(t *testing.T) {
	raw := goBuildInfoJSON()
	var info version.Info
	if err := json.Unmarshal([]byte(raw), &info); err != nil {
		t.Fatalf("unmarshal build info: %v", err)
	}

	expected := version.Build()
	if info.Version != expected.Version {
		t.Fatalf("version mismatch: got %q want %q", info.Version, expected.Version)
	}
	if info.UpstreamCommit != expected.UpstreamCommit {
		t.Fatalf("commit mismatch: got %q want %q", info.UpstreamCommit, expected.UpstreamCommit)
	}
	if info.ABIVersion != expected.ABIVersion {
		t.Fatalf("abi mismatch: got %q want %q", info.ABIVersion, expected.ABIVersion)
	}
	if info.BuildID != expected.BuildID {
		t.Fatalf("buildID mismatch: got %q want %q", info.BuildID, expected.BuildID)
	}
}

func TestFailureMessagePrefersSnapshotLastError(t *testing.T) {
	snapshot := runtimepkg.Snapshot{LastError: "redacted snapshot error"}
	err := errors.New("raw backend error")

	if got := failureMessage(snapshot, err); got != "redacted snapshot error" {
		t.Fatalf("failureMessage = %q want snapshot last error", got)
	}
}

func TestDelayDrainMutationExportsSourceUseGate(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("os.ReadFile(main.go) failed: %v", err)
	}
	text := string(source)

	wantSubstrings := []string{
		"func drainProxyDelayJobsForMutation() error",
		"func executeAfterProxyDelayDrain(",
		"func cmfa_mihomo_load_config_v1(",
		"func cmfa_mihomo_start_local_v1(",
		"func cmfa_mihomo_stop_v1(",
		"func cmfa_mihomo_start_tun_v1(",
		"func cmfa_mihomo_stop_tun_v1(",
		"drainProxyDelayJobsForMutation()",
	}
	for _, want := range wantSubstrings {
		if !strings.Contains(text, want) {
			t.Fatalf("main.go missing %q", want)
		}
	}
}

func TestLoadConfigForLocalProxyLeavesIngressPortsForRuntimeOwnership(t *testing.T) {
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve port: %v", err)
	}
	port := reserved.Addr().(*net.TCPAddr).Port
	if err := reserved.Close(); err != nil {
		t.Fatalf("release reserved port: %v", err)
	}

	configPath := filepath.Join(t.TempDir(), "profile.yaml")
	configSource := fmt.Sprintf("mode: rule\nmixed-port: %d\nrules:\n  - MATCH,DIRECT\n", port)
	if err := os.WriteFile(configPath, []byte(configSource), 0o644); err != nil {
		t.Fatalf("write profile: %v", err)
	}
	t.Cleanup(mihomoexecutor.Shutdown)

	manager := configpkg.NewHomeManager(func(string) {})
	previousLoaderFactory := newManagedConfigLoader
	newManagedConfigLoader = func(sandboxRoot string) managedConfigLoader {
		return configpkg.NewLoaderWithDeps(sandboxRoot, configpkg.LoaderDeps{
			PrepareHome: manager.Prepare,
		})
	}
	t.Cleanup(func() {
		newManagedConfigLoader = previousLoaderFactory
	})
	previousLegacyLoaderFactory := newLegacyRelativeConfigLoader
	t.Cleanup(func() {
		newLegacyRelativeConfigLoader = previousLegacyLoaderFactory
	})

	if err := loadConfigForLocalProxy(configPath); err != nil {
		t.Fatalf("loadConfigForLocalProxy: %v", err)
	}

	rebound, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("profile ingress port remained occupied after local-proxy prepare: %v", err)
	}
	_ = rebound.Close()
}

func TestRelativeConfigRoutesDoNotClaimManagedAuthority(t *testing.T) {
	legacyRoot := t.TempDir()
	managedRoot := t.TempDir()
	legacyConfigPath := filepath.Join(legacyRoot, "legacy.yaml")
	managedConfigPath := writeManagedConfig(t, filepath.Join(managedRoot, "self-test.yaml"))
	if err := os.WriteFile(legacyConfigPath, []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write legacy config: %v", err)
	}

	previousWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(legacyRoot); err != nil {
		t.Fatalf("chdir legacy root: %v", err)
	}
	t.Cleanup(func() {
		_ = os.Chdir(previousWD)
	})

	manager := configpkg.NewHomeManager(func(string) {})
	managedPrepareCalls := 0
	validateLegacyCalls := 0
	validateManagedCalls := 0
	loadLegacyCalls := 0
	loadManagedCalls := 0

	previousManagedValidator := validateManagedConfig
	previousLegacyValidator := validateLegacyRelativeConfig
	previousManagedLoaderFactory := newManagedConfigLoader
	previousLegacyLoaderFactory := newLegacyRelativeConfigLoader
	t.Cleanup(func() {
		validateManagedConfig = previousManagedValidator
		validateLegacyRelativeConfig = previousLegacyValidator
		newManagedConfigLoader = previousManagedLoaderFactory
		newLegacyRelativeConfigLoader = previousLegacyLoaderFactory
	})

	validateLegacyRelativeConfig = func(sandboxRoot, candidate string) error {
		validateLegacyCalls++
		return configpkg.ValidateFileWithDeps(sandboxRoot, candidate, configpkg.ValidateDeps{
			PrepareHome: nonAuthoritativePrepareHome,
			ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
				return &mihomocfg.Config{}, nil
			},
		})
	}
	validateManagedConfig = func(sandboxRoot, candidate string) error {
		validateManagedCalls++
		return configpkg.ValidateFileWithDeps(sandboxRoot, candidate, configpkg.ValidateDeps{
			PrepareHome: func(root string) error {
				managedPrepareCalls++
				return manager.Prepare(root)
			},
			ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
				return &mihomocfg.Config{}, nil
			},
		})
	}
	newLegacyRelativeConfigLoader = func(sandboxRoot string) managedConfigLoader {
		return managedConfigLoaderFunc(func(candidate string) error {
			loadLegacyCalls++
			return nil
		})
	}
	newManagedConfigLoader = func(sandboxRoot string) managedConfigLoader {
		return managedConfigLoaderFunc(func(candidate string) error {
			loadManagedCalls++
			managedPrepareCalls++
			return manager.Prepare(sandboxRoot)
		})
	}

	if err := validateConfigForNative("legacy.yaml"); err != nil {
		t.Fatalf("validateConfigForNative(relative): %v", err)
	}
	if managedPrepareCalls != 0 {
		t.Fatalf("relative validation claimed managed authority: %d", managedPrepareCalls)
	}
	if validateLegacyCalls != 1 || validateManagedCalls != 0 {
		t.Fatalf("unexpected validate routing: legacy=%d managed=%d", validateLegacyCalls, validateManagedCalls)
	}

	if err := validateConfigForNative(managedConfigPath); err != nil {
		t.Fatalf("validateConfigForNative(managed): %v", err)
	}
	if managedPrepareCalls != 1 {
		t.Fatalf("managed validation prepare calls = %d want 1", managedPrepareCalls)
	}
	if validateManagedCalls != 1 {
		t.Fatalf("managed validate calls = %d want 1", validateManagedCalls)
	}

	if err := loadConfigForLocalProxy("legacy.yaml"); err != nil {
		t.Fatalf("loadConfigForLocalProxy(relative): %v", err)
	}
	if loadLegacyCalls != 1 || loadManagedCalls != 0 {
		t.Fatalf("unexpected load routing after relative: legacy=%d managed=%d", loadLegacyCalls, loadManagedCalls)
	}
	if managedPrepareCalls != 1 {
		t.Fatalf("relative load changed managed authority: %d", managedPrepareCalls)
	}

	if err := loadConfigForLocalProxy(managedConfigPath); err != nil {
		t.Fatalf("loadConfigForLocalProxy(managed): %v", err)
	}
	if loadManagedCalls != 1 {
		t.Fatalf("managed load calls = %d want 1", loadManagedCalls)
	}
	if managedPrepareCalls != 2 {
		t.Fatalf("managed prepare calls after managed load = %d want 2", managedPrepareCalls)
	}
}

func TestConfigSandboxResolvesManagedAbsolutePathsToStableFilesHome(t *testing.T) {
	filesRoot := t.TempDir()
	wantRoot, err := filepath.EvalSymlinks(filesRoot)
	if err != nil {
		wantRoot = filesRoot
	}
	tests := []struct {
		name          string
		configPath    string
		wantCandidate string
	}{
		{
			name:          "tmp stage config",
			configPath:    writeManagedConfig(t, filepath.Join(filesRoot, "tmp", "prepare.yaml")),
			wantCandidate: filepath.Join("tmp", "prepare.yaml"),
		},
		{
			name:          "retained valid revision",
			configPath:    writeManagedConfig(t, filepath.Join(filesRoot, "profiles", "alpha", "valid", "rev-1.yaml")),
			wantCandidate: filepath.Join("profiles", "alpha", "valid", "rev-1.yaml"),
		},
		{
			name:          "retained failed revision",
			configPath:    writeManagedConfig(t, filepath.Join(filesRoot, "profiles", "alpha", "failed", "rev-2.yaml")),
			wantCandidate: filepath.Join("profiles", "alpha", "failed", "rev-2.yaml"),
		},
		{
			name:          "self test config",
			configPath:    writeManagedConfig(t, filepath.Join(filesRoot, "self-test.yaml")),
			wantCandidate: "self-test.yaml",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root, candidate, err := configSandbox(tt.configPath)
			if err != nil {
				t.Fatalf("configSandbox returned error: %v", err)
			}
			if root != wantRoot {
				t.Fatalf("sandbox root = %q want %q", root, wantRoot)
			}
			if candidate != tt.wantCandidate {
				t.Fatalf("candidate = %q want %q", candidate, tt.wantCandidate)
			}
		})
	}
}

func TestConfigSandboxRejectsMalformedManagedAbsolutePaths(t *testing.T) {
	filesRoot := t.TempDir()
	writeManagedConfig(t, filepath.Join(filesRoot, "tmp", "prepare.yaml"))

	tests := []struct {
		name string
		path string
	}{
		{
			name: "traversal component",
			path: filepath.Join(filesRoot, "tmp") + string(filepath.Separator) + ".." + string(filepath.Separator) + "self-test.yaml",
		},
		{
			name: "tmp nested too deep",
			path: writeManagedConfig(t, filepath.Join(filesRoot, "tmp", "nested", "prepare.yaml")),
		},
		{
			name: "profile malformed depth",
			path: writeManagedConfig(t, filepath.Join(filesRoot, "profiles", "alpha", "valid.yaml")),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, err := configSandbox(tt.path)
			if err == nil {
				t.Fatal("configSandbox unexpectedly succeeded")
			}
		})
	}
}

func TestValidateConfigForNativeRedactsMissingManagedAbsolutePath(t *testing.T) {
	filesRoot := t.TempDir()
	missingPath := filepath.Join(filesRoot, "tmp", "missing-native-secret.yaml")

	err := validateConfigForNative(missingPath)
	if err == nil {
		t.Fatal("validateConfigForNative unexpectedly succeeded")
	}
	if !errors.Is(err, configpkg.ErrManagedConfigUnavailable) {
		t.Fatalf("expected ErrManagedConfigUnavailable, got %v", err)
	}
	if got, want := configStatus(err), configStatus(configpkg.ErrPathOutsideSandbox); got != want {
		t.Fatalf("configStatus = %v want %v", got, want)
	}
	assertNoConfigPathLeak(t, err.Error(), missingPath)
	if got := err.Error(); got != "MANAGED_CONFIG_UNAVAILABLE" {
		t.Fatalf("error text = %q want %q", got, "MANAGED_CONFIG_UNAVAILABLE")
	}
}

func TestLoadConfigForLocalProxyRedactsMissingManagedAbsolutePath(t *testing.T) {
	filesRoot := t.TempDir()
	missingPath := filepath.Join(filesRoot, "tmp", "missing-local-proxy-secret.yaml")

	err := loadConfigForLocalProxy(missingPath)
	if err == nil {
		t.Fatal("loadConfigForLocalProxy unexpectedly succeeded")
	}
	if !errors.Is(err, configpkg.ErrManagedConfigUnavailable) {
		t.Fatalf("expected ErrManagedConfigUnavailable, got %v", err)
	}
	if got, want := configStatus(err), configStatus(configpkg.ErrPathOutsideSandbox); got != want {
		t.Fatalf("configStatus = %v want %v", got, want)
	}
	assertNoConfigPathLeak(t, err.Error(), missingPath)
	if got := err.Error(); got != "MANAGED_CONFIG_UNAVAILABLE" {
		t.Fatalf("error text = %q want %q", got, "MANAGED_CONFIG_UNAVAILABLE")
	}
}

func TestTunStageRuntimeLogEncodingPreservesOnlyFixedStages(t *testing.T) {
	for _, stage := range []string{"tun.prepare.begin", "tun.listener.failure.stack-start", "tun.listener.failure.invalid"} {
		allowed := encodeRuntimeLogMessage(runtimepkg.RuntimeLog{
			Level:    runtimepkg.LogLevelInfo,
			Category: "runtime.tun.stage",
			Message:  stage,
		})
		if allowed != stage {
			t.Fatalf("allowed stage encoding = %q want %q", allowed, stage)
		}
	}

	invalid := encodeRuntimeLogMessage(runtimepkg.RuntimeLog{
		Level:    runtimepkg.LogLevelInfo,
		Category: "runtime.tun.stage",
		Message:  "tun.listener.failed:secret",
	})
	if strings.Contains(invalid, "secret") {
		t.Fatalf("invalid stage encoding leaked dynamic suffix: %q", invalid)
	}
}

type managedConfigLoaderFunc func(candidate string) error

func (fn managedConfigLoaderFunc) LoadForLocalProxy(candidate string) error {
	return fn(candidate)
}

func writeManagedConfig(t *testing.T, path string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

func assertNoConfigPathLeak(t *testing.T, text, path string) {
	t.Helper()
	cleaned := filepath.Clean(path)
	fragments := []string{cleaned, filepath.Base(cleaned)}
	parent := filepath.Dir(cleaned)
	if parent != "." && parent != string(filepath.Separator) {
		fragments = append(fragments, parent, filepath.Base(parent))
	}
	for _, fragment := range fragments {
		if fragment != "" && strings.Contains(text, fragment) {
			t.Fatalf("error leaked path fragment %q in %q", fragment, text)
		}
	}
}

func TestReportTunStartStageQueuesFixedRuntimeLog(t *testing.T) {
	for {
		if _, ok := runtimeLogs.Take(); !ok {
			break
		}
	}
	t.Cleanup(func() {
		for {
			if _, ok := runtimeLogs.Take(); !ok {
				return
			}
		}
	})

	reportTunStartStage("tun.listener.begin")
	log, ok := runtimeLogs.Take()
	if !ok {
		t.Fatal("stage reporter did not queue a runtime log")
	}
	if log.Category != "runtime.tun.stage" || log.Message != "tun.listener.begin" {
		t.Fatalf("stage runtime log = %#v", log)
	}
}
