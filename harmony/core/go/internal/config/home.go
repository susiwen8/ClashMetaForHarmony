package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const homeDriftCode = "GEODATA_HOME_DRIFT"
const managedConfigUnavailableCode = "MANAGED_CONFIG_UNAVAILABLE"

var ErrManagedConfigUnavailable = errors.New("managed config is unavailable")

type PrepareHomeFunc func(string) error

type HomeManager struct {
	mu         sync.Mutex
	root       string
	setHomeDir func(string)
}

type HomeDriftError struct {
	Code string
}

type ManagedConfigPathError struct {
	Code string
}

func (e *HomeDriftError) Error() string {
	code := e.Code
	if code == "" {
		code = homeDriftCode
	}
	return code + ": managed config home changed"
}

func (e *ManagedConfigPathError) Error() string {
	code := e.Code
	if code == "" {
		code = managedConfigUnavailableCode
	}
	return code
}

func (e *ManagedConfigPathError) Unwrap() error {
	return ErrManagedConfigUnavailable
}

func NewHomeManager(setHomeDir func(string)) *HomeManager {
	if setHomeDir == nil {
		setHomeDir = func(string) {}
	}
	return &HomeManager{setHomeDir: setHomeDir}
}

func (m *HomeManager) Prepare(root string) error {
	if m == nil {
		return nil
	}

	canonicalRoot, err := canonicalRoot(root)
	if err != nil {
		return redactManagedConfigPathError(err)
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	if m.root == "" {
		m.setHomeDir(canonicalRoot)
		m.root = canonicalRoot
		return nil
	}
	if m.root != canonicalRoot {
		return &HomeDriftError{Code: homeDriftCode}
	}
	return nil
}

func ResolveManagedConfigPath(configPath string) (string, string, error) {
	if !filepath.IsAbs(configPath) {
		return "", "", ErrPathOutsideSandbox
	}
	if hasTraversalComponent(configPath) {
		return "", "", ErrPathOutsideSandbox
	}

	absPath, err := filepath.Abs(configPath)
	if err != nil {
		return "", "", redactManagedConfigPathError(err)
	}

	root, candidate, ok := matchManagedPath(filepath.Clean(absPath))
	if !ok {
		return "", "", ErrPathOutsideSandbox
	}

	canonicalManagedRoot, err := canonicalRoot(root)
	if err != nil {
		return "", "", redactManagedConfigPathError(err)
	}

	canonicalManagedPath, err := canonicalPath(absPath)
	if err != nil {
		return "", "", redactManagedConfigPathError(err)
	}

	relativePath, err := filepath.Rel(canonicalManagedRoot, canonicalManagedPath)
	if err != nil || !filepath.IsLocal(relativePath) || filepath.Clean(relativePath) != candidate {
		return "", "", ErrPathOutsideSandbox
	}

	return canonicalManagedRoot, candidate, nil
}

func canonicalRoot(root string) (string, error) {
	if root == "" {
		return "", errors.New("sandbox root is required")
	}
	return canonicalPath(root)
}

func canonicalPath(path string) (string, error) {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolvedPath, err := filepath.EvalSymlinks(absPath)
	if err == nil {
		return filepath.Clean(resolvedPath), nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	return filepath.Clean(absPath), nil
}

func matchManagedPath(configPath string) (string, string, bool) {
	if ext := strings.ToLower(filepath.Ext(configPath)); ext != ".yaml" {
		return "", "", false
	}

	volume := filepath.VolumeName(configPath)
	trimmed := strings.TrimPrefix(configPath, volume)
	trimmed = strings.TrimPrefix(trimmed, string(filepath.Separator))
	parts := strings.Split(trimmed, string(filepath.Separator))
	if len(parts) < 1 {
		return "", "", false
	}

	base := parts[len(parts)-1]
	switch {
	case len(parts) >= 3 && parts[len(parts)-2] == "tmp":
		root := rootFromParts(volume, parts[:len(parts)-2])
		if root == "" {
			return "", "", false
		}
		return root, filepath.Join("tmp", base), true
	case len(parts) >= 5 && parts[len(parts)-4] == "profiles" && (parts[len(parts)-2] == "valid" || parts[len(parts)-2] == "failed"):
		profile := parts[len(parts)-3]
		root := rootFromParts(volume, parts[:len(parts)-4])
		if root == "" || profile == "" {
			return "", "", false
		}
		return root, filepath.Join("profiles", profile, parts[len(parts)-2], base), true
	case len(parts) >= 2:
		for _, part := range parts[:len(parts)-1] {
			if part == "tmp" || part == "profiles" {
				return "", "", false
			}
		}
		root := rootFromParts(volume, parts[:len(parts)-1])
		if root == "" {
			return "", "", false
		}
		return root, base, true
	default:
		return "", "", false
	}
}

func hasTraversalComponent(path string) bool {
	for _, part := range strings.FieldsFunc(path, func(r rune) bool {
		return r == filepath.Separator || r == '/' || r == '\\'
	}) {
		if part == ".." {
			return true
		}
	}
	return false
}

func rootFromParts(volume string, parts []string) string {
	if len(parts) == 0 {
		return ""
	}
	if volume != "" {
		return volume + string(filepath.Separator) + filepath.Join(parts...)
	}
	return string(filepath.Separator) + filepath.Join(parts...)
}

func redactManagedConfigPathError(err error) error {
	if err == nil {
		return nil
	}
	return &ManagedConfigPathError{Code: managedConfigUnavailableCode}
}
