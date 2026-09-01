package config_test

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	mihomocfg "github.com/metacubex/mihomo/config"
	mihomoconstant "github.com/metacubex/mihomo/constant"

	configwrap "github.com/clashmetaforandroid/harmony/core/go/internal/config"
	eventspkg "github.com/clashmetaforandroid/harmony/core/go/internal/events"
	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
	"github.com/clashmetaforandroid/harmony/core/go/internal/version"
)

func repoHarmonyRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", "..", ".."))
}

func fixturePath(t *testing.T, name string) string {
	t.Helper()
	return filepath.Join(repoHarmonyRoot(t), "tests", "fixtures", name)
}

func fixtureRelPath(name string) string {
	return filepath.Join("tests", "fixtures", name)
}

func canonicalPath(t *testing.T, filePath string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(filePath)
	if err == nil {
		return resolved
	}
	return filepath.Clean(filePath)
}

func TestBuildInfoUsesUpstreamVersion(t *testing.T) {
	info := version.Build()
	if info.Version != mihomoconstant.Version {
		t.Fatalf("version mismatch: got %q want %q", info.Version, mihomoconstant.Version)
	}
	if info.ABIVersion == "" {
		t.Fatal("abi version must not be empty")
	}
	if info.BuildID == "" {
		t.Fatal("build id must not be empty")
	}
}

func TestValidateFileAcceptsMatchDirectFixture(t *testing.T) {
	root := repoHarmonyRoot(t)
	if err := configwrap.ValidateFileWithDeps(root, fixtureRelPath("phase2-match-direct.yaml"), configwrap.ValidateDeps{
		PrepareHome: noopPrepareHome,
	}); err != nil {
		t.Fatalf("ValidateFile returned error: %v", err)
	}
}

func TestValidateFileWithDepsClassifiesGeoIPFixtureAsGeodataMissing(t *testing.T) {
	root := repoHarmonyRoot(t)
	expectedBody := mustReadFile(t, fixturePath(t, "phase5-geoip-rule.yaml"))

	err := configwrap.ValidateFileWithDeps(root, fixtureRelPath("phase5-geoip-rule.yaml"), configwrap.ValidateDeps{
		PrepareHome: noopPrepareHome,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			if string(body) != expectedBody {
				t.Fatalf("unexpected fixture bytes: %q", string(body))
			}
			return nil, errors.New("rules[0] line 4: GEOIP,CN,DIRECT can't find MMDB: /data/user/0/example/files/geoip.metadb")
		},
	})
	if err == nil {
		t.Fatal("ValidateFileWithDeps unexpectedly succeeded")
	}

	var validationErr *configwrap.ValidationError
	if !errors.As(err, &validationErr) {
		t.Fatalf("expected ValidationError, got %T", err)
	}
	if validationErr.Code != "GEODATA_MISSING" {
		t.Fatalf("validation code = %q want GEODATA_MISSING", validationErr.Code)
	}
	if validationErr.Field != "geoip" {
		t.Fatalf("validation field = %q want geoip", validationErr.Field)
	}
	if validationErr.Line == nil || *validationErr.Line != 4 {
		t.Fatalf("validation line = %v want 4", validationErr.Line)
	}
	if text := err.Error(); strings.Contains(text, "/data/user/0/example/files/geoip.metadb") {
		t.Fatalf("validation error leaked prepared-home path: %q", text)
	}
}

func TestValidateFileWithDepsAcceptsGeoIPFixtureWhenPreparedHomeContainsPinnedGeoIP(t *testing.T) {
	root := t.TempDir()
	fixtureBody := mustReadFile(t, fixturePath(t, "phase5-geoip-rule.yaml"))
	if err := os.WriteFile(filepath.Join(root, "phase5-geoip-rule.yaml"), []byte(fixtureBody), 0o644); err != nil {
		t.Fatalf("write fixture copy: %v", err)
	}

	preparedRoot := ""
	prepareCalls := 0
	if err := configwrap.ValidateFileWithDeps(root, "phase5-geoip-rule.yaml", configwrap.ValidateDeps{
		PrepareHome: func(homeRoot string) error {
			prepareCalls++
			preparedRoot = homeRoot
			return os.WriteFile(filepath.Join(homeRoot, "geoip.metadb"), []byte("fixture"), 0o644)
		},
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			if string(body) != fixtureBody {
				t.Fatalf("unexpected fixture bytes: %q", string(body))
			}
			if preparedRoot == "" {
				t.Fatal("parse ran before PrepareHome")
			}
			if _, err := os.Stat(filepath.Join(preparedRoot, "geoip.metadb")); err != nil {
				t.Fatalf("expected prepared geoip.metadb: %v", err)
			}
			return &mihomocfg.Config{}, nil
		},
	}); err != nil {
		t.Fatalf("ValidateFileWithDeps returned error: %v", err)
	}
	if prepareCalls != 1 {
		t.Fatalf("prepare calls = %d want 1", prepareCalls)
	}
}

func TestValidateFileReturnsUsefulDetailsForInvalidFixture(t *testing.T) {
	root := repoHarmonyRoot(t)
	err := configwrap.ValidateFileWithDeps(root, fixtureRelPath("phase2-invalid.yaml"), configwrap.ValidateDeps{
		PrepareHome: noopPrepareHome,
	})
	if err == nil {
		t.Fatal("ValidateFile unexpectedly succeeded")
	}

	var validationErr *configwrap.ValidationError
	if !errors.As(err, &validationErr) {
		t.Fatalf("expected ValidationError, got %T", err)
	}
	if validationErr.Code != "YAML_SYNTAX" {
		t.Fatalf("validation code = %q want YAML_SYNTAX", validationErr.Code)
	}
	if errText := err.Error(); !strings.Contains(errText, "line=2") {
		t.Fatalf("expected sanitized line detail, got %q", errText)
	}
}

func TestValidateFileWithDepsPreparesStableHomeBeforeParse(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "config.yaml"), []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	preparedRoot := ""
	setHomeDirCalls := 0
	manager := configwrap.NewHomeManager(func(path string) {
		setHomeDirCalls++
		preparedRoot = path
	})

	parseCalls := 0
	if err := configwrap.ValidateFileWithDeps(root, "config.yaml", configwrap.ValidateDeps{
		PrepareHome: manager.Prepare,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			parseCalls++
			if preparedRoot == "" {
				t.Fatal("parse ran before PrepareHome")
			}
			return &mihomocfg.Config{}, nil
		},
	}); err != nil {
		t.Fatalf("ValidateFileWithDeps failed: %v", err)
	}

	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
		PrepareHome: manager.Prepare,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			parseCalls++
			if preparedRoot == "" {
				t.Fatal("loader parse ran before PrepareHome")
			}
			return &mihomocfg.Config{}, nil
		},
		Apply: func(cfg *mihomocfg.Config, force bool) error { return nil },
	})
	if err := loader.Load("config.yaml"); err != nil {
		t.Fatalf("Loader.Load failed: %v", err)
	}

	if setHomeDirCalls != 1 {
		t.Fatalf("setHomeDir calls = %d want 1", setHomeDirCalls)
	}
	if parseCalls != 2 {
		t.Fatalf("parse calls = %d want 2", parseCalls)
	}
}

func TestValidateFileWithDepsRejectsForeignRootDriftBeforeParserRuns(t *testing.T) {
	firstRoot := t.TempDir()
	secondRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(firstRoot, "self-test.yaml"), []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write first config: %v", err)
	}
	if err := os.WriteFile(filepath.Join(secondRoot, "self-test.yaml"), []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write second config: %v", err)
	}

	manager := configwrap.NewHomeManager(func(path string) {})
	validateCalls := 0
	if err := configwrap.ValidateFileWithDeps(firstRoot, "self-test.yaml", configwrap.ValidateDeps{
		PrepareHome: manager.Prepare,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			validateCalls++
			return &mihomocfg.Config{}, nil
		},
	}); err != nil {
		t.Fatalf("ValidateFileWithDeps(first): %v", err)
	}

	loadCalls := 0
	loader := configwrap.NewLoaderWithDeps(secondRoot, configwrap.LoaderDeps{
		PrepareHome: manager.Prepare,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			loadCalls++
			return &mihomocfg.Config{}, nil
		},
		Apply: func(cfg *mihomocfg.Config, force bool) error { return nil },
	})

	err := loader.Load("self-test.yaml")
	if err == nil {
		t.Fatal("Loader.Load(second) unexpectedly succeeded")
	}
	var driftErr *configwrap.HomeDriftError
	if !errors.As(err, &driftErr) {
		t.Fatalf("expected HomeDriftError, got %T", err)
	}
	if driftErr.Code != "GEODATA_HOME_DRIFT" {
		t.Fatalf("drift code = %q want GEODATA_HOME_DRIFT", driftErr.Code)
	}
	if validateCalls != 1 {
		t.Fatalf("validate calls = %d want 1", validateCalls)
	}
	if loadCalls != 0 {
		t.Fatalf("load parse calls = %d want 0", loadCalls)
	}
}

func TestValidateFileWithDepsSanitizesSecretBearingParserErrors(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "config.yaml"), []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	tests := []struct {
		name         string
		parseErr     string
		wantCode     string
		wantContains []string
		wantAbsent   []string
	}{
		{
			name:         "yaml syntax",
			parseErr:     "yaml: unmarshal errors:\n  line 7: cannot unmarshal !!str 'token=abc123' into int",
			wantCode:     "YAML_SYNTAX",
			wantContains: []string{"YAML_SYNTAX", "line=7"},
			wantAbsent:   []string{"abc123", "token="},
		},
		{
			name:         "proxy invalid",
			parseErr:     "proxy 3: server https://user:pass@example.com is invalid",
			wantCode:     "PROXY_INVALID",
			wantContains: []string{"PROXY_INVALID", "field=proxy", "index=3"},
			wantAbsent:   []string{"user", "pass", "example.com"},
		},
		{
			name:         "rule invalid",
			parseErr:     "rules[5] [DOMAIN-SUFFIX,netflix.com,Proxy-Group] error: proxy [Proxy-Group] not found",
			wantCode:     "RULE_INVALID",
			wantContains: []string{"RULE_INVALID", "field=rules", "index=5"},
			wantAbsent:   []string{"netflix.com", "Proxy-Group"},
		},
		{
			name:         "geodata missing",
			parseErr:     "load GeoIP dns fallback filter error, can't find MMDB: /data/user/0/app/files/geoip.metadb",
			wantCode:     "GEODATA_MISSING",
			wantContains: []string{"GEODATA_MISSING", "field=geoip"},
			wantAbsent:   []string{"/data/user/0/app/files/geoip.metadb"},
		},
		{
			name:         "unknown validation error",
			parseErr:     "listen https://secret.example.com:443 failed for proxy node-01",
			wantCode:     "VALIDATION_UNKNOWN",
			wantContains: []string{"VALIDATION_UNKNOWN"},
			wantAbsent:   []string{"secret.example.com", "node-01"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := configwrap.ValidateFileWithDeps(root, "config.yaml", configwrap.ValidateDeps{
				PrepareHome: noopPrepareHome,
				ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
					return nil, errors.New(tt.parseErr)
				},
			})
			if err == nil {
				t.Fatal("ValidateFileWithDeps unexpectedly succeeded")
			}

			var validationErr *configwrap.ValidationError
			if !errors.As(err, &validationErr) {
				t.Fatalf("expected ValidationError, got %T", err)
			}
			if validationErr.Code != tt.wantCode {
				t.Fatalf("validation code = %q want %q", validationErr.Code, tt.wantCode)
			}

			text := err.Error()
			for _, want := range tt.wantContains {
				if !strings.Contains(text, want) {
					t.Fatalf("expected %q in %q", want, text)
				}
			}
			for _, forbidden := range tt.wantAbsent {
				if strings.Contains(text, forbidden) {
					t.Fatalf("error leaked forbidden fragment %q in %q", forbidden, text)
				}
			}
		})
	}
}

func TestValidateFileRejectsContentURIAndOutsideSandbox(t *testing.T) {
	root := repoHarmonyRoot(t)

	if err := configwrap.ValidateFileWithDeps(root, "content://profile/config.yaml", configwrap.ValidateDeps{
		PrepareHome: noopPrepareHome,
	}); err == nil {
		t.Fatal("content:// path unexpectedly succeeded")
	}

	outside := filepath.Clean(filepath.Join(root, "..", "outside.yaml"))
	err := configwrap.ValidateFileWithDeps(root, outside, configwrap.ValidateDeps{
		PrepareHome: noopPrepareHome,
	})
	if err == nil {
		t.Fatal("outside-sandbox path unexpectedly succeeded")
	}
	if !errors.Is(err, configwrap.ErrPathOutsideSandbox) {
		t.Fatalf("expected ErrPathOutsideSandbox, got %v", err)
	}
}

func TestValidateFileTreatsDirectoryCandidateAsManagedConfigUnavailable(t *testing.T) {
	root := t.TempDir()
	dirCandidate := filepath.Join(root, "config.yaml")
	if err := os.Mkdir(dirCandidate, 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}

	parseCalls := 0
	err := configwrap.ValidateFileWithDeps(root, "config.yaml", configwrap.ValidateDeps{
		PrepareHome: noopPrepareHome,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			parseCalls++
			return &mihomocfg.Config{}, nil
		},
	})
	if err == nil {
		t.Fatal("ValidateFileWithDeps unexpectedly succeeded")
	}
	if !errors.Is(err, configwrap.ErrManagedConfigUnavailable) {
		t.Fatalf("expected ErrManagedConfigUnavailable, got %v", err)
	}
	if errors.Is(err, configwrap.ErrPathOutsideSandbox) {
		t.Fatalf("directory candidate misclassified as outside sandbox: %v", err)
	}
	if parseCalls != 0 {
		t.Fatalf("parse calls = %d want 0", parseCalls)
	}
	if got := err.Error(); got != "MANAGED_CONFIG_UNAVAILABLE" {
		t.Fatalf("error text = %q want %q", got, "MANAGED_CONFIG_UNAVAILABLE")
	}
}

func TestLoaderPreservesPreviousConfigWhenLoadFails(t *testing.T) {
	root := repoHarmonyRoot(t)
	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{PrepareHome: noopPrepareHome})
	valid := fixtureRelPath("phase2-match-direct.yaml")
	invalid := fixtureRelPath("phase2-invalid.yaml")

	if err := loader.Load(valid); err != nil {
		t.Fatalf("initial load failed: %v", err)
	}

	if err := loader.Load(invalid); err == nil {
		t.Fatal("invalid load unexpectedly succeeded")
	}

	if got := loader.CurrentPath(); got != fixturePath(t, "phase2-match-direct.yaml") {
		t.Fatalf("current path changed after failed load: got %q want %q", got, fixturePath(t, "phase2-match-direct.yaml"))
	}
}

func TestLoaderAppliesOnceAndPreservesStateOnInvalidLoad(t *testing.T) {
	root := repoHarmonyRoot(t)
	valid := fixtureRelPath("phase2-match-direct.yaml")
	invalid := fixtureRelPath("phase2-invalid.yaml")
	lifecycle := runtimepkg.NewLifecycle()
	sink := &eventspkg.Buffer{}
	configObject := &mihomocfg.Config{}
	parseCalls := 0
	applyCalls := 0

	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
		PrepareHome: noopPrepareHome,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			parseCalls++
			switch string(body) {
			case mustReadFile(t, fixturePath(t, "phase2-match-direct.yaml")):
				return configObject, nil
			case mustReadFile(t, fixturePath(t, "phase2-invalid.yaml")):
				return nil, errors.New("synthetic parse failure")
			default:
				t.Fatalf("unexpected body: %q", string(body))
				return nil, nil
			}
		},
		Apply: func(cfg *mihomocfg.Config, force bool) error {
			applyCalls++
			if cfg != configObject {
				t.Fatalf("apply received unexpected config pointer: %p", cfg)
			}
			if !force {
				t.Fatal("apply must force reconfiguration")
			}
			return nil
		},
		Lifecycle: lifecycle,
		Events:    sink,
	})

	if err := loader.Load(valid); err != nil {
		t.Fatalf("valid load failed: %v", err)
	}
	if parseCalls != 1 {
		t.Fatalf("parse count after valid load = %d want 1", parseCalls)
	}
	if applyCalls != 1 {
		t.Fatalf("apply count after valid load = %d want 1", applyCalls)
	}
	if lifecycle.State() != runtimepkg.StateConfigLoaded {
		t.Fatalf("lifecycle state after valid load = %s want %s", lifecycle.State(), runtimepkg.StateConfigLoaded)
	}
	expectedValidPath := canonicalPath(t, fixturePath(t, "phase2-match-direct.yaml"))
	if loader.CurrentPath() != expectedValidPath {
		t.Fatalf("current path after valid load = %q want %q", loader.CurrentPath(), expectedValidPath)
	}

	eventsAfterValid := sink.Events()
	if len(eventsAfterValid) < 2 {
		t.Fatalf("expected at least 2 events after valid load, got %d", len(eventsAfterValid))
	}
	if eventsAfterValid[0].Kind != "config.load.started" || eventsAfterValid[1].Kind != "config.load.applied" {
		t.Fatalf("unexpected valid event order: %#v", eventsAfterValid[:2])
	}

	if err := loader.Load(invalid); err == nil {
		t.Fatal("invalid load unexpectedly succeeded")
	}
	if parseCalls != 2 {
		t.Fatalf("parse count after invalid load = %d want 2", parseCalls)
	}
	if applyCalls != 1 {
		t.Fatalf("apply count after invalid load = %d want 1", applyCalls)
	}
	if lifecycle.State() != runtimepkg.StateConfigLoaded {
		t.Fatalf("lifecycle state after invalid load = %s want %s", lifecycle.State(), runtimepkg.StateConfigLoaded)
	}
	if loader.CurrentPath() != expectedValidPath {
		t.Fatalf("current path after invalid load = %q want %q", loader.CurrentPath(), expectedValidPath)
	}

	allEvents := sink.Events()
	if len(allEvents) < 4 {
		t.Fatalf("expected at least 4 events, got %d", len(allEvents))
	}
	if allEvents[2].Kind != "config.load.started" || allEvents[3].Kind != "config.load.failed" {
		t.Fatalf("unexpected invalid event order: %#v", allEvents[2:4])
	}
}

func TestLoaderLoadForLocalProxyClearsConfigOwnedIngressBeforeApply(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "profile.yaml")
	if err := os.WriteFile(configPath, []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	parsed := &mihomocfg.Config{
		General: &mihomocfg.General{
			Inbound: mihomocfg.Inbound{
				Port:              7890,
				SocksPort:         7891,
				RedirPort:         7892,
				TProxyPort:        7893,
				MixedPort:         7894,
				ShadowSocksConfig: "shadow-server",
				VmessConfig:       "vmess-server",
				AllowLan:          true,
				BindAddress:       "*",
			},
			IPv6: true,
		},
		DNS: &mihomocfg.DNS{
			Enable:            true,
			Listen:            "127.0.0.1:1053",
			ListenRoutingMark: 123,
		},
		IPTables: &mihomocfg.IPTables{Enable: true},
		Listeners: map[string]mihomoconstant.InboundListener{
			"profile-owned": nil,
		},
	}
	parsed.General.Tun.Enable = true
	parsed.General.TuicServer.Enable = true

	applyCalls := 0
	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
		PrepareHome: noopPrepareHome,
		ParseBytes: func([]byte) (*mihomocfg.Config, error) {
			return parsed, nil
		},
		Apply: func(cfg *mihomocfg.Config, force bool) error {
			applyCalls++
			if !force {
				t.Fatal("local proxy load must force reconfiguration")
			}
			if cfg.General == nil {
				t.Fatal("general config was removed")
			}
			if !reflect.DeepEqual(cfg.General.Inbound, mihomocfg.Inbound{}) {
				t.Fatalf("config-owned inbound survived: %#v", cfg.General.Inbound)
			}
			if cfg.DNS == nil || !cfg.DNS.Enable {
				t.Fatal("DNS resolution policy must remain enabled")
			}
			if cfg.DNS.Listen != "" || cfg.DNS.ListenRoutingMark != 0 {
				t.Fatalf("DNS listener survived: listen=%q mark=%d", cfg.DNS.Listen, cfg.DNS.ListenRoutingMark)
			}
			if cfg.IPTables == nil || cfg.IPTables.Enable {
				t.Fatal("profile-owned iptables must be disabled")
			}
			if len(cfg.Listeners) != 0 {
				t.Fatalf("custom listeners survived: %#v", cfg.Listeners)
			}
			if !cfg.General.IPv6 {
				t.Fatal("unrelated general config was changed")
			}
			return nil
		},
	})

	if err := loader.LoadForLocalProxy("profile.yaml"); err != nil {
		t.Fatalf("LoadForLocalProxy failed: %v", err)
	}
	if applyCalls != 1 {
		t.Fatalf("apply calls = %d want 1", applyCalls)
	}
}

func mustReadFile(t *testing.T, filePath string) string {
	t.Helper()
	body, err := os.ReadFile(filePath)
	if err != nil {
		t.Fatalf("read file %s: %v", filePath, err)
	}
	return string(body)
}

func TestLoaderRejectsAbsoluteSandboxPath(t *testing.T) {
	root := repoHarmonyRoot(t)
	err := configwrap.ValidateFileWithDeps(root, fixturePath(t, "phase2-match-direct.yaml"), configwrap.ValidateDeps{
		PrepareHome: noopPrepareHome,
	})
	if !errors.Is(err, configwrap.ErrPathOutsideSandbox) {
		t.Fatalf("expected absolute path rejection, got %v", err)
	}
}

func TestLoaderRejectsSymlinkEscapeWithoutParsingOrApplying(t *testing.T) {
	root := t.TempDir()
	outsideDir := t.TempDir()
	outsidePath := filepath.Join(outsideDir, "outside.yaml")
	if err := os.WriteFile(outsidePath, []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write outside: %v", err)
	}
	if err := os.Symlink(outsidePath, filepath.Join(root, "escape.yaml")); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	parseCalls := 0
	applyCalls := 0
	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
		PrepareHome: noopPrepareHome,
		ParseBytes: func([]byte) (*mihomocfg.Config, error) {
			parseCalls++
			return &mihomocfg.Config{}, nil
		},
		Apply: func(cfg *mihomocfg.Config, force bool) error {
			applyCalls++
			return nil
		},
	})

	err := loader.Load("escape.yaml")
	if !errors.Is(err, configwrap.ErrPathOutsideSandbox) {
		t.Fatalf("expected ErrPathOutsideSandbox, got %v", err)
	}
	if parseCalls != 0 {
		t.Fatalf("parse calls = %d want 0", parseCalls)
	}
	if applyCalls != 0 {
		t.Fatalf("apply calls = %d want 0", applyCalls)
	}
}

func TestLoaderParsesStableBytesAfterOnDiskMutation(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "snapshot.yaml")
	original := []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n")
	if err := os.WriteFile(configPath, original, 0o644); err != nil {
		t.Fatalf("write original: %v", err)
	}

	parseCalls := 0
	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
		PrepareHome: noopPrepareHome,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			parseCalls++
			if string(body) != string(original) {
				t.Fatalf("parser saw mutated bytes: %q", string(body))
			}
			if err := os.WriteFile(configPath, []byte("mode: rule\nmixed-port: nope\n"), 0o644); err != nil {
				t.Fatalf("mutate file: %v", err)
			}
			return &mihomocfg.Config{}, nil
		},
		Apply: func(cfg *mihomocfg.Config, force bool) error { return nil },
	})

	if err := loader.Load("snapshot.yaml"); err != nil {
		t.Fatalf("load failed: %v", err)
	}
	if parseCalls != 1 {
		t.Fatalf("parse calls = %d want 1", parseCalls)
	}
}

func TestLoaderApplyFailurePreservesOldPathStateAndEmitsFailedEvent(t *testing.T) {
	root := t.TempDir()
	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{PrepareHome: noopPrepareHome})
	lifecycle := runtimepkg.NewLifecycle()
	sink := &eventspkg.Buffer{}
	good := &mihomocfg.Config{}
	bad := &mihomocfg.Config{}
	applyCalls := 0
	loader = configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
		PrepareHome: noopPrepareHome,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			if strings.Contains(string(body), "bad") {
				return bad, nil
			}
			return good, nil
		},
		Apply: func(cfg *mihomocfg.Config, force bool) error {
			applyCalls++
			if cfg == bad {
				return errors.New("synthetic apply failure")
			}
			return nil
		},
		Lifecycle: lifecycle,
		Events:    sink,
	})

	if err := os.WriteFile(filepath.Join(root, "good.yaml"), []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write good: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "bad.yaml"), []byte("bad"), 0o644); err != nil {
		t.Fatalf("write bad: %v", err)
	}

	if err := loader.Load("good.yaml"); err != nil {
		t.Fatalf("initial good load failed: %v", err)
	}
	if err := loader.Load("bad.yaml"); err == nil {
		t.Fatal("bad apply unexpectedly succeeded")
	}
	if applyCalls != 2 {
		t.Fatalf("apply calls = %d want 2", applyCalls)
	}
	if lifecycle.State() != runtimepkg.StateConfigLoaded {
		t.Fatalf("lifecycle state = %s want %s", lifecycle.State(), runtimepkg.StateConfigLoaded)
	}
	expected := canonicalPath(t, filepath.Join(root, "good.yaml"))
	if loader.CurrentPath() != expected {
		t.Fatalf("current path after apply failure = %q want %q", loader.CurrentPath(), expected)
	}
	events := sink.Events()
	last := events[len(events)-1]
	if last.Kind != "config.load.failed" {
		t.Fatalf("last event kind = %q want config.load.failed", last.Kind)
	}
}

func TestLoaderAtomicApplyPreventsTornSharedLifecycleTransition(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "config.yaml")
	if err := os.WriteFile(configPath, []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	lifecycle := runtimepkg.NewLifecycle()
	sink := &eventspkg.Buffer{}
	applyStarted := make(chan struct{})
	releaseApply := make(chan struct{})

	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
		PrepareHome: noopPrepareHome,
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			return &mihomocfg.Config{}, nil
		},
		Apply: func(cfg *mihomocfg.Config, force bool) error {
			close(applyStarted)
			<-releaseApply
			return nil
		},
		Lifecycle: lifecycle,
		Events:    sink,
	})

	loadDone := make(chan error, 1)
	go func() {
		loadDone <- loader.Load("config.yaml")
	}()

	<-applyStarted
	close(releaseApply)
	if err := <-loadDone; err != nil {
		t.Fatalf("load returned torn failure: %v", err)
	}
	expected := canonicalPath(t, configPath)
	if loader.CurrentPath() != expected {
		t.Fatalf("current path = %q want %q", loader.CurrentPath(), expected)
	}

	if err := lifecycle.Transition(runtimepkg.StateShutdown); err != nil {
		t.Fatalf("post-load transition failed: %v", err)
	}
	events := sink.Events()
	if events[len(events)-1].Kind != "config.load.applied" {
		t.Fatalf("unexpected final event %#v", events[len(events)-1])
	}
}

func noopPrepareHome(string) error {
	return nil
}
