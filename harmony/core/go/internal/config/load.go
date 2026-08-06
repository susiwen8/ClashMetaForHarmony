package config

import "sync"

type Loader struct {
	sandboxRoot string

	mu          sync.RWMutex
	currentPath string
	current     any
}

func NewLoader(sandboxRoot string) *Loader {
	return &Loader{sandboxRoot: sandboxRoot}
}

func (l *Loader) Load(candidate string) error {
	resolvedPath, cfg, err := parseWithinSandbox(l.sandboxRoot, candidate)
	if err != nil {
		return err
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	l.currentPath = resolvedPath
	l.current = cfg
	return nil
}

func (l *Loader) CurrentPath() string {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.currentPath
}
