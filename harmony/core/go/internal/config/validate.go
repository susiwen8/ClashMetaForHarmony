package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	mihomocfg "github.com/metacubex/mihomo/config"
	mihomoexecutor "github.com/metacubex/mihomo/hub/executor"
)

var (
	ErrContentURIUnsupported = errors.New("content URI is not supported")
	ErrPathOutsideSandbox    = errors.New("path is outside the sandbox root")
)

func ValidateFile(sandboxRoot, candidate string) error {
	_, _, err := parseWithinSandbox(sandboxRoot, candidate, mihomoexecutor.ParseWithBytes)
	return err
}

type ParseBytesFunc func([]byte) (*mihomocfg.Config, error)

func parseWithinSandbox(sandboxRoot, candidate string, parse ParseBytesFunc) (string, *mihomocfg.Config, error) {
	resolvedPath, body, err := readWithinSandbox(sandboxRoot, candidate)
	if err != nil {
		return "", nil, err
	}

	cfg, err := parse(body)
	if err != nil {
		return "", nil, err
	}

	return resolvedPath, cfg, nil
}

func readWithinSandbox(sandboxRoot, candidate string) (string, []byte, error) {
	if strings.HasPrefix(candidate, "content://") {
		return "", nil, ErrContentURIUnsupported
	}

	if sandboxRoot == "" {
		return "", nil, errors.New("sandbox root is required")
	}

	root, err := filepath.Abs(sandboxRoot)
	if err != nil {
		return "", nil, fmt.Errorf("resolve sandbox root: %w", err)
	}
	if resolvedRoot, err := filepath.EvalSymlinks(root); err == nil {
		root = resolvedRoot
	}

	if filepath.IsAbs(candidate) {
		return "", nil, ErrPathOutsideSandbox
	}

	target := filepath.Clean(candidate)
	if target == "." || target == "" {
		return "", nil, ErrPathOutsideSandbox
	}
	if target == ".." || strings.HasPrefix(target, ".."+string(filepath.Separator)) {
		return "", nil, ErrPathOutsideSandbox
	}

	sandbox, err := os.OpenRoot(root)
	if err != nil {
		return "", nil, fmt.Errorf("open sandbox root: %w", err)
	}
	defer sandbox.Close()

	body, err := sandbox.ReadFile(target)
	if err != nil {
		if _, statErr := os.Lstat(filepath.Join(root, target)); statErr == nil {
			return "", nil, fmt.Errorf("%w: %s", ErrPathOutsideSandbox, target)
		}
		return "", nil, err
	}

	return filepath.Join(root, target), body, nil
}
