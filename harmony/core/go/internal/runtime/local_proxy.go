package runtime

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	C "github.com/metacubex/mihomo/constant"
	mihomoexecutor "github.com/metacubex/mihomo/hub/executor"
	mihomohttp "github.com/metacubex/mihomo/listener/http"
	mihomosocks "github.com/metacubex/mihomo/listener/socks"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var ErrRuntimeBusy = errors.New("runtime is already transitioning or running")
var secretQueryPattern = regexp.MustCompile(`(?i)(token|password|secret)=([^&\s]+)`)
var urlUserinfoPattern = regexp.MustCompile(`://[^/\s:@]+:[^@\s/]+@`)

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
	Logs              LogSink
	BaseTunnel        C.Tunnel
	TunFactory        TunListenerFactory
	SocketProtector   SocketProtector
	SocketProtectAPILevel int
	SocketProtectTimeout  time.Duration
	MaxMessageBytes       int
	MaxSnapshotBytes      int
	AllowedLoopbackIP     string
	MaxLogContextFields int
	MaxLogFieldBytes    int
}

type LocalProxy struct {
	mu     sync.Mutex
	deps   LocalProxyDeps
	state  RuntimeState
	latest Snapshot

	httpListener  ListenerHandle
	socksListener ListenerHandle
	tunListener   TunListenerHandle

	tunSnapshot TunSnapshot
	tunRecorder *tunTraceRecorder
	tunTraces   []TunTrace

	lastStartOptions       StartOptions
	restoreSocketProtection func()
}

func joinErrors(primary error, extras ...error) error {
	errs := make([]error, 0, 1+len(extras))
	if primary != nil {
		errs = append(errs, primary)
	}
	for _, err := range extras {
		if err != nil {
			errs = append(errs, err)
		}
	}
	if len(errs) == 0 {
		return nil
	}
	return errors.Join(errs...)
}

type runtimeFailure struct {
	message string
}

func (e runtimeFailure) Error() string {
	return e.message
}

func NewLocalProxy() *LocalProxy {
	return NewLocalProxyWithDeps(LocalProxyDeps{})
}

func NewLocalProxyWithDeps(deps LocalProxyDeps) *LocalProxy {
	if deps.Prepare == nil {
		deps.Prepare = func(string) error { return nil }
	}
	if deps.BaseTunnel == nil {
		deps.BaseTunnel = tunnel.Tunnel
	}
	if deps.HTTPFactory == nil {
		deps.HTTPFactory = func(addr string) (ListenerHandle, error) {
			return mihomohttp.NewWithAuthenticate(addr, deps.BaseTunnel, false)
		}
	}
	if deps.SOCKSFactory == nil {
		deps.SOCKSFactory = func(addr string) (ListenerHandle, error) {
			return mihomosocks.New(addr, deps.BaseTunnel)
		}
	}
	if deps.TunFactory == nil {
		deps.TunFactory = productionTunListenerFactory
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
	if deps.Logs == nil {
		deps.Logs = DiscardLogs{}
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
	if deps.MaxLogContextFields <= 0 {
		deps.MaxLogContextFields = 4
	}
	if deps.MaxLogFieldBytes <= 0 {
		deps.MaxLogFieldBytes = 256
	}
	if deps.SocketProtectTimeout <= 0 {
		deps.SocketProtectTimeout = 3 * time.Second
	}

	return &LocalProxy{
		deps:   deps,
		state:  RuntimeStopped,
		latest: Snapshot{State: RuntimeStopped},
		tunSnapshot: TunSnapshot{
			State: TunStateIdle,
		},
	}
}

func (p *LocalProxy) Snapshot() Snapshot {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.latest
}

func (p *LocalProxy) TunSnapshot() TunSnapshot {
	p.mu.Lock()
	defer p.mu.Unlock()

	snapshot := p.tunSnapshot
	if p.tunRecorder != nil {
		snapshot.Counters = p.tunRecorder.Counters()
	}
	return snapshot
}

func (p *LocalProxy) CopyTunTraces(limit int) []TunTrace {
	p.mu.Lock()
	recorder := p.tunRecorder
	stored := append([]TunTrace(nil), p.tunTraces...)
	p.mu.Unlock()

	if recorder != nil {
		return recorder.Traces(limit)
	}
	if limit <= 0 || limit > len(stored) {
		limit = len(stored)
	}
	return append([]TunTrace(nil), stored[len(stored)-limit:]...)
}

func (p *LocalProxy) Start(options StartOptions) (Snapshot, error) {
	if err := p.validateStartOptions(options); err != nil {
		return p.commitStartFailure(options.ConfigPath, err)
	}
	snapshot, _, err := p.startRuntime(options, nil)
	return snapshot, err
}

func (p *LocalProxy) StartTun(options TunStartOptions) (TunSnapshot, error) {
	if strings.TrimSpace(options.SessionID) == "" {
		return p.commitTunStartFailure("", options.SessionID, "VPN_TUN_START_FAILED", errTunSessionRequired)
	}
	if options.TunFD <= 0 {
		return p.commitTunStartFailure(options.Base.ConfigPath, options.SessionID, "VPN_TUN_START_FAILED", errTunFDRequired)
	}

	base, restart, err := p.resolveTunBaseOptions(options)
	if err != nil {
		return p.commitTunStartFailure(options.Base.ConfigPath, options.SessionID, "VPN_TUN_START_FAILED", err)
	}
	if restart {
		if _, err := p.Stop(); err != nil {
			return p.commitTunStartFailure(base.ConfigPath, options.SessionID, "VPN_TUN_START_FAILED", err)
		}
	}

	_, tunSnapshot, err := p.startRuntime(base, &options)
	return tunSnapshot, err
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

	preserveError := p.state == RuntimeError
	previous := p.latest
	httpListener := p.httpListener
	socksListener := p.socksListener
	tunListener := p.tunListener
	tunRecorder := p.tunRecorder
	restoreSocketProtection := p.restoreSocketProtection
	previousTun := p.tunSnapshot
	p.httpListener = nil
	p.socksListener = nil
	p.tunListener = nil
	p.tunRecorder = nil
	p.restoreSocketProtection = nil
	p.state = RuntimeStopping
	if !preserveError {
		p.latest = Snapshot{State: RuntimeStopping}
	}
	p.mu.Unlock()

	p.publish(RuntimeEvent{
		Kind:  "runtime.stopping",
		State: RuntimeStopping,
	})
	p.publishLog(LogLevelInfo, "runtime.stopping", "stopping local proxy", nil)

	if restoreSocketProtection != nil {
		defer restoreSocketProtection()
	}
	var stopErr error
	if err := closeTunListener(tunListener); err != nil {
		stopErr = joinErrors(stopErr, err)
	}
	if err := closeListener(httpListener); err != nil {
		stopErr = joinErrors(stopErr, err)
	}
	if err := closeListener(socksListener); err != nil {
		stopErr = joinErrors(stopErr, err)
	}
	if err := p.deps.CloseConnections(); err != nil {
		stopErr = joinErrors(stopErr, fmt.Errorf("close tracked connections: %w", err))
	}
	if err := p.deps.Shutdown(); err != nil {
		stopErr = joinErrors(stopErr, fmt.Errorf("executor shutdown: %w", err))
	}

	snapshot := Snapshot{State: RuntimeStopped}
	tunSnapshot := TunSnapshot{State: TunStateStopped}
	if tunRecorder != nil {
		tunSnapshot.Counters = tunRecorder.Counters()
		p.tunTraces = tunRecorder.Traces(256)
	}
	if preserveError {
		snapshot = previous
		snapshot.State = RuntimeError
		tunSnapshot = previousTun
		tunSnapshot.State = TunStateError
	}
	p.mu.Lock()
	p.state = snapshot.State
	p.latest = snapshot
	p.tunSnapshot = tunSnapshot
	p.mu.Unlock()

	if preserveError {
		p.publish(RuntimeEvent{
			Kind:    "runtime.error",
			State:   RuntimeError,
			Message: snapshot.LastError,
		})
		p.publishLog(LogLevelError, "runtime.stop.error", snapshot.LastError, map[string]string{
			"configPath": snapshot.ActiveConfigPath,
		})
		return snapshot, nil
	}

	if stopErr != nil {
		return p.commitStopFailureWithTun(stopErr, tunSnapshot)
	}

	p.publish(RuntimeEvent{
		Kind:  "runtime.stopped",
		State: RuntimeStopped,
	})
	p.publishLog(LogLevelInfo, "runtime.stopped", "local proxy stopped", nil)

	return snapshot, nil
}

func (p *LocalProxy) startRuntime(options StartOptions, tunOptions *TunStartOptions) (Snapshot, TunSnapshot, error) {
	startingEvent := RuntimeEvent{
		Kind:  "runtime.starting",
		State: RuntimeStarting,
	}
	p.mu.Lock()
	if p.state == RuntimeStarting || p.state == RuntimeRunning || p.state == RuntimeStopping {
		p.mu.Unlock()
		return Snapshot{}, TunSnapshot{}, ErrRuntimeBusy
	}
	p.state = RuntimeStarting
	p.latest = Snapshot{
		State:            RuntimeStarting,
		ActiveConfigPath: truncateUTF8(options.ConfigPath, p.deps.MaxSnapshotBytes),
	}
	if tunOptions != nil {
		p.tunSnapshot = TunSnapshot{
			State:     TunStateStarting,
			SessionID: tunOptions.SessionID,
		}
		p.tunTraces = nil
	} else {
		p.tunSnapshot = TunSnapshot{State: TunStateIdle}
		p.tunTraces = nil
	}
	p.mu.Unlock()

	p.publish(startingEvent)
	p.publishLog(LogLevelInfo, "runtime.starting", "starting local proxy", map[string]string{
		"configPath":  options.ConfigPath,
		"httpListen":  options.HTTPListenAddress,
		"socksListen": options.SOCKSListenAddress,
	})

	if err := p.deps.Prepare(options.ConfigPath); err != nil {
		if tunOptions != nil {
			tunSnapshot, tunErr := p.commitTunStartFailure(options.ConfigPath, tunOptions.SessionID, "VPN_TUN_START_FAILED", err)
			return Snapshot{}, tunSnapshot, tunErr
		}
		snapshot, startErr := p.commitStartFailure(options.ConfigPath, err)
		return snapshot, TunSnapshot{}, startErr
	}

	restoreSocketProtection := func() {}
	if tunOptions != nil {
		restoreSocketProtection = installSocketProtection(SocketProtectionOptions{
			APILevel:         effectiveAPILevel(tunOptions, p.deps.SocketProtectAPILevel),
			Timeout:          p.deps.SocketProtectTimeout,
			Protector:        p.deps.SocketProtector,
			Events:           p.deps.Events,
			FailureCode:      "VPN_SOCKET_PROTECT_FAILED",
			FailureState:     RuntimeRunning,
			ProcessProtected: tunOptions.ProcessProtected,
		})
	}

	httpListener, err := p.deps.HTTPFactory(options.HTTPListenAddress)
	if err != nil {
		rollbackErr := p.rollbackStart(nil, restoreSocketProtection, nil)
		if tunOptions != nil {
			tunSnapshot, tunErr := p.commitTunStartFailure(
				options.ConfigPath,
				tunOptions.SessionID,
				"VPN_TUN_START_FAILED",
				joinErrors(fmt.Errorf("bind HTTP listener %s: %w", options.HTTPListenAddress, err), rollbackErr),
			)
			return Snapshot{}, tunSnapshot, tunErr
		}
		snapshot, startErr := p.commitStartFailure(
			options.ConfigPath,
			joinErrors(fmt.Errorf("bind HTTP listener %s: %w", options.HTTPListenAddress, err), rollbackErr),
		)
		return snapshot, TunSnapshot{}, startErr
	}

	socksListener, err := p.deps.SOCKSFactory(options.SOCKSListenAddress)
	if err != nil {
		bindErr := fmt.Errorf("bind SOCKS listener %s: %w", options.SOCKSListenAddress, err)
		rollbackErr := p.rollbackStart(httpListener, restoreSocketProtection, nil)
		if tunOptions != nil {
			tunSnapshot, tunErr := p.commitTunStartFailure(
				options.ConfigPath,
				tunOptions.SessionID,
				"VPN_TUN_START_FAILED",
				joinErrors(bindErr, rollbackErr),
			)
			return Snapshot{}, tunSnapshot, tunErr
		}
		snapshot, startErr := p.commitStartFailure(options.ConfigPath, joinErrors(bindErr, rollbackErr))
		return snapshot, TunSnapshot{}, startErr
	}

	var (
		tunListener TunListenerHandle
		tunRecorder *tunTraceRecorder
		tunSnapshot TunSnapshot
	)
	if tunOptions != nil {
		tunRecorder = newTunTraceRecorder(tunOptions.SessionID, p.deps.Events, 256)
		tunListener, err = p.deps.TunFactory(
			buildTunConfig(tunOptions.TunFD),
			tunRecorder.Wrap(p.deps.BaseTunnel),
			adapterinbound.WithInName("CMFA-TUN"),
			adapterinbound.WithSpecialRules(""),
		)
		if err != nil {
			rollbackErr := p.rollbackStart(socksListener, restoreSocketProtection, httpListener)
			tunSnapshot, tunErr := p.commitTunStartFailure(
				options.ConfigPath,
				tunOptions.SessionID,
				"VPN_TUN_START_FAILED",
				joinErrors(err, rollbackErr),
			)
			return Snapshot{}, tunSnapshot, tunErr
		}
		tunSnapshot = TunSnapshot{
			State:     TunStateReady,
			SessionID: tunOptions.SessionID,
			Counters:  tunRecorder.Counters(),
		}
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
	p.tunListener = tunListener
	p.tunRecorder = tunRecorder
	p.restoreSocketProtection = restoreSocketProtection
	p.lastStartOptions = options
	p.state = RuntimeRunning
	p.latest = snapshot
	if tunOptions != nil {
		p.tunSnapshot = tunSnapshot
	} else {
		p.tunSnapshot = TunSnapshot{State: TunStateIdle}
	}
	p.mu.Unlock()

	p.publish(RuntimeEvent{
		Kind:         "runtime.running",
		State:        RuntimeRunning,
		Message:      truncateUTF8("local HTTP and SOCKS listeners are running", p.deps.MaxMessageBytes),
		HTTPAddress:  snapshot.HTTPAddress,
		SOCKSAddress: snapshot.SOCKSAddress,
	})
	p.publishLog(LogLevelInfo, "runtime.running", "local proxy running", map[string]string{
		"httpAddress":  snapshot.HTTPAddress,
		"socksAddress": snapshot.SOCKSAddress,
	})

	return snapshot, tunSnapshot, nil
}

func (p *LocalProxy) resolveTunBaseOptions(options TunStartOptions) (StartOptions, bool, error) {
	base := options.Base
	if strings.TrimSpace(base.ConfigPath) == "" {
		p.mu.Lock()
		base = p.lastStartOptions
		needsRestart := p.state == RuntimeRunning && p.tunListener == nil
		if p.state == RuntimeRunning && p.tunListener != nil {
			p.mu.Unlock()
			return StartOptions{}, false, ErrRuntimeBusy
		}
		p.mu.Unlock()
		if strings.TrimSpace(base.ConfigPath) == "" {
			return StartOptions{}, false, errors.New("tun start requires an existing local runtime or explicit base options")
		}
		return base, needsRestart, p.validateStartOptions(base)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.state == RuntimeRunning && p.tunListener != nil {
		return StartOptions{}, false, ErrRuntimeBusy
	}
	return base, p.state == RuntimeRunning, p.validateStartOptions(base)
}

func (p *LocalProxy) failStart(configPath string, err error) Snapshot {
	diagnostic := truncateUTF8(redactSecrets(err.Error(), configPath), p.deps.MaxMessageBytes)
	snapshot := Snapshot{
		State:            RuntimeError,
		ActiveConfigPath: truncateUTF8(configPath, p.deps.MaxSnapshotBytes),
		LastError:        diagnostic,
	}

	p.mu.Lock()
	p.state = RuntimeError
	p.latest = snapshot
	p.httpListener = nil
	p.socksListener = nil
	p.tunListener = nil
	p.tunRecorder = nil
	p.restoreSocketProtection = nil
	p.mu.Unlock()

	p.publish(RuntimeEvent{
		Kind:    "runtime.error",
		State:   RuntimeError,
		Message: snapshot.LastError,
	})
	p.publishLog(LogLevelError, "runtime.start.failed", snapshot.LastError, map[string]string{
		"configPath": configPath,
	})

	return snapshot
}

func (p *LocalProxy) failStop(err error) Snapshot {
	diagnostic := truncateUTF8(redactSecrets(err.Error(), ""), p.deps.MaxMessageBytes)
	snapshot := Snapshot{
		State:     RuntimeError,
		LastError: diagnostic,
	}
	p.mu.Lock()
	p.state = RuntimeError
	p.latest = snapshot
	p.tunListener = nil
	p.tunRecorder = nil
	p.restoreSocketProtection = nil
	p.mu.Unlock()
	p.publish(RuntimeEvent{
		Kind:    "runtime.error",
		State:   RuntimeError,
		Message: snapshot.LastError,
	})
	p.publishLog(LogLevelError, "runtime.stop.failed", snapshot.LastError, nil)
	return snapshot
}

func (p *LocalProxy) commitStartFailure(configPath string, err error) (Snapshot, error) {
	snapshot := p.failStart(configPath, err)
	return snapshot, runtimeFailure{message: snapshot.LastError}
}

func (p *LocalProxy) commitTunStartFailure(configPath string, sessionID string, code string, err error) (TunSnapshot, error) {
	if code == "" {
		code = "VPN_TUN_START_FAILED"
	}
	diagnostic := truncateUTF8(redactSecrets(err.Error(), configPath), p.deps.MaxMessageBytes)
	snapshot := TunSnapshot{
		State:     TunStateError,
		SessionID: truncateUTF8(sessionID, p.deps.MaxSnapshotBytes),
		Failure: TunFailure{
			Code:   truncateUTF8(code, p.deps.MaxLogFieldBytes),
			Detail: diagnostic,
		},
	}
	p.mu.Lock()
	p.state = RuntimeError
	p.latest = Snapshot{State: RuntimeError, LastError: diagnostic}
	p.tunSnapshot = snapshot
	p.tunListener = nil
	p.tunRecorder = nil
	p.tunTraces = nil
	p.restoreSocketProtection = nil
	p.mu.Unlock()

	p.publish(RuntimeEvent{
		Kind:    "runtime.error",
		State:   RuntimeError,
		Code:    snapshot.Failure.Code,
		Message: snapshot.Failure.Detail,
	})
	p.publishLog(LogLevelError, "runtime.tun.start.failed", snapshot.Failure.Detail, nil)
	return snapshot, runtimeFailure{message: snapshot.Failure.Detail}
}

func (p *LocalProxy) commitStopFailure(err error) (Snapshot, error) {
	snapshot := p.failStop(err)
	return snapshot, runtimeFailure{message: snapshot.LastError}
}

func (p *LocalProxy) commitStopFailureWithTun(err error, tunSnapshot TunSnapshot) (Snapshot, error) {
	snapshot := p.failStop(err)
	p.mu.Lock()
	tunSnapshot.State = TunStateError
	p.tunSnapshot = tunSnapshot
	p.mu.Unlock()
	return snapshot, runtimeFailure{message: snapshot.LastError}
}

func (p *LocalProxy) rollbackStart(primary ListenerHandle, restoreSocketProtection func(), secondary ListenerHandle) error {
	if restoreSocketProtection != nil {
		restoreSocketProtection()
	}
	var rollbackErr error
	if err := closeListener(primary); err != nil {
		rollbackErr = joinErrors(rollbackErr, err)
	}
	if err := closeListener(secondary); err != nil {
		rollbackErr = joinErrors(rollbackErr, err)
	}
	if err := p.deps.CloseConnections(); err != nil {
		rollbackErr = joinErrors(rollbackErr, fmt.Errorf("close tracked connections: %w", err))
	}
	if err := p.deps.Shutdown(); err != nil {
		rollbackErr = joinErrors(rollbackErr, fmt.Errorf("executor shutdown: %w", err))
	}
	return rollbackErr
}

func effectiveAPILevel(options *TunStartOptions, fallback int) int {
	if options != nil && options.PlatformAPILevel > 0 {
		return options.PlatformAPILevel
	}
	return fallback
}

func (p *LocalProxy) publish(event RuntimeEvent) {
	event.Message = truncateUTF8(event.Message, p.deps.MaxMessageBytes)
	event.HTTPAddress = truncateUTF8(event.HTTPAddress, p.deps.MaxSnapshotBytes)
	event.SOCKSAddress = truncateUTF8(event.SOCKSAddress, p.deps.MaxSnapshotBytes)
	p.deps.Events.Publish(event)
}

func (p *LocalProxy) publishLog(level LogLevel, category, message string, context map[string]string) {
	configPath := ""
	if context != nil {
		configPath = context["configPath"]
	}
	p.deps.Logs.Publish(RuntimeLog{
		Level:    level,
		Category: truncateUTF8(category, p.deps.MaxLogFieldBytes),
		Message:  truncateUTF8(redactSecrets(message, configPath), p.deps.MaxLogFieldBytes),
		Context:  sanitizeContext(context, p.deps.MaxLogContextFields, p.deps.MaxLogFieldBytes),
	})
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

func closeTunListener(listener TunListenerHandle) error {
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

func sanitizeContext(values map[string]string, maxFields, maxBytes int) map[string]string {
	if len(values) == 0 {
		return nil
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if len(keys) > maxFields {
		keys = keys[:maxFields]
	}
	sanitized := make(map[string]string, len(keys))
	for _, key := range keys {
		value := values[key]
		if key == "configPath" {
			value = "<redacted-path>"
		} else {
			value = redactSecrets(value, "")
		}
		sanitized[truncateUTF8(key, maxBytes)] = truncateUTF8(value, maxBytes)
	}
	return sanitized
}

func redactSecrets(text string, configPath string) string {
	if text == "" {
		return text
	}
	redacted := text
	if configPath != "" {
		redacted = strings.ReplaceAll(redacted, configPath, "<redacted-path>")
	}
	redacted = urlUserinfoPattern.ReplaceAllString(redacted, "://<redacted>@")
	redacted = secretQueryPattern.ReplaceAllString(redacted, `$1=<redacted>`)
	if parsed, err := url.Parse(redacted); err == nil && parsed.User != nil {
		parsed.User = url.User("<redacted>")
		redacted = parsed.String()
	}
	return redacted
}
