package runtime

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"

	mihomoexecutor "github.com/metacubex/mihomo/hub/executor"
	mihomohttp "github.com/metacubex/mihomo/listener/http"
	mihomosocks "github.com/metacubex/mihomo/listener/socks"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var ErrRuntimeBusy = errors.New("runtime is already transitioning or running")

type ListenerHandle interface {
	Address() string
	Close() error
}

type LocalProxyDeps struct {
	Prepare           func(configPath string) error
	HTTPFactory       func(addr string) (ListenerHandle, error)
	SOCKSFactory      func(addr string) (ListenerHandle, error)
	CloseConnections  func() error
	Shutdown          func() error
	Events            EventSink
	MaxMessageBytes   int
	MaxSnapshotBytes  int
	AllowedLoopbackIP string
}

type LocalProxy struct {
	mu     sync.Mutex
	deps   LocalProxyDeps
	state  RuntimeState
	latest Snapshot

	httpListener  ListenerHandle
	socksListener ListenerHandle
}

func NewLocalProxy() *LocalProxy {
	return NewLocalProxyWithDeps(LocalProxyDeps{})
}

func NewLocalProxyWithDeps(deps LocalProxyDeps) *LocalProxy {
	if deps.Prepare == nil {
		deps.Prepare = func(string) error { return nil }
	}
	if deps.HTTPFactory == nil {
		deps.HTTPFactory = func(addr string) (ListenerHandle, error) {
			return mihomohttp.NewWithAuthenticate(addr, tunnel.Tunnel, false)
		}
	}
	if deps.SOCKSFactory == nil {
		deps.SOCKSFactory = func(addr string) (ListenerHandle, error) {
			return mihomosocks.New(addr, tunnel.Tunnel)
		}
	}
	if deps.CloseConnections == nil {
		deps.CloseConnections = func() error {
			statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
				_ = tracker.Close()
				return true
			})
			return nil
		}
	}
	if deps.Shutdown == nil {
		deps.Shutdown = func() error {
			mihomoexecutor.Shutdown()
			return nil
		}
	}
	if deps.Events == nil {
		deps.Events = DiscardEvents{}
	}
	if deps.MaxMessageBytes <= 0 {
		deps.MaxMessageBytes = 4096
	}
	if deps.MaxSnapshotBytes <= 0 {
		deps.MaxSnapshotBytes = 4096
	}
	if deps.AllowedLoopbackIP == "" {
		deps.AllowedLoopbackIP = "127.0.0.1"
	}

	return &LocalProxy{
		deps:   deps,
		state:  RuntimeStopped,
		latest: Snapshot{State: RuntimeStopped},
	}
}

func (p *LocalProxy) Snapshot() Snapshot {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.latest
}

func (p *LocalProxy) Start(options StartOptions) (Snapshot, error) {
	if err := p.validateStartOptions(options); err != nil {
		return p.failStart(options.ConfigPath, err), err
	}

	startingEvent := RuntimeEvent{
		Kind:  "runtime.starting",
		State: RuntimeStarting,
	}
	p.mu.Lock()
	if p.state == RuntimeStarting || p.state == RuntimeRunning || p.state == RuntimeStopping {
		p.mu.Unlock()
		return Snapshot{}, ErrRuntimeBusy
	}
	p.state = RuntimeStarting
	p.latest = Snapshot{
		State:            RuntimeStarting,
		ActiveConfigPath: truncateUTF8(options.ConfigPath, p.deps.MaxSnapshotBytes),
	}
	p.mu.Unlock()
	p.publish(startingEvent)

	if err := p.deps.Prepare(options.ConfigPath); err != nil {
		return p.failStart(options.ConfigPath, err), err
	}

	httpListener, err := p.deps.HTTPFactory(options.HTTPListenAddress)
	if err != nil {
		return p.failStart(options.ConfigPath, fmt.Errorf("bind HTTP listener %s: %w", options.HTTPListenAddress, err)), err
	}

	socksListener, err := p.deps.SOCKSFactory(options.SOCKSListenAddress)
	if err != nil {
		_ = httpListener.Close()
		return p.failStart(options.ConfigPath, fmt.Errorf("bind SOCKS listener %s: %w", options.SOCKSListenAddress, err)), err
	}

	snapshot := Snapshot{
		State:            RuntimeRunning,
		ActiveConfigPath: truncateUTF8(options.ConfigPath, p.deps.MaxSnapshotBytes),
		HTTPAddress:      truncateUTF8(httpListener.Address(), p.deps.MaxSnapshotBytes),
		SOCKSAddress:     truncateUTF8(socksListener.Address(), p.deps.MaxSnapshotBytes),
	}

	p.mu.Lock()
	p.httpListener = httpListener
	p.socksListener = socksListener
	p.state = RuntimeRunning
	p.latest = snapshot
	p.mu.Unlock()

	p.publish(RuntimeEvent{
		Kind:         "runtime.running",
		State:        RuntimeRunning,
		Message:      truncateUTF8("local HTTP and SOCKS listeners are running", p.deps.MaxMessageBytes),
		HTTPAddress:  snapshot.HTTPAddress,
		SOCKSAddress: snapshot.SOCKSAddress,
	})

	return snapshot, nil
}

func (p *LocalProxy) Stop() (Snapshot, error) {
	p.mu.Lock()
	switch p.state {
	case RuntimeStopped:
		snapshot := p.latest
		p.mu.Unlock()
		return snapshot, nil
	case RuntimeStarting, RuntimeStopping:
		p.mu.Unlock()
		return Snapshot{}, ErrRuntimeBusy
	}

	httpListener := p.httpListener
	socksListener := p.socksListener
	p.httpListener = nil
	p.socksListener = nil
	p.state = RuntimeStopping
	p.latest = Snapshot{State: RuntimeStopping}
	p.mu.Unlock()

	p.publish(RuntimeEvent{
		Kind:  "runtime.stopping",
		State: RuntimeStopping,
	})

	if err := closeListener(httpListener); err != nil {
		return p.failStop(err), err
	}
	if err := closeListener(socksListener); err != nil {
		return p.failStop(err), err
	}
	if err := p.deps.CloseConnections(); err != nil {
		return p.failStop(fmt.Errorf("close tracked connections: %w", err)), err
	}
	if err := p.deps.Shutdown(); err != nil {
		return p.failStop(fmt.Errorf("executor shutdown: %w", err)), err
	}

	snapshot := Snapshot{State: RuntimeStopped}
	p.mu.Lock()
	p.state = RuntimeStopped
	p.latest = snapshot
	p.mu.Unlock()

	p.publish(RuntimeEvent{
		Kind:  "runtime.stopped",
		State: RuntimeStopped,
	})

	return snapshot, nil
}

func (p *LocalProxy) failStart(configPath string, err error) Snapshot {
	snapshot := Snapshot{
		State:            RuntimeError,
		ActiveConfigPath: truncateUTF8(configPath, p.deps.MaxSnapshotBytes),
		LastError:        truncateUTF8(err.Error(), p.deps.MaxMessageBytes),
	}

	p.mu.Lock()
	p.state = RuntimeError
	p.latest = snapshot
	p.httpListener = nil
	p.socksListener = nil
	p.mu.Unlock()

	p.publish(RuntimeEvent{
		Kind:    "runtime.error",
		State:   RuntimeError,
		Message: snapshot.LastError,
	})

	return snapshot
}

func (p *LocalProxy) failStop(err error) Snapshot {
	snapshot := Snapshot{
		State:     RuntimeError,
		LastError: truncateUTF8(err.Error(), p.deps.MaxMessageBytes),
	}
	p.mu.Lock()
	p.state = RuntimeError
	p.latest = snapshot
	p.mu.Unlock()
	p.publish(RuntimeEvent{
		Kind:    "runtime.error",
		State:   RuntimeError,
		Message: snapshot.LastError,
	})
	return snapshot
}

func (p *LocalProxy) publish(event RuntimeEvent) {
	event.Message = truncateUTF8(event.Message, p.deps.MaxMessageBytes)
	event.HTTPAddress = truncateUTF8(event.HTTPAddress, p.deps.MaxSnapshotBytes)
	event.SOCKSAddress = truncateUTF8(event.SOCKSAddress, p.deps.MaxSnapshotBytes)
	p.deps.Events.Publish(event)
}

func (p *LocalProxy) validateStartOptions(options StartOptions) error {
	if strings.TrimSpace(options.ConfigPath) == "" {
		return errors.New("config path must not be empty")
	}
	if err := validateLoopbackAddress(options.HTTPListenAddress, p.deps.AllowedLoopbackIP); err != nil {
		return fmt.Errorf("HTTP listen address: %w", err)
	}
	if err := validateLoopbackAddress(options.SOCKSListenAddress, p.deps.AllowedLoopbackIP); err != nil {
		return fmt.Errorf("SOCKS listen address: %w", err)
	}
	return nil
}

func validateLoopbackAddress(raw string, allowedHost string) error {
	host, port, err := net.SplitHostPort(raw)
	if err != nil {
		return err
	}
	if host != allowedHost {
		return fmt.Errorf("must bind loopback %s", allowedHost)
	}
	numericPort, err := strconv.Atoi(port)
	if err != nil {
		return fmt.Errorf("invalid port: %w", err)
	}
	if numericPort < 0 || numericPort > 65535 {
		return fmt.Errorf("port %d out of range", numericPort)
	}
	return nil
}

func closeListener(listener ListenerHandle) error {
	if listener == nil {
		return nil
	}
	return listener.Close()
}

func truncateUTF8(text string, maxBytes int) string {
	if maxBytes <= 0 || len(text) <= maxBytes {
		return text
	}

	truncated := text[:maxBytes]
	for !utf8.ValidString(truncated) && len(truncated) > 0 {
		truncated = truncated[:len(truncated)-1]
	}
	return truncated
}
