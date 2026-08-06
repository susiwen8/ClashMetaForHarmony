package main

/*
#cgo CFLAGS: -I${SRCDIR}/../../../abi/include
#include <stdint.h>
#include <string.h>

#include "cmfa_types.h"

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
*/
import "C"

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"unicode/utf8"
	"unsafe"

	configpkg "github.com/clashmetaforandroid/harmony/core/go/internal/config"
	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
	"github.com/clashmetaforandroid/harmony/core/go/internal/version"
)

var (
	coreVersionOnce sync.Once
	coreVersionCStr *C.char
	buildInfoOnce   sync.Once
	buildInfoCStr   *C.char
	localProxy      = runtimepkg.NewLocalProxyWithDeps(runtimepkg.LocalProxyDeps{
		Prepare: loadConfigForLocalProxy,
	})
)

func goCoreVersion() string {
	return version.Build().Version
}

func goBuildInfoJSON() string {
	payload, err := json.Marshal(version.Build())
	if err != nil {
		return `{"error":"marshal build info"}`
	}
	return string(payload)
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
		setError(errorOut, status, err.Error())
		return status
	}
	clearError(errorOut)
	return C.CMFA_OK
}

//export cmfa_mihomo_stop_v1
func cmfa_mihomo_stop_v1(errorOut *C.cmfa_error) C.cmfa_status {
	_, err := localProxy.Stop()
	status := runtimeStatus(err)
	if err != nil {
		setError(errorOut, status, err.Error())
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
func main() {}
