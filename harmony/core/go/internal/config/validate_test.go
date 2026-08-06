package config_test

import (
	"errors"
	"path/filepath"
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
	if err := configwrap.ValidateFile(root, fixturePath(t, "phase2-match-direct.yaml")); err != nil {
		t.Fatalf("ValidateFile returned error: %v", err)
	}
}

func TestValidateFileReturnsUsefulDetailsForInvalidFixture(t *testing.T) {
	root := repoHarmonyRoot(t)
	err := configwrap.ValidateFile(root, fixturePath(t, "phase2-invalid.yaml"))
	if err == nil {
		t.Fatal("ValidateFile unexpectedly succeeded")
	}

	text := err.Error()
	if !strings.Contains(text, "mixed-port") && !strings.Contains(strings.ToLower(text), "line") {
		t.Fatalf("expected upstream detail in error, got %q", text)
	}
}

func TestValidateFileRejectsContentURIAndOutsideSandbox(t *testing.T) {
	root := repoHarmonyRoot(t)

	if err := configwrap.ValidateFile(root, "content://profile/config.yaml"); err == nil {
		t.Fatal("content:// path unexpectedly succeeded")
	}

	outside := filepath.Clean(filepath.Join(root, "..", "outside.yaml"))
	err := configwrap.ValidateFile(root, outside)
	if err == nil {
		t.Fatal("outside-sandbox path unexpectedly succeeded")
	}
	if !errors.Is(err, configwrap.ErrPathOutsideSandbox) {
		t.Fatalf("expected ErrPathOutsideSandbox, got %v", err)
	}
}

func TestLoaderPreservesPreviousConfigWhenLoadFails(t *testing.T) {
	root := repoHarmonyRoot(t)
	loader := configwrap.NewLoader(root)
	valid := fixturePath(t, "phase2-match-direct.yaml")
	invalid := fixturePath(t, "phase2-invalid.yaml")

	if err := loader.Load(valid); err != nil {
		t.Fatalf("initial load failed: %v", err)
	}

	if err := loader.Load(invalid); err == nil {
		t.Fatal("invalid load unexpectedly succeeded")
	}

	if got := loader.CurrentPath(); got != valid {
		t.Fatalf("current path changed after failed load: got %q want %q", got, valid)
	}
}

func TestLoaderAppliesOnceAndPreservesStateOnInvalidLoad(t *testing.T) {
	root := repoHarmonyRoot(t)
	valid := fixturePath(t, "phase2-match-direct.yaml")
	invalid := fixturePath(t, "phase2-invalid.yaml")
	lifecycle := runtimepkg.NewLifecycle()
	sink := &eventspkg.Buffer{}
	configObject := &mihomocfg.Config{}
	parseCalls := 0
	applyCalls := 0

	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
		Parse: func(path string) (*mihomocfg.Config, error) {
			parseCalls++
			switch path {
			case valid:
				return configObject, nil
			case invalid:
				return nil, errors.New("synthetic parse failure")
			default:
				t.Fatalf("unexpected path: %s", path)
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
	if loader.CurrentPath() != valid {
		t.Fatalf("current path after valid load = %q want %q", loader.CurrentPath(), valid)
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
	if loader.CurrentPath() != valid {
		t.Fatalf("current path after invalid load = %q want %q", loader.CurrentPath(), valid)
	}

	allEvents := sink.Events()
	if len(allEvents) < 4 {
		t.Fatalf("expected at least 4 events, got %d", len(allEvents))
	}
	if allEvents[2].Kind != "config.load.started" || allEvents[3].Kind != "config.load.failed" {
		t.Fatalf("unexpected invalid event order: %#v", allEvents[2:4])
	}
}
