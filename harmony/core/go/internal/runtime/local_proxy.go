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
	"syscall"
	"time"
	"unicode/utf8"

	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	C "github.com/metacubex/mihomo/constant"
	mihomoexecutor "github.com/metacubex/mihomo/hub/executor"
	authStore "github.com/metacubex/mihomo/listener/auth"
	LC "github.com/metacubex/mihomo/listener/config"
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
	Prepare               func(configPath string) error
	HTTPFactory           func(addr string) (ListenerHandle, error)
	SOCKSFactory          func(addr string) (ListenerHandle, error)
	CloseConnections      func() error
	Shutdown              func() error
	Events                EventSink
	Logs                  LogSink
	BaseTunnel            C.Tunnel
	TunFactory            TunListenerFactory
	ReportStageLifecycle  func(stage string)
	SocketProtector       SocketProtector
	SocketProtectAPILevel int
	SocketProtectTimeout  time.Duration
	TunRouteProbe         TunRouteProbe
	TunRouteProbeInterval time.Duration
	MaxMessageBytes       int
	MaxSnapshotBytes      int
	AllowedLoopbackIP     string
	MaxLogContextFields   int
	MaxLogFieldBytes      int
}

type LocalProxy struct {
	mu     sync.Mutex
	deps   LocalProxyDeps
	state  RuntimeState
	latest Snapshot

	httpListener  ListenerHandle
	socksListener ListenerHandle
	tunListener   TunListenerHandle

	tunSnapshot           TunSnapshot
	tunRecorder           *tunTraceRecorder
	tunTraces             []TunTrace
	tunCloseStaleInFlight bool
	tunRouteProbeInFlight bool
	tunRouteProbeEpoch    uint64
	lastTunRouteProbeAt   time.Time

	lastStartOptions        StartOptions
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

type stopStageDefinition struct {
	stage         string
	codePrefix    string
	classifyCause bool
}

func (e runtimeFailure) Error() string {
	return e.message
}

var (
	tunStopListenerStage = stopStageDefinition{
		stage:         "tun.stop.listener",
		codePrefix:    "TUN_STOP_LISTENER_FAILED",
		classifyCause: true,
	}
	tunStopHTTPListenerStage = stopStageDefinition{
		stage:      "tun.stop.http-listener",
		codePrefix: "TUN_STOP_HTTP_LISTENER_FAILED",
	}
	tunStopSOCKSListenerStage = stopStageDefinition{
		stage:      "tun.stop.socks-listener",
		codePrefix: "TUN_STOP_SOCKS_LISTENER_FAILED",
	}
	tunStopConnectionsStage = stopStageDefinition{
		stage:      "tun.stop.connections",
		codePrefix: "TUN_STOP_CONNECTIONS_FAILED",
	}
	tunStopExecutorStage = stopStageDefinition{
		stage:      "tun.stop.executor",
		codePrefix: "TUN_STOP_EXECUTOR_FAILED",
	}
)

type stopCommitDecision struct {
	snapshot    Snapshot
	tunSnapshot TunSnapshot
	event       RuntimeEvent
	logLevel    LogLevel
	logCategory string
	logMessage  string
	logContext  map[string]string
	returnErr   error
}

func buildStopCommitDecision(
	preserveError bool,
	previous Snapshot,
	previousTun TunSnapshot,
	stopFailureDiagnostic string,
	baseTunSnapshot TunSnapshot,
) stopCommitDecision {
	switch {
	case preserveError:
		snapshot := previous
		snapshot.State = RuntimeError
		tunSnapshot := previousTun
		tunSnapshot.State = TunStateError
		return stopCommitDecision{
			snapshot:    snapshot,
			tunSnapshot: tunSnapshot,
			event: RuntimeEvent{
				Kind:    "runtime.error",
				State:   RuntimeError,
				Message: snapshot.LastError,
			},
			logLevel:    LogLevelError,
			logCategory: "runtime.stop.error",
			logMessage:  snapshot.LastError,
			logContext: map[string]string{
				"configPath": snapshot.ActiveConfigPath,
			},
		}
	case stopFailureDiagnostic != "":
		snapshot := Snapshot{
			State:     RuntimeError,
			LastError: stopFailureDiagnostic,
		}
		tunSnapshot := baseTunSnapshot
		tunSnapshot.State = TunStateError
		return stopCommitDecision{
			snapshot:    snapshot,
			tunSnapshot: tunSnapshot,
			event: RuntimeEvent{
				Kind:    "runtime.error",
				State:   RuntimeError,
				Message: snapshot.LastError,
			},
			logLevel:    LogLevelError,
			logCategory: "runtime.stop.failed",
			logMessage:  snapshot.LastError,
			returnErr:   runtimeFailure{message: snapshot.LastError},
		}
	default:
		snapshot := Snapshot{State: RuntimeStopped}
		tunSnapshot := baseTunSnapshot
		tunSnapshot.State = TunStateStopped
		return stopCommitDecision{
			snapshot:    snapshot,
			tunSnapshot: tunSnapshot,
			event: RuntimeEvent{
				Kind:  "runtime.stopped",
				State: RuntimeStopped,
			},
			logLevel:    LogLevelInfo,
			logCategory: "runtime.stopped",
			logMessage:  "local proxy stopped",
		}
	}
}

func NewLocalProxy() *LocalProxy {
	return NewLocalProxyWithDeps(LocalProxyDeps{})
}

func localListenerAdditions(name string) []adapterinbound.Addition {
	return []adapterinbound.Addition{
		adapterinbound.WithInName(name),
		adapterinbound.WithSpecialRules(""),
	}
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
			return mihomohttp.NewWithAuthenticate(addr, deps.BaseTunnel, false, localListenerAdditions("CMFA-LOCAL-HTTP")...)
		}
	}
	if deps.SOCKSFactory == nil {
		deps.SOCKSFactory = func(addr string) (ListenerHandle, error) {
			return mihomosocks.NewWithConfig(
				LC.AuthServer{Enable: true, Listen: addr, AuthStore: authStore.Nil},
				adapterinbound.NewListenConfig(),
				deps.BaseTunnel,
				localListenerAdditions("CMFA-LOCAL-SOCKS")...,
			)
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
	if deps.TunRouteProbeInterval <= 0 {
		deps.TunRouteProbeInterval = 200 * time.Millisecond
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
	snapshot := p.tunSnapshot
	recorder := p.tunRecorder
	activeSessionID := snapshot.SessionID
	activeState := snapshot.State
	hasActiveTun := p.tunListener != nil
	routeProbe := p.deps.TunRouteProbe
	routeProbeInterval := p.deps.TunRouteProbeInterval
	probeEpoch := p.tunRouteProbeEpoch
	if recorder != nil {
		snapshot.Counters = recorder.Counters()
	}
	shouldProbe := hasActiveTun && (snapshot.State == TunStateReady ||
		(snapshot.State == TunStateError && snapshot.Failure.Code == tunRouteLostCode))
	if shouldProbe && p.tunRouteProbeInFlight {
		shouldProbe = false
	}
	if shouldProbe && routeProbeInterval > 0 && !p.lastTunRouteProbeAt.IsZero() && time.Since(p.lastTunRouteProbeAt) < routeProbeInterval {
		shouldProbe = false
	}
	if shouldProbe {
		p.tunRouteProbeInFlight = true
	}
	p.mu.Unlock()

	if !shouldProbe {
		return snapshot
	}
	if routeProbe == nil {
		routeProbe = defaultTunRouteProbe
	}

	var (
		probeErr   error
		probePanic any
	)
	func() {
		defer func() {
			probePanic = recover()
		}()
		probeErr = routeProbe()
	}()

	p.mu.Lock()
	current := p.tunSnapshot
	if p.tunRecorder != nil {
		current.Counters = p.tunRecorder.Counters()
	}
	ownsProbeGate := p.tunRouteProbeInFlight && p.tunRouteProbeEpoch == probeEpoch
	if ownsProbeGate {
		p.tunRouteProbeInFlight = false
	}
	if p.tunListener == nil || current.SessionID != activeSessionID {
		p.mu.Unlock()
		if probePanic != nil {
			panic(probePanic)
		}
		return current
	}
	if current.State != activeState {
		p.mu.Unlock()
		if probePanic != nil {
			panic(probePanic)
		}
		return current
	}
	if !ownsProbeGate {
		p.mu.Unlock()
		if probePanic != nil {
			panic(probePanic)
		}
		return current
	}
	if probePanic != nil {
		p.mu.Unlock()
		panic(probePanic)
	}
	p.lastTunRouteProbeAt = time.Now()
	if current.State == TunStateError && current.Failure.Code != tunRouteLostCode {
		p.mu.Unlock()
		return current
	}
	if failure, lost := classifyTunRouteProbeFailure(probeErr); lost {
		current.State = TunStateError
		current.Failure = failure
		p.tunSnapshot = current
		p.mu.Unlock()
		return current
	}
	if probeErr == nil && current.State == TunStateError && current.Failure.Code == tunRouteLostCode {
		current.State = TunStateReady
		current.Failure = TunFailure{}
		p.tunSnapshot = current
	}
	p.mu.Unlock()
	return current
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

func (p *LocalProxy) CloseStaleOutboundConnections(sessionID string) error {
	if strings.TrimSpace(sessionID) == "" {
		return errTunSessionRequired
	}

	p.mu.Lock()
	if p.tunCloseStaleInFlight || p.state == RuntimeStarting || p.state == RuntimeStopping {
		p.mu.Unlock()
		return ErrRuntimeBusy
	}
	activeSessionID := p.tunSnapshot.SessionID
	activeState := p.tunSnapshot.State
	if activeSessionID == "" || activeState == TunStateIdle || activeState == TunStateStopped || activeSessionID != sessionID {
		p.mu.Unlock()
		return runtimeFailure{message: fmt.Sprintf("close stale outbound connections rejected stale session %s", sessionID)}
	}
	p.tunCloseStaleInFlight = true
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		p.tunCloseStaleInFlight = false
		p.mu.Unlock()
	}()
	if err := p.deps.CloseConnections(); err != nil {
		return runtimeFailure{message: fmt.Sprintf("close tracked connections: %v", err)}
	}
	return nil
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
	if p.tunCloseStaleInFlight {
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
	p.tunRouteProbeInFlight = false
	p.tunRouteProbeEpoch += 1
	p.lastTunRouteProbeAt = time.Time{}
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
	recordStopStage := func(definition stopStageDefinition, run func() error) {
		p.reportStageLifecycle(definition.stage + ".begin")
		var err error
		func() {
			defer func() {
				if recovered := recover(); recovered != nil {
					err = newStopStagePanic(definition)
				}
			}()
			err = run()
		}()
		if err != nil {
			if !isStopStageClassifiedError(err) {
				err = classifyStopStageError(definition, err)
			}
			stopErr = joinErrors(stopErr, err)
			p.reportStageLifecycle(definition.stage + ".failed")
			return
		}
		p.reportStageLifecycle(definition.stage + ".ok")
	}
	recordStopStage(tunStopListenerStage, func() error {
		return closeTunListener(tunListener)
	})
	recordStopStage(tunStopHTTPListenerStage, func() error {
		return closeListener(httpListener)
	})
	recordStopStage(tunStopSOCKSListenerStage, func() error {
		return closeListener(socksListener)
	})
	recordStopStage(tunStopConnectionsStage, func() error {
		if err := p.deps.CloseConnections(); err != nil {
			return fmt.Errorf("close tracked connections: %w", err)
		}
		return nil
	})
	recordStopStage(tunStopExecutorStage, func() error {
		if err := p.deps.Shutdown(); err != nil {
			return fmt.Errorf("executor shutdown: %w", err)
		}
		return nil
	})

	tunSnapshot := TunSnapshot{
		SessionID: previousTun.SessionID,
	}
	if tunRecorder != nil {
		tunSnapshot.Counters = tunRecorder.Counters()
		p.tunTraces = tunRecorder.Traces(256)
	}
	stopFailureDiagnostic := ""
	if stopErr != nil {
		stopFailureDiagnostic = truncateUTF8(redactSecrets(stopErr.Error(), ""), p.deps.MaxMessageBytes)
	}
	decision := buildStopCommitDecision(preserveError, previous, previousTun, stopFailureDiagnostic, tunSnapshot)
	p.mu.Lock()
	p.state = decision.snapshot.State
	p.latest = decision.snapshot
	p.tunSnapshot = decision.tunSnapshot
	p.mu.Unlock()

	p.publish(decision.event)
	p.publishLog(decision.logLevel, decision.logCategory, decision.logMessage, decision.logContext)
	return decision.snapshot, decision.returnErr
}

func (p *LocalProxy) startRuntime(options StartOptions, tunOptions *TunStartOptions) (Snapshot, TunSnapshot, error) {
	startingEvent := RuntimeEvent{
		Kind:  "runtime.starting",
		State: RuntimeStarting,
	}
	p.mu.Lock()
	if p.state == RuntimeStarting || p.state == RuntimeRunning || p.state == RuntimeStopping || p.tunCloseStaleInFlight {
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
	p.tunRouteProbeInFlight = false
	p.tunRouteProbeEpoch += 1
	p.lastTunRouteProbeAt = time.Time{}
	p.mu.Unlock()

	p.publish(startingEvent)
	p.publishLog(LogLevelInfo, "runtime.starting", "starting local proxy", map[string]string{
		"configPath":  options.ConfigPath,
		"httpListen":  options.HTTPListenAddress,
		"socksListen": options.SOCKSListenAddress,
	})

	if tunOptions != nil {
		p.reportStageLifecycle("tun.prepare.begin")
	}
	if err := p.deps.Prepare(options.ConfigPath); err != nil {
		if tunOptions != nil {
			p.reportStageLifecycle("tun.prepare.failed")
			tunSnapshot, tunErr := p.commitTunStartFailure(options.ConfigPath, tunOptions.SessionID, "VPN_TUN_START_FAILED", err)
			return Snapshot{}, tunSnapshot, tunErr
		}
		snapshot, startErr := p.commitStartFailure(options.ConfigPath, err)
		return snapshot, TunSnapshot{}, startErr
	}
	if tunOptions != nil {
		p.reportStageLifecycle("tun.prepare.ok")
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

	if tunOptions != nil {
		p.reportStageLifecycle("tun.http-listener.begin")
	}
	httpListener, err := p.deps.HTTPFactory(options.HTTPListenAddress)
	if err != nil {
		if tunOptions != nil {
			p.reportStageLifecycle("tun.http-listener.failed")
		}
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
	if tunOptions != nil {
		p.reportStageLifecycle("tun.http-listener.ok")
	}

	if tunOptions != nil {
		p.reportStageLifecycle("tun.socks-listener.begin")
	}
	socksListener, err := p.deps.SOCKSFactory(options.SOCKSListenAddress)
	if err != nil {
		if tunOptions != nil {
			p.reportStageLifecycle("tun.socks-listener.failed")
		}
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
	if tunOptions != nil {
		p.reportStageLifecycle("tun.socks-listener.ok")
	}

	var (
		tunListener TunListenerHandle
		tunRecorder *tunTraceRecorder
		tunSnapshot TunSnapshot
	)
	if tunOptions != nil {
		tunRecorder = newTunTraceRecorder(tunOptions.SessionID, p.deps.Events, 256)
		tunRecorder.packetDiagnosticSink = p.reportStageLifecycle
		p.reportStageLifecycle("tun.listener.begin")
		tunListener, err = p.deps.TunFactory(
			buildTunConfig(tunOptions.TunFD),
			tunRecorder.Wrap(p.deps.BaseTunnel),
			adapterinbound.WithInName("CMFA-TUN"),
			adapterinbound.WithSpecialRules(""),
		)
		if err != nil {
			for _, stage := range classifyTunListenerFailure(err) {
				p.reportStageLifecycle(stage)
			}
			p.reportStageLifecycle("tun.listener.failed")
			rollbackErr := p.rollbackStart(socksListener, restoreSocketProtection, httpListener)
			tunSnapshot, tunErr := p.commitTunStartFailure(
				options.ConfigPath,
				tunOptions.SessionID,
				"VPN_TUN_START_FAILED",
				joinErrors(err, rollbackErr),
			)
			return Snapshot{}, tunSnapshot, tunErr
		}
		p.reportStageLifecycle("tun.listener.ok")
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

func (p *LocalProxy) reportStageLifecycle(stage string) {
	if p.deps.ReportStageLifecycle == nil {
		return
	}
	defer func() {
		_ = recover()
	}()
	p.deps.ReportStageLifecycle(stage)
}

func classifyStopStageError(definition stopStageDefinition, err error) error {
	code := definition.codePrefix + "_ERROR"
	if definition.classifyCause {
		code = definition.codePrefix + "_" + classifyStopListenerFailureCause(err)
	}
	return stopStageClassifiedError{
		code:  code,
		cause: err,
	}
}

func newStopStagePanic(definition stopStageDefinition) error {
	return stopStageClassifiedError{
		code:    definition.codePrefix + "_PANIC",
		message: "panic during stop cleanup",
	}
}

type stopStageClassifiedError struct {
	code    string
	cause   error
	message string
}

func (e stopStageClassifiedError) Error() string {
	if e.cause != nil {
		return fmt.Sprintf("%s: %s", e.code, e.cause.Error())
	}
	if e.message != "" {
		return fmt.Sprintf("%s: %s", e.code, e.message)
	}
	return e.code
}

func (e stopStageClassifiedError) Unwrap() error {
	return e.cause
}

func isStopStageClassifiedError(err error) bool {
	var classified stopStageClassifiedError
	return errors.As(err, &classified)
}

func classifyStopListenerFailureCause(err error) string {
	switch {
	case errors.Is(err, syscall.EBADF):
		return "BAD_FD"
	case errors.Is(err, net.ErrClosed):
		return "ALREADY_CLOSED"
	case errors.Is(err, syscall.EINVAL):
		return "INVALID"
	case errors.Is(err, syscall.EIO):
		return "IO"
	}

	normalized := strings.ToLower(strings.TrimSpace(err.Error()))
	switch {
	case strings.Contains(normalized, "bad file descriptor"):
		return "BAD_FD"
	case strings.Contains(normalized, "use of closed network connection"),
		strings.Contains(normalized, "already closed"),
		strings.Contains(normalized, "closed pipe"):
		return "ALREADY_CLOSED"
	case strings.Contains(normalized, "invalid argument"),
		strings.Contains(normalized, "invalid fd"),
		strings.Contains(normalized, "invalid file descriptor"):
		return "INVALID"
	case strings.Contains(normalized, "i/o"),
		strings.Contains(normalized, "input/output"):
		return "IO"
	default:
		return "OTHER"
	}
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
