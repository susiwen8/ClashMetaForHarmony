package main

/*
#cgo CFLAGS: -I${SRCDIR}/../../../abi/include
#include <stdint.h>
#include <string.h>

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
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
	"unicode/utf8"
	"unsafe"

	configpkg "github.com/clashmetaforandroid/harmony/core/go/internal/config"
	probepkg "github.com/clashmetaforandroid/harmony/core/go/internal/probe"
	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
	"github.com/clashmetaforandroid/harmony/core/go/internal/version"
)

var (
	coreVersionOnce     sync.Once
	coreVersionCStr     *C.char
	buildInfoOnce       sync.Once
	buildInfoCStr       *C.char
	probeDefaultTimeout = probepkg.DefaultTimeout
	runtimeLogs         = runtimepkg.NewLogBuffer(32)
	localProxy          = runtimepkg.NewLocalProxyWithDeps(runtimepkg.LocalProxyDeps{
		Prepare:             loadConfigForLocalProxy,
		Logs:                runtimeLogs,
		MaxLogContextFields: 4,
		MaxLogFieldBytes:    256,
	})
)

func goCoreVersion() string {
	return version.Build().Version
}

func goBuildInfoJSON() string {
	return version.BuildInfoJSON()
}

func loadConfigForLocalProxy(configPath string) error {
	sandboxRoot, candidate, err := configSandbox(configPath)
	if err != nil {
		return err
	}

	loader := configpkg.NewLoader(sandboxRoot)
	return loader.Load(candidate)
}

func configSandbox(configPath string) (string, string, error) {
	if filepath.IsAbs(configPath) {
		dir := filepath.Dir(configPath)
		base := filepath.Base(configPath)
		if base == "." || base == string(filepath.Separator) {
			return "", "", errors.New("config path must name a file")
		}
		return dir, base, nil
	}

	wd, err := os.Getwd()
	if err != nil {
		return "", "", err
	}
	return wd, configPath, nil
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

func failureMessage(snapshot runtimepkg.Snapshot, err error) string {
	if snapshot.LastError != "" {
		return snapshot.LastError
	}
	if err != nil {
		return err.Error()
	}
	return "runtime operation failed"
}

func probeStatus(err error) C.cmfa_status {
	if err == nil {
		return C.CMFA_OK
	}
	return C.CMFA_BACKEND_ERROR
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

	result, err := localProxy.Start(runtimepkg.StartOptions{
		ConfigPath:         C.GoString(configPath),
		HTTPListenAddress:  "127.0.0.1:" + strconv.FormatUint(uint64(mixedPort), 10),
		SOCKSListenAddress: "127.0.0.1:0",
	})
	writeSnapshot(snapshot, result)
	status := runtimeStatus(err)
	if err != nil {
		setError(errorOut, status, failureMessage(result, err))
		return status
	}
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_stop_v1
func cmfa_mihomo_stop_v1(errorOut *C.cmfa_error) C.cmfa_status {
	result, err := localProxy.Stop()
	status := runtimeStatus(err)
	if err != nil {
		setError(errorOut, status, failureMessage(result, err))
		return status
	}
	clearError(errorOut)
	return C.CMFA_OK
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
