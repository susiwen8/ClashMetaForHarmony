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
	_, _, err := parseWithinSandbox(sandboxRoot, candidate, mihomoexecutor.ParseWithPath)
	return err
}

type ParseFunc func(path string) (*mihomocfg.Config, error)

func parseWithinSandbox(sandboxRoot, candidate string, parse ParseFunc) (string, *mihomocfg.Config, error) {
	resolvedPath, err := resolvePath(sandboxRoot, candidate)
	if err != nil {
		return "", nil, err
	}

	cfg, err := parse(resolvedPath)
	if err != nil {
		return "", nil, err
	}

	return resolvedPath, cfg, nil
}

func resolvePath(sandboxRoot, candidate string) (string, error) {
	if strings.HasPrefix(candidate, "content://") {
		return "", ErrContentURIUnsupported
	}

	if sandboxRoot == "" {
		return "", errors.New("sandbox root is required")
	}

	root, err := filepath.Abs(sandboxRoot)
	if err != nil {
		return "", fmt.Errorf("resolve sandbox root: %w", err)
	}
	if resolvedRoot, err := filepath.EvalSymlinks(root); err == nil {
		root = resolvedRoot
	}

	target := candidate
	if !filepath.IsAbs(target) {
		target = filepath.Join(root, target)
	}

	target = filepath.Clean(target)
	if _, err := os.Stat(target); err == nil {
		if resolvedTarget, evalErr := filepath.EvalSymlinks(target); evalErr == nil {
			target = resolvedTarget
		}
	}

	rel, err := filepath.Rel(root, target)
	if err != nil {
		return "", fmt.Errorf("resolve relative path: %w", err)
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", ErrPathOutsideSandbox
	}

	return target, nil
}
