package config

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"

	mihomocfg "github.com/metacubex/mihomo/config"
)

func TestResolveManagedConfigPathAllowedShapes(t *testing.T) {
	filesRoot := t.TempDir()
	mustWriteManagedFile(t, filepath.Join(filesRoot, "tmp", "stage.yaml"))
	mustWriteManagedFile(t, filepath.Join(filesRoot, "profiles", "alpha", "valid", "rev-a.yaml"))
	mustWriteManagedFile(t, filepath.Join(filesRoot, "profiles", "alpha", "failed", "rev-b.yaml"))
	mustWriteManagedFile(t, filepath.Join(filesRoot, "self-test.yaml"))

	tests := []struct {
		name          string
		path          string
		wantCandidate string
	}{
		{
			name:          "tmp revision",
			path:          filepath.Join(filesRoot, "tmp", "stage.yaml"),
			wantCandidate: filepath.Join("tmp", "stage.yaml"),
		},
		{
			name:          "retained valid revision",
			path:          filepath.Join(filesRoot, "profiles", "alpha", "valid", "rev-a.yaml"),
			wantCandidate: filepath.Join("profiles", "alpha", "valid", "rev-a.yaml"),
		},
		{
			name:          "retained failed revision",
			path:          filepath.Join(filesRoot, "profiles", "alpha", "failed", "rev-b.yaml"),
			wantCandidate: filepath.Join("profiles", "alpha", "failed", "rev-b.yaml"),
		},
		{
			name:          "self test",
			path:          filepath.Join(filesRoot, "self-test.yaml"),
			wantCandidate: "self-test.yaml",
		},
	}

	wantRoot := mustEvalPath(t, filesRoot)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root, candidate, err := ResolveManagedConfigPath(tt.path)
			if err != nil {
				t.Fatalf("ResolveManagedConfigPath returned error: %v", err)
			}
			if root != wantRoot {
				t.Fatalf("root = %q want %q", root, wantRoot)
			}
			if candidate != tt.wantCandidate {
				t.Fatalf("candidate = %q want %q", candidate, tt.wantCandidate)
			}
		})
	}
}

func TestResolveManagedConfigPathRejectsTraversalMalformedAndSymlinkEscape(t *testing.T) {
	filesRoot := t.TempDir()
	foreignRoot := t.TempDir()
	mustWriteManagedFile(t, filepath.Join(filesRoot, "tmp", "stage.yaml"))
	mustWriteManagedFile(t, filepath.Join(filesRoot, "profiles", "alpha", "valid", "rev-a.yaml"))
	mustWriteManagedFile(t, filepath.Join(filesRoot, "profiles", "alpha", "failed", "rev-b.yaml"))
	mustWriteManagedFile(t, filepath.Join(filesRoot, "self-test.yaml"))
	mustWriteManagedFile(t, filepath.Join(filesRoot, "tmp", "nested", "stage.yaml"))
	mustWriteManagedFile(t, filepath.Join(filesRoot, "profiles", "alpha", "valid.yaml"))

	tests := []struct {
		name string
		path string
	}{
		{
			name: "raw traversal component",
			path: filepath.Join(filesRoot, "tmp") + string(filepath.Separator) + ".." + string(filepath.Separator) + "self-test.yaml",
		},
		{
			name: "malformed tmp depth",
			path: filepath.Join(filesRoot, "tmp", "nested", "stage.yaml"),
		},
		{
			name: "malformed profile depth",
			path: filepath.Join(filesRoot, "profiles", "alpha", "valid.yaml"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, err := ResolveManagedConfigPath(tt.path)
			if !errors.Is(err, ErrPathOutsideSandbox) {
				t.Fatalf("expected ErrPathOutsideSandbox, got %v", err)
			}
		})
	}

	t.Run("symlink escape", func(t *testing.T) {
		if runtime.GOOS == "windows" {
			t.Skip("symlink escape test requires unix-style symlink support")
		}

		outsidePath := filepath.Join(foreignRoot, "outside.yaml")
		mustWriteManagedFile(t, outsidePath)
		escapePath := filepath.Join(filesRoot, "tmp", "escape.yaml")
		if err := os.Symlink(outsidePath, escapePath); err != nil {
			t.Fatalf("symlink escape: %v", err)
		}

		_, _, err := ResolveManagedConfigPath(escapePath)
		if !errors.Is(err, ErrPathOutsideSandbox) {
			t.Fatalf("expected ErrPathOutsideSandbox, got %v", err)
		}
	})
}

func TestResolveManagedConfigPathRedactsMissingManagedAbsolutePath(t *testing.T) {
	filesRoot := t.TempDir()
	missingPath := filepath.Join(filesRoot, "tmp", "missing-secret-profile.yaml")

	_, _, err := ResolveManagedConfigPath(missingPath)
	if err == nil {
		t.Fatal("ResolveManagedConfigPath unexpectedly succeeded")
	}
	if !errors.Is(err, ErrManagedConfigUnavailable) {
		t.Fatalf("expected ErrManagedConfigUnavailable, got %v", err)
	}

	var managedErr *ManagedConfigPathError
	if !errors.As(err, &managedErr) {
		t.Fatalf("expected ManagedConfigPathError, got %T", err)
	}
	if managedErr.Code != managedConfigUnavailableCode {
		t.Fatalf("managed error code = %q want %q", managedErr.Code, managedConfigUnavailableCode)
	}

	assertNoPathLeak(t, err.Error(), missingPath)
	if got := err.Error(); got != managedConfigUnavailableCode {
		t.Fatalf("error text = %q want %q", got, managedConfigUnavailableCode)
	}
}

func TestHomeManagerPrepareInitializesOnceAndCanonicalizesRoot(t *testing.T) {
	root := t.TempDir()
	aliasParent := t.TempDir()
	alias := filepath.Join(aliasParent, "files")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatalf("symlink alias: %v", err)
	}

	var calls int
	var applied []string
	manager := NewHomeManager(func(path string) {
		calls++
		applied = append(applied, path)
	})

	if err := manager.Prepare(alias); err != nil {
		t.Fatalf("Prepare(alias): %v", err)
	}
	if err := manager.Prepare(root); err != nil {
		t.Fatalf("Prepare(root): %v", err)
	}
	if calls != 1 {
		t.Fatalf("setHomeDir calls = %d want 1", calls)
	}

	wantRoot := mustEvalPath(t, root)
	if len(applied) != 1 || applied[0] != wantRoot {
		t.Fatalf("applied roots = %#v want [%q]", applied, wantRoot)
	}
}

func TestHomeManagerPrepareConcurrentFirstUseCallsSetterOnce(t *testing.T) {
	root := t.TempDir()
	setterCalls := 0
	manager := NewHomeManager(func(path string) {
		setterCalls++
	})

	start := make(chan struct{})
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			errs <- manager.Prepare(root)
		}()
	}

	close(start)
	wg.Wait()
	close(errs)

	for err := range errs {
		if err != nil {
			t.Fatalf("Prepare returned error: %v", err)
		}
	}
	if setterCalls != 1 {
		t.Fatalf("setHomeDir calls = %d want 1", setterCalls)
	}
}

func TestHomeManagerPrepareRejectsDriftWithTypedRedactedError(t *testing.T) {
	firstRoot := t.TempDir()
	secondRoot := t.TempDir()

	manager := NewHomeManager(func(path string) {})
	if err := manager.Prepare(firstRoot); err != nil {
		t.Fatalf("Prepare(firstRoot): %v", err)
	}

	err := manager.Prepare(secondRoot)
	if err == nil {
		t.Fatal("Prepare(secondRoot) unexpectedly succeeded")
	}

	var driftErr *HomeDriftError
	if !errors.As(err, &driftErr) {
		t.Fatalf("expected HomeDriftError, got %T", err)
	}
	if driftErr.Code != "GEODATA_HOME_DRIFT" {
		t.Fatalf("drift code = %q want GEODATA_HOME_DRIFT", driftErr.Code)
	}

	text := err.Error()
	if text == "" {
		t.Fatal("redacted error text must not be empty")
	}
	if containsPathFragment(text, firstRoot) || containsPathFragment(text, secondRoot) {
		t.Fatalf("error leaked root fragment: %q", text)
	}
}

func TestValidateFileWithInjectedParserStillUsesDefaultHomeManager(t *testing.T) {
	root := t.TempDir()
	mustWriteManagedFile(t, filepath.Join(root, "config.yaml"))

	var setCalls int
	manager := NewHomeManager(func(path string) {
		setCalls++
	})

	restore := swapDefaultHomeManager(t, manager)
	defer restore()

	parseCalls := 0
	if err := ValidateFileWithDeps(root, "config.yaml", ValidateDeps{
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			parseCalls++
			if setCalls != 1 {
				t.Fatalf("parse ran before default home prepare: setCalls=%d", setCalls)
			}
			return &mihomocfg.Config{}, nil
		},
	}); err != nil {
		t.Fatalf("ValidateFileWithDeps failed: %v", err)
	}

	if setCalls != 1 {
		t.Fatalf("default home manager calls = %d want 1", setCalls)
	}
	if parseCalls != 1 {
		t.Fatalf("parse calls = %d want 1", parseCalls)
	}
}

func TestSanitizeValidationErrorRebuildsIncomingValidationError(t *testing.T) {
	index := -7
	line := 22
	err := sanitizeValidationError(&ValidationError{
		Code:  "https://user:pass@[2001:db8::1]:8443",
		Field: "node-01 /data/user/0/app/files/config.yaml host:8443",
		Index: &index,
		Line:  &line,
	})

	var validationErr *ValidationError
	if !errors.As(err, &validationErr) {
		t.Fatalf("expected ValidationError, got %T", err)
	}
	if validationErr.Code != "VALIDATION_UNKNOWN" {
		t.Fatalf("validation code = %q want VALIDATION_UNKNOWN", validationErr.Code)
	}
	if validationErr.Field != "" {
		t.Fatalf("validation field leaked: %q", validationErr.Field)
	}
	if validationErr.Index != nil {
		t.Fatalf("validation index leaked: %d", *validationErr.Index)
	}
	if validationErr.Line == nil || *validationErr.Line != 22 {
		t.Fatalf("validation line = %#v want 22", validationErr.Line)
	}

	text := err.Error()
	for _, forbidden := range []string{"user", "pass", "2001:db8::1", "8443", "node-01", "/data/user/0/app/files/config.yaml"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("sanitized error leaked %q in %q", forbidden, text)
		}
	}
	if text != "VALIDATION_UNKNOWN line=22" {
		t.Fatalf("sanitized text = %q want %q", text, "VALIDATION_UNKNOWN line=22")
	}
}

func TestProductionDefaultHomeManagerRejectsForeignRootBeforeSecondParse(t *testing.T) {
	firstRoot := t.TempDir()
	secondRoot := t.TempDir()
	mustWriteManagedFile(t, filepath.Join(firstRoot, "self-test.yaml"))
	mustWriteManagedFile(t, filepath.Join(secondRoot, "self-test.yaml"))

	firstSandbox, firstCandidate, err := ResolveManagedConfigPath(filepath.Join(firstRoot, "self-test.yaml"))
	if err != nil {
		t.Fatalf("ResolveManagedConfigPath(first): %v", err)
	}
	secondSandbox, secondCandidate, err := ResolveManagedConfigPath(filepath.Join(secondRoot, "self-test.yaml"))
	if err != nil {
		t.Fatalf("ResolveManagedConfigPath(second): %v", err)
	}

	var setCalls int
	manager := NewHomeManager(func(path string) {
		setCalls++
	})
	restore := swapDefaultHomeManager(t, manager)
	defer restore()

	validateParseCalls := 0
	if err := ValidateFileWithDeps(firstSandbox, firstCandidate, ValidateDeps{
		ParseBytes: func(body []byte) (*mihomocfg.Config, error) {
			validateParseCalls++
			return &mihomocfg.Config{}, nil
		},
	}); err != nil {
		t.Fatalf("ValidateFileWithDeps(first): %v", err)
	}

	loadParseCalls := 0
	loader := NewLoader(secondSandbox)
	loader.parseBytes = func(body []byte) (*mihomocfg.Config, error) {
		loadParseCalls++
		return &mihomocfg.Config{}, nil
	}
	loader.apply = func(cfg *mihomocfg.Config, force bool) error { return nil }

	err = loader.Load(secondCandidate)
	if err == nil {
		t.Fatal("Loader.Load(second) unexpectedly succeeded")
	}
	var driftErr *HomeDriftError
	if !errors.As(err, &driftErr) {
		t.Fatalf("expected HomeDriftError, got %T", err)
	}
	if driftErr.Code != homeDriftCode {
		t.Fatalf("drift code = %q want %q", driftErr.Code, homeDriftCode)
	}
	if validateParseCalls != 1 {
		t.Fatalf("first parse calls = %d want 1", validateParseCalls)
	}
	if loadParseCalls != 0 {
		t.Fatalf("second parse calls = %d want 0", loadParseCalls)
	}
	if setCalls != 1 {
		t.Fatalf("setHomeDir calls = %d want 1", setCalls)
	}
}

func mustWriteManagedFile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func mustEvalPath(t *testing.T, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err == nil {
		return resolved
	}
	absPath, absErr := filepath.Abs(path)
	if absErr != nil {
		t.Fatalf("abs %s: %v", path, absErr)
	}
	return filepath.Clean(absPath)
}

func containsPathFragment(text, path string) bool {
	base := filepath.Base(path)
	return base != "." && base != string(filepath.Separator) && base != "" && (contains(text, path) || contains(text, base))
}

func contains(text, fragment string) bool {
	return fragment != "" && strings.Contains(text, fragment)
}

func assertNoPathLeak(t *testing.T, text, path string) {
	t.Helper()
	for _, fragment := range pathFragments(path) {
		if fragment != "" && strings.Contains(text, fragment) {
			t.Fatalf("error leaked path fragment %q in %q", fragment, text)
		}
	}
}

func pathFragments(path string) []string {
	cleaned := filepath.Clean(path)
	fragments := []string{cleaned, filepath.Base(cleaned)}
	parent := filepath.Dir(cleaned)
	if parent != "." && parent != string(filepath.Separator) {
		fragments = append(fragments, parent, filepath.Base(parent))
	}
	return fragments
}

func swapDefaultHomeManager(t *testing.T, manager *HomeManager) func() {
	t.Helper()
	previous := defaultHomeManager
	defaultHomeManager = manager
	return func() {
		defaultHomeManager = previous
	}
}
