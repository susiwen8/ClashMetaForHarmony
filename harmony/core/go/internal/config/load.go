package config

import (
	"sync"

	mihomocfg "github.com/metacubex/mihomo/config"
	mihomoexecutor "github.com/metacubex/mihomo/hub/executor"

	eventspkg "github.com/clashmetaforandroid/harmony/core/go/internal/events"
	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
)

type ApplyFunc func(cfg *mihomocfg.Config, force bool) error

type LoaderDeps struct {
	Parse     ParseFunc
	Apply     ApplyFunc
	Lifecycle *runtimepkg.Lifecycle
	Events    eventspkg.Sink
}

type Loader struct {
	sandboxRoot string

	parse     ParseFunc
	apply     ApplyFunc
	lifecycle *runtimepkg.Lifecycle
	events    eventspkg.Sink

	mu          sync.RWMutex
	currentPath string
	current     *mihomocfg.Config
}

func NewLoader(sandboxRoot string) *Loader {
	return NewLoaderWithDeps(sandboxRoot, LoaderDeps{})
}

func NewLoaderWithDeps(sandboxRoot string, deps LoaderDeps) *Loader {
	parse := deps.Parse
	if parse == nil {
		parse = mihomoexecutor.ParseWithPath
	}

	apply := deps.Apply
	if apply == nil {
		apply = func(cfg *mihomocfg.Config, force bool) error {
			mihomoexecutor.ApplyConfig(cfg, force)
			return nil
		}
	}

	lifecycle := deps.Lifecycle
	if lifecycle == nil {
		lifecycle = runtimepkg.NewLifecycle()
	}

	sink := deps.Events
	if sink == nil {
		sink = eventspkg.Discard{}
	}

	return &Loader{
		sandboxRoot: sandboxRoot,
		parse:       parse,
		apply:       apply,
		lifecycle:   lifecycle,
		events:      sink,
	}
}

func (l *Loader) Load(candidate string) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	currentState := l.lifecycle.State()
	l.events.Publish(eventspkg.Event{
		Kind:  "config.load.started",
		Path:  candidate,
		State: string(currentState),
	})

	resolvedPath, cfg, err := parseWithinSandbox(l.sandboxRoot, candidate, l.parse)
	if err != nil {
		l.events.Publish(eventspkg.Event{
			Kind:    "config.load.failed",
			Path:    candidate,
			State:   string(l.lifecycle.State()),
			Message: err.Error(),
		})
		return err
	}

	if !l.lifecycle.CanTransition(runtimepkg.StateConfigLoaded) {
		err = runtimepkg.ErrIllegalTransition
		l.events.Publish(eventspkg.Event{
			Kind:    "config.load.failed",
			Path:    resolvedPath,
			State:   string(l.lifecycle.State()),
			Message: err.Error(),
		})
		return err
	}

	if err := l.apply(cfg, true); err != nil {
		l.events.Publish(eventspkg.Event{
			Kind:    "config.load.failed",
			Path:    resolvedPath,
			State:   string(l.lifecycle.State()),
			Message: err.Error(),
		})
		return err
	}

	if err := l.lifecycle.Transition(runtimepkg.StateConfigLoaded); err != nil {
		l.events.Publish(eventspkg.Event{
			Kind:    "config.load.failed",
			Path:    resolvedPath,
			State:   string(l.lifecycle.State()),
			Message: err.Error(),
		})
		return err
	}

	l.currentPath = resolvedPath
	l.current = cfg
	l.events.Publish(eventspkg.Event{
		Kind:  "config.load.applied",
		Path:  resolvedPath,
		State: string(l.lifecycle.State()),
	})
	return nil
}

func (l *Loader) CurrentPath() string {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.currentPath
}
