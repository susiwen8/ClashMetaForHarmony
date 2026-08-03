package main

/*
#include <stdint.h>
char *go_cmfa_probe_version_impl(void);
int32_t go_cmfa_probe_add_impl(int32_t left, int32_t right);
const char *cmfa_probe_version(void);
int32_t cmfa_probe_add(int32_t left, int32_t right);
*/
import "C"

import (
	"sync"
)

var (
	probeVersionOnce sync.Once
	probeVersionCStr *C.char
)

const probeVersion = "cmfa-probe/v1"

func goProbeVersion() string {
	return probeVersion
}

func goProbeAdd(left, right int32) int32 {
	return left + right
}

//export go_cmfa_probe_version_impl
func go_cmfa_probe_version_impl() *C.char {
	probeVersionOnce.Do(func() {
		probeVersionCStr = C.CString(goProbeVersion())
	})

	return probeVersionCStr
}

//export go_cmfa_probe_add_impl
func go_cmfa_probe_add_impl(left, right C.int32_t) C.int32_t {
	return C.int32_t(goProbeAdd(int32(left), int32(right)))
}

func main() {}
