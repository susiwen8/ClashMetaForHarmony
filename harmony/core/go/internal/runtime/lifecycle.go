package runtime

import (
	"errors"
	"fmt"
	"sync"
)

type State string

const (
	StateIdle         State = "idle"
	StateConfigLoaded State = "config_loaded"
	StateRunning      State = "running"
	StateStopped      State = "stopped"
	StateShutdown     State = "shutdown"
)

var ErrIllegalTransition = errors.New("illegal lifecycle transition")

type Lifecycle struct {
	mu    sync.RWMutex
	state State
}

func NewLifecycle() *Lifecycle {
	return &Lifecycle{state: StateIdle}
}

func (l *Lifecycle) State() State {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.state
}

func (l *Lifecycle) Transition(next State) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if !transitionAllowed(l.state, next) {
		return fmt.Errorf("%w: %s -> %s", ErrIllegalTransition, l.state, next)
	}

	l.state = next
	return nil
}

func (l *Lifecycle) TransitionWith(next State, fn func() error) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if !transitionAllowed(l.state, next) {
		return fmt.Errorf("%w: %s -> %s", ErrIllegalTransition, l.state, next)
	}
	if err := fn(); err != nil {
		return err
	}
	l.state = next
	return nil
}

func (l *Lifecycle) CanTransition(next State) bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return transitionAllowed(l.state, next)
}

func transitionAllowed(current, next State) bool {
	switch current {
	case StateIdle:
		return next == StateConfigLoaded || next == StateShutdown
	case StateConfigLoaded:
		return next == StateConfigLoaded || next == StateRunning || next == StateShutdown
	case StateRunning:
		return next == StateStopped || next == StateShutdown
	case StateStopped:
		return next == StateConfigLoaded || next == StateRunning || next == StateShutdown
	case StateShutdown:
		return false
	default:
		return false
	}
}
