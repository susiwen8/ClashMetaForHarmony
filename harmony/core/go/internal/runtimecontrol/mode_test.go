package runtimecontrol

import (
	"errors"
	"testing"
)

type fakeModeBackend struct {
	current    Mode
	setCalls   []Mode
	closeCalls int
	queryErr   error
	setErr     error
}

func (f *fakeModeBackend) CurrentMode() (Mode, error) {
	if f.queryErr != nil {
		return ModeRule, f.queryErr
	}
	return f.current, nil
}

func (f *fakeModeBackend) ApplyMode(mode Mode) error {
	if f.setErr != nil {
		return f.setErr
	}
	f.current = mode
	f.setCalls = append(f.setCalls, mode)
	return nil
}

func (f *fakeModeBackend) CloseTrackedConnections() {
	f.closeCalls++
}

func TestServiceQueriesAndSwitchesEveryClosedMode(t *testing.T) {
	backend := &fakeModeBackend{current: ModeRule}
	service := NewService(backend)

	mode, err := service.Query()
	if err != nil || mode != ModeRule {
		t.Fatalf("Query() = (%v, %v), want (%v, nil)", mode, err, ModeRule)
	}

	for _, target := range []Mode{ModeGlobal, ModeDirect, ModeRule} {
		mode, err = service.Set(target)
		if err != nil || mode != target {
			t.Fatalf("Set(%v) = (%v, %v), want (%v, nil)", target, mode, err, target)
		}
	}
	if backend.closeCalls != 3 {
		t.Fatalf("CloseTrackedConnections calls = %d, want 3", backend.closeCalls)
	}
}

func TestServiceRejectsInvalidModeWithoutMutation(t *testing.T) {
	backend := &fakeModeBackend{current: ModeRule}
	service := NewService(backend)

	mode, err := service.Set(Mode(99))
	if !errors.Is(err, ErrInvalidMode) {
		t.Fatalf("Set(invalid) error = %v, want ErrInvalidMode", err)
	}
	if mode != ModeRule {
		t.Fatalf("Set(invalid) mode = %v, want existing %v", mode, ModeRule)
	}
	if len(backend.setCalls) != 0 || backend.closeCalls != 0 {
		t.Fatalf("invalid mode mutated backend: set=%v close=%d", backend.setCalls, backend.closeCalls)
	}
}

func TestServiceDoesNotCloseConnectionsForNoOpOrFailedSwitch(t *testing.T) {
	backend := &fakeModeBackend{current: ModeGlobal}
	service := NewService(backend)

	mode, err := service.Set(ModeGlobal)
	if err != nil || mode != ModeGlobal {
		t.Fatalf("no-op Set = (%v, %v)", mode, err)
	}
	if backend.closeCalls != 0 || len(backend.setCalls) != 0 {
		t.Fatalf("no-op switch mutated backend: set=%v close=%d", backend.setCalls, backend.closeCalls)
	}

	backend.setErr = errors.New("apply failed")
	mode, err = service.Set(ModeDirect)
	if err == nil || mode != ModeGlobal {
		t.Fatalf("failed Set = (%v, %v), want existing mode and error", mode, err)
	}
	if backend.closeCalls != 0 {
		t.Fatalf("failed switch closed %d connection sets", backend.closeCalls)
	}
}
