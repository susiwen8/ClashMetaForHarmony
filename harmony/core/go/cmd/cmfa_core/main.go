package main

/*
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"sync"

	"github.com/clashmetaforandroid/harmony/core/go/internal/version"
)

var (
	coreVersionOnce sync.Once
	coreVersionCStr *C.char
	buildInfoOnce   sync.Once
	buildInfoCStr   *C.char
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
func main() {}
