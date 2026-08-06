package config_test

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

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
	if err := configwrap.ValidateFile(root, fixtureRelPath("phase2-match-direct.yaml")); err != nil {
		t.Fatalf("ValidateFile returned error: %v", err)
	}
}

func TestValidateFileReturnsUsefulDetailsForInvalidFixture(t *testing.T) {
	root := repoHarmonyRoot(t)
	err := configwrap.ValidateFile(root, fixtureRelPath("phase2-invalid.yaml"))
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
	err := configwrap.ValidateFile(root, fixturePath(t, "phase2-match-direct.yaml"))
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
	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{})
	lifecycle := runtimepkg.NewLifecycle()
	sink := &eventspkg.Buffer{}
	good := &mihomocfg.Config{}
	bad := &mihomocfg.Config{}
	applyCalls := 0
	loader = configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
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
	transitionDone := make(chan error, 1)

	loader := configwrap.NewLoaderWithDeps(root, configwrap.LoaderDeps{
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
	go func() {
		transitionDone <- lifecycle.Transition(runtimepkg.StateShutdown)
	}()

	select {
	case err := <-transitionDone:
		t.Fatalf("transition completed before apply committed: %v", err)
	case <-time.After(50 * time.Millisecond):
	}

	close(releaseApply)
	if err := <-loadDone; err != nil {
		t.Fatalf("load returned torn failure: %v", err)
	}
	expected := canonicalPath(t, configPath)
	if loader.CurrentPath() != expected {
		t.Fatalf("current path = %q want %q", loader.CurrentPath(), expected)
	}

	if err := <-transitionDone; err != nil {
		t.Fatalf("post-load transition failed: %v", err)
	}
	events := sink.Events()
	if events[len(events)-1].Kind != "config.load.applied" {
		t.Fatalf("unexpected final event %#v", events[len(events)-1])
	}
}
