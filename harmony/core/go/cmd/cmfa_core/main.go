package main

/*
#cgo CFLAGS: -I${SRCDIR}/../../../abi/include
#include <dlfcn.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "cmfa_host.h"
#include "cmfa_types.h"

typedef struct cmfa_mihomo_runtime_log_record_v1 {
	uint32_t struct_size;
	cmfa_log_level level;
	char message[4096];
} cmfa_mihomo_runtime_log_record_v1;

static char *cmfa_snapshot_active_config_path(cmfa_runtime_snapshot *snapshot) {
	return snapshot->active_config_path;
}

static char *cmfa_snapshot_http_address(cmfa_runtime_snapshot *snapshot) {
	return snapshot->http_address;
}

static char *cmfa_snapshot_socks_address(cmfa_runtime_snapshot *snapshot) {
	return snapshot->socks_address;
}

static char *cmfa_snapshot_last_error(cmfa_runtime_snapshot *snapshot) {
	return snapshot->last_error;
}

static char *cmfa_runtime_log_message(cmfa_mihomo_runtime_log_record_v1 *record) {
	return record->message;
}

static char *cmfa_tun_options_session_id(cmfa_tun_options *options) {
	return options->session_id;
}

static const char *cmfa_tun_options_config_path(cmfa_tun_options *options) {
	return options->config_path;
}

static uint32_t cmfa_tun_options_mixed_port(cmfa_tun_options *options) {
	return options->mixed_port;
}

static uint32_t cmfa_tun_options_platform_api_level(cmfa_tun_options *options) {
	return options->platform_api_level;
}

static uint8_t cmfa_tun_options_process_protected(cmfa_tun_options *options) {
	return options->process_protected;
}

static char *cmfa_tun_snapshot_session_id(cmfa_tun_snapshot *snapshot) {
	return snapshot->session_id;
}

static char *cmfa_tun_snapshot_failure_code(cmfa_tun_snapshot *snapshot) {
	return snapshot->failure.code;
}

static char *cmfa_tun_snapshot_failure_detail(cmfa_tun_snapshot *snapshot) {
	return snapshot->failure.detail;
}

static cmfa_tun_trace *cmfa_tun_trace_at(cmfa_tun_trace_collection *collection, size_t index) {
	return &collection->traces[index];
}

static char *cmfa_tun_trace_session_id(cmfa_tun_trace *trace) {
	return trace->session_id;
}

static char *cmfa_tun_trace_trace_id(cmfa_tun_trace *trace) {
	return trace->trace_id;
}

static char *cmfa_tun_trace_ingress(cmfa_tun_trace *trace) {
	return trace->ingress;
}

static char *cmfa_tun_trace_protocol(cmfa_tun_trace *trace) {
	return trace->protocol;
}

static char *cmfa_tun_trace_source_address(cmfa_tun_trace *trace) {
	return trace->source_address;
}

static char *cmfa_tun_trace_destination_address(cmfa_tun_trace *trace) {
	return trace->destination_address;
}

static char *cmfa_tun_trace_hashed_tuple(cmfa_tun_trace *trace) {
	return trace->hashed_tuple;
}

static char *cmfa_tun_trace_correlation_hash(cmfa_tun_trace *trace) {
	return trace->correlation_hash;
}

static char *cmfa_tun_trace_destination_hash(cmfa_tun_trace *trace) {
	return trace->destination_hash;
}

static char *cmfa_tun_trace_outbound_terminal_hash(cmfa_tun_trace *trace) {
	return trace->outbound_terminal_hash;
}

static char *cmfa_tun_trace_outbound_chain_hash(cmfa_tun_trace *trace) {
	return trace->outbound_chain_hash;
}

typedef cmfa_status (*cmfa_host_protect_socket_bridge_fn)(int fd, uint32_t timeout_ms, cmfa_error *error);
typedef cmfa_status (*cmfa_host_emit_runtime_event_bridge_fn)(const cmfa_runtime_event *event, cmfa_error *error);

static cmfa_host_protect_socket_bridge_fn cmfa_lookup_host_protect_socket_bridge(void) {
	return (cmfa_host_protect_socket_bridge_fn)dlsym(RTLD_DEFAULT, "cmfa_host_protect_socket_bridge_v1");
}

static cmfa_host_emit_runtime_event_bridge_fn cmfa_lookup_host_emit_runtime_event_bridge(void) {
	return (cmfa_host_emit_runtime_event_bridge_fn)dlsym(RTLD_DEFAULT, "cmfa_host_emit_runtime_event_bridge_v1");
}

static int cmfa_host_protect_socket_bridge_available(void) {
	return cmfa_lookup_host_protect_socket_bridge() != 0;
}

static int cmfa_host_emit_runtime_event_bridge_available(void) {
	return cmfa_lookup_host_emit_runtime_event_bridge() != 0;
}

static cmfa_status cmfa_call_host_protect_socket_bridge(int fd, uint32_t timeout_ms, cmfa_error *error) {
	cmfa_host_protect_socket_bridge_fn bridge = cmfa_lookup_host_protect_socket_bridge();
	if (bridge == 0) {
		return CMFA_SOCKET_PROTECT_FAILED;
	}
	return bridge(fd, timeout_ms, error);
}

static cmfa_status cmfa_call_host_emit_runtime_event_bridge(const cmfa_runtime_event *event, cmfa_error *error) {
	cmfa_host_emit_runtime_event_bridge_fn bridge = cmfa_lookup_host_emit_runtime_event_bridge();
	if (bridge == 0) {
		return CMFA_BACKEND_ERROR;
	}
	return bridge(event, error);
}

static char *cmfa_probe_result_probe_run_id(cmfa_probe_result *result) {
	return result->probe_run_id;
}

static char *cmfa_probe_result_request_id_echo(cmfa_probe_result *result) {
	return result->request_id_echo;
}

static char *cmfa_probe_result_origin_id(cmfa_probe_result *result) {
	return result->origin_id;
}

static char *cmfa_probe_result_response_sha256(cmfa_probe_result *result) {
	return result->response_sha256;
}

static char *cmfa_probe_result_tls_peer_sha256(cmfa_probe_result *result) {
	return result->tls_peer_sha256;
}

static char *cmfa_probe_result_started_at(cmfa_probe_result *result) {
	return result->started_at;
}

static char *cmfa_probe_result_completed_at(cmfa_probe_result *result) {
	return result->completed_at;
}

static char *cmfa_probe_result_client_local_address(cmfa_probe_result *result) {
	return result->client_local_address;
}

static char *cmfa_probe_result_client_remote_address(cmfa_probe_result *result) {
	return result->client_remote_address;
}

static char *cmfa_probe_tracker_connection_id(cmfa_probe_result *result) {
	return result->tracker.connection_id;
}

static char *cmfa_probe_tracker_source_address(cmfa_probe_result *result) {
	return result->tracker.source_address;
}

static char *cmfa_probe_tracker_destination_address(cmfa_probe_result *result) {
	return result->tracker.destination_address;
}

static char *cmfa_probe_tracker_inbound_type(cmfa_probe_result *result) {
	return result->tracker.inbound_type;
}

static char *cmfa_probe_tracker_opened_at(cmfa_probe_result *result) {
	return result->tracker.opened_at;
}

static char *cmfa_probe_error_code(cmfa_probe_result *result) {
	return result->error.code;
}

static char *cmfa_probe_error_stage(cmfa_probe_result *result) {
	return result->error.stage;
}

static char *cmfa_probe_error_detail(cmfa_probe_result *result) {
	return result->error.detail;
}
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
	"unsafe"

	configpkg "github.com/clashmetaforandroid/harmony/core/go/internal/config"
	probepkg "github.com/clashmetaforandroid/harmony/core/go/internal/probe"
	proxygroups "github.com/clashmetaforandroid/harmony/core/go/internal/proxygroups"
	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
	runtimecontrol "github.com/clashmetaforandroid/harmony/core/go/internal/runtimecontrol"
	"github.com/clashmetaforandroid/harmony/core/go/internal/version"
)

var (
	coreVersionOnce           sync.Once
	coreVersionCStr           *C.char
	buildInfoOnce             sync.Once
	buildInfoCStr             *C.char
	probeDefaultTimeout       = probepkg.DefaultTimeout
	runtimeLogs               = runtimepkg.NewLogBuffer(32)
	tunSocketProtector        = backendHostSocketProtector{}
	tunEventSink              = backendHostEventSink{}
	proxygroupsServiceMu      sync.RWMutex
	proxygroupsRuntimeService proxygroupsService = proxygroups.NewService(nil)
	proxyDelayServiceMu       sync.RWMutex
	proxyDelayRuntimeService  proxyDelayService = proxygroups.NewMihomoDelayJobManager()
	runtimeModeService                          = runtimecontrol.NewService(nil)
	localProxy                                  = runtimepkg.NewLocalProxyWithDeps(runtimepkg.LocalProxyDeps{
		Prepare:               loadConfigForLocalProxy,
		Events:                tunEventSink,
		Logs:                  runtimeLogs,
		ReportStageLifecycle:  reportTunStartStage,
		SocketProtector:       tunSocketProtector,
		SocketProtectAPILevel: 21,
		MaxLogContextFields:   4,
		MaxLogFieldBytes:      256,
	})
	newManagedConfigLoader = func(sandboxRoot string) managedConfigLoader {
		return configpkg.NewLoader(sandboxRoot)
	}
	newLegacyRelativeConfigLoader = func(sandboxRoot string) managedConfigLoader {
		return configpkg.NewLoaderWithDeps(sandboxRoot, configpkg.LoaderDeps{
			PrepareHome: nonAuthoritativePrepareHome,
		})
	}
	validateManagedConfig        = configpkg.ValidateFile
	validateLegacyRelativeConfig = func(sandboxRoot, candidate string) error {
		return configpkg.ValidateFileWithDeps(sandboxRoot, candidate, configpkg.ValidateDeps{
			PrepareHome: nonAuthoritativePrepareHome,
		})
	}
)

type backendHostSocketProtector struct{}
type backendHostEventSink struct{}
type managedConfigLoader interface {
	LoadForLocalProxy(candidate string) error
}

type proxygroupsService interface {
	ListGroups(ctx proxygroups.QueryContext, selectableOnly bool) ([]byte, error)
	QueryGroup(ctx proxygroups.QueryContext, groupName string) ([]byte, error)
	Select(ctx proxygroups.QueryContext, groupName, memberName string) ([]byte, error)
}

type proxyDelayService interface {
	Start(ctx proxygroups.QueryContext, groupName string) (proxygroups.DelayTestSnapshot, error)
	Read(jobID string) (proxygroups.DelayTestSnapshot, error)
	Cancel(jobID string) (proxygroups.DelayTestSnapshot, error)
	CancelActiveAndDrain() error
}

type proxyRawExportStatus uint8

const (
	proxyRawExportStatusOK proxyRawExportStatus = iota
	proxyRawExportStatusInvalidArgument
	proxyRawExportStatusInvalidUTF8
	proxyRawExportStatusOutOfRange
	proxyRawExportStatusInvalidState
	proxyRawExportStatusBackendError
	proxyRawExportStatusBufferTooSmall
)

type proxyRawExportRequest struct {
	profileHash    *string
	revisionHash   *string
	sessionHash    *string
	generation     uint64
	selectableOnly uint8
	groupName      *string
	memberName     *string
}

type proxyRawExportBuffer struct {
	output       []byte
	outputLength *uint64
}

type proxyRawExportResult struct {
	status    proxyRawExportStatus
	errorCode string
}

type proxyMutationResult struct {
	status  int
	message string
}

const (
	delayBridgeInvalidErrorCode     = "PROXY_DELAY_BRIDGE_INVALID"
	delayJobNotFoundErrorCode       = "PROXY_DELAY_JOB_NOT_FOUND"
	proxyMutationBackendErrorStatus = int(C.CMFA_BACKEND_ERROR)
)

func reportTunStartStage(stage string) {
	runtimeLogs.Publish(runtimepkg.RuntimeLog{
		Level:    runtimepkg.LogLevelInfo,
		Category: "runtime.tun.stage",
		Message:  stage,
	})
}

func (backendHostSocketProtector) ProtectSocket(fd int, timeout time.Duration) error {
	if C.cmfa_host_protect_socket_bridge_available() == 0 {
		return errors.New("host protect_socket callback is unavailable")
	}

	var message [1024]C.char
	cErr := C.cmfa_error{
		code:     C.CMFA_OK,
		message:  (*C.char)(unsafe.Pointer(&message[0])),
		capacity: C.size_t(len(message)),
	}
	timeoutMs := timeout / time.Millisecond
	if timeoutMs < 0 {
		timeoutMs = 0
	}
	if timeoutMs > time.Duration(math.MaxUint32) {
		timeoutMs = time.Duration(math.MaxUint32)
	}
	status := C.cmfa_call_host_protect_socket_bridge(C.int(fd), C.uint32_t(timeoutMs), &cErr)
	if status == C.CMFA_OK {
		return nil
	}
	if detail := C.GoString(cErr.message); detail != "" {
		return errors.New(detail)
	}
	return fmt.Errorf("host protect_socket failed with status %d", int(status))
}

func (backendHostEventSink) Publish(event runtimepkg.RuntimeEvent) {
	if event.TraceID == "" && !(event.Kind == "runtime.socket_protect_failed" && event.Code == "VPN_SOCKET_PROTECT_FAILED") {
		return
	}
	if err := hostRuntimeEventBridge(event); err != nil && isFixedTunPacketDiagnostic(event) {
		runtimeLogs.Publish(runtimepkg.RuntimeLog{
			Level:    runtimepkg.LogLevelInfo,
			Category: "runtime.tun.packet-diagnostic",
			Message:  event.Protocol,
		})
	}
}

func isFixedTunPacketDiagnostic(event runtimepkg.RuntimeEvent) bool {
	if event.Kind != "tun.diagnostic" || event.Ingress != "diagnostic" || event.Message != event.Protocol {
		return false
	}
	switch event.Protocol {
	case "tun.packet.read-loop-enter",
		"tun.packet.read-would-block",
		"tun.packet.read-failed",
		"tun.packet.raw-read",
		"tun.packet.gvisor-inject":
		return true
	default:
		return false
	}
}

var hostRuntimeEventBridge = emitRuntimeEventToHost

func emitRuntimeEventToHost(event runtimepkg.RuntimeEvent) error {
	if C.cmfa_host_emit_runtime_event_bridge_available() == 0 {
		return errors.New("host runtime event bridge is unavailable")
	}

	var message [1024]C.char
	cErr := C.cmfa_error{
		code:     C.CMFA_OK,
		message:  (*C.char)(unsafe.Pointer(&message[0])),
		capacity: C.size_t(len(message)),
	}
	cEvent := C.cmfa_runtime_event{
		struct_size: C.uint32_t(C.sizeof_cmfa_runtime_event),
		state:       encodeRuntimeState(event.State),
		message:     C.CString(event.Message),
		code:        C.CString(event.Code),
		session_id:  C.CString(event.SessionID),
		trace_id:    C.CString(event.TraceID),
		ingress:     C.CString(event.Ingress),
		protocol:    C.CString(event.Protocol),
	}
	defer C.free(unsafe.Pointer(cEvent.message))
	defer C.free(unsafe.Pointer(cEvent.code))
	defer C.free(unsafe.Pointer(cEvent.session_id))
	defer C.free(unsafe.Pointer(cEvent.trace_id))
	defer C.free(unsafe.Pointer(cEvent.ingress))
	defer C.free(unsafe.Pointer(cEvent.protocol))

	status := C.cmfa_call_host_emit_runtime_event_bridge(&cEvent, &cErr)
	if status == C.CMFA_OK {
		return nil
	}
	if detail := C.GoString(cErr.message); detail != "" {
		return errors.New(detail)
	}
	return fmt.Errorf("host runtime event bridge failed with status %d", int(status))
}

func buildLocalStartOptions(configPath string, mixedPort uint32) runtimepkg.StartOptions {
	socksPort := uint64(0)
	if mixedPort < 65535 {
		socksPort = uint64(mixedPort) + 1
	}
	return runtimepkg.StartOptions{
		ConfigPath:         configPath,
		HTTPListenAddress:  "127.0.0.1:" + strconv.FormatUint(uint64(mixedPort), 10),
		SOCKSListenAddress: "127.0.0.1:" + strconv.FormatUint(socksPort, 10),
	}
}

func buildTunStartOptions(configPath string, mixedPort uint32, sessionID string, tunFD int, platformAPILevel uint32, processProtected bool) runtimepkg.TunStartOptions {
	return runtimepkg.TunStartOptions{
		SessionID:        sessionID,
		TunFD:            tunFD,
		Base:             buildLocalStartOptions(configPath, mixedPort),
		PlatformAPILevel: int(platformAPILevel),
		ProcessProtected: processProtected,
	}
}

func goCoreVersion() string {
	return version.Build().Version
}

func goBuildInfoJSON() string {
	return version.BuildInfoJSON()
}

func loadConfigForLocalProxy(configPath string) error {
	managedConfigPath := filepath.IsAbs(configPath)
	sandboxRoot, candidate, err := configSandbox(configPath)
	if err != nil {
		return err
	}

	loader := newLegacyRelativeConfigLoader(sandboxRoot)
	if managedConfigPath {
		loader = newManagedConfigLoader(sandboxRoot)
	}
	return loader.LoadForLocalProxy(candidate)
}

func validateConfigForNative(configPath string) error {
	managedConfigPath := filepath.IsAbs(configPath)
	sandboxRoot, candidate, err := configSandbox(configPath)
	if err != nil {
		return err
	}

	if managedConfigPath {
		return validateManagedConfig(sandboxRoot, candidate)
	}
	return validateLegacyRelativeConfig(sandboxRoot, candidate)
}

func configStatus(err error) C.cmfa_status {
	switch {
	case err == nil:
		return C.CMFA_OK
	case errors.Is(err, configpkg.ErrContentURIUnsupported), errors.Is(err, configpkg.ErrPathOutsideSandbox), errors.Is(err, configpkg.ErrManagedConfigUnavailable):
		return C.CMFA_INVALID_ARGUMENT
	default:
		return C.CMFA_BACKEND_ERROR
	}
}

func configSandbox(configPath string) (string, string, error) {
	if filepath.IsAbs(configPath) {
		return configpkg.ResolveManagedConfigPath(configPath)
	}

	wd, err := os.Getwd()
	if err != nil {
		return "", "", err
	}
	return wd, configPath, nil
}

func nonAuthoritativePrepareHome(string) error {
	return nil
}

func setError(errorOut *C.cmfa_error, status C.cmfa_status, message string) {
	if errorOut == nil {
		return
	}

	errorOut.code = status
	errorOut.length = C.size_t(len(message))
	if errorOut.message == nil || errorOut.capacity == 0 {
		return
	}

	buffer := unsafe.Slice((*byte)(unsafe.Pointer(errorOut.message)), int(errorOut.capacity))
	clear(buffer)
	copyLimit := len(message)
	if copyLimit > len(buffer)-1 {
		copyLimit = len(buffer) - 1
		for copyLimit > 0 && !utf8.ValidString(message[:copyLimit]) {
			copyLimit -= 1
		}
	}
	copy(buffer, message[:copyLimit])
}

func clearError(errorOut *C.cmfa_error) {
	setError(errorOut, C.CMFA_OK, "")
}

func runtimeStatus(err error) C.cmfa_status {
	switch {
	case err == nil:
		return C.CMFA_OK
	case errors.Is(err, runtimepkg.ErrRuntimeBusy):
		return C.CMFA_BUSY
	default:
		return C.CMFA_BACKEND_ERROR
	}
}

func encodeRuntimeState(state runtimepkg.RuntimeState) C.cmfa_runtime_state_value {
	switch state {
	case runtimepkg.RuntimeStarting:
		return C.CMFA_RUNTIME_STARTING
	case runtimepkg.RuntimeRunning:
		return C.CMFA_RUNTIME_RUNNING
	case runtimepkg.RuntimeStopping:
		return C.CMFA_RUNTIME_STOPPING
	case runtimepkg.RuntimeError:
		return C.CMFA_RUNTIME_ERROR
	default:
		return C.CMFA_RUNTIME_STOPPED
	}
}

func encodeLogLevel(level runtimepkg.LogLevel) C.cmfa_log_level {
	switch level {
	case runtimepkg.LogLevelDebug:
		return C.CMFA_LOG_DEBUG
	case runtimepkg.LogLevelWarn:
		return C.CMFA_LOG_WARN
	case runtimepkg.LogLevelError:
		return C.CMFA_LOG_ERROR
	default:
		return C.CMFA_LOG_INFO
	}
}

func encodeRuntimeMode(mode runtimecontrol.Mode) C.cmfa_runtime_mode {
	switch mode {
	case runtimecontrol.ModeGlobal:
		return C.CMFA_MODE_GLOBAL
	case runtimecontrol.ModeDirect:
		return C.CMFA_MODE_DIRECT
	default:
		return C.CMFA_MODE_RULE
	}
}

func decodeRuntimeMode(mode C.cmfa_runtime_mode) (runtimecontrol.Mode, error) {
	switch mode {
	case C.CMFA_MODE_RULE:
		return runtimecontrol.ModeRule, nil
	case C.CMFA_MODE_GLOBAL:
		return runtimecontrol.ModeGlobal, nil
	case C.CMFA_MODE_DIRECT:
		return runtimecontrol.ModeDirect, nil
	default:
		return runtimecontrol.ModeRule, runtimecontrol.ErrInvalidMode
	}
}

func copyCStringBuffer(target *C.char, capacity C.size_t, value string) {
	if target == nil || capacity == 0 {
		return
	}
	buffer := unsafe.Slice((*byte)(unsafe.Pointer(target)), int(capacity))
	clear(buffer)
	copyLimit := len(value)
	if copyLimit > len(buffer)-1 {
		copyLimit = len(buffer) - 1
		for copyLimit > 0 && !utf8.ValidString(value[:copyLimit]) {
			copyLimit -= 1
		}
	}
	copy(buffer, value[:copyLimit])
}

func writeSnapshot(snapshot *C.cmfa_runtime_snapshot, source runtimepkg.Snapshot) {
	if snapshot == nil {
		return
	}
	snapshot.struct_size = C.uint32_t(C.sizeof_cmfa_runtime_snapshot)
	snapshot.state = encodeRuntimeState(source.State)
	copyCStringBuffer(C.cmfa_snapshot_active_config_path(snapshot), C.CMFA_MAX_PATH_BYTES, source.ActiveConfigPath)
	copyCStringBuffer(C.cmfa_snapshot_http_address(snapshot), C.CMFA_MAX_PATH_BYTES, source.HTTPAddress)
	copyCStringBuffer(C.cmfa_snapshot_socks_address(snapshot), C.CMFA_MAX_PATH_BYTES, source.SOCKSAddress)
	copyCStringBuffer(C.cmfa_snapshot_last_error(snapshot), C.CMFA_MAX_PATH_BYTES, source.LastError)
	snapshot.mixed_port = 0
}

func encodeTunState(state runtimepkg.TunState) C.cmfa_tun_state_value {
	switch state {
	case runtimepkg.TunStateStarting:
		return C.CMFA_TUN_STARTING
	case runtimepkg.TunStateReady:
		return C.CMFA_TUN_READY
	case runtimepkg.TunStateStopped:
		return C.CMFA_TUN_STOPPED
	case runtimepkg.TunStateError:
		return C.CMFA_TUN_ERROR
	default:
		return C.CMFA_TUN_IDLE
	}
}

func writeTunSnapshot(snapshot *C.cmfa_tun_snapshot, source runtimepkg.TunSnapshot) {
	if snapshot == nil {
		return
	}
	*snapshot = C.cmfa_tun_snapshot{}
	snapshot.struct_size = C.uint32_t(C.sizeof_cmfa_tun_snapshot)
	snapshot.state = encodeTunState(source.State)
	copyCStringBuffer(C.cmfa_tun_snapshot_session_id(snapshot), C.CMFA_MAX_TUN_SESSION_ID_BYTES, source.SessionID)
	snapshot.counters.struct_size = C.uint32_t(C.sizeof_cmfa_tun_counters)
	snapshot.counters.tx_packets = C.uint64_t(source.Counters.TXPackets)
	snapshot.counters.tx_bytes = C.uint64_t(source.Counters.TXBytes)
	snapshot.counters.rx_packets = C.uint64_t(source.Counters.RXPackets)
	snapshot.counters.rx_bytes = C.uint64_t(source.Counters.RXBytes)
	snapshot.failure.struct_size = C.uint32_t(C.sizeof_cmfa_tun_failure)
	copyCStringBuffer(C.cmfa_tun_snapshot_failure_code(snapshot), C.CMFA_MAX_TUN_FAILURE_CODE_BYTES, source.Failure.Code)
	copyCStringBuffer(C.cmfa_tun_snapshot_failure_detail(snapshot), C.CMFA_MAX_TUN_FAILURE_DETAIL_BYTES, source.Failure.Detail)
}

func sanitizeTunTraceForBridge(source runtimepkg.TunTrace) runtimepkg.TunTrace {
	sanitized := source
	sanitized.SourceAddress = ""
	sanitized.DestinationAddress = ""
	return sanitized
}

func writeTunTrace(trace *C.cmfa_tun_trace, source runtimepkg.TunTrace) {
	if trace == nil {
		return
	}
	source = sanitizeTunTraceForBridge(source)
	*trace = C.cmfa_tun_trace{}
	trace.struct_size = C.uint32_t(C.sizeof_cmfa_tun_trace)
	copyCStringBuffer(C.cmfa_tun_trace_session_id(trace), C.CMFA_MAX_TUN_SESSION_ID_BYTES, source.SessionID)
	copyCStringBuffer(C.cmfa_tun_trace_trace_id(trace), C.CMFA_MAX_TUN_TRACE_ID_BYTES, source.TraceID)
	copyCStringBuffer(C.cmfa_tun_trace_ingress(trace), C.CMFA_MAX_TUN_INGRESS_BYTES, source.Ingress)
	copyCStringBuffer(C.cmfa_tun_trace_protocol(trace), C.CMFA_MAX_TUN_PROTOCOL_BYTES, source.Protocol)
	copyCStringBuffer(C.cmfa_tun_trace_source_address(trace), C.CMFA_MAX_TUN_ADDRESS_BYTES, source.SourceAddress)
	copyCStringBuffer(C.cmfa_tun_trace_destination_address(trace), C.CMFA_MAX_TUN_ADDRESS_BYTES, source.DestinationAddress)
	copyCStringBuffer(C.cmfa_tun_trace_hashed_tuple(trace), C.CMFA_MAX_TUN_HASH_BYTES, source.HashedTuple)
	copyCStringBuffer(C.cmfa_tun_trace_correlation_hash(trace), C.CMFA_MAX_TUN_HASH_BYTES, source.CorrelationHash)
	copyCStringBuffer(C.cmfa_tun_trace_destination_hash(trace), C.CMFA_MAX_TUN_HASH_BYTES, source.DestinationHash)
	copyCStringBuffer(C.cmfa_tun_trace_outbound_terminal_hash(trace), C.CMFA_MAX_TUN_HASH_BYTES, source.OutboundTerminalHash)
	copyCStringBuffer(C.cmfa_tun_trace_outbound_chain_hash(trace), C.CMFA_MAX_TUN_HASH_BYTES, source.OutboundChainHash)
	trace.outbound_chain_length = C.uint32_t(source.OutboundChainLength)
}

func writeTunTraceCollection(collection *C.cmfa_tun_trace_collection, traces []runtimepkg.TunTrace) {
	if collection == nil {
		return
	}
	*collection = C.cmfa_tun_trace_collection{}
	collection.struct_size = C.uint32_t(C.sizeof_cmfa_tun_trace_collection)
	if len(traces) > int(C.CMFA_MAX_TUN_TRACE_COUNT) {
		traces = traces[len(traces)-int(C.CMFA_MAX_TUN_TRACE_COUNT):]
	}
	collection.trace_count = C.uint32_t(len(traces))
	for index := range traces {
		writeTunTrace(C.cmfa_tun_trace_at(collection, C.size_t(index)), traces[index])
	}
}

func writeTunTraceRing(collection *C.cmfa_tun_trace_ring, traces []runtimepkg.TunTrace) {
	if collection == nil {
		return
	}
	*collection = C.cmfa_tun_trace_ring{}
	collection.struct_size = C.uint32_t(C.sizeof_cmfa_tun_trace_ring)
	if len(traces) > int(C.CMFA_TUN_TRACE_RING_CAPACITY) {
		traces = traces[len(traces)-int(C.CMFA_TUN_TRACE_RING_CAPACITY):]
	}
	collection.trace_count = C.uint32_t(len(traces))
	for index := range traces {
		writeTunTrace((*C.cmfa_tun_trace)(unsafe.Pointer(&collection.traces[index])), traces[index])
	}
}

func writeProbeText(target *C.char, capacity int, value string) {
	copyCStringBuffer(target, C.size_t(capacity), value)
}

func writeProbeError(result *C.cmfa_probe_result, code, stage, detail string) {
	if result == nil {
		return
	}
	result.error.struct_size = C.uint32_t(C.sizeof_cmfa_probe_error)
	writeProbeText(C.cmfa_probe_error_code(result), int(C.CMFA_MAX_PROBE_KIND_BYTES), code)
	writeProbeText(C.cmfa_probe_error_stage(result), int(C.CMFA_MAX_PROBE_KIND_BYTES), stage)
	writeProbeText(C.cmfa_probe_error_detail(result), int(C.CMFA_MAX_PROBE_ERROR_BYTES), detail)
}

func clearProbeError(result *C.cmfa_probe_result) {
	writeProbeError(result, "", "", "")
}

func initializeProbeResult(result *C.cmfa_probe_result) {
	if result == nil {
		return
	}
	*result = C.cmfa_probe_result{}
	result.struct_size = C.uint32_t(C.sizeof_cmfa_probe_result)
	result.protocol = C.CMFA_PROBE_PROTOCOL_UNSPECIFIED
	result.tracker.struct_size = C.uint32_t(C.sizeof_cmfa_probe_tracker_record)
	result.error.struct_size = C.uint32_t(C.sizeof_cmfa_probe_error)
}

func probeProtocolFromC(protocol C.cmfa_probe_protocol) (probepkg.Protocol, C.cmfa_status, string) {
	switch protocol {
	case C.CMFA_PROBE_PROTOCOL_HTTP_CONNECT:
		return probepkg.ProtocolHTTPConnect, C.CMFA_OK, ""
	case C.CMFA_PROBE_PROTOCOL_SOCKS5:
		return probepkg.ProtocolSOCKS5, C.CMFA_OK, ""
	default:
		return "", C.CMFA_INVALID_ARGUMENT, "probe protocol is invalid"
	}
}

func formatProbeTime(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.UTC().Format(time.RFC3339Nano)
}

func writeProbeResult(result *C.cmfa_probe_result, protocol C.cmfa_probe_protocol, source probepkg.HTTPSResult, probeErr *probepkg.Error) {
	if result == nil {
		return
	}
	initializeProbeResult(result)
	result.ok = 0
	result.protocol = protocol
	result.http_status = C.int32_t(source.HTTPStatus)
	result.body_bytes = C.uint64_t(source.BodyBytes)
	writeProbeText(C.cmfa_probe_result_probe_run_id(result), int(C.CMFA_MAX_PROBE_ID_BYTES), source.ProbeRunID)
	writeProbeText(C.cmfa_probe_result_request_id_echo(result), int(C.CMFA_MAX_PROBE_ID_BYTES), source.RequestIDEcho)
	writeProbeText(C.cmfa_probe_result_origin_id(result), int(C.CMFA_MAX_PROBE_ID_BYTES), source.OriginID)
	writeProbeText(C.cmfa_probe_result_response_sha256(result), int(C.CMFA_MAX_PROBE_DIGEST_BYTES), source.ResponseSHA256)
	writeProbeText(C.cmfa_probe_result_tls_peer_sha256(result), int(C.CMFA_MAX_PROBE_DIGEST_BYTES), source.TLSPeerSHA256)
	writeProbeText(C.cmfa_probe_result_started_at(result), int(C.CMFA_MAX_PROBE_TIMESTAMP_BYTES), formatProbeTime(source.StartedAt))
	writeProbeText(C.cmfa_probe_result_completed_at(result), int(C.CMFA_MAX_PROBE_TIMESTAMP_BYTES), formatProbeTime(source.CompletedAt))
	writeProbeText(C.cmfa_probe_result_client_local_address(result), int(C.CMFA_MAX_PROBE_ENDPOINT_BYTES), source.ClientLocalAddress)
	writeProbeText(C.cmfa_probe_result_client_remote_address(result), int(C.CMFA_MAX_PROBE_ENDPOINT_BYTES), source.ClientRemoteAddress)
	writeProbeText(C.cmfa_probe_tracker_connection_id(result), int(C.CMFA_MAX_PROBE_ID_BYTES), source.Tracker.ConnectionID)
	writeProbeText(C.cmfa_probe_tracker_source_address(result), int(C.CMFA_MAX_PROBE_ENDPOINT_BYTES), source.Tracker.SourceAddress)
	writeProbeText(C.cmfa_probe_tracker_destination_address(result), int(C.CMFA_MAX_PROBE_ENDPOINT_BYTES), source.Tracker.DestinationAddress)
	writeProbeText(C.cmfa_probe_tracker_inbound_type(result), int(C.CMFA_MAX_PROBE_KIND_BYTES), source.Tracker.InboundType)
	writeProbeText(C.cmfa_probe_tracker_opened_at(result), int(C.CMFA_MAX_PROBE_TIMESTAMP_BYTES), formatProbeTime(source.Tracker.OpenedAt))
	if probeErr == nil {
		result.ok = 1
		clearProbeError(result)
		return
	}
	writeProbeError(result, probeErr.Code, probeErr.Stage, probeErr.Detail)
}

type runtimeLogEnvelope struct {
	Category string            `json:"category"`
	Message  string            `json:"message"`
	Context  map[string]string `json:"context,omitempty"`
}

func encodeRuntimeLogMessage(log runtimepkg.RuntimeLog) string {
	if log.Category == "runtime.tun.stage" {
		if isAllowedTunStartStage(log.Message) {
			return log.Message
		}
		return `{"category":"runtime.tun.stage.invalid","message":"invalid tun stage"}`
	}
	payload, err := json.Marshal(runtimeLogEnvelope{
		Category: log.Category,
		Message:  log.Message,
		Context:  log.Context,
	})
	if err != nil {
		return `{"category":"runtime.log.encode_failed","message":"failed to encode runtime log"}`
	}
	return string(payload)
}

func isAllowedTunStartStage(stage string) bool {
	switch stage {
	case "tun.prepare.begin",
		"tun.prepare.ok",
		"tun.prepare.failed",
		"tun.http-listener.begin",
		"tun.http-listener.ok",
		"tun.http-listener.failed",
		"tun.socks-listener.begin",
		"tun.socks-listener.ok",
		"tun.socks-listener.failed",
		"tun.listener.begin",
		"tun.listener.ok",
		"tun.listener.failure.interface",
		"tun.listener.failure.stack-create",
		"tun.listener.failure.stack-start",
		"tun.listener.failure.unknown-scope",
		"tun.listener.failure.bad-fd",
		"tun.listener.failure.permission",
		"tun.listener.failure.invalid",
		"tun.listener.failure.unsupported",
		"tun.listener.failure.io",
		"tun.listener.failure.unknown-cause",
		"tun.listener.failed":
		return true
	default:
		return false
	}
}

func failureMessage(snapshot runtimepkg.Snapshot, err error) string {
	if snapshot.LastError != "" {
		return snapshot.LastError
	}
	if err != nil {
		return err.Error()
	}
	return "runtime operation failed"
}

func tunFailureMessage(snapshot runtimepkg.TunSnapshot, err error) string {
	if snapshot.Failure.Detail != "" {
		return snapshot.Failure.Detail
	}
	if err != nil {
		return err.Error()
	}
	return "tun operation failed"
}

func probeStatus(err error) C.cmfa_status {
	if err == nil {
		return C.CMFA_OK
	}
	return C.CMFA_BACKEND_ERROR
}

func tunStatus(snapshot runtimepkg.TunSnapshot, err error) C.cmfa_status {
	switch {
	case err == nil:
		return C.CMFA_OK
	case errors.Is(err, runtimepkg.ErrRuntimeBusy):
		return C.CMFA_BUSY
	case snapshot.Failure.Code == "VPN_SOCKET_PROTECT_FAILED":
		return C.CMFA_SOCKET_PROTECT_FAILED
	default:
		return C.CMFA_BACKEND_ERROR
	}
}

func currentProxygroupsService() proxygroupsService {
	proxygroupsServiceMu.RLock()
	defer proxygroupsServiceMu.RUnlock()
	return proxygroupsRuntimeService
}

func currentProxyDelayService() proxyDelayService {
	proxyDelayServiceMu.RLock()
	defer proxyDelayServiceMu.RUnlock()
	return proxyDelayRuntimeService
}

func proxyExportAccessibleBytes(capacity uint64) int {
	if capacity == 0 {
		return 0
	}

	limit := uint64(proxygroups.MaxResponseBytes + 1)
	if capacity > limit {
		capacity = limit
	}
	return int(capacity)
}

func proxyExportBufferFromC(output *C.char, outputCapacity C.size_t, outputLength *C.size_t) (proxyRawExportBuffer, *uint64) {
	var goOutputLength *uint64
	var lengthValue uint64
	if outputLength != nil {
		goOutputLength = &lengthValue
	}

	buffer := proxyRawExportBuffer{outputLength: goOutputLength}
	size := proxyExportAccessibleBytes(uint64(outputCapacity))
	if output != nil && size > 0 {
		buffer.output = unsafe.Slice((*byte)(unsafe.Pointer(output)), size)
	}

	return buffer, goOutputLength
}

func cStringToGoStringPointer(value *C.char) *string {
	if value == nil {
		return nil
	}

	goValue := C.GoString(value)
	return &goValue
}

func toCProxyRawExportStatus(status proxyRawExportStatus) C.cmfa_status {
	switch status {
	case proxyRawExportStatusOK:
		return C.CMFA_OK
	case proxyRawExportStatusInvalidArgument:
		return C.CMFA_INVALID_ARGUMENT
	case proxyRawExportStatusInvalidUTF8:
		return C.CMFA_INVALID_UTF8
	case proxyRawExportStatusOutOfRange:
		return C.CMFA_OUT_OF_RANGE
	case proxyRawExportStatusInvalidState:
		return C.CMFA_INVALID_STATE
	case proxyRawExportStatusBackendError:
		return C.CMFA_BACKEND_ERROR
	case proxyRawExportStatusBufferTooSmall:
		return C.CMFA_BUFFER_TOO_SMALL
	default:
		return C.CMFA_BACKEND_ERROR
	}
}

func writeProxyRawExportResult(outputLength *C.size_t, goOutputLength *uint64, errorOut *C.cmfa_error, result proxyRawExportResult) C.cmfa_status {
	if outputLength != nil {
		if goOutputLength != nil {
			*outputLength = C.size_t(*goOutputLength)
		} else {
			*outputLength = 0
		}
	}

	status := toCProxyRawExportStatus(result.status)
	if result.status == proxyRawExportStatusOK {
		clearError(errorOut)
		return status
	}

	setError(errorOut, status, result.errorCode)
	return status
}

func executeProxyGroupsExport(request proxyRawExportRequest, buffer proxyRawExportBuffer) proxyRawExportResult {
	return executeProxyRawExport(request, buffer, func(ctx proxygroups.QueryContext) ([]byte, error) {
		return currentProxygroupsService().ListGroups(ctx, request.selectableOnly == 1)
	}, false, false)
}

func executeProxyGroupExport(request proxyRawExportRequest, buffer proxyRawExportBuffer) proxyRawExportResult {
	return executeProxyRawExport(request, buffer, func(ctx proxygroups.QueryContext) ([]byte, error) {
		return currentProxygroupsService().QueryGroup(ctx, *request.groupName)
	}, true, false)
}

func executeProxySelectExport(request proxyRawExportRequest, buffer proxyRawExportBuffer) proxyRawExportResult {
	return executeProxyRawExport(request, buffer, func(ctx proxygroups.QueryContext) ([]byte, error) {
		return currentProxygroupsService().Select(ctx, *request.groupName, *request.memberName)
	}, true, true)
}

func executeProxyRawExport(
	request proxyRawExportRequest,
	buffer proxyRawExportBuffer,
	invoke func(proxygroups.QueryContext) ([]byte, error),
	requireGroupName bool,
	requireMemberName bool,
) proxyRawExportResult {
	if buffer.outputLength != nil {
		*buffer.outputLength = 0
	}
	if len(buffer.output) > 0 {
		buffer.output[0] = 0
	}
	if buffer.outputLength == nil || len(buffer.output) == 0 {
		return proxyRawExportResult{
			status:    proxyRawExportStatusInvalidArgument,
			errorCode: string(proxygroups.ErrCodeProxyBridgeInvalid),
		}
	}

	ctx, status, errorCode := buildProxyQueryContext(request)
	if status != proxyRawExportStatusOK {
		return proxyRawExportResult{status: status, errorCode: errorCode}
	}
	if request.selectableOnly != 0 && request.selectableOnly != 1 {
		return proxyRawExportResult{
			status:    proxyRawExportStatusInvalidArgument,
			errorCode: string(proxygroups.ErrCodeProxyBridgeInvalid),
		}
	}
	if status, errorCode := validateProxyExportNames(request, requireGroupName, requireMemberName); status != proxyRawExportStatusOK {
		return proxyRawExportResult{status: status, errorCode: errorCode}
	}

	payload, err := invoke(ctx)
	if err != nil {
		return mapProxyRawExportError(request, err)
	}
	if len(payload) > proxygroups.MaxResponseBytes {
		return proxyRawExportResult{
			status:    proxyRawExportStatusOutOfRange,
			errorCode: string(proxygroups.ErrCodeProxyBridgeInvalid),
		}
	}
	if status := writeProxyRawExportPayload(buffer, payload); status != proxyRawExportStatusOK {
		return proxyRawExportResult{
			status:    status,
			errorCode: string(proxygroups.ErrCodeProxyBridgeInvalid),
		}
	}
	return proxyRawExportResult{status: proxyRawExportStatusOK}
}

func buildProxyQueryContext(request proxyRawExportRequest) (proxygroups.QueryContext, proxyRawExportStatus, string) {
	profileHash, status, errorCode := normalizeProxyRequiredString(request.profileHash)
	if status != proxyRawExportStatusOK {
		return proxygroups.QueryContext{}, status, errorCode
	}
	revisionHash, status, errorCode := normalizeProxyRequiredString(request.revisionHash)
	if status != proxyRawExportStatusOK {
		return proxygroups.QueryContext{}, status, errorCode
	}

	sessionHash, status, errorCode := normalizeProxyOptionalString(request.sessionHash)
	if status != proxyRawExportStatusOK {
		return proxygroups.QueryContext{}, status, errorCode
	}

	ctx := proxygroups.QueryContext{
		ProfileHash:  profileHash,
		RevisionHash: revisionHash,
		SessionHash:  sessionHash,
		Generation:   request.generation,
	}
	if err := ctx.Validate(); err != nil {
		if isProxyModelError(err, proxygroups.ErrCodeInvalidQueryContext) {
			return proxygroups.QueryContext{}, proxyRawExportStatusInvalidArgument, string(proxygroups.ErrCodeProxyBridgeInvalid)
		}
		return proxygroups.QueryContext{}, proxyRawExportStatusBackendError, string(proxygroups.ErrCodeProxyBridgeInvalid)
	}
	return ctx, proxyRawExportStatusOK, ""
}

func validateProxyExportNames(request proxyRawExportRequest, requireGroupName bool, requireMemberName bool) (proxyRawExportStatus, string) {
	if requireGroupName {
		status, errorCode := validateProxyNamePointer(request.groupName)
		if status != proxyRawExportStatusOK {
			return status, errorCode
		}
	}
	if requireMemberName {
		status, errorCode := validateProxyNamePointer(request.memberName)
		if status != proxyRawExportStatusOK {
			return status, errorCode
		}
	}
	return proxyRawExportStatusOK, ""
}

func normalizeProxyRequiredString(value *string) (string, proxyRawExportStatus, string) {
	if value == nil {
		return "", proxyRawExportStatusInvalidArgument, string(proxygroups.ErrCodeProxyBridgeInvalid)
	}
	if !utf8.ValidString(*value) {
		return "", proxyRawExportStatusInvalidUTF8, string(proxygroups.ErrCodeProxyBridgeInvalid)
	}
	return *value, proxyRawExportStatusOK, ""
}

func normalizeProxyOptionalString(value *string) (*string, proxyRawExportStatus, string) {
	if value == nil {
		return nil, proxyRawExportStatusOK, ""
	}
	if !utf8.ValidString(*value) {
		return nil, proxyRawExportStatusInvalidUTF8, string(proxygroups.ErrCodeProxyBridgeInvalid)
	}
	if *value == "" {
		return nil, proxyRawExportStatusOK, ""
	}
	copy := *value
	return &copy, proxyRawExportStatusOK, ""
}

func validateProxyNamePointer(value *string) (proxyRawExportStatus, string) {
	if value == nil {
		return proxyRawExportStatusInvalidArgument, string(proxygroups.ErrCodeProxyBridgeInvalid)
	}
	if !utf8.ValidString(*value) {
		return proxyRawExportStatusInvalidUTF8, string(proxygroups.ErrCodeProxyBridgeInvalid)
	}
	if *value == "" {
		return proxyRawExportStatusInvalidArgument, string(proxygroups.ErrCodeProxyBridgeInvalid)
	}
	if len(*value) > proxygroups.MaxNameUTF8Bytes {
		return proxyRawExportStatusOutOfRange, string(proxygroups.ErrCodeProxyBridgeInvalid)
	}
	for _, r := range *value {
		if unicode.IsControl(r) {
			return proxyRawExportStatusInvalidArgument, string(proxygroups.ErrCodeProxyBridgeInvalid)
		}
	}
	return proxyRawExportStatusOK, ""
}

func writeProxyRawExportPayload(buffer proxyRawExportBuffer, payload []byte) proxyRawExportStatus {
	required := len(payload)
	if len(buffer.output) < required+1 {
		*buffer.outputLength = uint64(required)
		return proxyRawExportStatusBufferTooSmall
	}

	copy(buffer.output[:required], payload)
	buffer.output[required] = 0
	*buffer.outputLength = uint64(required)
	return proxyRawExportStatusOK
}

func mapProxyRawExportError(request proxyRawExportRequest, err error) proxyRawExportResult {
	var modelErr *proxygroups.ModelError
	if errors.As(err, &modelErr) {
		switch modelErr.Code {
		case proxygroups.ErrCodeProxyRuntimeNotReady:
			return proxyRawExportResult{
				status:    proxyRawExportStatusInvalidState,
				errorCode: string(proxygroups.ErrCodeProxyRuntimeNotReady),
			}
		case proxygroups.ErrCodeProxyGroupNotFound:
			return proxyRawExportResult{
				status:    proxyRawExportStatusInvalidArgument,
				errorCode: string(proxygroups.ErrCodeProxyGroupNotFound),
			}
		case proxygroups.ErrCodeProxyGroupNotSelectable:
			return proxyRawExportResult{
				status:    proxyRawExportStatusInvalidArgument,
				errorCode: string(proxygroups.ErrCodeProxyGroupNotSelectable),
			}
		case proxygroups.ErrCodeProxyMemberNotFound:
			return proxyRawExportResult{
				status:    proxyRawExportStatusInvalidArgument,
				errorCode: string(proxygroups.ErrCodeProxyMemberNotFound),
			}
		case proxygroups.ErrCodeProxySelectionFailed:
			return proxyRawExportResult{
				status:    proxyRawExportStatusBackendError,
				errorCode: string(proxygroups.ErrCodeProxySelectionFailed),
			}
		case proxygroups.ErrCodeResponseTooLarge:
			return proxyRawExportResult{
				status:    proxyRawExportStatusOutOfRange,
				errorCode: string(proxygroups.ErrCodeProxyBridgeInvalid),
			}
		default:
			return proxyRawExportResult{
				status:    proxyRawExportStatusBackendError,
				errorCode: string(proxygroups.ErrCodeProxyBridgeInvalid),
			}
		}
	}

	errorCode := proxygroups.ErrCodeProxyBridgeInvalid
	if request.memberName != nil {
		errorCode = proxygroups.ErrCodeProxySelectionFailed
	}
	return proxyRawExportResult{
		status:    proxyRawExportStatusBackendError,
		errorCode: string(errorCode),
	}
}

func isProxyModelError(err error, code proxygroups.ErrorCode) bool {
	var modelErr *proxygroups.ModelError
	return errors.As(err, &modelErr) && modelErr.Code == code
}

func executeProxyDelayStartExport(request proxyRawExportRequest, buffer proxyRawExportBuffer) (result proxyRawExportResult) {
	defer func() {
		if recover() != nil {
			result = proxyRawExportResult{
				status:    proxyRawExportStatusBackendError,
				errorCode: delayBridgeInvalidErrorCode,
			}
		}
	}()

	if buffer.outputLength != nil {
		*buffer.outputLength = 0
	}
	if len(buffer.output) > 0 {
		buffer.output[0] = 0
	}
	if buffer.outputLength == nil || len(buffer.output) == 0 {
		return proxyRawExportResult{
			status:    proxyRawExportStatusInvalidArgument,
			errorCode: delayBridgeInvalidErrorCode,
		}
	}

	ctx, status, _ := buildProxyQueryContext(request)
	if status != proxyRawExportStatusOK {
		return proxyRawExportResult{
			status:    status,
			errorCode: delayBridgeInvalidErrorCode,
		}
	}
	if status, _ := validateProxyNamePointer(request.groupName); status != proxyRawExportStatusOK {
		return proxyRawExportResult{
			status:    status,
			errorCode: delayBridgeInvalidErrorCode,
		}
	}

	snapshot, err := currentProxyDelayService().Start(ctx, *request.groupName)
	if err != nil {
		return mapProxyDelayExportError(err)
	}
	return marshalProxyDelaySnapshot(buffer, snapshot)
}

func executeProxyDelaySnapshotExport(jobID *string, buffer proxyRawExportBuffer) (result proxyRawExportResult) {
	defer func() {
		if recover() != nil {
			result = proxyRawExportResult{
				status:    proxyRawExportStatusBackendError,
				errorCode: delayBridgeInvalidErrorCode,
			}
		}
	}()

	if buffer.outputLength != nil {
		*buffer.outputLength = 0
	}
	if len(buffer.output) > 0 {
		buffer.output[0] = 0
	}
	if buffer.outputLength == nil || len(buffer.output) == 0 {
		return proxyRawExportResult{
			status:    proxyRawExportStatusInvalidArgument,
			errorCode: delayBridgeInvalidErrorCode,
		}
	}

	normalizedJobID, status, errorCode := normalizeProxyDelayJobID(jobID)
	if status != proxyRawExportStatusOK {
		return proxyRawExportResult{status: status, errorCode: errorCode}
	}

	snapshot, err := currentProxyDelayService().Read(normalizedJobID)
	if err != nil {
		return mapProxyDelayExportError(err)
	}
	return marshalProxyDelaySnapshot(buffer, snapshot)
}

func executeProxyDelayCancelExport(jobID *string, buffer proxyRawExportBuffer) (result proxyRawExportResult) {
	defer func() {
		if recover() != nil {
			result = proxyRawExportResult{
				status:    proxyRawExportStatusBackendError,
				errorCode: delayBridgeInvalidErrorCode,
			}
		}
	}()

	if buffer.outputLength != nil {
		*buffer.outputLength = 0
	}
	if len(buffer.output) > 0 {
		buffer.output[0] = 0
	}
	if buffer.outputLength == nil || len(buffer.output) == 0 {
		return proxyRawExportResult{
			status:    proxyRawExportStatusInvalidArgument,
			errorCode: delayBridgeInvalidErrorCode,
		}
	}

	normalizedJobID, status, errorCode := normalizeProxyDelayJobID(jobID)
	if status != proxyRawExportStatusOK {
		return proxyRawExportResult{status: status, errorCode: errorCode}
	}

	snapshot, err := currentProxyDelayService().Cancel(normalizedJobID)
	if err != nil {
		return mapProxyDelayExportError(err)
	}
	return marshalProxyDelaySnapshot(buffer, snapshot)
}

func normalizeProxyDelayJobID(value *string) (string, proxyRawExportStatus, string) {
	if value == nil {
		return "", proxyRawExportStatusInvalidArgument, delayBridgeInvalidErrorCode
	}
	if !utf8.ValidString(*value) {
		return "", proxyRawExportStatusInvalidUTF8, delayBridgeInvalidErrorCode
	}
	if len(*value) != proxygroups.MaxDelayJobIDBytes {
		return "", proxyRawExportStatusInvalidArgument, delayBridgeInvalidErrorCode
	}
	for _, r := range *value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return "", proxyRawExportStatusInvalidArgument, delayBridgeInvalidErrorCode
		}
	}
	return *value, proxyRawExportStatusOK, ""
}

func marshalProxyDelaySnapshot(buffer proxyRawExportBuffer, snapshot proxygroups.DelayTestSnapshot) proxyRawExportResult {
	payload, err := snapshot.MarshalJSONBytes()
	if err != nil {
		return mapProxyDelayExportError(err)
	}
	if len(payload) > proxygroups.MaxResponseBytes {
		return proxyRawExportResult{
			status:    proxyRawExportStatusOutOfRange,
			errorCode: delayBridgeInvalidErrorCode,
		}
	}
	if status := writeProxyRawExportPayload(buffer, payload); status != proxyRawExportStatusOK {
		return proxyRawExportResult{
			status:    status,
			errorCode: delayBridgeInvalidErrorCode,
		}
	}
	return proxyRawExportResult{status: proxyRawExportStatusOK}
}

func mapProxyDelayExportError(err error) proxyRawExportResult {
	var modelErr *proxygroups.ModelError
	if errors.As(err, &modelErr) {
		switch modelErr.Code {
		case proxygroups.ErrCodeDelayJobNotFound:
			return proxyRawExportResult{
				status:    proxyRawExportStatusInvalidState,
				errorCode: delayJobNotFoundErrorCode,
			}
		case proxygroups.ErrCodeProxyGroupNotFound:
			return proxyRawExportResult{
				status:    proxyRawExportStatusInvalidArgument,
				errorCode: delayBridgeInvalidErrorCode,
			}
		case proxygroups.ErrCodeProxyRuntimeNotReady:
			return proxyRawExportResult{
				status:    proxyRawExportStatusInvalidState,
				errorCode: delayBridgeInvalidErrorCode,
			}
		case proxygroups.ErrCodeResponseTooLarge:
			return proxyRawExportResult{
				status:    proxyRawExportStatusOutOfRange,
				errorCode: delayBridgeInvalidErrorCode,
			}
		default:
			return proxyRawExportResult{
				status:    proxyRawExportStatusBackendError,
				errorCode: delayBridgeInvalidErrorCode,
			}
		}
	}
	return proxyRawExportResult{
		status:    proxyRawExportStatusBackendError,
		errorCode: delayBridgeInvalidErrorCode,
	}
}

func drainProxyDelayJobsForMutation() error {
	var err error
	recovered := false
	func() {
		defer func() {
			if recover() != nil {
				recovered = true
			}
		}()
		err = currentProxyDelayService().CancelActiveAndDrain()
	}()
	if recovered {
		return errors.New(delayBridgeInvalidErrorCode)
	}
	return err
}

func executeAfterProxyDelayDrain(initOutput func(), mutate func() proxyMutationResult) proxyMutationResult {
	if initOutput != nil {
		initOutput()
	}
	if err := drainProxyDelayJobsForMutation(); err != nil {
		return proxyMutationResult{
			status:  proxyMutationBackendErrorStatus,
			message: delayBridgeInvalidErrorCode,
		}
	}
	return mutate()
}

func writeProxyMutationResult(errorOut *C.cmfa_error, result proxyMutationResult) C.cmfa_status {
	status := C.cmfa_status(result.status)
	if result.status == int(C.CMFA_OK) {
		clearError(errorOut)
		return C.CMFA_OK
	}
	setError(errorOut, status, result.message)
	return status
}

//export cmfa_mihomo_core_version_cstr_v1
func cmfa_mihomo_core_version_cstr_v1() *C.char {
	coreVersionOnce.Do(func() {
		coreVersionCStr = C.CString(goCoreVersion())
	})

	return coreVersionCStr
}

//export cmfa_mihomo_core_build_info_json_cstr_v1
func cmfa_mihomo_core_build_info_json_cstr_v1() *C.char {
	buildInfoOnce.Do(func() {
		buildInfoCStr = C.CString(goBuildInfoJSON())
	})

	return buildInfoCStr
}

//export cmfa_mihomo_validate_config_v1
func cmfa_mihomo_validate_config_v1(configPath *C.char, errorOut *C.cmfa_error) C.cmfa_status {
	if configPath == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "config path must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}

	err := validateConfigForNative(C.GoString(configPath))
	status := configStatus(err)
	if err != nil {
		setError(errorOut, status, err.Error())
		return status
	}
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_load_config_v1
func cmfa_mihomo_load_config_v1(configPath *C.char, errorOut *C.cmfa_error) C.cmfa_status {
	if configPath == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "config path must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}

	return writeProxyMutationResult(errorOut, executeAfterProxyDelayDrain(nil, func() proxyMutationResult {
		err := loadConfigForLocalProxy(C.GoString(configPath))
		status := configStatus(err)
		if err != nil {
			return proxyMutationResult{status: int(status), message: err.Error()}
		}
		return proxyMutationResult{status: int(C.CMFA_OK)}
	}))
}

//export cmfa_mihomo_proxy_groups_v1
func cmfa_mihomo_proxy_groups_v1(
	profileHash *C.char,
	revisionHash *C.char,
	sessionHash *C.char,
	generation C.uint64_t,
	selectableOnly C.uint8_t,
	output *C.char,
	outputCapacity C.size_t,
	outputLength *C.size_t,
	errorOut *C.cmfa_error,
) C.cmfa_status {
	buffer, goOutputLength := proxyExportBufferFromC(output, outputCapacity, outputLength)
	result := executeProxyGroupsExport(proxyRawExportRequest{
		profileHash:    cStringToGoStringPointer(profileHash),
		revisionHash:   cStringToGoStringPointer(revisionHash),
		sessionHash:    cStringToGoStringPointer(sessionHash),
		generation:     uint64(generation),
		selectableOnly: uint8(selectableOnly),
	}, buffer)
	return writeProxyRawExportResult(outputLength, goOutputLength, errorOut, result)
}

//export cmfa_mihomo_proxy_group_v1
func cmfa_mihomo_proxy_group_v1(
	profileHash *C.char,
	revisionHash *C.char,
	sessionHash *C.char,
	generation C.uint64_t,
	groupName *C.char,
	output *C.char,
	outputCapacity C.size_t,
	outputLength *C.size_t,
	errorOut *C.cmfa_error,
) C.cmfa_status {
	buffer, goOutputLength := proxyExportBufferFromC(output, outputCapacity, outputLength)
	result := executeProxyGroupExport(proxyRawExportRequest{
		profileHash:  cStringToGoStringPointer(profileHash),
		revisionHash: cStringToGoStringPointer(revisionHash),
		sessionHash:  cStringToGoStringPointer(sessionHash),
		generation:   uint64(generation),
		groupName:    cStringToGoStringPointer(groupName),
	}, buffer)
	return writeProxyRawExportResult(outputLength, goOutputLength, errorOut, result)
}

//export cmfa_mihomo_proxy_select_v1
func cmfa_mihomo_proxy_select_v1(
	profileHash *C.char,
	revisionHash *C.char,
	sessionHash *C.char,
	generation C.uint64_t,
	groupName *C.char,
	memberName *C.char,
	output *C.char,
	outputCapacity C.size_t,
	outputLength *C.size_t,
	errorOut *C.cmfa_error,
) C.cmfa_status {
	buffer, goOutputLength := proxyExportBufferFromC(output, outputCapacity, outputLength)
	result := executeProxySelectExport(proxyRawExportRequest{
		profileHash:  cStringToGoStringPointer(profileHash),
		revisionHash: cStringToGoStringPointer(revisionHash),
		sessionHash:  cStringToGoStringPointer(sessionHash),
		generation:   uint64(generation),
		groupName:    cStringToGoStringPointer(groupName),
		memberName:   cStringToGoStringPointer(memberName),
	}, buffer)
	return writeProxyRawExportResult(outputLength, goOutputLength, errorOut, result)
}

//export cmfa_mihomo_proxy_delay_start_v1
func cmfa_mihomo_proxy_delay_start_v1(
	profileHash *C.char,
	revisionHash *C.char,
	sessionHash *C.char,
	generation C.uint64_t,
	groupName *C.char,
	output *C.char,
	outputCapacity C.size_t,
	outputLength *C.size_t,
	errorOut *C.cmfa_error,
) C.cmfa_status {
	buffer, goOutputLength := proxyExportBufferFromC(output, outputCapacity, outputLength)
	result := executeProxyDelayStartExport(proxyRawExportRequest{
		profileHash:  cStringToGoStringPointer(profileHash),
		revisionHash: cStringToGoStringPointer(revisionHash),
		sessionHash:  cStringToGoStringPointer(sessionHash),
		generation:   uint64(generation),
		groupName:    cStringToGoStringPointer(groupName),
	}, buffer)
	return writeProxyRawExportResult(outputLength, goOutputLength, errorOut, result)
}

//export cmfa_mihomo_proxy_delay_snapshot_v1
func cmfa_mihomo_proxy_delay_snapshot_v1(
	jobID *C.char,
	output *C.char,
	outputCapacity C.size_t,
	outputLength *C.size_t,
	errorOut *C.cmfa_error,
) C.cmfa_status {
	buffer, goOutputLength := proxyExportBufferFromC(output, outputCapacity, outputLength)
	result := executeProxyDelaySnapshotExport(cStringToGoStringPointer(jobID), buffer)
	return writeProxyRawExportResult(outputLength, goOutputLength, errorOut, result)
}

//export cmfa_mihomo_proxy_delay_cancel_v1
func cmfa_mihomo_proxy_delay_cancel_v1(
	jobID *C.char,
	output *C.char,
	outputCapacity C.size_t,
	outputLength *C.size_t,
	errorOut *C.cmfa_error,
) C.cmfa_status {
	buffer, goOutputLength := proxyExportBufferFromC(output, outputCapacity, outputLength)
	result := executeProxyDelayCancelExport(cStringToGoStringPointer(jobID), buffer)
	return writeProxyRawExportResult(outputLength, goOutputLength, errorOut, result)
}

//export cmfa_mihomo_start_local_v1
func cmfa_mihomo_start_local_v1(configPath *C.char,
	mixedPort C.uint32_t,
	snapshot *C.cmfa_runtime_snapshot,
	errorOut *C.cmfa_error,
) C.cmfa_status {
	if configPath == nil || snapshot == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "config path and snapshot must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}

	return writeProxyMutationResult(errorOut, executeAfterProxyDelayDrain(func() {
		writeSnapshot(snapshot, runtimepkg.Snapshot{})
	}, func() proxyMutationResult {
		result, err := localProxy.Start(buildLocalStartOptions(C.GoString(configPath), uint32(mixedPort)))
		writeSnapshot(snapshot, result)
		status := runtimeStatus(err)
		if err != nil {
			return proxyMutationResult{status: int(status), message: failureMessage(result, err)}
		}
		return proxyMutationResult{status: int(C.CMFA_OK)}
	}))
}

//export cmfa_mihomo_stop_v1
func cmfa_mihomo_stop_v1(errorOut *C.cmfa_error) C.cmfa_status {
	return writeProxyMutationResult(errorOut, executeAfterProxyDelayDrain(nil, func() proxyMutationResult {
		result, err := localProxy.Stop()
		status := runtimeStatus(err)
		if err != nil {
			return proxyMutationResult{status: int(status), message: failureMessage(result, err)}
		}
		return proxyMutationResult{status: int(C.CMFA_OK)}
	}))
}

//export cmfa_mihomo_runtime_state_v1
func cmfa_mihomo_runtime_state_v1(snapshot *C.cmfa_runtime_snapshot, errorOut *C.cmfa_error) C.cmfa_status {
	if snapshot == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "snapshot must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}

	writeSnapshot(snapshot, localProxy.Snapshot())
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_runtime_mode_v1
func cmfa_mihomo_runtime_mode_v1(modeOut *C.cmfa_runtime_mode, errorOut *C.cmfa_error) C.cmfa_status {
	if modeOut == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "runtime mode output must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}
	mode, err := runtimeModeService.Query()
	if err != nil {
		setError(errorOut, C.CMFA_BACKEND_ERROR, "runtime mode query failed")
		return C.CMFA_BACKEND_ERROR
	}
	*modeOut = encodeRuntimeMode(mode)
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_set_runtime_mode_v1
func cmfa_mihomo_set_runtime_mode_v1(rawMode C.cmfa_runtime_mode, errorOut *C.cmfa_error) C.cmfa_status {
	mode, err := decodeRuntimeMode(rawMode)
	if err != nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "runtime mode is invalid")
		return C.CMFA_INVALID_ARGUMENT
	}
	if _, err := runtimeModeService.Set(mode); err != nil {
		if errors.Is(err, runtimecontrol.ErrInvalidMode) {
			setError(errorOut, C.CMFA_INVALID_ARGUMENT, "runtime mode is invalid")
			return C.CMFA_INVALID_ARGUMENT
		}
		setError(errorOut, C.CMFA_BACKEND_ERROR, "runtime mode switch failed")
		return C.CMFA_BACKEND_ERROR
	}
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_start_tun_v1
func cmfa_mihomo_start_tun_v1(options *C.cmfa_tun_options, snapshot *C.cmfa_tun_snapshot, errorOut *C.cmfa_error) C.cmfa_status {
	if options == nil || snapshot == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "tun options and snapshot must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}

	return writeProxyMutationResult(errorOut, executeAfterProxyDelayDrain(func() {
		writeTunSnapshot(snapshot, runtimepkg.TunSnapshot{})
	}, func() proxyMutationResult {
		result, err := localProxy.StartTun(buildTunStartOptions(
			C.GoString(C.cmfa_tun_options_config_path(options)),
			uint32(C.cmfa_tun_options_mixed_port(options)),
			C.GoString(C.cmfa_tun_options_session_id(options)),
			int(options.tun_fd),
			uint32(C.cmfa_tun_options_platform_api_level(options)),
			C.cmfa_tun_options_process_protected(options) != 0,
		))
		writeTunSnapshot(snapshot, result)
		status := tunStatus(result, err)
		if err != nil {
			return proxyMutationResult{status: int(status), message: tunFailureMessage(result, err)}
		}
		return proxyMutationResult{status: int(C.CMFA_OK)}
	}))
}

//export cmfa_mihomo_stop_tun_v1
func cmfa_mihomo_stop_tun_v1(errorOut *C.cmfa_error) C.cmfa_status {
	return writeProxyMutationResult(errorOut, executeAfterProxyDelayDrain(nil, func() proxyMutationResult {
		_, err := localProxy.Stop()
		result := localProxy.TunSnapshot()
		status := tunStatus(result, err)
		if err != nil {
			return proxyMutationResult{status: int(status), message: tunFailureMessage(result, err)}
		}
		return proxyMutationResult{status: int(C.CMFA_OK)}
	}))
}

//export cmfa_mihomo_tun_runtime_state_v1
func cmfa_mihomo_tun_runtime_state_v1(snapshot *C.cmfa_tun_snapshot, errorOut *C.cmfa_error) C.cmfa_status {
	if snapshot == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "tun snapshot must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}

	writeTunSnapshot(snapshot, localProxy.TunSnapshot())
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_tun_copy_traces_v1
func cmfa_mihomo_tun_copy_traces_v1(traces *C.cmfa_tun_trace_collection, errorOut *C.cmfa_error) C.cmfa_status {
	if traces == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "tun traces must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}

	writeTunTraceCollection(traces, localProxy.CopyTunTraces(int(C.CMFA_MAX_TUN_TRACE_COUNT)))
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_tun_copy_traces_ring_v1
func cmfa_mihomo_tun_copy_traces_ring_v1(traces *C.cmfa_tun_trace_ring, errorOut *C.cmfa_error) C.cmfa_status {
	if traces == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "tun trace ring must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}
	writeTunTraceRing(traces, localProxy.CopyTunTraces(int(C.CMFA_TUN_TRACE_RING_CAPACITY)))
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_close_stale_tun_connections_v1
func cmfa_mihomo_close_stale_tun_connections_v1(sessionID *C.char, errorOut *C.cmfa_error) C.cmfa_status {
	if sessionID == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "tun session id must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}

	if err := localProxy.CloseStaleOutboundConnections(C.GoString(sessionID)); err != nil {
		switch {
		case errors.Is(err, runtimepkg.ErrRuntimeBusy):
			setError(errorOut, C.CMFA_BUSY, err.Error())
			return C.CMFA_BUSY
		case runtimepkg.IsTunSessionRequired(err):
			setError(errorOut, C.CMFA_INVALID_ARGUMENT, err.Error())
			return C.CMFA_INVALID_ARGUMENT
		default:
			setError(errorOut, C.CMFA_BACKEND_ERROR, err.Error())
			return C.CMFA_BACKEND_ERROR
		}
	}
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_take_runtime_log_v1
func cmfa_mihomo_take_runtime_log_v1(record *C.cmfa_mihomo_runtime_log_record_v1) C.int {
	if record == nil {
		return 0
	}

	record.struct_size = C.uint32_t(C.sizeof_cmfa_mihomo_runtime_log_record_v1)
	record.level = C.CMFA_LOG_INFO
	copyCStringBuffer(C.cmfa_runtime_log_message(record), C.size_t(len(record.message)), "")

	log, ok := runtimeLogs.Take()
	if !ok {
		return 0
	}

	record.level = encodeLogLevel(log.Level)
	copyCStringBuffer(C.cmfa_runtime_log_message(record), C.size_t(len(record.message)), encodeRuntimeLogMessage(log))
	return 1
}

//export cmfa_mihomo_probe_https_v1
func cmfa_mihomo_probe_https_v1(request *C.cmfa_probe_request,
	result *C.cmfa_probe_result,
	errorOut *C.cmfa_error,
) C.cmfa_status {
	if request == nil || result == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "probe request and result must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}
	initializeProbeResult(result)
	result.protocol = request.protocol

	protocol, status, message := probeProtocolFromC(request.protocol)
	if status != C.CMFA_OK {
		writeProbeError(result, "INVALID_ARGUMENT", "request", message)
		setError(errorOut, status, message)
		return status
	}

	ctx, cancel := context.WithTimeout(context.Background(), probeDefaultTimeout)
	defer cancel()

	probeResult, err := probepkg.HTTPS(
		ctx,
		probepkg.HTTPSRequest{
			ProbeRunID:         C.GoString(request.probe_run_id),
			Protocol:           protocol,
			ListenerAddress:    C.GoString(request.listener_address),
			OriginURL:          C.GoString(request.origin_url),
			CAPEM:              []byte(C.GoString(request.ca_pem)),
			ExpectedBodySHA256: C.GoString(request.expected_body_sha256),
		},
	)
	var probeErr *probepkg.Error
	if err != nil && errors.As(err, &probeErr) {
		writeProbeResult(result, request.protocol, probeResult, probeErr)
		setError(errorOut, probeStatus(err), probeErr.Detail)
		return probeStatus(err)
	}
	if err != nil {
		writeProbeError(result, "BACKEND_ERROR", "probe", err.Error())
		setError(errorOut, C.CMFA_BACKEND_ERROR, err.Error())
		return C.CMFA_BACKEND_ERROR
	}

	writeProbeResult(result, request.protocol, probeResult, nil)
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_probe_cancel_v1
func cmfa_mihomo_probe_cancel_v1(probeRunID *C.char, errorOut *C.cmfa_error) C.cmfa_status {
	if probeRunID == nil {
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "probeRunID must not be null")
		return C.CMFA_INVALID_ARGUMENT
	}

	switch probepkg.CancelProbeRun(C.GoString(probeRunID)) {
	case probepkg.CancelRunInvalid:
		setError(errorOut, C.CMFA_INVALID_ARGUMENT, "probeRunID must not be empty")
		return C.CMFA_INVALID_ARGUMENT
	default:
		clearError(errorOut)
		return C.CMFA_OK
	}
}

func main() {}
