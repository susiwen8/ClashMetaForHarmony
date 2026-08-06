package config_test

import (
	"errors"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	mihomoconstant "github.com/metacubex/mihomo/constant"

	configwrap "github.com/clashmetaforandroid/harmony/core/go/internal/config"
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
