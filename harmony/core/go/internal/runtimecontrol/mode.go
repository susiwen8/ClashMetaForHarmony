package runtimecontrol

import (
	"errors"
	"sync"

	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type Mode uint32

const (
	ModeRule Mode = iota
	ModeGlobal
	ModeDirect
)

var ErrInvalidMode = errors.New("runtime mode is invalid")

type ModeBackend interface {
	CurrentMode() (Mode, error)
	ApplyMode(mode Mode) error
	CloseTrackedConnections()
}

type Service struct {
	mu      sync.Mutex
	backend ModeBackend
}

func NewService(backend ModeBackend) *Service {
	if backend == nil {
		backend = mihomoModeBackend{}
	}
	return &Service{backend: backend}
}

func (s *Service) Query() (Mode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	mode, err := s.backend.CurrentMode()
	if err != nil {
		return ModeRule, err
	}
	if !mode.Valid() {
		return ModeRule, ErrInvalidMode
	}
	return mode, nil
}

func (s *Service) Set(mode Mode) (Mode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	current, err := s.backend.CurrentMode()
	if err != nil {
		return ModeRule, err
	}
	if !current.Valid() {
		return ModeRule, ErrInvalidMode
	}
	if !mode.Valid() {
		return current, ErrInvalidMode
	}
	if current == mode {
		return current, nil
	}
	if err := s.backend.ApplyMode(mode); err != nil {
		return current, err
	}
	s.backend.CloseTrackedConnections()
	return mode, nil
}

func (m Mode) Valid() bool {
	return m == ModeRule || m == ModeGlobal || m == ModeDirect
}

func (m Mode) String() string {
	switch m {
	case ModeRule:
		return "RULE"
	case ModeGlobal:
		return "GLOBAL"
	case ModeDirect:
		return "DIRECT"
	default:
		return "UNKNOWN"
	}
}

type mihomoModeBackend struct{}

func (mihomoModeBackend) CurrentMode() (Mode, error) {
	switch tunnel.Mode() {
	case tunnel.Rule:
		return ModeRule, nil
	case tunnel.Global:
		return ModeGlobal, nil
	case tunnel.Direct:
		return ModeDirect, nil
	default:
		return ModeRule, ErrInvalidMode
	}
}

func (mihomoModeBackend) ApplyMode(mode Mode) error {
	switch mode {
	case ModeRule:
		tunnel.SetMode(tunnel.Rule)
	case ModeGlobal:
		tunnel.SetMode(tunnel.Global)
	case ModeDirect:
		tunnel.SetMode(tunnel.Direct)
	default:
		return ErrInvalidMode
	}
	return nil
}

func (mihomoModeBackend) CloseTrackedConnections() {
	if statistic.DefaultManager == nil {
		return
	}
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		_ = tracker.Close()
		return true
	})
}
